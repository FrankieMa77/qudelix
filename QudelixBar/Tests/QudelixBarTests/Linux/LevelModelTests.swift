import XCTest
@testable import QudelixBar

@MainActor
final class LevelModelTests: XCTestCase {
    private var rigs: [StageRig] = []

    override func tearDown() async throws {
        for rig in rigs { rig.cleanUp() }
        rigs = []
        try await super.tearDown()
    }

    private func makeRig(sinks: [AudioSink] = [StageRig.fiveK, StageRig.speakers],
                         defaultSink: String? = "qx_5k",
                         detect: Bool = false) throws -> StageRig {
        let rig = try StageRig(sinks: sinks, defaultSink: defaultSink, detect: detect)
        rigs.append(rig)
        return rig
    }

    private func feedSignal(_ rig: StageRig, signal: [Float], rate: Int, ticks: Int,
                            chunk: inout Int) {
        let size = QualityAnalyzer.fftSize
        let chunks = signal.count / size
        for _ in 0..<ticks {
            let start = (chunk % chunks) * size
            rig.feedMonitor(Array(signal[start..<(start + size)]), rate: rate)
            rig.tick()
            chunk += 1
        }
    }

    private func feedTone(_ rig: StageRig, amplitude: Float, ticks: Int) {
        for _ in 0..<ticks {
            rig.feedMonitor(StageRig.sine(1000, amplitude: amplitude, frames: 24000))
            rig.tick()
        }
    }

    func testEarLevelUsesTheFiveKsReportedVolumeWhenItIsTheOutput() throws {
        let rig = try makeRig()
        rig.reporter.reportedVolumeDb = -20
        rig.backend.volumes["qx_5k"] = AudioSinkVolume(volume: 1, channelVolume: 0.5, muted: false)
        rig.model.setLevelTracking(true)
        feedTone(rig, amplitude: 0.3, ticks: 4)
        XCTAssertEqual(rig.model.level.state.earAnchor, .qudelix(-20))
        guard case .estimated = rig.model.level.state.earLevel else {
            return XCTFail("expected an estimate, got \(rig.model.level.state.earLevel)")
        }
        XCTAssertNotNil(rig.model.level.state.earLevelAverageDb)
    }

    func testEarLevelFallsBackToTheSinkVolumeOnOtherOutputs() throws {
        let rig = try makeRig(defaultSink: "alsa_speakers")
        rig.reporter.reportedVolumeDb = -20
        rig.backend.volumes["alsa_speakers"] = AudioSinkVolume(volume: 1, channelVolume: 0.1, muted: false)
        rig.model.setLevelTracking(true)
        feedTone(rig, amplitude: 0.3, ticks: 3)
        guard case .system(let db)? = rig.model.level.state.earAnchor else {
            return XCTFail("expected a system anchor")
        }
        XCTAssertEqual(db, -20, accuracy: 0.01)
    }

    func testTheFiveKFallsBackToItsSinkVolumeWhenTheDeviceReportsNothing() throws {
        let rig = try makeRig()
        rig.backend.volumes["qx_5k"] = AudioSinkVolume(volume: 1, channelVolume: 0.25, muted: false)
        rig.model.setLevelTracking(true)
        feedTone(rig, amplitude: 0.3, ticks: 2)
        guard case .system(let db)? = rig.model.level.state.earAnchor else {
            return XCTFail("expected a system anchor")
        }
        XCTAssertEqual(db, -12.04, accuracy: 0.05)
    }

    func testNoAnchorMeansNoEstimate() throws {
        let rig = try makeRig(defaultSink: "alsa_speakers")
        rig.backend.volumes["alsa_speakers"] = AudioSinkVolume(volume: 1, channelVolume: 0.5, muted: true)
        rig.model.setLevelTracking(true)
        feedTone(rig, amplitude: 0.3, ticks: 3)
        XCTAssertNil(rig.model.level.state.earAnchor)
        XCTAssertEqual(rig.model.level.state.earLevel, .unavailable)
    }

    func testSilenceReadsAsTooQuiet() throws {
        let rig = try makeRig()
        rig.reporter.reportedVolumeDb = -20
        rig.model.setLevelTracking(true)
        for _ in 0..<3 {
            rig.feedMonitor([Float](repeating: 0, count: 24000))
            rig.tick()
        }
        XCTAssertEqual(rig.model.level.state.earLevel, .tooQuiet)
    }

