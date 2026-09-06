import XCTest
@testable import QudelixBar

@MainActor
final class BlindComparisonTests: XCTestCase {

    private func connected(bands: [QxEqBandValue]? = nil,
                           preGain: Double = 0,
                           eqEnabled: Bool = true) -> QudelixController {
        let c = QudelixController()
        c.connection = .connected(name: "Qudelix 5K")
        c.compatibility = .ok
        c.eqEnabled = eqEnabled
        if let bands { c.bands = bands }
        c.preGain = preGain
        return c
    }

    private func peak(_ freq: Int, _ gain: Double, _ q: Double = 1.0) -> QxEqBandValue {
        QxEqBandValue(filter: .peak, freq: freq, gain: gain, q: q)
    }

    private func flat() -> [QxEqBandValue] {
        QxEq.defaultFreqs.map { peak($0, 0) }
    }

    private func correction() -> [QxEqBandValue] {
        QxEq.defaultFreqs.enumerated().map { i, hz in peak(hz, i.isMultiple(of: 2) ? 4 : -4) }
    }

    private func bassLifted(_ db: Double) -> [QxEqBandValue] {
        QxEq.defaultFreqs.map { hz in
            QxEqBandValue(filter: hz == 31 ? .lowShelf : .peak, freq: hz,
                          gain: hz <= 125 ? db : 0, q: 0.71)
        }
    }

    private var alwaysHigh: Chance { Chance(coin: { true }, index: { _ in 0 }) }
    private var alwaysLow: Chance { Chance(coin: { false }, index: { _ in 0 }) }

    private func runShape(_ blind: BlindTuner, _ c: QudelixController,
                          answerRealTrials: ShapeRun.Answer,
                          answerChecks: ShapeRun.Answer) {
        var steps = 0
        while blind.phase == .running && steps < 100 {
            steps += 1
            let answer = blind.isConsistencyCheck ? answerChecks : answerRealTrials
            switch answer {
            case .same: blind.noDifference(c)
            case .preferA: blind.choose(preferA: true, c)
            case .preferB: blind.choose(preferA: false, c)
            }
        }
        XCTAssertEqual(blind.phase, .finished, "the session must end on its own")
    }


    func testTheTwoSidesOfAPairEndUpAtTheSameComputedLevel() {
        let loud = bassLifted(8)
        let quiet = flat()
        let matched = LevelMatch.matchedPreGains(loud, quiet, base: 0)

        let levelLoud = LevelMatch.meanLevelDb(bands: loud, preGain: matched.a)
        let levelQuiet = LevelMatch.meanLevelDb(bands: quiet, preGain: matched.b)
        XCTAssertEqual(levelLoud, levelQuiet, accuracy: LevelMatch.toleranceDb,
                       "a presented pair that is not level-matched measures loudness")
    }

    func testOnlyTheLouderSideIsTrimmedAndTheQuieterKeepsTheBase() {
        let loud = bassLifted(8)
        let quiet = flat()
        let base = -3.0
        let matched = LevelMatch.matchedPreGains(loud, quiet, base: base)

        XCTAssertEqual(matched.b, base, accuracy: 1e-9,
                       "trimming the quiet side down would make the session quieter "
                           + "than the caller decided was safe")
        XCTAssertLessThan(matched.a, base)
    }

    func testTheMatchNeverGoesLouderThanTheBaseWhicheverSideIsLouder() {
        let base = -4.0
        for (a, b) in [(bassLifted(8), flat()), (flat(), bassLifted(8)),
                       (correction(), flat()), (flat(), flat())] {
            let matched = LevelMatch.matchedPreGains(a, b, base: base)
            XCTAssertLessThanOrEqual(matched.a, base + 1e-9)
            XCTAssertLessThanOrEqual(matched.b, base + 1e-9)
            XCTAssertGreaterThanOrEqual(matched.a, EQHeadroom.range.lowerBound)
            XCTAssertGreaterThanOrEqual(matched.b, EQHeadroom.range.lowerBound)
        }
    }

    func testAnIdenticalPairIsMatchedToTheSameValueOnBothSides() {
        let matched = LevelMatch.matchedPreGains(correction(), correction(), base: -5)
        XCTAssertEqual(matched.a, -5, accuracy: 1e-9)
        XCTAssertEqual(matched.b, -5, accuracy: 1e-9)
    }

