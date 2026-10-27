import XCTest
@testable import QudelixBar

@MainActor
final class UIFixTests: XCTestCase {
    private func connected(bands: [QxEqBandValue]? = nil) -> QudelixController {
        let c = QudelixController()
        c.connection = .connected(name: "Qudelix 5K")
        c.compatibility = .ok
        c.eqEnabled = true
        if let bands { c.bands = bands }
        return c
    }

    private func curve() -> [QxEqBandValue] {
        QxEq.defaultFreqs.enumerated().map {
            QxEqBandValue(filter: .peak, freq: $1, gain: $0 == 3 ? 4.0 : 1.0, q: 1.0)
        }
    }

    func testNegativeZeroNeverPrints() {
        XCTAssertEqual(DisplayFormat.signed(-0.0), "+0.0")
        XCTAssertEqual(DisplayFormat.signed(-0.04), "+0.0")
        XCTAssertEqual(DisplayFormat.signed(-0.0, decimals: 2), "+0.00")
        XCTAssertEqual(DisplayFormat.decibels(-0.3, decimals: 0), "+0 dB")
        XCTAssertEqual(AutomationReadout.signed(-0.0), "+0.0")
    }

    func testRealNegativesUseTheTypographicMinus() {
        XCTAssertEqual(DisplayFormat.signed(-1.26), "\u{2212}1.3")
        XCTAssertEqual(DisplayFormat.signed(2), "+2.0")
        XCTAssertEqual(DisplayFormat.decibels(-3), "\u{2212}3.0 dB")
        XCTAssertEqual(DisplayFormat.signed(.nan), "\u{2014}")
    }

    func testAccessibleDecibelsSpeakTheUnitAndTheSign() {
        XCTAssertEqual(DisplayFormat.accessibleDecibels(3), "3.0 decibels")
        XCTAssertEqual(DisplayFormat.accessibleDecibels(-2.5), "minus 2.5 decibels")
        XCTAssertEqual(DisplayFormat.accessibleDecibels(-0.0), "0.0 decibels")
    }

    func testTheZeroLineIsAlwaysDrawn() {
        for range in stride(from: 9.0, through: 18.0, by: 3.0) {
            XCTAssertTrue(EQCurveView.gridLevels(range: range).contains(0), "range \(range)")
        }
        XCTAssertEqual(EQCurveView.gridLevels(range: 15), [-9, -3, 0, 3, 9])
        XCTAssertEqual(EQCurveView.gridLevels(range: 12), [-6, 0, 6])
    }

