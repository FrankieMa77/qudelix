import Foundation

protocol PackedRealFFT: AnyObject {
    var length: Int { get }

    func forward(time: UnsafePointer<Float>,
                 real: UnsafeMutablePointer<Float>,
                 imag: UnsafeMutablePointer<Float>)

    func inverse(real: UnsafeMutablePointer<Float>,
                 imag: UnsafeMutablePointer<Float>,
                 time: UnsafeMutablePointer<Float>)
}

final class PortableRealFFT: PackedRealFFT {
    let length: Int
    private let half: Int
    private let reversed: [Int]
    private let twiddleCos: [Float]
    private let twiddleSin: [Float]
    private let splitCos: [Float]
    private let splitSin: [Float]
    private let zr: UnsafeMutablePointer<Float>
    private let zi: UnsafeMutablePointer<Float>

    static func supports(length: Int) -> Bool {
        length >= 4 && length & (length - 1) == 0
    }

    init?(length: Int) {
        guard Self.supports(length: length) else { return nil }
        self.length = length
        let m = length / 2
        half = m
        var bits = 0
        while 1 << bits < m { bits += 1 }
        reversed = (0..<m).map { index in
            var value = index
            var out = 0
            for _ in 0..<bits {
                out = (out << 1) | (value & 1)
                value >>= 1
            }
            return out
        }
        let tableSize = max(1, m / 2)
        twiddleCos = (0..<tableSize).map { Float(cos(2 * Double.pi * Double($0) / Double(m))) }
        twiddleSin = (0..<tableSize).map { Float(sin(2 * Double.pi * Double($0) / Double(m))) }
        splitCos = (0..<m).map { Float(cos(2 * Double.pi * Double($0) / Double(length))) }
        splitSin = (0..<m).map { Float(sin(2 * Double.pi * Double($0) / Double(length))) }
        zr = UnsafeMutablePointer<Float>.allocate(capacity: m)
        zi = UnsafeMutablePointer<Float>.allocate(capacity: m)
        zr.initialize(repeating: 0, count: m)
        zi.initialize(repeating: 0, count: m)
    }

    deinit {
        zr.deallocate()
        zi.deallocate()
    }

    private func transform(sign: Float) {
        let m = half
        for i in 0..<m {
            let j = reversed[i]
            if j > i {
                let tr = zr[i], ti = zi[i]
                zr[i] = zr[j]; zi[i] = zi[j]
                zr[j] = tr; zi[j] = ti
            }
        }
        var size = 2
        while size <= m {
            let h = size / 2
            let step = m / size
            var start = 0
            while start < m {
                for k in 0..<h {
                    let index = k * step
                    let wr = twiddleCos[index]
                    let wi = -sign * twiddleSin[index]
                    let a = start + k
                    let b = a + h
                    let xr = zr[b] * wr - zi[b] * wi
                    let xi = zr[b] * wi + zi[b] * wr
                    zr[b] = zr[a] - xr
                    zi[b] = zi[a] - xi
                    zr[a] += xr
                    zi[a] += xi
                }
                start += size
            }
            size <<= 1
        }
    }

    func forward(time: UnsafePointer<Float>,
                 real: UnsafeMutablePointer<Float>,
                 imag: UnsafeMutablePointer<Float>) {
        let m = half
        for n in 0..<m {
            zr[n] = time[2 * n]
            zi[n] = time[2 * n + 1]
        }
        transform(sign: 1)
        real[0] = 2 * (zr[0] + zi[0])
        imag[0] = 2 * (zr[0] - zi[0])
        for k in 1..<m {
            let a = zr[k], b = zi[k]
            let c = zr[m - k], d = zi[m - k]
            let er = (a + c) * 0.5, ei = (b - d) * 0.5
            let or = (b + d) * 0.5, oi = -(a - c) * 0.5
            let wr = splitCos[k], wi = -splitSin[k]
            real[k] = 2 * (er + wr * or - wi * oi)
            imag[k] = 2 * (ei + wr * oi + wi * or)
        }
    }