    func testTheTrimStopsAtTheDeviceFloorRatherThanRunningPastIt() {
        let matched = LevelMatch.matchedPreGains(bassLifted(12), flat(), base: -11)
        XCTAssertGreaterThanOrEqual(matched.a, EQHeadroom.range.lowerBound)
    }

    func testTheGridIsSampledAtCellMidpointsInsideTheProgrammeBand() {
        XCTAssertEqual(LevelMatch.grid.count, LevelMatch.points)
        XCTAssertGreaterThan(LevelMatch.grid.first ?? 0, LevelMatch.lowHz)
        XCTAssertLessThan(LevelMatch.grid.last ?? 0, LevelMatch.highHz)
    }


    func testTheRangeShrinksOnlyAsFarAsTheHeadroomForcesIt() {
        let open = flat()
        let crowded = bassLifted(8)
        let openFit = BlindTuner.fitted(baseline: open,
                                        weights: BlindTuner.weights(for: open),
                                        userPreGain: 0)
        let crowdedFit = BlindTuner.fitted(baseline: crowded,
                                           weights: BlindTuner.weights(for: crowded),
                                           userPreGain: 0)

        XCTAssertGreaterThan(openFit.scale, crowdedFit.scale,
                             "a curve with headroom left must get more of the range "
                                 + "than one without")
        XCTAssertGreaterThanOrEqual(openFit.scale, 0.5)
        XCTAssertLessThanOrEqual(openFit.scale, 1)
    }

    func testACurveWithNoHeadroomLeftRunsWithAReducedRange() {
        let baseline = bassLifted(8)
        let weights = BlindTuner.weights(for: baseline)
        let fit = BlindTuner.fitted(baseline: baseline, weights: weights, userPreGain: 0)

        XCTAssertLessThan(fit.scale, 1,
                          "a session that cannot level-match inside the floor must "
                              + "explore less, not present mismatched pairs")
        XCTAssertGreaterThanOrEqual(fit.scale, BlindTuner.smallestRange)
    }

    func testTheFittedRangeActuallyLeavesRoomForTheWorstTrim() {
        for baseline in [flat(), correction(), bassLifted(6), bassLifted(11)] {
            let weights = BlindTuner.weights(for: baseline)
            let fit = BlindTuner.fitted(baseline: baseline, weights: weights, userPreGain: 0)
            let trim = BlindTuner.worstTrim(baseline: baseline, weights: weights,
                                            scale: fit.scale)
            XCTAssertTrue(fit.base - trim >= EQHeadroom.range.lowerBound
                            || fit.scale == BlindTuner.smallestRange,
                          "the session must either fit under the floor or already be "
                              + "at the smallest range it will run")
        }
    }

    func testTheWorstTrimIsAPairsSpanNotTheWholeSearchSpace() {
        let baseline = flat()
        let weights = BlindTuner.weights(for: baseline)
        let trim = BlindTuner.worstTrim(baseline: baseline, weights: weights, scale: 1)

        let corners = BlindTuner.cornerCurves(baseline: baseline, weights: weights, scale: 1)
        let levels = corners.map { LevelMatch.meanLevelDb(bands: $0) }
        let wholeSpace = (levels.max() ?? 0) - (levels.min() ?? 0)

        XCTAssertGreaterThan(trim, 0)
        XCTAssertLessThan(trim, wholeSpace,
                          "two candidates in a pair differ on one axis by one step, "
                              + "never across the whole space at once")
    }


    func testEachAxisIsSettledBeforeTheNextOneIsAsked() {
        let baseline = flat()
        var run = ShapeRun(baseline: baseline,
                           weights: BlindTuner.weights(for: baseline),
                           chance: .seeded(7))
        var order: [ShapeAxis?] = []
        while let trial = run.trial {
            order.append(trial.axis)
            run.answer(.same)
        }

        XCTAssertEqual(order.count, run.trialsTotal)
        XCTAssertEqual(order.compactMap { $0 },
                       [.bass, .bass, .bass, .presence, .presence, .presence,
                        .tilt, .tilt, .tilt])
        XCTAssertEqual(order.filter { $0 == nil }.count, ShapeRun.axisOrder.count,
                       "one identical pair inside each axis's own block")
    }

