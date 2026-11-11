import XCTest
@testable import QudelixBar

@MainActor
final class AudioSafetyTests: XCTestCase {
    private var rigs: [StageRig] = []
    private let stage = LinuxAudioNames.stageSinkName

    override func tearDown() async throws {
        for rig in rigs { rig.cleanUp() }
        rigs = []
        try await super.tearDown()
    }

    private func makeRig(directory: URL? = nil,
                         defaultSink: String? = "qx_5k",
                         configured: String?? = nil,
                         start: Bool = true,
                         realGain: Float = 1,
                         prepare: @escaping (FakeAudioBackend) -> Void = { _ in }) throws -> StageRig {
        let rig = try StageRig(directory: directory, defaultSink: defaultSink, configured: configured,
                               start: start) { backend in
            backend.volumes["qx_5k"] = AudioSinkVolume(volume: 1, channelVolume: realGain, muted: false)
            prepare(backend)
        }
        rigs.append(rig)
        return rig
    }

    private func setStageVolume(_ rig: StageRig, gain: Float, muted: Bool = false) {
        rig.backend.volumes[stage] = AudioSinkVolume(volume: 1, channelVolume: gain, muted: muted)
        rig.backend.changeHandler?()
        rig.hops.drain()
    }

    private func real(_ rig: StageRig) -> AudioSinkVolume {
        rig.backend.volumes["qx_5k"] ?? AudioSinkVolume(volume: -1, channelVolume: -1, muted: false)
    }

    private func scaleCalls(_ rig: StageRig, on name: String = "qx_5k") -> Int {
        rig.backend.scaleCalls.filter { $0.name == name }.count
    }

    private func savedMemory(_ rig: StageRig) -> RoutingMemory? {
        guard let data = try? Data(contentsOf: rig.memoryURL) else { return nil }
        return try? JSONDecoder().decode(RoutingMemory.self, from: data)
    }

    private func assertHandedOver(_ rig: StageRig, gain: Float, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(real(rig).gain, gain, accuracy: 0.0005, file: file, line: line)
        let events = rig.backend.events
        guard let scaled = events.firstIndex(of: "scale:qx_5k"),
              let restored = events.lastIndex(of: "default:qx_5k") else {
            return XCTFail("missing events: \(events)", file: file, line: line)
        }
        XCTAssertLessThan(scaled, restored, "the volume must move before the default does", file: file, line: line)
    }

    func testTurningStageOffHandsTheStageVolumeToTheRealSinkBeforeTheDefaultReturns() throws {
        let rig = try makeRig()
        rig.enableStage()
        setStageVolume(rig, gain: 0.2)
        rig.model.setEnabled(false, editedFor: rig.key)
        rig.settle()
        assertHandedOver(rig, gain: 0.2)
        XCTAssertFalse(real(rig).muted)
    }

    func testTheHandoverIsAProductOfBothVolumes() throws {
        let rig = try makeRig(realGain: 0.6)
        rig.enableStage()
        setStageVolume(rig, gain: 0.5)
        rig.model.setEnabled(false, editedFor: rig.key)
        rig.settle()
        assertHandedOver(rig, gain: 0.3)
    }

    func testAMutedStageSinkMutesTheRealSink() throws {
        let rig = try makeRig()
        rig.enableStage()
        setStageVolume(rig, gain: 1, muted: true)
        rig.model.setEnabled(false, editedFor: rig.key)
        rig.settle()
        XCTAssertTrue(real(rig).muted)
        XCTAssertEqual(real(rig).gain, 1, accuracy: 0.0005)
    }

    func testAFailedStageHandsTheVolumeOver() throws {
        let rig = try makeRig()
        rig.enableStage()
        setStageVolume(rig, gain: 0.25)
        rig.backend.inserts[0].stream.hasFailed = true
        rig.tick()
        XCTAssertFalse(rig.model.state.running)
        assertHandedOver(rig, gain: 0.25)
    }

    func testShuttingDownRestoresTheDefaultOnceSoTheBudgetHolds() throws {
        let rig = try makeRig()
        rig.enableStage()
        rig.model.shutdown()
        XCTAssertEqual(rig.backend.setDefaultCalls, [stage, "qx_5k"])
    }

    func testQuittingHandsTheVolumeOver() throws {
        let rig = try makeRig()
        rig.enableStage()
        setStageVolume(rig, gain: 0.4)
        rig.model.shutdown()
        assertHandedOver(rig, gain: 0.4)
    }

    func testShuttingDownAfterStageWasTurnedOffDoesNotApplyTheVolumeTwice() throws {
        let rig = try makeRig()
        rig.enableStage()
        setStageVolume(rig, gain: 0.5)
        rig.model.setEnabled(false, editedFor: rig.key)
        rig.settle()
        rig.model.shutdown()
        XCTAssertEqual(real(rig).gain, 0.5, accuracy: 0.0005)
        XCTAssertEqual(scaleCalls(rig), 1)
    }

