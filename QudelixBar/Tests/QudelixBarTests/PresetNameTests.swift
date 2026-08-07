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
