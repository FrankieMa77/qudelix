import Foundation
@testable import QudelixBar

enum SyntheticSpectra {
    static func noise(length: Int, rate: Double, seed: UInt64, rms: Float = 0.1,
                      magnitude: (Double) -> Double) -> [Float] {
        let fft = PortableRealFFT(length: length)!
        var state = seed
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        let half = length / 2
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        for k in 1..<half {
            let hz = Double(k) * rate / Double(length)
            let m = magnitude(hz)
            let phase = 2 * Double.pi * next()
            re[k] = Float(m * cos(phase))
            im[k] = Float(m * sin(phase))
        }
        var time = [Float](repeating: 0, count: length)
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                time.withUnsafeMutableBufferPointer { t in
                    fft.inverse(real: r.baseAddress!, imag: i.baseAddress!, time: t.baseAddress!)
                }
            }
        }
        let power = time.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(length)
        let scale = power > 0 ? Float(Double(rms) / power.squareRoot()) : 0
        return time.map { $0 * scale }
    }

    static func lowpassed(cutoffHz: Double, rate: Double, length: Int = 1 << 16,
                          seed: UInt64) -> [Float] {
        noise(length: length, rate: rate, seed: seed) { $0 <= cutoffHz ? 1 : 1e-6 }
    }

    static func tilted(slopeDbPerOctave: Double, rate: Double, length: Int = 1 << 16,
                       seed: UInt64) -> [Float] {
        noise(length: length, rate: rate, seed: seed) { hz in
            pow(10, slopeDbPerOctave * log2(max(hz, 20) / 1000) / 20)
        }
    }

    static func windows(_ signal: [Float]) -> [[Float]] {
        let n = QualityAnalyzer.fftSize
        return stride(from: 0, through: signal.count - n, by: n).map {
            Array(signal[$0..<($0 + n)])
        }
    }
}
