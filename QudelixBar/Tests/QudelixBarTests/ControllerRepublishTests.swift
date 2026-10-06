import Combine
import XCTest
@testable import QudelixBar

@MainActor
final class ControllerRepublishTests: XCTestCase {
    override func tearDown() async throws {
        DeviceRig.cleanUp()
    }

    private var limit: Double { -3 }

    private func packets() -> [(String, [UInt8])] {
        [
            ("status push", Wire.statusNotification(percent: 70, volume: -10.5, muted: false,
                                                    limit: limit, trimLeft: -2, trimRight: -4,
                                                    audio: Wire.audioBlock())),
            ("config with sys and eq", Wire.deviceConfig(eqMode: 0, group: 0, slot: 3)),
            ("config with volume block", Wire.packet(.rspDevConfig,
                [QxConfigMask.vol] + Wire.volumeBlock(volume: -10.5, limit: limit,
                                                      trimLeft: -2, trimRight: -4))),
            ("slot notification", Wire.presetChanged(group: 0, slot: 3)),
            ("eq enable notification", Wire.notification([130, 0, 1])),
            ("device status reply", Wire.packet(.rspDevStatus,
                [QxStatusMask.power | QxStatusMask.vol] + Wire.powerBlock(percent: 70)
                + Wire.volumeBlock(volume: -10.5, limit: limit, trimLeft: -2, trimRight: -4)
                + [0])),
        ]
    }

    private func warmedUp() async -> DeviceRig {
        let rig = DeviceRig()
        await rig.connect(slot: 3)
        for _ in 0..<2 {
            for (_, packet) in packets() { rig.controller.debugIngest(packet) }
        }
        return rig
    }

    func testAnIdenticalPacketRepublishesNothing() async {
        let rig = await warmedUp()
        let c = rig.controller
        for (name, packet) in packets() {
            var changes = 0
            let sub = c.objectWillChange.sink { changes += 1 }
            for _ in 0..<10 { c.debugIngest(packet) }
            sub.cancel()
            XCTAssertEqual(changes, 0, "\(name) redrew the popover")
        }
    }

    func testTheFieldsStillTrackWhatTheDeviceReports() async {
        let rig = await warmedUp()
        let c = rig.controller
        XCTAssertEqual(c.batteryPercent, 70)
        XCTAssertEqual(c.volumeDb, -10.5, accuracy: 0.02)
        XCTAssertEqual(c.volumeLimitDb, limit, accuracy: 0.02)
        XCTAssertEqual(c.volumeMax, limit, accuracy: 0.02)
        XCTAssertEqual(c.trimLeftDb, -2, accuracy: 0.02)
        XCTAssertEqual(c.trimRightDb, -4, accuracy: 0.02)
        XCTAssertEqual(c.activePreset, 3)
        XCTAssertEqual(c.usbFsMode, 4)
        XCTAssertFalse(c.muted)
        XCTAssertTrue(c.eqEnabled)
        XCTAssertEqual(c.compatibility, .ok)
    }

    func testAChangedValueStillGetsThrough() async {
        let rig = await warmedUp()
        let c = rig.controller
        var changes = 0
        let sub = c.objectWillChange.sink { changes += 1 }

        c.debugIngest(Wire.statusNotification(volume: -20, muted: true, limit: limit,
                                              trimLeft: -2, trimRight: -4))
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(c.volumeDb, -20, accuracy: 0.02)
        XCTAssertTrue(c.muted)

        c.debugIngest(Wire.presetChanged(group: 0, slot: 7))
        XCTAssertEqual(c.activePreset, 7)
        c.debugIngest(Wire.notification([130, 0, 0]))
        XCTAssertFalse(c.eqEnabled)
        sub.cancel()
    }

    func testARepeatedReadBackOfTheSamePresetRepublishesNothing() async {
        let rig = await warmedUp()
        let c = rig.controller
        var changes = 0
        let sub = c.objectWillChange.sink { changes += 1 }
        for _ in 0..<5 {
            rig.ingest(Wire.presetPackets(group: .user, bands: DeviceRig.curve(), preGain: 0))
        }
        sub.cancel()
        XCTAssertEqual(changes, 0)
    }

    func testTheSameSlotNameTwiceRepublishesNothing() async {
        let rig = await warmedUp()
        let c = rig.controller
        let name = Array("Reference".utf8)
        let packet = Wire.packet(.rspEqPresetName, [0, 4, UInt8(3 + name.count)] + name)
        c.debugIngest(packet)
        var changes = 0
        let sub = c.objectWillChange.sink { changes += 1 }
        c.debugIngest(packet)
        sub.cancel()
        XCTAssertEqual(c.presetNames[4], "Reference")
        XCTAssertEqual(changes, 0)
    }
}