    func testAlwaysPreferringTheHigherSideWalksEachAxisToItsTop() {
        let baseline = flat()
        var run = ShapeRun(baseline: baseline,
                           weights: BlindTuner.weights(for: baseline),
                           chance: alwaysHigh)
        while let trial = run.trial {
            run.answer(trial.axis == nil ? .same : .preferA)
        }

        XCTAssertEqual(run.values[.bass] ?? 0, 7, accuracy: 1e-9)
        XCTAssertEqual(run.values[.presence] ?? 0, 4, accuracy: 1e-9)
        XCTAssertEqual(run.values[.tilt] ?? 0, 1.75, accuracy: 1e-9)
        XCTAssertFalse(run.nothingAudible)
    }

    func testHearingNoDifferenceLeavesEveryAxisWhereItStarted() {
        let baseline = correction()
        var run = ShapeRun(baseline: baseline,
                           weights: BlindTuner.weights(for: baseline),
                           chance: .seeded(3))
        while run.trial != nil { run.answer(.same) }

        for axis in ShapeAxis.allCases {
            XCTAssertEqual(run.values[axis] ?? 0, 0, accuracy: 1e-9)
        }
        XCTAssertTrue(run.nothingAudible)
    }

    func testAStepTooSmallForTheDeviceToStoreIsSkippedAndTheAxisStops() {
        let baseline = flat()
        let zeros = Array(repeating: 0.0, count: baseline.count)
        var weights: [ShapeAxis: [Double]] = [.bass: zeros, .presence: zeros]
        weights[.tilt] = Array(repeating: 0.002, count: baseline.count)
        var run = ShapeRun(baseline: baseline, weights: weights, chance: alwaysHigh)
        var presented = 0
        while let trial = run.trial {
            presented += 1
            run.answer(trial.axis == nil ? .same : .preferA)
        }

        XCTAssertEqual(run.skipped, ShapeRun.axisOrder.count * ShapeRun.rounds,
                       "asking about a difference the device cannot store is asking "
                           + "the listener to guess")
        XCTAssertEqual(presented, ShapeRun.axisOrder.count,
                       "only the identical pairs are left to present")
        for axis in ShapeAxis.allCases {
            XCTAssertTrue(run.converged.contains(axis))
            XCTAssertEqual(run.values[axis] ?? 0, 0, accuracy: 1e-9)
        }
        XCTAssertEqual(run.trialsDone, run.trialsTotal)
        XCTAssertNil(run.trial)
    }

    func testTrialGainsAreQuantisedToWhatTheDeviceCanActuallyStore() {
        let baseline = correction()
        var run = ShapeRun(baseline: baseline,
                           weights: BlindTuner.weights(for: baseline),
                           chance: .seeded(11))
        while let trial = run.trial {
            for band in trial.low + trial.high {
                XCTAssertEqual(band.gain, ShapeRun.quantised(band.gain), accuracy: 1e-12)
                XCTAssertLessThanOrEqual(abs(band.gain), 12 + 1e-9)
            }
            run.answer(.preferA)
        }
    }

    func testTheSameSeedReplaysTheSameSession() {
        let baseline = flat()
        let weights = BlindTuner.weights(for: baseline)
        func sides(_ seed: UInt64) -> [Bool] {
            var run = ShapeRun(baseline: baseline, weights: weights, chance: .seeded(seed))
            var out: [Bool] = []
            while let trial = run.trial {
                out.append(trial.highIsA)
                run.answer(.preferA)
            }
            return out
        }
        XCTAssertEqual(sides(42), sides(42))
        XCTAssertNotEqual(sides(42), sides(43))
    }

    func testABandThatCannotRenderGainIsLeftAlone() {
        var baseline = flat()
        baseline[0].filter = .hpf
        baseline[9].filter = .bypass
        let curve = ShapeRun.curve(baseline: baseline,
                                   weights: BlindTuner.weights(for: baseline),
                                   values: [.bass: 8, .presence: 4, .tilt: 2])

        XCTAssertEqual(curve[0], baseline[0])
        XCTAssertEqual(curve[9], baseline[9])
        XCTAssertNotEqual(curve[1], baseline[1])
    }