    func inverse(real: UnsafeMutablePointer<Float>,
                 imag: UnsafeMutablePointer<Float>,
                 time: UnsafeMutablePointer<Float>) {
        let m = half
        let dc = real[0], nyquist = imag[0]
        zr[0] = (dc + nyquist) * 0.5
        zi[0] = (dc - nyquist) * 0.5
        for k in 1..<m {
            let xr = real[k], xi = imag[k]
            let yr = real[m - k], yi = -imag[m - k]
            let er = (xr + yr) * 0.5, ei = (xi + yi) * 0.5
            let dr = (xr - yr) * 0.5, di = (xi - yi) * 0.5
            let wr = splitCos[k], wi = splitSin[k]
            let or = dr * wr - di * wi
            let oi = dr * wi + di * wr
            zr[k] = er - oi
            zi[k] = ei + or
        }
        transform(sign: -1)
        for n in 0..<m {
            time[2 * n] = 2 * zr[n]
            time[2 * n + 1] = 2 * zi[n]
        }
    }
}

enum RealFFTFactory {
    static func make(length: Int) -> PackedRealFFT? {
        #if canImport(Accelerate)
        if let fft = AccelerateRealFFT(length: length) { return fft }
        return nil
        #else
        return PortableRealFFT(length: length)
        #endif
    }
}

protocol SpectrumKernel: AnyObject {
    var size: Int { get }
    func hannWindow() -> [Float]
    func multiply(_ a: [Float], _ b: [Float], into out: inout [Float])
    func powerSpectrum(of windowed: [Float], into magnitudes: inout [Float])
    func clamp(_ values: inout [Float], floor: Float)
    func sum(_ values: [Float]) -> Float
    func add(_ accumulator: inout [Float], _ values: [Float])
    func decibels(_ power: [Float], into db: inout [Float])
    func maximum(_ accumulator: inout [Float], _ values: [Float])
    func clear(_ values: inout [Float])
}

extension SpectrumKernel {
    func hannWindow() -> [Float] {
        let n = Double(size)
        let norm = (8.0 / 3.0).squareRoot()
        return (0..<size).map { Float(norm * 0.5 * (1 - cos(2 * Double.pi * Double($0) / n))) }
    }

    func multiply(_ a: [Float], _ b: [Float], into out: inout [Float]) {
        for i in 0..<min(a.count, b.count, out.count) { out[i] = a[i] * b[i] }
    }

    func clamp(_ values: inout [Float], floor: Float) {
        for i in values.indices where !(values[i] >= floor) { values[i] = floor }
    }

    func sum(_ values: [Float]) -> Float {
        var total: Float = 0
        for v in values { total += v }
        return total
    }

    func add(_ accumulator: inout [Float], _ values: [Float]) {
        for i in 0..<min(accumulator.count, values.count) { accumulator[i] += values[i] }
    }

    func decibels(_ power: [Float], into db: inout [Float]) {
        for i in 0..<min(power.count, db.count) { db[i] = 10 * log10(power[i]) }
    }

    func maximum(_ accumulator: inout [Float], _ values: [Float]) {
        for i in 0..<min(accumulator.count, values.count) {
            accumulator[i] = accumulator[i] > values[i] ? accumulator[i] : values[i]
        }
    }

    func clear(_ values: inout [Float]) {
        for i in values.indices { values[i] = 0 }
    }
}

final class PortableSpectrumKernel: SpectrumKernel {
    let size: Int
    private let fft: PortableRealFFT
    private var real: [Float]
    private var imag: [Float]

    init?(size: Int) {
        guard let fft = PortableRealFFT(length: size) else { return nil }
        self.size = size
        self.fft = fft
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
    }

    func powerSpectrum(of windowed: [Float], into magnitudes: inout [Float]) {
        windowed.withUnsafeBufferPointer { time in
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { i in
                    fft.forward(time: time.baseAddress!, real: r.baseAddress!,
                                imag: i.baseAddress!)
                }
            }
        }
        for k in 0..<(size / 2) { magnitudes[k] = real[k] * real[k] + imag[k] * imag[k] }
    }
}

enum SpectrumKernels {
    static func make(size: Int) -> SpectrumKernel {
        #if canImport(Accelerate)
        if let kernel = AccelerateSpectrumKernel(size: size) { return kernel }
        #endif
        return PortableSpectrumKernel(size: size)!
    }
}
