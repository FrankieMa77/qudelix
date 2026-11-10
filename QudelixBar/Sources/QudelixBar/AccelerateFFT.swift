import Accelerate
import Foundation

final class AccelerateRealFFT: PackedRealFFT {
    let length: Int
    fileprivate let setup: FFTSetup
    fileprivate let log2n: vDSP_Length

    init?(length: Int) {
        guard PortableRealFFT.supports(length: length) else { return nil }
        let log2n = vDSP_Length(log2(Double(length)).rounded())
        guard let created = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        self.length = length
        self.log2n = log2n
        setup = created
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func forward(time: UnsafePointer<Float>,
                 real: UnsafeMutablePointer<Float>,
                 imag: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: real, imagp: imag)
        time.withMemoryRebound(to: DSPComplex.self, capacity: length / 2) { c in
            vDSP_ctoz(c, 2, &split, 1, vDSP_Length(length / 2))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
    }

    func inverse(real: UnsafeMutablePointer<Float>,
                 imag: UnsafeMutablePointer<Float>,
                 time: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: real, imagp: imag)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        time.withMemoryRebound(to: DSPComplex.self, capacity: length / 2) { c in
            vDSP_ztoc(&split, 1, c, 2, vDSP_Length(length / 2))
        }
    }
}

final class AccelerateSpectrumKernel: SpectrumKernel {
    let size: Int
    private let fft: AccelerateRealFFT
    private var real: [Float]
    private var imag: [Float]

    init?(size: Int) {
        guard let fft = AccelerateRealFFT(length: size) else { return nil }
        self.size = size
        self.fft = fft
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
    }

    func hannWindow() -> [Float] {
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        return window
    }

    func multiply(_ a: [Float], _ b: [Float], into out: inout [Float]) {
        vDSP_vmul(a, 1, b, 1, &out, 1, vDSP_Length(size))
    }

    func powerSpectrum(of windowed: [Float], into magnitudes: inout [Float]) {
        let half = size / 2
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                              &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(fft.setup, &split, 1, fft.log2n,
                              FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
    }

    func clamp(_ values: inout [Float], floor: Float) {
        var floorVal = floor
        vDSP_vthr(values, 1, &floorVal, &values, 1, vDSP_Length(size / 2))
    }

    func sum(_ values: [Float]) -> Float {
        var total: Float = 0
        vDSP_sve(values, 1, &total, vDSP_Length(size / 2))
        return total
    }

    func add(_ accumulator: inout [Float], _ values: [Float]) {
        vDSP_vadd(accumulator, 1, values, 1, &accumulator, 1, vDSP_Length(size / 2))
    }

    func decibels(_ power: [Float], into db: inout [Float]) {
        var one: Float = 1
        vDSP_vdbcon(power, 1, &one, &db, 1, vDSP_Length(size / 2), 0)
    }

    func maximum(_ accumulator: inout [Float], _ values: [Float]) {
        vDSP_vmax(accumulator, 1, values, 1, &accumulator, 1, vDSP_Length(size / 2))
    }

    func clear(_ values: inout [Float]) {
        vDSP_vclr(&values, 1, vDSP_Length(size / 2))
    }
}
