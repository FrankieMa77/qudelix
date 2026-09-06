import XCTest
@testable import QudelixBar

/// What the two by-ear tools are allowed to claim.
///
/// Both of them make statements about a person — what they prefer, what they can
/// hear — off the back of a five-minute session, so the interesting failures are
/// not arithmetic. They are the cases where the tool says something confident
/// about a session that established nothing, or says something discouraging about
/// a session the listener answered perfectly. All three defects covered here were
/// of that kind, and all three were invisible to the existing tests because the
/// result-screen predicates had never been exercised.
@MainActor
final class TuneHonestyTests: XCTestCase {

    // MARK: - Fixtures

    /// Same shape the other controller tests use: writable without a device.
    private func connected(bands: [QxEqBandValue]? = nil) -> QudelixController {
        let c = QudelixController()
        c.connection = .connected(name: "Qudelix 5K")
        c.compatibility = .ok
        if let bands { c.bands = bands }
        return c
    }

    private func peak(_ freq: Int, _ gain: Double, _ q: Double = 1.0) -> QxEqBandValue {
        QxEqBandValue(filter: .peak, freq: freq, gain: gain, q: q)
    }

    /// A curve with real shape in it — an imported headphone correction, which is
    /// what people are tuning on top of when they open this pane.
    private func correction() -> [QxEqBandValue] {
        QxEq.defaultFreqs.enumerated().map { i, hz in
            peak(hz, i.isMultiple(of: 2) ? 7 : -7)
        }
    }

    /// Drive a whole session, deciding only how to answer the identical pairs.
    /// Every real pair gets a preference, which is the busiest a listener can be.
    @discardableResult
    private func runSession(_ tuner: ABTuner, _ c: QudelixController,
                            guessOnCheck: (Int) -> Bool) -> Int {
        var checksSeen = 0, steps = 0
        while tuner.phase == .running && steps < 200 {
            steps += 1
            if tuner.isConsistencyCheck {
                let guessing = guessOnCheck(checksSeen)
                checksSeen += 1
                if guessing { tuner.choose(preferA: true, c) } else { tuner.noDifference(c) }
            } else {
                tuner.choose(preferA: true, c)
            }
        }
        XCTAssertEqual(tuner.phase, .finished, "the session must end on its own")
        return checksSeen
    }

    /// Drive a session in which nothing ever sounded different.
    private func runHearingNoDifference(_ tuner: ABTuner, _ c: QudelixController) {
        var steps = 0
        while tuner.phase == .running && steps < 200 {
            tuner.noDifference(c)
            steps += 1
        }
        XCTAssertEqual(tuner.phase, .finished)
    }

    // MARK: - The identical-pair check

    /// The regression, and the worst of the three: the check counted "preferred
    /// the higher setting", so answering "sound the same" every time — the only
    /// correct answer available — scored zero out of two and landed exactly on
    /// the condition for calling the session unreliable.
    func testAnsweringEveryIdenticalPairCorrectlyIsNotCalledUnreliable() {
        let c = connected()
        let tuner = ABTuner()
        tuner.start(c)
        let checks = runSession(tuner, c) { _ in false }

        XCTAssertGreaterThanOrEqual(checks, ABTuner.minChecksToJudge)
        XCTAssertEqual(tuner.sameTrials, checks)
        XCTAssertEqual(tuner.sameGuesses, 0, "saying they sound the same is not a guess")
        XCTAssertFalse(tuner.consistencyPoor,
                       "the ideal answer must not be reported as a bad session")
    }

    /// What the check is actually for: naming a winner between two copies of the
    /// same curve is a preference for nothing.
    func testNamingAWinnerOnEveryIdenticalPairIsCalledOut() {
        let c = connected()
        let tuner = ABTuner()
        tuner.start(c)
        let checks = runSession(tuner, c) { _ in true }

        XCTAssertEqual(tuner.sameGuesses, checks)
        XCTAssertTrue(tuner.consistencyPoor)
    }

    /// One wrong button press in twenty trials is a slip, not a habit, and the
    /// result screen must not lead with it.
    func testASingleStrayAnswerIsNotEnoughToCondemnTheSession() {
        let c = connected()
        let tuner = ABTuner()
        tuner.start(c)
        runSession(tuner, c) { index in index == 0 }

        XCTAssertEqual(tuner.sameGuesses, 1)
        XCTAssertFalse(tuner.consistencyPoor)
    }

