import Accelerate
import XCTest
@testable import QudelixBar

/// The soft clipper's anti-aliasing, measured rather than asserted by faith.
///
/// A memoryless waveshaper fed a loud tone near the top of the band emits
/// harmonics above Nyquist, and those fold back to frequencies unrelated to
/// anything in the music — the one distortion product no downstream filter
/// can undo. 11 kHz at 48 kHz is the clean test case: the 3rd harmonic
/// (33 kHz) folds to 15 kHz and the 5th (55 kHz) to 7 kHz, both far from the
/// fundamental and from each other, so each alias can be weighed on its own.
final class AntiAliasingTests: XCTestCase {

    private let rate = 48000.0
    private let fftSize = 8192

    // MARK: Helpers

    /// One channel of the clipper, sample by sample, the way the render loop
    /// runs it: `adaa` false is the old memoryless path.
    private func clip(_ input: [Float], adaa: Bool) -> [Float] {
        let p = StageProcessor()
        var out = [Float](repeating: 0, count: input.count)
        var prev: Float = 0
        for i in 0..<input.count {
            out[i] = adaa ? p.softClipADAA(input[i], prev: prev) : p.softClip(input[i])
            prev = input[i]
        }
        return out
    }

    private func sine(hz: Double, amplitude: Float, count: Int) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }

    /// Hann-windowed power spectrum. The window matters: an 11 kHz tone is
    /// not bin-centred at this length, and a rectangular window's leakage
    /// would smear the fundamental across the alias bands being measured.
    private func powerSpectrum(_ samples: [Float]) -> [Float] {
        let n = fftSize
        let log2n = vDSP_Length(13)
        guard samples.count >= n,
              let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var windowed = [Float](repeating: 0, count: n)
        samples.withUnsafeBufferPointer { s in
            vDSP_vmul(s.baseAddress!, 1, window, 1, &windowed, 1, vDSP_Length(n))
        }

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBufferPointer { raw in
                    raw.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                       capacity: n / 2) { p in
                        vDSP_ctoz(p, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        return mags
    }

    /// Energy in a narrow band around `hz`, in dB. ±40 Hz is a handful of
    /// bins — wide enough to hold a Hann main lobe whatever the alias lands
    /// between, narrow enough that no other product leaks in.
    private func bandEnergyDb(_ spectrum: [Float], around hz: Double) -> Double {
        let binHz = rate / Double(fftSize)
        var sum = 0.0
        for bin in 0..<spectrum.count where abs(Double(bin) * binHz - hz) <= 40 {
            sum += Double(spectrum[bin])
        }
        return 10 * log10(max(sum, 1e-30))
    }

    // MARK: Tests

    /// The point of the exercise: both fold-back products must drop hard.
    /// 10 dB is a floor, not the expectation — the measured reduction is
    /// well past it, and a threshold set at the measurement would fail on
    /// the first harmless change to the curve.
    func testADAASuppressesFoldedHarmonics() {
        let input = sine(hz: 11000, amplitude: 0.9, count: fftSize)
        let oldSpectrum = powerSpectrum(clip(input, adaa: false))
        let newSpectrum = powerSpectrum(clip(input, adaa: true))
        XCTAssertFalse(oldSpectrum.isEmpty)
        XCTAssertFalse(newSpectrum.isEmpty)

        for alias in [15000.0, 7000.0] {
            let before = bandEnergyDb(oldSpectrum, around: alias)
            let after = bandEnergyDb(newSpectrum, around: alias)
            XCTAssertGreaterThanOrEqual(
                before - after, 10,
                "alias at \(Int(alias)) Hz: \(before) dB → \(after) dB")
        }
    }

    /// The fix is an anti-aliasing measure, not a new curve. Where the
    /// signal moves slowly there is nothing above Nyquist to fold, and the
    /// segment average must land on the memoryless shaper's own answer.
    func testADAAMatchesTheCurveOnSlowSignals() {
        let input = sine(hz: 100, amplitude: 0.5, count: 4800)
        let direct = clip(input, adaa: false)
        let antiAliased = clip(input, adaa: true)
        for i in 0..<input.count {
            XCTAssertEqual(antiAliased[i], direct[i], accuracy: 0.02)
        }
    }

    /// The difference quotient's denominator vanishes on a held signal.
    /// Every one of these would be 0/0 without the midpoint fallback.
    func testHeldSignalStaysFinite() {
        let p = StageProcessor()
        for held in [Float(0), 0.25, 0.9, 1.5, 3, 12, -0.25, -0.9, -3, -12] {
            let y = p.softClipADAA(held, prev: held)
            XCTAssertTrue(y.isFinite, "held \(held) produced \(y)")
            // A held input is a DC segment; the shaper's own value is the
            // only defensible answer, and the fallback must return it.
            XCTAssertEqual(y, p.softClip(held), accuracy: 1e-6)
        }
    }
}
