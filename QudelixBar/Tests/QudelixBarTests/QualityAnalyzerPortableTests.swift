import XCTest
@testable import QudelixBar

final class QualityAnalyzerPortableTests: XCTestCase {
    private func analyzer() -> QualityAnalyzer {
        QualityAnalyzer(kernel: PortableSpectrumKernel(size: QualityAnalyzer.fftSize)!)
    }

    private func verdict(_ signal: [Float], rate: Double) -> QualityAnalyzer.Verdict? {
        let a = analyzer()
        for w in SyntheticSpectra.windows(signal) { a.feed(w) }
        return a.classify(sampleRate: rate)
    }

    func testABrickwallAtSixteenKilohertzReadsAsLossy() {
        let signal = SyntheticSpectra.lowpassed(cutoffHz: 16000, rate: 44100, seed: 11)
        guard case .lossy(let cutoff)? = verdict(signal, rate: 44100) else {
            return XCTFail("expected lossy")
        }
        XCTAssertEqual(cutoff, 16, accuracy: 1)
    }

    func testSilenceIsTooQuiet() {
        let signal = [Float](repeating: 0, count: 1 << 16)
        XCTAssertEqual(verdict(signal, rate: 48000), .tooQuiet)
    }

    func testAFullBandSignalAtNinetySixKilohertzReachesHiRes() {
        let signal = SyntheticSpectra.lowpassed(cutoffHz: 47000, rate: 96000, seed: 12)
        guard case .hiRes? = verdict(signal, rate: 96000) else {
            return XCTFail("expected hi-res")
        }
    }

    func testAnImplausibleRateGivesNoVerdict() {
        let a = analyzer()
        for w in SyntheticSpectra.windows(SyntheticSpectra.lowpassed(cutoffHz: 16000,
                                                                       rate: 44100, seed: 13)) {
            a.feed(w)
        }
        XCTAssertNil(a.classify(sampleRate: 100))
        XCTAssertNil(a.balance(sampleRate: .nan))
    }

    func testBalanceTiltFollowsTheSpectralSlope() throws {
        let steep = SyntheticSpectra.tilted(slopeDbPerOctave: -3, rate: 48000, seed: 21)
        let flat = SyntheticSpectra.tilted(slopeDbPerOctave: 0, rate: 48000, seed: 22)
        let a = analyzer()
        for w in SyntheticSpectra.windows(steep) { a.feed(w) }
        let steepReading = try XCTUnwrap(a.balance(sampleRate: 48000))
        for w in SyntheticSpectra.windows(flat) { a.feed(w) }
        let flatReading = try XCTUnwrap(a.balance(sampleRate: 48000))
        XCTAssertEqual(steepReading.tiltDbPerOctave - flatReading.tiltDbPerOctave, -3,
                       accuracy: 0.6)
    }

    func testBalanceGivesNothingBelowTheGate() {
        let quiet = SyntheticSpectra.noise(length: 1 << 15, rate: 48000, seed: 5, rms: 1e-6) { _ in 1 }
        let a = analyzer()
        for w in SyntheticSpectra.windows(quiet) { a.feed(w) }
        XCTAssertNil(a.balance(sampleRate: 48000))
    }

    func testVerdictHelpers() {
        XCTAssertEqual(QualityAnalyzer.Verdict.lossy(cutoffKHz: 16).isLosslessClass, false)
        XCTAssertEqual(QualityAnalyzer.Verdict.lossyHigh(cutoffKHz: 19).isLosslessClass, false)
        XCTAssertNil(QualityAnalyzer.Verdict.lossyHigh(cutoffKHz: 20).isLosslessClass)
        XCTAssertEqual(QualityAnalyzer.Verdict.hiRes(cutoffKHz: 30).isLosslessClass, true)
        XCTAssertNil(QualityAnalyzer.Verdict.natural(cutoffKHz: 18).isLosslessClass)
        XCTAssertEqual(QualityAnalyzer.Verdict.tooQuiet.kind, 0)
        XCTAssertEqual(QualityAnalyzer.Verdict.natural(cutoffKHz: 1).kind, 6)
    }

    func testPlausibleRateBounds() {
        XCTAssertTrue(AudioOutputs.isPlausibleRate(44100))
        XCTAssertFalse(AudioOutputs.isPlausibleRate(7999))
        XCTAssertFalse(AudioOutputs.isPlausibleRate(768_001))
        XCTAssertFalse(AudioOutputs.isPlausibleRate(.infinity))
        XCTAssertEqual(AudioOutputs.plausibleRate(.nan), AudioOutputs.fallbackRate)
        XCTAssertEqual(AudioOutputs.plausibleRate(96000), 96000)
    }
}
