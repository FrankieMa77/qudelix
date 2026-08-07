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
        XCTAssertEqual(tester.measuredCount, 0)
        XCTAssertTrue(tester.measurementFailed)
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
}
