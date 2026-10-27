import XCTest
@testable import QudelixBar

final class TrimControllerTests: XCTestCase {
    private let neutral = BalanceFeatures(bassDb: 0, tiltDbPerOctave: -2, presenceDb: 0)

    private func controller(mode: TrimMode = .presentation, strength: Double = 1) -> TrimController {
        var c = TrimController()
        c.mode = mode
        c.strength = strength
        return c
    }

    func testClampsLimitEveryAxis() {
        let g = TrimGains(bassDb: 99, tiltDbPerOctave: -99, presenceDb: .nan, airDb: -5).clamped()
        XCTAssertEqual(g.bassDb, 3)
        XCTAssertEqual(g.tiltDbPerOctave, -1)
        XCTAssertEqual(g.presenceDb, 0)
        XCTAssertEqual(g.airDb, 0)
        XCTAssertEqual(TrimGains(airDb: 9).clamped().airDb, 2)
    }

    func testTargetNeverExceedsTheLimits() {
        let far = BalanceFeatures(bassDb: -40, tiltDbPerOctave: 40, presenceDb: -40)
        let t = TrimController.target(anchor: far, baseline: BalanceBaseline(),
                                      weights: (1, 1, 1, 1), strength: 1, air: .extended)
        XCTAssertEqual(t.bassDb, 3)
        XCTAssertEqual(t.tiltDbPerOctave, -1)
        XCTAssertEqual(t.presenceDb, 3)
        XCTAssertEqual(t.airDb, 2)
    }

    func testDeadBandsHoldSmallErrors() {
        var baseline = BalanceBaseline()
        baseline.tiltDbPerOctave = -2
        let inside = BalanceFeatures(bassDb: -0.5, tiltDbPerOctave: -2.25, presenceDb: 0.5)
        let t = TrimController.target(anchor: inside, baseline: baseline,
                                      weights: (1, 1, 1, 1), strength: 1, air: .unknown)
        XCTAssertEqual(t, .zero)
        let outside = BalanceFeatures(bassDb: -0.6, tiltDbPerOctave: -2.3, presenceDb: 0.6)
        let u = TrimController.target(anchor: outside, baseline: baseline,
                                      weights: (1, 1, 1, 1), strength: 1, air: .unknown)
        XCTAssertGreaterThan(u.bassDb, 0)
        XCTAssertGreaterThan(u.tiltDbPerOctave, 0)
        XCTAssertLessThan(u.presenceDb, 0)
    }

    func testHalfCorrectionAndAxisGains() {
        var baseline = BalanceBaseline()
        baseline.tiltDbPerOctave = -2
        let anchor = BalanceFeatures(bassDb: -0.8, tiltDbPerOctave: -2.4, presenceDb: 0.8)
        let t = TrimController.target(anchor: anchor, baseline: baseline,
                                      weights: (1, 1, 1, 0), strength: 0.5, air: .unknown)
        XCTAssertEqual(t.bassDb, 0.5 * 0.5 * 3.1 * 0.8, accuracy: 1e-9)
        XCTAssertEqual(t.tiltDbPerOctave, 0.5 * 0.5 * 1.0 * 0.4, accuracy: 1e-9)
        XCTAssertEqual(t.presenceDb, -0.5 * 0.5 * 2.4 * 0.8, accuracy: 1e-9)
    }

    func testModeWeightsScaleTheCorrection() {
        var baseline = BalanceBaseline()
        baseline.tiltDbPerOctave = -2
        let anchor = BalanceFeatures(bassDb: -0.8, tiltDbPerOctave: -2, presenceDb: 0)
        let clarity = TrimController.target(anchor: anchor, baseline: baseline,
                                            weights: TrimMode.clarity.weights, strength: 1,
                                            air: .unknown)
        let presentation = TrimController.target(anchor: anchor, baseline: baseline,
                                                 weights: TrimMode.presentation.weights,
                                                 strength: 1, air: .unknown)
        XCTAssertEqual(presentation.bassDb, 2 * clarity.bassDb, accuracy: 1e-9)
        let audiophile = TrimController.target(anchor: anchor, baseline: baseline,
                                               weights: TrimMode.audiophile.weights, strength: 1,
                                               air: .extended)
        XCTAssertEqual(audiophile, .zero)
    }

