import Foundation

enum LevelMatch {
    static let lowHz: Double = 100
    static let highHz: Double = 8000
    static let points = 129
    static let toleranceDb: Double = 0.1

    nonisolated static let grid: [Double] = {
        let l0 = log10(lowHz), l1 = log10(highHz)
        return (0..<points).map { i in
            pow(10, l0 + (l1 - l0) * (Double(i) + 0.5) / Double(points))
        }
    }()

    nonisolated static func meanLevelDb(bands: [QxEqBandValue], preGain: Double = 0) -> Double {
        let response = EQCurve.response(bands: bands, preGain: preGain, at: grid)
        guard !response.isEmpty else { return preGain }
        return response.reduce(0, +) / Double(response.count)
    }

    nonisolated static func matchedPreGains(_ a: [QxEqBandValue], _ b: [QxEqBandValue],
                                            base: Double) -> (a: Double, b: Double) {
        let levelA = meanLevelDb(bands: a), levelB = meanLevelDb(bands: b)
        let quieter = min(levelA, levelB)
        return (trimmed(base, by: levelA - quieter), trimmed(base, by: levelB - quieter))
    }

    nonisolated static func trimmed(_ base: Double, by trim: Double) -> Double {
        guard base.isFinite else { return 0 }
        guard trim.isFinite else { return EQHeadroom.clamp(base) }
        return EQHeadroom.clamp(base - max(0, trim))
    }
}
