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

        /// The lossy/lossless binary used for rate switching. nil = no vote.
        var isLosslessClass: Bool? {
            switch self {
            case .lossy, .lossyHigh: return false
            case .losslessLike, .hiRes: return true
            case .tooQuiet, .noTreble: return nil
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
        vDSP_vdbcon(magnitudes, 1, &one, &db, 1, vDSP_Length(Self.fftSize / 2), 1)
        if windowsAveraged == 0 {
            averagedDb = db
        } else {
            vDSP_vmax(averagedDb, 1, db, 1, &averagedDb, 1, vDSP_Length(Self.fftSize / 2))
        }
        windowsAveraged += 1
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
        // Raw zrip/Hann-NORM FFT numbers sit ~104 dB above dBFS at this
        // size (measured against known-RMS noise); calibrate so the gate
        // means what it says.
        let bandPowerDb = 10 * log10(max(totalPower, 1e-16)) - 104
        lastDebug = String(format: "bandPower=%.1f dBFS", bandPowerDb)
        guard bandPowerDb > -60 else { return .tooQuiet }

        // Reference for the edge search: the 75th-percentile bin level in
        // the 1–8 kHz band — near the real content level for both tonal
        // material (peaks) and broadband material, unlike a median, which
        // tonal music drags down into the gaps between harmonics.
        let refBins = Array(averagedDb[bin(1000)...bin(8000)]).sorted()
        let reference = refBins[(refBins.count * 3) / 4]

        // The spectral edge: the highest frequency still within 40 dB of the
        // reference, required to hold for a few consecutive bins so a lone
        // noise spike can't fake extension.
        let threshold = reference - 40
        let searchTop = min(bin(sampleRate / 2 - 200), Self.fftSize / 2 - 1)
        var edgeBin = 0
        var run = 0
        for i in stride(from: searchTop, through: bin(8000), by: -1) {
            if averagedDb[i] > threshold {
                run += 1
                if run >= 4 { edgeBin = i + run - 1; break }
            } else {
                run = 0
            }
        }
        guard edgeBin > 0 else { return .noTreble }
        let edgeKHz = Double(edgeBin) * binHz / 1000

        // The device Nyquist clips what is observable: content can never
        // extend past it, so "reaches the top" at a 44.1/48 device rate is
        // still only "lossless-like", never "hi-res". And an edge BELOW any
        // plausible codec cutoff isn't a codec at all — it's dark material
        // (a quiet piano passage rolls off by 10 kHz on its own), which is
        // honestly unjudgeable, not lossy.
        switch edgeKHz {
        case ..<14.5: return .noTreble
        case ..<18.5: return .lossy(cutoffKHz: edgeKHz)
        case ..<20.8: return .lossyHigh(cutoffKHz: edgeKHz)
        case ..<22.5: return .losslessLike(cutoffKHz: edgeKHz)
        default: return .hiRes(cutoffKHz: edgeKHz)
        }
    }
}