    func testAirOnlyWhenExtended() {
        let anchor = neutral
        var baseline = BalanceBaseline()
        baseline.tiltDbPerOctave = -2
        for air in [AirClass.unknown, .limited] {
            let t = TrimController.target(anchor: anchor, baseline: baseline,
                                          weights: TrimMode.resolution.weights, strength: 1,
                                          air: air)
            XCTAssertEqual(t.airDb, 0)
        }
        let t = TrimController.target(anchor: anchor, baseline: baseline,
                                      weights: TrimMode.resolution.weights, strength: 0.5,
                                      air: .extended)
        XCTAssertEqual(t.airDb, 1.0, accuracy: 1e-9)
    }

    func testAirClassFollowsTheVerdict() {
        XCTAssertEqual(AirClass(verdict: .hiRes(cutoffKHz: 24)), .extended)
        XCTAssertEqual(AirClass(verdict: .losslessLike(cutoffKHz: 21)), .extended)
        XCTAssertEqual(AirClass(verdict: .lossy(cutoffKHz: 16)), .limited)
        XCTAssertEqual(AirClass(verdict: .lossyHigh(cutoffKHz: 19)), .limited)
        XCTAssertEqual(AirClass(verdict: .natural(cutoffKHz: 18)), .unknown)
        XCTAssertEqual(AirClass(verdict: .noTreble), .unknown)
        XCTAssertEqual(AirClass(verdict: nil), .unknown)
    }

    func testSlewMovesAtTheStatedRates() {
        var c = controller()
        let reading = BalanceFeatures(bassDb: -3, tiltDbPerOctave: -3, presenceDb: 3)
        let g = c.step(reading: reading, air: .extended, frozen: false, dt: 1)
        XCTAssertEqual(g.bassDb, 0.1, accuracy: 1e-9)
        XCTAssertEqual(g.tiltDbPerOctave, 0.05, accuracy: 1e-9)
        XCTAssertEqual(g.presenceDb, -0.1, accuracy: 1e-9)
        XCTAssertEqual(g.airDb, 0.1, accuracy: 1e-9)
        let h = c.step(reading: reading, air: .extended, frozen: false, dt: 2)
        XCTAssertEqual(h.bassDb, 0.3, accuracy: 1e-9)
        XCTAssertEqual(h.tiltDbPerOctave, 0.15, accuracy: 1e-9)
    }

    func testStepSecondsAreCapped() {
        var c = controller()
        let reading = BalanceFeatures(bassDb: -3, tiltDbPerOctave: -2, presenceDb: 0)
        let g = c.step(reading: reading, air: .unknown, frozen: false, dt: 1000)
        XCTAssertEqual(g.bassDb, 1.0, accuracy: 1e-9)
        let n = c.step(reading: nil, air: .unknown, frozen: false, dt: .nan)
        XCTAssertEqual(n.bassDb, g.bassDb, accuracy: 1e-9)
    }

    func testAnchorBlendsWithNinetySecondConstant() {
        var c = controller()
        let a = BalanceFeatures(bassDb: 0, tiltDbPerOctave: -2, presenceDb: 0)
        let b = BalanceFeatures(bassDb: 3, tiltDbPerOctave: -1, presenceDb: -3)
        _ = c.step(reading: a, air: .unknown, frozen: false, dt: 1)
        _ = c.step(reading: b, air: .unknown, frozen: false, dt: 3)
        let k = 1 - exp(-3.0 / 90)
        let anchor = try? XCTUnwrap(c.anchor)
        XCTAssertEqual(anchor?.bassDb ?? 99, 3 * k, accuracy: 1e-9)
        XCTAssertEqual(anchor?.tiltDbPerOctave ?? 99, -2 + k, accuracy: 1e-9)
        XCTAssertEqual(anchor?.presenceDb ?? 99, -3 * k, accuracy: 1e-9)
    }

