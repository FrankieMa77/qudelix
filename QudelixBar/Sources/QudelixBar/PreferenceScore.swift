import Foundation

enum PreferenceScore {
    struct Reading: Equatable {
        var score: Double
        var standardDeviation: Double
        var absoluteSlope: Double
    }

    static let intercept = 114.49
    static let deviationWeight = 12.62
    static let slopeWeight = 15.52

    static let bandLow: Double = 50
    static let bandHigh: Double = 10_000

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

    static let maxInputSpacingOctaves = 1.0 / 6.0

    static let maxInputPoints = 512

    static func reading(frequencies: [Double], errorDb: [Double]) -> Reading? {
        guard let y = resampleOntoAnalysisGrid(frequencies: frequencies, values: errorDb) else {
            return nil
        }
        let sd = standardDeviation(of: y)
        let slope = abs(logSlope(of: y))
        return Reading(score: intercept - deviationWeight * sd - slopeWeight * slope,
                       standardDeviation: sd, absoluteSlope: slope)
    }

    static func reading(frequencies: [Double],
                        responseDb: [Double], targetDb: [Double]) -> Reading? {
        guard responseDb.count == targetDb.count else { return nil }
        return reading(frequencies: frequencies,
                       errorDb: zip(responseDb, targetDb).map(-))
    }

    static func appliesTo(form: String?) -> Bool { form == "over-ear" }

    static func standardDeviation(of y: [Double]) -> Double {
        guard y.count > 1 else { return 0 }
        let mean = y.reduce(0, +) / Double(y.count)
        let sumSquares = y.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (sumSquares / Double(y.count - 1)).squareRoot()
    }

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
