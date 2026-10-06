import Accelerate
import CoreAudio
import Foundation
import XCTest
@testable import QudelixBar

final class StageClipperKneeTests: XCTestCase {
    private static let knee = 0.6

    private static func padeClip(_ x: Double) -> Double {
        let c = min(max(x, -3), 3)
        return c * (27 + c * c) / (27 + 9 * c * c)
    }

    private static func padeAntiderivative(_ x: Double) -> Double {
        let kneeValue = 3.813_208_866_384_000_5
        if x > 3 { return kneeValue + (x - 3) }
        if x < -3 { return kneeValue - (x + 3) }
        return (x * x / 2 + 12 * log(x * x + 3)) / 9
    }

    private static func previousAveragingClipper(_ input: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: input.count)
        var prev = 0.0
        for i in 0..<input.count {
            let x = input[i]
            let dx = x - prev
            out[i] = abs(dx) < 1e-6
                ? padeClip((x + prev) / 2)
                : (padeAntiderivative(x) - padeAntiderivative(prev)) / dx
            prev = x
        }
        return out
    }

    private static func neutralStage() -> StageSettings {
        var s = StageSettings()
        s.enabled = true
        s.width = 100
        s.crossfeed = 0
        s.dialogue = 0
        s.room = 0
        s.distance = 0
        s.center = 0
        s.night = 0
        return s
    }

    private static func render(_ stage: StageSettings, mono: [Double],
                               rate: Double, block: Int? = nil) -> [Float] {
        let p = StageProcessor()
        p.prepare(sampleRate: rate)
        p.applyStage(stage)
        let step = block ?? mono.count
        var out = [Float]()
        out.reserveCapacity(mono.count)
        var start = 0
        while start < mono.count {
            let n = min(step, mono.count - start)
            let input = Buffers([(2, n)])
            input.fill(0, (0..<n * 2).map { Float(mono[start + $0 / 2]) })
            let output = Buffers([(2, n)])
            p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
            let samples = output.samples(0, count: n * 2)
            for f in 0..<n { out.append(samples[f * 2]) }
            start += n
        }
        return out
    }

    private static func sine(hz: Double, amplitude: Double, rate: Double,
                             count: Int) -> [Double] {
        (0..<count).map { amplitude * sin(2 * .pi * hz * Double($0) / rate) }
    }

    private static func tone(_ samples: [Double], hz: Double, rate: Double,
                             from: Int) -> Double {
        var re = 0.0, im = 0.0
        let w = 2 * Double.pi * hz / rate
        for n in from..<samples.count {
            re += samples[n] * cos(w * Double(n))
            im += samples[n] * sin(w * Double(n))
        }
        return 2 * (re * re + im * im).squareRoot() / Double(samples.count - from)
    }

    private static func gainDb(stage: StageSettings, hz: Double, rate: Double,
                               dbfs: Double) -> Double {
        let amplitude = pow(10, dbfs / 20)
        let count = Int(rate)
        let input = sine(hz: hz, amplitude: amplitude, rate: rate, count: count)
        let out = render(stage, mono: input, rate: rate).map(Double.init)
        let from = count / 2
        return 20 * log10(tone(out, hz: hz, rate: rate, from: from)
                          / tone(input, hz: hz, rate: rate, from: from))
    }

    private static func thdPercent(_ samples: [Double], hz: Double, rate: Double,
                                   from: Int) -> Double {
        let fundamental = tone(samples, hz: hz, rate: rate, from: from)
        var harmonics = 0.0
        for k in 2...9 where hz * Double(k) < rate / 2 {
            let h = tone(samples, hz: hz * Double(k), rate: rate, from: from)
            harmonics += h * h
        }
        return 100 * harmonics.squareRoot() / fundamental
    }

    private static func nonFundamentalDb(_ samples: [Double], hz: Double,
                                         rate: Double) -> Double {
        let n = 8192
        let log2n = vDSP_Length(13)
        let slice = Array(samples.suffix(n))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return 0 }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var windowed = (0..<n).map { Float(slice[$0]) * window[$0] }
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeMutableBufferPointer { raw in
                    raw.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                       capacity: n / 2) { p in
                        vDSP_ctoz(p, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        let binHz = rate / Double(n)
        var fundamental = 0.0
        var other = 0.0
        for bin in 1..<n / 2 {
            if abs(Double(bin) * binHz - hz) <= 4 * binHz {
                fundamental += Double(mags[bin])
            } else {
                other += Double(mags[bin])
            }
        }
        return 10 * log10(other / fundamental)
    }

    func testANeutralStageIsFlatToTwentyKilohertzAtFortyFourOne() {
        let rate = 44100.0
        for hz in [100.0, 1000, 5000, 8000, 10000, 12000, 14000, 16000, 18000, 20000] {
            let db = Self.gainDb(stage: Self.neutralStage(), hz: hz, rate: rate, dbfs: -20)
            XCTAssertEqual(db, 0, accuracy: 0.1, "\(Int(hz)) Hz at \(Int(rate)) Hz")
        }
    }

    func testANeutralStageIsFlatAtTheOtherCommonRates() {
        for rate in [48000.0, 96000.0] {
            for hz in [1000.0, 10000, 16000, 20000] {
                let db = Self.gainDb(stage: Self.neutralStage(), hz: hz, rate: rate, dbfs: -20)
                XCTAssertEqual(db, 0, accuracy: 0.1, "\(Int(hz)) Hz at \(Int(rate)) Hz")
            }
        }
    }

    func testTheDefaultStageNoLongerLosesTrebleToTheClipper() {
        var stage = Self.neutralStage()
        stage.distance = 0
        stage.width = 100
        let reference = Self.gainDb(stage: stage, hz: 1000, rate: 44100, dbfs: -20)
        let treble = Self.gainDb(stage: stage, hz: 16000, rate: 44100, dbfs: -20)
        XCTAssertEqual(treble - reference, 0, accuracy: 0.1,
                       "16 kHz used to read about 7.6 dB under 1 kHz")
    }

    func testTheNeutralStageDoesNotDistortAtMinusSix() {
        let rate = 48000.0
        let input = Self.sine(hz: 1000, amplitude: 0.5, rate: rate, count: 48000)
        let out = Self.render(Self.neutralStage(), mono: input, rate: rate).map(Double.init)
        let thd = Self.thdPercent(out, hz: 1000, rate: rate, from: 24000)

        let oldCurve = input.map { Self.padeClip($0) }
        let oldThd = Self.thdPercent(oldCurve, hz: 1000, rate: rate, from: 24000)

        print(String(format: "THD 1 kHz -6 dBFS neutral Stage: previous curve %.4f %%, now %.6f %%",
                     oldThd, thd))
        XCTAssertGreaterThan(oldThd, 1.5, "the previous curve measured 1.8 % here")
        XCTAssertLessThan(thd, 0.001, "below the knee the path is exactly linear")
        XCTAssertEqual(20 * log10(Self.tone(out, hz: 1000, rate: rate, from: 24000)
                                  / Self.tone(input, hz: 1000, rate: rate, from: 24000)),
                       0, accuracy: 0.001)
    }

    func testDistortionStaysSmallJustAboveTheKnee() {
        let rate = 48000.0
        var worst = 0.0
        for dbfs in [-3.0, -1.0, 0.0] {
            let input = Self.sine(hz: 1000, amplitude: pow(10, dbfs / 20), rate: rate,
                                  count: 48000)
            let out = Self.render(Self.neutralStage(), mono: input, rate: rate).map(Double.init)
            let thd = Self.thdPercent(out, hz: 1000, rate: rate, from: 24000)
            let old = Self.thdPercent(input.map { Self.padeClip($0) }, hz: 1000, rate: rate,
                                      from: 24000)
            XCTAssertLessThan(thd, old, "\(dbfs) dBFS: \(thd) % against \(old) %")
            worst = max(worst, thd)
        }
        XCTAssertLessThan(worst, 6.2)
    }

    func testTheCurveIsExactlyLinearBelowTheKneeAndBoundedAbove() {
        let p = StageProcessor()
        for x in stride(from: Float(-0.6), through: 0.6, by: 0.01) {
            XCTAssertEqual(p.softClip(x).bitPattern, x.bitPattern, "x = \(x)")
        }
        for x in [Float(0.61), 0.8, 1, 1.5, 3, 40, 1e6, 3e38, -0.61, -1, -3, -3e38] {
            let y = p.softClip(x)
            XCTAssertLessThanOrEqual(abs(y), 1, "x = \(x)")
            XCTAssertGreaterThan(abs(y), 0.6, "x = \(x)")
            XCTAssertEqual(y.sign, x.sign)
        }
    }

    func testTheCurveHasNoStepAndNoKinkAtTheKnee() {
        let p = StageProcessor()
        let h: Float = 1e-4
        var previous = p.softClip(0.5)
        var x: Float = 0.5
        var previousSlope: Float = 1
        while x < 0.7 {
            x += h
            let y = p.softClip(x)
            let slope = (y - previous) / h
            XCTAssertLessThanOrEqual(slope, 1.01, "x = \(x)")
            XCTAssertGreaterThan(slope, 0.5, "x = \(x)")
            XCTAssertEqual(slope, previousSlope, accuracy: 0.03, "x = \(x)")
            previous = y
            previousSlope = slope
        }
    }

    func testTheAntiAliasedStepHasNoJumpWhereASweepCrossesTheKnee() {
        let p = StageProcessor()
        for increment in [Float(0.001), 0.01, 0.05] {
            var prev: Float = 0
            var prevF: Double?
            var lastOut: Float = 0
            var x: Float = 0
            while x < 1.4 {
                x += increment
                let step = p.softClipADAAStep(x, prev: prev, prevF: prevF)
                XCTAssertLessThanOrEqual(step.out - lastOut, increment * 1.02,
                                         "x = \(x) step \(increment)")
                XCTAssertGreaterThanOrEqual(step.out - lastOut, -increment * 0.02,
                                            "x = \(x) step \(increment)")
                lastOut = step.out
                prev = x
                prevF = step.f
            }
        }
    }

    func testOnlySegmentsTouchingTheSaturatingRegionAreAntiAliased() {
        let p = StageProcessor()
        let inside = p.softClipADAAStep(0.4, prev: -0.3, prevF: nil)
        XCTAssertEqual(inside.out.bitPattern, Float(0.4).bitPattern)
        XCTAssertNil(inside.f)

        let leaving = p.softClipADAAStep(0.9, prev: 0.3, prevF: nil)
        XCTAssertNotNil(leaving.f)
        XCTAssertNotEqual(leaving.out, 0.9)

        let returning = p.softClipADAAStep(0.2, prev: 0.9, prevF: leaving.f)
        XCTAssertNil(returning.f)
        XCTAssertEqual(returning.out, p.softClipADAAStep(0.2, prev: 0.9, prevF: nil).out)
    }

    func testTheClipperStateCarriesAcrossBlockBoundaries() {
        let rate = 48000.0
        let input = Self.sine(hz: 9000, amplitude: 1.8, rate: rate, count: 4096)
            .enumerated().map { $0.element + 0.3 * sin(Double($0.offset) * 0.013) }
        let whole = Self.render(Self.neutralStage(), mono: input, rate: rate)
        for block in [64, 37, 1] {
            let pieces = Self.render(Self.neutralStage(), mono: input, rate: rate, block: block)
            XCTAssertEqual(pieces.map(\.bitPattern), whole.map(\.bitPattern),
                           "blocks of \(block)")
        }
    }

    private func foldBack(hz: Double, amplitude: Double, rate: Double)
        -> (now: Double, memoryless: Double, previous: Double, peak: Float) {
        let input = Self.sine(hz: hz, amplitude: amplitude, rate: rate, count: 16384)
        let rendered = Self.render(Self.neutralStage(), mono: input, rate: rate)
        let p = StageProcessor()
        let memoryless = input.map { Double(p.softClip(Float($0))) }
        let previous = Self.previousAveragingClipper(input.map { Double(Float($0)) })
        return (Self.nonFundamentalDb(rendered.map(Double.init), hz: hz, rate: rate),
                Self.nonFundamentalDb(memoryless, hz: hz, rate: rate),
                Self.nonFundamentalDb(previous, hz: hz, rate: rate),
                rendered.map { abs($0) }.max() ?? 0)
    }

    func testAHotHighFrequencySineStillFoldsBackFarLessThanTheMemorylessCurve() {
        let hot = foldBack(hz: 15000, amplitude: 1, rate: 44100)
        print(String(format: "alias vs fundamental, 15 kHz 0 dBFS at 44.1 kHz: "
                     + "memoryless knee %.1f dB, previous averaging clipper %.1f dB, now %.1f dB",
                     hot.memoryless, hot.previous, hot.now))
        XCTAssertLessThan(hot.now, hot.memoryless - 10)
        XCTAssertLessThan(hot.now, hot.previous - 10)

        let extreme = foldBack(hz: 15000, amplitude: 2, rate: 44100)
        print(String(format: "alias vs fundamental, 15 kHz +6 dBFS at 44.1 kHz: "
                     + "memoryless knee %.1f dB, previous averaging clipper %.1f dB, now %.1f dB",
                     extreme.memoryless, extreme.previous, extreme.now))
        XCTAssertLessThanOrEqual(extreme.peak, 1)
        XCTAssertLessThan(extreme.now, extreme.memoryless + 3)
    }

    func testModeratelyHotMidAndHighSinesAreNotGlitchedAtTheKnee() {
        for (hz, amplitude) in [(8000.0, 0.9), (3000.0, 0.8), (11000.0, 0.9)] {
            let r = foldBack(hz: hz, amplitude: amplitude, rate: 44100)
            XCTAssertLessThanOrEqual(r.now, r.memoryless + 1,
                                     "\(hz) Hz at \(amplitude): \(r.now) dB against \(r.memoryless) dB")
            XCTAssertLessThanOrEqual(r.now, r.previous + 1,
                              "\(hz) Hz at \(amplitude): \(r.now) dB against \(r.previous) dB")
        }
        let eight = foldBack(hz: 8000, amplitude: 0.9, rate: 44100)
        XCTAssertLessThan(eight.now, eight.memoryless - 10)
    }

    func testNothingLeavesTheClipperAboveFullScale() {
        var inputs = [[Double]]()
        inputs.append(Self.sine(hz: 15000, amplitude: 3, rate: 44100, count: 2048))
        inputs.append((0..<2048).map { $0 % 2 == 0 ? 3 : -3 })
        inputs.append((0..<2048).map { [0.0, 3, 0, -3][$0 % 4] })
        inputs.append((0..<2048).map { $0 % 64 < 32 ? 50 : -50 })
        for input in inputs {
            let out = Self.render(Self.neutralStage(), mono: input, rate: 44100)
            XCTAssertLessThanOrEqual(out.map { abs($0) }.max() ?? 0, 1)
            XCTAssertTrue(out.allSatisfy(\.isFinite))
        }
    }

    func testHugeFiniteInputsKeepTheSignOfTheSaturation() {
        let p = StageProcessor()
        for (x, prev) in [(Float(1e30), Float(-1e30)), (-1e30, 1e30), (3e38, 0), (-3e38, 0.5)] {
            let step = p.softClipADAAStep(x, prev: prev, prevF: nil)
            XCTAssertTrue(step.out.isFinite)
            XCTAssertLessThanOrEqual(abs(step.out), 1)
        }
        XCTAssertEqual(p.softClipADAAStep(1e30, prev: 1e30, prevF: nil).out, 1)
        XCTAssertEqual(p.softClipADAAStep(-1e30, prev: -1e30, prevF: nil).out, -1)
    }

    private final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        private var blocks: [UnsafeMutablePointer<Float>] = []

        init(_ shapes: [(channels: Int, frames: Int)]) {
            list = AudioBufferList.allocate(maximumBuffers: shapes.count)
            for (i, shape) in shapes.enumerated() {
                let count = shape.channels * shape.frames
                let block = UnsafeMutablePointer<Float>.allocate(capacity: count)
                block.initialize(repeating: 0, count: count)
                blocks.append(block)
                list[i] = AudioBuffer(
                    mNumberChannels: UInt32(shape.channels),
                    mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(block))
            }
        }

        deinit {
            for block in blocks { block.deallocate() }
            free(list.unsafeMutablePointer)
        }

        var constPointer: UnsafePointer<AudioBufferList> {
            UnsafePointer(list.unsafeMutablePointer)
        }

        func fill(_ buffer: Int, _ samples: [Float]) {
            for (i, v) in samples.enumerated() { blocks[buffer][i] = v }
        }

        func samples(_ buffer: Int, count: Int) -> [Float] {
            Array(UnsafeBufferPointer(start: blocks[buffer], count: count))
        }
    }
}
