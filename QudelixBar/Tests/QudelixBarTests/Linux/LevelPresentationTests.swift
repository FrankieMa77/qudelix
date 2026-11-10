import XCTest
@testable import QudelixBar

@MainActor
final class LevelPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func live(_ scenario: DemoLevelScenario = .live) -> (StageModelState, LevelModelState) {
        (DemoAudioData.runningStage(for: scenario), DemoAudioData.level(scenario, now: now))
    }

    func testOutputLevelTextAndFraction() {
        let (stage, level) = live()
        XCTAssertEqual(LevelPresentation.outputLevelText(stage: stage, level: level), "-21 dBFS")
        XCTAssertEqual(LevelPresentation.meterFraction(stage: stage, level: level)!, 0.65, accuracy: 1e-9)
        var silent = level
        silent.currentLevelDb = nil
        XCTAssertEqual(LevelPresentation.outputLevelText(stage: stage, level: silent), "silent")
        XCTAssertNil(LevelPresentation.meterFraction(stage: stage, level: silent))
        let off = DemoAudioData.runningStage(for: .empty)
        XCTAssertEqual(LevelPresentation.outputLevelText(stage: off, level: level), "off")
        XCTAssertEqual(LevelPresentation.meterFraction(-90), 0)
        XCTAssertEqual(LevelPresentation.meterFraction(6), 1)
        XCTAssertEqual(LevelPresentation.meterFraction(LevelPresentation.loudMarkerDb), 0.8, accuracy: 1e-9)
    }

    func testMeterRowsAppearOnlyWhileStageIsInserted() {
        XCTAssertTrue(LevelPresentation.meterRows(stage: DemoAudioData.stage(.off)).isEmpty)
        XCTAssertTrue(LevelPresentation.meterRows(stage: DemoAudioData.runningStage(for: .live)).isEmpty)
        let rows = LevelPresentation.meterRows(stage: DemoAudioData.stage(.on))
        XCTAssertEqual(rows.map(\.label), ["True-peak limiter", "Loudness", "Bass guard"])
        XCTAssertEqual(rows.map(\.value), ["\u{2212}1.4 dB", "+3.2 dB bass", "\u{2212}1.1 of 6.5 dB"])
        XCTAssertEqual(rows.map(\.lit), [true, true, true])
        XCTAssertEqual(rows.map(\.caution), [true, false, true])
    }

    func testIdleMeterRowsReadIdle() {
        var stage = DemoAudioData.stage(.on)
        stage.limiterGainReductionDb = 0
        stage.loudnessShelfDb = 0
        stage.bassGuardGainReductionDb = 0
        let rows = LevelPresentation.meterRows(stage: stage)
        XCTAssertEqual(rows.map(\.value), ["idle", "flat", "idle of 6.5 dB"])
        XCTAssertEqual(rows.map(\.lit), [false, false, false])
        stage.settings.bassGuard = false
        XCTAssertEqual(LevelPresentation.meterRows(stage: stage).count, 2)
        stage.bassGuardBoostDb = 0
        stage.settings.bassGuard = true
        XCTAssertEqual(LevelPresentation.meterRows(stage: stage).count, 2)
    }

    func testEarLevelTexts() {
        let (stage, level) = live()
        XCTAssertEqual(LevelPresentation.earLevelText(stage: stage, level: level), "~78 dB (estimate)")
        var quiet = level
        quiet.earLevel = .tooQuiet
        XCTAssertEqual(LevelPresentation.earLevelText(stage: stage, level: quiet), "too quiet to estimate")
        XCTAssertEqual(LevelPresentation.earLevelText(stage: DemoAudioData.stage(.off), level: level), "\u{2014}")
        XCTAssertTrue(LevelPresentation.earDisclaimer(level).contains("5K\u{2019}s volume setting"))
        var system = level
        system.earAnchor = .system(-10)
        XCTAssertTrue(LevelPresentation.earDisclaimer(system).contains("this output\u{2019}s volume"))
        system.earAnchor = nil
        XCTAssertTrue(LevelPresentation.earDisclaimer(system).contains("offers none"))
    }

    func testCalibrationReadout() {
        let (_, level) = live()
        XCTAssertEqual(LevelPresentation.calibrationOffsetText(level), "+3 dB")
        XCTAssertFalse(LevelPresentation.calibrationIsDefault(level))
        XCTAssertTrue(LevelPresentation.calibrationIsDefault(LevelModelState()))
        XCTAssertEqual(LevelPresentation.calibrationTitle(DemoAudioData.stage(.on)),
                       "Ear level calibration for Qudelix-5K USB DAC")
    }

    func testVerdictTextsAndTones() {
        let (stage, level) = live()
        XCTAssertEqual(LevelPresentation.verdictText(stage: stage, level: level), "consistent with lossless (21.9 kHz)")
        XCTAssertEqual(LevelPresentation.verdictTone(stage: stage, level: level), .good)
        let (lossyStage, lossy) = live(.lossy)
        XCTAssertEqual(LevelPresentation.verdictText(stage: lossyStage, level: lossy), "lossy (cuts at 16.0 kHz)")
        XCTAssertEqual(LevelPresentation.verdictTone(stage: lossyStage, level: lossy), .caution)
        var pending = level
        pending.quality = nil
        XCTAssertEqual(LevelPresentation.verdictText(stage: stage, level: pending), "listening\u{2026}")
        XCTAssertEqual(LevelPresentation.verdictTone(stage: stage, level: pending), .neutral)
        let kinds: [(StreamQualityKind, String)] = [
            (.tooQuiet, "too quiet to judge"), (.noTreble, "no treble to judge"),
            (.lossyHigh, "lossy, high bitrate (19.0 kHz)"), (.hiRes, "hi-res content (19.0 kHz)"),
            (.natural, "rolls off naturally (19.0 kHz), can\u{2019}t judge")
        ]
        for (kind, text) in kinds {
            var next = level
            next.quality = StreamQuality(.natural(cutoffKHz: 19))
            next.quality?.kind = kind
            XCTAssertEqual(LevelPresentation.verdictText(stage: stage, level: next), text)
        }
    }

    func testVerdictWhenMeteringIsOffOrFailed() {
        let level = DemoAudioData.level(.live, now: now)
        XCTAssertEqual(LevelPresentation.verdictText(stage: DemoAudioData.stage(.off), level: level), "metering off")
        XCTAssertEqual(LevelPresentation.verdictText(stage: DemoAudioData.stage(.failure), level: level),
                       "metering didn\u{2019}t start")
        XCTAssertEqual(LevelPresentation.verdictTone(stage: DemoAudioData.stage(.off), level: level), .neutral)
    }

    func testBalanceAndAutoMatchTexts() {
        let (stage, level) = live()
        XCTAssertTrue(LevelPresentation.showsBalance(stage: stage, level: level))
        XCTAssertEqual(LevelPresentation.balanceText(level), "bass +1.2 \u{00B7} tilt \u{2212}0.4 dB/oct \u{00B7} presence +0.6")
        var off = level
        off.detectQuality = false
        XCTAssertFalse(LevelPresentation.showsBalance(stage: stage, level: off))
        XCTAssertEqual(LevelPresentation.balanceText(LevelModelState()), "listening\u{2026}")
        XCTAssertEqual(LevelPresentation.autoMatchStatus(level), "The audio graph is currently set to 44.1 kHz by Auto-match.")
        XCTAssertNil(LevelPresentation.autoMatchStatus(DemoAudioData.level(.lossy, now: now)))
        XCTAssertTrue(LevelPresentation.autoMatchExplanation.contains("whole audio graph"))
    }

    func testTrackingNote() {
        let (stage, level) = live()
        XCTAssertNil(LevelPresentation.trackingNote(stage: stage, level: level))
        XCTAssertTrue(LevelPresentation.trackingNote(stage: stage, level: DemoAudioData.level(.empty, now: now))!
            .contains("Nothing is recorded"))
        XCTAssertEqual(LevelPresentation.trackingNote(stage: DemoAudioData.stage(.on), level: level),
                       "Metering rides the Stage while it runs.")
    }

    func testTodayAndPreviousDays() {
        let (_, level) = live()
        let today = LevelPresentation.today(level, now: now)!
        let reading = LevelPresentation.todayReading(today)
        XCTAssertEqual(reading.listened, "1h 31m")
        XCTAssertEqual(reading.loud, "7m")
        XCTAssertEqual(reading.average, "-23 dBFS")
        XCTAssertFalse(reading.loudHighlight)
        let previous = LevelPresentation.previousDays(level: level, now: now)
        XCTAssertEqual(previous.count, 6)
        XCTAssertEqual(previous.first?.day, LevelModel.dayKey(now.addingTimeInterval(-86_400)))
        XCTAssertEqual(previous.map(\.audibleFraction).max()!, 1, accuracy: 1e-9)
        XCTAssertTrue(previous.allSatisfy { $0.audibleFraction <= 1 && $0.loudFraction <= $0.audibleFraction })
        XCTAssertEqual(LevelPresentation.previousTitle(1), "Previous 1 day")
        XCTAssertEqual(LevelPresentation.previousTitle(6), "Previous 6 days")
    }

    func testHistoryHeadlines() {
        XCTAssertEqual(LevelPresentation.historyHeadline(level: DemoAudioData.level(.live, now: now), now: now), "Today")
        XCTAssertEqual(LevelPresentation.historyHeadline(level: DemoAudioData.level(.idle, now: now), now: now),
                       "Nothing listened to today yet.")
        XCTAssertEqual(LevelPresentation.historyHeadline(level: DemoAudioData.level(.empty, now: now), now: now),
                       "Nothing recorded.")
        var paused = DemoAudioData.level(.live, now: now)
        paused.levelTracking = false
        XCTAssertEqual(LevelPresentation.historyHeadline(level: paused, now: now), "Paused: nothing new is being added.")
    }

    func testDurationAndShortDate() {
        XCTAssertEqual(LevelPresentation.duration(59), "59s")
        XCTAssertEqual(LevelPresentation.duration(61), "1m")
        XCTAssertEqual(LevelPresentation.duration(3_600), "1h 00m")
        XCTAssertEqual(LevelPresentation.duration(.nan), "0s")
        XCTAssertEqual(LevelPresentation.duration(-5), "0s")
        XCTAssertEqual(LevelPresentation.shortDate("2026-11-09"), "Nov 9")
        XCTAssertEqual(LevelPresentation.shortDate("garbage"), "garbage")
        XCTAssertEqual(LevelPresentation.shortDate("2026-13-01"), "2026-13-01")
    }

    func testDeletePromptWording() {
        XCTAssertEqual(LevelPresentation.historyDeleteTitle, "Delete all listening history?")
        XCTAssertTrue(LevelPresentation.historyDeleteMessage.contains("can\u{2019}t be brought back"))
    }

    func testFailureNotice() {
        XCTAssertNil(LevelPresentation.failureNotice(DemoAudioData.stage(.on)))
        XCTAssertNotNil(LevelPresentation.failureNotice(DemoAudioData.stage(.failure)))
    }
}

