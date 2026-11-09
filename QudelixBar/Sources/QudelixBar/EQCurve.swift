import Foundation

enum EQCurve {
    static let sampleRate: Double = 48000
    static let minFreq: Double = 20
    static let maxFreq: Double = 20000

    static func response(bands: [QxEqBandValue], preGain: Double, count: Int = 220) -> [Double] {
        response(bands: bands, preGain: preGain, at: logSweep(count: count))
    }

    static func response(bands: [QxEqBandValue], preGain: Double, at freqs: [Double]) -> [Double] {
        let filters = bands.compactMap(BandFilter.init(band:))
        guard !filters.isEmpty else { return [Double](repeating: preGain, count: freqs.count) }
        return freqs.map { f in
            let phase = Phase(radians: 2 * .pi * f / sampleRate)
            var db = preGain
            for filter in filters { db += filter.gainDb(at: phase) }
            return db
        }
    }

    static func logSweep(count: Int, from: Double = minFreq, to: Double = maxFreq) -> [Double] {
        let logMin = log10(from), logMax = log10(to)
        return (0..<count).map { i in
            let t = Double(i) / Double(max(count - 1, 1))
            return pow(10, logMin + t * (logMax - logMin))
        }
    }

    static func frequency(atFraction t: Double) -> Double {
        pow(10, log10(minFreq) + t * (log10(maxFreq) - log10(minFreq)))
    }

    static func fraction(of freq: Double) -> Double {
        (log10(max(freq, minFreq)) - log10(minFreq)) / (log10(maxFreq) - log10(minFreq))
    }

    struct Phase {
        let cosW: Double, sinW: Double, cos2W: Double, sin2W: Double

        init(radians w: Double) {
            cosW = cos(w)
            sinW = sin(w)
            cos2W = cos(2 * w)
            sin2W = sin(2 * w)
        }
    }

    struct BandFilter {
        let b0: Double, b1: Double, b2: Double
        let a0: Double, a1: Double, a2: Double

        init?(band: QxEqBandValue) {
            let f0 = max(1, min(Double(band.freq), EQCurve.sampleRate / 2 - 1))
            let q = max(0.05, band.q)
            let a = pow(10, band.gain / 40)
            let w0 = 2 * .pi * f0 / EQCurve.sampleRate
            let cosW0 = cos(w0), sinW0 = sin(w0)
            let alpha = sinW0 / (2 * q)

            switch band.filter {
            case .peak:
                b0 = 1 + alpha * a;  b1 = -2 * cosW0;  b2 = 1 - alpha * a
                a0 = 1 + alpha / a;  a1 = -2 * cosW0;  a2 = 1 - alpha / a
            case .lowShelf:
                let sq = 2 * sqrt(a) * alpha
                b0 = a * ((a + 1) - (a - 1) * cosW0 + sq)
                b1 = 2 * a * ((a - 1) - (a + 1) * cosW0)
                b2 = a * ((a + 1) - (a - 1) * cosW0 - sq)
                a0 = (a + 1) + (a - 1) * cosW0 + sq
                a1 = -2 * ((a - 1) + (a + 1) * cosW0)
                a2 = (a + 1) + (a - 1) * cosW0 - sq
            case .highShelf:
                let sq = 2 * sqrt(a) * alpha
                b0 = a * ((a + 1) + (a - 1) * cosW0 + sq)
                b1 = -2 * a * ((a - 1) + (a + 1) * cosW0)
                b2 = a * ((a + 1) + (a - 1) * cosW0 - sq)
                a0 = (a + 1) - (a - 1) * cosW0 + sq
                a1 = 2 * ((a - 1) - (a + 1) * cosW0)
                a2 = (a + 1) - (a - 1) * cosW0 - sq
            case .lpf:
                b0 = (1 - cosW0) / 2;  b1 = 1 - cosW0;  b2 = (1 - cosW0) / 2
                a0 = 1 + alpha;        a1 = -2 * cosW0; a2 = 1 - alpha
            case .hpf:
                b0 = (1 + cosW0) / 2;  b1 = -(1 + cosW0); b2 = (1 + cosW0) / 2
                a0 = 1 + alpha;        a1 = -2 * cosW0;   a2 = 1 - alpha
            case .bypass:
                return nil
            }
        }

        func gainDb(at phase: Phase) -> Double {
            let numRe = b0 + b1 * phase.cosW + b2 * phase.cos2W
            let numIm = -(b1 * phase.sinW + b2 * phase.sin2W)
            let denRe = a0 + a1 * phase.cosW + a2 * phase.cos2W
            let denIm = -(a1 * phase.sinW + a2 * phase.sin2W)

            let num = sqrt(numRe * numRe + numIm * numIm)
            let den = sqrt(denRe * denRe + denIm * denIm)
            guard den > 1e-12, num > 1e-12 else { return 0 }
            let db = 20 * log10(num / den)
            return db.isFinite ? db : 0
        }
    }
}

