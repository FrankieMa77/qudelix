import XCTest
@testable import QudelixBar

final class PreferenceScoreTests: XCTestCase {
    private func denseGrid(from: Double = 20, to: Double = 20_000) -> [Double] {
        var f = from
        var out: [Double] = []
        while f <= to * 1.0001 {
            out.append(f)
            f *= pow(2, 1.0 / 12.0)
        }
        return out
    }

    func testPerfectCurveScoresTheIntercept() {
        let f = denseGrid()
        let r = PreferenceScore.reading(frequencies: f, errorDb: f.map { _ in 0 })
        XCTAssertEqual(r?.score ?? .nan, 114.49, accuracy: 1e-9)
        XCTAssertEqual(r?.standardDeviation ?? .nan, 0, accuracy: 1e-12)
        XCTAssertEqual(r?.absoluteSlope ?? .nan, 0, accuracy: 1e-12)
    }

    func testUnitLogTiltMatchesTheHandComputedPredictors() {
        let f = denseGrid()
        let r = PreferenceScore.reading(frequencies: f, errorDb: f.map { log($0) })
        XCTAssertEqual(r?.absoluteSlope ?? .nan, 1.0, accuracy: 1e-9)
        XCTAssertEqual(r?.standardDeviation ?? .nan, 1.554135106506, accuracy: 1e-9)
        XCTAssertEqual(r?.score ?? .nan,
                       114.49 - 12.62 * 1.554135106506 - 15.52, accuracy: 1e-9)
    }

    func testOneDecibelPerOctaveTilt() {
        let f = denseGrid()
        let perLogUnit = 1 / log(2.0)
        let r = PreferenceScore.reading(frequencies: f, errorDb: f.map { perLogUnit * log($0) })
        XCTAssertEqual(r?.absoluteSlope ?? .nan, perLogUnit, accuracy: 1e-9)
        XCTAssertEqual(r?.score ?? .nan, 63.803528166230, accuracy: 1e-6)
    }

    func testRippleIsChargedToDeviationNotSlope() {
        let f = PreferenceScore.analysisFrequencies
        let y = f.indices.map { $0.isMultiple(of: 2) ? 2.0 : -2.0 }
        let r = PreferenceScore.reading(frequencies: f, errorDb: y)
        XCTAssertEqual(r?.standardDeviation ?? .nan, 2.010723937463, accuracy: 1e-9)
        XCTAssertEqual(r?.absoluteSlope ?? .nan, 0, accuracy: 1e-3)
        XCTAssertEqual(r?.score ?? .nan, 89.105808773238, accuracy: 1e-6)
    }

    func testConstantOffsetDoesNotChangeTheScore() {
        let f = denseGrid()
        let shape = f.map { 3 * sin(log($0)) }
        let plain = PreferenceScore.reading(frequencies: f, errorDb: shape)
        let lifted = PreferenceScore.reading(frequencies: f, errorDb: shape.map { $0 + 6 })
        XCTAssertEqual(plain?.score ?? .nan, lifted?.score ?? .infinity, accuracy: 1e-9)
    }

    func testMirroredErrorCurvesScoreTheSame() {
        let f = denseGrid()
        let shape = f.map { 2.5 * log($0) - 4 }
        let up = PreferenceScore.reading(frequencies: f, errorDb: shape)
        let down = PreferenceScore.reading(frequencies: f, errorDb: shape.map { -$0 })
        XCTAssertEqual(up?.score ?? .nan, down?.score ?? .infinity, accuracy: 1e-9)
    }

    func testDeviationOutsideTheBandIsIgnored() {
        let f = denseGrid()
        let clean = f.map { _ in 0.0 }
        let wrecked = f.map { $0 < 40 || $0 > 13_000 ? 20.0 : 0.0 }
        let a = PreferenceScore.reading(frequencies: f, errorDb: clean)
        let b = PreferenceScore.reading(frequencies: f, errorDb: wrecked)
        XCTAssertEqual(a?.score ?? .nan, b?.score ?? .infinity, accuracy: 1e-9)
    }

    func testScoreDoesNotDependOnTheCallersSamplingDensity() {
        func score(step: Double) -> Double {
            var f: [Double] = [], x = 20.0
            while x <= 20_000 { f.append(x); x *= pow(2, step) }
            return PreferenceScore.reading(frequencies: f,
                                           errorDb: f.map { 2 * sin(1.7 * log($0)) })?.score ?? .nan
        }
        XCTAssertEqual(score(step: 1.0 / 12.0), score(step: 1.0 / 24.0), accuracy: 0.05)
    }

