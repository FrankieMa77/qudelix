import XCTest
@testable import QudelixBar

final class FollowSolverTests: XCTestCase {
    private typealias Band = QxEqBandValue
    private typealias Follower = ReferenceFollower

    private struct Run {
        var final: Follower.Result
        var maxGain: Double
        var maxTickStep: Double
        var maxRise: Double
        var deviations: [Double]
    }

    private func run(base: [Band], reference: [Band], trim: TrimGains? = nil,
                     preGain: Double = 0, ticks: Int = 120) -> Run {
        var current = Follower.solve(base: base, basePreGain: preGain, reference: reference,
                                     referencePreGain: preGain, trim: trim,
                                     iterations: Follower.startIterations)
        var maxGain = FollowFixtures.maxAbsGain(current.bands)
        var maxStep = 0.0
        var maxRise = 0.0
        var deviations = [current.deviationDb]
        for _ in 0..<ticks {
            let next = Follower.solve(base: base, basePreGain: preGain, reference: reference,
                                      referencePreGain: preGain, trim: trim,
                                      iterations: Follower.iterationsPerTick,
                                      previousGains: current.gains)
            maxStep = max(maxStep, zip(next.gains, current.gains).map { abs($0 - $1) }.max() ?? 0)
            maxRise = max(maxRise, next.deviationDb - (deviations.last ?? 0))
            maxGain = max(maxGain, FollowFixtures.maxAbsGain(next.bands))
            deviations.append(next.deviationDb)
            current = next
        }
        return Run(final: current, maxGain: maxGain, maxTickStep: maxStep, maxRise: maxRise,
                   deviations: deviations)
    }

    private let userTrim = TrimGains(bassDb: -1.1, tiltDbPerOctave: 0, presenceDb: -1.0, airDb: 0)
    private let bigTrim = TrimGains(bassDb: 3, tiltDbPerOctave: -1, presenceDb: 3, airDb: 2)

    func testIdentityDoesNotMove() {
        let base = FollowFixtures.px8Jazz()
        let result = Follower.solve(base: base, basePreGain: -5.5, reference: base,
                                    referencePreGain: -5.5, trim: nil,
                                    iterations: Follower.startIterations)
        for (a, b) in zip(result.bands, base) {
            XCTAssertEqual(a.gain, b.gain, accuracy: 0.1)
            XCTAssertEqual(a.freq, b.freq)
            XCTAssertEqual(a.q, b.q)
            XCTAssertEqual(a.filter, b.filter)
        }
        XCTAssertLessThan(result.deviationDb, 0.1)
    }

    func testIdentityHoldsOverManyTicks() {
        let base = FollowFixtures.px8Jazz()
        let r = run(base: base, reference: base)
        for (a, b) in zip(r.final.bands, base) { XCTAssertEqual(a.gain, b.gain, accuracy: 0.1) }
        XCTAssertLessThanOrEqual(r.maxTickStep, 0.1 + 1e-9)
    }

    func testSameLayoutReferenceIsReproducedFromZero() {
        let reference = FollowFixtures.px8Jazz()
        let r = run(base: FollowFixtures.px8Flat(), reference: reference, ticks: 60)
        for (a, b) in zip(r.final.bands, reference) {
            XCTAssertEqual(a.gain, b.gain, accuracy: 0.1)
        }
        XCTAssertLessThan(r.final.deviationDb, 0.3)
    }

    func testPx8UserTrimConvergesNearTheStatedPeak() {
        let r = run(base: FollowFixtures.px8Jazz(), reference: FollowFixtures.px8Jazz(),
                    trim: userTrim, preGain: -5.5)
        XCTAssertLessThan(r.final.deviationDb, 0.2)
        XCTAssertEqual(r.maxGain, 4.5, accuracy: 0.3)
        XCTAssertLessThan(r.maxGain, ReferenceFollower.FollowHealth.clampDb)
        XCTAssertLessThanOrEqual(r.maxRise, 0.05)
    }

    func testPx8ZeroTrimStaysNearTheBase() {
        let base = FollowFixtures.px8Jazz()
        let r = run(base: base, reference: base, trim: .zero)
        XCTAssertLessThan(r.final.deviationDb, 0.1)
        XCTAssertEqual(r.maxGain, 4.7, accuracy: 0.3)
        for (a, b) in zip(r.final.bands, base) { XCTAssertEqual(a.gain, b.gain, accuracy: 0.2) }
    }

