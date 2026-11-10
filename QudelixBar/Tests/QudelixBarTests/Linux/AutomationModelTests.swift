import XCTest
@testable import QudelixBar

final class FlashLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(cmd: QxCmd, bands: [QxEqBandValue], preGain: Double)] = []

    func add(_ cmd: QxCmd, _ bands: [QxEqBandValue], _ preGain: Double) {
        lock.lock()
        items.append((cmd, bands, preGain))
        lock.unlock()
    }

    var all: [(cmd: QxCmd, bands: [QxEqBandValue], preGain: Double)] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

@MainActor
final class AutoRig {
    let device: EqTestDevice
    let clock = ManualClock()
    let directory: URL
    let app: AppModel
    let automation: AutomationModel
    let stageRig: StageRig?
    private let flashLog = FlashLog()

    var flashSnapshots: [(cmd: QxCmd, bands: [QxEqBandValue], preGain: Double)] { flashLog.all }
    let base: [QxEqBandValue]

    var url: URL { directory.appendingPathComponent("autofit.json") }

    init(bands: [QxEqBandValue] = FollowFixtures.tenBandBase(), preGain: Double = -3,
         withStage: Bool = false, stageDefault: String = "qx_5k",
         connect: Bool = true) async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("auto-rig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActiveSlotFile.directoryOverride = directory
        EqHistoryFile.directoryOverride = directory
        device = EqTestDevice(bands: bands, preGain: preGain)
        base = bands
        let lockURL = directory.appendingPathComponent("qudelix.lock")
        let present = connect
        let link = device.link
        app = AppModel(makeLinks: { [link] },
                       acquireLock: { QxInstanceLock.acquire(at: lockURL) },
                       probeDevice: { AppDeviceProbe(present: present) },
                       clock: clock, retryInterval: 2, connectTimeout: 2)
        stageRig = withStage ? try StageRig(defaultSink: stageDefault, detect: false) : nil
        automation = AutomationModel(app: app, stage: stageRig?.model, url: directory.appendingPathComponent("autofit.json"))
        let original = device.link.onSend
        let log = flashLog
        let live = device
        device.link.onSend = { cmd, data in
            original?(cmd, data)
            guard cmd == .saveAll || cmd == .saveEqPreset else { return }
            log.add(cmd, live.bands, live.preGain)
        }
        app.start()
        if connect {
            await until("connected") { self.app.state.connection.isConnected && self.app.eq.state.ready }
            await settle()
            device.link.clearSends()
        }
    }

    func close() async {
        await app.shutdown()
        stageRig?.cleanUp()
        ActiveSlotFile.directoryOverride = nil
        EqHistoryFile.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func until(_ what: String = "condition", timeout: TimeInterval = 4,
               _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func settle() async {
        await app.eq.waitForIdle()
        await app.waitForIdle()
    }

    func tick(_ count: Int = 1, _ context: EqAutomation.Context = .init()) async {
        for _ in 0..<count {
            automation.tick(context)
            await settle()
        }
    }

    static func reference() -> ReferenceCurve {
        var file = ParametricEQFile()
        file.preamp = -3
        file.bands = FollowFixtures.tenBandReference()
        return ReferenceCurve(file: file, source: "test", headphone: "Test Phone")
    }

    func engage() async {
        automation.engine.recordReference(Self.reference(), for: .user)
        automation.setAutoFit(true)
        await tick()
    }

    func gainsMoved() -> Bool {
        !Self.matches(device.bands, base)
    }

    static func matches(_ a: [QxEqBandValue], _ b: [QxEqBandValue]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.filter == $1.filter && $0.freq == $1.freq && abs($0.gain - $1.gain) < 0.051
        }
    }

    var bandWriteCount: Int { device.link.payloads(for: .setEqBandParam).count }
}

@MainActor
final class AutomationModelTests: XCTestCase {
    private func sameGains(_ a: [QxEqBandValue], _ b: [QxEqBandValue]) -> Bool {
        AutoRig.matches(a, b)
    }

    func testFollowingMovesTheDeviceGainsAndPublishesTheState() async throws {
        let rig = try await AutoRig()
        await rig.engage()
        XCTAssertTrue(rig.gainsMoved())
        let state = rig.automation.state
        XCTAssertTrue(state.following)
        XCTAssertTrue(state.referenceActive)
        XCTAssertTrue(state.hasReference)
        XCTAssertNil(state.waitingReason)
        XCTAssertNotNil(state.deviationDb)
        XCTAssertNotNil(state.referenceLine)
        XCTAssertEqual(state.followNote?.hasPrefix("Auto-fit is following the line"), true)
        XCTAssertTrue(state.canKeep)
        await rig.close()
    }

