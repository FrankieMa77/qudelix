import Foundation

enum ToneTestMath {
    static let maxLevelDBFS: Double = -12
    static let minLevelDBFS: Double = -90

    static func clamp(_ dbfs: Double) -> Double {
        min(max(dbfs, minLevelDBFS), maxLevelDBFS)
    }

    static let reference: [Int: Double] = [
        31: 60, 63: 40, 125: 22, 250: 11, 500: 4,
        1000: 2, 2000: -1, 4000: -5, 8000: 2, 16000: 15,
    ]

    static let order = [1000, 2000, 500, 4000, 250, 8000, 125, 16000, 63, 31]

    static let minCatchTrials = 6

    static let minFalseAlarms = 2

    static let unreliableFalseAlarmRate = 1.0 / 3.0

    static let cautionFalseAlarmRate = 0.2

    static let maxDeviationSpread: Double = 30

    static let withinTestNoiseSpread: Double = 8

    static let minThresholds = 3

    static let fallbackRate: Double = 44100
    static let plausibleRates: ClosedRange<Double> = 8000...768000

    static func plausibleRate(_ rate: Double) -> Double {
        rate.isFinite && plausibleRates.contains(rate) ? rate : fallbackRate
    }

    enum Phase: Equatable { case idle, running, finished }

    typealias Point = (hz: Int, gain: Double, deviation: Double, measured: Bool)

    static func interruption(connected: Bool, compatible: Bool,
                             voiceCall: Bool, eqModeChanged: Bool,
                             playerRunning: Bool,
                             outputIsDevice: Bool) -> SessionInterruption? {
        if !connected { return .disconnected }
        if !compatible { return .unsupported }
        if voiceCall { return .voiceCall }
        if eqModeChanged { return .eqModeChanged }
        if !playerRunning { return .playerStopped }
        if !outputIsDevice { return .outputChanged }
        return nil
    }

    struct Staircase {
        private(set) var level: Double = -40
        private var heardCount: [Double: Int] = [:]
        private var descending = true
        private var missesAtCap = 0

        enum Outcome: Equatable {
            case ask(Double)
            case settled(Double?)
        }

        mutating func answer(_ didHear: Bool) -> Outcome {
            if didHear { heardCount[level, default: 0] += 1 }

            if descending {
                if didHear {
                    if level - 10 < ToneTestMath.minLevelDBFS { return .settled(level) }
                    level -= 10
                } else {
                    descending = false
                    level += 5
                }
            } else {
                if didHear {
                    missesAtCap = 0
                    if heardCount[level, default: 0] >= 2 { return .settled(level) }
                    level -= 5
                    if level < ToneTestMath.minLevelDBFS { return .settled(nil) }
                    descending = true
                } else {
                    if level == ToneTestMath.maxLevelDBFS {
                        missesAtCap += 1
                        if missesAtCap >= 2 { return .settled(nil) }
                    }
                    level = min(level + 5, ToneTestMath.maxLevelDBFS)
                }
            }
            return .ask(level)
        }

        var bestRepeated: Double? {
            heardCount.filter { $0.value >= 2 }.keys.min()
        }
    }

    static func pulseSamples(hz: Double, dbfs: Double, sampleRate: Double, ms: Int = 220,
                             pulses: Int = 3, gapMs: Int = 120) -> [Float] {
        let amp = pow(10.0, clamp(dbfs) / 20.0)
        let onFrames = Int(Double(ms) / 1000 * sampleRate)
        let gapFrames = Int(Double(gapMs) / 1000 * sampleRate)
        let total = pulses * onFrames + (pulses - 1) * gapFrames
        guard total > 0 else { return [] }
        var samples = [Float](repeating: 0, count: total)

        let ramp = max(1, min(Int(0.025 * sampleRate), onFrames / 4))
        let twoPi = 2.0 * Double.pi
        let inc = twoPi * hz / sampleRate
        var phase = 0.0
        var cursor = 0
        for p in 0..<pulses {
            for i in 0..<onFrames {
                var env = 1.0
                if i < ramp {
                    env = 0.5 * (1 - cos(Double.pi * Double(i) / Double(ramp)))
                } else if i >= onFrames - ramp {
                    let k = onFrames - i - 1
                    env = 0.5 * (1 - cos(Double.pi * Double(k) / Double(ramp)))
                }
                let s = Float(amp * env * sin(phase))
                phase += inc
                if phase > twoPi { phase -= twoPi }
                samples[cursor + i] = s
            }
            cursor += onFrames + (p < pulses - 1 ? gapFrames : 0)
        }
        return samples
    }

    static func suggest(_ results: [(Int, Double?)], fraction: Double = 0.4,
                        cap: Double = 6) -> [Point] {
        var devs: [(Int, Double)] = []
        for (hz, t) in results {
            guard let t, let ref = reference[hz] else { continue }
            devs.append((hz, t - ref))
        }
        guard devs.count >= minThresholds else { return [] }
        let mean = devs.map(\.1).reduce(0, +) / Double(devs.count)

        return results.map { (hz, t) in
            guard let t, let ref = reference[hz] else { return (hz, 0, 0, false) }
            let dev = (t - ref) - mean
            return (hz, min(max(dev * fraction, -cap), cap), dev, true)
        }
    }

    static func readingCount(in results: [(Int, Double?)]) -> Int {
        results.filter { $0.1 != nil && reference[$0.0] != nil }.count
    }

    static func spread(of points: [Point]) -> Double {
        let ds = points.filter(\.measured).map(\.deviation)
        guard let lo = ds.min(), let hi = ds.max() else { return 0 }
        return hi - lo
    }

    enum Verdict: Equatable {
        case tooFewReadings
        case unreliable
        case tooScattered(spread: Double)
        case withinTestNoise
        case usable
    }

    static func verdict(readings: Int, catchTrials: Int,
                        falseAlarms: Int, spread: Double) -> Verdict {
        if readings < minThresholds { return .tooFewReadings }
        if catchTrials >= minCatchTrials, falseAlarms >= minFalseAlarms,
           rate(falseAlarms, of: catchTrials) >= unreliableFalseAlarmRate {
            return .unreliable
        }
        if spread > maxDeviationSpread { return .tooScattered(spread: spread) }
        if spread < withinTestNoiseSpread { return .withinTestNoise }
        return .usable
    }

    static func falseAlarmsElevated(catchTrials: Int, falseAlarms: Int) -> Bool {
        let r = rate(falseAlarms, of: catchTrials)
        return catchTrials >= minCatchTrials && falseAlarms >= minFalseAlarms
            && r > cautionFalseAlarmRate && r < unreliableFalseAlarmRate
    }

    private static func rate(_ alarms: Int, of trials: Int) -> Double {
        trials == 0 ? 0 : Double(alarms) / Double(trials)
    }

    static func gain(at hz: Double, from points: [(hz: Double, gain: Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if hz <= first.hz { return first.gain }
        if hz >= last.hz { return last.gain }
        for i in 1..<points.count where hz <= points[i].hz {
            let lo = points[i - 1], hi = points[i]
            guard hi.hz > lo.hz else { return hi.gain }
            let t = (log10(hz) - log10(lo.hz)) / (log10(hi.hz) - log10(lo.hz))
            return lo.gain + t * (hi.gain - lo.gain)
        }
        return last.gain
    }
}