    func testCurveSummaryNamesThePeakAndTheSelection() {
        let summary = EQCurveView.accessibilitySummary(
            bands: curve(), preGain: -4, enabled: true, selected: 3)
        XCTAssertTrue(summary.contains("Peak boost 4.0 decibels at"), summary)
        XCTAssertTrue(summary.contains("pre-gain minus 4.0 decibels"), summary)
        XCTAssertTrue(summary.contains("band 4 selected"), summary)
        XCTAssertEqual(EQCurveView.accessibilitySummary(
            bands: curve(), preGain: 0, enabled: false, selected: nil), "Equalizer is off")
        let flat = QxEq.defaultFreqs.map { QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1) }
        XCTAssertEqual(EQCurveView.accessibilitySummary(
            bands: flat, preGain: 0, enabled: true, selected: nil), "No band boost")
    }

    func testReferenceSourceLabelsDoNotCollideWithTheFitAction() {
        XCTAssertEqual(ReferenceSource.auto.label, "Auto")
        XCTAssertEqual(ReferenceSource.catalog.label, "AutoEq")
        XCTAssertEqual(ReferenceSource.listening.label, "Listening")
        XCTAssertTrue(AutomationPanel.title(.catalog).hasPrefix("AutoEq"))
        XCTAssertFalse(AutomationPanel.title(.auto).contains("catalog"))
        let texts = AutomationReadout.referenceTexts(
            source: .catalog, reference: nil, trim: .zero, autoTrimOn: false, mode: .clarity)
        XCTAssertTrue(texts.allSatisfy { $0.hasPrefix("AutoEq") })
    }

    func testKeepHelpSaysItTurnsAutoTrimOffWheneverItWasOn() {
        XCTAssertTrue(AutomationPanel.keepHelp.contains("Auto-trim off if it is on"))
        XCTAssertFalse(AutomationPanel.keepHelp.contains("listening reference"))
    }

    func testEqControlsFollowTheControllerGateAndTheSession() {
        let c = connected()
        XCTAssertTrue(c.eqControlsEnabled)
        XCTAssertNil(c.eqControlsHelp)
        c.beginEqSession()
        XCTAssertFalse(c.eqControlsEnabled)
        XCTAssertTrue(c.canEditEqNow)
        XCTAssertEqual(c.eqControlsHelp, QudelixController.tuningSessionHelp)
        c.endEqSession()
        XCTAssertTrue(c.eqControlsEnabled)
        c.connection = .disconnected
        XCTAssertFalse(c.eqControlsEnabled)
    }

    func testTuneOpensTrimOnlyWhileATrimSessionOrResultShows() {
        func opening(tones: ToneTester.Phase = .idle, tuner: ABTuner.Phase = .idle,
                     blind: BlindTuner.Phase = .idle, mode: BlindTuner.Mode = .trim,
                     stored: TuneView.Method) -> TuneView.Method {
            TuneView.Method.opening(tones: tones, tuner: tuner, blind: blind,
                                    blindMode: mode, stored: stored)
        }
        XCTAssertEqual(opening(stored: .shape), .shape)
        XCTAssertEqual(opening(stored: .compare), .compare)
        XCTAssertEqual(opening(blind: .running, stored: .compare), .trim)
        XCTAssertEqual(opening(blind: .finished, stored: .compare), .trim)
        XCTAssertEqual(opening(blind: .running, mode: .bypass, stored: .compare), .check)
        XCTAssertEqual(opening(blind: .running, mode: .shape, stored: .compare), .shape)
        XCTAssertEqual(opening(tuner: .running, stored: .shape), .compare)
        XCTAssertEqual(opening(tones: .running, stored: .shape), .tones)
    }

    func testTheTooltipSaysAutoFitWhileFollowing() {
        XCTAssertEqual(StatusIconModel.presetLine(label: "Warm", following: false), "Preset: Warm")
        XCTAssertEqual(StatusIconModel.presetLine(label: nil, following: false), "Preset: custom")
        XCTAssertEqual(StatusIconModel.presetLine(label: "Warm", following: true),
                       "Preset: Warm \u{00B7} Auto-fit")
    }

    func testTheAIOverwriteRowSaysAnEmptySlotIsEmpty() {
        XCTAssertTrue(AIPresetSection.overwriteCopy(slot: 2, name: nil).contains("is empty"))
        let named = AIPresetSection.overwriteCopy(slot: 2, name: "Warm")
        XCTAssertTrue(named.contains("Warm"))
        XCTAssertFalse(named.contains("is empty"))
    }

    func testAnEndedSessionStopsACompareWithoutRestoringTheBaseline() {
        let c = connected(bands: curve())
        let tuner = ABTuner()
        tuner.start(c)
        XCTAssertEqual(tuner.phase, .running)
        let trial = c.bands
        c.endEqSession()
        tuner.abandon(c)
        XCTAssertEqual(tuner.phase, .idle)
        XCTAssertNotNil(tuner.note)
        XCTAssertEqual(c.bands, trial)
    }

    func testAnEndedSessionStopsABlindRunWithoutRestoringTheBaseline() {
        let c = connected(bands: curve())
        let blind = BlindTuner()
        blind.start(c, mode: .shape)
        XCTAssertEqual(blind.phase, .running)
        let trial = c.bands
        c.endEqSession()
        blind.abandon(c)
        XCTAssertEqual(blind.phase, .idle)
        XCTAssertNotNil(blind.note)
        XCTAssertEqual(c.bands, trial)
    }

    func testAbandonLeavesALiveSessionAlone() {
        let c = connected(bands: curve())
        let tuner = ABTuner()
        tuner.start(c)
        tuner.abandon(c)
        XCTAssertEqual(tuner.phase, .running)
        XCTAssertTrue(c.byEarSessionActive)
        tuner.cancel(c)
    }
}
