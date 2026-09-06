import AppKit
import Foundation
import SwiftUI

/// Draws the combined EQ response with a log frequency axis.
///
/// The curve shows the filter shape *excluding* pre-gain — pre-gain is a
/// uniform offset to avoid clipping, so folding it in would just slide the
/// whole curve off-centre and hide the tonal shape. It's captioned instead.
struct EQCurveView: View {
    let bands: [QxEqBandValue]
    let preGain: Double
    var highlighted: Int?          // band index to mark, while it's being edited

    /// The correction as it was asked for, before the device's band count,
    /// gain ceiling, Q limits and frequency window reshaped it — or nil when
    /// nothing was imported, which is the common case and draws nothing extra.
    ///
    /// Only the bands are read. The file's preamp is deliberately ignored; see
    /// `EQDivergence.reading`.
    var requested: ParametricEQFile?

    /// Shapes parked by a per-band mute, so the divergence measurement can tell
    /// a band the user silenced from one the device could not hold. Empty in
    /// the ordinary case, which is why it defaults.
    var mutedBands: [Int: QxFilter] = [:]

    var enabled: Bool = true

    var selectedBand: Int?

    var onSelectBand: ((Int?) -> Void)?

    var onZeroBand: ((Int) -> Void)?

    /// Called with a band's new value as it is dragged. Absent — the default —
    /// leaves the curve read-only, which is what the render harness and any
    /// non-editing use of this view want.
    var onBandChanged: ((Int, QxEqBandValue) -> Void)?
    /// Reported while a drag is in progress so the band table can highlight
    /// the same row, and cleared on release.
    var onDragBand: ((Int?) -> Void)?

    /// Which band this drag captured. Chosen once, at the press, and held for
    /// the whole gesture: re-picking as the pointer moves would hop between
    /// bands the moment it crossed another one, which turns one intended edit
    /// into several unintended ones.
    @State private var dragging: Int?

    /// The canvas's drawn size. The gesture lives outside the `Canvas` closure,
    /// which is the only place the size is handed to us, so it is recorded here
    /// and read back when converting a press into a frequency and a gain.
    @State private var viewSize: CGSize = .zero

    /// The band the pointer is over, so the grab target is visible before the
    /// press rather than discovered by grabbing the wrong one. Kept separate
    /// from `highlighted`, which the band table drives — a hover is a
    /// different thing from an edit in progress and should not look like one.
    @State private var hovering: Int?

    /// The band's value when the drag began. Movement is applied as an offset
    /// from this rather than by placing the band under the pointer: the grab
    /// radius is far larger than the dot, so an absolute map would snap the
    /// band to wherever the press landed before the pointer had moved at all.
    /// Holding it also makes a fine-adjust modifier possible, which an
    /// absolute map cannot express.
    @State private var dragOrigin: QxEqBandValue?

    /// Where the current leg of the drag started, and under which modifiers.
    ///
    /// Movement is measured from here rather than from the gesture's own start
    /// point so that taking up Shift or Option re-anchors instead of rescaling
    /// everything already dragged. Without this, reaching +6 dB and *then*
    /// pressing Shift to refine it snapped the band to 1.6 dB — the advertised
    /// workflow destroyed the value it was meant to refine.
    @State private var dragAnchor: CGPoint?
    @State private var dragModifiers: NSEvent.ModifierFlags = []

    /// The axis in force when the drag began.
    ///
    /// The drawn range grows with the curve, and the gain map is scaled by it,
    /// so an axis that stepped from 9 to 12 dB mid-gesture moved the band about
    /// 2 dB without the pointer moving. Held fixed for the gesture.
    @State private var dragRange: Double?

    /// How much a drag is slowed while Shift is held. The graph is 104 points
    /// tall for as much as ±18 dB, so a quarter-speed mode is the difference
    /// between setting 3 dB and setting roughly 3 dB.
    private static let fineDragScale: CGFloat = 0.25

    /// How far from a marker a press still counts, in points. The 20-band
    /// layout puts markers about 20pt apart in a 400pt window, so this is
    /// deliberately larger than the dot: the nearest one wins rather than
    /// requiring a hit on a 5pt target.
    private static let grabRadius: CGFloat = 22