    func testPx8BigTrimNeverRunsAway() {
        let r = run(base: FollowFixtures.px8Jazz(), reference: FollowFixtures.px8Jazz(),
                    trim: bigTrim)
        XCTAssertLessThan(r.final.deviationDb, 0.9)
        XCTAssertLessThan(r.maxGain, 7.5)
        XCTAssertLessThanOrEqual(r.maxRise, 0.05)
        XCTAssertLessThanOrEqual(r.maxTickStep, 0.3)
    }

    func testPx8AgainstAStaticTenBandReference() {
        let r = run(base: FollowFixtures.px8Jazz(), reference: FollowFixtures.tenBandReference(),
                    preGain: -4.1)
        XCTAssertLessThan(r.final.deviationDb, 0.7)
        XCTAssertLessThan(r.maxGain, 5)
        XCTAssertLessThanOrEqual(r.maxTickStep, 0.3)
    }

    func testPx8WithoutShelvesConverges() {
        let base = FollowFixtures.px8NoShelves()
        let r = run(base: base, reference: base, trim: userTrim)
        XCTAssertLessThan(r.final.deviationDb, 0.5)
        XCTAssertLessThan(r.maxGain, 6)
    }

    func testTwentyBandReferenceOnATenBandBase() {
        let r = run(base: FollowFixtures.tenBandBase(),
                    reference: FollowFixtures.twentyBandReference())
        XCTAssertLessThan(r.final.deviationDb, 1.3)
        XCTAssertLessThan(r.maxGain, 4)
    }

    func testTenBandReferenceOnATwentyBandBase() {
        let r = run(base: FollowFixtures.px8Flat(), reference: FollowFixtures.tenBandReference())
        XCTAssertLessThan(r.final.deviationDb, 0.7)
    }

    func testResultsAreQuantizedToTheDeviceStep() {
        let r = run(base: FollowFixtures.px8Jazz(), reference: FollowFixtures.px8Jazz(),
                    trim: bigTrim, preGain: -5.5, ticks: 10)
        for band in r.final.bands {
            XCTAssertEqual(band.gain * 10, (band.gain * 10).rounded(), accuracy: 1e-9)
        }
        XCTAssertEqual(r.final.preGain * 10, (r.final.preGain * 10).rounded(), accuracy: 1e-9)
    }

    func testFiltersFrequenciesAndQsNeverChange() {
        let base = FollowFixtures.px8Jazz()
        let r = run(base: base, reference: FollowFixtures.tenBandReference(), trim: bigTrim,
                    ticks: 10)
        XCTAssertTrue(Follower.sameLayout(r.final.bands, base))
    }

    func testBypassHighPassAndLowPassAreUntouched() {
        var base = FollowFixtures.tenBandBase()
        base[0] = Band(filter: .hpf, freq: 31, gain: 0, q: 0.7)
        base[1] = Band(filter: .bypass, freq: 62, gain: 0, q: 1)
        base[9] = Band(filter: .lpf, freq: 16000, gain: 0, q: 0.7)
        let r = run(base: base, reference: FollowFixtures.twentyBandReference(), trim: bigTrim,
                    ticks: 10)
        XCTAssertEqual(r.final.bands[0], base[0])
        XCTAssertEqual(r.final.bands[1], base[1])
        XCTAssertEqual(r.final.bands[9], base[9])
        XCTAssertEqual(Follower.pinnedSet(base: base), Set(2...8))
    }

    func testGainsStayInsideTheDeviceRange() {
        let loud = FollowFixtures.px8Flat().map { var b = $0; b.gain = 12; return b }
        let r = run(base: FollowFixtures.px8Flat(), reference: loud, ticks: 20)
        XCTAssertLessThanOrEqual(r.maxGain, 12)
    }

    func testRampingTheTrimMovesGainsSmoothly() {
        let base = FollowFixtures.px8Jazz()
        var previous = Follower.solve(
            base: base, basePreGain: 0, reference: base, referencePreGain: 0,
            trim: TrimGains(bassDb: -3), iterations: Follower.startIterations)
        var worst = 0.0
        for tick in 1...60 {
            let trim = TrimGains(bassDb: -3 + 6 * Double(tick) / 60)
            let next = Follower.solve(base: base, basePreGain: 0, reference: base,
                                      referencePreGain: 0, trim: trim,
                                      iterations: Follower.iterationsPerTick,
                                      previousGains: previous.gains)
            worst = max(worst, zip(next.gains, previous.gains).map { abs($0 - $1) }.max() ?? 0)
            previous = next
        }
        XCTAssertLessThanOrEqual(worst, 0.3)
    }

