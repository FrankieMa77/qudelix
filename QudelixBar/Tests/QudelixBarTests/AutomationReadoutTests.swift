import XCTest
@testable import QudelixBar

@MainActor
final class AutomationReadoutTests: XCTestCase {
    private func band(_ f: Int, _ g: Double) -> QxEqBandValue {
        QxEqBandValue(filter: .peak, freq: f, gain: g, q: 1)
    }

    private var user: [QxEqBandValue] { [band(100, 2), band(1000, -1), band(8000, 3)] }

    private func curve() -> ReferenceCurve {
        var file = ParametricEQFile()
        file.bands = [band(100, 4), band(1000, 0), band(8000, 1)]
        file.preamp = -4
        return ReferenceCurve(file: file, source: "oratory1990", headphone: "Alder AR-5")
    }

    private var trim: TrimGains { TrimGains(bassDb: 1, tiltDbPerOctave: -0.3, presenceDb: 0.5, airDb: 0) }

    func testNothingIsDrawnWhenEverythingIsOffAndThereIsNoReference() {
        let lines = AutomationReadout.lines(.init(userBands: user))
        XCTAssertNil(lines.reference)
        XCTAssertNil(lines.trim)
    }

    func testACatalogReferenceIsDrawnAsItsOwnBands() {
        let lines = AutomationReadout.lines(.init(source: .catalog, reference: curve(),
                                                  userBands: user))
        XCTAssertEqual(lines.reference?.bands, curve().bands)
        XCTAssertEqual(lines.reference?.offsetDb, 0)
        XCTAssertNil(lines.trim)
    }

    func testHidingTheReferenceHidesItsLine() {
        let lines = AutomationReadout.lines(.init(showReference: false, source: .catalog,
                                                  reference: curve(), userBands: user))
        XCTAssertNil(lines.reference)
    }

    func testTrimIsFoldedIntoTheCatalogLineAndNotDrawnTwice() {
        let lines = AutomationReadout.lines(.init(source: .catalog, reference: curve(),
                                                  userBands: user, trim: trim,
                                                  autoTrimOn: true))
        XCTAssertEqual(lines.reference?.bands.count, curve().bands.count + trim.bands.count)
        XCTAssertNil(lines.trim)
    }

    func testTheListeningLineNeedsAnActiveTrim() {
        var input = AutomationReadout.Inputs(source: .listening, userBands: user, autoTrimOn: true)
        XCTAssertNil(AutomationReadout.lines(input).reference)
        input.trim = trim
        XCTAssertEqual(AutomationReadout.lines(input).reference?.bands.count,
                       user.count + trim.bands.count)
    }

    func testTheTrimLineShowsOnlyWhenNoReferenceLineIsAndNothingIsFollowing() {
        var input = AutomationReadout.Inputs(showReference: false, source: .listening,
                                             userBands: user, trim: trim, autoTrimOn: true)
        XCTAssertNotNil(AutomationReadout.lines(input).trim)
        input.following = true
        XCTAssertNil(AutomationReadout.lines(input).trim)
        input.following = false
        input.autoTrimOn = false
        XCTAssertNil(AutomationReadout.lines(input).trim)
    }

    func testTheLinesRespondOverTheSameGridAsTheAppliedCurve() {
        let lines = AutomationReadout.lines(.init(source: .catalog, reference: curve(),
                                                  userBands: user, trim: trim, autoTrimOn: true))
        XCTAssertEqual(lines.reference?.response().count,
                       EQCurve.response(bands: user, preGain: 0).count)
    }

    func testReferenceTextsNameTheFitOrSayNoneExists() {
        XCTAssertEqual(AutomationReadout.referenceTexts(source: .catalog, reference: nil,
                                                        trim: .zero, autoTrimOn: false,
                                                        mode: .clarity).last,
                       "catalog \u{2014} none yet")
        let named = AutomationReadout.referenceTexts(source: .auto, reference: curve(),
                                                     trim: .zero, autoTrimOn: false,
                                                     mode: .clarity)
        XCTAssertEqual(named.first, "Alder AR-5 \u{00B7} oratory1990")
    }

    func testListeningTextsExplainWhyThereIsNothingToFollow() {
        func texts(on: Bool, mode: TrimMode, trim: TrimGains) -> [String] {
            AutomationReadout.referenceTexts(source: .listening, reference: nil,
                                             trim: trim, autoTrimOn: on, mode: mode)
        }
        XCTAssertTrue(texts(on: false, mode: .clarity, trim: .zero)[0].contains("Auto-trim is off"))
        XCTAssertTrue(texts(on: true, mode: .audiophile, trim: .zero)[0].contains("audiophile"))
        XCTAssertEqual(texts(on: true, mode: .clarity, trim: .zero), ["listening\u{2026}"])
        XCTAssertTrue(texts(on: true, mode: .clarity, trim: trim)[0].contains("bass +1.0"))
    }