    func testASessionThatFoundNothingAudibleRefusesToWriteAnything() {
        let baseline = correction()
        let c = connected(bands: baseline)
        let blind = BlindTuner()
        blind.start(c, mode: .shape, chance: .seeded(5))
        runShape(blind, c, answerRealTrials: .same, answerChecks: .same)

        XCTAssertEqual(blind.verdict, .nothingAudible)
        blind.keepResult(c)
        XCTAssertEqual(blind.phase, .finished, "keeping is refused, not silently done")

        blind.discardResult(c)
        XCTAssertEqual(c.bands, baseline)
        XCTAssertEqual(blind.phase, .idle)
    }

    func testNamingAWinnerOnEveryRepeatedSettingRefusesTheResult() {
        let baseline = correction()
        let c = connected(bands: baseline)
        let blind = BlindTuner()
        blind.start(c, mode: .shape, chance: alwaysHigh)
        runShape(blind, c, answerRealTrials: .preferA, answerChecks: .preferA)

        XCTAssertEqual(blind.sameTrials, ShapeRun.axisOrder.count)
        XCTAssertEqual(blind.sameGuesses, blind.sameTrials)
        XCTAssertEqual(blind.verdict, .unreliable)

        blind.keepResult(c)
        XCTAssertEqual(blind.phase, .finished)

        blind.discardResult(c)
        XCTAssertEqual(c.bands, baseline, "a refused session leaves the curve alone")
    }

    func testAUsableSessionWritesTheCurveTheListenerHeard() {
        let baseline = correction()
        let c = connected(bands: baseline)
        let blind = BlindTuner()
        blind.start(c, mode: .shape, chance: alwaysHigh)
        runShape(blind, c, answerRealTrials: .preferA, answerChecks: .same)

        XCTAssertEqual(blind.verdict, .usable)
        XCTAssertNotEqual(blind.resultBands, baseline)
        let heard = c.bands

        blind.keepResult(c)
        XCTAssertEqual(blind.phase, .idle)
        XCTAssertEqual(c.bands, heard,
                       "keeping must not swap in a curve nobody auditioned")
        XCTAssertEqual(c.bands, blind.resultBands)
        XCTAssertFalse(c.byEarSessionActive)
    }

    func testABankSwitchStopsTheSessionWithoutWritingIntoTheOtherBank() {
        let baseline = correction()
        let c = connected(bands: baseline)
        let blind = BlindTuner()
        blind.start(c, mode: .shape, chance: alwaysHigh)
        var steps = 0
        while c.bands == baseline, blind.phase == .running, steps < 20 {
            steps += 1
            blind.choose(preferA: true, c)
        }
        let onDevice = c.bands
        XCTAssertNotEqual(onDevice, baseline, "a trial curve is loaded, not the baseline")

        c.applyPreviewGroup(.b20)
        blind.cancel(c)

        XCTAssertEqual(c.bands, onDevice,
                       "the baseline belongs to the bank the session started in")
        XCTAssertEqual(blind.phase, .idle)
        XCTAssertFalse(c.byEarSessionActive)
    }

    func testAResultIsNotKeptIntoABankTheSessionWasNeverMadeFor() {
        let baseline = correction()
        let c = connected(bands: baseline)
        let blind = BlindTuner()
        blind.start(c, mode: .shape, chance: alwaysHigh)
        runShape(blind, c, answerRealTrials: .preferA, answerChecks: .same)
        XCTAssertEqual(blind.verdict, .usable)
        let onDevice = c.bands

        c.applyPreviewGroup(.b20)
        blind.keepResult(c)

        XCTAssertEqual(c.bands, onDevice, "no band write lands in the other bank")
        XCTAssertEqual(blind.phase, .idle)
    }

    func testDiscardingPutsBackTheCurveAndThePreGain() {
        let baseline = correction()
        let c = connected(bands: baseline, preGain: -2)
        let blind = BlindTuner()
        blind.start(c, mode: .shape, chance: alwaysHigh)
        runShape(blind, c, answerRealTrials: .preferA, answerChecks: .same)
        blind.discardResult(c)

        XCTAssertEqual(c.bands, baseline)
        XCTAssertEqual(c.preGain, -2, accuracy: 1e-9)
    }

