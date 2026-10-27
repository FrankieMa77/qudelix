import Foundation
@testable import QudelixBar

enum FollowFixtures {
    typealias Band = QxEqBandValue

    static func px8Jazz() -> [Band] {
        let rows: [(QxFilter, Int, Double, Double)] = [
            (.peak, 31, 0, 1.8), (.lowShelf, 35, 1, 0.71), (.peak, 44, 0, 1.8),
            (.peak, 53, 4.7, 1.09), (.peak, 63, 0, 1.8), (.peak, 88, 0, 1.8),
            (.lowShelf, 105, -2, 0.7), (.peak, 259, -3.6, 0.3), (.peak, 425, 4, 0.9),
            (.peak, 1013, -0.5, 3.11), (.peak, 1994, 3, 0.7), (.peak, 3000, 1, 1.2),
            (.peak, 4355, -2, 2.5), (.peak, 5200, 1, 1.8), (.peak, 6260, 2, 2.5),
            (.peak, 8000, 1, 1.5), (.peak, 9862, 1, 2), (.highShelf, 10000, 0.5, 0.7),
            (.peak, 11300, 1.2, 2), (.highShelf, 15000, 2, 0.71)
        ]
        return rows.map { Band(filter: $0.0, freq: $0.1, gain: $0.2, q: $0.3) }
    }

    static func px8Flat() -> [Band] {
        px8Jazz().map { var b = $0; b.gain = 0; return b }
    }

    static func px8NoShelves() -> [Band] {
        px8Jazz().map { var b = $0; if b.filter != .peak { b.filter = .bypass }; return b }
    }

    static func tenBandReference() -> [Band] {
        [Band(filter: .lowShelf, freq: 105, gain: 3.0, q: 0.70),
         Band(filter: .peak, freq: 62, gain: -0.6, q: 1.8),
         Band(filter: .peak, freq: 200, gain: -2.0, q: 0.9),
         Band(filter: .peak, freq: 480, gain: 0.6, q: 1.2),
         Band(filter: .peak, freq: 1250, gain: 0.8, q: 1.6),
         Band(filter: .peak, freq: 3000, gain: 2.5, q: 1.4),
         Band(filter: .peak, freq: 5200, gain: -1.2, q: 3.0),
         Band(filter: .peak, freq: 8000, gain: -3.0, q: 2.2),
         Band(filter: .highShelf, freq: 10000, gain: 1.5, q: 0.70),
         Band(filter: .peak, freq: 14500, gain: -1.0, q: 2.0)]
    }

    static func tenBandBase() -> [Band] {
        [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000].map {
            Band(filter: .peak, freq: $0, gain: 0, q: 1.4)
        }
    }

    static func twentyBandReference() -> [Band] {
        let freqs = [25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 8000,
                     10000, 12500, 14000, 16000, 18000, 20000]
        let gains: [Double] = [0, 0.5, 1.0, 1.5, 1.0, 0, -1.0, -1.5, -1.0, 0, 1.5, 2.0, 1.0,
                               -1.0, 0.5, 0, 0, 0, 0, 0]
        return zip(freqs, gains).map { Band(filter: .peak, freq: $0, gain: $1, q: 4.3) }
    }

    static func maxAbsGain(_ bands: [Band]) -> Double {
        bands.map { abs($0.gain) }.max() ?? 0
    }
}