    func testFollowerWritesAreNotPersistentUndoStepsOrHistory() async throws {
        let rig = try await AutoRig()
        await rig.engage()
        await rig.tick(4)
        XCTAssertTrue(rig.gainsMoved())
        rig.clock.advance(60)
        await rig.settle()
        XCTAssertFalse(rig.app.hasPendingSave)
        XCTAssertFalse(rig.device.link.sentCommands.contains(.saveAll))
        XCTAssertFalse(rig.app.eq.state.canUndo)
        XCTAssertNil(rig.app.eq.state.undoLabel)
        XCTAssertTrue(EqHistoryFile.load().entries.isEmpty)
        await rig.close()
    }

    func testTheEditorIsReadOnlyWhileFollowing() async throws {
        let rig = try await AutoRig()
        await rig.engage()
        let state = rig.app.eq.state
        XCTAssertFalse(state.canEdit)
        XCTAssertEqual(state.readOnlyReason, EqEditorModel.followRefusal)
        let before = rig.device.bands
        let beforeGain = rig.device.preGain
        rig.app.eq.setBand(0, EqBand(filter: .peak, freq: 31, gain: 9, q: 1))
        rig.app.eq.setPreGain(-9)
        rig.app.eq.flatten()
        rig.app.eq.resetLayout()
        rig.app.eq.undo()
        rig.app.eq.zeroBand(3)
        await rig.settle()
        XCTAssertEqual(rig.device.bands, before)
        XCTAssertEqual(rig.device.preGain, beforeGain)
        XCTAssertFalse(rig.app.hasPendingSave)
        rig.automation.setAutoFit(false)
        await rig.settle()
        XCTAssertTrue(rig.app.eq.state.canEdit)
        XCTAssertNil(rig.app.eq.state.readOnlyReason)
        await rig.close()
    }

    func testTurningAutomationOffPutsTheBaseBack() async throws {
        let rig = try await AutoRig()
        await rig.engage()
        XCTAssertTrue(rig.gainsMoved())
        rig.automation.setAutoFit(false)
        await rig.settle()
        XCTAssertTrue(sameGains(rig.device.bands, rig.base))
        XCTAssertEqual(rig.device.preGain, -3, accuracy: 0.05)
        XCTAssertFalse(rig.automation.state.following)
        await rig.close()
    }

    func testADebouncedSaveWritesTheBaseFirstThenTheFollowerRewrites() async throws {
        let rig = try await AutoRig()
        await rig.engage()
        rig.app.armSave()
        rig.clock.advance(5.1)
        await rig.until("saveAll") { rig.device.link.sentCommands.contains(.saveAll) }
        await rig.settle()
        let snapshot = try XCTUnwrap(rig.flashSnapshots.first { $0.cmd == .saveAll })
        XCTAssertTrue(sameGains(snapshot.bands, rig.base))
        XCTAssertEqual(snapshot.preGain, -3, accuracy: 0.05)
        await rig.tick(2)
        XCTAssertTrue(rig.gainsMoved())
        XCTAssertTrue(rig.automation.state.following)
        await rig.close()
    }

    func testASlotSaveWhileFollowingStoresTheBase() async throws {
        let rig = try await AutoRig()
        await rig.engage()
        rig.app.presets.save(slot: 4)
        await rig.settle()
        await rig.until("slot saved") { rig.device.slots[4] != nil }
        let stored = try XCTUnwrap(rig.device.slots[4])
        XCTAssertTrue(sameGains(stored.bands, rig.base))
        XCTAssertEqual(stored.preGain, -3, accuracy: 0.05)
        await rig.tick(3)
        XCTAssertTrue(rig.gainsMoved())
        await rig.close()
    }

    func testQuitWithAPendingSaveWritesTheBaseBeforeTheFinalSave() async throws {
        let rig = try await AutoRig()
        await rig.engage()
        rig.app.armSave()
        await rig.app.shutdown()
        let snapshot = try XCTUnwrap(rig.flashSnapshots.first { $0.cmd == .saveAll })
        XCTAssertTrue(sameGains(snapshot.bands, rig.base))
        XCTAssertEqual(snapshot.preGain, -3, accuracy: 0.05)
        XCTAssertTrue(sameGains(rig.device.bands, rig.base))
        await rig.close()
    }

    func testQuitWithoutASaveStillLeavesTheLiveEqOnTheBase() async throws {
        let rig = try await AutoRig()
        await rig.engage()
        XCTAssertTrue(rig.gainsMoved())
        await rig.app.shutdown()
        XCTAssertTrue(sameGains(rig.device.bands, rig.base))
        XCTAssertFalse(rig.device.link.sentCommands.contains(.saveAll))
        await rig.close()
    }

