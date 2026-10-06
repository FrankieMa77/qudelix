import XCTest
@testable import QudelixBar

final class PresetNameTests: XCTestCase {
    func testPayloadShapeForAsciiName() {
        let p = QxPacket.presetNamePayload(group: .b20, index: 0, name: "ZQ7")
        XCTAssertEqual(p, [0x02, 0x00, 0x06, 0x5A, 0x51, 0x37])
    }

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

    func testAHandShapedCurveLeavesAnExistingNameAlone() {
        XCTAssertNil(QudelixController.nameOnSave(source: nil, existing: "Night listening", unchangedSinceSource: true))
        XCTAssertNil(QudelixController.nameOnSave(source: nil, existing: nil, unchangedSinceSource: true))
        XCTAssertNil(QudelixController.nameOnSave(source: "   ", existing: "Night listening", unchangedSinceSource: true))
    }

    func testNoWriteWhenTheNameWouldNotChange() {
        XCTAssertNil(QudelixController.nameOnSave(source: "HD 650", existing: "HD 650", unchangedSinceSource: true))
    }

    func testALongSourceNameStillProducesAValidPayload() {
        let long = String(repeating: "Sennheiser HD 650 ", count: 5)
        let name = QudelixController.nameOnSave(source: long, existing: nil,
                                                unchangedSinceSource: true)
        let payload = QxPacket.presetNamePayload(group: .b20, index: 4,
                                                 name: try! XCTUnwrap(name))
        XCTAssertNotNil(payload)
        XCTAssertLessThanOrEqual(payload!.count - 3, QxPacket.maxPresetNameBytes)
    }

    func testAnEditedCurveIsNotNamedAfterWhatItStartedAs() {
        XCTAssertNil(QudelixController.nameOnSave(source: "HD 650", existing: nil,
                                                  unchangedSinceSource: false))
        XCTAssertNil(QudelixController.nameOnSave(source: "HD 650", existing: "Preset 3",
                                                  unchangedSinceSource: false),
                     "an existing name must survive rather than be overwritten wrongly")
    }

    func testLongAsciiNameIsCutToTheFieldWidth() {
        let p = QxPacket.presetNamePayload(group: .user, index: 0,
                                           name: String(repeating: "a", count: 200))
        XCTAssertEqual(p?.count, 3 + QxPacket.maxPresetNameBytes)
        XCTAssertEqual(p?[2], UInt8(3 + QxPacket.maxPresetNameBytes))
    }

    func testMultiByteNameIsCutByBytes() {
        for name in ["日本語のプリセット名前です", "🎧🎧🎧🎧🎧🎧🎧🎧🎧🎧🎧🎧", "ñññññññññññññññññññññññññññññññ"] {
            guard let p = QxPacket.presetNamePayload(group: .user, index: 0, name: name) else {
                return XCTFail("should still produce a packet for \(name)")
            }
            XCTAssertLessThanOrEqual(p.count - 3, QxPacket.maxPresetNameBytes)
            XCTAssertEqual(p[2], UInt8(p.count))
        }
    }

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

    func testMaxOffsetMatchesTheFieldTheDeviceReports() {
        let p = QxPacket.presetNamePayload(group: .b20, index: 0,
                                           name: String(repeating: "z", count: 100))!
        XCTAssertEqual(p[2], 32, "the largest offset written must be the reported field end")
    }
}
