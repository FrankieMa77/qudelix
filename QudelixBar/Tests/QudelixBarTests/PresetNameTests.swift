import XCTest
@testable import QudelixBar

/// The name payload is `[group, index, endOffset, utf8…]` with
/// `endOffset = 3 + byteCount`, confirmed against hardware.
///
/// The failure that identifies the shape is worth restating, because it is
/// what these tests exist to prevent regressing to: sending the text with no
/// offset byte makes the device read the first character *as* the offset and
/// store the remainder, so "ZQ7" comes back as "Q7". Losing the leading
/// character is the visible symptom; writing at the wrong offset is the real
/// one.
final class PresetNameTests: XCTestCase {

    func testPayloadShapeForAsciiName() {
        let p = QxPacket.presetNamePayload(group: .b20, index: 0, name: "ZQ7")
        XCTAssertEqual(p, [0x02, 0x00, 0x06, 0x5A, 0x51, 0x37])
    }

    /// The offset counts the header too, so it is 3 + the text, not the text.
    func testEndOffsetCountsTheHeader() {
        for text in ["A", "AB", "a longer preset name"] {
            let p = QxPacket.presetNamePayload(group: .user, index: 3, name: text)
            XCTAssertEqual(p?[2], UInt8(3 + text.utf8.count), "for \(text)")
            XCTAssertEqual(p?.count, 3 + text.utf8.count)
        }
    }

    func testGroupAndIndexAreCarried() {
        XCTAssertEqual(QxPacket.presetNamePayload(group: .user, index: 0, name: "x")?.prefix(2),
                       [0x00, 0x00])
        XCTAssertEqual(QxPacket.presetNamePayload(group: .b20, index: 19, name: "x")?.prefix(2),
                       [0x02, 0x13])
    }

    /// Clearing a slot is an empty field: header only, offset 3.
    func testEmptyNameClearsTheSlot() {
        XCTAssertEqual(QxPacket.presetNamePayload(group: .b20, index: 0, name: ""),
                       [0x02, 0x00, 0x03])
    }

    func testRejectsSlotOutsideTheDevicesRange() {
        for i in [-1, 20, 255, Int.max] {
            XCTAssertNil(QxPacket.presetNamePayload(group: .user, index: i, name: "x"),
                         "index \(i) must produce no packet")
        }
        XCTAssertNotNil(QxPacket.presetNamePayload(group: .user, index: 19, name: "x"))
    }

    // MARK: - Naming a slot when a curve is saved into it

    /// Saving an imported correction into a slot should leave the slot called
    /// what the correction is called — otherwise the library reads "Preset 7".
    func testASourcedCurveNamesTheSlot() {
        XCTAssertEqual(
            QudelixController.nameOnSave(source: "Sennheiser HD 650 · Harman", existing: nil,
                                        unchangedSinceSource: true),
            "Sennheiser HD 650 · Harman")
        XCTAssertEqual(
            QudelixController.nameOnSave(source: "HD 650", existing: "Preset 7",
                                        unchangedSinceSource: true),
            "HD 650")
    }

    /// A hand-shaped curve has no name to offer. Clearing whatever the user
    /// typed there, in exchange for nothing, would be worse than leaving it.
    func testAHandShapedCurveLeavesAnExistingNameAlone() {
        XCTAssertNil(QudelixController.nameOnSave(source: nil, existing: "Night listening", unchangedSinceSource: true))
        XCTAssertNil(QudelixController.nameOnSave(source: nil, existing: nil, unchangedSinceSource: true))
        XCTAssertNil(QudelixController.nameOnSave(source: "   ", existing: "Night listening", unchangedSinceSource: true))
    }

    /// Re-saving a slot under the name it already carries is a pointless write
    /// to a part that stores it in flash.
    func testNoWriteWhenTheNameWouldNotChange() {
        XCTAssertNil(QudelixController.nameOnSave(source: "HD 650", existing: "HD 650", unchangedSinceSource: true))
    }