    /// Neighbouring bands may not be dragged past each other, and must keep
    /// this much of a gap. Crossing would reorder the curve under the table.
    static let minNeighbourRatio = 1.05

    /// Everything a redraw needs, worked out once.
    ///
    /// The axis size and the curve were previously derived from two separate
    /// evaluations of the same response, which a second curve would have turned
    /// into four. This view redraws on every frame of a slider drag, so the
    /// whole plot is computed once per body evaluation and shared by the canvas
    /// and the corner label.
    private struct Plot {
        var applied: [Double]
        /// Present only when there is a request *and* the device changed it.
        var requested: [Double]?
        var divergence: EQDivergence.Reading?
        /// Symmetric dB range, grown to fit the curve so small edits stay
        /// legible.
        var range: Double
    }

    private func plot() -> Plot {
        let applied = EQCurve.response(bands: bands, preGain: 0)
        let asked = requested.map { EQCurve.response(bands: $0.bands, preGain: 0) }
        // Divergence is measured against the curve with mutes undone, not the
        // one being drawn. A mute is the user silencing a band on purpose; the
        // shading and the "N dB" label mean "the device could not hold what was
        // asked for", and pointing them at the user's own A/B would be the app
        // blaming the hardware for something the user did a second ago. The
        // drawn curve still shows the mute — that is what is being heard.
        let comparable = mutedBands.isEmpty
            ? applied
            : EQCurve.response(bands: unmuted(bands), preGain: 0)
        let gap = asked.flatMap { EQDivergence.reading(requested: $0, applied: comparable) }

        // The axis has to hold whichever curves are drawn. A request that
        // overshoots is exactly the case this feature exists for, and an axis
        // sized to the applied curve alone would pin the ghost flat along the
        // top edge — turning "asked for 6 dB more here" into "asked for as much
        // as the frame allows, somewhere". The 3 dB quantisation means most
        // divergences don't move the axis at all, and the 18 dB ceiling caps
        // what the live curve can ever be shrunk to.
        var peak = applied.map(abs).max() ?? 0
        if gap != nil, let asked { peak = max(peak, asked.map(abs).max() ?? 0) }

        return Plot(applied: applied,
                    requested: gap == nil ? nil : asked,
                    divergence: gap,
                    range: min(18, max(9, (peak / 3).rounded(.up) * 3 + 3)))
    }

    /// `bands` with each muted band's parked shape put back, so a comparison
    /// sees the curve the user actually asked the device to hold.
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

