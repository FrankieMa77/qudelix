import AppKit
import Foundation
import SwiftUI

/// Computes the combined magnitude response of the 10 EQ bands so the UI can
/// draw the curve the device is actually applying.
///
/// Uses the standard RBJ audio-EQ-cookbook biquad coefficients, evaluated on
/// the unit circle: |H(e^jw)| = |b0 + b1·z⁻¹ + b2·z⁻²| / |a0 + a1·z⁻¹ + a2·z⁻²|
enum EQCurve {
    static let sampleRate: Double = 48000
    static let minFreq: Double = 20
    static let maxFreq: Double = 20000

    /// Magnitude in dB at `count` log-spaced frequencies from 20 Hz to 20 kHz.
    static func response(bands: [QxEqBandValue], preGain: Double, count: Int = 220) -> [Double] {
        response(bands: bands, preGain: preGain, at: logSweep(count: count))
    }

    /// Magnitude in dB at an explicit set of frequencies, for callers that
    /// need a grid the drawing one doesn't give them — a different span, a
    /// different density, or a handful of frequencies picked on purpose.
    static func response(bands: [QxEqBandValue], preGain: Double, at freqs: [Double]) -> [Double] {
        freqs.map { f in
            var db = preGain
            for band in bands where band.filter != .bypass {
                db += bandGainDb(band, at: f)
            }
            return db
        }
    }

    /// `count` frequencies spaced evenly on the log axis across `from`…`to`.
    static func logSweep(count: Int, from: Double = minFreq, to: Double = maxFreq) -> [Double] {
        let logMin = log10(from), logMax = log10(to)
        return (0..<count).map { i in
            let t = Double(i) / Double(max(count - 1, 1))
            return pow(10, logMin + t * (logMax - logMin))
        }
    }

    /// Frequency at normalised position 0…1 across the log axis.
    static func frequency(atFraction t: Double) -> Double {
        pow(10, log10(minFreq) + t * (log10(maxFreq) - log10(minFreq)))
    }

    /// Normalised 0…1 x-position of a frequency on the log axis.
    static func fraction(of freq: Double) -> Double {
        (log10(max(freq, minFreq)) - log10(minFreq)) / (log10(maxFreq) - log10(minFreq))
    }

    private static func bandGainDb(_ band: QxEqBandValue, at freq: Double) -> Double {
        let f0 = max(1, min(Double(band.freq), sampleRate / 2 - 1))
        let q = max(0.05, band.q)
        let gain = band.gain
        let a = pow(10, gain / 40)              // amplitude for shelf/peak maths
        let w0 = 2 * .pi * f0 / sampleRate
        let cosW0 = cos(w0), sinW0 = sin(w0)
        let alpha = sinW0 / (2 * q)

        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0

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
            return 0
        }

        let w = 2 * .pi * freq / sampleRate
        let cosW = cos(w), sinW = sin(w)
        let cos2W = cos(2 * w), sin2W = sin(2 * w)

        let numRe = b0 + b1 * cosW + b2 * cos2W
        let numIm = -(b1 * sinW + b2 * sin2W)
        let denRe = a0 + a1 * cosW + a2 * cos2W
        let denIm = -(a1 * sinW + a2 * sin2W)

        let num = sqrt(numRe * numRe + numIm * numIm)
        let den = sqrt(denRe * denRe + denIm * denIm)
        guard den > 1e-12, num > 1e-12 else { return 0 }
        let db = 20 * log10(num / den)
        return db.isFinite ? db : 0
    }
}

/// How much the current curve boosts, and the pre-gain that offsets it.
///
/// The filters run inside the 5K, and a curve whose bands sum above 0 dB asks
/// that DSP for more output than it has room for; what comes back is digital
/// clipping on loud passages, which sounds like harshness and looks like
/// nothing. Pre-gain sits ahead of the filters, so attenuating there by the
/// peak boost leaves the EQ stage unable to hand on more than it was given.
/// That is all it does — audio that was already clipped when it reached the
/// device stays clipped, and no pre-gain will find those samples again.
enum EQHeadroom {
    /// The pre-gain range the device accepts, in dB.
    ///
    /// The wire field is wider than this (a signed dB×10 int16, and the preset
    /// decoder tolerates ±24 before calling a read implausible), but the
    /// control the hardware exposes is ±12 — the same span a band gain has —
    /// and that is what this app has always sent. Everything that writes or
    /// proposes a pre-gain clamps here rather than repeating the literal.
    static let range: ClosedRange<Double> = -12...12

    /// The one clamp, for the write path, the slider and the suggestion alike.
    static func clamp(_ db: Double) -> Double {
        guard db.isFinite else { return 0 }
        return min(max(db, range.lowerBound), range.upperBound)
    }

