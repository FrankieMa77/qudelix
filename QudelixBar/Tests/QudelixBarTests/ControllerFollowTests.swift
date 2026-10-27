import XCTest
@testable import QudelixBar

extension QudelixController {
    func writeCount(_ name: String = "coalesced:setEqBandParam") -> Int {
        sendTrace.filter { $0 == name }.count
    }
}

@MainActor
final class ControllerFollowTests: XCTestCase {
    private let flat = DeviceRig.curve()

    override func tearDown() async throws {
        DeviceRig.cleanUp()
    }

    private func followed(_ gains: [Int: Double], over bands: [QxEqBandValue]) -> [QxEqBandValue] {
        var out = bands
        for (i, g) in gains { out[i].gain = g }
        return out
    }

    private func connected(bands: [QxEqBandValue]? = nil) async -> (DeviceRig, QudelixController) {
        let rig = DeviceRig()
        await rig.connect(bands: bands ?? flat)
        rig.controller.clearSendTrace()
        return (rig, rig.controller)
    }

    func testOnlyBandsWhoseQuantizedGainChangedAreSent() async {
        let (_, c) = await connected()
        let target = followed([2: 3.04, 5: -1.0], over: flat)

        XCTAssertEqual(c.writeFollowed(bands: target, preGain: 0), 2)
        XCTAssertEqual(c.writeCount(), 2)

        c.clearSendTrace()
        XCTAssertEqual(c.writeFollowed(bands: target, preGain: 0), 0)
        XCTAssertEqual(c.writeCount(), 0)

        var nudged = target
        nudged[2].gain = 3.02
        XCTAssertEqual(c.writeFollowed(bands: nudged, preGain: 0), 0, "below the device's 0.1 dB resolution")

        nudged[2].gain = 3.1
        XCTAssertEqual(c.writeFollowed(bands: nudged, preGain: 0), 1)
        XCTAssertEqual(c.bands[2].gain, 3.1)
    }

    func testPreGainIsWrittenOnlyWhenItsQuantizedValueChanged() async {
        let (_, c) = await connected()
        c.writeFollowed(bands: flat, preGain: -2.04)
        XCTAssertEqual(c.preGain, -2.0)
        let sent = c.sendTrace.count
        c.writeFollowed(bands: flat, preGain: -2.02)
        XCTAssertEqual(c.sendTrace.count, sent)
    }

    func testLoweringPreGainGoesOutBeforeTheBandsAndRaisingGoesAfter() async {
        let (_, c) = await connected()
        c.writeFollowed(bands: flat, preGain: -3)
        c.clearSendTrace()
        c.writeFollowed(bands: followed([1: 4], over: flat), preGain: -6)
        let lowered = c.sendTrace
        XCTAssertEqual(lowered.first, "coalesced:setEqPreGain")
        XCTAssertEqual(lowered.last, "coalesced:setEqBandParam")

        c.clearSendTrace()
        c.writeFollowed(bands: followed([1: 5], over: flat), preGain: -1)
        let raised = c.sendTrace
        XCTAssertEqual(raised.first, "coalesced:setEqBandParam")
        XCTAssertEqual(raised.last, "coalesced:setEqPreGain")
    }

    func testFollowerWritesNeverArmTheFlashSaveNorAddUndoSteps() async {
        let (_, c) = await connected()
        c.writeFollowed(bands: followed([0: 5, 3: -2], over: flat), preGain: -4)
        XCTAssertFalse(c.debugFlashSavePending)
        XCTAssertFalse(c.canUndo)
        XCTAssertFalse(c.sendTrace.contains("saveAll"))
    }

    func testNothingIsSentWhenTheEqCannotBeWritten() async {
        let (rig, c) = await connected()
        await rig.detachUSB()
        c.clearSendTrace()
        XCTAssertEqual(c.writeFollowed(bands: followed([0: 5], over: c.bands), preGain: -1), 0)
        XCTAssertTrue(c.sendTrace.isEmpty)
    }

    func testAFlashSaveWhileFollowingPutsTheBaseBackBeforeSaving() async {
        let (_, c) = await connected()
        let base = flat
        var committed = 0
        c.baseProvider = { (base, 0) }
        c.onFlashCommitted = { committed += 1 }
        c.writeFollowed(bands: followed([0: 4, 4: -3, 7: 2], over: flat), preGain: -2)
        c.clearSendTrace()

        c.debugFireFlashSave()

        let trace = c.sendTrace
        let save = trace.firstIndex(of: "saveAll")
        let lastBand = trace.lastIndex(of: "coalesced:setEqBandParam")
        XCTAssertNotNil(save)
        XCTAssertNotNil(lastBand)
        XCTAssertLessThan(lastBand ?? 99, save ?? -1)
        XCTAssertTrue(trace[(lastBand ?? 0)..<(save ?? 0)].contains("flush"),
                      "queued base writes are flushed before the save leaves")
        XCTAssertEqual(c.bands, base)
        XCTAssertEqual(c.preGain, 0)
        XCTAssertEqual(committed, 1)
    }

