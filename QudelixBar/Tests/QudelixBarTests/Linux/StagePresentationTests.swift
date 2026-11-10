import XCTest
@testable import QudelixBar

@MainActor
final class StagePresentationTests: XCTestCase {
    private func state(_ configure: (inout StageModelState) -> Void = { _ in }) -> StageModelState {
        var state = DemoAudioData.stage(.on)
        configure(&state)
        return state
    }

    func testEveryControlRoundTripsItsOwnDisplayedValue() {
        for control in StageControl.allCases {
            var settings = StageSettings.music
            let target = control.quantized((control.range.lowerBound + control.range.upperBound) / 2 + control.step * 0.3)
            control.apply(target, to: &settings)
            XCTAssertEqual(control.value(settings), target, accuracy: 1e-9, "\(control)")
            XCTAssertFalse(control.display(settings).isEmpty)
        }
    }

    func testApplyClampsAndSnapsLikeTheMacSliders() {
        var settings = StageSettings.music
        StageControl.width.apply(260.4, to: &settings)
        XCTAssertEqual(settings.width, 200)
        StageControl.dialogue.apply(2.3, to: &settings)
        XCTAssertEqual(settings.dialogue, 2.5)
        StageControl.balanceLevel.apply(-1.234, to: &settings)
        XCTAssertEqual(settings.balanceDbValue, -1.2, accuracy: 1e-9)
        StageControl.balanceTime.apply(0.337, to: &settings)
        XCTAssertEqual(settings.alignMsValue, 0.34, accuracy: 1e-9)
        StageControl.crossfeed.apply(41.6, to: &settings)
        XCTAssertEqual(settings.crossfeed, 0.42, accuracy: 1e-9)
        StageControl.center.apply(-9, to: &settings)
        XCTAssertEqual(settings.centerValue, -6)
    }

    func testDisplaysMatchTheMacWording() {
        var settings = StageSettings.music
        XCTAssertEqual(StageControl.balanceLevel.display(settings), "centered")
        XCTAssertEqual(StageControl.balanceTime.display(settings), "aligned")
        StageControl.balanceLevel.apply(1.5, to: &settings)
        StageControl.balanceTime.apply(-0.25, to: &settings)
        XCTAssertEqual(StageControl.balanceLevel.display(settings), "R +1.5 dB")
        XCTAssertEqual(StageControl.balanceTime.display(settings), "L +0.25 ms")
        XCTAssertEqual(StageControl.width.display(settings), "115 %")
        XCTAssertEqual(StageControl.dialogue.display(settings), "+0.0 dB")
        StageControl.center.apply(-1.5, to: &settings)
        XCTAssertEqual(StageControl.center.display(settings), "\u{2212}1.5 dB")
    }

    func testResetNeutralValuesAreCenteredForBalanceOnly() {
        XCTAssertTrue(StageControl.balanceLevel.hasReset)
        XCTAssertTrue(StageControl.balanceTime.hasReset)
        XCTAssertFalse(StageControl.width.hasReset)
        var settings = StageSettings.music
        StageControl.balanceLevel.apply(2, to: &settings)
        StageControl.balanceLevel.apply(StageControl.balanceLevel.neutral, to: &settings)
        XCTAssertEqual(settings.balanceDbValue, 0)
    }

    func testGroupsCoverEveryControlExceptTheDynamicsAndImpulseOnes() {
        let grouped = StageControlGroup.allCases.flatMap { StageControl.controls(in: $0) }
        XCTAssertEqual(Set(grouped).count, grouped.count)
        let rest = Set(StageControl.allCases).subtracting(grouped)
        XCTAssertEqual(rest, [.loudnessStrength, .bassGuardStrength, .impulseMix])
    }

    func testPresetSelectionFollowsTheSettings() {
        XCTAssertTrue(StagePresetChoice.music.isSelected(.music))
        XCTAssertFalse(StagePresetChoice.movie.isSelected(.music))
        var off = StageSettings.theater
        off.enabled = false
        XCTAssertFalse(StagePresetChoice.theater.isSelected(off))
    }

    func testOutputLabelNamesTheOutputOrSaysThereIsNone() {
        XCTAssertEqual(StagePresentation.outputLabel(state()), "Settings for Qudelix-5K USB DAC")
        XCTAssertEqual(StagePresentation.outputLabel(state { $0.outputDescription = nil }),
                       StagePresentation.noOutput)
        XCTAssertTrue(StagePresentation.perOutputNote(state()).contains("Qudelix-5K USB DAC only"))
        XCTAssertTrue(StagePresentation.perOutputNote(state { $0.outputDescription = nil }).contains("Connect or select"))
    }

    func testRoutingExplanationNamesTheStageOutputAndTheRealOutput() {
        let text = StagePresentation.routingExplanation(state())
        XCTAssertTrue(text.contains("\u{201C}Qudelix Stage\u{201D}"))
        XCTAssertTrue(text.contains("system default"))
        XCTAssertTrue(text.contains("Qudelix-5K USB DAC"))
        XCTAssertTrue(text.contains("restored"))
        XCTAssertTrue(text.hasPrefix("Stage is active."))
        XCTAssertFalse(StagePresentation.routingExplanation(DemoAudioData.stage(.off)).hasPrefix("Stage is active."))
    }