    func testTheRealOutputDisappearingNeverWritesToAMissingSink() throws {
        let rig = try makeRig()
        rig.enableStage()
        setStageVolume(rig, gain: 0.3)
        rig.backend.sinks.removeAll { $0.name == "qx_5k" }
        rig.backend.changeHandler?()
        rig.settle(0.5)
        XCTAssertEqual(scaleCalls(rig), 0)
        XCTAssertEqual(rig.backend.inserts.last?.target, "alsa_speakers")
        XCTAssertFalse(rig.backend.inserts[0].stream.isStreaming)
    }

    func testPickingAnotherDefaultWhileStagedLeavesTheOutputsVolumeAlone() throws {
        let rig = try makeRig()
        rig.enableStage()
        setStageVolume(rig, gain: 0.3)
        rig.changeDefault(to: "alsa_speakers")
        XCTAssertEqual(scaleCalls(rig), 0)
        XCTAssertEqual(real(rig).gain, 1, accuracy: 0.0005)
    }

    func testABoostedStageSinkNeverRaisesTheRealSink() throws {
        let rig = try makeRig(realGain: 0.5)
        rig.enableStage()
        setStageVolume(rig, gain: 1.5)
        rig.model.setEnabled(false, editedFor: rig.key)
        rig.settle()
        XCTAssertEqual(real(rig).gain, 0.5, accuracy: 0.0005)
    }

    func testAStaleStageSinkVolumeIsResetToUnityBeforeTheDefaultMovesThere() throws {
        let rig = try makeRig(realGain: 0.6) { backend in
            backend.stageVolumeOnCreate = AudioSinkVolume(volume: 1, channelVolume: 0.3, muted: true)
        }
        rig.enableStage()
        let volume = try XCTUnwrap(rig.backend.volumes[stage])
        XCTAssertEqual(volume.gain, 1, accuracy: 0.001)
        XCTAssertFalse(volume.muted)
        XCTAssertEqual(real(rig).gain, 0.6, accuracy: 0.0005)
        let events = rig.backend.events
        XCTAssertEqual(events.first, "scale:\(stage)")
        XCTAssertEqual(events.dropFirst().first, "default:\(stage)")
    }

    func testTheStageVolumeIsPersistedWhileStageRuns() throws {
        let rig = try makeRig()
        rig.enableStage()
        XCTAssertEqual(savedMemory(rig)?.stageGain, 1)
        setStageVolume(rig, gain: 0.25)
        rig.tick(2)
        let memory = try XCTUnwrap(savedMemory(rig))
        XCTAssertEqual(try XCTUnwrap(memory.stageGain), 0.25, accuracy: 0.001)
        XCTAssertEqual(memory.stageMuted, false)
        setStageVolume(rig, gain: 0.25, muted: true)
        rig.tick(2)
        XCTAssertEqual(savedMemory(rig)?.stageMuted, true)
    }

    func testAQuieterStageVolumeIsPersistedAtOnce() throws {
        let rig = try makeRig()
        rig.enableStage()
        rig.clock.advance(0.2)
        setStageVolume(rig, gain: 0.1)
        XCTAssertEqual(try XCTUnwrap(savedMemory(rig)?.stageGain), 0.1, accuracy: 0.001)
    }

