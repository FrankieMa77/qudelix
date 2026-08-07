import XCTest
@testable import QudelixBar

/// The predicted-preference model, checked against curves whose SD and slope
/// can be worked out on paper rather than against a stored answer — an
/// expected value that was produced by the code under test would only confirm
/// that it still does whatever it did before, which is not what these
/// coefficients need guarding against.
final class PreferenceScoreTests: XCTestCase {

    /// A 1/12-octave grid wider than the analysis band, so the resampler has
    /// real samples either side of 50 Hz and 10 kHz.
    private func denseGrid(from: Double = 20, to: Double = 20_000) -> [Double] {
        var f = from
        var out: [Double] = []
        while f <= to * 1.0001 {
            out.append(f)
            f *= pow(2, 1.0 / 12.0)
        }
        return out
    }

    // MARK: - The model's fixed points

    /// A headphone sitting exactly on the target scores the intercept. Both
    /// predictors are zero, so equation 4 collapses to 114.49 — which is also
    /// the reminder that the scale is not a percentage and does not stop at
    /// 100.
    func testPerfectCurveScoresTheIntercept() {
        let f = denseGrid()
        let r = PreferenceScore.reading(frequencies: f, errorDb: f.map { _ in 0 })
        XCTAssertEqual(r?.score ?? .nan, 114.49, accuracy: 1e-9)
        XCTAssertEqual(r?.standardDeviation ?? .nan, 0, accuracy: 1e-12)
        XCTAssertEqual(r?.absoluteSlope ?? .nan, 0, accuracy: 1e-12)
    }

    /// A curve tilted by exactly one dB per natural-log unit of frequency has
    /// AS = 1 by definition, and SD equal to the spread of ln(f) over the
    /// analysis grid, which is 1.5541351065 for the 93 points from 50 Hz to
    /// 10 kHz.
    func testUnitLogTiltMatchesTheHandComputedPredictors() {
        let f = denseGrid()
        let r = PreferenceScore.reading(frequencies: f, errorDb: f.map { log($0) })
        XCTAssertEqual(r?.absoluteSlope ?? .nan, 1.0, accuracy: 1e-9)
        XCTAssertEqual(r?.standardDeviation ?? .nan, 1.554135106506, accuracy: 1e-9)
        XCTAssertEqual(r?.score ?? .nan,
                       114.49 - 12.62 * 1.554135106506 - 15.52, accuracy: 1e-9)
    }

    /// The same tilt expressed the way a listener would describe it. One dB
    /// per octave is 1/ln2 per log unit, so a headphone only a decibel an
    /// octave off target already gives up 50 rating points — the tilt term
    /// dominates, which is the model's central claim.
    func testOneDecibelPerOctaveTilt() {
        let f = denseGrid()
        let perLogUnit = 1 / log(2.0)
        let r = PreferenceScore.reading(frequencies: f, errorDb: f.map { perLogUnit * log($0) })
        XCTAssertEqual(r?.absoluteSlope ?? .nan, perLogUnit, accuracy: 1e-9)
        XCTAssertEqual(r?.score ?? .nan, 63.803528166230, accuracy: 1e-6)
    }

    /// Ripple with no net tilt: alternating ±2 dB on the analysis grid itself,
    /// so no interpolation happens. The population it is drawn from has
    /// standard deviation 2, and the sample estimate over 93 points lands just
    /// above it; the regression finds essentially no slope.
    func testRippleIsChargedToDeviationNotSlope() {
        let f = PreferenceScore.analysisFrequencies
        let y = f.indices.map { $0.isMultiple(of: 2) ? 2.0 : -2.0 }
        let r = PreferenceScore.reading(frequencies: f, errorDb: y)
        XCTAssertEqual(r?.standardDeviation ?? .nan, 2.010723937463, accuracy: 1e-9)
        XCTAssertEqual(r?.absoluteSlope ?? .nan, 0, accuracy: 1e-3)
        XCTAssertEqual(r?.score ?? .nan, 89.105808773238, accuracy: 1e-6)
    }