    /// The span the peak search covers.
    ///
    /// Deliberately wider than the drawn 20 Hz–20 kHz window: a shelf sitting
    /// near either edge only reaches its full gain outside it, and a peak the
    /// search never visits is a peak the pre-gain never pays for. The top stops
    /// short of the 24 kHz Nyquist point, where an LPF's magnitude collapses to
    /// zero and the arithmetic stops being informative.
    private static let probeMin: Double = 10
    private static let probeMax: Double = 22000

    /// How finely that span is sampled.
    ///
    /// No fixed grid is the right answer on its own. The editor allows Q up to
    /// 10, and a biquad's width is `sin(w0)/Q` radians — so the same Q = 10
    /// spans 0.144 octaves at 1 kHz but only 0.035 at 19 kHz, where `sin(w0)`
    /// has fallen away towards Nyquist. Measured against a brute-force scan,
    /// even a 1024-point log grid reads a +12 dB Q = 10 peak 1.2 dB low at the
    /// top of the band, and the 220 points the curve is *drawn* with are nearly
    /// five times coarser than that. Reporting a dB too little is the one
    /// failure this feature cannot have: it is a dB of clipping the user was
    /// told had been dealt with.
    ///
    /// So the grid stays coarse enough to be cheap — 512 points, ~0.022
    /// octaves — and does what a grid is good at: broad shapes, shelf
    /// asymptotes, the sums of overlapping wide bands. The narrow features are
    /// handled by the clusters below, which is the only thing that can hide
    /// between grid lines.
    private static let probeCount = 512

    /// Probes placed either side of each feature, per half-width. Eight each
    /// way puts the spacing at an eighth of the feature's own half-width;
    /// checked against a brute-force scan over random band sets, the worst
    /// reading came out 0.03 dB low, which is inside the 0.05 dB that rounding
    /// to the device's stored step would swallow anyway.
    private static let clusterSteps = 8

