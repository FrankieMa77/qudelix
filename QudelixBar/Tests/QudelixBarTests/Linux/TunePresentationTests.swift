import XCTest
@testable import QudelixBar

@MainActor
final class TunePresentationTests: XCTestCase {
    private func screen(_ scenario: DemoTuneScenario) -> TuneScreen {
        TunePresentation.screen(scenario.method, DemoTuneData.state(scenario))
    }

    func testMethodTitlesFollowTheMacOrder() {
        XCTAssertEqual(TuneMethod.allCases.map(TunePresentation.title),
                       ["Compare", "Shape", "Tones", "Blind", "Trim"])
        for method in TuneMethod.allCases {
            XCTAssertFalse(TunePresentation.summary(method).isEmpty)
            XCTAssertTrue(TunePresentation.accessibleName(method).hasSuffix("method"))
        }
    }

    func testEveryScenarioProducesAHeadlineAndTheRightButtons() {
        for scenario in DemoTuneScenario.allCases {
            let result = screen(scenario)
            XCTAssertFalse(result.headline.isEmpty, "\(scenario)")
            switch result.phase {
            case .idle:
                XCTAssertTrue(result.startEnabled == (result.blocker == nil), "\(scenario)")
                XCTAssertNil(result.keepLabel)
            case .running:
                XCTAssertTrue(result.canListenAndChoose)
                XCTAssertEqual(result.discardLabel, "Stop")
                XCTAssertFalse(result.progressText.isEmpty)
            case .finished:
                XCTAssertFalse(result.discardLabel.isEmpty)
            }
        }
    }

    func testProgressTextClampsAtTheLastTrial() {
        XCTAssertEqual(TunePresentation.trialText(done: 0, total: 20), "1 / 20")
        XCTAssertEqual(TunePresentation.trialText(done: 19, total: 20), "20 / 20")
        XCTAssertEqual(TunePresentation.trialText(done: 20, total: 20), "20 / 20")
        let running = screen(.compareRunning)
        XCTAssertEqual(running.progressText, "7 / 20")
        XCTAssertEqual(running.progressFraction, 0.3, accuracy: 1e-9)
        XCTAssertEqual(running.playingLabel, "B")
    }

    func testConsistencyChecksReadLikeTheMac() {
        XCTAssertEqual(TunePresentation.sanityCheck(pairs: 1, guesses: 0),
                       "Sanity check: 1 pair was the same setting twice; you called a winner in 0.")
        XCTAssertEqual(TunePresentation.sanityCheck(pairs: 4, guesses: 1),
                       "Sanity check: 4 pairs were the same setting twice; you called a winner in 1.")
        XCTAssertTrue(TunePresentation.shapeConsistency(pairs: 3, guesses: 0, skipped: 1)
            .hasSuffix("1 step too small for the device to store"))
        XCTAssertTrue(TunePresentation.shapeConsistency(pairs: 3, guesses: 0, skipped: 2)
            .hasSuffix("2 steps too small for the device to store"))
        XCTAssertEqual(TunePresentation.catchSummary(played: 1, falsePresses: 1), "1 silent check, 1 press on silence")
        XCTAssertEqual(TunePresentation.catchSummary(played: 3, falsePresses: 2), "3 silent checks, 2 presses on silence")
    }

    func testCompareResultListsEveryMacroAndMarksInaudibleOnes() {
        let result = screen(.compareFinished)
        XCTAssertEqual(result.rows.map(\.title), ["Bass", "Warmth", "Presence", "Treble"])
        XCTAssertEqual(result.rows[0].value, "+3.0")
        XCTAssertEqual(result.rows[0].fraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result.rows[1].fraction, -1.5 / 4, accuracy: 1e-9)
        XCTAssertTrue(result.rows[2].muted)
        XCTAssertEqual(result.rows[2].value, "\u{2014}")
        XCTAssertEqual(result.keepLabel, "Keep")
        XCTAssertEqual(result.discardLabel, "Discard")
        XCTAssertTrue(result.cautions.isEmpty)
    }

    func testPoorConsistencyAddsTheWeakResultCaution() {
        var state = DemoTuneData.state(.compareFinished)
        state.compare.verdict = .unreliable
        state.compare.maxMovement = 0.4
        let result = TunePresentation.screen(.compare, state)
        XCTAssertEqual(result.cautions.count, 1)
        XCTAssertTrue(result.footnotes.contains { $0.hasPrefix("Within a decibel") })
    }

