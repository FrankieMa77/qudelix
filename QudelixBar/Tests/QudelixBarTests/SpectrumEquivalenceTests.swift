import Accelerate
import XCTest
@testable import QudelixBar

final class SpectrumEquivalenceTests: XCTestCase {
    private func pair() -> (vdsp: QualityAnalyzer, portable: QualityAnalyzer) {
        (QualityAnalyzer(kernel: AccelerateSpectrumKernel(size: QualityAnalyzer.fftSize)!),
         QualityAnalyzer(kernel: PortableSpectrumKernel(size: QualityAnalyzer.fftSize)!))
    }

    private func feedBoth(_ p: (vdsp: QualityAnalyzer, portable: QualityAnalyzer),
                          _ signal: [Float]) {
        for w in SyntheticSpectra.windows(signal) {
            p.vdsp.feed(w)
            p.portable.feed(w)
        }
    }

    private func cutoff(_ v: QualityAnalyzer.Verdict?) -> Double? {
        switch v {
        case .lossy(let k)?, .lossyHigh(let k)?, .losslessLike(let k)?, .hiRes(let k)?,
             .natural(let k)?: return k
        default: return nil
        }
    }

    func testTheTwoTransformsAgreeOnRandomInput() throws {
        for n in [64, 512, 8192] {
            let v = try XCTUnwrap(AccelerateRealFFT(length: n))
            let p = try XCTUnwrap(PortableRealFFT(length: n))
            let x = SyntheticSpectra.noise(length: n, rate: 48000, seed: UInt64(n)) { _ in 1 }
            var vr = [Float](repeating: 0, count: n / 2), vi = vr
            var pr = vr, pi = vr
            x.withUnsafeBufferPointer { t in
                v.forward(time: t.baseAddress!, real: &vr, imag: &vi)
                p.forward(time: t.baseAddress!, real: &pr, imag: &pi)
            }
            var peak: Float = 0
            for k in 0..<(n / 2) { peak = max(peak, abs(vr[k]), abs(vi[k])) }
            for k in 0..<(n / 2) {
                XCTAssertEqual(pr[k], vr[k], accuracy: peak * 1e-4, "n=\(n) real \(k)")
                XCTAssertEqual(pi[k], vi[k], accuracy: peak * 1e-4, "n=\(n) imag \(k)")
            }
            var vt = [Float](repeating: 0, count: n), pt = vt
            v.inverse(real: &vr, imag: &vi, time: &vt)
            p.inverse(real: &pr, imag: &pi, time: &pt)
            for i in 0..<n {
                XCTAssertEqual(pt[i], vt[i], accuracy: peak * 1e-3, "n=\(n) time \(i)")
            }
        }
    }

    func testBothKernelsGiveTheSameVerdictOnSyntheticSignals() {
        let cases: [(Double, Double)] = [(16000, 44100), (19000, 44100), (20500, 48000),
                                         (22000, 48000), (30000, 96000), (47000, 96000),
                                         (12000, 48000), (8000, 48000)]
        for (index, c) in cases.enumerated() {
            let signal = SyntheticSpectra.lowpassed(cutoffHz: c.0, rate: c.1,
                                                    seed: UInt64(100 + index))
            let p = pair()
            feedBoth(p, signal)
            let a = p.vdsp.classify(sampleRate: c.1)
            let b = p.portable.classify(sampleRate: c.1)
            XCTAssertNotNil(a)
            XCTAssertNotEqual(a?.kind, 0)
            if c.0 >= 16000 { XCTAssertNotEqual(a?.kind, 1) }
            XCTAssertEqual(a?.kind, b?.kind, "cutoff \(c.0) at \(c.1)")
            XCTAssertEqual(cutoff(a) ?? 0, cutoff(b) ?? 0, accuracy: 0.01)
        }
    }

    func testBothKernelsGiveTheSameVerdictForSilenceAndQuietSignals() {
        let p = pair()
        feedBoth(p, [Float](repeating: 0, count: 1 << 15))
        XCTAssertEqual(p.vdsp.classify(sampleRate: 48000), .tooQuiet)
        XCTAssertEqual(p.portable.classify(sampleRate: 48000), .tooQuiet)
    }

    func testBothKernelsGiveTheSameBalanceFeatures() throws {
        for (index, slope) in [-4.0, -2.0, 0, 1.5].enumerated() {
            let signal = SyntheticSpectra.tilted(slopeDbPerOctave: slope, rate: 48000,
                                                 seed: UInt64(300 + index))
            let p = pair()
            feedBoth(p, signal)
            let a = try XCTUnwrap(p.vdsp.balance(sampleRate: 48000))
            let b = try XCTUnwrap(p.portable.balance(sampleRate: 48000))
            XCTAssertEqual(a.bassDb, b.bassDb, accuracy: 0.01)
            XCTAssertEqual(a.tiltDbPerOctave, b.tiltDbPerOctave, accuracy: 0.01)
            XCTAssertEqual(a.presenceDb, b.presenceDb, accuracy: 0.01)
        }
    }

    func testBothKernelsRefuseTheSameQuietBalance() {
        let quiet = SyntheticSpectra.noise(length: 1 << 15, rate: 48000, seed: 5,
                                           rms: 1e-6) { _ in 1 }
        let p = pair()
        feedBoth(p, quiet)
        XCTAssertNil(p.vdsp.balance(sampleRate: 48000))
        XCTAssertNil(p.portable.balance(sampleRate: 48000))
    }
}