    func testAnchorReseedsAfterSixtySecondsOfSilence() {
        var c = controller()
        let a = BalanceFeatures(bassDb: 0, tiltDbPerOctave: -2, presenceDb: 0)
        let b = BalanceFeatures(bassDb: 2, tiltDbPerOctave: -1, presenceDb: 1)
        _ = c.step(reading: a, air: .unknown, frozen: false, dt: 1)
        for _ in 0..<7 { _ = c.step(reading: nil, air: .unknown, frozen: false, dt: 10) }
        _ = c.step(reading: b, air: .unknown, frozen: false, dt: 1)
        XCTAssertEqual(c.anchor, b)
    }

    func testAnchorDoesNotReseedWithinSixtySeconds() {
        var c = controller()
        let a = BalanceFeatures(bassDb: 0, tiltDbPerOctave: -2, presenceDb: 0)
        let b = BalanceFeatures(bassDb: 2, tiltDbPerOctave: -1, presenceDb: 1)
        _ = c.step(reading: a, air: .unknown, frozen: false, dt: 1)
        for _ in 0..<5 { _ = c.step(reading: nil, air: .unknown, frozen: false, dt: 10) }
        _ = c.step(reading: b, air: .unknown, frozen: false, dt: 1)
        XCTAssertNotEqual(c.anchor, b)
        XCTAssertLessThan(c.anchor?.bassDb ?? 99, 2)
    }

    func testFrozenKeepsGainsAndSkipsLearning() {
        var c = controller()
        let reading = BalanceFeatures(bassDb: -3, tiltDbPerOctave: -2, presenceDb: 0)
        for _ in 0..<10 { _ = c.step(reading: reading, air: .unknown, frozen: false, dt: 1) }
        let held = c.gains
        let readings = c.baseline.readings
        let baseline = c.baseline
        let far = BalanceFeatures(bassDb: 3, tiltDbPerOctave: -2, presenceDb: 0)
        for _ in 0..<20 { _ = c.step(reading: far, air: .unknown, frozen: true, dt: 1) }
        XCTAssertEqual(c.gains, held)
        XCTAssertEqual(c.baseline.readings, readings)
        XCTAssertEqual(c.baseline, baseline)
    }

    func testBaselineLearnsWhileDisabledAndGainsStayZero() {
        var c = controller()
        c.enabled = false
        let reading = BalanceFeatures(bassDb: -3, tiltDbPerOctave: -2, presenceDb: 0)
        for _ in 0..<50 { _ = c.step(reading: reading, air: .extended, frozen: false, dt: 1) }
        XCTAssertEqual(c.gains, .zero)
        XCTAssertEqual(c.baseline.readings, 50)
        XCTAssertLessThan(c.baseline.bassDb, 0)
    }

    func testBaselineIsLearnedAfterSixHundredReadings() {
        var c = controller()
        XCTAssertFalse(c.baseline.isLearned)
        for _ in 0..<599 { _ = c.step(reading: neutral, air: .unknown, frozen: false, dt: 1) }
        XCTAssertFalse(c.baseline.isLearned)
        _ = c.step(reading: neutral, air: .unknown, frozen: false, dt: 1)
        XCTAssertTrue(c.baseline.isLearned)
        XCTAssertEqual(BalanceBaseline.learnedAfter, 600)
    }

    func testResetSlewsGainsBackToZero() {
        var c = controller()
        let reading = BalanceFeatures(bassDb: -3, tiltDbPerOctave: -2, presenceDb: 0)
        for _ in 0..<30 { _ = c.step(reading: reading, air: .unknown, frozen: false, dt: 1) }
        XCTAssertGreaterThan(c.gains.bassDb, 1)
        let before = c.gains.bassDb
        c.reset()
        XCTAssertNil(c.anchor)
        let g = c.step(reading: nil, air: .unknown, frozen: false, dt: 1)
        XCTAssertEqual(g.bassDb, before - 0.1, accuracy: 1e-9)
        for _ in 0..<40 { _ = c.step(reading: nil, air: .unknown, frozen: false, dt: 1) }
        XCTAssertEqual(c.gains, .zero)
    }

