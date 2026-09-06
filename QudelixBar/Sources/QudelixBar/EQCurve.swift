import Foundation

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
        let filters = bands.compactMap(BandFilter.init(band:))
        guard !filters.isEmpty else { return [Double](repeating: preGain, count: freqs.count) }
        return freqs.map { f in
            let phase = Phase(radians: 2 * .pi * f / sampleRate)
            var db = preGain
            for filter in filters { db += filter.gainDb(at: phase) }
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