    func testLargerDeviationScoresLower() {
        let f = denseGrid()
        let scores = [0.5, 1.0, 2.0, 4.0].map { amplitude in
            PreferenceScore.reading(frequencies: f,
                                    errorDb: f.map { amplitude * sin(2 * log($0)) })?.score ?? .nan
        }
        for i in 1..<scores.count {
            XCTAssertLessThan(scores[i], scores[i - 1])
        }
    }

    func testResponseAndTargetMatchAPreDifferencedCurve() {
        let f = denseGrid()
        let response = f.map { 1.5 * sin(log($0)) + 84 }
        let target = f.map { _ in 84.0 }
        let paired = PreferenceScore.reading(frequencies: f,
                                             responseDb: response, targetDb: target)
        let differenced = PreferenceScore.reading(frequencies: f,
                                                  errorDb: zip(response, target).map(-))
        XCTAssertEqual(paired?.score ?? .nan, differenced?.score ?? .infinity, accuracy: 1e-12)
    }

    func testCurvesThatMissTheBandAreRefused() {
        let short = denseGrid(from: 60, to: 20_000)
        XCTAssertNil(PreferenceScore.reading(frequencies: short, errorDb: short.map { _ in 0 }))
        let low = denseGrid(from: 20, to: 8_000)
        XCTAssertNil(PreferenceScore.reading(frequencies: low, errorDb: low.map { _ in 0 }))
    }

    func testTooCoarseAnInputIsRefused() {
        let coarse = denseGrid(from: 20, to: 20_000).enumerated()
            .filter { $0.offset.isMultiple(of: 4) }.map(\.element)
        XCTAssertNil(PreferenceScore.reading(frequencies: coarse, errorDb: coarse.map { _ in 0 }))
    }

    func testCoarseTailsOutsideTheBandAreAccepted() {
        var f = [20.0, 30.0, 45.0]
        f += denseGrid(from: 48, to: 10_400)
        f += [14_000.0, 20_000.0]
        XCTAssertNotNil(PreferenceScore.reading(frequencies: f, errorDb: f.map { _ in 0 }))
    }

    func testMalformedInputIsRefused() {
        let f = denseGrid()
        var reversed = f; reversed.swapAt(30, 40)
        XCTAssertNil(PreferenceScore.reading(frequencies: reversed, errorDb: f.map { _ in 0 }))

        var withNaN = f.map { _ in 0.0 }; withNaN[50] = .nan
        XCTAssertNil(PreferenceScore.reading(frequencies: f, errorDb: withNaN))

        XCTAssertNil(PreferenceScore.reading(frequencies: f, errorDb: [0, 0, 0]))
        XCTAssertNil(PreferenceScore.reading(frequencies: [], errorDb: []))
        XCTAssertNil(PreferenceScore.reading(frequencies: f,
                                             responseDb: f.map { _ in 0 }, targetDb: [0]))
    }

    func testOnlyOverEarFormFactorsAreCovered() {
        XCTAssertTrue(PreferenceScore.appliesTo(form: "over-ear"))
        XCTAssertFalse(PreferenceScore.appliesTo(form: "in-ear"))
        XCTAssertFalse(PreferenceScore.appliesTo(form: "earbud"))
        XCTAssertFalse(PreferenceScore.appliesTo(form: nil))
    }

    func testAnInputDenserThanTheModelReadsIsRefused() {
        func grid(_ n: Int) -> [Double] {
            (0..<n).map { 20 * pow(1000, Double($0) / Double(n - 1)) }
        }
        let over = grid(PreferenceScore.maxInputPoints + 1)
        XCTAssertNil(PreferenceScore.reading(frequencies: over, errorDb: over.map { _ in 0 }))

        let atTheBound = grid(PreferenceScore.maxInputPoints)
        XCTAssertNotNil(PreferenceScore.reading(frequencies: atTheBound,
                                                errorDb: atTheBound.map { _ in 0 }),
                        "the bound itself is still readable")
    }

    func testAnalysisGridSpansTheBandAtTwelfthOctave() {
        let g = PreferenceScore.analysisFrequencies
        XCTAssertEqual(g.count, 93)
        XCTAssertEqual(g.first, PreferenceScore.bandLow)
        XCTAssertEqual(g.last, PreferenceScore.bandHigh)
        for i in 1..<g.count {
            XCTAssertGreaterThan(g[i], g[i - 1])
            XCTAssertLessThan(g[i] / g[i - 1], pow(2, 1.0 / 10.0))
        }
    }
}