    func testNonFiniteReadingIsIgnored() {
        var c = controller()
        let bad = BalanceFeatures(bassDb: .nan, tiltDbPerOctave: -2, presenceDb: 0)
        _ = c.step(reading: bad, air: .unknown, frozen: false, dt: 1)
        XCTAssertNil(c.anchor)
        XCTAssertEqual(c.baseline.readings, 0)
    }

    func testAdvisoryUsesFullWeightsRegardlessOfMode() {
        var c = controller(mode: .audiophile)
        let reading = BalanceFeatures(bassDb: -3, tiltDbPerOctave: -2, presenceDb: 0)
        for _ in 0..<10 { _ = c.step(reading: reading, air: .unknown, frozen: false, dt: 1) }
        XCTAssertEqual(c.gains, .zero)
        XCTAssertGreaterThan(c.advisory.bassDb, 0)
    }

    func testTrimBandsLayout() {
        let bands = TrimGains(bassDb: 1, tiltDbPerOctave: -0.5, presenceDb: -2, airDb: 1.5).bands
        XCTAssertEqual(bands.map(\.filter), [.lowShelf, .lowShelf, .highShelf, .peak, .highShelf])
        XCTAssertEqual(bands.map(\.freq), [105, 250, 4000, 2800, 10000])
        let shelf = 0.5 / 0.2747
        XCTAssertEqual(bands[1].gain, shelf, accuracy: 1e-9)
        XCTAssertEqual(bands[2].gain, -shelf, accuracy: 1e-9)
        XCTAssertEqual(bands[0].gain, 1)
        XCTAssertEqual(bands[3].gain, -2)
        XCTAssertEqual(bands[4].gain, 1.5)
    }

    func testRoundingToTheDeviceStep() {
        let g = TrimGains(bassDb: 1.234, tiltDbPerOctave: -0.449, presenceDb: -2.06, airDb: 0.04)
            .rounded()
        XCTAssertEqual(g.bassDb, 1.2, accuracy: 1e-9)
        XCTAssertEqual(g.tiltDbPerOctave, -0.4, accuracy: 1e-9)
        XCTAssertEqual(g.presenceDb, -2.1, accuracy: 1e-9)
        XCTAssertEqual(g.airDb, 0, accuracy: 1e-9)
    }

    func testBaselineCodecIsLenientAndClamped() throws {
        let json = #"{"bassDb": 99, "tiltDbPerOctave": "x", "readings": -4}"#
        let b = try JSONDecoder().decode(BalanceBaseline.self, from: Data(json.utf8))
        XCTAssertEqual(b.bassDb, 12)
        XCTAssertEqual(b.tiltDbPerOctave, -2)
        XCTAssertEqual(b.presenceDb, 0)
        XCTAssertEqual(b.readings, 0)
        let again = try JSONDecoder().decode(
            BalanceBaseline.self, from: JSONEncoder().encode(BalanceBaseline(
                bassDb: 1, tiltDbPerOctave: -1, presenceDb: 2, readings: 7)))
        XCTAssertEqual(again, BalanceBaseline(bassDb: 1, tiltDbPerOctave: -1, presenceDb: 2,
                                              readings: 7))
    }

    func testModeAndSourceRoundTripByRawValue() throws {
        for m in TrimMode.allCases {
            let data = try JSONEncoder().encode([m])
            XCTAssertEqual(try JSONDecoder().decode([TrimMode].self, from: data), [m])
        }
        for s in ReferenceSource.allCases {
            let data = try JSONEncoder().encode([s])
            XCTAssertEqual(try JSONDecoder().decode([ReferenceSource].self, from: data), [s])
        }
    }
}
