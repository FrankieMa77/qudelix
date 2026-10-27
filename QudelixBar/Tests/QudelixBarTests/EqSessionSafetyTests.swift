import XCTest
@testable import QudelixBar

@MainActor
final class EqSessionSafetyTests: XCTestCase {
    override func tearDown() async throws { DeviceRig.cleanUp() }

    private let orig = DeviceRig.curve(first: 3)

    private func connected(preGain: Double = 0) async -> DeviceRig {
        let rig = DeviceRig()
        await rig.connect(bands: orig, preGain: preGain, slot: 255)
        try? await Task.sleep(for: .milliseconds(400))
        return rig
    }

    private func tempWrite(_ c: QudelixController) {
        var t = c.bands[0]
        t.gain = -9
        c.updateBand(0, t, persistToFlash: false, recordUndo: false)
    }

    func testPendingSaveDoesNotFireInsideASession() async {
        let rig = await connected()
        let c = rig.controller
        var b = c.bands[1]; b.gain = 2
        c.updateBand(1, b)
        XCTAssertTrue(c.debugFlashSavePending)
        c.setByEarSessionActive(true)
        XCTAssertFalse(c.debugFlashSavePending)
        c.setEqEnabled(false, persistToFlash: false, duringSession: true)
        XCTAssertFalse(c.debugFlashSavePending)
    }

    func testUsersPendingSaveIsRearmedWhenTheSessionEnds() async {
        let rig = await connected()
        let c = rig.controller
        var b = c.bands[1]; b.gain = 2
        c.updateBand(1, b)
        c.setByEarSessionActive(true)
        c.setByEarSessionActive(false)
        XCTAssertTrue(c.debugFlashSavePending)
    }

    func testNoPendingSaveMeansNoneAfterTheSession() async {
        let rig = await connected()
        let c = rig.controller
        c.setByEarSessionActive(true)
        tempWrite(c)
        c.setByEarSessionActive(false)
        XCTAssertFalse(c.debugFlashSavePending)
    }

    func testSnapshotKeepsTheBaselineNotTheTempCurve() async {
        let rig = await connected()
        let c = rig.controller
        let baseline = c.bands[0].gain
        c.setByEarSessionActive(true)
        tempWrite(c)
        c.flushEqSnapshot()
        XCTAssertEqual(rig.savedSnapshots[0]?.bands[0].gain, baseline)
    }

    func testToneStyleEqOffDoesNotReachTheSnapshot() async {
        let rig = await connected()
        let c = rig.controller
        c.beginEqSession()
        c.setEqEnabled(false, persistToFlash: false, duringSession: true)
        c.flushEqSnapshot()
        XCTAssertEqual(rig.savedSnapshots[0]?.enabled, true)
    }

    func testDropEndsTheSessionAndReconnectDoesNotRestoreTheTempCurve() async {
        let rig = await connected()
        let c = rig.controller
        let baseline = c.bands[0].gain
        c.setByEarSessionActive(true)
        tempWrite(c)
        c.flushEqSnapshot()
        await rig.detachUSB()
        XCTAssertFalse(c.byEarSessionActive)
        await rig.connect(bands: orig, slot: 255)
        XCTAssertEqual(c.bands[0].gain, baseline)
        XCTAssertNotEqual(c.lastImportSummary, "Restored your last EQ")
    }

    func testKeepWithUnchangedPreGainStillArmsTheFlashSave() async {
        let rig = await connected(preGain: -3)
        let c = rig.controller
        c.setByEarSessionActive(true)
        tempWrite(c)
        c.setPreGain(c.preGain, recordUndo: false, force: true)
        c.setByEarSessionActive(false)
        XCTAssertTrue(c.debugFlashSavePending)
    }

    func testWritersRefuseWhileASessionRuns() async {
        let rig = await connected()
        let c = rig.controller
        c.setByEarSessionActive(true)
        c.clearSendTrace()
        XCTAssertFalse(c.loadPreset(2))
        XCTAssertFalse(c.apply(ParametricEQFile()))
        XCTAssertNotNil(c.lastImportSummary)
        c.flatten()
        c.savePreset(2)
        c.setEqEnabled(false)
        c.undoEqEdit()
        XCTAssertTrue(c.eqEnabled)
        XCTAssertTrue(c.sendTrace.isEmpty, "\(c.sendTrace)")
    }

    func testWritersWorkAgainAfterTheSession() async {
        let rig = await connected()
        let c = rig.controller
        c.setByEarSessionActive(true)
        c.setByEarSessionActive(false)
        XCTAssertTrue(c.loadPreset(2))
    }

    func testRefusedApplyDuringModeSwitchBlamesTheSwitch() async {
        let rig = await connected()
        let c = rig.controller
        c.setEqMode(twentyBand: true)
        XCTAssertFalse(c.apply(ParametricEQFile()))
        XCTAssertTrue(c.lastImportSummary?.contains("switching EQ mode") ?? false, "\(String(describing: c.lastImportSummary))")
    }

    func testTunersRefuseToStartWithTheEqOff() async {
        let rig = await connected()
        let c = rig.controller
        c.setEqEnabled(false, persistToFlash: false)
        XCTAssertEqual(ABTuner.blocker(c), .eqOff)
        XCTAssertEqual(BlindTuner.blocker(c, mode: .shape), .eqOff)
    }

    func testUnknownInitFormatIsAnExplicitUnsupportedState() async {
        let rig = DeviceRig()
        await rig.attachUSB()
        var packet = Wire.initData()
        packet[5] = 9
        rig.controller.debugIngest(packet)
        guard case .unsupported = rig.controller.compatibility else {
            return XCTFail("\(rig.controller.compatibility)")
        }
    }
}
