import AppKit
import Foundation
import SwiftUI

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

struct EQCurveView: View {
    let bands: [QxEqBandValue]
    let preGain: Double
    var highlighted: Int?

    var requested: ParametricEQFile?

    var mutedBands: [Int: QxFilter] = [:]

    var enabled: Bool = true

    var selectedBand: Int?

    var onSelectBand: ((Int?) -> Void)?

    var onZeroBand: ((Int) -> Void)?

    var onBandChanged: ((Int, QxEqBandValue) -> Void)?
    var onDragBand: ((Int?) -> Void)?

    @State private var dragging: Int?

    @State private var viewSize: CGSize = .zero

    @State private var hovering: Int?

    @State private var dragOrigin: QxEqBandValue?

    @State private var dragAnchor: CGPoint?
    @State private var dragModifiers: NSEvent.ModifierFlags = []

    @State private var dragRange: Double?

    private static let fineDragScale: CGFloat = 0.25

    private static let grabRadius: CGFloat = 22

    static let minNeighbourRatio = 1.05

    private struct Plot {
        var applied: [Double]
        var requested: [Double]?
        var divergence: EQDivergence.Reading?
        var range: Double
    }

    private func plot() -> Plot {
        let applied = EQCurve.response(bands: bands, preGain: 0)
        let asked = requested.map { EQCurve.response(bands: $0.bands, preGain: 0) }
        let comparable = mutedBands.isEmpty
            ? applied
            : EQCurve.response(bands: unmuted(bands), preGain: 0)
        let gap = asked.flatMap { EQDivergence.reading(requested: $0, applied: comparable) }

        var peak = applied.map(abs).max() ?? 0
        if gap != nil, let asked { peak = max(peak, asked.map(abs).max() ?? 0) }

        return Plot(applied: applied,
                    requested: gap == nil ? nil : asked,
                    divergence: gap,
                    range: min(18, max(9, (peak / 3).rounded(.up) * 3 + 3)))
    }

    private func unmuted(_ input: [QxEqBandValue]) -> [QxEqBandValue] {
        var out = input
        for (index, shape) in mutedBands where out.indices.contains(index) {
            if out[index].filter == .bypass { out[index].filter = shape }
        }
        return out
    }

