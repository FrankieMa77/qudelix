import XCTest
@testable import QudelixBar

final class ToneTestMathTests: XCTestCase {
    func testTheClampKeepsLevelsInsideTheSafeWindow() {
        XCTAssertEqual(ToneTestMath.clamp(0), ToneTestMath.maxLevelDBFS)
        XCTAssertEqual(ToneTestMath.clamp(-200), ToneTestMath.minLevelDBFS)
        XCTAssertEqual(ToneTestMath.clamp(-40), -40)
    }

    func testThePulseTrainHasTheRequestedShape() {
        let rate = 48000.0
        let samples = ToneTestMath.pulseSamples(hz: 1000, dbfs: -20, sampleRate: rate)
        let on = Int(0.22 * rate), gap = Int(0.12 * rate)
        XCTAssertEqual(samples.count, 3 * on + 2 * gap)
        let peak = samples.map { abs($0) }.max() ?? 0
        XCTAssertEqual(Double(peak), pow(10, -20.0 / 20), accuracy: 0.01)
        XCTAssertEqual(samples[0], 0, accuracy: 1e-6)
        for i in (on + 10)..<(on + gap - 10) { XCTAssertEqual(samples[i], 0) }
    }

    func testThePulseLevelIsClampedAtTheCeiling() {
        let samples = ToneTestMath.pulseSamples(hz: 500, dbfs: 12, sampleRate: 44100)
        let peak = Double(samples.map { abs($0) }.max() ?? 0)
        XCTAssertLessThanOrEqual(peak, pow(10, ToneTestMath.maxLevelDBFS / 20) + 1e-4)
    }

    func testAZeroLengthPulseTrainIsEmpty() {
        XCTAssertTrue(ToneTestMath.pulseSamples(hz: 1000, dbfs: -30, sampleRate: 48000,
                                                ms: 0, pulses: 1, gapMs: 0).isEmpty)
    }

    func testTheStaircaseDescendsThenSettlesOnARepeatedHit() {
        var s = ToneTestMath.Staircase()
        XCTAssertEqual(s.level, -40)
        XCTAssertEqual(s.answer(true), .ask(-50))
        XCTAssertEqual(s.answer(false), .ask(-45))
        XCTAssertEqual(s.answer(true), .ask(-50))
        XCTAssertEqual(s.answer(false), .ask(-45))
        XCTAssertEqual(s.answer(true), .settled(-45))
    }

    func testTheStaircaseGivesUpAfterTwoMissesAtTheCeiling() {
        var s = ToneTestMath.Staircase()
        var outcome = s.answer(false)
        var guardCount = 0
        while case .ask = outcome, guardCount < 40 {
            outcome = s.answer(false)
            guardCount += 1
        }
        XCTAssertEqual(outcome, .settled(nil))
        XCTAssertEqual(s.level, ToneTestMath.maxLevelDBFS)
    }

    func testSuggestNeedsEnoughReadingsAndCapsTheCorrection() {
        XCTAssertTrue(ToneTestMath.suggest([(1000, 2), (2000, nil)]).isEmpty)
        let results: [(Int, Double?)] = ToneTestMath.order.map { hz in
            (hz, (ToneTestMath.reference[hz] ?? 0) + (hz == 250 ? 40 : 0))
        }
        let points = ToneTestMath.suggest(results)
        XCTAssertEqual(points.count, results.count)
        XCTAssertTrue(points.allSatisfy { abs($0.gain) <= 6 })
        XCTAssertEqual(points.first { $0.hz == 250 }?.gain, 6)
        XCTAssertGreaterThan(ToneTestMath.spread(of: points), 30)
    }

    func testReadingCountSkipsMissingAndUnknownBands() {
        XCTAssertEqual(ToneTestMath.readingCount(in: [(1000, 3), (2000, nil), (1234, 5)]), 1)
    }

    func testVerdictsFollowTheDocumentedThresholds() {
        let v = ToneTestMath.verdict
        XCTAssertEqual(v(2, 10, 0, 20), .tooFewReadings)
        XCTAssertEqual(v(8, 10, 4, 20), .unreliable)
        XCTAssertEqual(v(8, 10, 1, 20), .usable)
        XCTAssertEqual(v(8, 5, 5, 20), .usable)
        XCTAssertEqual(v(8, 10, 0, 31), .tooScattered(spread: 31))
        XCTAssertEqual(v(8, 10, 0, 7.9), .withinTestNoise)
    }

    func testFalseAlarmsAreElevatedOnlyBetweenTheCautionAndUnreliableRates() {
        XCTAssertFalse(ToneTestMath.falseAlarmsElevated(catchTrials: 10, falseAlarms: 2))
        XCTAssertTrue(ToneTestMath.falseAlarmsElevated(catchTrials: 10, falseAlarms: 3))
        XCTAssertFalse(ToneTestMath.falseAlarmsElevated(catchTrials: 9, falseAlarms: 3))
        XCTAssertFalse(ToneTestMath.falseAlarmsElevated(catchTrials: 0, falseAlarms: 0))
    }

    func testGainInterpolatesOnALogFrequencyAxis() {
        let points: [(hz: Double, gain: Double)] = [(100, 0), (10000, 4)]
        XCTAssertEqual(ToneTestMath.gain(at: 1000, from: points), 2, accuracy: 1e-9)
        XCTAssertEqual(ToneTestMath.gain(at: 50, from: points), 0)
        XCTAssertEqual(ToneTestMath.gain(at: 20000, from: points), 4)
        XCTAssertEqual(ToneTestMath.gain(at: 1000, from: []), 0)
    }

    func testRatesOutsideThePlausibleRangeFallBack() {
        XCTAssertEqual(ToneTestMath.plausibleRate(96000), 96000)
        XCTAssertEqual(ToneTestMath.plausibleRate(0), ToneTestMath.fallbackRate)
        XCTAssertEqual(ToneTestMath.plausibleRate(.nan), ToneTestMath.fallbackRate)
    }

    func testInterruptionPrecedence() {
        let i = ToneTestMath.interruption
        XCTAssertEqual(i(false, false, true, true, false, false), .disconnected)
        XCTAssertEqual(i(true, false, true, true, false, false), .unsupported)
        XCTAssertEqual(i(true, true, true, true, false, false), .voiceCall)
        XCTAssertEqual(i(true, true, false, true, false, false), .eqModeChanged)
        XCTAssertEqual(i(true, true, false, false, false, false), .playerStopped)
        XCTAssertEqual(i(true, true, false, false, true, false), .outputChanged)
        XCTAssertNil(i(true, true, false, false, true, true))
    }
}
