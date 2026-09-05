import Accelerate
import XCTest
@testable import QudelixBar

/// The classifier's verdict boundaries, tested against band-limited
/// BROADBAND noise built in the frequency domain — the classifier's
/// reference metrics assume broadband content (music), which sparse sine
/// combs defeat. Each case models a real source class.
final class QualityAnalyzerTests: XCTestCase {

    private var lcgState: UInt64 = 0x2545_F491_4F6C_DD1D

    /// White noise brickwalled (or gently sloped) above `cutoffHz`.
    private func bandlimitedNoise(cutoffHz: Double, rate: Double,
                                  gradualSlopeDbPerKHz: Double = 0) -> [Float] {
        let n = QualityAnalyzer.fftSize
        var noise = [Float](repeating: 0, count: n)
        for i in 0..<n {
            lcgState = lcgState &* 6364136223846793005 &+ 1442695040888963407
            // Full-width signed reinterpret: shifting first keeps only
            // positive bits and a whisper of signal (a bug this suite
            // exists to remember).
            noise[i] = Float(Int64(bitPattern: lcgState)) / Float(Int64.max) * 0.1
        }
        let log2n = vDSP_Length(13)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return noise }
        defer { vDSP_destroy_fftsetup(setup) }
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                noise.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                              &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                let cutoffBin = Int(cutoffHz / (rate / Double(n)))
                for b in 0..<(n / 2) where b >= cutoffBin {
                    if gradualSlopeDbPerKHz > 0 {
                        let kHzAbove = Double(b - cutoffBin) * (rate / Double(n)) / 1000
                        let g = Float(pow(10, -gradualSlopeDbPerKHz * kHzAbove / 20))
                        r.baseAddress![b] *= g
                        im.baseAddress![b] *= g
                    } else {
                        r.baseAddress![b] = 0
                        im.baseAddress![b] = 0
                    }
                }
                if cutoffBin < n / 2 { im.baseAddress![0] = 0 }  // packed Nyquist
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                var scale = Float(1.0 / Double(2 * n))
                vDSP_vsmul(r.baseAddress!, 1, &scale, r.baseAddress!, 1, vDSP_Length(n / 2))
                vDSP_vsmul(im.baseAddress!, 1, &scale, im.baseAddress!, 1, vDSP_Length(n / 2))
                noise.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                              vDSP_Length(n / 2))
                }
            }
        }
        return noise
    }

    private func verdict(cutoffHz: Double, rate: Double,
                         slope: Double = 0) -> QualityAnalyzer.Verdict? {
        let a = QualityAnalyzer()
        for _ in 0..<3 {
            a.feed(bandlimitedNoise(cutoffHz: cutoffHz, rate: rate,
                                    gradualSlopeDbPerKHz: slope))
        }
        return a.classify(sampleRate: rate)
    }

    func testLowBitrateCliffReadsLossy() throws {
        guard case .lossy = try XCTUnwrap(verdict(cutoffHz: 16000, rate: 44100))
        else { return XCTFail("16 kHz cliff should read lossy") }
    }

    func testHighBitrateCliffReadsLossyHigh() throws {
        guard case .lossyHigh = try XCTUnwrap(verdict(cutoffHz: 19800, rate: 44100))
        else { return XCTFail("19.8 kHz cliff should read lossy-high") }
    }

    func testSourceNyquistCliffAtHighDeviceRateReadsLossless() throws {
        // 44.1 lossless played at a 96 kHz device rate: its own legitimate
        // cliff sits at the source Nyquist and must NOT read as lossy.
        guard case .losslessLike = try XCTUnwrap(verdict(cutoffHz: 21500, rate: 96000))
        else { return XCTFail("source-Nyquist cliff should read lossless-like") }
    }

    func testFullBandContentReadsLossless() throws {
        guard case .losslessLike = try XCTUnwrap(verdict(cutoffHz: 21900, rate: 44100))
        else { return XCTFail("full-band 44.1 content should read lossless-like") }
    }

    func testUltrasonicContentReadsHiRes() throws {
        guard case .hiRes = try XCTUnwrap(verdict(cutoffHz: 30000, rate: 96000))
        else { return XCTFail("30 kHz content should read hi-res") }
    }

    func testShallowRolloffExtendsToLossless() throws {
        // Warm master, gentle slope: still audible at the top → nothing cut it.
        guard case .losslessLike = try XCTUnwrap(
            verdict(cutoffHz: 17000, rate: 44100, slope: 8))
        else { return XCTFail("shallow roll-off should read lossless-like") }
    }

    func testSteepRolloffAbstains() throws {
        guard case .natural = try XCTUnwrap(
            verdict(cutoffHz: 16000, rate: 44100, slope: 14))
        else { return XCTFail("steep natural roll-off should abstain") }
    }

    func testDarkMaterialIsNotAccusedOfBeingLossy() throws {
        // A 10 kHz edge is a quiet piano, not a codec.
        guard case .noTreble = try XCTUnwrap(verdict(cutoffHz: 10000, rate: 44100))
        else { return XCTFail("dark material should read no-treble") }
    }

    func testSilenceReadsTooQuiet() throws {
        let a = QualityAnalyzer()
        a.feed([Float](repeating: 0, count: QualityAnalyzer.fftSize))
        guard case .tooQuiet = try XCTUnwrap(a.classify(sampleRate: 44100))
        else { return XCTFail("silence should read too-quiet") }
    }

    func testBoundaryCliffCastsNoVote() {
        // The ambiguous 19.7–20.25 zone must not vote on rate switching —
        // the same physical cliff measures across the boundary at different
        // device rates, and a voting verdict ping-pongs the rate.
        XCTAssertNil(QualityAnalyzer.Verdict.lossyHigh(cutoffKHz: 20.1).isLosslessClass)
        XCTAssertEqual(QualityAnalyzer.Verdict.lossyHigh(cutoffKHz: 19.5).isLosslessClass, false)
        XCTAssertEqual(QualityAnalyzer.Verdict.losslessLike(cutoffKHz: 21.4).isLosslessClass, true)
    }

    func testResetDropsAccumulatedSpectra() {
        let a = QualityAnalyzer()
        a.feed(bandlimitedNoise(cutoffHz: 16000, rate: 44100))
        a.reset()
        XCTAssertNil(a.classify(sampleRate: 44100))
    }

    /// The counter alone was reset; the max-held levels stayed. The first
    /// window after a rate change was then max-held against peaks measured
    /// before it, so a 16 kHz-capped stream kept the old stream's treble and
    /// read lossless — the reset has to take the levels with it.
    func testResetDropsTheHeldLevelsAndNotJustTheCounter() throws {
        let a = QualityAnalyzer()
        for _ in 0..<3 { a.feed(bandlimitedNoise(cutoffHz: 21900, rate: 44100)) }
        _ = a.classify(sampleRate: 44100)
        a.reset()
        for _ in 0..<3 { a.feed(bandlimitedNoise(cutoffHz: 16000, rate: 44100)) }
        guard case .lossy = try XCTUnwrap(a.classify(sampleRate: 44100))
        else { return XCTFail("the previous stream's treble survived the reset") }
    }

    /// A driver supplies the rate. An infinity makes the top of the band
    /// infinite, and the 250 Hz cell scan that walks up to it never reaches
    /// its bound — on the main thread, which is the app hanging rather than
    /// misreporting.
    func testARateNoDeviceCouldRunAtIsRefusedRatherThanScanned() {
        for rate in [Double.infinity, .nan, 0, -44100, 1e12] {
            let a = QualityAnalyzer()
            a.feed(bandlimitedNoise(cutoffHz: 16000, rate: 44100))
            XCTAssertNil(a.classify(sampleRate: rate), "rate \(rate)")
        }
    }
}