    private func crashDirectory(_ memory: RoutingMemory) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stage-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(memory).write(to: directory.appendingPathComponent("routing.json"))
        return directory
    }

    func testCrashRecoveryAppliesThePersistedStageVolumeBeforeRestoringTheDefault() throws {
        let directory = try crashDirectory(RoutingMemory(target: "qx_5k", previousConfigured: "qx_5k",
                                                         stageGain: 0.2, stageMuted: false))
        let rig = try makeRig(directory: directory, defaultSink: stage, configured: .some(stage), start: false)
        rig.model.start()
        rig.settle(0.5)
        assertHandedOver(rig, gain: 0.2)
        XCTAssertEqual(rig.backend.configuredDefaultSinkName, "qx_5k")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.memoryURL.path))
    }

    func testCrashRecoveryHonoursAPersistedMute() throws {
        let directory = try crashDirectory(RoutingMemory(target: "qx_5k", previousConfigured: "qx_5k",
                                                         stageGain: 1, stageMuted: true))
        let rig = try makeRig(directory: directory, defaultSink: stage, configured: .some(stage), start: false)
        rig.model.start()
        rig.settle(0.5)
        XCTAssertTrue(real(rig).muted)
    }

    func testCrashRecoveryDoesNotApplyAnAlreadyHandedOverVolumeAgain() throws {
        let directory = try crashDirectory(RoutingMemory(target: "qx_5k", previousConfigured: "qx_5k",
                                                         stageGain: 0.2, stageMuted: false, handedOver: true))
        let rig = try makeRig(directory: directory, defaultSink: stage, configured: .some(stage), start: false)
        rig.model.start()
        rig.settle(0.5)
        XCTAssertEqual(scaleCalls(rig), 0)
        XCTAssertEqual(rig.backend.configuredDefaultSinkName, "qx_5k")
    }

    func testAnOldRecordWithoutVolumeFieldsStillRecoversTheDefault() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stage-old-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"target\":\"qx_5k\",\"previousConfigured\":\"qx_5k\"}".utf8)
            .write(to: directory.appendingPathComponent("routing.json"))
        let rig = try makeRig(directory: directory, defaultSink: stage, configured: .some(stage), start: false)
        rig.model.start()
        rig.settle(0.5)
        XCTAssertEqual(scaleCalls(rig), 0)
        XCTAssertEqual(rig.backend.configuredDefaultSinkName, "qx_5k")
    }

    func testAHandoverThatCannotBeWrittenIsReportedAndTheDefaultStillReturns() throws {
        let rig = try makeRig()
        rig.enableStage()
        setStageVolume(rig, gain: 0.5)
        rig.backend.acceptScale = false
        rig.model.setEnabled(false, editedFor: rig.key)
        rig.settle()
        XCTAssertEqual(rig.routing.notice, OutputRouting.volumeHandoverFailedNotice)
        XCTAssertEqual(rig.model.state.audioNotice, OutputRouting.volumeHandoverFailedNotice)
        XCTAssertEqual(rig.backend.configuredDefaultSinkName, "qx_5k")
    }

    func testARestoreThatTheServerRefusesIsReported() throws {
        let rig = try makeRig()
        rig.enableStage()
        rig.backend.acceptDefaultChange = false
        rig.model.setEnabled(false, editedFor: rig.key)
        rig.settle()
        XCTAssertEqual(rig.routing.notice, OutputRouting.restoreFailedNotice)
        XCTAssertEqual(rig.model.state.audioNotice, "Couldn\u{2019}t put your default output back \u{2014} choose it in Sound settings.")
        XCTAssertTrue(StagePresentation.notices(rig.model.state).contains {
            $0.text == OutputRouting.restoreFailedNotice && $0.caution
        })
    }

    func testARestoreThatNeverLandsIsReportedAfterThreeSeconds() throws {
        let rig = try makeRig()
        rig.enableStage()
        rig.backend.deferDefaultChange = true
        rig.model.setEnabled(false, editedFor: rig.key)
        rig.settle()
        XCTAssertNil(rig.routing.notice)
        rig.tick(4)
        XCTAssertEqual(rig.routing.notice, OutputRouting.restoreFailedNotice)
    }

    func testARestoreThatLandsClearsAnEarlierNotice() throws {
        let rig = try makeRig()
        rig.enableStage()
        rig.backend.acceptDefaultChange = false
        rig.model.setEnabled(false, editedFor: rig.key)
        rig.settle()
        XCTAssertNotNil(rig.routing.notice)
        rig.backend.acceptDefaultChange = true
        rig.enableStage()
        XCTAssertNil(rig.routing.notice)
    }

    func testStageDoesNotStartWhenTheRecoveryRecordCannotBeWritten() throws {
        let rig = try makeRig()
        let blocker = rig.memoryURL.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        rig.enableStage()
        XCTAssertTrue(rig.backend.inserts.isEmpty)
        XCTAssertFalse(rig.model.state.running)
        XCTAssertEqual(rig.model.state.failure?.message, OutputRouting.recordFailedNotice)
        XCTAssertEqual(rig.backend.setDefaultCalls, [])
        XCTAssertEqual(rig.model.state.audioNotice, OutputRouting.recordFailedNotice)
    }

    func testAStageThatStaysSilentWhileAppsPlayIsSwitchedOffAfterThreeSeconds() throws {
        let rig = try makeRig()
        rig.enableStage()
        rig.backend.inserts[0].stream.playbackLegState = .ready
        rig.tick(2)
        XCTAssertTrue(rig.model.state.running)
        rig.tick(2)
        XCTAssertFalse(rig.model.state.running)
        XCTAssertTrue(rig.model.state.failure?.message.hasPrefix("Stage went silent") == true)
        XCTAssertEqual(rig.backend.configuredDefaultSinkName, "qx_5k")
        rig.tick(40)
        XCTAssertFalse(rig.model.state.running)
    }

    func testASilentPlaybackLegIsFineWhileNothingPlaysIntoStage() throws {
        let rig = try makeRig()
        rig.enableStage()
        rig.backend.inserts[0].stream.sinkLegState = .ready
        rig.backend.inserts[0].stream.playbackLegState = .ready
        rig.tick(10)
        XCTAssertTrue(rig.model.state.running)
    }

    func testABriefStallDoesNotSwitchStageOff() throws {
        let rig = try makeRig()
        rig.enableStage()
        let stream = rig.backend.inserts[0].stream
        stream.playbackLegState = .ready
        rig.tick(2)
        stream.playbackLegState = .streaming
        rig.tick(5)
        XCTAssertTrue(rig.model.state.running)
    }

    func testUnderrunsOnEveryTickForThreeSecondsSwitchStageOff() throws {
        let rig = try makeRig()
        rig.enableStage()
        let stream = rig.backend.inserts[0].stream
        for _ in 0..<2 {
            stream.underruns += 5
            rig.tick()
        }
        XCTAssertTrue(rig.model.state.running)
        stream.underruns += 5
        rig.tick()
        XCTAssertFalse(rig.model.state.running)
        XCTAssertTrue(rig.model.state.failure?.message.contains("keep up") == true)
        XCTAssertEqual(rig.backend.configuredDefaultSinkName, "qx_5k")
    }

    func testOccasionalUnderrunsAreTolerated() throws {
        let rig = try makeRig()
        rig.enableStage()
        let stream = rig.backend.inserts[0].stream
        for index in 0..<12 {
            if index % 3 == 0 { stream.underruns += 1 }
            rig.tick()
        }
        XCTAssertTrue(rig.model.state.running)
    }

    func testDifferentRatesOnTheTwoLegsFailStageBeforeTheSwitch() throws {
        let rig = try makeRig { backend in
            backend.streamFormat = AudioStreamFormat(rate: 44100, channels: 2)
            backend.sinkLegRate = 48000
        }
        rig.enableStage()
        XCTAssertFalse(rig.model.state.running)
        XCTAssertEqual(rig.model.state.failure?.message,
                       "The audio graph runs the Stage output and the 5K at different rates; Stage needs one rate.")
        XCTAssertFalse(rig.backend.setDefaultCalls.contains(stage))
    }

    func testARateMismatchThatAppearsLaterAlsoSwitchesStageOff() throws {
        let rig = try makeRig()
        rig.enableStage()
        rig.backend.inserts[0].stream.sinkLegFormat = AudioStreamFormat(rate: 44100, channels: 2)
        rig.tick()
        XCTAssertFalse(rig.model.state.running)
        XCTAssertNotNil(rig.model.state.failure)
        XCTAssertEqual(rig.backend.configuredDefaultSinkName, "qx_5k")
    }

    func testTheProcessorIsPreparedAtThePlaybackRateBeforeStageGoesLive() throws {
        let rig = try makeRig { backend in
            backend.streamFormat = AudioStreamFormat(rate: 44100, channels: 2)
        }
        rig.enableStage()
        XCTAssertEqual(rig.model.state.runningRate, 44100)
        XCTAssertTrue(rig.model.state.routed)
    }

    func testTheStageVolumeIsPartOfTheEarLevelAnchor() throws {
        let rig = try makeRig(realGain: 0.5)
        rig.model.setLevelTracking(true)
        rig.enableStage()
        setStageVolume(rig, gain: 0.5)
        XCTAssertEqual(try XCTUnwrap(rig.model.level.volumeAnchor()).db, -12.04, accuracy: 0.05)
        setStageVolume(rig, gain: 1, muted: true)
        XCTAssertNil(rig.model.level.volumeAnchor())
        rig.model.setEnabled(false, editedFor: rig.key)
        rig.settle()
        XCTAssertTrue(real(rig).muted)
        rig.backend.volumes["qx_5k"] = AudioSinkVolume(volume: 1, channelVolume: 0.5, muted: false)
        XCTAssertEqual(try XCTUnwrap(rig.model.level.volumeAnchor()).db, -6.02, accuracy: 0.05)
    }

    func testTheFiveKAnchorAlsoFollowsTheStageVolume() throws {
        let rig = try makeRig()
        rig.reporter.reportedVolumeDb = -20
        rig.model.setLevelTracking(true)
        rig.enableStage()
        setStageVolume(rig, gain: 0.1)
        XCTAssertEqual(try XCTUnwrap(rig.model.level.volumeAnchor()).db, -40, accuracy: 0.05)
    }

    func testAnImpulseThatTheConvolverCannotTakeIsReportedAsWaiting() throws {
        var state = StageModelState()
        var settings = StageSettings.music
        settings.enabled = true
        settings.impulseFile = "ir.wav"
        settings.impulseMix = 1
        state.settings = settings
        state.impulseState = .ready(partitions: 4, taps: 1024, hop: 128, rate: 48000)
        XCTAssertTrue(state.impulseInPath)
        state.impulseWaiting = true
        XCTAssertFalse(state.impulseInPath)
        let notices = StagePresentation.notices(state)
        XCTAssertTrue(notices.contains { $0.text == StagePresentation.impulseWaitingText })
    }
}
