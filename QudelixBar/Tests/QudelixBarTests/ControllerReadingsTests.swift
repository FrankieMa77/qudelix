import XCTest
@testable import QudelixBar

@MainActor
final class ControllerReadingsTests: XCTestCase {
    override func tearDown() async throws {
        DeviceRig.cleanUp()
    }

    func testTheReportedLevelIsNilUntilTheDeviceSendsAVolumeBlock() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connect()
        XCTAssertTrue(c.receivingReports)
        XCTAssertNil(c.reportedVolumeDb, "the -30 dB placeholder is not the 5K's level")

        c.debugIngest(Wire.statusNotification(percent: 80))
        XCTAssertNil(c.reportedVolumeDb, "a battery push says nothing about the level")

        c.debugIngest(Wire.statusNotification(volume: -10.5))
        XCTAssertEqual(c.reportedVolumeDb ?? 0, -10.5, accuracy: 0.02)
    }

    func testTheReportedLevelIsForgottenWithTheLink() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connect()
        c.debugIngest(Wire.statusNotification(volume: -10.5))
        XCTAssertNotNil(c.reportedVolumeDb)

        await rig.detachUSB()
        await rig.connect()
        XCTAssertNil(c.reportedVolumeDb, "a new connection has not reported a level yet")
    }

    func testAMutedDeviceStillReportsNoLevel() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connect()
        c.debugIngest(Wire.statusNotification(volume: -10.5, muted: true))
        XCTAssertNil(c.reportedVolumeDb)
    }
}