    func testShapeResultVerdictsChangeHeadlineAndButtons() {
        let usable = screen(.shapeFinished)
        XCTAssertEqual(usable.headline, "The shape you preferred")
        XCTAssertEqual(usable.rows.map(\.title), ["Bass", "Presence", "Tilt"])
        XCTAssertEqual(usable.rows[0].value, "+2.5 dB")
        XCTAssertEqual(usable.rows[2].value, "+0.5 dB/oct")
        XCTAssertEqual(usable.keepLabel, "Keep")
        var state = DemoTuneData.state(.shapeFinished)
        state.shape.verdict = .unreliable
        let bad = TunePresentation.screen(.shape, state)
        XCTAssertEqual(bad.headline, "Can't trust this run")
        XCTAssertTrue(bad.rowsDimmed)
        XCTAssertNil(bad.keepLabel)
        XCTAssertEqual(bad.discardLabel, "Close")
        state.shape.verdict = .nothingAudible
        let flat = TunePresentation.screen(.shape, state)
        XCTAssertNil(flat.keepLabel)
        XCTAssertEqual(flat.discardLabel, "Close")
    }

    func testBlindAndTrimResultsNameTheSidesAndNeverOfferKeep() {
        let blind = screen(.blindFinished)
        XCTAssertEqual(blind.headline, "You preferred your EQ in 4 of 5")
        XCTAssertEqual(blind.paragraphs.first, "4 for your EQ \u{00B7} 1 for flat \u{00B7} 0 sounded the same")
        XCTAssertNil(blind.keepLabel)
        let trim = screen(.trimFinished)
        XCTAssertEqual(trim.headline, "You preferred your EQ as it is in 3 of 5")
        XCTAssertEqual(trim.paragraphs.first, "1 for the trim \u{00B7} 3 for your EQ \u{00B7} 1 sounded the same")
        XCTAssertNil(trim.keepLabel)
        var state = DemoTuneData.state(.blindFinished)
        state.check.outcome = .noneSurvived(eq: 2, flat: 2, same: 1)
        XCTAssertEqual(TunePresentation.screen(.check, state).headline, "No clear preference in 5")
    }

    func testToneRunningAndResults() {
        let running = screen(.tonesRunning)
        XCTAssertEqual(running.headline, "2 kHz")
        XCTAssertEqual(running.progressText, "1 / 10 done")
        XCTAssertTrue(running.isTones)
        let done = screen(.tonesFinished)
        XCTAssertEqual(done.rows.count, 10)
        XCTAssertEqual(done.rows[0].value, "no reading")
        XCTAssertEqual(done.rows[1].title, "63")
        XCTAssertEqual(done.rows[1].value, "EQ \u{2212}4.0")
        XCTAssertEqual(done.rows.last?.title, "16k")
        XCTAssertEqual(done.keepLabel, "Apply suggestion")
        XCTAssertEqual(done.catchSummary, "3 silent checks, 0 presses on silence")
        let bad = screen(.tonesUnreliable)
        XCTAssertNil(bad.keepLabel)
        XCTAssertTrue(bad.rowsDimmed)
        XCTAssertEqual(bad.discardLabel, "Close")
        var state = DemoTuneData.state(.tonesFinished)
        state.tones.verdict = .tooFewReadings
        state.tones.readingCount = 3
        let few = TunePresentation.screen(.tones, state)
        XCTAssertTrue(few.rows.isEmpty)
        XCTAssertTrue(few.paragraphs[0].hasPrefix("3 of the 10 frequencies"))
        state.tones.verdict = .tooScattered(31.6)
        XCTAssertTrue(TunePresentation.screen(.tones, state).paragraphs[0].contains("32 dB apart"))
        state.tones.verdict = .usable
        state.tones.falseAlarmsElevated = true
        XCTAssertEqual(TunePresentation.screen(.tones, state).cautions.count, 1)
    }

    func testBlockersReplaceTheFootnoteAndDisableStart() {
        let blocked = screen(.tonesBlocked)
        XCTAssertEqual(blocked.blocker, "Sound is going to Built-in Audio Analog Stereo. Choose the Qudelix as the output device.")
        XCTAssertFalse(blocked.startEnabled)
        XCTAssertTrue(blocked.footnotes.isEmpty)
        let open = screen(.tonesIdle)
        XCTAssertTrue(open.startEnabled)
        XCTAssertEqual(open.footnotes.count, 1)
        var state = TuneState()
        state.busy = TuneModel.busyText
        let busy = TunePresentation.screen(.shape, state)
        XCTAssertEqual(busy.blocker, TuneModel.busyText)
        XCTAssertFalse(busy.startEnabled)
        let compare = screen(.compareBlocked)
        XCTAssertEqual(compare.blocker, ABTuner.Blocker.eqOff.message)
        XCTAssertEqual(TunePresentation.screen(.tones, DemoTuneData.state(.compareBlocked)).startEnabled, true)
    }

