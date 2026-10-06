import Accelerate
import XCTest
@testable import QudelixBar

final class AntiAliasingTests: XCTestCase {
    private let rate = 48000.0
    private let fftSize = 8192

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

    private func bandEnergyDb(_ spectrum: [Float], around hz: Double) -> Double {
        let binHz = rate / Double(fftSize)
        var sum = 0.0
        for bin in 0..<spectrum.count where abs(Double(bin) * binHz - hz) <= 40 {
            sum += Double(spectrum[bin])
        }
        return 10 * log10(max(sum, 1e-30))
    }

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

    func testADAAMatchesTheCurveOnSlowSignals() {
        let input = sine(hz: 100, amplitude: 0.5, count: 4800)
        let direct = clip(input, adaa: false)
        let antiAliased = clip(input, adaa: true)
        for i in 0..<input.count {
            XCTAssertEqual(antiAliased[i], direct[i], accuracy: 0.02)
        }
    }

    func testHeldSignalStaysFinite() {
        let p = StageProcessor()
        for held in [Float(0), 0.25, 0.9, 1.5, 3, 12, -0.25, -0.9, -3, -12] {
            let y = p.softClipADAA(held, prev: held)
            XCTAssertTrue(y.isFinite, "held \(held) produced \(y)")
            XCTAssertEqual(y, p.softClip(held), accuracy: 1e-6)
        }
    }
}