final class ResidualScoreTests: XCTestCase {
    private let freqs: [Double] = (0..<120).map { 20 * pow(2.0, Double($0) / 12) }

    private func response(_ decoded: [Double]) -> EqualizeResponse {
        EqualizeResponse(
            parametricEq: PEQResult(fs: 48000, filters: [], preamp: 0),
            fr: FrequencyResponse(frequency: freqs, error: decoded))
    }

    func testAnAlreadyFlatErrorScoresTheIntercept() {
        let r = AutoEqService.residualScore(response(freqs.map { _ in 0 }),
                                            file: ParametricEQFile(),
                                            limits: .qudelix(bandCount: 10))
        XCTAssertEqual(r?.score ?? 0, 114.49, accuracy: 0.01)
    }

    func testCorrectingABumpScoresBetterThanLeavingIt() {
        let bump = freqs.map { f in 6 * exp(-pow(log(f / 3000), 2) / 0.02) }
        let uncorrected = AutoEqService.residualScore(response(bump),
                                                      file: ParametricEQFile(),
                                                      limits: .qudelix(bandCount: 10))
        var fixed = ParametricEQFile()
        fixed.bands = [QxEqBandValue(filter: .peak, freq: 3000, gain: -6, q: 4)]
        let corrected = AutoEqService.residualScore(response(bump), file: fixed,
                                                    limits: .qudelix(bandCount: 10))
        XCTAssertNotNil(corrected)
        XCTAssertGreaterThan(corrected!.score, uncorrected!.score + 1,
                             "cancelling the bump has to move the score")
        XCTAssertLessThan(corrected!.standardDeviation, uncorrected!.standardDeviation)
    }

    func testBandsBeyondTheModeAreNotCredited() {
        let bump = freqs.map { f in 6 * exp(-pow(log(f / 3000), 2) / 0.02) }
        var file = ParametricEQFile()
        file.bands = Array(repeating: QxEqBandValue(filter: .peak, freq: 100, gain: 0, q: 1),
                           count: 10)
            + [QxEqBandValue(filter: .peak, freq: 3000, gain: -6, q: 4)]
        let scored = AutoEqService.residualScore(response(bump), file: file,
                                                 limits: .qudelix(bandCount: 10))
        let none = AutoEqService.residualScore(response(bump), file: ParametricEQFile(),
                                               limits: .qudelix(bandCount: 10))
        XCTAssertEqual(scored?.score ?? 0, none?.score ?? -1, accuracy: 0.01,
                       "the 11th band is dropped by a 10-band device and must not count")
    }

    func testAResponseWithoutACurveScoresNothing() {
        let bare = EqualizeResponse(
            parametricEq: PEQResult(fs: 48000, filters: [], preamp: 0), fr: nil)
        XCTAssertNil(AutoEqService.residualScore(bare, file: ParametricEQFile(),
                                                 limits: .qudelix(bandCount: 10)))
        let mismatched = EqualizeResponse(
            parametricEq: PEQResult(fs: 48000, filters: [], preamp: 0),
            fr: FrequencyResponse(frequency: freqs, error: [0, 0]))
        XCTAssertNil(AutoEqService.residualScore(mismatched, file: ParametricEQFile(),
                                                 limits: .qudelix(bandCount: 10)))
    }

    func testAnOverDenseResponseScoresNothing() {
        let n = PreferenceScore.maxInputPoints + 1
        let dense = (0..<n).map { 20 * pow(1000, Double($0) / Double(n - 1)) }
        var file = ParametricEQFile()
        file.bands = [QxEqBandValue(filter: .peak, freq: 3000, gain: -6, q: 4)]
        let response = EqualizeResponse(
            parametricEq: PEQResult(fs: 48000, filters: [], preamp: 0),
            fr: FrequencyResponse(frequency: dense, error: dense.map { _ in 0 }))
        XCTAssertNil(AutoEqService.residualScore(response, file: file,
                                                 limits: .qudelix(bandCount: 10)))
    }

    func testTheModelIsRefusedForInEarAndEarbud() {
        XCTAssertTrue(PreferenceScore.appliesTo(form: "over-ear"))
        for form in ["in-ear", "earbud", nil, "on-ear", ""] {
            XCTAssertFalse(PreferenceScore.appliesTo(form: form), "form \(form ?? "nil")")
        }
    }
}