    func testCalibrationShiftsTheEstimateOneForOne() throws {
        let rig = try makeRig()
        rig.reporter.reportedVolumeDb = -20
        rig.model.setLevelTracking(true)
        feedTone(rig, amplitude: 0.3, ticks: 3)
        guard case .estimated(let before) = rig.model.level.state.earLevel else {
            return XCTFail("expected an estimate")
        }
        rig.model.setEarCalibration(EarLevel.defaultCalibrationDb + 10, editedFor: rig.key)
        feedTone(rig, amplitude: 0.3, ticks: 1)
        guard case .estimated(let after) = rig.model.level.state.earLevel else {
            return XCTFail("expected an estimate")
        }
        XCTAssertEqual(after - before, 10, accuracy: 1.01)
    }

    func testCalibrationIsRememberedPerOutput() throws {
        let rig = try makeRig()
        rig.model.setEarCalibration(110, editedFor: rig.key)
        XCTAssertEqual(rig.model.level.state.earCalibrationDb, 110)
        rig.changeDefault(to: "alsa_speakers")
        XCTAssertEqual(rig.model.level.state.earCalibrationDb, EarLevel.defaultCalibrationDb)
        rig.model.setEarCalibration(95, editedFor: rig.key)
        rig.changeDefault(to: "qx_5k")
        XCTAssertEqual(rig.model.level.state.earCalibrationDb, 110)
        rig.changeDefault(to: "alsa_speakers")
        XCTAssertEqual(rig.model.level.state.earCalibrationDb, 95)
    }

    func testCalibrationIsClampedAndStaleEditsAreDropped() throws {
        let rig = try makeRig()
        rig.model.setEarCalibration(500, editedFor: rig.key)
        XCTAssertEqual(rig.model.level.state.earCalibrationDb, EarLevel.calibrationRange.upperBound)
        rig.model.setEarCalibration(90, editedFor: "alsa_speakers")
        XCTAssertEqual(rig.model.level.state.earCalibrationDb, EarLevel.calibrationRange.upperBound)
    }

    func testEarLevelIsClearedWhenTheOutputChanges() throws {
        let rig = try makeRig()
        rig.reporter.reportedVolumeDb = -20
        rig.model.setLevelTracking(true)
        feedTone(rig, amplitude: 0.3, ticks: 3)
        XCTAssertNotEqual(rig.model.level.state.earLevel, .unavailable)
        rig.changeDefault(to: "alsa_speakers")
        XCTAssertEqual(rig.model.level.state.earLevel, .unavailable)
        XCTAssertNil(rig.model.level.state.earAnchor)
    }

    func testListeningIsRecordedOnlyWhileTrackingAndAudible() throws {
        let rig = try makeRig(detect: true)
        feedTone(rig, amplitude: 0.2, ticks: 3)
        XCTAssertTrue(rig.model.level.state.exposureDays.isEmpty)
        rig.model.setLevelTracking(true)
        feedTone(rig, amplitude: 0.2, ticks: 4)
        let today = LevelModel.dayKey(rig.clock.now())
        let day = try XCTUnwrap(rig.model.level.state.exposureDays.first { $0.day == today })
        XCTAssertEqual(day.audibleSeconds, 4)
        XCTAssertEqual(day.loudSeconds, 0)
        for _ in 0..<2 {
            rig.feedMonitor([Float](repeating: 0, count: 24000))
            rig.tick()
        }
        XCTAssertEqual(rig.model.level.state.exposureDays.first?.audibleSeconds, 4)
    }

    func testLoudSecondsCountAboveTheThreshold() throws {
        let rig = try makeRig()
        rig.model.setLevelTracking(true)
        feedTone(rig, amplitude: 0.9, ticks: 3)
        let day = try XCTUnwrap(rig.model.level.state.exposureDays.first)
        XCTAssertEqual(day.loudSeconds, 3)
        XCTAssertGreaterThan(day.energySum, 0)
    }

