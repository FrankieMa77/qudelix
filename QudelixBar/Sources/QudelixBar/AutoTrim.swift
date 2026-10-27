import Foundation

enum TiltShelf {
    static let slopePerShelfDb = 0.2747
    static let q = 0.71
    static let lowHz = 250
    static let highHz = 4000

    static func gain(forSlope slope: Double) -> Double {
        -slope / slopePerShelfDb
    }
}

struct TrimGains: Equatable {
    var bassDb: Double = 0
    var tiltDbPerOctave: Double = 0
    var presenceDb: Double = 0
    var airDb: Double = 0

    static let zero = TrimGains()

    static let bassLimitDb = 3.0
    static let tiltLimitDbPerOctave = 1.0
    static let presenceLimitDb = 3.0
    static let airLimitDb = 2.0

    static let bassHz = 105
    static let bassQ = 0.71
    static let presenceHz = 2800
    static let presenceQ = 1.0
    static let airHz = 10000
    static let airQ = 0.71

    var isZero: Bool {
        bassDb == 0 && tiltDbPerOctave == 0 && presenceDb == 0 && airDb == 0
    }

    func clamped() -> TrimGains {
        func c(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
            v.isFinite ? min(max(v, lo), hi) : 0
        }
        return TrimGains(bassDb: c(bassDb, -Self.bassLimitDb, Self.bassLimitDb),
                         tiltDbPerOctave: c(tiltDbPerOctave, -Self.tiltLimitDbPerOctave,
                                            Self.tiltLimitDbPerOctave),
                         presenceDb: c(presenceDb, -Self.presenceLimitDb, Self.presenceLimitDb),
                         airDb: c(airDb, 0, Self.airLimitDb))
    }

    func rounded(to step: Double = 0.1) -> TrimGains {
        func r(_ v: Double) -> Double { (v / step).rounded() * step + 0 }
        return TrimGains(bassDb: r(bassDb), tiltDbPerOctave: r(tiltDbPerOctave),
                         presenceDb: r(presenceDb), airDb: r(airDb))
    }

    var bands: [QxEqBandValue] {
        let tiltShelf = TiltShelf.gain(forSlope: tiltDbPerOctave)
        return [
            QxEqBandValue(filter: .lowShelf, freq: Self.bassHz, gain: bassDb, q: Self.bassQ),
            QxEqBandValue(filter: .lowShelf, freq: TiltShelf.lowHz, gain: tiltShelf,
                          q: TiltShelf.q),
            QxEqBandValue(filter: .highShelf, freq: TiltShelf.highHz, gain: -tiltShelf,
                          q: TiltShelf.q),
            QxEqBandValue(filter: .peak, freq: Self.presenceHz, gain: presenceDb,
                          q: Self.presenceQ),
            QxEqBandValue(filter: .highShelf, freq: Self.airHz, gain: airDb, q: Self.airQ)
        ]
    }

    func levelDb() -> Double {
        let level = LevelMatch.meanLevelDb(bands: bands)
        return level.isFinite ? level : 0
    }
}

enum TrimMode: String, Codable, CaseIterable, Identifiable {
    case audiophile, clarity, resolution, presentation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .audiophile: return "Audiophile"
        case .clarity: return "Clarity"
        case .resolution: return "Resolution"
        case .presentation: return "Presentation"
        }
    }

    var weights: (bass: Double, tilt: Double, presence: Double, air: Double) {
        switch self {
        case .audiophile: return (0, 0, 0, 0)
        case .clarity: return (0.5, 1, 1, 0)
        case .resolution: return (0.5, 0.5, 0.5, 1)
        case .presentation: return (1, 0.5, 1, 0.5)
        }
    }
}

enum AirClass: Equatable {
    case unknown, limited, extended

    init(verdict: QualityAnalyzer.Verdict?) {
        switch verdict {
        case .losslessLike?, .hiRes?: self = .extended
        case .lossy?, .lossyHigh?: self = .limited
        default: self = .unknown
        }
    }
}

enum ReferenceSource: String, Codable, CaseIterable, Identifiable {
    case auto, catalog, listening

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .catalog: return "Fit"
        case .listening: return "Listening"
        }
    }
}

struct BalanceBaseline: Equatable {
    var bassDb: Double = 0
    var tiltDbPerOctave: Double = -2.0
    var presenceDb: Double = 0
    var readings: Int = 0

    static let learnedAfter = 600
    static let coefficient = 1 - exp(-3.0 / 7200)

    var isLearned: Bool { readings >= Self.learnedAfter }

    func sanitized() -> BalanceBaseline {
        var b = self
        if !b.bassDb.isFinite { b.bassDb = 0 }
        if !b.tiltDbPerOctave.isFinite { b.tiltDbPerOctave = -2 }
        if !b.presenceDb.isFinite { b.presenceDb = 0 }
        b.bassDb = min(max(b.bassDb, -12), 12)
        b.tiltDbPerOctave = min(max(b.tiltDbPerOctave, -6), 6)
        b.presenceDb = min(max(b.presenceDb, -12), 12)
        b.readings = min(max(b.readings, 0), 1_000_000)
        return b
    }
}

extension BalanceBaseline: Codable {
    private enum CodingKeys: String, CodingKey {
        case bassDb, tiltDbPerOctave, presenceDb, readings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let v = try? c.decode(Double.self, forKey: .bassDb) { bassDb = v }
        if let v = try? c.decode(Double.self, forKey: .tiltDbPerOctave) { tiltDbPerOctave = v }
        if let v = try? c.decode(Double.self, forKey: .presenceDb) { presenceDb = v }
        if let v = try? c.decode(Int.self, forKey: .readings) { readings = v }
        self = sanitized()
    }
}