            // Horizontal grid: 0 dB emphasised, the rest faint.
            let step = range > 12 ? 6.0 : (range > 9 ? 6.0 : 3.0)
            for db in stride(from: -range + step, through: range - step, by: step) {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(db)))
                line.addLine(to: CGPoint(x: size.width, y: y(db)))
                ctx.stroke(line, with: .color(.secondary.opacity(db == 0 ? 0.45 : 0.14)),
                           lineWidth: db == 0 ? 1 : 0.5)
            }
            // Vertical grid at decades.
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

            // The response curve, with a soft fill down to the 0 dB line.
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

            // What was asked for, where the device couldn't give it.
            //
            // Everything here is drawn on top of the accent fill but under the
            // accent stroke, and in `secondary` rather than a colour of its
            // own. The live curve is the truth about what the user is hearing;
            // this is a note in the margin, and it has to stay legible as one
            // without ever competing for the eye.
            if let asked = plot.requested, let gap = plot.divergence,
               asked.count == values.count {
                // The shaded gap is the whole message: it says where the two
                // disagree and, read against the dB gridlines, by how much,
                // with no key to look up and no space spent on one.
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

                // The worst departure gets the one number on the chart, so the
                // size of the shortfall doesn't have to be estimated off the
                // gridlines. Under a dB there is nothing to say that the shape
                // hasn't already said, and the label would only be clutter.
                if abs(gap.peak) >= 1 {
                    let px = x(gap.peakIndex)
                    let applied = y(values[gap.peakIndex]), wanted = y(asked[gap.peakIndex])
                    var tick = Path()
                    tick.move(to: CGPoint(x: px, y: applied))
                    tick.addLine(to: CGPoint(x: px, y: wanted))
                    ctx.stroke(tick, with: .color(.secondary.opacity(0.5)), lineWidth: 0.8)
                    // Set the number on whichever side of the tick has room,
                    // and halfway up the gap so it can't land on either curve.
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

            // The band the pointer is over: a ring, not a bigger dot, so it
            // reads as "this is what you'd grab" rather than as a state the
            // band is in.
            if let h = hovering, dragging == nil, bands.indices.contains(h),
               bands[h].filter != .bypass {
                let hx = CGFloat(EQCurve.fraction(of: Double(bands[h].freq))) * size.width
                let ring = Path(ellipseIn: CGRect(x: hx - 7,
                                                  y: y(EQCurveView.markerGain(bands[h])) - 7,
                                                  width: 14, height: 14))
                ctx.stroke(ring, with: .color(tint.opacity(0.45)), lineWidth: 1)
            }

            // Band markers.
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

    // MARK: - Dragging a band

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

                // Modifiers are read live, not captured at the press: nobody
                // reaches for one before there is something to hold, so both
                // must be possible to take up and release mid-drag.
                let mods = NSEvent.modifierFlags.intersection([.shift, .option])
                if mods != dragModifiers {
                    // Re-anchor: from here on, movement is measured against the
                    // value the band holds now, under the new modifiers.
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

                // Option turns the vertical axis into Q. Read from the live
                // modifier state rather than captured at the press, so the key
                // can be taken up or released mid-drag and the gesture follows
                // — pressing it first, before there is anything to hold, is not
                // how anyone reaches for a modifier.
                // Option turns the vertical axis into Q, logarithmically: Q
                // runs 0.1 to 10, and a linear pixel map spends most of its
                // travel between 8 and 10 while cramming the wide end — where
                // the musically useful values are — into a few pixels.
                if mods.contains(.option) {
                    let decades = log10(10.0) - log10(0.1)
                    let perPoint = decades / Double(max(viewSize.height - 12, 1))
                    let q = pow(10, log10(origin.q) - Double(dy) * perPoint)
                    band.q = (min(max(q, 0.1), 10) * 100).rounded() / 100
                    guard band != bands[i] else { return }
                    return onBandChanged?(i, band) ?? ()
                }

                // Vertical: gain, clamped to what the device accepts rather
                // than to the drawn axis — the axis grows to fit a ghost and
                // must not become a way to ask for more than ±12 dB.
                if band.filter.hasGain {
                    let usable = max(viewSize.height / 2 - 6, 1)
                    let db = origin.gain - Double(dy / usable) * range
                    band.gain = (min(max(db, -12), 12) * 10).rounded() / 10
                }

                // Horizontal: frequency, kept strictly between its neighbours.
                // Compared by frequency value rather than array position: a
                // typed edit in the table can leave the array unsorted, and an
                // index-based clamp would then teleport the dot being dragged.
                let startFx = EQCurve.fraction(of: Double(origin.freq))
                // Floored like the vertical axis above. A zero width makes
                // this 0/0, and NaN passes straight through `min`/`max` when it
                // is the first argument — every comparison against it is false
                // — reaching `Int()`, which traps.
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

    /// A dragged frequency, kept strictly between the band's neighbours.
    ///
    /// Neighbours are found by frequency *value*, not array position: a typed
    /// edit in the band table can leave the array unsorted, and an index-based
    /// clamp would then teleport the dot being dragged to the wrong side of
    /// something. Bypassed bands draw no marker and are not obstacles.
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
        // Neighbours closer together than twice the gap leave no room between
        // them, and applying the two clamps in sequence let the upper one
        // overwrite the lower — throwing the node *past* the neighbour it was
        // being kept above, which is the reordering this function exists to
        // prevent. With nowhere legal to go, the band stays where it is.
        guard lower <= upper else { return bands[i].freq }
        guard wanted.isFinite else { return bands[i].freq }
        return Int(min(max(wanted.rounded(), lower), upper))
    }

    /// The band whose marker is nearest the press, or nil if none is close
    /// enough. Bypassed bands are excluded: they draw no marker, and grabbing
    /// an invisible one would edit a band the user cannot see.
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
