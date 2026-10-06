import XCTest
@testable import QudelixBar

@MainActor
final class DeviceRigTests: XCTestCase {
    func testAHandshakeBringsTheControllerUpOverUSB() async {
        let rig = DeviceRig()
        let c = rig.controller
        let curve = DeviceRig.curve(first: 3)
        await rig.connect(bands: curve, preGain: -2, slot: 4)

        XCTAssertEqual(c.link, .usb)
        XCTAssertTrue(c.receivingReports)
        XCTAssertEqual(c.compatibility, .ok)
        XCTAssertEqual(c.eqGroup, .user)
        XCTAssertEqual(c.activePreset, 4)
        XCTAssertEqual(c.bands, curve)
        XCTAssertEqual(c.preGain, -2, accuracy: 0.05)
    }

    func testATwentyBandHandshakeSwitchesTheGroupAndReadsItsCurve() async {
        let rig = DeviceRig()
        let c = rig.controller
        let curve = DeviceRig.curve(.b20, first: -4)
        await rig.connect(group: .b20, bands: curve, slot: 2)

        XCTAssertEqual(c.eqGroup, .b20)
        XCTAssertEqual(c.bands, curve)
        XCTAssertEqual(c.activePreset, 2)
    }

    func testStatusNotificationsCarryBatteryAndVolume() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connect()
        c.debugIngest(Wire.statusNotification(percent: 73, volume: -12.5))
        XCTAssertEqual(c.batteryPercent, 73)
        XCTAssertEqual(c.volumeDb, -12.5, accuracy: 0.02)
    }
}

extension DeviceRigTests {
    func testTheLinkDropsAndComesBack() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connect()
        XCTAssertEqual(c.connection, .connected(name: "Qudelix-5K USB DAC 96KHz"))

        await rig.detachUSB()
        XCTAssertEqual(c.link, .none)
        XCTAssertEqual(c.connection, .disconnected)
        XCTAssertFalse(c.receivingReports)

        await rig.connect()
        XCTAssertEqual(c.link, .usb)
        XCTAssertEqual(c.compatibility, .ok)
    }
}
