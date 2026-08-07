import Foundation

/// Predicted preference rating for an around-ear or on-ear headphone: the
/// score a panel of listeners would give it *on average*, computed from how
/// far its magnitude response sits from the Harman AE/OE target curve.
///
/// The model is Olive, Welti and Khonsaripour, "A Statistical Model that
/// Predicts Listeners' Preference Ratings of Around-Ear and On-Ear
/// Headphones", AES 144th Convention, Milan, May 2018, convention paper 9919.
/// The two predictors, their frequency band, and all three coefficients below
/// are transcribed from that paper's equations 2, 3 and 4. Nothing here is
/// inferred from a restatement of it.
///
/// What this number is not: a judgement of whether a headphone will sound
/// good to the person holding it. It is the fitted mean of 31,200 ratings
/// from 130 listeners across 31 headphones, and the same research programme's
/// clustering of those listeners put only about two thirds of them in the
/// group whose taste the target actually describes — the rest want measurably
/// more or less bass. Two corrections a point apart are indistinguishable;
/// the model's own residual error is ±6.7 rating points. Anything built on
/// top of this has to carry that framing with it.
enum PreferenceScore {

    /// The score and the two quantities it is made of, so a caller can show
    /// *why* one correction scored above another rather than only that it did.
    struct Reading: Equatable {
        /// Predicted mean preference rating. Deliberately unclamped: the fit
        /// is a plain linear model, its intercept is 114.49, and the paper's
        /// own scatterplot (Fig. 5) carries a headphone predicted near 115.
        /// Clamping to 0…100 here would quietly flatten the top of the range
        /// where candidate corrections are most likely to land, which is
        /// exactly where a ranking needs resolution.
        var score: Double
        /// SD in the paper: how ragged the error curve is, in dB.
        var standardDeviation: Double
        /// AS in the paper: how tilted it is, in dB per natural-log unit of
        /// frequency. Already an absolute value, so bright and dull tilts of
        /// equal size are penalised equally — the model has no opinion about
        /// direction.
        var absoluteSlope: Double
    }

    // MARK: - The published model

    /// Equation 4's intercept and the two slopes, exactly as printed.
    ///
    /// Higher-precision variants of these (114.490443008238, 15.5163857197367)
    /// circulate in third-party implementations. They shift the result by
    /// under a hundredth of a rating point and have no published origin, so
    /// the paper's own figures are what get used.
    static let intercept = 114.49
    static let deviationWeight = 12.62
    static let slopeWeight = 15.52

    /// The band both predictors are measured over. The authors chose the
    /// 50 Hz floor deliberately, not for convenience: errors below it
    /// "contributed little to the underlying variance in headphone
    /// preferences", because nearly every headphone in the sample rolls off
    /// down there and so the deviation carries no discriminating information.
    /// The 10 kHz ceiling matches the range over which their virtualisation
    /// rig was trustworthy.
    static let bandLow: Double = 50
    static let bandHigh: Double = 10_000

    /// The 1/12-octave grid the predictors are evaluated on, 50 Hz to 10 kHz.
    ///
    /// This is the one part of the calculation the paper leaves open, and it
    /// is not a detail: SD is an unweighted standard deviation over whatever
    /// points it is handed, so a linearly-spaced input would let the octave
    /// above 5 kHz outvote everything below 500 Hz and produce a different
    /// number for the same headphone. Fixing a log-spaced grid is what makes
    /// the score a property of the curve rather than of the caller's
    /// sampling. These particular frequencies are the ISO preferred series
    /// that the Harman-derived reference spreadsheet uses, so scores computed
    /// here line up with scores quoted elsewhere.
    static let analysisFrequencies: [Double] = [
        50, 53, 56, 60, 63, 67, 71, 75, 80, 85, 90, 95,
        100, 106, 112, 118, 125, 132, 140, 150, 160, 170, 180, 190,
        200, 212, 224, 236, 250, 265, 280, 300, 315, 335, 355, 375,
        400, 425, 450, 475, 500, 530, 560, 600, 630, 670, 710, 750,
        800, 850, 900, 950, 1000, 1060, 1120, 1180, 1250, 1320, 1400, 1500,
        1600, 1700, 1800, 1900, 2000, 2120, 2240, 2360, 2500, 2650, 2800, 3000,
        3150, 3350, 3550, 3750, 4000, 4250, 4500, 4750, 5000, 5300, 5600, 6000,
        6300, 6700, 7100, 7500, 8000, 8500, 9000, 9500, 10_000
    ]

    /// Widest gap tolerated between two input samples inside the band, in
    /// octaves.
    ///
    /// Interpolating a sparse curve up to the analysis grid does not recover
    /// the ripple that sparse sampling threw away — it straightens it, which
    /// shrinks SD and hands back a flattering score for a curve nobody
    /// measured properly. One interpolated point between real ones is the
    /// most this will invent; past that it refuses. A caller fetching a
    /// response for scoring has to ask its source for a fine enough one.
    static let maxInputSpacingOctaves = 1.0 / 6.0

    /// Most samples an input curve may carry.
    ///
    /// Everything handed in is resampled onto the 93-point grid above, so a
    /// denser input buys the score no accuracy at all — it only buys work, and
    /// the work happens on the thread drawing the window. A 1/12-octave curve
    /// across the audible range is about 120 samples and a 1/48-octave one
    /// about 480, so this admits anything a source has a reason to send and
    /// refuses the rest outright. Refusing costs a caller its score; reading a
    /// response with a hundred thousand points in it would cost the user the
    /// window.
    static let maxInputPoints = 512