    func testTrimIntroShowsTheCurrentTrimOnlyWhenNotBlocked() {
        let open = screen(.trimIdle)
        XCTAssertTrue(open.paragraphs.contains { $0.hasPrefix("Trim now: bass +0.5") })
        var state = DemoTuneData.state(.trimIdle)
        state.blockers[.trim] = BlindTuner.Blocker.trimOff.message
        let blocked = TunePresentation.screen(.trim, state)
        XCTAssertFalse(blocked.paragraphs.contains { $0.hasPrefix("Trim now") })
    }

    func testInterruptionNotesComeWithTheRestoreLine() {
        let compare = screen(.interrupted)
        XCTAssertEqual(compare.cautions, ["Comparison stopped \u{2014} the 5K disconnected."])
        XCTAssertEqual(compare.restoreLine, TunePresentation.restoreText)
        let tones = screen(.toneInterrupted)
        XCTAssertEqual(tones.restoreLine, TunePresentation.restoreText)
        var state = TuneState()
        state.tones.note = "Couldn't start the tone player, so nothing was measured. Try again."
        let failed = TunePresentation.screen(.tones, state)
        XCTAssertEqual(failed.cautions.count, 1)
        XCTAssertNil(failed.restoreLine)
    }

    func testSpaceTogglesTheSideOrReportsAToneAndNothingElse() {
        let space = TunePresentation.spaceKey
        XCTAssertEqual(TunePresentation.keyAction(keyval: space, modified: false, state: DemoTuneData.state(.compareRunning)), .toggleSide)
        XCTAssertEqual(TunePresentation.keyAction(keyval: space, modified: false, state: DemoTuneData.state(.shapeRunning)), .toggleSide)
        XCTAssertEqual(TunePresentation.keyAction(keyval: space, modified: false, state: DemoTuneData.state(.blindRunning)), .toggleSide)
        XCTAssertEqual(TunePresentation.keyAction(keyval: space, modified: false, state: DemoTuneData.state(.trimRunning)), .toggleSide)
        XCTAssertEqual(TunePresentation.keyAction(keyval: space, modified: false, state: DemoTuneData.state(.tonesRunning)), .heard)
        XCTAssertNil(TunePresentation.keyAction(keyval: space, modified: true, state: DemoTuneData.state(.compareRunning)))
        XCTAssertNil(TunePresentation.keyAction(keyval: 0x61, modified: false, state: DemoTuneData.state(.compareRunning)))
        XCTAssertNil(TunePresentation.keyAction(keyval: space, modified: false, state: DemoTuneData.state(.compareFinished)))
        XCTAssertNil(TunePresentation.keyAction(keyval: space, modified: false, state: TuneState()))
    }

    func testAccessibleRowNamesIncludeTheValue() {
        let row = TuneRow(title: "Bass", detail: "31\u{2013}250 Hz", value: "+3.0", fraction: 0.5, muted: false, hasBar: true)
        XCTAssertEqual(TunePresentation.accessibleRow(row), "Bass, 31\u{2013}250 Hz, +3.0")
        let plain = TuneRow(title: "63", detail: "", value: "no reading", fraction: 0, muted: true, hasBar: false)
        XCTAssertEqual(TunePresentation.accessibleRow(plain), "63, no reading")
    }

    func testPreviewSeamPublishesToObserversAndSuppressesLiveUpdates() async throws {
        let rig = try await AutoRig()
        let tune = TuneModel(app: rig.app, routing: rig.stageRig?.routing, backend: rig.stageRig?.backend,
                             stage: rig.stageRig?.model, automation: rig.automation)
        var seen: [TuneState] = []
        tune.addObserver { seen.append($0) }
        let preview = DemoTuneData.state(.shapeRunning)
        tune.showPreview(preview)
        XCTAssertEqual(seen.last, preview)
        XCTAssertEqual(tune.state, preview)
        tune.start(.compare, seed: 3)
        XCTAssertEqual(tune.state, preview)
        await rig.close()
    }

    func testLiveSessionStateDrivesTheScreen() async throws {
        let rig = try await AutoRig()
        let tune = TuneModel(app: rig.app, routing: rig.stageRig?.routing, backend: rig.stageRig?.backend,
                             stage: rig.stageRig?.model, automation: rig.automation)
        tune.start(.compare, seed: 5)
        await rig.settle()
        let running = TunePresentation.screen(.compare, tune.state)
        XCTAssertEqual(running.phase, .running)
        XCTAssertEqual(running.progressText, "1 / 20")
        XCTAssertEqual(running.playingLabel, "A")
        XCTAssertEqual(TunePresentation.keyAction(keyval: TunePresentation.spaceKey, modified: false, state: tune.state), .toggleSide)
        tune.toggleSide()
        XCTAssertEqual(TunePresentation.screen(.compare, tune.state).playingLabel, "B")
        tune.cancel()
        await rig.settle()
        XCTAssertEqual(TunePresentation.screen(.compare, tune.state).phase, .idle)
        await rig.close()
    }
}
