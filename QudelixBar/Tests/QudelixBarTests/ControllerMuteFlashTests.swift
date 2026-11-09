import XCTest
@testable import QudelixBar

@MainActor
final class ControllerMuteFlashTests: XCTestCase {
    override func tearDown() async throws { DeviceRig.cleanUp() }

    private func connected() async -> QudelixController {
        let rig = DeviceRig()
        await rig.connect(bands: DeviceRig.curve(first: 3), slot: 255)
        try? await Task.sleep(for: .milliseconds(400))
        rig.controller.clearSendTrace()
        keep = rig
        return rig.controller
    }

    private var keep: DeviceRig?

    private func edit(_ c: QudelixController, band: Int = 1, gain: Double = 2) {
        var b = c.bands[band]
        b.gain = gain
        c.updateBand(band, b)
    }

    private func settleSave(_ c: QudelixController) {
        c.debugFireFlashSave()
        c.clearSendTrace()
    }

    func testUndoArmsTheSave() async {
        let c = await connected()
        edit(c)
        settleSave(c)
        XCTAssertFalse(c.debugFlashSavePending)
        c.undoEqEdit()
        XCTAssertTrue(c.debugFlashSavePending)
    }

    func testRedoArmsTheSave() async {
        let c = await connected()
        edit(c)
        c.undoEqEdit()
        settleSave(c)
        XCTAssertFalse(c.debugFlashSavePending)
        c.redoEqEdit()
        XCTAssertTrue(c.debugFlashSavePending)
    }

    func testAMutePendingSaveIsParkedUntilTheLastUnmute() async {
        let c = await connected()
        edit(c)
        XCTAssertTrue(c.debugFlashSavePending)
        c.setBandMuted(2, true)
        XCTAssertFalse(c.debugFlashSavePending)
        edit(c, band: 3, gain: 1)
        XCTAssertFalse(c.debugFlashSavePending)
        c.setBandMuted(4, true)
        c.setBandMuted(2, false)
        XCTAssertFalse(c.debugFlashSavePending)
        c.setBandMuted(4, false)
        XCTAssertTrue(c.debugFlashSavePending)
    }

    func testAFilterChangeThatDropsTheLastMuteReleasesTheParkedSave() async {
        let c = await connected()
        edit(c)
        c.setBandMuted(2, true)
        XCTAssertFalse(c.debugFlashSavePending)
        var b = c.bands[2]
        b.filter = .peak
        b.gain = 4
        c.updateBand(2, b, persistToFlash: false)
        XCTAssertTrue(c.mutedBands.isEmpty)
        XCTAssertTrue(c.debugFlashSavePending)
    }

    func testUndoWhileMutedParksInsteadOfArming() async {
        let c = await connected()
        c.setBandMuted(2, true)
        edit(c, band: 3, gain: 1)
        XCTAssertFalse(c.debugFlashSavePending)
        c.undoEqEdit()
        XCTAssertFalse(c.mutedBands.isEmpty)
        XCTAssertFalse(c.debugFlashSavePending)
    }

    func testTheParkedSaveSurvivesAnOverlappingByEarSession() async {
        let c = await connected()
        edit(c)
        c.setBandMuted(2, true)
        c.setByEarSessionActive(true)
        c.setByEarSessionActive(false)
        XCTAssertFalse(c.debugFlashSavePending)
        c.setBandMuted(2, false)
        XCTAssertTrue(c.debugFlashSavePending)
    }

    func testTheParkedSaveFiresExactlyOnce() async {
        let c = await connected()
        edit(c)
        c.setBandMuted(2, true)
        c.setByEarSessionActive(true)
        c.setByEarSessionActive(false)
        c.setBandMuted(2, false)
        XCTAssertTrue(c.debugFlashSavePending)
        c.debugFireFlashSave()
        XCTAssertFalse(c.debugFlashSavePending)
        c.setByEarSessionActive(true)
        c.setByEarSessionActive(false)
        XCTAssertFalse(c.debugFlashSavePending)
    }