    func testThePreGainStaysInsideTheDeviceRangeAndNeverGoesAboveTheUsersOwn() {
        let baseline = bassLifted(6)
        let c = connected(bands: baseline, preGain: -1)
        let blind = BlindTuner()
        blind.start(c, mode: .shape, chance: .seeded(9))
        var steps = 0
        while blind.phase == .running && steps < 100 {
            steps += 1
            XCTAssertLessThanOrEqual(c.preGain, -1 + 1e-9)
            XCTAssertGreaterThanOrEqual(c.preGain, EQHeadroom.range.lowerBound)
            blind.toggleSide(c)
            XCTAssertLessThanOrEqual(c.preGain, -1 + 1e-9)
            XCTAssertGreaterThanOrEqual(c.preGain, EQHeadroom.range.lowerBound)
            blind.noDifference(c)
        }
        XCTAssertEqual(blind.phase, .finished)
    }

    func testAReducedRangeSessionSaysSo() {
        let c = connected(bands: bassLifted(8))
        let blind = BlindTuner()
        blind.start(c, mode: .shape, chance: .seeded(2))

        XCTAssertLessThan(blind.rangeScale, 1)
        XCTAssertNotNil(blind.note)
        blind.cancel(c)
    }

    func testAShapeSessionRefusesWhenNoBandCanCarryAShape() {
        let c = connected(bands: QxEq.defaultFreqs.map {
            QxEqBandValue(filter: .bypass, freq: $0, gain: 0, q: 1)
        })
        XCTAssertEqual(BlindTuner.blocker(c, mode: .shape), .noGainBand)

        let blind = BlindTuner()
        blind.start(c, mode: .shape)
        XCTAssertEqual(blind.phase, .idle)
    }


    func testTheCheckPutsEverythingBackWhicheverWayTheAnswersFall() {
        let baseline = correction()
        for answer in [true, false] {
            let c = connected(bands: baseline, preGain: -3)
            let blind = BlindTuner()
            blind.start(c, mode: .bypass, chance: .seeded(4))
            var steps = 0
            while blind.phase == .running && steps < 20 {
                steps += 1
                blind.choose(preferA: answer, c)
            }

            XCTAssertEqual(blind.phase, .finished)
            XCTAssertEqual(c.bands, baseline, "the check reports and writes nothing")
            XCTAssertEqual(c.preGain, -3, accuracy: 1e-9)
            XCTAssertTrue(c.eqEnabled, "flat is a flat curve, never the enable flag")
        }
    }

    func testFiveTrialsAreRunAndACleanMajorityIsNamed() {
        let c = connected(bands: correction())
        let blind = BlindTuner()
        blind.start(c, mode: .bypass, chance: alwaysHigh)
        for _ in 0..<BlindTuner.bypassTrials { blind.choose(preferA: true, c) }

        XCTAssertEqual(blind.trialsDone, BlindTuner.bypassTrials)
        XCTAssertEqual(blind.bypassOutcome, .preferredEQ(BlindTuner.bypassTrials))
    }

    func testTheSideIsTakenFromTheInjectedSourceRatherThanTheSystem() {
        let c = connected(bands: correction())
        let blind = BlindTuner()
        blind.start(c, mode: .bypass, chance: alwaysLow)
        for _ in 0..<BlindTuner.bypassTrials { blind.choose(preferA: true, c) }

        XCTAssertEqual(blind.bypassOutcome, .preferredFlat(BlindTuner.bypassTrials))
    }

    func testThreeOfFiveIsNotAMajorityAndCarriesEveryCount() {
        let c = connected(bands: correction())
        let blind = BlindTuner()
        blind.start(c, mode: .bypass, chance: alwaysHigh)
        blind.choose(preferA: true, c)
        blind.choose(preferA: true, c)
        blind.choose(preferA: true, c)
        blind.choose(preferA: false, c)
        blind.noDifference(c)

        XCTAssertEqual(blind.bypassOutcome, .noneSurvived(eq: 3, flat: 1, same: 1))
    }

    func testTheMajorityLineIsOneTrialAboveACoinToss() {
        XCTAssertEqual(BlindTuner.bypassClearMajority, 4)
        XCTAssertEqual(BlindTuner.bypassTrials, 5)
    }