    /// Every frequency the search visits: the log grid, plus a cluster around
    /// each sharp feature each live band contributes.
    ///
    /// The bands are the only narrow things in the response — nothing else can
    /// put a peak between two grid lines — and each one states how wide it is,
    /// so resolution can follow it instead of being guessed globally.
    private static func probes(for bands: [QxEqBandValue]) -> [Double] {
        var freqs = EQCurve.logSweep(count: probeCount, from: probeMin, to: probeMax)
        for band in bands where band.filter != .bypass {
            for w in featureFrequencies(of: band) {
                // Alpha again: half the feature's width in radians, and the
                // reason a high band is narrower than a low one at equal Q.
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

    /// Where a band's response turns over, in radians — the frequencies its
    /// poles and zeros sit at, which is where any extremum has to be.
    ///
    /// For a peak, an LPF or an HPF that is the centre frequency and nothing
    /// else, and a peaking biquad's maximum lands on it exactly. A shelf is
    /// the trap: its pole and zero are pushed apart by √A, so a +12 dB shelf
    /// with a high Q rings half an octave off its nominal corner, and a search
    /// that only looked at the corner would read it as much as 1.5 dB low.
    private static func featureFrequencies(of band: QxEqBandValue) -> [Double] {
        let f0 = min(max(Double(band.freq), probeMin), probeMax)
        let w0 = 2 * .pi * f0 / EQCurve.sampleRate
        switch band.filter {
        case .lowShelf, .highShelf:
            // Bilinear warping, so the split stays right near Nyquist where
            // digital and analogue frequency stop agreeing.
            let spread = pow(10, band.gain / 80)          // √A
            let t0 = tan(w0 / 2)
            return [2 * atan(t0 / spread), w0, 2 * atan(t0 * spread)]
        default:
            return [w0]
        }
    }

    /// Peak of the combined filter response above 0 dB, pre-gain excluded.
    /// Zero for a curve that only cuts — there is nothing to offset then.
    static func peakBoost(of bands: [QxEqBandValue]) -> Double {
        let peak = EQCurve.response(bands: bands, preGain: 0, at: probes(for: bands)).max() ?? 0
        return peak.isFinite ? max(0, peak) : 0
    }

    /// The pre-gain that offsets a given peak boost.
    ///
    /// Attenuation only: a positive pre-gain to "make the level back up" would
    /// hand straight back the headroom this exists to buy. Rounded to the
    /// 0.1 dB the device actually stores, so the number on screen is the number
    /// on the wire.
    static func preGain(offsetting peakBoost: Double) -> Double {
        let steps = (peakBoost * 10).rounded()
        guard steps.isFinite, steps > 0 else { return 0 }
        return clamp(-steps / 10)
    }

    /// The pre-gain this curve needs, ignoring whatever it currently has.
    static func suggestedPreGain(for bands: [QxEqBandValue]) -> Double {
        preGain(offsetting: peakBoost(of: bands))
    }

    /// What there is to say about the curve in front of the user.
    struct Advice: Equatable {
        /// Peak boost of the filters in dB, pre-gain excluded.
        var peakBoost: Double
        /// The value to offer, or nil when the pre-gain already in place
        /// covers the boost. A pre-gain deeper than the curve needs is never
        /// something to "correct": the user chose it, and undoing it would be
        /// a level rise they didn't ask for.
        var suggestion: Double?
        /// Boost that even the deepest pre-gain the device takes cannot
        /// offset. Non-zero only for curves that boost past the range, and the
        /// reason the UI can't promise the EQ stage stays inside 0 dB.
        var shortfall: Double
    }

    static func advice(for bands: [QxEqBandValue], preGain currentPreGain: Double) -> Advice {
        let peak = peakBoost(of: bands)
        let want = preGain(offsetting: peak)
        // Worth a button only when it buys at least one whole stored step more
        // attenuation than the user already has.
        let offer = want < currentPreGain - 0.05 ? want : nil
        return Advice(peakBoost: peak, suggestion: offer,
                      shortfall: max(0, peak + range.lowerBound))
    }
}

/// How far a requested correction and the one the device could take have
/// parted company, and where.
///
/// An imported correction is fitted for a generic equalizer: as many bands as
/// it likes, any gain, any Q. The 5K has ten or twenty bands, ±12 dB, Q inside
/// 0.1…10 and a 20 Hz–20 kHz window, and the import path folds the request into
/// that before it reaches the wire. Today the user is told a count — "N band(s)
/// … will be clamped" — which is the one thing about the outcome that doesn't
/// matter. A shape flattened at 40 Hz and the same shape flattened at 8 kHz
/// produce identical sentences and completely different sound.
///
/// So the comparison is made on the response, not on the bands: two curves
/// sampled on the same grid, subtracted. That catches everything a per-band
/// check would miss — a band the device never received at all, a Q pulled in
/// until a narrow notch became a wide dip, two clamped bands whose errors
/// happen to cancel — and it reports the answer in the units the user is
/// already reading off the axis.
enum EQDivergence {
    /// Below this, in dB, the two curves are the same curve.
    ///
    /// The device stores gains in tenths of a dB and hands them back through
    /// its own fixed-point scaling, so even a request that fitted exactly comes
    /// back a few hundredths out; the existing read-back comparison allows 0.06
    /// for the same reason. A quarter of a dB sits well clear of that and well
    /// under anything audible, which is the bar a second line on the chart has
    /// to clear before it earns the ink.
    static let tolerance: Double = 0.25

    /// The gap, sample by sample, plus the two things worth drawing about it.
    struct Reading: Equatable {
        /// Requested minus applied, in dB, one per point of the shared grid.
        /// Positive means the device is giving less lift than was asked for.
        var deltas: [Double]
        /// Grid index of the widest gap and its signed size — the one place
        /// worth putting a number.
        var peakIndex: Int
        var peak: Double
        /// Contiguous stretches wide enough to shade.
        var spans: [ClosedRange<Int>]
    }

    /// nil whenever there is nothing to draw: grids that don't line up, a
    /// response that isn't a number, or two curves that agree everywhere.
    ///
    /// Both inputs are expected to exclude pre-gain, as the drawn curve does.
    /// A pre-gain that had to be clamped is a level change, not a shape change:
    /// folding it in here would slide the whole ghost curve off the applied one
    /// and report a divergence at every frequency, including the ones where the
    /// device gave exactly what was asked.
    static func reading(requested: [Double], applied: [Double]) -> Reading? {
        guard requested.count == applied.count, requested.count > 1 else { return nil }
        var deltas = [Double](repeating: 0, count: applied.count)
        var peakIndex = 0
        var peak = 0.0
        for i in applied.indices {
            let d = requested[i] - applied[i]
            // A non-finite sample means the comparison is meaningless, and
            // treating it as zero would be a claim that the device matched the
            // request there. Say nothing instead.
            guard d.isFinite else { return nil }
            deltas[i] = d
            if abs(d) > abs(peak) { peak = d; peakIndex = i }
        }
        guard abs(peak) > tolerance else { return nil }
        return Reading(deltas: deltas, peakIndex: peakIndex, peak: peak,
                       spans: spans(of: deltas, above: tolerance))
    }

    /// Runs of indices where the gap is worth showing, each widened by one
    /// sample at either end.
    ///
    /// The widening is what stops a shaded region from starting with a visible
    /// vertical edge: the neighbouring sample is by definition inside the
    /// tolerance, so the patch tapers to nearly nothing there instead of
    /// beginning at full height. Runs that overlap once widened are merged, so
    /// a single sample dipping under the tolerance mid-divergence doesn't split
    /// one region into two.
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
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [.accentColor.opacity(0.34), .accentColor.opacity(0.05)]),
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

            ctx.stroke(curve, with: .color(.accentColor), lineWidth: 1.8)

            // The band the pointer is over: a ring, not a bigger dot, so it
            // reads as "this is what you'd grab" rather than as a state the
            // band is in.
            if let h = hovering, dragging == nil, bands.indices.contains(h),
               bands[h].filter != .bypass {
                let hx = CGFloat(EQCurve.fraction(of: Double(bands[h].freq))) * size.width
                let ring = Path(ellipseIn: CGRect(x: hx - 7, y: y(bands[h].gain) - 7,
                                                  width: 14, height: 14))
                ctx.stroke(ring, with: .color(.accentColor.opacity(0.45)), lineWidth: 1)
            }

            // Band markers.
            for (i, band) in bands.enumerated() where band.filter != .bypass {
                let dotX = CGFloat(EQCurve.fraction(of: Double(band.freq))) * size.width
                let isOn = highlighted == i
                let r: CGFloat = isOn ? 4 : 2.5
                let dot = Path(ellipseIn: CGRect(x: dotX - r, y: y(band.gain) - r,
                                                 width: r * 2, height: r * 2))
                ctx.fill(dot, with: .color(isOn ? .accentColor : .accentColor.opacity(0.55)))
                if isOn {
                    ctx.stroke(dot, with: .color(.white.opacity(0.9)), lineWidth: 1.2)
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
            switch phase {
            case .active(let point): hovering = nearestBand(to: point, range: plot.range)
            case .ended: hovering = nil
            }
        }
        .gesture(onBandChanged == nil ? nil : dragGesture(range: plot.range))
        .help(onBandChanged == nil ? "" : "Drag a point to shape the curve: up and "
              + "down for gain, sideways for frequency. Hold Option and drag up or "
              + "down for Q. Hold Shift for fine adjustment.")
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            Text("±\(Int(plot.range)) dB")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .padding(4)
        }
        .overlay(alignment: .topTrailing) {
            if abs(preGain) >= 0.05 {
                Text(String(format: "pre-gain %+.1f dB", preGain))
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
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
                    onDragBand?(hit)
                }
                guard let i = dragging, bands.indices.contains(i),
                      let origin = dragOrigin else { return }
                var band = bands[i]

                // Modifiers are read live, not captured at the press: nobody
                // reaches for one before there is something to hold, so both
                // must be possible to take up and release mid-drag.
                let mods = NSEvent.modifierFlags
                let scale = mods.contains(.shift) ? Self.fineDragScale : 1
                let dx = (value.location.x - value.startLocation.x) * scale
                let dy = (value.location.y - value.startLocation.y) * scale

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
                let usable = max(viewSize.height / 2 - 6, 1)
                let db = origin.gain - Double(dy / usable) * range
                band.gain = (min(max(db, -12), 12) * 10).rounded() / 10

                // Horizontal: frequency, kept strictly between its neighbours.
                // Compared by frequency value rather than array position: a
                // typed edit in the table can leave the array unsorted, and an
                // index-based clamp would then teleport the dot being dragged.
                let startFx = EQCurve.fraction(of: Double(origin.freq))
                let fx = min(max(startFx + Double(dx / viewSize.width), 0), 1)
                band.freq = Self.clampedFrequency(EQCurve.frequency(atFraction: fx),
                                                  forBand: i, in: bands)

                guard band != bands[i] else { return }
                onBandChanged?(i, band)
            }
            .onEnded { _ in
                dragging = nil
                dragOrigin = nil
                onDragBand?(nil)
            }
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
        var freq = wanted
        let current = Double(bands[i].freq)
        let others = bands.enumerated()
            .filter { $0.offset != i && $0.element.filter != .bypass }
            .map { Double($0.element.freq) }
        if let below = others.filter({ $0 < current }).max() {
            freq = max(freq, below * minNeighbourRatio)
        }
        if let above = others.filter({ $0 > current }).min() {
            freq = min(freq, above / minNeighbourRatio)
        }
        return Int(min(max(freq.rounded(), 20), 20000))
    }

    /// The band whose marker is nearest the press, or nil if none is close
    /// enough. Bypassed bands are excluded: they draw no marker, and grabbing
    /// an invisible one would edit a band the user cannot see.
    private func nearestBand(to point: CGPoint, range: Double) -> Int? {
        let midY = viewSize.height / 2
        let usable = max(viewSize.height / 2 - 6, 1)
        var best: (index: Int, distance: CGFloat)?
        for (i, band) in bands.enumerated() where band.filter != .bypass {
            let bx = CGFloat(EQCurve.fraction(of: Double(band.freq))) * viewSize.width
            let by = midY - CGFloat(max(-range, min(range, band.gain)) / range) * usable
            let d = hypot(point.x - bx, point.y - by)
            if d <= Self.grabRadius, best == nil || d < best!.distance {
                best = (i, d)
            }
        }
        return best?.index
    }
}