    func testTheFollowNotePrefersPausedThenWaitingThenDeviation() {
        XCTAssertTrue(AutomationReadout.followNote(following: false, paused: true,
                                                   waitingReason: "x", deviationDb: 2,
                                                   referenceActive: true)!.hasPrefix("Paused"))
        XCTAssertEqual(AutomationReadout.followNote(following: true, paused: false,
                                                    waitingReason: "Connect the 5K",
                                                    deviationDb: nil, referenceActive: true),
                       "Connect the 5K")
        XCTAssertEqual(AutomationReadout.followNote(following: true, paused: false,
                                                    waitingReason: nil, deviationDb: 0.84,
                                                    referenceActive: true),
                       "Auto-fit is following the line \u{2014} 0.8 dB off")
        XCTAssertEqual(AutomationReadout.followNote(following: true, paused: false,
                                                    waitingReason: nil, deviationDb: nil,
                                                    referenceActive: false),
                       "Auto-trim is moving the gains")
        XCTAssertNil(AutomationReadout.followNote(following: false, paused: false,
                                                  waitingReason: nil, deviationDb: nil,
                                                  referenceActive: false))
    }

    func testTrimLinesCoverOffNoDetectionLearningAndSettledStates() {
        let learning = BalanceBaseline(readings: 240)
        let learned = BalanceBaseline(readings: 900)
        XCTAssertEqual(AutomationReadout.trimLines(on: false, detecting: true, mode: .clarity,
                                                   trim: .zero, baseline: learned).count, 1)
        XCTAssertTrue(AutomationReadout.trimLines(on: true, detecting: false, mode: .clarity,
                                                  trim: .zero, baseline: learned)[0]
            .contains("Detect stream quality"))
        XCTAssertTrue(AutomationReadout.trimLines(on: true, detecting: true, mode: .clarity,
                                                  trim: trim, baseline: learning)[0]
            .contains("learning (12 min)"))
        XCTAssertTrue(AutomationReadout.trimLines(on: true, detecting: true, mode: .clarity,
                                                  trim: trim, baseline: learned)[0]
            .contains("usual balance"))
    }

    func testTheBalanceReadingFormatsSignsAndWaits() {
        XCTAssertEqual(AutomationReadout.balanceText(nil), "listening\u{2026}")
        XCTAssertEqual(AutomationReadout.balanceText(BalanceFeatures(bassDb: 1.4,
                                                                      tiltDbPerOctave: -2.6,
                                                                      presenceDb: -0.7)),
                       "bass +1.4 \u{00B7} tilt \u{2212}2.6 dB/oct \u{00B7} presence \u{2212}0.7")
    }

    func testTheBaselineIndicatorCountsTowardThirtyMinutes() {
        XCTAssertEqual(AutomationReadout.baselineText(BalanceBaseline(readings: 240)),
                       "learning your usual balance (12 of 30 min)")
        XCTAssertEqual(AutomationReadout.baselineText(BalanceBaseline(readings: 600)),
                       "your usual balance is learned")
    }
}

@MainActor
final class QuickFitPlanTests: XCTestCase {
    private func entry(_ title: String, _ source: String = "oratory1990") -> AutoEqEntry {
        AutoEqEntry(title: title, source: source, path: source + "/over-ear/" + title)
    }

    func testAnExactNameFitsEvenWhenLongerNamesContainIt() {
        let entries = [entry("Alder AR-5X"), entry("Alder AR-5"), entry("Alder AR-5 Pro")]
        XCTAssertEqual(QuickFitPlan.decide(name: "Alder AR-5", entries: entries),
                       .fit(entry("Alder AR-5")))
    }

    func testTheSameHeadphoneFromTwoSourcesFitsFromTheBetterRankedOne() {
        let entries = [entry("Alder AR-5", "crinacle"), entry("Alder AR-5", "oratory1990")]
        XCTAssertEqual(QuickFitPlan.decide(name: "alder ar-5", entries: entries),
                       .fit(entry("Alder AR-5", "oratory1990")))
    }

    func testASingleLongerMatchFits() {
        XCTAssertEqual(QuickFitPlan.decide(name: "Alder AR-9",
                                           entries: [entry("Alder AR-9 Reference"), entry("Other X1")]),
                       .fit(entry("Alder AR-9 Reference")))
    }

    func testSeveralDifferentMatchesSendYouToImportWithTheName() {
        let plan = QuickFitPlan.decide(name: "Alder AR",
                                       entries: [entry("Alder AR-5"), entry("Alder AR-3")])
        guard case .choose(let query, let note) = plan else { return XCTFail("expected a choice") }
        XCTAssertEqual(query, "Alder AR")
        XCTAssertTrue(note.contains("More than one"))
    }

    func testAnUnmeasuredModelSendsYouToImportWithItsFamily() {
        let plan = QuickFitPlan.decide(name: "Alder AR-7 Limited",
                                       entries: [entry("Alder AR-5"), entry("Alder AR-3")])
        guard case .choose(let query, let note) = plan else { return XCTFail("expected a choice") }
        XCTAssertEqual(query, "Alder")
        XCTAssertTrue(note.contains("Alder AR-7 Limited"))
    }

    func testNoRelativeAtAllKeepsTheTypedName() {
        let plan = QuickFitPlan.decide(name: "Zeta Phantom", entries: [entry("Alder AR-5")])
        guard case .choose(let query, let note) = plan else { return XCTFail("expected a choice") }
        XCTAssertEqual(query, "Zeta Phantom")
        XCTAssertTrue(note.contains("No measurement found"))
    }

    func testAnEmptyOrTinyNameAsksForASearch() {
        for name in ["", "  ", "AR"] {
            let plan = QuickFitPlan.decide(name: name, entries: [entry("Alder AR-5")])
            guard case .choose = plan else { return XCTFail("expected a choice for \(name)") }
        }
    }
}