    func testFlatIsAFlatCurveWithNoPassFiltersLeftInIt() {
        var bands = correction()
        bands[0].filter = .hpf
        bands[1].filter = .lpf
        bands[2].filter = .bypass
        bands[3].filter = .lowShelf
        let flattened = ShapeRun.flattened(bands)

        XCTAssertEqual(flattened.map(\.gain), Array(repeating: 0, count: bands.count))
        XCTAssertEqual(flattened[0].filter, .peak)
        XCTAssertEqual(flattened[1].filter, .peak)
        XCTAssertEqual(flattened[2].filter, .bypass,
                       "an empty slot has nothing to flatten and costs a write to touch")
        XCTAssertEqual(flattened[3].filter, .lowShelf)
        XCTAssertEqual(flattened.map(\.freq), bands.map(\.freq))
    }

    func testTheCheckRefusesWhenBothSidesWouldBeTheSameSound() {
        XCTAssertEqual(BlindTuner.blocker(connected(bands: flat()), mode: .bypass),
                       .alreadyFlat)
        XCTAssertEqual(
            BlindTuner.blocker(connected(bands: correction(), eqEnabled: false),
                               mode: .bypass), .eqOff)
        XCTAssertNil(BlindTuner.blocker(connected(bands: correction()), mode: .bypass))
    }

    func testAPassFilterAloneIsStillSomethingToCompareAgainst() {
        var bands = flat()
        bands[0].filter = .hpf
        XCTAssertNil(BlindTuner.blocker(connected(bands: bands), mode: .bypass))
    }


    func testOnlyBandsThatActuallyChangeAreWritten() {
        let before = correction()
        var after = before
        after[3].gain += 0.5
        after[7].gain += 0.1

        XCTAssertEqual(BlindTuner.changedIndices(from: before, to: after,
                                                 limit: before.count), [3, 7])
        XCTAssertEqual(BlindTuner.changedIndices(from: before, to: before,
                                                 limit: before.count), [])
        XCTAssertEqual(BlindTuner.changedIndices(from: [], to: after, limit: 2), [0, 1])
        XCTAssertEqual(BlindTuner.changedIndices(from: before, to: after, limit: 4), [3])
    }

    func testASessionTakesOneUndoStepAndNoMore() {
        let c = connected(bands: correction())
        var edited = c.bands[0]
        edited.gain += 1
        c.updateBand(0, edited)
        let sessionStart = c.bands
        let depth = c.undoStack.count

        let blind = BlindTuner()
        blind.start(c, mode: .shape, chance: alwaysHigh)
        runShape(blind, c, answerRealTrials: .preferA, answerChecks: .same)
        blind.keepResult(c)

        XCTAssertEqual(c.undoLabel, "by-ear shaping")
        XCTAssertEqual(c.undoStack.count, depth + 1,
                       "a session is one step, not one per trial")
        c.undoEqEdit()
        XCTAssertEqual(c.bands, sessionStart, "one step takes the whole session back")
    }


    func testTheComparisonMatchesLevelsWithPreGainRatherThanBandGains() {
        let c = connected(bands: correction(), preGain: -2)
        let tuner = ABTuner()
        tuner.start(c, chance: .seeded(21))

        var sawCheck = false
        var steps = 0
        while tuner.phase == .running && steps < 100 {
            steps += 1
            XCTAssertLessThanOrEqual(c.preGain, -2 + 1e-9)
            XCTAssertGreaterThanOrEqual(c.preGain, EQHeadroom.range.lowerBound)
            if tuner.isConsistencyCheck {
                sawCheck = true
                let a = c.preGain
                tuner.toggleSide(c)
                XCTAssertEqual(c.preGain, a, accuracy: 1e-9,
                               "two copies of one curve are equally loud, so switching "
                                   + "between them must not move the pre-gain")
            }
            tuner.noDifference(c)
        }
        XCTAssertTrue(sawCheck)
        XCTAssertEqual(tuner.phase, .finished)
    }

    func testTheComparisonReplaysFromASeed() {
        func session(_ seed: UInt64) -> [QxEqBandValue] {
            let c = connected(bands: correction())
            let tuner = ABTuner()
            tuner.start(c, chance: .seeded(seed))
            var steps = 0
            while tuner.phase == .running && steps < 100 {
                steps += 1
                tuner.choose(preferA: true, c)
            }
            return tuner.resultBands
        }
        XCTAssertEqual(session(8), session(8))
        XCTAssertNotEqual(session(8), session(9))
    }
}