    /// Whatever comes back here still goes through the payload builder, so an
    /// over-long source name is cut there rather than refused.
    func testALongSourceNameStillProducesAValidPayload() {
        let long = String(repeating: "Sennheiser HD 650 ", count: 5)
        let name = QudelixController.nameOnSave(source: long, existing: nil,
                                                unchangedSinceSource: true)
        let payload = QxPacket.presetNamePayload(group: .b20, index: 4,
                                                 name: try! XCTUnwrap(name))
        XCTAssertNotNil(payload)
        XCTAssertLessThanOrEqual(payload!.count - 3, QxPacket.maxPresetNameBytes)
    }

    /// A curve shaped since it arrived is no longer the thing the name
    /// describes. Labelling a slot "HD 650" when it holds an hour of by-ear
    /// tuning on top of HD 650 is worse than leaving it unnamed, because the
    /// label would be believed. `eqSourceName` survives every hand edit on
    /// purpose — the overlay needs it — so this is the guard that stops it
    /// being used for something it cannot answer.
    func testAnEditedCurveIsNotNamedAfterWhatItStartedAs() {
        XCTAssertNil(QudelixController.nameOnSave(source: "HD 650", existing: nil,
                                                  unchangedSinceSource: false))
        XCTAssertNil(QudelixController.nameOnSave(source: "HD 650", existing: "Preset 3",
                                                  unchangedSinceSource: false),
                     "an existing name must survive rather than be overwritten wrongly")
    }

    // MARK: - Byte budget, not character budget

    func testLongAsciiNameIsCutToTheFieldWidth() {
        let p = QxPacket.presetNamePayload(group: .user, index: 0,
                                           name: String(repeating: "a", count: 200))
        XCTAssertEqual(p?.count, 3 + QxPacket.maxPresetNameBytes)
        XCTAssertEqual(p?[2], UInt8(3 + QxPacket.maxPresetNameBytes))
    }

    /// A name of multi-byte characters runs out of room long before it looks
    /// long. Cutting by character count would overrun the field.
    func testMultiByteNameIsCutByBytes() {
        for name in ["日本語のプリセット名前です", "🎧🎧🎧🎧🎧🎧🎧🎧🎧🎧🎧🎧", "ñññññññññññññññññññññññññññññññ"] {
            guard let p = QxPacket.presetNamePayload(group: .user, index: 0, name: name) else {
                return XCTFail("should still produce a packet for \(name)")
            }
            XCTAssertLessThanOrEqual(p.count - 3, QxPacket.maxPresetNameBytes)
            XCTAssertEqual(p[2], UInt8(p.count))
        }
    }

    /// Cutting must land between characters — never mid-scalar, which would
    /// store bytes that are not text.
    func testTruncationNeverSplitsACharacter() {
        for name in ["🎧🎧🎧🎧🎧🎧🎧🎧🎧🎧", "日本語日本語日本語日本語日本語"] {
            let p = QxPacket.presetNamePayload(group: .user, index: 0, name: name)!
            let text = Array(p.dropFirst(3))
            XCTAssertNotNil(String(bytes: text, encoding: .utf8),
                            "truncated \(name) must still decode as UTF-8")
        }
    }

    func testTruncatingIsIdentityWhenItFits() {
        XCTAssertEqual(QxPacket.truncatingUTF8("HD 800 Harman", to: 29), "HD 800 Harman")
        XCTAssertEqual(QxPacket.truncatingUTF8("", to: 29), "")
    }

    /// The cap matches the offset the device itself reports for the field end,
    /// so a full-length write cannot run past it.
    func testMaxOffsetMatchesTheFieldTheDeviceReports() {
        let p = QxPacket.presetNamePayload(group: .b20, index: 0,
                                           name: String(repeating: "z", count: 100))!
        XCTAssertEqual(p[2], 32, "the largest offset written must be the reported field end")
    }
}
