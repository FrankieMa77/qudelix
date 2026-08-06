import Accelerate
import Foundation

/// Estimates whether what's playing came from a lossy or lossless source, by
/// measuring the audio itself. Lossy codecs low-pass the signal — 128 kbps
/// cuts around 16 kHz, 256–320 kbps around 19–20.5 kHz — while lossless
/// material carries energy to the edge of its sample rate with a natural
/// roll-off. The classifier finds that spectral edge.
///
/// This measures BANDWIDTH LIMITING, which correlates with lossy encoding
/// but is not proof: a lossless file transcoded from a lossy source keeps
/// the cutoff (and deserves the flag), old analog masters roll off
/// naturally, and quiet or dark material has no treble to judge — which is
/// why "can't tell" is a first-class verdict, not a failure.
final class QualityAnalyzer {

    enum Verdict: Equatable {
        case tooQuiet                 // not enough signal to judge
        case noTreble                 // loud enough, but no HF content at all
        case lossy(cutoffKHz: Double)         // sharp edge well below Nyquist
        case lossyHigh(cutoffKHz: Double)     // 256–320 kbps territory
        case losslessLike(cutoffKHz: Double)  // extends to the 44.1/48 edge
        case hiRes(cutoffKHz: Double)         // content beyond 22.5 kHz
        /// A GRADUAL roll-off in codec territory: the master's own spectrum,
        /// not a codec cliff — warm acoustic material does this losslessly,
        /// and a lossy cut of the same master would look identical. No vote.
        case natural(cutoffKHz: Double)

        /// The lossy/lossless binary used for rate switching. nil = no vote.
        ///
        /// A cliff near the 20 kHz boundary abstains: the same physical
        /// cliff measures a few hundred Hz differently at different device
        /// rates, and a boundary-riding verdict that voted would ping-pong
        /// the rate (observed live: 20.9 kHz at a 96 k device rate, 20.1 at
        /// 44.1 — one cliff, two verdicts). Clear cases still vote.
        var isLosslessClass: Bool? {
            switch self {
            case .lossy: return false
            case .lossyHigh(let k): return k < 19.7 ? false : nil
            case .losslessLike, .hiRes: return true
            case .tooQuiet, .noTreble, .natural: return nil
            }
        }

        /// Category without the measured cutoff. Stability MUST be judged
        /// on this: the cutoff is a fresh FFT measurement every time, and
        /// two rounds never produce the same 21.83… twice — full equality
        /// makes "three consecutive equal verdicts" unreachable.
        var kind: Int {
            switch self {
            case .tooQuiet: return 0
            case .noTreble: return 1
            case .lossy: return 2
            case .lossyHigh: return 3
            case .losslessLike: return 4
            case .hiRes: return 5
            case .natural: return 6
            }
        }
    }

