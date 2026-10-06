import XCTest
@testable import QudelixBar

@MainActor
final class ControllerUnchangedWriteTests: XCTestCase {
    override func tearDown() async throws {
        DeviceRig.cleanUp()
    }

    private func connected(preGain: Double = -2, slot: Int = 255) async -> DeviceRig {
        let rig = DeviceRig()
        await rig.connect(bands: DeviceRig.curve(first: 3), preGain: preGain, slot: slot)
        try? await Task.sleep(for: .milliseconds(400))
        rig.controller.clearSendTrace()
        return rig
    }

    func testRewritingABandWithItsOwnValueSendsNothingAndLeavesNoStep() async {
        let rig = await connected()
        let c = rig.controller

        c.updateBand(0, c.bands[0])

        XCTAssertTrue(c.sendTrace.isEmpty, "\(c.sendTrace)")
        XCTAssertFalse(c.canUndo, "a focus change is not an edit")
        XCTAssertFalse(c.debugFlashSavePending)
    }

    func testAValueThatClampsToTheCurrentOneIsNotAnEditEither() async {
        let rig = await connected()
        let c = rig.controller
        var low = c.bands[0]
        low.freq = 5
        c.updateBand(0, low)
        XCTAssertEqual(c.bands[0].freq, 20)
        c.clearSendTrace()
        c.updateBand(0, low)

        XCTAssertTrue(c.sendTrace.isEmpty, "5 Hz clamps to the 20 Hz it already is")
    }

    func testRewritingThePreGainWithItsOwnValueSendsNothingAndLeavesNoStep() async {
        let rig = await connected(preGain: -2)
        let c = rig.controller

        c.setPreGain(c.preGain)
        c.setPreGain(-2.0)

        XCTAssertTrue(c.sendTrace.isEmpty, "\(c.sendTrace)")
        XCTAssertFalse(c.canUndo)
        XCTAssertFalse(c.debugFlashSavePending)
    }

    func testAPreGainBeyondTheLimitThatMatchesTheLimitIsNotAnEdit() async {
        let rig = await connected(preGain: 12)
        let c = rig.controller
        XCTAssertEqual(c.preGain, 12, accuracy: 0.05)

        c.setPreGain(20)
        XCTAssertTrue(c.sendTrace.isEmpty)
        XCTAssertFalse(c.canUndo)
    }

    func testARealBandEditStillSendsStepsAndSchedulesTheSave() async {
        let rig = await connected()
        let c = rig.controller
        var band = c.bands[0]
        band.gain = 5

        c.updateBand(0, band)

        XCTAssertEqual(c.sendTrace.filter { $0 == "coalesced:setEqBandParam" }.count, 1)
        XCTAssertEqual(c.undoStack.count, 1)
        XCTAssertEqual(c.undoLabel, "band 1")
        XCTAssertTrue(c.debugFlashSavePending)
    }

    func testARealPreGainEditStillSendsBothChannelsAndSteps() async {
        let rig = await connected(preGain: -2)
        let c = rig.controller

        c.setPreGain(-4)

        XCTAssertEqual(c.sendTrace.filter { $0 == "coalesced:setEqPreGain" }.count, 2)
        XCTAssertEqual(c.undoLabel, "pre-gain")
        XCTAssertTrue(c.debugFlashSavePending)
    }

    func testANoOpDoesNotCostTheNextRealEditItsStep() async {
        let rig = await connected()
        let c = rig.controller
        c.updateBand(0, c.bands[0])
        var band = c.bands[0]
        band.gain = 5
        c.updateBand(0, band)

        XCTAssertEqual(c.undoStack.count, 1)
        c.undoEqEdit()
        XCTAssertEqual(c.bands[0].gain, 3)
        XCTAssertFalse(c.canUndo)
    }

    func testAnImportIntoAnIdenticalCurveWritesNoBandsButStillRecordsTheSource() async {
        let rig = await connected(preGain: 0)
        let c = rig.controller
        var file = ParametricEQFile()
        file.bands = c.bands
        file.preamp = 0
        c.clearSendTrace()

        XCTAssertTrue(c.apply(file, named: "Same"))
        XCTAssertEqual(c.sendTrace.filter { $0 == "coalesced:setEqBandParam" }.count, 0)
        XCTAssertEqual(c.currentSourceName, "Same")
    }

    func testRestoringOverAnUnreadableDeviceStillRewritesEveryBand() async {
        var unreadable = DeviceRig.curve()
        unreadable[4].freq = 30000
        let rig = DeviceRig(seed: DeviceRig.snapshot("usb:Qudelix-5K", bands: DeviceRig.curve(first: 3)))
        let c = rig.controller
        await rig.attachUSB()
        c.debugIngest(Wire.initData())
        c.debugIngest(Wire.deviceConfig(eqMode: 0, group: 0, slot: 255))
        try? await Task.sleep(for: .milliseconds(400))
        c.clearSendTrace()
        rig.ingest(Wire.presetPackets(group: .user, bands: unreadable, preGain: 0))

        XCTAssertEqual(c.lastImportSummary, "Restored your last EQ")
        XCTAssertEqual(c.sendTrace.filter { $0 == "coalesced:setEqBandParam" }.count, 10,
                       "the placeholder says nothing about what is on the device")
        XCTAssertEqual(c.sendTrace.filter { $0 == "coalesced:setEqPreGain" }.count, 2)
    }
}