    func testNoWritesOnACall() async throws {
        let rig = try await AutoRig()
        rig.automation.engine.recordReference(AutoRig.reference(), for: .user)
        rig.automation.setAutoFit(true)
        var context = EqAutomation.Context()
        context.onCall = true
        await rig.tick(3, context)
        XCTAssertEqual(rig.bandWriteCount, 0)
        XCTAssertEqual(rig.automation.state.waitingReason, "Paused for the call")
        XCTAssertFalse(rig.automation.state.following)
        await rig.tick()
        XCTAssertGreaterThan(rig.bandWriteCount, 0)
        await rig.close()
    }

    func testNoWritesDuringATuneSessionAndTheBaseIsRestoredFirst() async throws {
        let rig = try await AutoRig()
        await rig.engage()
        XCTAssertTrue(rig.gainsMoved())
        rig.app.eqHost.beginEqSession()
        await rig.settle()
        XCTAssertTrue(sameGains(rig.device.bands, rig.base))
        XCTAssertTrue(rig.automation.state.suspended)
        rig.device.link.clearSends()
        await rig.tick(3)
        XCTAssertEqual(rig.bandWriteCount, 0)
        XCTAssertEqual(rig.automation.state.waitingReason, "Paused while a tuning session runs")
        rig.app.eqHost.endEqSession()
        await rig.tick(2)
        XCTAssertTrue(rig.gainsMoved())
        XCTAssertTrue(rig.automation.state.following)
        await rig.close()
    }

    func testNoWritesWhileAPresetIsBeingRead() async throws {
        let rig = try await AutoRig()
        await rig.engage()
        rig.device.slots[1] = (-2, FollowFixtures.tenBandBase().map {
            var band = $0
            band.gain = 1.5
            return band
        })
        rig.app.presets.load(slot: 1)
        rig.device.link.clearSends()
        rig.automation.tick(.init())
        XCTAssertEqual(rig.bandWriteCount, 0)
        XCTAssertNotNil(rig.automation.state.waitingReason)
        await rig.settle()
        await rig.tick(2)
        XCTAssertEqual(rig.automation.engine.baseBands.map(\.gain), Array(repeating: 1.5, count: 10))
        await rig.close()
    }

    func testNoWritesDuringAnEqModeChangeAndTheBaseIsWrittenFirst() async throws {
        let rig = try await AutoRig()
        await rig.engage()
        let session = try XCTUnwrap(rig.app.session)
        let ready = await rig.app.eq.prepareModeChange(session)
        XCTAssertTrue(ready)
        XCTAssertTrue(sameGains(rig.device.bands, rig.base))
        rig.device.link.clearSends()
        await rig.tick(2)
        XCTAssertEqual(rig.bandWriteCount, 0)
        XCTAssertEqual(rig.automation.state.waitingReason, "Waiting for the 5K's EQ mode")
        rig.app.eq.finishModeChange()
        await rig.tick(2)
        XCTAssertTrue(rig.gainsMoved())
        await rig.close()
    }

    func testNoWritesWhenTheEqIsOffOrNotConnected() async throws {
        let rig = try await AutoRig()
        rig.automation.engine.recordReference(AutoRig.reference(), for: .user)
        rig.automation.setAutoFit(true)
        rig.app.setEqEnabled(false)
        await rig.settle()
        await rig.tick(2)
        XCTAssertEqual(rig.bandWriteCount, 0)
        XCTAssertEqual(rig.automation.state.waitingReason, "Turn the EQ on to use it")
        await rig.close()
        let lonely = try await AutoRig(connect: false)
        lonely.automation.engine.recordReference(AutoRig.reference(), for: .user)
        lonely.automation.setAutoFit(true)
        await lonely.tick(2)
        XCTAssertEqual(lonely.automation.state.waitingReason, "Connect the 5K")
        XCTAssertEqual(lonely.bandWriteCount, 0)
        await lonely.close()
    }

    func testKeepBakesTheFollowedGainsAndTurnsAutoTrimOff() async throws {
        let rig = try await AutoRig()
        rig.automation.setAutoTrim(on: true)
        rig.automation.engine.recordReference(AutoRig.reference(), for: .user)
        rig.automation.setAutoFit(true)
        await rig.tick(2)
        let followed = rig.device.bands
        XCTAssertFalse(AutoRig.matches(followed, rig.base))
        rig.automation.keep()
        await rig.settle()
        XCTAssertTrue(sameGains(rig.device.bands, followed))
        XCTAssertFalse(rig.automation.state.autoFit)
        XCTAssertFalse(rig.automation.state.autoTrimOn)
        XCTAssertFalse(rig.automation.state.following)
        XCTAssertEqual(rig.app.eq.state.undoLabel, "Keep auto-fit")
        XCTAssertTrue(rig.app.hasPendingSave)
        rig.clock.advance(5.1)
        await rig.until("saveAll") { rig.device.link.sentCommands.contains(.saveAll) }
        let snapshot = try XCTUnwrap(rig.flashSnapshots.first { $0.cmd == .saveAll })
        XCTAssertTrue(sameGains(snapshot.bands, followed))
        rig.app.eq.undo()
        await rig.settle()
        XCTAssertTrue(sameGains(rig.device.bands, rig.base))
        await rig.close()
    }