    func testHistoryDeleteEmptiesStateAndFileImmediately() throws {
        let rig = try makeRig()
        rig.model.setLevelTracking(true)
        feedTone(rig, amplitude: 0.5, ticks: 3)
        rig.model.saveNow()
        var saved = try JSONDecoder().decode(PersistedStageState.self, from: Data(contentsOf: rig.settingsURL))
        XCTAssertFalse(saved.exposure.isEmpty)
        rig.model.level.clearExposureHistory()
        XCTAssertTrue(rig.model.level.state.exposureDays.isEmpty)
        saved = try JSONDecoder().decode(PersistedStageState.self, from: Data(contentsOf: rig.settingsURL))
        XCTAssertTrue(saved.exposure.isEmpty)
    }

    func testHistoryIsLoadedUniqueAndCappedAtFourteenDays() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("level-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var seeded = PersistedStageState()
        seeded.detectQuality = false
        for day in 1...20 {
            let key = String(format: "2026-10-%02d", day)
            seeded.exposure.append(DayExposure(day: key, audibleSeconds: 60, loudSeconds: 5, energySum: 1))
        }
        seeded.exposure.append(DayExposure(day: "2026-10-20", audibleSeconds: 9, loudSeconds: 0, energySum: 0))
        StageStateFile.save(seeded, to: directory.appendingPathComponent("stage.json"))
        let rig = try StageRig(directory: directory)
        rigs.append(rig)
        let days = rig.model.level.state.exposureDays
        XCTAssertEqual(days.count, 14)
        XCTAssertEqual(days.last?.day, "2026-10-20")
        XCTAssertEqual(days.first?.day, "2026-10-07")
        XCTAssertEqual(Set(days.map(\.day)).count, 14)
    }