    // MARK: - Scoring

    /// The reading for an error curve — headphone minus target, in dB, at
    /// ascending frequencies.
    ///
    /// nil whenever the curve cannot honestly be scored: it does not reach
    /// both ends of the band, its samples are too far apart or there are more
    /// of them than `maxInputPoints`, its frequencies are out of order or
    /// non-positive, or any value is not a number. There is no partial answer
    /// worth returning, because a score computed over part of the band is not
    /// on the same scale as one computed over all of it and would rank against
    /// it wrongly.
    ///
    /// The result is invariant to a constant dB offset on the whole curve, by
    /// construction: a standard deviation ignores the mean and a regression
    /// slope ignores the intercept. That is why the caller does not have to
    /// decide where to align the two curves first, and why the third variable
    /// the authors tried and dropped — mean absolute error, which is *not*
    /// offset-invariant — could not have been used without that decision.
    static func reading(frequencies: [Double], errorDb: [Double]) -> Reading? {
        guard let y = resampleOntoAnalysisGrid(frequencies: frequencies, values: errorDb) else {
            return nil
        }
        let sd = standardDeviation(of: y)
        let slope = abs(logSlope(of: y))
        return Reading(score: intercept - deviationWeight * sd - slopeWeight * slope,
                       standardDeviation: sd, absoluteSlope: slope)
    }

    /// The reading for a measured response and a target sampled on the same
    /// grid, differenced here so the caller does not have to.
    static func reading(frequencies: [Double],
                        responseDb: [Double], targetDb: [Double]) -> Reading? {
        guard responseDb.count == targetDb.count else { return nil }
        return reading(frequencies: frequencies,
                       errorDb: zip(responseDb, targetDb).map(-))
    }

    /// Whether the published model covers a catalogue form factor.
    ///
    /// "over-ear" in the catalogue's vocabulary spans both the around-ear and
    /// on-ear designs the paper tested, which is why it is the only accepted
    /// value. In-ear and earbud are excluded on purpose: the authors fitted a
    /// separate model for in-ear headphones with a different predictor set
    /// and different bands, and its coefficients are not available from the
    /// paper that publishes it. Reusing these coefficients across the gap
    /// would be a guess wearing a citation.
    static func appliesTo(form: String?) -> Bool { form == "over-ear" }

    // MARK: - Predictors

    /// Equation 2: the sample standard deviation of the error curve, over
    /// n − 1 rather than n, as printed.
    static func standardDeviation(of y: [Double]) -> Double {
        guard y.count > 1 else { return 0 }
        let mean = y.reduce(0, +) / Double(y.count)
        let sumSquares = y.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (sumSquares / Double(y.count - 1)).squareRoot()
    }

    /// Equation 3: the least-squares slope of the error curve regressed on
    /// log frequency, in dB per natural-log unit.
    ///
    /// Equation 3 as typeset draws a radical over the whole fraction and puts
    /// the exponent inside the denominator's logarithm. Neither can be meant.
    /// The covariance in the numerator is signed, so the root would be
    /// undefined for every headphone with a rising error curve, and the
    /// surrounding prose asks plainly for "the slope of a logarithmic
    /// regression line" — which is this expression without the radical. The
    /// equation is transcribed as the text describes it, not as the equation
    /// editor rendered it, and that is the single place this file departs
    /// from the printed page.
    static func logSlope(of y: [Double]) -> Double {
        let x = analysisFrequencies.map(log)
        guard y.count == x.count, y.count > 1 else { return 0 }
        let xMean = x.reduce(0, +) / Double(x.count)
        let yMean = y.reduce(0, +) / Double(y.count)
        var covariance = 0.0, variance = 0.0
        for i in x.indices {
            let dx = x[i] - xMean
            covariance += dx * (y[i] - yMean)
            variance += dx * dx
        }
        guard variance > 0 else { return 0 }
        return covariance / variance
    }

    // MARK: - Grid

    /// Linear-in-dB, linear-in-log-frequency interpolation onto the analysis
    /// grid, or nil if the input does not support it.
    ///
    /// dB against log frequency is the space the curve is drawn, read and
    /// regressed in, so a straight line between two samples there is the
    /// interpolation that adds the least shape of its own.
    private static func resampleOntoAnalysisGrid(frequencies: [Double],
                                                 values: [Double]) -> [Double]? {
        guard frequencies.count == values.count, frequencies.count > 1,
              frequencies.count <= maxInputPoints else { return nil }
        guard let first = frequencies.first, let last = frequencies.last,
              first > 0, first <= bandLow, last >= bandHigh else { return nil }

        let maxRatio = pow(2, maxInputSpacingOctaves)
        for i in 1..<frequencies.count {
            let lo = frequencies[i - 1], hi = frequencies[i]
            guard lo > 0, hi > lo, values[i].isFinite, values[i - 1].isFinite else { return nil }
            // Only spacing that lands inside the band can distort the
            // predictors; a coarse tail below 50 Hz or above 10 kHz is read
            // by nobody here.
            if hi > bandLow, lo < bandHigh, hi / lo > maxRatio { return nil }
        }

        var out = [Double](repeating: 0, count: analysisFrequencies.count)
        var i = 1
        for (k, f) in analysisFrequencies.enumerated() {
            while i < frequencies.count - 1, frequencies[i] < f { i += 1 }
            let f0 = frequencies[i - 1], f1 = frequencies[i]
            let t = (log(f) - log(f0)) / (log(f1) - log(f0))
            out[k] = values[i - 1] + t * (values[i] - values[i - 1])
        }
        return out
    }
}