    func testAReadbackThatMatchesTheLastWriteIsAnEchoNotABaseChange() async throws {
        let rig = try await AutoRig()
        await rig.engage()
        let baseBefore = rig.automation.engine.baseBands
        rig.app.eq.reloadFromDevice()
        await rig.settle()
        await rig.tick()
        XCTAssertEqual(rig.automation.engine.baseBands, baseBefore)
        XCTAssertTrue(rig.automation.state.following)
        await rig.close()
    }

    func testAReadbackFarFromTheLastWriteRebasesToWhatTheDeviceHolds() async throws {
        let rig = try await AutoRig()
        await rig.engage()
        var external = rig.device.bands
        external[4].gain += 4
        rig.device.bands = external
        rig.app.eq.reloadFromDevice()
        await rig.settle()
        XCTAssertEqual(rig.automation.engine.baseBands[4].gain, external[4].gain, accuracy: 0.11)
        XCTAssertTrue(rig.automation.state.following || rig.automation.state.waitingReason == nil)
        await rig.close()
    }

    func testSettingsPersistInTheAutofitFile() async throws {
        let rig = try await AutoRig()
        rig.automation.setAutoFit(true)
        rig.automation.setAutoTrim(on: true, mode: .resolution, strength: 0.8)
        rig.automation.setShowReference(false)
        rig.automation.setReferenceSource(.listening)
        rig.automation.persist()
        let saved = try XCTUnwrap(AutofitFile.load(from: rig.url))
        XCTAssertEqual(saved.autoFit, true)
        XCTAssertEqual(saved.autoTrimOn, true)
        XCTAssertEqual(saved.autoTrimMode, .resolution)
        XCTAssertEqual(saved.autoTrimStrength, 0.8)
        XCTAssertEqual(saved.showReference, false)
        XCTAssertEqual(saved.referenceSource, .listening)
        let again = AutomationModel(app: rig.app, stage: nil, url: rig.url)
        XCTAssertEqual(again.state.trimMode, .resolution)
        XCTAssertTrue(again.state.autoFit)
        XCTAssertFalse(again.state.showReference)
        XCTAssertEqual(AutofitFile.url.deletingLastPathComponent().path,
                       StageStateFile.directory.path)
        await rig.close()
    }

    func testAutoTrimTurnsDetectionOn() async throws {
        let rig = try await AutoRig(withStage: true)
        let stage = try XCTUnwrap(rig.stageRig).model
        XCTAssertFalse(stage.level.state.detectQuality)
        rig.automation.setAutoTrim(on: true)
        XCTAssertTrue(stage.level.state.detectQuality)
        await rig.close()
    }

    func testTheLevelFeedTicksTheAutomationEverySecond() async throws {
        let rig = try await AutoRig(withStage: true)
        let stageRig = try XCTUnwrap(rig.stageRig)
        rig.automation.engine.recordReference(AutoRig.reference(), for: .user)
        rig.automation.setAutoFit(true)
        XCTAssertFalse(rig.automation.state.following)
        stageRig.tick(2)
        await rig.settle()
        XCTAssertTrue(rig.automation.state.following)
        XCTAssertTrue(rig.gainsMoved())
        stageRig.tick(1)
        XCTAssertNotNil(rig.automation.diagnostics())
        await rig.close()
    }

    func testAnObserverHearsStateChanges() async throws {
        let rig = try await AutoRig()
        var seen: [AutomationState] = []
        let id = rig.automation.addObserver { seen.append($0) }
        rig.automation.setAutoTrim(on: true)
        XCTAssertTrue(seen.last?.autoTrimOn ?? false)
        rig.automation.removeObserver(id)
        let count = seen.count
        rig.automation.setAutoTrim(on: false)
        XCTAssertEqual(seen.count, count)
        await rig.close()
    }

    func testTheFitHandoffIsAModelAction() async throws {
        let rig = try await AutoRig()
        rig.automation.requestFit(headphone: "Test Phone")
        XCTAssertEqual(rig.automation.state.fitRequest, "Test Phone")
        rig.automation.landReference(AutoRig.reference())
        XCTAssertTrue(rig.automation.state.hasReference)
        rig.automation.clearFitRequest()
        XCTAssertNil(rig.automation.state.fitRequest)
        await rig.close()
    }

    func testTheDisconnectEndsFollowingState() async throws {
        let rig = try await AutoRig()
        await rig.engage()
        rig.device.link.drop()
        await rig.until("disconnected") { !rig.app.state.connection.isConnected }
        XCTAssertFalse(rig.automation.state.following)
        XCTAssertFalse(rig.app.eq.state.canEdit)
        await rig.close()
    }
}