    static let fftSize = 8192
    private let log2n = vDSP_Length(13)
    private var fftSetup: FFTSetup?
    private var window = [Float](repeating: 0, count: fftSize)
    private var real = [Float](repeating: 0, count: fftSize / 2)
    private var imag = [Float](repeating: 0, count: fftSize / 2)
    private var magnitudes = [Float](repeating: 0, count: fftSize / 2)
    /// Averaged spectrum across recent windows, in dB.
    private var averagedDb = [Float](repeating: -160, count: fftSize / 2)
    private var windowsAveraged = 0

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    /// Feed one window of consecutive samples (fftSize of them) at the
    /// device rate. Spectra are averaged; call `classify` when a few have
    /// accumulated. Control thread only.
    func feed(_ samples: [Float]) {
        guard samples.count >= Self.fftSize, let fftSetup else { return }

        var windowed = [Float](repeating: 0, count: Self.fftSize)
        samples.withUnsafeBufferPointer { p in
            vDSP_vmul(p.baseAddress!, 1, window, 1, &windowed, 1,
                      vDSP_Length(Self.fftSize))
        }

        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                              &split, 1, vDSP_Length(Self.fftSize / 2))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(Self.fftSize / 2))
            }
        }

        // dB, with a floor; running max-hold average across windows (peaks
        // matter — treble is sparse in time, and a mean would wash it out).
        var floorVal: Float = 1e-12
        vDSP_vthr(magnitudes, 1, &floorVal, &magnitudes, 1, vDSP_Length(Self.fftSize / 2))
        var one: Float = 1
        var db = [Float](repeating: 0, count: Self.fftSize / 2)
        // Flag 0 = POWER (10·log10): the input is magnitude-squared. Flag 1
        // treats it as amplitude and doubles every dB in the pipeline —
        // which silently doubles every threshold tuned against it.
        vDSP_vdbcon(magnitudes, 1, &one, &db, 1, vDSP_Length(Self.fftSize / 2), 0)
        if windowsAveraged == 0 {
            averagedDb = db
        } else {
            vDSP_vmax(averagedDb, 1, db, 1, &averagedDb, 1, vDSP_Length(Self.fftSize / 2))
        }
        windowsAveraged += 1
    }

    /// Drop any half-accumulated spectra — for rate changes, where mixing
    /// windows from two rates mislabels every bin frequency.
    func reset() {
        windowsAveraged = 0
    }

    /// The last classification's raw numbers, for diagnostics.
    private(set) var lastDebug = ""

    /// Classify what has accumulated since the last call, then reset.
    /// Returns nil when nothing was fed.
    func classify(sampleRate: Double) -> Verdict? {
        defer { windowsAveraged = 0 }
        guard windowsAveraged > 0, sampleRate > 0 else { return nil }

        let binHz = sampleRate / Double(Self.fftSize)
        func bin(_ hz: Double) -> Int {
            min(Self.fftSize / 2 - 1, max(0, Int(hz / binHz)))
        }

        // Loudness gate on TOTAL band power (300 Hz – 8 kHz): individual
        // bins of a 5 Hz-wide FFT are far quieter than the music is, so any
        // per-bin absolute threshold misreads real signal as silence.
        var totalPower: Double = 0
        for i in bin(300)...bin(8000) {
            totalPower += pow(10, Double(averagedDb[i]) / 10)
        }
        // Raw zrip/Hann-NORM FFT numbers summed across the band sit ~79 dB
        // above dBFS at this size (measured against known-RMS noise);
        // calibrate so the gate means what it says.
        let bandPowerDb = 10 * log10(max(totalPower, 1e-16)) - 79
        lastDebug = String(format: "bandPower=%.1f dBFS", bandPowerDb)
        guard bandPowerDb > -55 else { return .tooQuiet }

        // Reference: the 75th-percentile bin level in the 1–8 kHz band —
        // near the real content level for both tonal and broadband material.
        // Used only for the profile display and the nothing-up-here gate;
        // real music tilts 40–80 dB from midband to treble, so no fixed
        // offset from this reference can find the treble edge (field lesson).
        let refBins = Array(averagedDb[bin(1000)...bin(8000)]).sorted()
        let reference = refBins[(refBins.count * 3) / 4]

        // Coarse profile: max level in 250 Hz cells from 9 kHz up. All
        // classification below works on this — max-hold cells are robust
        // against the FFT's bin-to-bin variance.
        let topHz = sampleRate / 2 - 200
        var cells: [(kHz: Double, level: Float)] = []
        var f = 9000.0
        while f + 250 <= topHz {
            var level: Float = -160
            for i in bin(f)...bin(f + 250) { level = max(level, averagedDb[i]) }
            cells.append((kHz: (f + 125) / 1000, level: level))
            f += 250
        }
        guard cells.count > 8 else { return .noTreble }

        // Diagnostic profile at fixed frequencies, reference-relative.
        var profile = ""
        for kHz in [10.0, 13, 16, 18, 19, 20, 21, 21.8] where kHz * 1000 < topHz {
            if let cell = cells.last(where: { $0.kHz <= kHz }) {
                profile += String(format: " %gk:%.0f", kHz, cell.level - reference)
            }
        }
        lastDebug += " ref-rel:" + profile

        // Anchor: the low-treble level (9–11 kHz), the yardstick everything
        // above it is judged against. If even that is buried, there is no
        // treble to reason about.
        let anchor = cells.prefix(8).map(\.level).max() ?? -160
        guard anchor > reference - 40 else { return .noTreble }

        // A codec cliff: ≥20 dB lost within one kHz, somewhere above 12 kHz.
        // The steepest natural masters shed under ~15 dB/kHz; encoders drop
        // into digital silence. Position separates the suspects — 320 kbps
        // cuts by ~20 kHz, while 44.1 lossless played at a higher device
        // rate shows its OWN legitimate cliff at the source Nyquist (~22 k).
        var cliffKHz = 0.0
        var cliffDrop: Float = 0
        for i in 0..<(cells.count - 4) where cells[i].kHz >= 12 {
            let drop = cells[i].level - cells[i + 4].level
            if drop > cliffDrop {
                cliffDrop = drop
                cliffKHz = cells[i].kHz + 0.5
            }
        }
        if cliffDrop >= 20 {
            lastDebug += String(format: " cliff=%.1fk (%.0f dB)", cliffKHz, cliffDrop)
            switch cliffKHz {
            case ..<18.5: return .lossy(cutoffKHz: cliffKHz)
            case ..<20.25: return .lossyHigh(cutoffKHz: cliffKHz)
            case ..<22.5: return .losslessLike(cutoffKHz: cliffKHz)
            default: return .hiRes(cutoffKHz: cliffKHz)
            }
        }

        // No cliff: find where the content fades below the anchor by 35 dB.
        // Fading only near the very top (or not at all) means nothing cut
        // it; fading early is the master's own darkness.
        let fadeKHz = cells.last(where: { $0.level > anchor - 35 })?.kHz ?? 0
        lastDebug += String(format: " fade=%.1fk", fadeKHz)
        let topKHz = topHz / 1000
        if fadeKHz >= 22.5 { return .hiRes(cutoffKHz: fadeKHz) }
        if fadeKHz >= min(20.9, topKHz - 0.5) { return .losslessLike(cutoffKHz: fadeKHz) }
        if fadeKHz < 14.5 { return .noTreble }
        return .natural(cutoffKHz: fadeKHz)
    }
}