    // MARK: - Invariances the model is entitled to

    /// Level is not tone. A correction that is 6 dB quieter overall is the
    /// same correction, and the score must not move — this is what lets a
    /// caller skip deciding where to align the response against the target.
    func testConstantOffsetDoesNotChangeTheScore() {
        let f = denseGrid()
        let shape = f.map { 3 * sin(log($0)) }
        let plain = PreferenceScore.reading(frequencies: f, errorDb: shape)
        let lifted = PreferenceScore.reading(frequencies: f, errorDb: shape.map { $0 + 6 })
        XCTAssertEqual(plain?.score ?? .nan, lifted?.score ?? .infinity, accuracy: 1e-9)
    }

    /// Neither predictor can tell a bright headphone from a dull one of the
    /// same magnitude: SD ignores sign and AS is taken absolute. Worth pinning
    /// because it is a real limit of the model, not an implementation detail —
    /// two headphones that sound nothing alike can score identically.
    func testMirroredErrorCurvesScoreTheSame() {
        let f = denseGrid()
        let shape = f.map { 2.5 * log($0) - 4 }
        let up = PreferenceScore.reading(frequencies: f, errorDb: shape)
        let down = PreferenceScore.reading(frequencies: f, errorDb: shape.map { -$0 })
        XCTAssertEqual(up?.score ?? .nan, down?.score ?? .infinity, accuracy: 1e-9)
    }

    /// Everything outside 50 Hz–10 kHz is excluded, including the sub-bass the
    /// authors dropped on purpose. A curve wrecked below 40 Hz and above
    /// 13 kHz — deviation that would dominate a plain RMS error — scores
    /// exactly as its in-band twin.
    ///
    /// The margins are not padding for its own sake: the samples immediately
    /// outside the band are still read, because the 50 Hz and 10 kHz grid
    /// points interpolate between their neighbours on either side.
    func testDeviationOutsideTheBandIsIgnored() {
        let f = denseGrid()
        let clean = f.map { _ in 0.0 }
        let wrecked = f.map { $0 < 40 || $0 > 13_000 ? 20.0 : 0.0 }
        let a = PreferenceScore.reading(frequencies: f, errorDb: clean)
        let b = PreferenceScore.reading(frequencies: f, errorDb: wrecked)
        XCTAssertEqual(a?.score ?? .nan, b?.score ?? .infinity, accuracy: 1e-9)
    }

    /// Sampling density is the caller's choice; the score is not. The same
    /// analytic curve handed over at 1/12 and 1/24 octave must rank the same,
    /// which is the whole reason the predictors are computed on a fixed grid.
    func testScoreDoesNotDependOnTheCallersSamplingDensity() {
        func score(step: Double) -> Double {
            var f: [Double] = [], x = 20.0
            while x <= 20_000 { f.append(x); x *= pow(2, step) }
            return PreferenceScore.reading(frequencies: f,
                                           errorDb: f.map { 2 * sin(1.7 * log($0)) })?.score ?? .nan
        }
        XCTAssertEqual(score(step: 1.0 / 12.0), score(step: 1.0 / 24.0), accuracy: 0.05)
    }

    // MARK: - Ordering

    /// The property the ranking rests on: hold the shape, grow the error, and
    /// the score falls monotonically.
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

    /// Differencing a response against a target is the same calculation as
    /// handing over the difference, so a caller holding two curves need not
    /// build the third.
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

    // MARK: - Refusals

    /// A curve that starts above 50 Hz or stops below 10 kHz cannot be scored
    /// on the published scale, and a score over part of the band would rank
    /// against full-band scores wrongly. No extrapolation, no answer.
    func testCurvesThatMissTheBandAreRefused() {
        let short = denseGrid(from: 60, to: 20_000)
        XCTAssertNil(PreferenceScore.reading(frequencies: short, errorDb: short.map { _ in 0 }))
        let low = denseGrid(from: 20, to: 8_000)
        XCTAssertNil(PreferenceScore.reading(frequencies: low, errorDb: low.map { _ in 0 }))
    }