    func testAFlashSaveWithNothingFollowedSendsNoExtraWrites() async {
        let (_, c) = await connected()
        c.debugFireFlashSave()
        XCTAssertEqual(c.writeCount(), 0)
        XCTAssertTrue(c.sendTrace.contains("saveAll"))
    }

    func testSavingToASlotWhileFollowingWritesTheBaseFirst() async {
        let (_, c) = await connected()
        c.baseProvider = { (self.flat, 0) }
        c.writeFollowed(bands: followed([1: 6], over: flat), preGain: -1)
        c.clearSendTrace()

        c.savePreset(2)

        let trace = c.sendTrace
        let save = trace.firstIndex(of: "saveEqPreset")
        XCTAssertNotNil(save)
        XCTAssertLessThan(trace.lastIndex(of: "coalesced:setEqBandParam") ?? 99, save ?? -1)
        XCTAssertEqual(c.bands, flat)
    }

    func testTheSnapshotHoldsTheBaseWhileFollowing() async {
        let (rig, c) = await connected()
        c.baseProvider = { (self.flat, 0) }
        c.writeFollowed(bands: followed([0: 6, 2: -4], over: flat), preGain: -3)
        c.flushEqSnapshot()
        XCTAssertEqual(rig.savedSnapshots[0]?.bands, flat)
        XCTAssertEqual(rig.savedSnapshots[0]?.preGain, 0)
        XCTAssertNotEqual(c.bands, flat)
    }

    func testUndoNeverLandsFollowedGains() async {
        let (_, c) = await connected()
        c.baseProvider = { (self.flat, 0) }
        c.writeFollowed(bands: followed([0: 6, 2: -4], over: flat), preGain: -3)
        c.setPreGain(-5)
        XCTAssertTrue(c.canUndo)
        c.undoEqEdit()
        XCTAssertEqual(c.bands, flat)
        XCTAssertEqual(c.preGain, 0)
        XCTAssertEqual(c.userBands, c.bands.map { $0 })
    }

    func testUserBandsFallBackToTheLiveBandsWhenNothingIsFollowed() async {
        let (_, c) = await connected()
        XCTAssertEqual(c.userBands, c.bands)
        c.baseProvider = { (self.flat, 1) }
        c.writeFollowed(bands: followed([0: 3], over: flat), preGain: -1)
        XCTAssertEqual(c.userBands, flat)
        XCTAssertEqual(c.userPreGain, 1)
        XCTAssertEqual(c.bands[0].gain, 3)
    }

    func testBaseEventsAreSignalled() async {
        let (rig, c) = await connected()
        var events: [QudelixController.EqBaseEvent] = []
        c.onBaseEvent = { events.append($0) }

        c.loadPreset(1)
        XCTAssertEqual(events.last, .slotLoad)

        var file = ParametricEQFile()
        file.preamp = -1
        file.bands = [QxEqBandValue(filter: .peak, freq: 1000, gain: 2, q: 1)]
        c.apply(file, named: "fit")
        XCTAssertEqual(events.last, .fit)

        c.undoEqEdit()
        XCTAssertEqual(events.last, .undoRedo)

        c.debugIngest(Wire.deviceConfig(eqMode: 1, group: 2, slot: 255))
        XCTAssertEqual(events.last, .group)

        await rig.detachUSB()
        XCTAssertEqual(events.last, .reset)
    }

    func testTheReadbackCallbackReceivesWhatTheDeviceReported() async {
        let (rig, c) = await connected()
        var seen: ([QxEqBandValue], Double)?
        c.onReadback = { seen = ($0, $1) }
        let reported = DeviceRig.curve(gain: 2)
        rig.ingest(Wire.presetPackets(group: .user, bands: reported, preGain: -3))
        XCTAssertEqual(seen?.0, reported)
        XCTAssertEqual(seen?.1, -3)
    }

    func testARestoreIsSignalled() async {
        let rig = DeviceRig(seed: DeviceRig.snapshot("usb:Qudelix-5K USB DAC 96KHz",
                                                     bands: DeviceRig.curve(first: 3)))
        var events: [QudelixController.EqBaseEvent] = []
        rig.controller.onBaseEvent = { events.append($0) }
        await rig.connect("Qudelix-5K USB DAC 96KHz", bands: DeviceRig.curve(first: -4))
        XCTAssertTrue(events.contains(.restore))
    }
}
