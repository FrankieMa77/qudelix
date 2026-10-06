import XCTest
@testable import QudelixBar

@MainActor
final class ControllerSnapshotTimingTests: XCTestCase {
    override func tearDown() async throws {
        DeviceRig.cleanUp()
    }

    private func editFirstBand(_ c: QudelixController, to gain: Double) {
        var band = c.bands[0]
        band.gain = gain
        c.updateBand(0, band)
    }

    func testAnEditJustBeforeAUSBDropStillReachesTheSnapshot() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connect(bands: DeviceRig.curve(first: 1))
        c.flushEqSnapshot()

        editFirstBand(c, to: 6)
        await rig.detachUSB()
        XCTAssertEqual(rig.savedSnapshots[0]?.bands.first?.gain, 6)
    }

    func testTheNextConnectDoesNotRevertThatEdit() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connect(bands: DeviceRig.curve(first: 1))
        c.flushEqSnapshot()

        editFirstBand(c, to: 6)
        await rig.detachUSB()
        await rig.connect(bands: DeviceRig.curve(first: 6))

        XCTAssertEqual(c.bands.first?.gain, 6)
        XCTAssertNil(c.lastImportSummary)
        XCTAssertFalse(c.canUndo)
    }

    func testAnEditJustBeforeABluetoothDropStillReachesTheSnapshot() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connectBluetooth(bands: DeviceRig.curve(first: 1))
        c.flushEqSnapshot()
        XCTAssertEqual(c.link, .bluetooth)

        editFirstBand(c, to: 6)
        await rig.detachBluetooth()
        XCTAssertEqual(rig.savedSnapshots[0]?.bands.first?.gain, 6)
    }

    func testAnEditJustBeforeTheLinkIsReleasedStillReachesTheSnapshot() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connect(bands: DeviceRig.curve(first: 1))
        c.flushEqSnapshot()

        editFirstBand(c, to: 6)
        c.debugFireUSBUnusable()
        await rig.settle()
        XCTAssertEqual(rig.savedSnapshots[0]?.bands.first?.gain, 6)
    }

    func testAnEditJustBeforeAGroupSwitchStillReachesTheOutgoingGroupsSnapshot() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connect(bands: DeviceRig.curve(first: 1))
        c.flushEqSnapshot()

        editFirstBand(c, to: 6)
        c.debugIngest(Wire.deviceConfig(eqMode: 1, group: 2, slot: 255))

        XCTAssertEqual(c.eqGroup, .b20)
        XCTAssertEqual(rig.savedSnapshots[0]?.bands.first?.gain, 6)
        XCTAssertNil(rig.savedSnapshots[2], "nothing is filed under the incoming group yet")
    }

    func testAHandoverFromBluetoothToUSBFilesTheCurveUnderTheLinkItCameFrom() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connectBluetooth(bands: DeviceRig.curve(first: 1))
        c.flushEqSnapshot()

        editFirstBand(c, to: 6)
        await rig.attachUSB()
        XCTAssertEqual(rig.savedSnapshots[0]?.bands.first?.gain, 6)
        XCTAssertNotEqual(rig.savedSnapshots[0]?.deviceIdentity, "usb:Qudelix-5K",
                          "a Bluetooth curve must not be tagged as the USB device's")
    }

    func testNothingIsFiledWhenNoEditIsPending() async {
        let rig = DeviceRig()
        await rig.connect(bands: DeviceRig.curve(first: 1))
        await rig.detachUSB()
        XCTAssertTrue(rig.savedSnapshots.isEmpty || rig.savedSnapshots[0]?.bands.first?.gain == 1)
    }
}
