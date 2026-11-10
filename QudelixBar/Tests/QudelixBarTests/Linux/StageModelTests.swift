import XCTest
@testable import QudelixBar

@MainActor
final class StageModelTests: XCTestCase {
    private var rigs: [StageRig] = []

    override func tearDown() async throws {
        for rig in rigs { rig.cleanUp() }
        rigs = []
        try await super.tearDown()
    }

    private func makeRig(directory: URL? = nil,
                         sinks: [AudioSink] = [StageRig.fiveK, StageRig.speakers],
                         defaultSink: String? = "qx_5k",
                         configured: String?? = nil,
                         detect: Bool = false,
                         start: Bool = true) throws -> StageRig {
        let rig = try StageRig(directory: directory, sinks: sinks, defaultSink: defaultSink,
                               configured: configured, detect: detect, start: start)
        rigs.append(rig)
        return rig
    }

    private func liveStreams(_ rig: StageRig) -> (monitors: Int, inserts: Int) {
        (rig.backend.monitors.filter { !$0.stream.stopped }.count,
         rig.backend.inserts.filter { !$0.stream.stopped }.count)
    }

    func testNothingWantedStartsNoStream() throws {
        let rig = try makeRig()
        rig.settle()
        XCTAssertEqual(rig.backend.monitors.count, 0)
        XCTAssertEqual(rig.backend.inserts.count, 0)
        XCTAssertFalse(rig.model.state.running)
        XCTAssertEqual(rig.model.state.status, "Off.")
        XCTAssertEqual(rig.model.state.outputKey, "qx_5k")
    }

    func testLevelTrackingMonitorsTheRealOutput() throws {
        let rig = try makeRig()
        rig.model.setLevelTracking(true)
        XCTAssertEqual(rig.backend.monitors.map(\.sink), ["qx_5k"])
        XCTAssertEqual(rig.model.state.mode, .monitor)
        XCTAssertTrue(rig.model.state.status.hasPrefix("Metering"))
        XCTAssertEqual(rig.backend.setDefaultCalls, [])
        rig.model.setLevelTracking(false)
        XCTAssertEqual(liveStreams(rig).monitors, 0)
        XCTAssertFalse(rig.model.state.running)
    }

    func testQualityDetectionAloneMonitors() throws {
        let rig = try makeRig(detect: true)
        XCTAssertEqual(rig.backend.monitors.map(\.sink), ["qx_5k"])
        rig.model.setDetectQuality(false)
        XCTAssertEqual(liveStreams(rig).monitors, 0)
    }

    func testEnablingStageInsertsInFrontOfTheRealOutput() throws {
        let rig = try makeRig()
        rig.enableStage()
        XCTAssertEqual(rig.backend.inserts.map(\.target), ["qx_5k"])
        XCTAssertEqual(rig.backend.monitors.count, 0)
        XCTAssertEqual(rig.backend.setDefaultCalls, [LinuxAudioNames.stageSinkName])
        XCTAssertEqual(rig.model.state.mode, .insert)
        XCTAssertTrue(rig.model.state.routed)
        XCTAssertTrue(rig.model.state.status.hasPrefix("Stage active"))
        XCTAssertEqual(rig.model.state.outputKey, "qx_5k")
        XCTAssertEqual(rig.routing.realOutput?.name, "qx_5k")
        XCTAssertTrue(rig.routing.isStageDefault)
    }

    func testInsertBeatsMonitorWhenBothAreWanted() throws {
        let rig = try makeRig()
        rig.model.setLevelTracking(true)
        XCTAssertEqual(liveStreams(rig).monitors, 1)
        rig.enableStage()
        XCTAssertEqual(liveStreams(rig).monitors, 0)
        XCTAssertEqual(liveStreams(rig).inserts, 1)
    }