    func testAnArtificialLossyStreamIsDiagnosedOnlyAfterThreeStableReadings() throws {
        let rig = try makeRig(detect: true)
        rig.backend.streamFormat = AudioStreamFormat(rate: 44100, channels: 2)
        rig.model.checkCallNow()
        rig.model.setDetectQuality(false)
        rig.model.setDetectQuality(true)
        let signal = SyntheticSpectra.lowpassed(cutoffHz: 16000, rate: 44100, seed: 11)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 44100, ticks: 8, chunk: &chunk)
        XCTAssertNil(rig.model.level.state.quality)
        feedSignal(rig, signal: signal, rate: 44100, ticks: 2, chunk: &chunk)
        let quality = try XCTUnwrap(rig.model.level.state.quality)
        XCTAssertEqual(quality.kind, .lossy)
        XCTAssertEqual(try XCTUnwrap(quality.cutoffKHz), 16, accuracy: 1)
        XCTAssertEqual(quality.isLosslessClass, false)
    }

    func testBalanceIsReadAndSmoothed() throws {
        let rig = try makeRig(detect: true)
        let signal = SyntheticSpectra.tilted(slopeDbPerOctave: -3, rate: 48000, seed: 21)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 48000, ticks: 3, chunk: &chunk)
        let first = try XCTUnwrap(rig.model.level.state.balance)
        feedSignal(rig, signal: signal, rate: 48000, ticks: 6, chunk: &chunk)
        let later = try XCTUnwrap(rig.model.level.state.balance)
        XCTAssertEqual(first.tiltDbPerOctave, later.tiltDbPerOctave, accuracy: 0.5)
        XCTAssertEqual((later.bassDb * 10).rounded(), later.bassDb * 10, accuracy: 0.0001)
    }

    func testTurningDetectionOffClearsVerdictAndBalance() throws {
        let rig = try makeRig(detect: true)
        rig.backend.streamFormat = AudioStreamFormat(rate: 44100, channels: 2)
        rig.model.setDetectQuality(false)
        rig.model.setDetectQuality(true)
        let signal = SyntheticSpectra.lowpassed(cutoffHz: 16000, rate: 44100, seed: 11)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 44100, ticks: 10, chunk: &chunk)
        XCTAssertNotNil(rig.model.level.state.quality)
        XCTAssertNotNil(rig.model.level.state.balance)
        rig.model.setDetectQuality(false)
        XCTAssertNil(rig.model.level.state.quality)
        XCTAssertNil(rig.model.level.state.balance)
        XCTAssertFalse(rig.model.state.running)
    }

    func testTheVerdictIsClearedWhenTheOutputChanges() throws {
        let rig = try makeRig(detect: true)
        rig.backend.streamFormat = AudioStreamFormat(rate: 44100, channels: 2)
        rig.model.setDetectQuality(false)
        rig.model.setDetectQuality(true)
        let signal = SyntheticSpectra.lowpassed(cutoffHz: 16000, rate: 44100, seed: 11)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 44100, ticks: 10, chunk: &chunk)
        XCTAssertNotNil(rig.model.level.state.quality)
        rig.changeDefault(to: "alsa_speakers")
        rig.tick()
        XCTAssertNil(rig.model.level.state.quality)
        XCTAssertNil(rig.model.level.state.balance)
    }

    func testAFreshRateOutsideOurOwnSwitchRestartsTheDiagnosis() throws {
        let rig = try makeRig(detect: true)
        rig.backend.streamFormat = AudioStreamFormat(rate: 44100, channels: 2)
        rig.model.setDetectQuality(false)
        rig.model.setDetectQuality(true)
        let signal = SyntheticSpectra.lowpassed(cutoffHz: 16000, rate: 44100, seed: 11)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 44100, ticks: 10, chunk: &chunk)
        XCTAssertNotNil(rig.model.level.state.quality)
        rig.backend.monitors.last?.stream.format = AudioStreamFormat(rate: 48000, channels: 2)
        rig.tick()
        XCTAssertNil(rig.model.level.state.quality)
    }

    private func armAutoRate(_ rig: StageRig) throws -> [Float] {
        rig.backend.streamFormat = AudioStreamFormat(rate: 96000, channels: 2)
        rig.model.setDetectQuality(false)
        rig.model.setDetectQuality(true)
        return SyntheticSpectra.lowpassed(cutoffHz: 47000, rate: 96000, seed: 12)
    }

    func testAutoMatchForcesTheGraphRateOnlyAfterTheVerdictHasBeenStableForTenSeconds() throws {
        let rig = try makeRig(detect: true)
        let signal = try armAutoRate(rig)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 96000, ticks: 12, chunk: &chunk)
        XCTAssertEqual(rig.model.level.state.quality?.kind, .hiRes)
        XCTAssertEqual(rig.backend.forceRateCalls, [])
        feedSignal(rig, signal: signal, rate: 96000, ticks: 15, chunk: &chunk)
        XCTAssertEqual(rig.backend.forceRateCalls, [192000])
        XCTAssertEqual(rig.backend.forceRate, 192000)
        XCTAssertEqual(rig.model.level.state.autoSetRate, 192000)
        XCTAssertEqual(rig.model.level.state.manualRate, 96000)
        XCTAssertEqual(rig.model.level.forcedRate, 192000)
    }

    func testAutoMatchStaysOffWhenTheUserTurnedItOff() throws {
        let rig = try makeRig(detect: true)
        let signal = try armAutoRate(rig)
        rig.model.setAutoRate(false)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 96000, ticks: 30, chunk: &chunk)
        XCTAssertEqual(rig.backend.forceRateCalls, [])
    }

    func testAutoMatchNeverTouchesOtherOutputs() throws {
        let rig = try makeRig(defaultSink: "alsa_speakers", detect: true)
        let signal = try armAutoRate(rig)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 96000, ticks: 30, chunk: &chunk)
        XCTAssertEqual(rig.backend.forceRateCalls, [])
    }

    func testAutoMatchNeverTouchesABluetoothFiveK() throws {
        let rig = try makeRig(sinks: [StageRig.headset, StageRig.speakers],
                              defaultSink: "bluez_output.AA", detect: true)
        let signal = try armAutoRate(rig)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 96000, ticks: 30, chunk: &chunk)
        XCTAssertEqual(rig.model.level.state.quality?.kind, .hiRes)
        XCTAssertEqual(rig.backend.forceRateCalls, [])
    }

    func testAutoMatchIsSkippedWhileStageIsOn() throws {
        let rig = try makeRig(detect: true)
        rig.enableStage()
        let signal = try armAutoRate(rig)
        var chunk = 0
        for _ in 0..<30 {
            let start = (chunk % 8) * QualityAnalyzer.fftSize
            _ = rig.feedInsert(left: Array(signal[start..<(start + 8192)]),
                               right: Array(signal[start..<(start + 8192)]), rate: 96000)
            rig.tick()
            chunk += 1
        }
        XCTAssertEqual(rig.backend.forceRateCalls, [])
    }

    func testAutoMatchIsReleasedWhenStageIsSwitchedOn() throws {
        let rig = try makeRig(detect: true)
        let signal = try armAutoRate(rig)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 96000, ticks: 27, chunk: &chunk)
        XCTAssertEqual(rig.backend.forceRate, 192000)
        rig.enableStage()
        rig.tick()
        XCTAssertEqual(rig.backend.forceRate, 0)
        XCTAssertNil(rig.model.level.state.autoSetRate)
    }

    func testAutoMatchIsSkippedAndReleasedOnACall() throws {
        let rig = try makeRig(detect: true)
        let signal = try armAutoRate(rig)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 96000, ticks: 27, chunk: &chunk)
        XCTAssertEqual(rig.backend.forceRate, 192000)
        rig.reporter.reportedActiveCall = true
        rig.model.checkCallNow()
        rig.tick()
        XCTAssertEqual(rig.backend.forceRate, 0)
    }

    func testAutoMatchIsReleasedWhenTheFiveKStopsBeingTheOutput() throws {
        let rig = try makeRig(detect: true)
        let signal = try armAutoRate(rig)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 96000, ticks: 27, chunk: &chunk)
        XCTAssertEqual(rig.backend.forceRate, 192000)
        rig.changeDefault(to: "alsa_speakers")
        rig.tick()
        XCTAssertEqual(rig.backend.forceRate, 0)
    }

    func testTurningAutoMatchOffReleasesItAtOnce() throws {
        let rig = try makeRig(detect: true)
        let signal = try armAutoRate(rig)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 96000, ticks: 27, chunk: &chunk)
        XCTAssertEqual(rig.backend.forceRate, 192000)
        rig.model.setAutoRate(false)
        XCTAssertEqual(rig.backend.forceRate, 0)
        XCTAssertNil(rig.model.level.state.autoSetRate)
    }

    func testTurningDetectionOffReleasesTheForcedRate() throws {
        let rig = try makeRig(detect: true)
        let signal = try armAutoRate(rig)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 96000, ticks: 27, chunk: &chunk)
        rig.model.level.setQualityMaster(false)
        XCTAssertEqual(rig.backend.forceRate, 0)
        XCTAssertFalse(rig.model.level.state.qualityMasterOn)
    }

    func testShutdownReleasesTheForcedRate() throws {
        let rig = try makeRig(detect: true)
        let signal = try armAutoRate(rig)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 96000, ticks: 27, chunk: &chunk)
        XCTAssertEqual(rig.backend.forceRate, 192000)
        rig.model.shutdown()
        XCTAssertEqual(rig.backend.forceRate, 0)
    }

    private func markerRate(_ rig: StageRig) -> Int? {
        guard let data = try? Data(contentsOf: rig.forceMarkerURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else { return nil }
        return object["rate"]
    }

    private func staleRig(marker: Bool = true, rate: Int = 0) throws -> StageRig {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("force-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if marker {
            try Data("{\"rate\":44100}".utf8).write(to: directory.appendingPathComponent("force-rate.json"))
        }
        let rig = try StageRig(directory: directory, start: false) { $0.forceRate = rate }
        rigs.append(rig)
        return rig
    }

    func testAutoMatchRecordsTheRateItSetAndForgetsItOnRelease() throws {
        let rig = try makeRig(detect: true)
        let signal = try armAutoRate(rig)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 96000, ticks: 27, chunk: &chunk)
        XCTAssertEqual(rig.backend.forceRate, 192000)
        XCTAssertEqual(markerRate(rig), 192000)
        rig.enableStage()
        rig.tick()
        XCTAssertEqual(rig.backend.forceRate, 0)
        XCTAssertNil(markerRate(rig))
    }

    func testAMarkerThatCannotBeWrittenKeepsAutoMatchFromChangingTheRate() throws {
        let rig = try makeRig(detect: true)
        try FileManager.default.createDirectory(at: rig.forceMarkerURL.appendingPathComponent("occupied"),
                                                withIntermediateDirectories: true)
        let signal = try armAutoRate(rig)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 96000, ticks: 30, chunk: &chunk)
        XCTAssertEqual(rig.backend.forceRateCalls, [])
        XCTAssertEqual(rig.backend.forceRate, 0)
    }

    func testARateLeftBehindByAnEarlierRunIsClearedAtStart() throws {
        let rig = try staleRig(rate: 44100)
        rig.model.start()
        XCTAssertEqual(rig.backend.forceRateCalls, [0])
        XCTAssertEqual(rig.backend.forceRate, 0)
        XCTAssertNil(markerRate(rig))
        XCTAssertNil(rig.model.level.state.foreignForceRate)
    }

    func testARateSomeoneElseSetIsLeftAloneAndTheStaleMarkerIsDropped() throws {
        let rig = try staleRig(rate: 96000)
        rig.model.start()
        XCTAssertEqual(rig.backend.forceRateCalls, [])
        XCTAssertEqual(rig.backend.forceRate, 96000)
        XCTAssertNil(markerRate(rig))
    }

    func testAMarkerWithNoRateInForceIsJustRemoved() throws {
        let rig = try staleRig(rate: 0)
        rig.model.start()
        XCTAssertEqual(rig.backend.forceRateCalls, [])
        XCTAssertNil(markerRate(rig))
    }

    func testARateFixedByAnotherProgramIsShownOnTheLevelPage() throws {
        let rig = try makeRig()
        rig.backend.forceRate = 44100
        rig.tick()
        XCTAssertEqual(rig.model.level.state.foreignForceRate, 44100)
        let notices = LevelPresentation.notices(stage: rig.model.state, level: rig.model.level.state)
        XCTAssertEqual(notices.map(\.text),
                       ["Another program has fixed the audio graph at 44.1 kHz; Auto-match waits."])
        rig.backend.forceRate = 0
        rig.tick()
        XCTAssertNil(rig.model.level.state.foreignForceRate)
    }

    func testARateAutoMatchSetItselfIsNotReportedAsForeign() throws {
        let rig = try makeRig(detect: true)
        let signal = try armAutoRate(rig)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 96000, ticks: 27, chunk: &chunk)
        XCTAssertEqual(rig.backend.forceRate, 192000)
        XCTAssertNil(rig.model.level.state.foreignForceRate)
    }

    func testAForceRateIsForgottenWhenTheServerRestartsAndTheMarkerIsCheckedAgain() throws {
        let rig = try makeRig(detect: true)
        let signal = try armAutoRate(rig)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 96000, ticks: 27, chunk: &chunk)
        XCTAssertNotNil(rig.model.level.forcedRate)
        rig.backend.connected = false
        rig.backend.changeHandler?()
        rig.hops.drain()
        XCTAssertNil(rig.model.level.forcedRate)
        rig.backend.forceRate = 0
        rig.backend.connected = true
        rig.backend.changeHandler?()
        rig.hops.drain()
        XCTAssertNil(markerRate(rig))
    }

    func testAForceRateTheUserSetIsNeverOverridden() throws {
        let rig = try makeRig(detect: true)
        rig.backend.forceRate = 44100
        let signal = try armAutoRate(rig)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 96000, ticks: 30, chunk: &chunk)
        XCTAssertEqual(rig.backend.forceRateCalls, [])
        XCTAssertEqual(rig.backend.forceRate, 44100)
    }

    func testARateChangeThatNeverLandsIsDroppedAfterItsDeadline() throws {
        let rig = try makeRig(detect: true)
        rig.backend.applyForceRate = false
        let signal = try armAutoRate(rig)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 96000, ticks: 22, chunk: &chunk)
        XCTAssertEqual(rig.backend.forceRateCalls.first, 192000)
        XCTAssertEqual(rig.model.level.state.autoSetRate, 192000)
        feedSignal(rig, signal: signal, rate: 96000, ticks: Int(LevelModel.forceDeadline) + 2, chunk: &chunk)
        XCTAssertNil(rig.model.level.state.autoSetRate)
        XCTAssertNil(rig.model.level.forcedRate)
    }

    func testARateChangedBySomeoneElseIsLeftAlone() throws {
        let rig = try makeRig(detect: true)
        let signal = try armAutoRate(rig)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 96000, ticks: 27, chunk: &chunk)
        XCTAssertEqual(rig.backend.forceRate, 192000)
        rig.backend.forceRate = 48000
        let before = rig.backend.forceRateCalls.count
        rig.model.shutdown()
        XCTAssertEqual(rig.backend.forceRateCalls.count, before)
        XCTAssertEqual(rig.backend.forceRate, 48000)
    }

    func testTheAutomationFeedReportsEachSecond() throws {
        let rig = try makeRig(detect: true)
        var contexts: [EqAutomation.Context] = []
        rig.model.level.automationTick = { contexts.append($0) }
        rig.tick(2)
        XCTAssertEqual(contexts.count, 2)
        let context = try XCTUnwrap(contexts.last)
        XCTAssertEqual(context.deviceUID, "qx_5k")
        XCTAssertTrue(context.onQudelixOutput)
        XCTAssertTrue(context.detecting)
        XCTAssertFalse(context.muted)
        XCTAssertFalse(context.onCall)
        XCTAssertEqual(context.dt, 1)
        XCTAssertNil(context.verdict)
    }

    func testTheAutomationFeedCarriesReadingAndVerdict() throws {
        let rig = try makeRig(detect: true)
        rig.backend.streamFormat = AudioStreamFormat(rate: 44100, channels: 2)
        rig.model.setDetectQuality(false)
        rig.model.setDetectQuality(true)
        var contexts: [EqAutomation.Context] = []
        rig.model.level.automationTick = { contexts.append($0) }
        let signal = SyntheticSpectra.lowpassed(cutoffHz: 16000, rate: 44100, seed: 11)
        var chunk = 0
        feedSignal(rig, signal: signal, rate: 44100, ticks: 10, chunk: &chunk)
        XCTAssertTrue(contexts.contains { $0.reading != nil })
        XCTAssertNotNil(contexts.last?.verdict)
    }

    func testTheAutomationFeedKnowsTheOutputIsNotTheFiveK() throws {
        let rig = try makeRig(defaultSink: "alsa_speakers", detect: true)
        var contexts: [EqAutomation.Context] = []
        rig.model.level.automationTick = { contexts.append($0) }
        rig.tick()
        XCTAssertEqual(contexts.last?.deviceUID, "alsa_speakers")
        XCTAssertEqual(contexts.last?.onQudelixOutput, false)
    }

    func testTheAutomationFeedKeepsTickingWithoutARunningStream() throws {
        let rig = try makeRig()
        var contexts: [EqAutomation.Context] = []
        rig.model.level.automationTick = { contexts.append($0) }
        rig.tick(3)
        XCTAssertEqual(contexts.count, 3)
        XCTAssertNil(contexts.last?.deviceUID)
        XCTAssertFalse(contexts.last?.detecting ?? true)
    }

    func testTheAutomationFeedFlagsACall() throws {
        let rig = try makeRig(detect: true)
        var contexts: [EqAutomation.Context] = []
        rig.model.level.automationTick = { contexts.append($0) }
        rig.reporter.reportedActiveCall = true
        rig.model.checkCallNow()
        rig.tick()
        XCTAssertEqual(contexts.last?.onCall, true)
    }

    func testTheExplanationSaysItAffectsTheWholeGraph() {
        XCTAssertTrue(LevelModel.autoRateExplanation.contains("whole audio graph"))
        XCTAssertTrue(LevelModel.autoRateExplanation.contains("quits"))
    }

    func testQualityMasterTogglesBothSwitchesTogether() throws {
        let rig = try makeRig(detect: true)
        XCTAssertTrue(rig.model.level.state.qualityMasterOn)
        rig.model.level.setQualityMaster(false)
        XCTAssertFalse(rig.model.level.state.detectQuality)
        XCTAssertFalse(rig.model.level.state.autoRate)
        rig.model.level.setQualityMaster(true)
        XCTAssertTrue(rig.model.level.state.detectQuality)
        XCTAssertTrue(rig.model.level.state.autoRate)
        XCTAssertEqual(rig.backend.monitors.count, 2)
    }

    func testObserversAreToldOnlyAboutRealChanges() throws {
        let rig = try makeRig()
        var seen = 0
        let id = rig.model.level.addObserver { _ in seen += 1 }
        XCTAssertEqual(seen, 1)
        rig.model.level.setLevelTracking(true)
        XCTAssertEqual(seen, 2)
        rig.model.level.removeObserver(id)
        rig.model.level.setLevelTracking(false)
        XCTAssertEqual(seen, 2)
    }
}