    func testASlotSaveWhileMutedWritesTheRealShapeSavesThenMutesAgain() async {
        let c = await connected()
        c.setBandMuted(2, true)
        c.clearSendTrace()
        c.savePreset(3)
        let trace = c.sendTrace.filter { $0.hasPrefix("coalesced:setEqBandParam") || $0 == "saveEqPreset" }
        XCTAssertEqual(trace, ["coalesced:setEqBandParam", "saveEqPreset", "coalesced:setEqBandParam"])
        XCTAssertEqual(c.bands[2].filter, .bypass)
        XCTAssertNotNil(c.mutedBands[2])
        XCTAssertFalse(c.debugFlashSavePending)
    }

    func testASlotSaveWhileFollowingAndMutedKeepsTheMuteAndMutesAgainAfterTheSave() async {
        let c = await connected()
        let base = c.bands
        c.baseProvider = { (base, c.preGain) }
        c.setBandMuted(2, true)
        c.clearSendTrace()
        c.savePreset(3)
        let trace = c.sendTrace.filter { $0.hasPrefix("coalesced:setEqBandParam") || $0 == "saveEqPreset" }
        XCTAssertEqual(trace.last, "coalesced:setEqBandParam")
        XCTAssertTrue(trace.contains("saveEqPreset"))
        XCTAssertEqual(trace.firstIndex(of: "saveEqPreset"), trace.count - 2)
        XCTAssertEqual(c.bands[2].filter, .bypass)
        XCTAssertNotNil(c.mutedBands[2])
    }

    func testTheQuitFlushWhileFollowingAndMutedKeepsTheMute() async {
        let c = await connected()
        let base = c.bands
        c.baseProvider = { (base, c.preGain) }
        edit(c)
        c.setBandMuted(2, true)
        c.clearSendTrace()
        c.flushSaveForQuit()
        let trace = c.sendTrace.filter { $0.hasPrefix("coalesced:setEqBandParam") || $0 == "saveAll" }
        XCTAssertEqual(trace.last, "coalesced:setEqBandParam")
        XCTAssertEqual(trace.firstIndex(of: "saveAll"), trace.count - 2)
        XCTAssertEqual(c.bands[2].filter, .bypass)
        XCTAssertNotNil(c.mutedBands[2])
    }

    func testASlotSaveWhileMutedKeepsAParkedSaveParked() async {
        let c = await connected()
        edit(c)
        c.setBandMuted(2, true)
        c.savePreset(3)
        XCTAssertFalse(c.debugFlashSavePending)
        c.setBandMuted(2, false)
        XCTAssertTrue(c.debugFlashSavePending)
    }

    func testTheQuitFlushWritesRealShapesSavesAllThenMutesAgain() async {
        let c = await connected()
        edit(c)
        c.setBandMuted(2, true)
        c.clearSendTrace()
        c.flushSaveForQuit()
        let trace = c.sendTrace.filter { $0.hasPrefix("coalesced:setEqBandParam") || $0 == "saveAll" }
        XCTAssertEqual(trace, ["coalesced:setEqBandParam", "saveAll", "coalesced:setEqBandParam"])
        XCTAssertEqual(c.bands[2].filter, .bypass)
        XCTAssertNotNil(c.mutedBands[2])
        XCTAssertFalse(c.debugFlashSavePending)
    }

    func testTheQuitFlushSavesAnArmedSaveWithoutMutes() async {
        let c = await connected()
        edit(c)
        c.clearSendTrace()
        c.flushSaveForQuit()
        XCTAssertEqual(c.sendTrace.filter { $0 == "saveAll" }.count, 1)
        XCTAssertFalse(c.debugFlashSavePending)
        c.clearSendTrace()
        c.flushSaveForQuit()
        XCTAssertTrue(c.sendTrace.isEmpty)
    }

    func testTheQuitFlushSendsNothingWhenNoSaveIsPending() async {
        let c = await connected()
        c.setBandMuted(2, true)
        c.clearSendTrace()
        c.flushSaveForQuit()
        XCTAssertTrue(c.sendTrace.isEmpty)
    }

    func testReconnectRestoreDoesNotArmTheSave() async {
        let curve = DeviceRig.curve(first: 3)
        var other = curve
        other[1].gain = 5
        let seed = DeviceRig.snapshot("Qudelix-5K USB DAC 96KHz", bands: other, slot: 255)
        let rig = DeviceRig(seed: seed)
        await rig.connect(bands: curve, slot: 255)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(rig.controller.debugFlashSavePending)
    }
}