    func testDisablingStageFallsBackToMonitorWhenLevelIsTracked() throws {
        let rig = try makeRig()
        rig.model.setLevelTracking(true)
        rig.enableStage()
        rig.model.setEnabled(false, editedFor: rig.key)
        rig.settle()
        XCTAssertEqual(liveStreams(rig).inserts, 0)
        XCTAssertEqual(liveStreams(rig).monitors, 1)
        XCTAssertEqual(rig.backend.configuredDefaultSinkName, "qx_5k")
        XCTAssertEqual(rig.model.state.mode, .monitor)
    }

    func testStoppingStageRestoresTheDefaultAndRemovesTheSink() throws {
        let rig = try makeRig()
        rig.enableStage()
        rig.model.setEnabled(false, editedFor: rig.key)
        rig.settle()
        XCTAssertEqual(rig.backend.setDefaultCalls, [LinuxAudioNames.stageSinkName, "qx_5k"])
        XCTAssertEqual(rig.backend.defaultSinkName, "qx_5k")
        XCTAssertFalse(rig.backend.sinks.contains { $0.isStageSink })
        XCTAssertEqual(liveStreams(rig).inserts, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.memoryURL.path))
    }

    func testAnUnconfiguredDefaultIsRestoredAsUnconfigured() throws {
        let rig = try makeRig(configured: .some(nil))
        rig.enableStage()
        rig.model.setEnabled(false, editedFor: rig.key)
        rig.settle()
        XCTAssertEqual(rig.backend.setDefaultCalls, [LinuxAudioNames.stageSinkName, nil])
        XCTAssertNil(rig.backend.configuredDefaultSinkName)
        XCTAssertEqual(rig.backend.defaultSinkName, "qx_5k")
    }

    func testTheRealOutputDisappearingStopsStageAndMovesItToTheNextOutput() throws {
        let rig = try makeRig()
        rig.enableStage()
        rig.backend.sinks.removeAll { $0.name == "qx_5k" }
        rig.backend.changeHandler?()
        rig.settle(1)
        XCTAssertTrue(rig.backend.inserts[0].stream.stopped)
        XCTAssertEqual(rig.backend.inserts.last?.target, "alsa_speakers")
        XCTAssertEqual(rig.model.state.outputKey, "alsa_speakers")
        XCTAssertTrue(rig.model.state.routed)
    }

    func testTheRealOutputDisappearingWithNowhereToGoRestoresTheDefault() throws {
        let rig = try makeRig(sinks: [StageRig.fiveK])
        rig.enableStage()
        rig.backend.sinks.removeAll { $0.name == "qx_5k" }
        rig.backend.changeHandler?()
        rig.settle(1)
        XCTAssertEqual(liveStreams(rig).inserts, 0)
        XCTAssertNotEqual(rig.backend.configuredDefaultSinkName, LinuxAudioNames.stageSinkName)
        XCTAssertFalse(rig.model.state.running)
        XCTAssertNil(rig.model.state.outputKey)
    }

    func testMonitorFollowsTheDefaultOutput() throws {
        let rig = try makeRig()
        rig.model.setLevelTracking(true)
        rig.changeDefault(to: "alsa_speakers")
        XCTAssertEqual(rig.backend.monitors.map(\.sink), ["qx_5k", "alsa_speakers"])
        XCTAssertTrue(rig.backend.monitors[0].stream.stopped)
        XCTAssertFalse(rig.backend.monitors[1].stream.stopped)
        XCTAssertEqual(rig.model.state.outputKey, "alsa_speakers")
    }

    func testAMonitoredOutputDisappearingStopsTheMonitor() throws {
        let rig = try makeRig()
        rig.model.setLevelTracking(true)
        rig.backend.sinks.removeAll { $0.name == "qx_5k" }
        rig.backend.defaultSinkName = "alsa_speakers"
        rig.backend.changeHandler?()
        rig.settle()
        XCTAssertTrue(rig.backend.monitors[0].stream.stopped)
        XCTAssertEqual(rig.backend.monitors.last?.sink, "alsa_speakers")
    }

    func testChoosingAnotherOutputWhileStagedEndsStageWithoutOverridingTheChoice() throws {
        let rig = try makeRig()
        rig.enableStage()
        let calls = rig.backend.setDefaultCalls.count
        rig.changeDefault(to: "alsa_speakers")
        XCTAssertEqual(liveStreams(rig).inserts, 0)
        XCTAssertEqual(rig.backend.configuredDefaultSinkName, "alsa_speakers")
        XCTAssertEqual(rig.backend.setDefaultCalls.count, calls)
        XCTAssertFalse(rig.model.state.settings.enabled)
    }

    func testStageSettingsBelongToEachOutput() throws {
        let rig = try makeRig()
        rig.enableStage(.theater)
        rig.changeDefault(to: "alsa_speakers")
        XCTAssertFalse(rig.model.state.settings.enabled)
        XCTAssertEqual(liveStreams(rig).inserts, 0)
        rig.changeDefault(to: "qx_5k")
        rig.settle(0.5)
        XCTAssertTrue(rig.model.state.settings.audiblyEquals(.theater))
        XCTAssertEqual(liveStreams(rig).inserts, 1)
    }

    func testAnEditMadeForAnotherOutputIsDropped() throws {
        let rig = try makeRig()
        var settings = StageSettings.music
        settings.enabled = true
        rig.model.setStage(settings, editedFor: "alsa_speakers")
        XCTAssertFalse(rig.model.state.settings.enabled)
        XCTAssertEqual(rig.backend.inserts.count, 0)
    }

    func testPresetsReplaceTheSettingsAndAreRecognised() throws {
        let rig = try makeRig()
        rig.model.applyPreset(.movie, editedFor: rig.key)
        XCTAssertTrue(rig.model.state.settings.audiblyEquals(.movie))
        XCTAssertFalse(rig.model.state.isCustomPreset)
        rig.model.mutate(editedFor: rig.key) { $0.width = 111 }
        XCTAssertTrue(rig.model.state.isCustomPreset)
        XCTAssertEqual(rig.model.state.settings.width, 111)
    }

    func testControlsAreClampedBeforeTheyReachTheProcessor() throws {
        let rig = try makeRig()
        rig.model.mutate(editedFor: rig.key) {
            $0.width = 900
            $0.room = -3
        }
        XCTAssertEqual(rig.model.state.settings.width, 200)
        XCTAssertEqual(rig.model.state.settings.room, 0)
    }

    func testTheRenderCallbackRunsTheStageProcessor() throws {
        let rig = try makeRig()
        rig.enableStage(.theater)
        let left = StageRig.sine(440, amplitude: 0.5, frames: 4096)
        let right = [Float](repeating: 0, count: 4096)
        _ = rig.feedInsert(left: left, right: right)
        let output = rig.feedInsert(left: left, right: right)
        var rightEnergy = 0.0
        var inputEnergy = 0.0
        for i in 0..<4096 {
            rightEnergy += Double(output[i * 2 + 1] * output[i * 2 + 1])
            inputEnergy += Double(left[i] * left[i])
        }
        XCTAssertGreaterThan(rightEnergy / inputEnergy, 0.001)
        XCTAssertNotEqual(Array(output.prefix(200)), (0..<100).flatMap { [left[$0], right[$0]] })
    }

    func testAPassThroughSettingLeavesTheSignalAlone() throws {
        let rig = try makeRig()
        var neutral = StageSettings()
        neutral.width = 100
        neutral.crossfeed = 0
        neutral.room = 0
        neutral.dialogue = 0
        neutral.distance = 0
        neutral.enabled = true
        rig.model.setStage(neutral, editedFor: rig.key)
        rig.settle()
        let left = StageRig.sine(440, amplitude: 0.4, frames: 2048)
        let right = StageRig.sine(660, amplitude: 0.3, frames: 2048)
        _ = rig.feedInsert(left: left, right: right)
        let output = rig.feedInsert(left: left, right: right)
        func rms(_ values: [Float]) -> Double {
            (values.reduce(0.0) { $0 + Double($1 * $1) } / Double(values.count)).squareRoot()
        }
        let outLeft = (1024..<2048).map { output[$0 * 2] }
        let outRight = (1024..<2048).map { output[$0 * 2 + 1] }
        XCTAssertEqual(rms(outLeft) / rms(Array(left[1024..<2048])), 1, accuracy: 0.1)
        XCTAssertEqual(rms(outRight) / rms(Array(right[1024..<2048])), 1, accuracy: 0.1)
    }

    func testMonitorBlocksAreMeteredOnTheSecondTick() throws {
        let rig = try makeRig()
        rig.model.setLevelTracking(true)
        rig.feedMonitor(StageRig.sine(1000, amplitude: 0.5, frames: 24000))
        rig.tick()
        let level = try XCTUnwrap(rig.model.level.state.currentLevelDb)
        XCTAssertEqual(level, -9.03, accuracy: 0.3)
    }

    func testSilenceIsReportedAsTheFloor() throws {
        let rig = try makeRig()
        rig.model.setLevelTracking(true)
        rig.feedMonitor([Float](repeating: 0, count: 24000))
        rig.tick()
        XCTAssertEqual(rig.model.level.state.currentLevelDb, -80)
    }

    func testNoLevelIsShownWhileNothingRuns() throws {
        let rig = try makeRig()
        rig.tick(2)
        XCTAssertNil(rig.model.level.state.currentLevelDb)
        XCTAssertEqual(rig.model.state.limiterGainReductionDb, 0)
    }

    func testTheLimiterTelemetryReachesTheState() throws {
        let rig = try makeRig()
        var settings = StageSettings()
        settings.width = 100
        settings.crossfeed = 0
        settings.room = 0
        settings.distance = 0
        settings.limiter = true
        settings.enabled = true
        rig.model.setStage(settings, editedFor: rig.key)
        rig.settle()
        let loud = StageRig.sine(200, amplitude: 1.6, frames: 24000)
        _ = rig.feedInsert(left: loud, right: loud)
        rig.tick()
        XCTAssertGreaterThan(rig.model.state.limiterGainReductionDb, 0.3)
    }

    func testAnActiveCallHoldsStageAndResumesAfterwards() throws {
        let rig = try makeRig()
        rig.enableStage()
        rig.reporter.reportedActiveCall = true
        rig.model.checkCallNow()
        rig.settle()
        XCTAssertTrue(rig.model.state.callActive)
        XCTAssertTrue(rig.model.state.callHold)
        XCTAssertEqual(liveStreams(rig).inserts, 0)
        XCTAssertEqual(rig.backend.configuredDefaultSinkName, "qx_5k")
        XCTAssertEqual(rig.model.state.status, "Paused for a call — resumes when the call ends.")
        rig.reporter.reportedActiveCall = false
        rig.model.checkCallNow()
        rig.settle(0.6)
        XCTAssertFalse(rig.model.state.callHold)
        XCTAssertEqual(liveStreams(rig).inserts, 1)
        XCTAssertTrue(rig.model.state.routed)
    }

    func testAHandsFreeInputSourceCountsAsACall() throws {
        let rig = try makeRig()
        rig.model.setLevelTracking(true)
        rig.reporter.reportedInputSource = "HFP 1"
        rig.model.checkCallNow()
        XCTAssertTrue(rig.model.state.callActive)
        XCTAssertEqual(liveStreams(rig).monitors, 0)
        XCTAssertTrue(rig.model.state.callHold)
        rig.reporter.reportedInputSource = "USB"
        rig.model.checkCallNow()
        XCTAssertFalse(rig.model.state.callActive)
        XCTAssertEqual(liveStreams(rig).monitors, 1)
    }

    func testACallWithNothingToHoldIsNotAHold() throws {
        let rig = try makeRig()
        rig.reporter.reportedActiveCall = true
        rig.model.checkCallNow()
        XCTAssertTrue(rig.model.state.callActive)
        XCTAssertFalse(rig.model.state.callHold)
    }

    func testReleasingACallByHandResumesUntilTheDeviceStopsSayingCall() throws {
        let rig = try makeRig()
        rig.model.setLevelTracking(true)
        rig.reporter.reportedActiveCall = true
        rig.model.checkCallNow()
        XCTAssertTrue(rig.model.state.callHold)
        rig.model.releaseCall()
        XCTAssertFalse(rig.model.state.callActive)
        XCTAssertEqual(liveStreams(rig).monitors, 1)
        XCTAssertGreaterThan(rig.reporter.statusRequests, 0)
        rig.reporter.reportedActiveCall = false
        rig.model.checkCallNow()
        rig.reporter.reportedActiveCall = true
        rig.model.checkCallNow()
        XCTAssertTrue(rig.model.state.callActive)
    }

    func testTheCallIsReReadEveryFiveSecondsWhileItLasts() throws {
        let rig = try makeRig()
        rig.model.setLevelTracking(true)
        rig.reporter.reportedActiveCall = true
        rig.model.checkCallNow()
        let before = rig.reporter.statusRequests
        rig.tick(5)
        XCTAssertGreaterThan(rig.reporter.statusRequests, before)
    }

    func testAStartFailureIsReportedAndRetriedAfterTheBackoff() throws {
        let rig = try makeRig()
        rig.backend.failStreams = true
        rig.model.setLevelTracking(true)
        XCTAssertFalse(rig.model.state.running)
        XCTAssertNotNil(rig.model.state.failure)
        XCTAssertEqual(rig.backend.monitors.count, 0)
        rig.backend.failStreams = false
        rig.model.checkCallNow()
        XCTAssertEqual(rig.backend.monitors.count, 0)
        rig.tick(Int(StageModel.retryBackoff) + 35)
        XCTAssertEqual(rig.backend.monitors.count, 1)
        XCTAssertNil(rig.model.state.failure)
    }

    func testAnInsertFailureLeavesTheDefaultAlone() throws {
        let rig = try makeRig()
        rig.backend.failStreams = true
        rig.enableStage()
        XCTAssertNotNil(rig.model.state.failure)
        XCTAssertEqual(rig.backend.setDefaultCalls, [])
        XCTAssertEqual(rig.backend.configuredDefaultSinkName, "qx_5k")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.memoryURL.path))
    }

    func testTheDefaultSwitchIsAnAsynchronousWriteWithADeadline() throws {
        let rig = try makeRig()
        rig.backend.deferDefaultChange = true
        rig.enableStage()
        XCTAssertTrue(rig.model.state.running)
        XCTAssertFalse(rig.model.state.routed)
        XCTAssertTrue(rig.model.state.status.hasPrefix("Starting"))
        rig.backend.flushDefault()
        rig.settle(0.5)
        XCTAssertTrue(rig.model.state.routed)
        XCTAssertNil(rig.model.state.failure)
    }

    func testASwitchThatNeverLandsFailsCleanlyAndRestores() throws {
        let rig = try makeRig()
        rig.backend.deferDefaultChange = true
        rig.enableStage()
        rig.settle(StageModel.phaseDeadline + 1)
        XCTAssertFalse(rig.model.state.running)
        XCTAssertNotNil(rig.model.state.failure)
        XCTAssertEqual(liveStreams(rig).inserts, 0)
        XCTAssertEqual(rig.backend.setDefaultCalls.last, "qx_5k")
    }

    func testAStageSinkThatNeverAppearsFailsCleanly() throws {
        let rig = try makeRig()
        rig.backend.autoStageSink = false
        rig.enableStage()
        rig.settle(StageModel.phaseDeadline + 1)
        XCTAssertFalse(rig.model.state.running)
        XCTAssertNotNil(rig.model.state.failure)
        XCTAssertEqual(rig.backend.setDefaultCalls, [])
    }

    func testAFailedStreamStopsTheInsert() throws {
        let rig = try makeRig()
        rig.enableStage()
        rig.backend.inserts[0].stream.hasFailed = true
        rig.tick()
        XCTAssertFalse(rig.model.state.running)
        XCTAssertEqual(rig.backend.configuredDefaultSinkName, "qx_5k")
    }

    func testTheGraphRateFromTheStreamReachesTheState() throws {
        let rig = try makeRig()
        rig.backend.streamFormat = AudioStreamFormat(rate: 44100, channels: 2)
        rig.model.setLevelTracking(true)
        XCTAssertEqual(rig.model.state.runningRate, 44100)
        XCTAssertTrue(rig.model.state.status.contains("44.1"))
        rig.backend.monitors[0].stream.format = AudioStreamFormat(rate: 96000, channels: 2)
        rig.tick()
        XCTAssertEqual(rig.model.state.runningRate, 96000)
    }

    func testSettingsPersistOnlyAfterTheDebounce() throws {
        let rig = try makeRig()
        try? FileManager.default.removeItem(at: rig.settingsURL)
        rig.model.applyPreset(.music, editedFor: rig.key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.settingsURL.path))
        rig.clock.advance(StageModel.saveDelay + 0.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.settingsURL.path))
    }

    func testStateRoundTripsThroughTheSharedFile() throws {
        let first = try makeRig()
        first.model.applyPreset(.theater, editedFor: first.key)
        first.model.setLevelTracking(true)
        first.model.setEarCalibration(108, editedFor: first.key)
        first.model.setAutoRate(false)
        first.model.saveNow()
        let saved = try JSONDecoder().decode(PersistedStageState.self,
                                             from: Data(contentsOf: first.settingsURL))
        XCTAssertTrue(saved.stageByDevice["qx_5k"]?.audiblyEquals(.theater) ?? false)
        XCTAssertTrue(saved.levelTracking)
        XCTAssertEqual(saved.autoRate, false)
        XCTAssertEqual(saved.earCalibrationByDevice?["qx_5k"], 108)
        first.model.shutdown()

        let second = try makeRig(directory: first.directory)
        XCTAssertTrue(second.model.state.settings.audiblyEquals(.theater))
        XCTAssertTrue(second.model.level.state.levelTracking)
        XCTAssertFalse(second.model.level.state.autoRate)
        XCTAssertEqual(second.model.level.state.earCalibrationDb, 108)
        second.settle(0.5)
        XCTAssertEqual(liveStreams(second).inserts, 1)
    }

    func testFieldsThisPlatformDoesNotUseSurviveARoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stage-keep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var seeded = PersistedStageState()
        seeded.a2dpGuard = "ask"
        seeded.perAppEQ = false
        seeded.detectQuality = false
        StageStateFile.save(seeded, to: directory.appendingPathComponent("stage.json"))
        let rig = try makeRig(directory: directory)
        rig.model.setLevelTracking(true)
        rig.model.saveNow()
        let saved = try JSONDecoder().decode(PersistedStageState.self,
                                             from: Data(contentsOf: rig.settingsURL))
        XCTAssertEqual(saved.a2dpGuard, "ask")
        XCTAssertEqual(saved.perAppEQ, false)
    }

    func testAnUnreadableFileIsParkedAndNeverOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stage-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("stage.json")
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: url)
        let rig = try makeRig(directory: directory)
        XCTAssertNotNil(rig.model.state.settingsNotice)
        XCTAssertTrue(rig.model.state.settingsNotice?.contains("stage.json.recovered") ?? false)
        rig.model.applyPreset(.music, editedFor: rig.key)
        rig.model.setLevelTracking(true)
        rig.clock.advance(2)
        rig.model.saveNow()
        XCTAssertEqual(try Data(contentsOf: url), garbage)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("stage.json.recovered").path))
    }

    func testImpulseResponsesInstallApplyAndRemove() async throws {
        let rig = try makeRig()
        let wav = rig.directory.appendingPathComponent("room.wav")
        var taps = [Float](repeating: 0, count: 2048)
        taps[0] = 1
        taps[100] = 0.4
        try WavFixture.write(wav, samples: taps)
        rig.model.installImpulse(wav, editedFor: rig.key)
        XCTAssertTrue(rig.model.state.impulseBusy)
        var waited = 0
        while rig.model.state.impulse == nil, waited < 400 {
            try await Task.sleep(nanoseconds: 25_000_000)
            waited += 1
        }
        let info = try XCTUnwrap(rig.model.state.impulse)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.sourceRate, 48000)
        XCTAssertTrue(rig.model.state.settings.hasImpulse)
        XCTAssertTrue(rig.model.state.settings.enabled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rig.impulseDirectory.path).count, 1)
        rig.model.setImpulseMix(0.5, editedFor: rig.key)
        XCTAssertEqual(rig.model.state.settings.impulseMixValue, 0.5)
        rig.model.removeImpulse(editedFor: rig.key)
        XCTAssertFalse(rig.model.state.settings.hasImpulse)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rig.impulseDirectory.path).count, 0)
    }

    func testABrokenImpulseFileIsRefusedWithAReason() async throws {
        let rig = try makeRig()
        let bad = rig.directory.appendingPathComponent("bad.wav")
        try Data("RIFFnope".utf8).write(to: bad)
        rig.model.installImpulse(bad, editedFor: rig.key)
        var waited = 0
        while rig.model.state.impulseProblem == nil, waited < 400 {
            try await Task.sleep(nanoseconds: 25_000_000)
            waited += 1
        }
        XCTAssertNotNil(rig.model.state.impulseProblem)
        XCTAssertFalse(rig.model.state.settings.hasImpulse)
    }

    func testShutdownSavesRestoresTheDefaultAndStopsTimers() throws {
        let rig = try makeRig()
        rig.enableStage()
        rig.model.shutdown()
        XCTAssertEqual(rig.backend.configuredDefaultSinkName, "qx_5k")
        XCTAssertEqual(liveStreams(rig).inserts, 0)
        XCTAssertNil(rig.backend.changeHandler)
        let saved = try JSONDecoder().decode(PersistedStageState.self,
                                             from: Data(contentsOf: rig.settingsURL))
        XCTAssertTrue(saved.stageByDevice["qx_5k"]?.enabled ?? false)
        let before = rig.backend.setDefaultCalls.count
        rig.tick(3)
        XCTAssertEqual(rig.backend.setDefaultCalls.count, before)
    }

    func testObserversSeeEveryVisibleChange() throws {
        let rig = try makeRig()
        var seen: [StageModelState] = []
        rig.model.addObserver { seen.append($0) }
        rig.model.applyPreset(.music, editedFor: rig.key)
        XCTAssertTrue(seen.last?.settings.enabled ?? false)
        let count = seen.count
        rig.model.applyPreset(.music, editedFor: rig.key)
        XCTAssertGreaterThanOrEqual(seen.count, count)
    }

    func testStaleStageDefaultFromACrashIsHealedWhileTheModelStarts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stage-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let memory = try JSONEncoder().encode(RoutingMemory(target: "qx_5k", previousConfigured: "qx_5k"))
        try memory.write(to: directory.appendingPathComponent("routing.json"))
        let rig = try makeRig(directory: directory, defaultSink: LinuxAudioNames.stageSinkName,
                              configured: .some(LinuxAudioNames.stageSinkName), start: false)
        rig.model.start()
        rig.settle(0.5)
        XCTAssertEqual(rig.backend.configuredDefaultSinkName, "qx_5k")
        XCTAssertEqual(rig.model.state.outputKey, "qx_5k")
    }
}
