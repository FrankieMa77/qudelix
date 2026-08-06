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

/// Draws the combined EQ response with a log frequency axis.
///
/// The curve shows the filter shape *excluding* pre-gain — pre-gain is a
/// uniform offset to avoid clipping, so folding it in would just slide the
/// whole curve off-centre and hide the tonal shape. It's captioned instead.
struct EQCurveView: View {
    let bands: [QxEqBandValue]
    let preGain: Double
    var highlighted: Int?          // band index to mark, while it's being edited

    /// Symmetric dB range, grown to fit the curve so small edits stay legible.
    private var range: Double {
        let peak = EQCurve.response(bands: bands, preGain: 0).map(abs).max() ?? 0
        return min(18, max(9, (peak / 3).rounded(.up) * 3 + 3))
    }

    var body: some View {
        Canvas { ctx, size in
            let range = self.range
            let values = EQCurve.response(bands: bands, preGain: 0)
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
                let x = CGFloat(EQCurve.fraction(of: f)) * size.width
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(line, with: .color(.secondary.opacity(0.14)), lineWidth: 0.5)
                ctx.draw(Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary),
                         at: CGPoint(x: x + 11, y: size.height - 7))
            }

            guard values.count > 1 else { return }

            // The response curve, with a soft fill down to the 0 dB line.
            var curve = Path()
            for (i, db) in values.enumerated() {
                let x = CGFloat(i) / CGFloat(values.count - 1) * size.width
                let p = CGPoint(x: x, y: y(db))
                i == 0 ? curve.move(to: p) : curve.addLine(to: p)
            }

            var fill = curve
            fill.addLine(to: CGPoint(x: size.width, y: y(0)))
            fill.addLine(to: CGPoint(x: 0, y: y(0)))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [.accentColor.opacity(0.34), .accentColor.opacity(0.05)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            ctx.stroke(curve, with: .color(.accentColor), lineWidth: 1.8)

            // Band markers.
            for (i, band) in bands.enumerated() where band.filter != .bypass {
                let x = CGFloat(EQCurve.fraction(of: Double(band.freq))) * size.width
                let isOn = highlighted == i
                let r: CGFloat = isOn ? 4 : 2.5
                let dot = Path(ellipseIn: CGRect(x: x - r, y: y(band.gain) - r,
                                                 width: r * 2, height: r * 2))
                ctx.fill(dot, with: .color(isOn ? .accentColor : .accentColor.opacity(0.55)))
                if isOn {
                    ctx.stroke(dot, with: .color(.white.opacity(0.9)), lineWidth: 1.2)
                }
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            Text("±\(Int(range)) dB")
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
}