    /// Below three pairs the check cannot separate a slip from a pattern, so it
    /// must say nothing rather than something misleading.
    func testTheCheckStaysSilentWhenThereAreTooFewPairsToJudge() {
        for trials in 0..<ABTuner.minChecksToJudge {
            for guesses in 0...trials {
                XCTAssertFalse(ABTuner.consistencyPoor(guesses: guesses, of: trials),
                               "\(guesses) of \(trials) cannot support a verdict")
            }
        }
    }

    /// A majority, once there are enough pairs to count one.
    func testTheVerdictNeedsAMajorityOfThePairs() {
        XCTAssertFalse(ABTuner.consistencyPoor(guesses: 1, of: 3))
        XCTAssertTrue(ABTuner.consistencyPoor(guesses: 2, of: 3))
        XCTAssertFalse(ABTuner.consistencyPoor(guesses: 2, of: 4))
        XCTAssertTrue(ABTuner.consistencyPoor(guesses: 3, of: 4))
        XCTAssertFalse(ABTuner.consistencyPoor(guesses: 0, of: 8))
    }

    /// The check used to be sprinkled at a fixed per-trial probability, which left
    /// its sample size to chance — nearly half of sessions drew fewer pairs than
    /// the verdict needs, and the count of trials the intro promised was a guess.
    func testEverySessionSchedulesEnoughPairsAndTheAdvertisedNumberOfTrials() {
        for _ in 0..<10 {
            let c = connected()
            let tuner = ABTuner()
            tuner.start(c)
            XCTAssertEqual(tuner.trialsTotal, ABTuner.rounds * ABTuner.trialsPerRound,
                           "the intro promises twenty comparisons")

            let checks = runSession(tuner, c) { _ in false }
            XCTAssertEqual(checks, ABTuner.rounds, "one identical pair per round")
            XCTAssertGreaterThanOrEqual(checks, ABTuner.minChecksToJudge)
            XCTAssertEqual(tuner.trialsDone, tuner.trialsTotal)
        }
    }

    // MARK: - How far the session actually moved the curve

    /// The second regression. Tilts are applied on top of the loaded curve, and
    /// the old measure read the height of the finished curve — so a session run
    /// over an imported correction always reported several decibels, and the note
    /// telling the listener the session had found nothing could never appear.
    func testASessionThatFoundNothingReportsNoMovementEvenOverACorrection() {
        let base = correction()
        let c = connected(bands: base)
        let tuner = ABTuner()
        tuner.start(c)
        runHearingNoDifference(tuner, c)

        XCTAssertEqual(Set(tuner.inaudible), Set(ABTuner.macros.map(\.name)),
                       "nothing was audible, so nothing is kept")
        XCTAssertEqual(tuner.maxMovement, 0, accuracy: 0.001,
                       "the session moved the curve nowhere")

        // What the old measure saw, and why the note was suppressed: the height
        // of a curve the listener imported before the session began.
        let heightOfFinishedCurve = tuner.resultBands.map { abs($0.gain) }.max() ?? 0
        XCTAssertEqual(heightOfFinishedCurve, 7, accuracy: 0.001)
    }

    /// A flat start hid the bug entirely, which is why it survived: with nothing
    /// loaded, height and movement are the same number.
    func testMovementAndCurveHeightAgreeOnlyWhenTheSessionStartedFlat() {
        let c = connected()
        let tuner = ABTuner()
        tuner.start(c)
        runHearingNoDifference(tuner, c)

        XCTAssertEqual(tuner.maxMovement, 0, accuracy: 0.001)
        XCTAssertEqual(tuner.resultBands.map { abs($0.gain) }.max() ?? 0, 0, accuracy: 0.001)
    }