@MainActor
final class PreviewSeamTests: XCTestCase {
    func testPreviewReplacesWhatObserversSeeAndStaysSticky() throws {
        let rig = try StageRig()
        defer { rig.cleanUp() }
        var stageSeen: [StageModelState] = []
        var levelSeen: [LevelModelState] = []
        rig.model.addObserver { stageSeen.append($0) }
        rig.model.level.addObserver { levelSeen.append($0) }
        let stage = DemoAudioData.stage(.on)
        let level = DemoAudioData.level(.live)
        rig.model.showPreview(stage, level: level)
        XCTAssertEqual(stageSeen.last, stage)
        XCTAssertEqual(levelSeen.last, level)
        let count = stageSeen.count
        rig.model.setStage(StageSettings.theater)
        rig.model.meterTick()
        XCTAssertEqual(stageSeen.count, count)
        var late: StageModelState?
        rig.model.addObserver { late = $0 }
        XCTAssertEqual(late, stage)
    }

    func testDemoScenariosAreSelfConsistent() {
        let on = DemoAudioData.stage(.on)
        XCTAssertTrue(on.running)
        XCTAssertEqual(on.mode, .insert)
        XCTAssertTrue(on.settings.enabled)
        XCTAssertTrue(on.impulseInPath)
        XCTAssertNil(on.failure)
        let failed = DemoAudioData.stage(.failure)
        XCTAssertFalse(failed.running)
        XCTAssertNotNil(failed.failure)
        XCTAssertFalse(DemoAudioData.stage(.off).settings.enabled)
        let level = DemoAudioData.level(.live)
        XCTAssertEqual(level.exposureDays.count, 7)
        XCTAssertTrue(level.qualityMasterOn)
        XCTAssertNil(DemoAudioData.level(.empty).currentLevelDb)
        XCTAssertTrue(DemoAudioData.level(.empty).exposureDays.isEmpty)
    }
}