struct TrimController {
    typealias Weights = (bass: Double, tilt: Double, presence: Double, air: Double)

    var mode: TrimMode = .clarity
    var strength: Double = 0.5
    var enabled = true
    var baseline = BalanceBaseline()
    var gains = TrimGains.zero
    private(set) var advisory = TrimGains.zero
    private(set) var anchor: BalanceFeatures?
    private var sinceReading = 0.0
    private var silentSeconds = 0.0

    static let anchorTimeConstant = 90.0
    static let correctionFraction = 0.5
    static let deadbandDb = 0.5
    static let deadbandTilt = 0.25
    static let slewDbPerSecond = 0.1
    static let slewTiltPerSecond = 0.05
    static let airTargetDb = 2.0
    static let maxStepSeconds = 10.0
    static let staleReadingSeconds = 60.0
    static let axisGain = (bass: 3.1, tilt: 1.0, presence: 2.4)
    static let advisoryWeights: Weights = (1, 1, 1, 1)

    mutating func step(reading: BalanceFeatures?, air: AirClass,
                       frozen: Bool, dt: Double) -> TrimGains {
        let dt = dt.isFinite ? min(max(dt, 0), Self.maxStepSeconds) : 0
        sinceReading = min(sinceReading + dt, Self.maxStepSeconds)
        silentSeconds = min(silentSeconds + dt, Self.staleReadingSeconds * 2)
        if let r = reading, r.bassDb.isFinite, r.tiltDbPerOctave.isFinite, r.presenceDb.isFinite {
            if let a = anchor, silentSeconds <= Self.staleReadingSeconds {
                let k = 1 - exp(-sinceReading / Self.anchorTimeConstant)
                anchor = BalanceFeatures(
                    bassDb: a.bassDb + k * (r.bassDb - a.bassDb),
                    tiltDbPerOctave: a.tiltDbPerOctave + k * (r.tiltDbPerOctave - a.tiltDbPerOctave),
                    presenceDb: a.presenceDb + k * (r.presenceDb - a.presenceDb))
            } else {
                anchor = r
            }
            sinceReading = 0
            silentSeconds = 0
            if !frozen {
                let k = BalanceBaseline.coefficient
                baseline.bassDb += k * (r.bassDb - baseline.bassDb)
                baseline.tiltDbPerOctave += k * (r.tiltDbPerOctave - baseline.tiltDbPerOctave)
                baseline.presenceDb += k * (r.presenceDb - baseline.presenceDb)
                baseline.readings += 1
                baseline = baseline.sanitized()
            }
        }

        let s = strength.isFinite ? min(max(strength, 0), 1) : 0
        let target: TrimGains
        let advisoryTarget: TrimGains
        if let a = anchor {
            target = !enabled ? .zero
                : frozen ? gains
                : Self.target(anchor: a, baseline: baseline, weights: mode.weights,
                              strength: s, air: air)
            advisoryTarget = frozen ? advisory
                : Self.target(anchor: a, baseline: baseline, weights: Self.advisoryWeights,
                              strength: 1, air: air)
        } else {
            target = .zero
            advisoryTarget = .zero
        }
        gains = Self.slew(gains, toward: target, dt: dt)
        advisory = Self.slew(advisory, toward: advisoryTarget, dt: dt)
        return gains
    }

    mutating func reset() {
        anchor = nil
        sinceReading = 0
        silentSeconds = 0
    }

    static func target(anchor a: BalanceFeatures, baseline b: BalanceBaseline,
                       weights w: Weights, strength s: Double, air: AirClass) -> TrimGains {
        func axis(_ error: Double, _ deadband: Double, _ weight: Double, _ gain: Double) -> Double {
            guard error.isFinite, abs(error) > deadband else { return 0 }
            return weight * s * correctionFraction * gain * error
        }
        return TrimGains(
            bassDb: axis(b.bassDb - a.bassDb, deadbandDb, w.bass, axisGain.bass),
            tiltDbPerOctave: axis(b.tiltDbPerOctave - a.tiltDbPerOctave, deadbandTilt, w.tilt,
                                  axisGain.tilt),
            presenceDb: axis(b.presenceDb - a.presenceDb, deadbandDb, w.presence,
                             axisGain.presence),
            airDb: air == .extended ? w.air * s * airTargetDb : 0).clamped()
    }

    static func slew(_ g: TrimGains, toward t: TrimGains, dt: Double) -> TrimGains {
        func move(_ v: Double, _ to: Double, _ rate: Double) -> Double {
            let v = v.isFinite ? v : 0
            let to = to.isFinite ? to : 0
            let limit = rate * dt
            let d = to - v
            return abs(d) <= limit ? to : v + (d > 0 ? limit : -limit)
        }
        return TrimGains(bassDb: move(g.bassDb, t.bassDb, slewDbPerSecond),
                         tiltDbPerOctave: move(g.tiltDbPerOctave, t.tiltDbPerOctave,
                                               slewTiltPerSecond),
                         presenceDb: move(g.presenceDb, t.presenceDb, slewDbPerSecond),
                         airDb: move(g.airDb, t.airDb, slewDbPerSecond)).clamped()
    }
}
