import Foundation

enum KWeighting {
    private static let shelfFreq = 1681.974450955533
    private static let shelfQ = 0.7071752369554196
    private static let shelfGainDb = 3.999843853973347
    private static let shelfVbExponent = 0.4996667741545416
    private static let highpassFreq = 38.13547087602444
    private static let highpassQ = 0.5003270373238773

    static func designRate(_ sampleRate: Double) -> Double {
        guard sampleRate.isFinite else { return 48000 }
        return min(max(sampleRate, 8000), 768_000)
    }

    static func shelf(sampleRate: Double) -> BiquadSection {
        let k = tan(Double.pi * shelfFreq / designRate(sampleRate))
        let vh = pow(10, shelfGainDb / 20)
        let vb = pow(vh, shelfVbExponent)
        let a0 = 1 + k / shelfQ + k * k
        return BiquadSection(b0: (vh + vb * k / shelfQ + k * k) / a0,
                             b1: 2 * (k * k - vh) / a0,
                             b2: (vh - vb * k / shelfQ + k * k) / a0,
                             a1: 2 * (k * k - 1) / a0,
                             a2: (1 - k / shelfQ + k * k) / a0)
    }

    static func highpass(sampleRate: Double) -> BiquadSection {
        let k = tan(Double.pi * highpassFreq / designRate(sampleRate))
        let a0 = 1 + k / highpassQ + k * k
        return BiquadSection(b0: 1, b1: -2, b2: 1,
                             a1: 2 * (k * k - 1) / a0,
                             a2: (1 - k / highpassQ + k * k) / a0)
    }

    static func responseDb(shelf: BiquadSection, highpass: BiquadSection,
                           hz: Double, sampleRate: Double) -> Double {
        func magnitude(_ s: BiquadSection, _ w: Double) -> Double {
            let cos1 = cos(w), cos2 = cos(2 * w)
            let sin1 = sin(w), sin2 = sin(2 * w)
            let numRe = s.b0 + s.b1 * cos1 + s.b2 * cos2
            let numIm = -(s.b1 * sin1 + s.b2 * sin2)
            let denRe = 1 + s.a1 * cos1 + s.a2 * cos2
            let denIm = -(s.a1 * sin1 + s.a2 * sin2)
            return ((numRe * numRe + numIm * numIm)
                    / (denRe * denRe + denIm * denIm)).squareRoot()
        }
        let w = 2 * Double.pi * hz / designRate(sampleRate)
        return 20 * log10(magnitude(shelf, w) * magnitude(highpass, w))
    }
}

struct ShortTermLoudness {
    static let offsetDb = -0.691
    static let windowSeconds = 3

    private var ring: [(sum: Double, frames: Int)] = []

    mutating func add(sumSquares: Double, frames: Int) {
        guard frames > 0, sumSquares.isFinite, sumSquares >= 0 else { return }
        ring.append((sumSquares, frames))
        if ring.count > Self.windowSeconds {
            ring.removeFirst(ring.count - Self.windowSeconds)
        }
    }

    mutating func reset() { ring.removeAll(keepingCapacity: true) }

    var lufs: Double? {
        var sum = 0.0
        var frames = 0
        for entry in ring {
            sum += entry.sum
            frames += entry.frames
        }
        guard frames > 0 else { return nil }
        let power = sum / Double(frames)
        guard power > 0 else { return -.infinity }
        return Self.offsetDb + 10 * log10(power)
    }
}

struct AveragedLoudness {
    static let seconds = 30.0
    static let coefficient = 1 - exp(-1 / seconds)

    private(set) var lufs: Double?

    mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        lufs = lufs.map { $0 + Self.coefficient * (value - $0) } ?? value
    }

    mutating func reset() { lufs = nil }
}

enum EarVolumeAnchor: Equatable {
    case qudelix(Double)
    case system(Double)

    var db: Double {
        switch self {
        case .qudelix(let db), .system(let db): return db
        }
    }
}

enum EarLevelEstimate: Equatable {
    case unavailable
    case tooQuiet
    case estimated(Double)
}

enum EarLevel {
    static let defaultCalibrationDb: Double = 100
    static let calibrationSpanDb: Double = 30
    static let quietFloorLUFS: Double = -55
    static let calibrationRange: ClosedRange<Double> =
        (defaultCalibrationDb - calibrationSpanDb)...(defaultCalibrationDb + calibrationSpanDb)
    static let plausibleVolumeDb: ClosedRange<Double> = -160...20

    static let referenceDb: Double = 83
    static let shelfDbPerDeficitDb: Double = 0.35
    static let maxShelfDb: Double = 12
    static let trebleShelfRatio: Double = 0.3

    static func shelfDb(earLevelDb: Double?, strength: Double) -> Double {
        guard let level = earLevelDb, level.isFinite else { return 0 }
        let deficit = max(0, referenceDb - level)
        let s = strength.isFinite ? min(max(strength, 0), 1) : 0
        return min(maxShelfDb, deficit * shelfDbPerDeficitDb) * s
    }

    static func clampedCalibration(_ db: Double) -> Double {
        guard db.isFinite else { return defaultCalibrationDb }
        return min(max(db, calibrationRange.lowerBound), calibrationRange.upperBound)
    }

    static func estimate(shortTermLUFS: Double?, volumeDb: Double?,
                         calibrationDb: Double) -> EarLevelEstimate {
        guard let volumeDb, plausibleVolumeDb.contains(volumeDb) else { return .unavailable }
        guard let lufs = shortTermLUFS else { return .unavailable }
        guard lufs.isFinite, lufs > quietFloorLUFS else { return .tooQuiet }
        return .estimated((lufs + volumeDb + clampedCalibration(calibrationDb)).rounded())
    }
}