    /// A coarse curve interpolates into a smooth one, and smooth curves score
    /// well. Refusing is the only way not to reward a caller for asking its
    /// source for less detail.
    func testTooCoarseAnInputIsRefused() {
        let coarse = denseGrid(from: 20, to: 20_000).enumerated()
            .filter { $0.offset.isMultiple(of: 4) }.map(\.element)   // 1/3 octave
        XCTAssertNil(PreferenceScore.reading(frequencies: coarse, errorDb: coarse.map { _ in 0 }))
    }

    /// Coarse sampling outside the band is fine — nothing reads it.
    func testCoarseTailsOutsideTheBandAreAccepted() {
        var f = [20.0, 30.0, 45.0]
        f += denseGrid(from: 48, to: 10_400)
        f += [14_000.0, 20_000.0]
        XCTAssertNotNil(PreferenceScore.reading(frequencies: f, errorDb: f.map { _ in 0 }))
    }

    /// Malformed input never produces a number that looks like a score.
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

    /// The model was fitted on around-ear and on-ear headphones only. In-ear
    /// gear has its own published model with different predictors, and these
    /// coefficients must not be quietly borrowed for it.
    func testOnlyOverEarFormFactorsAreCovered() {
        XCTAssertTrue(PreferenceScore.appliesTo(form: "over-ear"))
        XCTAssertFalse(PreferenceScore.appliesTo(form: "in-ear"))
        XCTAssertFalse(PreferenceScore.appliesTo(form: "earbud"))
        XCTAssertFalse(PreferenceScore.appliesTo(form: nil))
    }

    /// The grid is the one part of the calculation the paper leaves open, so
    /// it is pinned here: 93 points, ascending, spanning exactly the band.
    /// Everything is resampled onto 93 points, so a denser input buys the
    /// score nothing and costs the caller a pass over every sample. Past the
    /// bound it is refused rather than worked through.
    func testAnInputDenserThanTheModelReadsIsRefused() {
        // 20 Hz to 20 kHz either way, so spacing cannot be what refuses it.
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

/// Scoring the residual: what is left after *this device's* filters, which is
/// the number worth showing. A perfect correction is not the interesting case
/// — a ten-band fit that cannot follow every wrinkle is.
final class ResidualScoreTests: XCTestCase {

    private let freqs: [Double] = (0..<120).map { 20 * pow(2.0, Double($0) / 12) }

    private func response(_ decoded: [Double]) -> EqualizeResponse {
        EqualizeResponse(
            parametricEq: PEQResult(fs: 48000, filters: [], preamp: 0),
            fr: FrequencyResponse(frequency: freqs, error: decoded))
    }

    /// A curve already on target scores the model's intercept, and a device
    /// that corrects nothing leaves it there.
    func testAnAlreadyFlatErrorScoresTheIntercept() {
        let r = AutoEqService.residualScore(response(freqs.map { _ in 0 }),
                                            file: ParametricEQFile(),
                                            limits: .qudelix(bandCount: 10))
        XCTAssertEqual(r?.score ?? 0, 114.49, accuracy: 0.01)
    }

    /// The device's own filters are added to the measured error, so a
    /// correction that cancels a bump must score better than no correction.
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

    /// Bands the mode cannot hold never reach the device, so they must not be
    /// credited in the score either.
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

    /// A response with no curve is still a good filter set; only the score is
    /// lost, and it must be lost rather than invented.
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

    /// The scoring work is bounded by the analysis grid, not by whatever the
    /// server decided to send: an over-dense response is turned away before a
    /// single biquad is evaluated, because this all happens on the thread
    /// drawing the window.
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

    /// The model is fitted on over-ear headphones. Anything else gets no score
    /// rather than the wrong one.
    func testTheModelIsRefusedForInEarAndEarbud() {
        XCTAssertTrue(PreferenceScore.appliesTo(form: "over-ear"))
        for form in ["in-ear", "earbud", nil, "on-ear", ""] {
            XCTAssertFalse(PreferenceScore.appliesTo(form: form), "form \(form ?? "nil")")
        }
    }
}