enum EQHeadroom {
    static let range: ClosedRange<Double> = -12...12

    static func clamp(_ db: Double) -> Double {
        guard db.isFinite else { return 0 }
        return min(max(db, range.lowerBound), range.upperBound)
    }

    private static let probeMin: Double = 10
    private static let probeMax: Double = 22000

    private static let probeCount = 512

    private static let clusterSteps = 8

    private static func probes(for bands: [QxEqBandValue]) -> [Double] {
        var freqs = EQCurve.logSweep(count: probeCount, from: probeMin, to: probeMax)
        for band in bands where band.filter != .bypass {
            for w in featureFrequencies(of: band) {
                let halfWidth = sin(w) / (2 * max(0.05, band.q))
                for k in -clusterSteps...clusterSteps {
                    let f = (w + Double(k) * halfWidth / Double(clusterSteps))
                        * EQCurve.sampleRate / (2 * .pi)
                    freqs.append(min(max(f, probeMin), probeMax))
                }
            }
        }
        return freqs
    }

    private static func featureFrequencies(of band: QxEqBandValue) -> [Double] {
        let f0 = min(max(Double(band.freq), probeMin), probeMax)
        let w0 = 2 * .pi * f0 / EQCurve.sampleRate
        switch band.filter {
        case .lowShelf, .highShelf:
            let spread = pow(10, band.gain / 80)
            let t0 = tan(w0 / 2)
            return [2 * atan(t0 / spread), w0, 2 * atan(t0 * spread)]
        default:
            return [w0]
        }
    }

    static func peakBoost(of bands: [QxEqBandValue]) -> Double {
        let peak = EQCurve.response(bands: bands, preGain: 0, at: probes(for: bands)).max() ?? 0
        return peak.isFinite ? max(0, peak) : 0
    }

    static func preGain(offsetting peakBoost: Double) -> Double {
        let steps = (peakBoost * 10).rounded()
        guard steps.isFinite, steps > 0 else { return 0 }
        return clamp(-steps / 10)
    }

    static func suggestedPreGain(for bands: [QxEqBandValue]) -> Double {
        preGain(offsetting: peakBoost(of: bands))
    }

    struct Advice: Equatable {
        var peakBoost: Double
        var suggestion: Double?
        var shortfall: Double
    }

    static func advice(for bands: [QxEqBandValue], preGain currentPreGain: Double) -> Advice {
        let peak = peakBoost(of: bands)
        let want = preGain(offsetting: peak)
        let offer = want < currentPreGain - 0.05 ? want : nil
        return Advice(peakBoost: peak, suggestion: offer,
                      shortfall: max(0, peak + range.lowerBound))
    }
}

enum EQDivergence {
    static let tolerance: Double = 0.25

    struct Reading: Equatable {
        var deltas: [Double]
        var peakIndex: Int
        var peak: Double
        var spans: [ClosedRange<Int>]
    }

    static func reading(requested: [Double], applied: [Double]) -> Reading? {
        guard requested.count == applied.count, requested.count > 1 else { return nil }
        var deltas = [Double](repeating: 0, count: applied.count)
        var peakIndex = 0
        var peak = 0.0
        for i in applied.indices {
            let d = requested[i] - applied[i]
            guard d.isFinite else { return nil }
            deltas[i] = d
            if abs(d) > abs(peak) { peak = d; peakIndex = i }
        }
        guard abs(peak) > tolerance else { return nil }
        return Reading(deltas: deltas, peakIndex: peakIndex, peak: peak,
                       spans: spans(of: deltas, above: tolerance))
    }

    static func spans(of deltas: [Double], above threshold: Double) -> [ClosedRange<Int>] {
        guard !deltas.isEmpty else { return [] }
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for (i, d) in deltas.enumerated() {
            if abs(d) > threshold {
                if start == nil { start = i }
            } else if let s = start {
                runs.append(s...(i - 1))
                start = nil
            }
        }
        if let s = start { runs.append(s...(deltas.count - 1)) }

        var merged: [ClosedRange<Int>] = []
        for run in runs {
            let wide = max(0, run.lowerBound - 1)...min(deltas.count - 1, run.upperBound + 1)
            if let last = merged.last, wide.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, wide.upperBound)
            } else {
                merged.append(wide)
            }
        }
        return merged
    }
}
