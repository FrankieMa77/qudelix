import Accelerate
import XCTest
@testable import QudelixBar

final class QualityAnalyzerBalanceTests: XCTestCase {
    private static let rate = 48000.0
    private static let log2n = vDSP_Length(22)
    private static let length = 1 << 22
    private static let window = QualityAnalyzer.fftSize
    private static let windowsPerReading = 30
    private static let readings = 10
    private static let seeds: [UInt64] = [0x2545_F491_4F6C_DD1D, 0x9E37_79B9_7F4A_7C15,
                                          0xD1B5_4A32_D192_ED03]

    private struct Lcg {
        var state: UInt64

        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int64(bitPattern: state)) / Double(Int64.max)
        }
    }

    private func signal(seed: UInt64, shape: (Double) -> Double) -> [Float] {
        let n = Self.length
        var lcg = Lcg(state: seed)
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        for b in 1..<(n / 2) {
            let amp = shape(Double(b) * Self.rate / Double(n))
            real[b] = Float(lcg.next() * amp)
            imag[b] = Float(lcg.next() * amp)
        }
        var out = [Float](repeating: 0, count: n)
        let setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_INVERSE))
                out.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                              vDSP_Length(n / 2))
                }
            }
        }
        var rms: Float = 0
        vDSP_rmsqv(out, 1, &rms, vDSP_Length(n))
        var scale = 0.1 / max(rms, 1e-20)
        vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(n))
        return out
    }

    private func pink(_ f: Double) -> Double { 1 / f.squareRoot() }

    private func shaped(_ band: QxEqBandValue) -> (Double) -> Double {
        guard let filter = EQCurve.BandFilter(band: band) else { return pink }
        return { f in
            let phase = EQCurve.Phase(radians: 2 * .pi * f / Self.rate)
            return self.pink(f) * pow(10, filter.gainDb(at: phase) / 20)
        }
    }

    private func measure(seed: UInt64, shape: @escaping (Double) -> Double)
        -> (bass: Double, tilt: Double, presence: Double) {
        let samples = signal(seed: seed, shape: shape)
        let analyzer = QualityAnalyzer()
        var bass = 0.0, tilt = 0.0, presence = 0.0
        var offset = 0
        for _ in 0..<Self.readings {
            for _ in 0..<Self.windowsPerReading {
                analyzer.feed(Array(samples[offset..<(offset + Self.window)]))
                offset += Self.window
            }
            guard let reading = analyzer.balance(sampleRate: Self.rate) else {
                XCTFail("no reading")
                return (0, 0, 0)
            }
            bass += reading.bassDb
            tilt += reading.tiltDbPerOctave
            presence += reading.presenceDb
        }
        let n = Double(Self.readings)
        return (bass / n, tilt / n, presence / n)
    }

    func testPinkNoiseReadsFlat() {
        for seed in Self.seeds {
            let m = measure(seed: seed, shape: pink)
            XCTAssertEqual(m.bass, 0, accuracy: 0.4, "bass seed \(seed)")
            XCTAssertEqual(m.tilt, 0, accuracy: 0.25, "tilt seed \(seed)")
            XCTAssertEqual(m.presence, 0, accuracy: 0.4, "presence seed \(seed)")
        }
    }

    func testWhiteNoiseTiltsThreeDbPerOctave() {
        for seed in Self.seeds {
            let m = measure(seed: seed, shape: { _ in 1 })
            XCTAssertEqual(m.tilt, 3, accuracy: 0.25, "seed \(seed)")
        }
    }

    func testLowShelfBoostShowsInBass() {
        let shelf = QxEqBandValue(filter: .lowShelf, freq: 100, gain: 9, q: 0.71)
        for seed in Self.seeds {
            let m = measure(seed: seed, shape: shaped(shelf))
            XCTAssertEqual(m.bass, 3.12, accuracy: 0.5, "seed \(seed)")
        }
    }

    func testHighPassCutsBass() {
        let shape: (Double) -> Double = { f in
            self.pink(f) * pow(f, 4) / (pow(f, 8) + pow(300, 8)).squareRoot()
        }
        for seed in Self.seeds {
            let m = measure(seed: seed, shape: shape)
            XCTAssertLessThan(m.bass, -6, "seed \(seed)")
        }
    }

    func testPresencePeakShowsInPresence() {
        let peak = QxEqBandValue(filter: .peak, freq: 3000, gain: 4, q: 1)
        for seed in Self.seeds {
            let m = measure(seed: seed, shape: shaped(peak))
            XCTAssertEqual(m.presence, 1.65, accuracy: 0.35, "seed \(seed)")
        }
    }

    func testSilenceReadsNil() {
        let analyzer = QualityAnalyzer()
        for _ in 0..<3 {
            analyzer.feed([Float](repeating: 0, count: QualityAnalyzer.fftSize))
        }
        XCTAssertNil(analyzer.balance(sampleRate: Self.rate))
    }

    func testNothingFedReadsNil() {
        XCTAssertNil(QualityAnalyzer().balance(sampleRate: Self.rate))
    }

    func testImplausibleRateReadsNil() {
        let samples = signal(seed: Self.seeds[0], shape: pink)
        let analyzer = QualityAnalyzer()
        analyzer.feed(Array(samples[0..<Self.window]))
        XCTAssertNil(analyzer.balance(sampleRate: 0))
        analyzer.feed(Array(samples[0..<Self.window]))
        XCTAssertNil(analyzer.balance(sampleRate: .nan))
    }

    func testReadingConsumesTheAccumulator() {
        let samples = signal(seed: Self.seeds[0], shape: pink)
        let analyzer = QualityAnalyzer()
        for w in 0..<3 { analyzer.feed(Array(samples[(w * Self.window)..<((w + 1) * Self.window)])) }
        XCTAssertNotNil(analyzer.balance(sampleRate: Self.rate))
        XCTAssertNil(analyzer.balance(sampleRate: Self.rate))
    }

    func testResetDropsTheAccumulator() {
        let samples = signal(seed: Self.seeds[0], shape: pink)
        let analyzer = QualityAnalyzer()
        for w in 0..<3 { analyzer.feed(Array(samples[(w * Self.window)..<((w + 1) * Self.window)])) }
        analyzer.reset()
        XCTAssertNil(analyzer.balance(sampleRate: Self.rate))
    }

    func testClassifyDoesNotConsumeTheBalanceAccumulator() {
        let samples = signal(seed: Self.seeds[0], shape: pink)
        let analyzer = QualityAnalyzer()
        for w in 0..<3 { analyzer.feed(Array(samples[(w * Self.window)..<((w + 1) * Self.window)])) }
        _ = analyzer.classify(sampleRate: Self.rate)
        XCTAssertNotNil(analyzer.balance(sampleRate: Self.rate))
    }

    func testBrickwallStillClassifiesAsLossy() throws {
        let shape: (Double) -> Double = { f in f > 16000 ? 0 : self.pink(f) }
        let samples = signal(seed: Self.seeds[0], shape: shape)
        let analyzer = QualityAnalyzer()
        for w in 0..<3 { analyzer.feed(Array(samples[(w * Self.window)..<((w + 1) * Self.window)])) }
        guard case .lossy(let kHz)? = analyzer.classify(sampleRate: Self.rate) else {
            return XCTFail("16 kHz brickwall should read lossy")
        }
        XCTAssertEqual(kHz, 16.4, accuracy: 0.8)
    }
}