    func testPreGainIsTheReferenceLevelCappedByHeadroom() {
        let base = FollowFixtures.tenBandBase()
        let reference = FollowFixtures.tenBandReference()
        let free = Follower.solve(base: base, basePreGain: 0, reference: reference,
                                  referencePreGain: -2.34, trim: nil, iterations: 24,
                                  capToHeadroom: false)
        XCTAssertEqual(free.preGain, -2.3, accuracy: 1e-9)
        let capped = Follower.solve(base: base, basePreGain: 0, reference: reference,
                                    referencePreGain: 5, trim: nil, iterations: 24,
                                    capToHeadroom: true)
        XCTAssertLessThanOrEqual(capped.preGain, EQHeadroom.suggestedPreGain(for: capped.bands))
        XCTAssertLessThanOrEqual(capped.preGain, 0)
    }

    func testBadPreviousGainsAreIgnoredOrClamped() {
        let base = FollowFixtures.px8Jazz()
        let wrongCount = Follower.solve(base: base, basePreGain: 0, reference: base,
                                        referencePreGain: 0, trim: nil, iterations: 6,
                                        previousGains: [1, 2, 3])
        XCTAssertLessThan(wrongCount.deviationDb, 0.1)
        let wild = [Double](repeating: .nan, count: base.count)
        let r = Follower.solve(base: base, basePreGain: 0, reference: base, referencePreGain: 0,
                               trim: nil, iterations: 6, previousGains: wild)
        XCTAssertTrue(r.gains.allSatisfy { $0.isFinite && abs($0) <= 12 })
    }

    func testFiveBandBaseWithNoMovableBandsIsReturnedAsIs() {
        let base = [Band(filter: .hpf, freq: 30, gain: 0, q: 0.7),
                    Band(filter: .bypass, freq: 100, gain: 0, q: 1)]
        let r = Follower.solve(base: base, basePreGain: -1, reference: FollowFixtures.tenBandReference(),
                               referencePreGain: -1, trim: bigTrim, iterations: 24)
        XCTAssertEqual(r.bands, base)
    }

    func testSolveCostStaysBounded() {
        let base = FollowFixtures.px8Jazz()
        let start = Date()
        _ = Follower.solve(base: base, basePreGain: 0, reference: FollowFixtures.tenBandReference(),
                           referencePreGain: 0, trim: bigTrim, iterations: Follower.startIterations)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testMatchedAnchorsPreferTheSameIndex() {
        let a = Band(filter: .peak, freq: 1000, gain: 0, q: 1)
        let b = Band(filter: .peak, freq: 1000, gain: 0, q: 1)
        var reference = [a, b]
        reference[0].gain = 2
        reference[1].gain = -2
        let out = EQFit.matched(bands: [a, b], toReference: reference, iterations: 24)
        XCTAssertGreaterThan(out[0].gain, out[1].gain)
    }

    func testCholeskyRejectsAnIndefiniteSystem() {
        XCTAssertNil(EQFit.solvePositiveDefinite([[1, 2], [2, 1]], [1, 1]))
        let x = EQFit.solvePositiveDefinite([[4, 1], [1, 3]], [1, 2])
        XCTAssertEqual(x?[0] ?? 99, 1.0 / 11, accuracy: 1e-12)
        XCTAssertEqual(x?[1] ?? 99, 7.0 / 11, accuracy: 1e-12)
    }

    func testZeroTrimKeepsABasePreGainAboveTheSuggestion() {
        let base = FollowFixtures.tenBandBase()
        let chosen = Follower.quantized(EQHeadroom.suggestedPreGain(for: base) + 3)
        let result = Follower.solve(base: base, basePreGain: chosen, reference: base,
                                    referencePreGain: chosen, trim: nil, iterations: 24)
        XCTAssertEqual(result.preGain, chosen, accuracy: 0.1)
        XCTAssertGreaterThan(result.preGain, EQHeadroom.suggestedPreGain(for: result.bands) + 2.5)
    }
}