    func testNoticesCoverSettingsFailureImpulseAndMono() {
        XCTAssertTrue(StagePresentation.notices(DemoAudioData.stage(.off)).isEmpty)
        var shown = StagePresentation.notices(state())
        XCTAssertEqual(shown.count, 1)
        XCTAssertFalse(shown[0].caution)
        XCTAssertTrue(shown[0].text.hasPrefix("Stage active"))
        shown = StagePresentation.notices(state {
            $0.settingsNotice = "stage.json could not be read and was left alone."
            $0.impulseState = .refused("Unsupported WAV format")
            $0.sourceCorrelation = 0.99
        })
        XCTAssertEqual(shown.map(\.caution), [true, false, true, true])
        XCTAssertEqual(shown[0].text, "stage.json could not be read and was left alone.")
        XCTAssertEqual(shown[2].text, "Unsupported WAV format")
        XCTAssertEqual(shown[3].text, StagePresentation.mono)
        let failed = StagePresentation.notices(DemoAudioData.stage(.failure))
        XCTAssertEqual(failed.count, 1)
        XCTAssertTrue(failed[0].caution)
        XCTAssertTrue(failed[0].text.contains("default output"))
    }

    func testStatusNoticeHandlesCallHoldAndMissingOutput() {
        let held = state {
            $0.running = false
            $0.callHold = true
            $0.status = "Paused for a call \u{2014} resumes when the call ends."
        }
        XCTAssertEqual(StagePresentation.statusNotice(held)?.caution, false)
        let missing = state {
            $0.running = false
            $0.outputKey = nil
            $0.status = "Off."
        }
        XCTAssertEqual(StagePresentation.statusNotice(missing)?.caution, true)
        let quiet = state {
            $0.running = false
            $0.status = "Off."
        }
        XCTAssertNil(StagePresentation.statusNotice(quiet))
    }

    func testBandTrimSummaryAppearsOnlyWhenATrimMoved() {
        XCTAssertNil(StagePresentation.bandTrimSummary(.music))
        var settings = StageSettings.music
        settings.crossLowTrim = 0.6
        XCTAssertEqual(StagePresentation.bandTrimSummary(settings), "60 / 100 / 100 %")
    }

    func testLimiterNoteReportsLatencyAtTheRunningRate() {
        let note = StagePresentation.limiterNote(state())
        XCTAssertTrue(note.contains("64 samples"))
        XCTAssertTrue(note.contains("1.3 ms at 48 kHz"))
        let fast = StagePresentation.limiterNote(state { $0.runningRate = 96000 })
        XCTAssertTrue(fast.contains("0.7 ms at 96 kHz"))
        XCTAssertTrue(StagePresentation.limiterNote(DemoAudioData.stage(.off)).hasPrefix("Stage is off."))
    }

    func testLoudnessNoteExplainsWhyItHoldsFlat() {
        var level = LevelModelState()
        XCTAssertTrue(StagePresentation.loudnessNote(state(), level: level).contains("no volume reading"))
        level.earAnchor = .qudelix(-20)
        XCTAssertTrue(StagePresentation.loudnessNote(state(), level: level).contains("settles"))
        level.earLevelAverageDb = 80
        XCTAssertTrue(StagePresentation.loudnessNote(state(), level: level).contains("measured before this shelf"))
        XCTAssertFalse(StagePresentation.loudnessNote(state { $0.running = false }, level: level).contains("Holding"))
    }

    func testAmountsAndBassGuardWording() {
        XCTAssertEqual(StagePresentation.loudnessAmount(state()), "+3.2 dB bass")
        XCTAssertEqual(StagePresentation.loudnessAmount(state { $0.loudnessShelfDb = 0 }), "flat")
        XCTAssertEqual(StagePresentation.bassGuardAmount(state()), "\u{2212}1.1 dB")
        XCTAssertEqual(StagePresentation.bassGuardAmount(state { $0.bassGuardGainReductionDb = 0 }),
                       "up to \u{2212}4.5 dB")
        let inert = state { $0.bassGuardBoostDb = 0 }
        XCTAssertTrue(StagePresentation.bassGuardNote(inert).hasPrefix("Nothing to guard"))
        XCTAssertTrue(StagePresentation.bassGuardNote(state()).hasPrefix("Eases the low band"))
    }

    func testImpulseDetailAndNotes() {
        let detail = StagePresentation.impulseDetail(state())
        XCTAssertEqual(detail, "0.62 s \u{00B7} stereo, one per side \u{00B7} 48 kHz file \u{00B7} 4 \u{00D7} 1024 at 48 kHz")
        XCTAssertNil(StagePresentation.impulseDetail(DemoAudioData.stage(.off)))
        XCTAssertEqual(StagePresentation.impulseTitle(state()), "Small studio room")
        XCTAssertEqual(StagePresentation.impulseTitle(DemoAudioData.stage(.off)), "None")
        let note = StagePresentation.impulseNote(state())
        XCTAssertTrue(note.contains("WAV files only"))
        XCTAssertTrue(note.contains("2 seconds"))
    }
}
