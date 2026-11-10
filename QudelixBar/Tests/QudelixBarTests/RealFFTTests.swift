import XCTest
@testable import QudelixBar

final class RealFFTTests: XCTestCase {
    private struct Lcg {
        var state: UInt64

        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state)) / Float(Int64.max)
        }
    }

    private func naive(_ x: [Float]) -> (re: [Double], im: [Double]) {
        let n = x.count
        var re = [Double](repeating: 0, count: n / 2 + 1)
        var im = [Double](repeating: 0, count: n / 2 + 1)
        for k in 0...(n / 2) {
            var r = 0.0, i = 0.0
            for t in 0..<n {
                let angle = -2 * Double.pi * Double((k * t) % n) / Double(n)
                r += Double(x[t]) * cos(angle)
                i += Double(x[t]) * sin(angle)
            }
            re[k] = 2 * r
            im[k] = 2 * i
        }
        return (re, im)
    }

    private func signal(_ n: Int, seed: UInt64) -> [Float] {
        var rng = Lcg(state: seed)
        return (0..<n).map { _ in rng.next() }
    }

    private func forward(_ fft: PackedRealFFT, _ x: [Float]) -> (re: [Float], im: [Float]) {
        var re = [Float](repeating: 0, count: x.count / 2)
        var im = [Float](repeating: 0, count: x.count / 2)
        x.withUnsafeBufferPointer { t in
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    fft.forward(time: t.baseAddress!, real: r.baseAddress!, imag: i.baseAddress!)
                }
            }
        }
        return (re, im)
    }

    func testForwardMatchesTheNaiveTransformAtEverySize() throws {
        for n in [4, 8, 16, 64, 256, 1024] {
            let fft = try XCTUnwrap(PortableRealFFT(length: n))
            let x = signal(n, seed: UInt64(n) &* 0x9E37_79B9_7F4A_7C15)
            let got = forward(fft, x)
            let want = naive(x)
            var peak = 0.0
            for k in 0...(n / 2) { peak = max(peak, abs(want.re[k]), abs(want.im[k])) }
            for k in 1..<(n / 2) {
                XCTAssertEqual(Double(got.re[k]), want.re[k], accuracy: peak * 1e-4,
                               "n=\(n) bin \(k) real")
                XCTAssertEqual(Double(got.im[k]), want.im[k], accuracy: peak * 1e-4,
                               "n=\(n) bin \(k) imag")
            }
            XCTAssertEqual(Double(got.re[0]), want.re[0], accuracy: peak * 1e-4)
            XCTAssertEqual(Double(got.im[0]), want.re[n / 2], accuracy: peak * 1e-4)
        }
    }

    func testInverseUndoesForwardWithTheDocumentedGain() throws {
        for n in [4, 32, 512, 8192] {
            let fft = try XCTUnwrap(PortableRealFFT(length: n))
            let x = signal(n, seed: 0xD1B5_4A32_D192_ED03 &+ UInt64(n))
            var spectrum = forward(fft, x)
            var back = [Float](repeating: 0, count: n)
            spectrum.re.withUnsafeMutableBufferPointer { r in
                spectrum.im.withUnsafeMutableBufferPointer { i in
                    back.withUnsafeMutableBufferPointer { t in
                        fft.inverse(real: r.baseAddress!, imag: i.baseAddress!,
                                    time: t.baseAddress!)
                    }
                }
            }
            for i in 0..<n {
                XCTAssertEqual(back[i] / Float(2 * n), x[i], accuracy: 1e-4, "n=\(n) sample \(i)")
            }
        }
    }

    func testAPureToneLandsInItsBin() throws {
        let n = 1024
        let fft = try XCTUnwrap(PortableRealFFT(length: n))
        let bin = 37
        let x = (0..<n).map { Float(sin(2 * Double.pi * Double(bin * $0) / Double(n))) }
        let got = forward(fft, x)
        var best = 1
        var bestPower: Float = 0
        for k in 1..<(n / 2) {
            let power = got.re[k] * got.re[k] + got.im[k] * got.im[k]
            if power > bestPower { bestPower = power; best = k }
        }
        XCTAssertEqual(best, bin)
    }

    func testUnsupportedLengthsAreRefused() {
        XCTAssertNil(PortableRealFFT(length: 0))
        XCTAssertNil(PortableRealFFT(length: 2))
        XCTAssertNil(PortableRealFFT(length: 12))
        XCTAssertNil(PortableRealFFT(length: 1000))
        XCTAssertNotNil(PortableRealFFT(length: 4))
    }

    func testTheFactoryHandsBackAWorkingTransform() throws {
        let fft = try XCTUnwrap(RealFFTFactory.make(length: 256))
        XCTAssertEqual(fft.length, 256)
        let x = signal(256, seed: 7)
        let got = forward(fft, x)
        let want = naive(x)
        var peak = 0.0
        for k in 0...128 { peak = max(peak, abs(want.re[k]), abs(want.im[k])) }
        for k in 1..<128 {
            XCTAssertEqual(Double(got.re[k]), want.re[k], accuracy: peak * 1e-4)
        }
    }

    func testThePortableWindowIsAHannShapeWithUnitMeanSquare() {
        let kernel = PortableSpectrumKernel(size: 8192)!
        let w = kernel.hannWindow()
        XCTAssertEqual(w.count, 8192)
        XCTAssertEqual(w[0], 0, accuracy: 1e-6)
        XCTAssertEqual(w[4096], Float((8.0 / 3.0).squareRoot()), accuracy: 1e-5)
        let meanSquare = w.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(w.count)
        XCTAssertEqual(meanSquare, 1, accuracy: 1e-3)
    }
}
