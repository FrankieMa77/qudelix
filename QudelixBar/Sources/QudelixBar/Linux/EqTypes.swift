import Foundation

package enum EqFilterKind: Int, CaseIterable {
    case bypass = 0
    case lpf
    case hpf
    case lowShelf
    case highShelf
    case peak

    init(_ raw: QxFilter) {
        self = EqFilterKind(rawValue: Int(raw.rawValue)) ?? .bypass
    }

    var raw: QxFilter { QxFilter(rawValue: UInt8(rawValue)) ?? .bypass }

    package var label: String { raw.label }
    package var shortLabel: String { raw.shortLabel }
    package var hasGain: Bool { raw.hasGain }
}

package struct EqBand: Equatable {
    package var filter: EqFilterKind
    package var freq: Int
    package var gain: Double
    package var q: Double

    package init(filter: EqFilterKind = .peak, freq: Int = 1000, gain: Double = 0, q: Double = 1) {
        self.filter = filter
        self.freq = freq
        self.gain = gain
        self.q = q
    }

    init(_ raw: QxEqBandValue) {
        self.init(filter: EqFilterKind(raw.filter), freq: raw.freq, gain: raw.gain, q: raw.q)
    }

    var raw: QxEqBandValue {
        QxEqBandValue(filter: filter.raw, freq: freq, gain: gain, q: q)
    }

    package var editsGain: Bool { filter == .bypass || filter.hasGain }
}

package enum EqCurveGeometry {
    package static let minFrequency = 20.0
    package static let maxFrequency = 20000.0
    package static let minNeighbourRatio = 1.05
    package static let fineDragScale = 0.25

    package static func fraction(of frequency: Double) -> Double {
        EQCurve.fraction(of: frequency)
    }

    package static func frequency(atFraction fraction: Double) -> Double {
        EQCurve.frequency(atFraction: fraction)
    }

    package static func response(bands: [EqBand], count: Int = 220) -> [Double] {
        EQCurve.response(bands: bands.map(\.raw), preGain: 0, count: count)
    }

    package static func plotRange(for values: [Double]) -> Double {
        let peak = values.map(abs).max() ?? 0
        return min(18, max(9, (peak / 3).rounded(.up) * 3 + 3))
    }

    package static func gridLevels(range: Double) -> [Double] {
        let step = range > 9 ? 6.0 : 3.0
        var levels = Array(stride(from: -range + step, through: range - step, by: step))
        if !levels.contains(0) {
            levels.append(0)
            levels.sort()
        }
        return levels
    }

    package static func markerGain(_ band: EqBand) -> Double {
        band.filter.hasGain ? band.gain : 0
    }

    package static func clampedFrequency(_ wanted: Double, forBand index: Int,
                                         in bands: [EqBand]) -> Int {
        guard bands.indices.contains(index) else { return 1000 }
        let current = Double(bands[index].freq)
        let others = bands.enumerated()
            .filter { $0.offset != index && $0.element.filter != .bypass }
        var lower = minFrequency, upper = maxFrequency
        let below = others.filter {
            Double($0.element.freq) < current
                || (Double($0.element.freq) == current && $0.offset < index)
        }.map { Double($0.element.freq) }.max()
        let above = others.filter {
            Double($0.element.freq) > current
                || (Double($0.element.freq) == current && $0.offset > index)
        }.map { Double($0.element.freq) }.min()
        if let below { lower = max(lower, below * minNeighbourRatio) }
        if let above { upper = min(upper, above / minNeighbourRatio) }
        guard lower <= upper else { return bands[index].freq }
        guard wanted.isFinite else { return bands[index].freq }
        return Int(min(max(wanted.rounded(), lower), upper))
    }

    package static func yPosition(gain: Double, range: Double, height: Double) -> Double {
        height / 2 - max(-range, min(range, gain)) / range * max(height / 2 - 6, 1)
    }

    package static func nearestBand(x: Double, y: Double, in bands: [EqBand],
                                    width: Double, height: Double, range: Double,
                                    grabRadius: Double = 22) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, band) in bands.enumerated() where band.filter != .bypass {
            let bx = fraction(of: Double(band.freq)) * width
            let by = yPosition(gain: markerGain(band), range: range, height: height)
            let distance = hypot(x - bx, y - by)
            if distance <= grabRadius, best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    package static func dragged(_ origin: EqBand, index: Int, in bands: [EqBand],
                                dx: Double, dy: Double, width: Double, height: Double,
                                range: Double, fine: Bool = false) -> EqBand {
        var band = origin
        let scale = fine ? fineDragScale : 1
        let moveX = dx * scale
        let moveY = dy * scale
        if band.filter.hasGain {
            let usable = max(height / 2 - 6, 1)
            let db = origin.gain - moveY / usable * range
            band.gain = (min(max(db, -12), 12) * 10).rounded() / 10
        }
        let startFraction = fraction(of: Double(origin.freq))
        let moved = min(max(startFraction + moveX / max(width, 1), 0), 1)
        band.freq = clampedFrequency(frequency(atFraction: moved), forBand: index, in: bands)
        return band
    }

    package static func scrolledQ(_ band: EqBand, steps: Double) -> EqBand {
        var result = band
        let q = pow(10, log10(max(band.q, 0.1)) - steps * 0.05)
        result.q = (min(max(q, 0.1), 10) * 100).rounded() / 100
        return result
    }
}

package enum EqFormat {
    package static func decibels(_ value: Double) -> String { DisplayFormat.decibels(value) }

    package static func signed(_ value: Double) -> String { DisplayFormat.signed(value) }

    package static func frequency(_ hertz: Int) -> String { "\(hertz) Hz" }

    package static func q(_ value: Double) -> String { NumberEntry.formatQ(value) }
}

package extension EqBand {
    var summary: String {
        switch filter {
        case .bypass:
            return "Off"
        case .peak, .lowShelf, .highShelf:
            return [EqFormat.frequency(freq), EqFormat.decibels(gain), "Q " + EqFormat.q(q)]
                .joined(separator: " \u{00B7} ")
        case .lpf, .hpf:
            return [EqFormat.frequency(freq), "Q " + EqFormat.q(q)].joined(separator: " \u{00B7} ")
        }
    }
}
