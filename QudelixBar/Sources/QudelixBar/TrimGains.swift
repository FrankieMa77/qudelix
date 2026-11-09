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