    /// And it must still see a tilt the session did add, on top of a correction.
    func testMovementSeesTheTiltTheSessionAddedOnTopOfACorrection() {
        let base = correction()
        let c = connected(bands: base)
        let tuner = ABTuner()
        tuner.start(c)
        runSession(tuner, c) { _ in false }

        let actual = zip(base, tuner.resultBands).map { abs($1.gain - $0.gain) }.max() ?? 0
        XCTAssertEqual(tuner.maxMovement, actual, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(tuner.maxMovement, ABTuner.tiltCap + 0.001,
                                 "a session cannot move further than its own cap")
    }

    func testMovementIsADistanceNotAHeight() {
        XCTAssertEqual(ABTuner.movement(from: [peak(1000, 9)], to: [peak(1000, 9)]),
                       0, accuracy: 1e-9)
        XCTAssertEqual(ABTuner.movement(from: [peak(1000, 9)], to: [peak(1000, 6.5)]),
                       2.5, accuracy: 1e-9)
        XCTAssertEqual(ABTuner.movement(from: [peak(1000, -4)], to: [peak(1000, -1)]),
                       3, accuracy: 1e-9)
        XCTAssertEqual(ABTuner.movement(from: [], to: []), 0, accuracy: 1e-9)
    }

    // MARK: - A tone test that measured nothing

    /// The third regression. Too few thresholds means no suggestion, no rows and a
    /// deviation spread of zero — and zero spread is also what "your hearing is
    /// typical" looks like, so a test that measured nothing was congratulating the
    /// listener on their hearing.
    func testATesterThatMeasuredNothingIsNotACleanBillOfHealth() {
        let tester = ToneTester()
        XCTAssertEqual(tester.readingCount, 0)
        XCTAssertTrue(tester.measurementFailed)
        XCTAssertEqual(tester.verdict, .tooFewReadings)
        // The spread on its own cannot tell the two endings apart, which is the
        // whole reason the failure needs a state of its own.
        XCTAssertLessThan(tester.deviationSpread, 8)
    }

    func testTooFewThresholdsProduceNoSuggestionAtAll() {
        let barelyAnything: [(Int, Double?)] = [
            (250, nil), (500, -40), (1000, -45), (2000, nil), (4000, nil),
        ]
        XCTAssertEqual(ToneTester.suggest(barelyAnything).count, 0,
                       "two readings cannot establish a reference to deviate from")

        var enough = barelyAnything
        enough[0] = (250, -30)
        XCTAssertFalse(ToneTester.suggest(enough).isEmpty,
                       "\(ToneTester.minThresholds) readings is the boundary")
    }

    /// A partly failed measurement is the same disease in miniature: the rows for
    /// frequencies that gave no reading must not read as ordinary hearing.
    func testFrequenciesThatGaveNoReadingAreMarkedRatherThanShownAsNormal() {
        let partial: [(Int, Double?)] = [
            (250, -30), (500, -40), (1000, -45), (4000, nil), (8000, nil),
        ]
        let points = ToneTester.suggest(partial)

        XCTAssertEqual(points.count, 5, "every frequency stays visible")
        XCTAssertEqual(points.filter(\.measured).map(\.hz), [250, 500, 1000])
        for p in points where !p.measured {
            XCTAssertEqual(p.gain, 0, accuracy: 1e-9)
            XCTAssertEqual(p.deviation, 0, accuracy: 1e-9,
                           "the zero is a placeholder, and the flag is what says so")
        }
    }

    /// Those placeholder zeros must not be read as data. Left in, they drag the
    /// spread toward "nothing to correct" — the same wrong reassurance, arrived at
    /// from the other direction.
    func testTheSpreadIgnoresFrequenciesThatGaveNoReading() {
        let tight: [ToneTester.Point] = [
            (125, 2, 5, true), (1000, 0, 0, false), (8000, 2.4, 6, true),
        ]
        XCTAssertEqual(ToneTester.spread(of: tight), 1, accuracy: 1e-9,
                       "counting the hole would have read 6 here")

        let wide: [ToneTester.Point] = [
            (125, -3.6, -9, true), (1000, 0, 0, false), (8000, 3.6, 9, true),
        ]
        XCTAssertEqual(ToneTester.spread(of: wide), 18, accuracy: 1e-9)
        XCTAssertEqual(ToneTester.spread(of: []), 0, accuracy: 1e-9)
    }

    func testAnUnreliableRunIsRefusedHoweverTidyItsNumbersLook() {
        XCTAssertEqual(ToneTester.verdict(readings: 10, catchTrials: 15,
                                          falseAlarms: 6, spread: 15), .unreliable)
        XCTAssertEqual(ToneTester.verdict(readings: 10, catchTrials: 15,
                                          falseAlarms: 6, spread: 45), .unreliable,
                       "unreliable outranks scattered — neither is applicable, "
                           + "and the reason given must be the deeper one")
        XCTAssertEqual(ToneTester.verdict(readings: 2, catchTrials: 15,
                                          falseAlarms: 6, spread: 15), .tooFewReadings,
                       "nothing was measured, so there is nothing to disbelieve")
    }

    func testAFewPressesOnSilenceDoNotCondemnARun() {
        XCTAssertEqual(ToneTester.verdict(readings: 10, catchTrials: 3,
                                          falseAlarms: 3, spread: 15), .usable,
                       "three silent checks cannot support a rate")
        XCTAssertEqual(ToneTester.verdict(readings: 10, catchTrials: 16,
                                          falseAlarms: 1, spread: 15), .usable)
    }

    func testScatterBeyondHearingIsRefusedAndNamed() {
        XCTAssertEqual(ToneTester.verdict(readings: 10, catchTrials: 0,
                                          falseAlarms: 0, spread: 45),
                       .tooScattered(spread: 45))
        XCTAssertEqual(ToneTester.verdict(readings: 10, catchTrials: 0,
                                          falseAlarms: 0,
                                          spread: ToneTester.maxDeviationSpread), .usable,
                       "the limit itself is still believable")
    }

    func testFlatEnoughIsSaidPlainlyRatherThanApplied() {
        XCTAssertEqual(ToneTester.verdict(readings: 10, catchTrials: 0,
                                          falseAlarms: 0, spread: 3), .withinTestNoise)
        XCTAssertEqual(ToneTester.verdict(readings: 10, catchTrials: 0, falseAlarms: 0,
                                          spread: ToneTester.withinTestNoiseSpread),
                       .usable, "the boundary is where a correction starts being worth it")
    }

    func testElevatedFalseAlarmsAreSaidWithoutRefusingTheRun() {
        XCTAssertTrue(ToneTester.falseAlarmsElevated(catchTrials: 20, falseAlarms: 5))
        XCTAssertFalse(ToneTester.falseAlarmsElevated(catchTrials: 20, falseAlarms: 1),
                       "an ordinary run says nothing")
        XCTAssertFalse(ToneTester.falseAlarmsElevated(catchTrials: 20, falseAlarms: 8),
                       "past the gate the run is refused outright, not cautioned")
        XCTAssertFalse(ToneTester.falseAlarmsElevated(catchTrials: 4, falseAlarms: 2),
                       "too few checks to say anything about a rate")
    }

    func testApplyingARefusedRunWritesNothing() {
        let base = correction()
        let c = connected(bands: base)
        let tester = ToneTester()
        XCTAssertEqual(tester.verdict, .tooFewReadings)

        tester.applySuggestion(c)
        XCTAssertEqual(c.bands, base, "a run that measured nothing must not write a curve")
        XCTAssertTrue(c.undoStack.isEmpty)
    }

    func testAThresholdInTheTopFewDecibelsIsStillFound() {
        var staircase = ToneTester.Staircase()
        var presented: [Double] = [staircase.level]
        var settled: Double??

        for _ in 0..<40 {
            let didHear = staircase.level >= ToneTester.maxLevelDBFS
            if case .settled(let t) = staircase.answer(didHear) { settled = t; break }
            presented.append(staircase.level)
        }

        XCTAssertTrue(presented.contains(ToneTester.maxLevelDBFS),
                      "the cap has to be presented before it can be ruled out")
        XCTAssertEqual(settled ?? nil, ToneTester.maxLevelDBFS)
    }

    func testTwoMissesAtTheCapEndTheFrequency() {
        var staircase = ToneTester.Staircase()
        var missesAtCap = 0
        var settled: Double?? = nil

        for _ in 0..<40 {
            if staircase.level == ToneTester.maxLevelDBFS { missesAtCap += 1 }
            if case .settled(let t) = staircase.answer(false) { settled = t; break }
            XCTAssertLessThanOrEqual(staircase.level, ToneTester.maxLevelDBFS,
                                     "the level clamps at the cap rather than running past it")
        }

        XCTAssertNotNil(settled, "a listener who hears nothing must not loop forever")
        XCTAssertEqual(settled ?? -1, nil)
        XCTAssertEqual(missesAtCap, 2)
    }

    func testAnOrdinaryThresholdIsTheLowestLevelHeardTwice() {
        var staircase = ToneTester.Staircase()
        var settled: Double??

        for _ in 0..<40 {
            let didHear = staircase.level >= -45
            if case .settled(let t) = staircase.answer(didHear) { settled = t; break }
        }
        XCTAssertEqual(settled ?? nil, -45)
    }

    func testAThresholdWithNothingToCompareItAgainstIsNotAReading() {
        let results: [(Int, Double?)] = [
            (250, -30), (1000, -45), (3000, -40), (4000, nil),
        ]
        XCTAssertEqual(ToneTester.readingCount(in: results), 2)
        XCTAssertNil(ToneTester.reference[3000])
    }

    func testAnImpossibleSampleRateFallsBackInsteadOfSilencingTheTest() {
        XCTAssertEqual(ToneTester.plausibleRate(0), ToneTester.fallbackRate)
        XCTAssertEqual(ToneTester.plausibleRate(-48000), ToneTester.fallbackRate)
        XCTAssertEqual(ToneTester.plausibleRate(.nan), ToneTester.fallbackRate)
        XCTAssertEqual(ToneTester.plausibleRate(.infinity), ToneTester.fallbackRate)
        XCTAssertEqual(ToneTester.plausibleRate(1_000_000), ToneTester.fallbackRate)
        XCTAssertEqual(ToneTester.plausibleRate(48000), 48000)
        XCTAssertEqual(ToneTester.plausibleRate(384_000), 384_000)
    }

    func testASessionIsFoldedForTheDeeperReasonFirst() {
        XCTAssertNil(ABTuner.interruption(connected: true, compatible: true,
                                          voiceCall: false, eqModeChanged: false))
        XCTAssertEqual(ABTuner.interruption(connected: false, compatible: false,
                                            voiceCall: true, eqModeChanged: true),
                       .disconnected)
        XCTAssertEqual(ABTuner.interruption(connected: true, compatible: true,
                                            voiceCall: true, eqModeChanged: true),
                       .voiceCall)
        XCTAssertEqual(ABTuner.interruption(connected: true, compatible: true,
                                            voiceCall: false, eqModeChanged: true),
                       .eqModeChanged)
    }

    func testAToneRunNoticesItsPlayerAndItsOutput() {
        XCTAssertNil(ToneTester.interruption(connected: true, compatible: true,
                                             voiceCall: false, eqModeChanged: false,
                                             playerRunning: true, outputIsDevice: true))
        XCTAssertEqual(ToneTester.interruption(connected: true, compatible: true,
                                               voiceCall: false, eqModeChanged: false,
                                               playerRunning: false, outputIsDevice: true),
                       .playerStopped)
        XCTAssertEqual(ToneTester.interruption(connected: true, compatible: true,
                                               voiceCall: false, eqModeChanged: false,
                                               playerRunning: true, outputIsDevice: false),
                       .outputChanged)
        XCTAssertEqual(ToneTester.interruption(connected: true, compatible: true,
                                               voiceCall: false, eqModeChanged: true,
                                               playerRunning: false, outputIsDevice: false),
                       .eqModeChanged,
                       "a mode change is about the curve, and outranks the audio path")
    }

    func testOnlyBandsThatShapeTheSoundCountAsGainCapable() {
        XCTAssertTrue(QxFilter.peak.rendersGain)
        XCTAssertTrue(QxFilter.lowShelf.rendersGain)
        XCTAssertTrue(QxFilter.highShelf.rendersGain)
        XCTAssertFalse(QxFilter.bypass.rendersGain)
        XCTAssertFalse(QxFilter.lpf.rendersGain)
        XCTAssertFalse(QxFilter.hpf.rendersGain)
    }

    func testACurveWithNothingToTiltIsRefusedRatherThanRun() {
        let passFilters = QxEq.defaultFreqs.enumerated().map { i, hz in
            QxEqBandValue(filter: i.isMultiple(of: 2) ? .bypass : .hpf,
                          freq: hz, gain: 0, q: 1.0)
        }
        XCTAssertEqual(ABTuner.blocker(connected(bands: passFilters)), .noGainBand)

        var oneUsable = passFilters
        oneUsable[3] = peak(oneUsable[3].freq, 0)
        XCTAssertNil(ABTuner.blocker(connected(bands: oneUsable)))
    }

    func testTiltsSkipTheBandsThatWouldIgnoreThem() {
        var base = correction()
        base[0] = QxEqBandValue(filter: .hpf, freq: base[0].freq, gain: 0, q: 0.7)
        base[9] = QxEqBandValue(filter: .bypass, freq: base[9].freq, gain: 0, q: 1.0)

        let c = connected(bands: base)
        let tuner = ABTuner()
        tuner.start(c)
        runSession(tuner, c) { _ in false }

        XCTAssertEqual(tuner.resultBands[0], base[0], "a pass filter is left exactly alone")
        XCTAssertEqual(tuner.resultBands[9], base[9])
        XCTAssertGreaterThan(zip(base, tuner.resultBands).dropFirst()
                                .map { abs($1.gain - $0.gain) }.max() ?? 0, 0,
                             "the bands that can render the tilt still get it")
    }

    func testAKeptSessionCostsExactlyOneUndoStep() {
        let c = connected(bands: correction())
        c.setPreGain(-3)
        let before = c.undoStack.count

        let tuner = ABTuner()
        tuner.start(c)
        runSession(tuner, c) { _ in false }
        tuner.keepResult(c)

        XCTAssertEqual(c.undoStack.count, before + 1)
        XCTAssertEqual(c.undoStack.last?.label, "by-ear tuning")
    }

    func testADiscardedSessionCostsTheSameOneStep() {
        let c = connected(bands: correction())
        let tuner = ABTuner()
        tuner.start(c)
        runSession(tuner, c) { _ in false }
        tuner.discardResult(c)

        XCTAssertEqual(c.undoStack.count, 1)
        XCTAssertEqual(c.bands, correction(), "the curve comes back")
    }

    func testKeepingWhatWasNeverFinishedDoesNothing() {
        let c = connected(bands: correction())
        c.setPreGain(-4)
        let tuner = ABTuner()

        tuner.keepResult(c)
        XCTAssertEqual(c.preGain, -4, accuracy: 0.001)
        XCTAssertTrue(tuner.resultBands.isEmpty)
    }

    func testTheDeviceKnowsWhenASessionIsHoldingTheCurve() {
        let c = connected(bands: correction())
        XCTAssertFalse(c.byEarSessionActive)

        let tuner = ABTuner()
        tuner.start(c)
        XCTAssertTrue(c.byEarSessionActive)

        runSession(tuner, c) { _ in false }
        XCTAssertTrue(c.byEarSessionActive, "the result screen still holds a trial curve")

        tuner.keepResult(c)
        XCTAssertFalse(c.byEarSessionActive)
    }

    func testStoppingAfterABankSwitchWritesNothingIntoTheOtherBank() {
        let baseline = correction()
        let c = connected(bands: baseline)
        let tuner = ABTuner()
        tuner.start(c)
        var steps = 0
        while c.bands == baseline, tuner.phase == .running, steps < 20 {
            steps += 1
            tuner.choose(preferA: true, c)
        }
        let onDevice = c.bands
        XCTAssertNotEqual(onDevice, baseline, "a trial curve is loaded, not the baseline")

        c.applyPreviewGroup(.b20)
        tuner.cancel(c)

        XCTAssertEqual(c.bands, onDevice,
                       "the baseline belongs to the bank the session started in")
        XCTAssertFalse(c.byEarSessionActive)
    }

    func testStoppingASessionHandsTheCurveBack() {
        let c = connected(bands: correction())
        let tuner = ABTuner()
        tuner.start(c)
        tuner.cancel(c)

        XCTAssertFalse(c.byEarSessionActive)
        XCTAssertEqual(c.bands, correction())
    }

    /// The file already argues that past the ends of the measured range the
    /// nearest reading holds, because not looking is not the same as finding
    /// nothing. A gap in the middle deserves the same treatment.
    func testTheCorrectionSpansAGapInsteadOfDivingToZeroInsideIt() {
        let points: [ToneTester.Point] = [
            (250, 4, 10, true), (1000, 0, 0, false), (4000, 4, 10, true),
        ]
        let measured = points.filter(\.measured).map { (hz: Double($0.hz), gain: $0.gain) }
        XCTAssertEqual(ToneTester.gain(at: 1000, from: measured), 4, accuracy: 0.01)

        let withTheHole = points.map { (hz: Double($0.hz), gain: $0.gain) }
        XCTAssertEqual(ToneTester.gain(at: 1000, from: withTheHole), 0, accuracy: 0.01,
                       "what feeding the placeholder in would have written")
    }

    func testTheSanityCheckLineSaysWhatTheRepeatedPairsWere() {
        XCTAssertEqual(
            TuneView.sanityCheck(pairs: 4, guesses: 1),
            "Sanity check: 4 pairs were the same setting twice; you called a "
                + "winner in 1.")
        XCTAssertEqual(
            TuneView.sanityCheck(pairs: 1, guesses: 0),
            "Sanity check: 1 pair was the same setting twice; you called a "
                + "winner in 0.")
    }
}