    var body: some View {
        let plot = self.plot()
        Canvas { ctx, size in
            let range = plot.range
            let values = plot.applied
            let midY = size.height / 2
            func y(_ db: Double) -> CGFloat {
                midY - CGFloat(max(-range, min(range, db)) / range) * (size.height / 2 - 6)
            }

            let step = range > 12 ? 6.0 : (range > 9 ? 6.0 : 3.0)
            for db in stride(from: -range + step, through: range - step, by: step) {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(db)))
                line.addLine(to: CGPoint(x: size.width, y: y(db)))
                ctx.stroke(line, with: .color(.secondary.opacity(db == 0 ? 0.45 : 0.14)),
                           lineWidth: db == 0 ? 1 : 0.5)
            }
            for f in [100.0, 1000, 10000] {
                let gridX = CGFloat(EQCurve.fraction(of: f)) * size.width
                var line = Path()
                line.move(to: CGPoint(x: gridX, y: 0))
                line.addLine(to: CGPoint(x: gridX, y: size.height))
                ctx.stroke(line, with: .color(.secondary.opacity(0.14)), lineWidth: 0.5)
                ctx.draw(Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary),
                         at: CGPoint(x: gridX + 11, y: size.height - 7))
            }

            guard values.count > 1 else { return }
            func x(_ i: Int) -> CGFloat {
                CGFloat(i) / CGFloat(values.count - 1) * size.width
            }

            var curve = Path()
            for (i, db) in values.enumerated() {
                let p = CGPoint(x: x(i), y: y(db))
                i == 0 ? curve.move(to: p) : curve.addLine(to: p)
            }

            var fill = curve
            fill.addLine(to: CGPoint(x: size.width, y: y(0)))
            fill.addLine(to: CGPoint(x: 0, y: y(0)))
            fill.closeSubpath()
            let tint: Color = enabled ? .accentColor : .secondary
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [tint.opacity(enabled ? 0.34 : 0.16),
                                  tint.opacity(0.05)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            if let asked = plot.requested, let gap = plot.divergence,
               asked.count == values.count {
                for span in gap.spans {
                    var patch = Path()
                    patch.move(to: CGPoint(x: x(span.lowerBound), y: y(asked[span.lowerBound])))
                    for i in span.dropFirst() {
                        patch.addLine(to: CGPoint(x: x(i), y: y(asked[i])))
                    }
                    for i in span.reversed() {
                        patch.addLine(to: CGPoint(x: x(i), y: y(values[i])))
                    }
                    patch.closeSubpath()
                    ctx.fill(patch, with: .color(.secondary.opacity(0.18)))
                }

                var ghost = Path()
                for (i, db) in asked.enumerated() {
                    let p = CGPoint(x: x(i), y: y(db))
                    i == 0 ? ghost.move(to: p) : ghost.addLine(to: p)
                }
                ctx.stroke(ghost, with: .color(.secondary.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))

                if abs(gap.peak) >= 1 {
                    let px = x(gap.peakIndex)
                    let applied = y(values[gap.peakIndex]), wanted = y(asked[gap.peakIndex])
                    var tick = Path()
                    tick.move(to: CGPoint(x: px, y: applied))
                    tick.addLine(to: CGPoint(x: px, y: wanted))
                    ctx.stroke(tick, with: .color(.secondary.opacity(0.5)), lineWidth: 0.8)
                    let leftOfTick = px > size.width * 0.62
                    ctx.draw(Text(String(format: "%.1f dB", abs(gap.peak)))
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary),
                             at: CGPoint(x: px + (leftOfTick ? -4 : 4),
                                         y: (applied + wanted) / 2),
                             anchor: leftOfTick ? .trailing : .leading)
                }
            }

            ctx.stroke(curve, with: .color(tint), lineWidth: 1.8)

            if let h = hovering, dragging == nil, bands.indices.contains(h),
               bands[h].filter != .bypass {
                let hx = CGFloat(EQCurve.fraction(of: Double(bands[h].freq))) * size.width
                let ring = Path(ellipseIn: CGRect(x: hx - 7,
                                                  y: y(EQCurveView.markerGain(bands[h])) - 7,
                                                  width: 14, height: 14))
                ctx.stroke(ring, with: .color(tint.opacity(0.45)), lineWidth: 1)
            }

            for (i, band) in bands.enumerated() where band.filter != .bypass {
                let dotX = CGFloat(EQCurve.fraction(of: Double(band.freq))) * size.width
                let dotY = y(EQCurveView.markerGain(band))
                let isOn = highlighted == i
                let picked = selectedBand == i
                let r: CGFloat = isOn || picked ? 4 : 2.5
                let dot = Path(ellipseIn: CGRect(x: dotX - r, y: dotY - r,
                                                 width: r * 2, height: r * 2))
                ctx.fill(dot, with: .color(isOn || picked ? tint : tint.opacity(0.55)))
                if isOn {
                    ctx.stroke(dot, with: .color(.white.opacity(0.9)), lineWidth: 1.2)
                }
                if picked {
                    let halo = Path(ellipseIn: CGRect(x: dotX - 7, y: dotY - 7,
                                                      width: 14, height: 14))
                    ctx.stroke(halo, with: .color(tint.opacity(0.8)), lineWidth: 1.2)
                }
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { viewSize = geo.size }
                    .onChange(of: geo.size) { _, new in viewSize = new }
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard onBandChanged != nil else { return }
            let resolved: Int?
            switch phase {
            case .active(let point): resolved = nearestBand(to: point, range: plot.range)
            case .ended: resolved = nil
            }
            if resolved != hovering { hovering = resolved }
        }
        .gesture(onBandChanged == nil ? nil : dragGesture(range: plot.range))
        .gesture(onSelectBand == nil ? nil : selectGesture(range: plot.range))
        .gesture(onZeroBand == nil ? nil : zeroGesture(range: plot.range))
        .help(onBandChanged == nil ? "" : "Click a point to select it, double-click to "
              + "zero it, drag to shape the curve: up and down for gain, sideways for "
              + "frequency. Hold Option and drag up or down for Q. Hold Shift for fine "
              + "adjustment.")
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            Text(axisText(range: plot.range))
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(4)
        }
        .overlay(alignment: .topTrailing) {
            if let i = readoutBand {
                Text(readoutText(i))
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 3))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    private func axisText(range: Double) -> String {
        let axis = "±\(Int(range)) dB"
        guard abs(preGain) >= 0.05 else { return axis }
        return axis + String(format: "   pre-gain %+.1f dB", preGain)
    }

    private var readoutBand: Int? {
        for candidate in [dragging, hovering, selectedBand] {
            if let candidate, bands.indices.contains(candidate),
               bands[candidate].filter != .bypass { return candidate }
        }
        return nil
    }

    private func readoutText(_ i: Int) -> String {
        let band = bands[i]
        let amount = band.filter.hasGain
            ? String(format: "%+.1f dB", band.gain)
            : band.filter.shortLabel
        return "\(i + 1)   " + amount + String(format: "   Q %.2f", band.q)
    }

    private func selectGesture(range: Double) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .local).onEnded { tap in
            onSelectBand?(nearestBand(to: tap.location, range: range))
        }
    }

    private func zeroGesture(range: Double) -> some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .local).onEnded { tap in
            guard let hit = nearestBand(to: tap.location, range: range) else { return }
            onSelectBand?(hit)
            onZeroBand?(hit)
        }
    }

    private func dragGesture(range: Double) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                if dragging == nil {
                    guard let hit = nearestBand(to: value.startLocation, range: range)
                    else { return }
                    dragging = hit
                    dragOrigin = bands[hit]
                    dragAnchor = value.startLocation
                    dragModifiers = NSEvent.modifierFlags
                        .intersection([.shift, .option])
                    dragRange = range
                    onDragBand?(hit)
                }
                guard let i = dragging, bands.indices.contains(i) else { return }
                var band = bands[i]

                let mods = NSEvent.modifierFlags.intersection([.shift, .option])
                if mods != dragModifiers {
                    dragModifiers = mods
                    dragAnchor = value.location
                    dragOrigin = bands[i]
                }
                let origin = dragOrigin ?? bands[i]
                let anchor = dragAnchor ?? value.startLocation
                let range = dragRange ?? range
                let scale = mods.contains(.shift) ? Self.fineDragScale : 1
                let dx = (value.location.x - anchor.x) * scale
                let dy = (value.location.y - anchor.y) * scale

                if mods.contains(.option) {
                    let decades = log10(10.0) - log10(0.1)
                    let perPoint = decades / Double(max(viewSize.height - 12, 1))
                    let q = pow(10, log10(origin.q) - Double(dy) * perPoint)
                    band.q = (min(max(q, 0.1), 10) * 100).rounded() / 100
                    guard band != bands[i] else { return }
                    return onBandChanged?(i, band) ?? ()
                }

                if band.filter.hasGain {
                    let usable = max(viewSize.height / 2 - 6, 1)
                    let db = origin.gain - Double(dy / usable) * range
                    band.gain = (min(max(db, -12), 12) * 10).rounded() / 10
                }

                let startFx = EQCurve.fraction(of: Double(origin.freq))
                let fx = min(max(startFx + Double(dx / max(viewSize.width, 1)), 0), 1)
                band.freq = Self.clampedFrequency(EQCurve.frequency(atFraction: fx),
                                                  forBand: i, in: bands)

                guard band != bands[i] else { return }
                onBandChanged?(i, band)
            }
            .onEnded { _ in
                dragging = nil
                dragOrigin = nil
                dragAnchor = nil
                dragRange = nil
                dragModifiers = []
                onDragBand?(nil)
            }
    }

    nonisolated static func markerGain(_ band: QxEqBandValue) -> Double {
        band.filter.hasGain ? band.gain : 0
    }

    nonisolated static func clampedFrequency(_ wanted: Double, forBand i: Int,
                                             in bands: [QxEqBandValue]) -> Int {
        guard bands.indices.contains(i) else { return 1000 }
        let current = Double(bands[i].freq)
        let others = bands.enumerated()
            .filter { $0.offset != i && $0.element.filter != .bypass }
        var lower = 20.0, upper = 20000.0
        let below = others.filter {
            Double($0.element.freq) < current
                || (Double($0.element.freq) == current && $0.offset < i)
        }.map { Double($0.element.freq) }.max()
        let above = others.filter {
            Double($0.element.freq) > current
                || (Double($0.element.freq) == current && $0.offset > i)
        }.map { Double($0.element.freq) }.min()
        if let below { lower = max(lower, below * minNeighbourRatio) }
        if let above { upper = min(upper, above / minNeighbourRatio) }
        guard lower <= upper else { return bands[i].freq }
        guard wanted.isFinite else { return bands[i].freq }
        return Int(min(max(wanted.rounded(), lower), upper))
    }

    private func nearestBand(to point: CGPoint, range: Double) -> Int? {
        Self.nearestBand(to: point, in: bands, size: viewSize, range: range)
    }

    nonisolated static func nearestBand(to point: CGPoint, in bands: [QxEqBandValue],
                                        size: CGSize, range: Double) -> Int? {
        let midY = size.height / 2
        let usable = max(size.height / 2 - 6, 1)
        var best: (index: Int, distance: CGFloat)?
        for (i, band) in bands.enumerated() where band.filter != .bypass {
            let bx = CGFloat(EQCurve.fraction(of: Double(band.freq))) * size.width
            let g = EQCurveView.markerGain(band)
            let by = midY - CGFloat(max(-range, min(range, g)) / range) * usable
            let d = hypot(point.x - bx, point.y - by)
            if d <= grabRadius, best == nil || d < best!.distance {
                best = (i, d)
            }
        }
        return best?.index
    }
}
