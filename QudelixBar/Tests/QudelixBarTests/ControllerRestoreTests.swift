import XCTest
@testable import QudelixBar

@MainActor
final class ControllerRestoreTests: XCTestCase {
    private let a = DeviceRig.curve(first: 3)
    private let b = DeviceRig.curve(first: -4)

    override func tearDown() async throws {
        DeviceRig.cleanUp()
    }

    func testARestoreSurvivesTheRateChangeThatRenamesTheDevice() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connect("Qudelix-5K USB DAC 96KHz", bands: a)
        c.flushEqSnapshot()
        XCTAssertEqual(rig.savedSnapshots[0]?.bands, a)

        await rig.detachUSB()
        await rig.connect("Qudelix-5K USB DAC 44.1KHz", bands: b)

        XCTAssertEqual(c.bands.first?.gain, 3, "the curve the user left is put back after the rename")
        XCTAssertEqual(c.lastImportSummary, "Restored your last EQ")
    }

    func testASnapshotTaggedWithTheOldFullNameStillMatchesTheSameDevice() async {
        let rig = DeviceRig(seed: DeviceRig.snapshot("usb:Qudelix-5K USB DAC 96KHz", bands: a))
        await rig.connect("Qudelix-5K USB DAC 48KHz", bands: b)

        XCTAssertEqual(rig.controller.bands.first?.gain, 3)
    }

    func testACurveFromAnotherUSBProductIsNeverWrittenBack() async {
        let rig = DeviceRig(seed: DeviceRig.snapshot("usb:Other DAC 96KHz", bands: a))
        await rig.connect("Qudelix-5K USB DAC 96KHz", bands: b)

        XCTAssertEqual(rig.controller.bands.first?.gain, -4)
        XCTAssertNotEqual(rig.controller.lastImportSummary, "Restored your last EQ")
    }

    func testACurveWithNoRecordedDeviceIsNeverWrittenBack() async {
        let rig = DeviceRig(seed: DeviceRig.snapshot(nil, bands: a))
        await rig.connect("Qudelix-5K USB DAC 96KHz", bands: b)

        XCTAssertEqual(rig.controller.bands.first?.gain, -4)
    }

    func testACurveSavedOverBluetoothIsNeverWrittenBackOverUSB() async {
        let rig = DeviceRig(seed: DeviceRig.snapshot(
            "ble:806760C0-0000-0000-0000-000000000000", bands: a))
        await rig.connect("Qudelix-5K USB DAC 96KHz", bands: b)

        XCTAssertEqual(rig.controller.bands.first?.gain, -4)
    }

    private var unreadable: [QxEqBandValue] {
        var bands = DeviceRig.curve()
        bands[4].freq = 30000
        return bands
    }

    func testAnImplausibleReadbackIsNeverFiledAsTheLastEq() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connect(bands: unreadable)
        XCTAssertEqual(c.bands.first?.gain, 0)

        c.flushEqSnapshot()
        XCTAssertTrue(rig.savedSnapshots.isEmpty,
                      "a placeholder is not something the device said")

        var edited = c.bands[0]
        edited.gain = 5
        c.updateBand(0, edited)
        c.flushEqSnapshot()
        XCTAssertTrue(rig.savedSnapshots.isEmpty, "one edit does not make the rest real")
    }

    func testAFlatPlaceholderNeverBecomesTheRestoreOnTheNextGoodConnect() async {
        let rig = DeviceRig()
        await rig.connect(bands: unreadable)
        rig.controller.flushEqSnapshot()

        let next = rig.restarted()
        await next.connect(bands: DeviceRig.curve(first: 2))
        XCTAssertEqual(next.controller.bands.first?.gain, 2)
        XCTAssertNil(next.controller.lastImportSummary)
    }

    func testAnImplausibleReadbackStillGetsTheLastEqBack() async {
        let rig = DeviceRig(seed: DeviceRig.snapshot("usb:Qudelix-5K", bands: a))
        let c = rig.controller
        await rig.connect(bands: unreadable)

        XCTAssertEqual(c.bands.first?.gain, 3)
        XCTAssertEqual(c.lastImportSummary, "Restored your last EQ")
        c.flushEqSnapshot()
        XCTAssertEqual(rig.savedSnapshots[0]?.bands, a, "the restored curve is real and may be filed")
    }

    func testARestoreIsOneStepTheUserCanUndo() async {
        let rig = DeviceRig(seed: DeviceRig.snapshot("usb:Qudelix-5K", bands: a))
        let c = rig.controller
        await rig.connect(bands: b)

        XCTAssertEqual(c.bands.first?.gain, 3)
        XCTAssertEqual(c.undoStack.count, 1, "the 23 writes are one step, not 23")
        XCTAssertEqual(c.undoLabel, "restore last EQ")

        c.undoEqEdit()
        XCTAssertEqual(c.bands.first?.gain, -4, "undo brings back what the device had")
        XCTAssertFalse(c.canUndo)
        XCTAssertTrue(c.canRedo)
    }

    func testARestoreStaysInTheDevicesRAMAndNeverReachesFlash() async {
        let rig = DeviceRig(seed: DeviceRig.snapshot("usb:Qudelix-5K", bands: a))
        let c = rig.controller
        await rig.connect(bands: b)
        XCTAssertEqual(c.lastImportSummary, "Restored your last EQ")
        XCTAssertFalse(c.debugFlashSavePending,
                       "a power cycle must return the device to its own flash state")

        var edited = c.bands[2]
        edited.gain = 4
        c.updateBand(2, edited)
        XCTAssertTrue(c.debugFlashSavePending, "a deliberate edit is still committed")
    }

    func testUndoingARestoreIsNotRestoredAgainByTheSnapshot() async {
        let rig = DeviceRig(seed: DeviceRig.snapshot("usb:Qudelix-5K", bands: a))
        let c = rig.controller
        await rig.connect(bands: b)
        c.undoEqEdit()
        c.flushEqSnapshot()

        XCTAssertEqual(rig.savedSnapshots[0]?.bands.first?.gain, -4,
                       "what the user walked back to is what the next connect compares with")
    }

    private func decide(snapshotSlot: Int?, deviceSlot: Int) async -> QudelixController {
        let rig = DeviceRig(seed: DeviceRig.snapshot("usb:Qudelix-5K", bands: a, slot: snapshotSlot))
        await rig.connect(bands: b, slot: deviceSlot)
        withExtendedLifetime(rig) {}
        return rig.controller
    }

    func testALoadOfAnotherSlotElsewhereIsNotRevertedOnConnect() async {
        let c = await decide(snapshotSlot: 3, deviceSlot: 5)
        XCTAssertEqual(c.bands.first?.gain, -4)
        XCTAssertNil(c.lastImportSummary)
        XCTAssertEqual(c.activePreset, 5)
        XCTAssertFalse(c.canUndo)
    }

    func testTheSameSlotWithADifferentCurveIsStillRestored() async {
        let c = await decide(snapshotSlot: 3, deviceSlot: 3)
        XCTAssertEqual(c.bands.first?.gain, 3)
        XCTAssertEqual(c.lastImportSummary, "Restored your last EQ")
    }

    func testACustomCurveOnTheDeviceIsStillRestored() async {
        let c = await decide(snapshotSlot: 3, deviceSlot: 255)
        XCTAssertEqual(c.bands.first?.gain, 3)
    }

    func testASnapshotWithNoSlotIsStillRestoredOverASlot() async {
        let c = await decide(snapshotSlot: nil, deviceSlot: 5)
        XCTAssertEqual(c.bands.first?.gain, 3)
    }

    func testTheSnapshotRecordsTheActiveSlot() async {
        let rig = DeviceRig()
        await rig.connect(bands: a, slot: 4)
        rig.controller.flushEqSnapshot()
        XCTAssertEqual(rig.savedSnapshots[0]?.activePreset, 4)
    }

    func testAnOldSnapshotFileWithoutASlotStillLoads() throws {
        let json = """
        {"groups": {"0": {"groupRaw": 0, "bands": [], "preGain": 0, "enabled": true}}}
        """
        let store = try JSONDecoder().decode(EqSnapshotStore.self, from: Data(json.utf8))
        XCTAssertNil(store[0]?.activePreset)
    }

    private func readBackBeforeTheSlotReport(_ rig: DeviceRig) async {
        let c = rig.controller
        await rig.attachUSB()
        c.debugIngest(Wire.initData())
        c.debugIngest(Wire.packet(.rspDevConfig,
                                  [QxConfigMask.sys] + Wire.sysBlock(eqMode: 0)))
        rig.ingest(Wire.presetPackets(group: .user, bands: b, preGain: 0))
    }

    func testTheDecisionWaitsForTheSlotReportWhenTheReadBackComesFirst() async {
        let rig = DeviceRig(seed: DeviceRig.snapshot("usb:Qudelix-5K", bands: a, slot: 3))
        let c = rig.controller
        await readBackBeforeTheSlotReport(rig)
        XCTAssertEqual(c.bands.first?.gain, -4, "nothing is written before the slot is known")

        c.debugIngest(Wire.eqConfigOnly(group: 0, slot: 5))
        XCTAssertEqual(c.bands.first?.gain, -4, "another slot: leave the device alone")

        let again = DeviceRig(seed: DeviceRig.snapshot("usb:Qudelix-5K", bands: a, slot: 3))
        await readBackBeforeTheSlotReport(again)
        again.controller.debugIngest(Wire.eqConfigOnly(group: 0, slot: 3))
        XCTAssertEqual(again.controller.bands.first?.gain, 3)
    }

    func testTheDecisionIsTakenAnywayIfTheSlotNeverArrives() async throws {
        let rig = DeviceRig(seed: DeviceRig.snapshot("usb:Qudelix-5K", bands: a, slot: 3))
        let c = rig.controller
        c.slotReportWait = 0.05
        await readBackBeforeTheSlotReport(rig)
        XCTAssertEqual(c.bands.first?.gain, -4)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(c.bands.first?.gain, 3)
        XCTAssertEqual(c.lastImportSummary, "Restored your last EQ")
    }

    func testASnapshotWritesKeepTheStoredSlotUntilTheDeviceReportsOne() async {
        let rig = DeviceRig(seed: DeviceRig.snapshot("usb:Qudelix-5K", bands: a, slot: 2))
        let c = rig.controller
        c.slotReportWait = 60
        await readBackBeforeTheSlotReport(rig)
        c.flushEqSnapshot()
        XCTAssertEqual(rig.savedSnapshots[0]?.activePreset, 2)
    }
}
