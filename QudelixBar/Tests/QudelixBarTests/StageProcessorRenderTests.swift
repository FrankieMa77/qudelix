import CoreAudio
import XCTest
@testable import QudelixBar

final class StageProcessorRenderTests: XCTestCase {


    func testTheTapsBufferIsTakenFromTheEndOfTheInputList() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)

        let input = Buffers([(1, 8), (2, 8)])
        input.fill(0, [Float](repeating: 1, count: 8))
        input.fill(1, (0..<16).map { Float($0) / 100 })
        let output = Buffers([(2, 8)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)

        XCTAssertEqual(output.samples(0, count: 16), (0..<16).map { Float($0) / 100 })
        XCTAssertFalse(output.samples(0, count: 16).contains(1))
        XCTAssertEqual(p.renderDiagnostics().channels, 2)
    }

    func testASingleInputBufferIsStillConsumed() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        let input = Buffers([(2, 4)])
        input.fill(0, [0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4])
        let output = Buffers([(2, 4)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        XCTAssertEqual(output.samples(0, count: 8),
                       [0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4])
    }

    func testTheSpectrumRingIsFedFromTheTapNotFromTheMicrophone() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        let n = QualityAnalyzer.fftSize
        let mic = [Float](repeating: 1, count: n)
        let tap = (0..<n).map { Float(sin(Double($0) * 0.01)) * 0.5 }

        let input = Buffers([(1, n), (1, n)])
        input.fill(0, mic)
        input.fill(1, tap)
        let output = Buffers([(2, n)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)

        let drained = p.drainSpectrumSamples(n)
        XCTAssertEqual(drained.count, n)
        XCTAssertEqual(drained, tap)
    }


    func testASecondDrainWithNoFreshAudioReturnsNothing() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        let n = QualityAnalyzer.fftSize
        feed(p, frames: n)

        XCTAssertEqual(p.drainSpectrumSamples(n).count, n)
        XCTAssertTrue(p.drainSpectrumSamples(n).isEmpty)

        feed(p, frames: n / 2)
        XCTAssertTrue(p.drainSpectrumSamples(n).isEmpty, "half a window is not a window")
        feed(p, frames: n / 2)
        XCTAssertEqual(p.drainSpectrumSamples(n).count, n)
    }

    func testAMutedRenderFeedsTheRingNothing() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        let n = QualityAnalyzer.fftSize
        feed(p, frames: n)
        XCTAssertEqual(p.drainSpectrumSamples(n).count, n)

        XCTAssertFalse(p.isMutedNow)
        p.setMuted(true)
        XCTAssertTrue(p.isMutedNow)
        feed(p, frames: n * 2)
        XCTAssertTrue(p.drainSpectrumSamples(n).isEmpty)

        p.setMuted(false)
        feed(p, frames: n)
        XCTAssertEqual(p.drainSpectrumSamples(n).count, n)
    }

    func testAMutedRenderWritesSilence() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.setMuted(true)
        let input = Buffers([(2, 4)])
        input.fill(0, [Float](repeating: 0.5, count: 8))
        let output = Buffers([(2, 4)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        XCTAssertEqual(output.samples(0, count: 8), [Float](repeating: 0, count: 8))
        XCTAssertEqual(p.renderDiagnostics().channels, 2)
        XCTAssertFalse(p.renderDiagnostics().stageRan)
    }


    func testPrepareDropsTheRingAndTheMeter() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        feed(p, frames: QualityAnalyzer.fftSize, value: 0.5)
        XCTAssertGreaterThan(p.drainMeter().frames, 0)
        feed(p, frames: QualityAnalyzer.fftSize, value: 0.5)

        p.prepare(sampleRate: 44100)
        XCTAssertTrue(p.drainSpectrumSamples(QualityAnalyzer.fftSize).isEmpty)
        let meter = p.drainMeter()
        XCTAssertEqual(meter.frames, 0)
        XCTAssertEqual(meter.sumSquares, 0)
        XCTAssertNil(p.drainSourceCorrelation())
    }

    func testPrepareSurvivesARateNoDeviceCouldRunAt() {
        for rate in [Double.infinity, .nan, 0, -48000, 1e30] {
            let p = StageProcessor()
            p.prepare(sampleRate: rate)
            p.applyStage(fullStage())
            let input = Buffers([(2, 64)])
            input.fill(0, (0..<128).map { Float(sin(Double($0) * 0.1)) * 0.3 })
            let output = Buffers([(2, 64)])
            p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
            XCTAssertTrue(output.samples(0, count: 128).allSatisfy(\.isFinite),
                          "rate \(rate)")
        }
    }


    func testAnOverflowInsideTheStageDoesNotPoisonEverySampleAfterIt() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        var s = StageSettings()
        s.enabled = true
        s.width = 200
        s.crossfeed = 0
        s.room = 0
        s.dialogue = 0
        s.night = 0
        s.distance = 0
        s.center = 0
        p.applyStage(s)

        let huge = Buffers([(2, 16)])
        huge.fill(0, (0..<32).map { $0 % 2 == 0 ? Float(3e38) : Float(-3e38) })
        let out1 = Buffers([(2, 16)])
        p.render(input: huge.constPointer, output: out1.list.unsafeMutablePointer)
        XCTAssertTrue(out1.samples(0, count: 32).allSatisfy(\.isFinite))

        let normal = Buffers([(2, 16)])
        normal.fill(0, (0..<32).map { Float(sin(Double($0) * 0.2)) * 0.4 })
        let out2 = Buffers([(2, 16)])
        p.render(input: normal.constPointer, output: out2.list.unsafeMutablePointer)
        XCTAssertTrue(out2.samples(0, count: 32).allSatisfy(\.isFinite))

        p.prepare(sampleRate: 48000)
        let again = Buffers([(2, 16)])
        again.fill(0, (0..<32).map { Float(sin(Double($0) * 0.2)) * 0.4 })
        let out3 = Buffers([(2, 16)])
        p.render(input: again.constPointer, output: out3.list.unsafeMutablePointer)
        let recovered = out3.samples(0, count: 32)
        XCTAssertTrue(recovered.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(recovered.map(abs).max() ?? 0, 0.01,
                             "the stage stayed silent after the epoch wipe")
    }

    func testNonFiniteInputIsScrubbedAtTheDoor() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyStage(fullStage())
        let input = Buffers([(2, 8)])
        input.fill(0, [0.2, .nan, .infinity, -0.2, 0.1, -.infinity, 0.3, .nan,
                       0.2, 0.1, -0.1, 0.4, .nan, 0.2, 0.1, -0.3])
        let output = Buffers([(2, 8)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        XCTAssertTrue(output.samples(0, count: 16).allSatisfy(\.isFinite))
    }


    func testTheFullStageStillRendersTheSameSamples() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyStage(fullStage())

        let frames = 4096
        let input = Buffers([(2, frames)])
        input.fill(0, Self.deterministicStereo(frames: frames))
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        let rendered = output.samples(0, count: frames * 2)

        let expected: [(index: Int, value: Float)] = [
            (0, 0.104_356_73), (1, -0.104_356_73), (201, 0.048_953_135),
            (2001, -0.109_035_04), (5001, 0.116_475_4), (8000, -0.236_269_28),
            (8191, 0.282_450_6),
        ]
        for e in expected {
            XCTAssertEqual(rendered[e.index], e.value, accuracy: 1e-6,
                           "sample \(e.index)")
        }
        let energy = rendered.reduce(0.0) { $0 + Double($1) * Double($1) }
        XCTAssertEqual(energy, 162.362_148_3, accuracy: 1e-4)
    }


    func testTheLoudnessMeasurementNeverWritesToTheAudio() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.setMonitorOnly(true)
        p.applyStage(fullStage())

        let frames = 1024
        let samples = Self.deterministicStereo(frames: frames)
        let input = Buffers([(2, frames)])
        input.fill(0, samples)
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)

        XCTAssertEqual(input.samples(0, count: frames * 2).map(\.bitPattern),
                       samples.map(\.bitPattern))
        XCTAssertTrue(output.samples(0, count: frames * 2).allSatisfy { $0 == 0 })
        let loudness = p.drainLoudnessMeter()
        XCTAssertEqual(loudness.frames, frames)
        XCTAssertGreaterThan(loudness.sumSquares, 0)
    }

    func testTheLoudnessMeterCountsFramesNotChannelSamples() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        let frames = 48000
        let amplitude = 0.5
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Float(amplitude * sin(2 * .pi * 1000 * Double(i) / 48000))
            samples[i * 2] = v
            samples[i * 2 + 1] = v
        }
        let input = Buffers([(2, frames)])
        input.fill(0, samples)
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)

        let loudness = p.drainLoudnessMeter()
        XCTAssertEqual(loudness.frames, frames)
        var window = ShortTermLoudness()
        window.add(sumSquares: loudness.sumSquares, frames: loudness.frames)
        let mono = 10 * log10(amplitude * amplitude / 2)
        XCTAssertEqual(window.lufs ?? .nan, mono + 3.01, accuracy: 0.1)
    }

    func testPrepareDropsTheLoudnessWindowWithTheRestOfTheMeter() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        feed(p, frames: 4096, value: 0.5)
        XCTAssertGreaterThan(p.drainLoudnessMeter().frames, 0)
        feed(p, frames: 4096, value: 0.5)

        p.prepare(sampleRate: 44100)
        let loudness = p.drainLoudnessMeter()
        XCTAssertEqual(loudness.frames, 0)
        XCTAssertEqual(loudness.sumSquares, 0)
    }

    func testAMutedRenderMeasuresNoLoudness() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.setMuted(true)
        feed(p, frames: 1024, value: 0.5)
        XCTAssertEqual(p.drainLoudnessMeter().frames, 0)
    }

    func testNonFiniteSamplesNeverLodgeInTheLoudnessFilter() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        let frames = 256
        var samples = [Float](repeating: 0.2, count: frames * 2)
        samples[10] = .nan
        samples[11] = .infinity
        let input = Buffers([(2, frames)])
        input.fill(0, samples)
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        XCTAssertGreaterThan(p.drainLoudnessMeter().sumSquares, 0)

        let clean = Buffers([(2, frames)])
        clean.fill(0, [Float](repeating: 0.2, count: frames * 2))
        p.render(input: clean.constPointer, output: output.list.unsafeMutablePointer)
        let after = p.drainLoudnessMeter()
        XCTAssertTrue(after.sumSquares.isFinite)
        XCTAssertGreaterThan(after.sumSquares, 0)
    }

    private func fullStage() -> StageSettings {
        var s = StageSettings()
        s.enabled = true
        s.width = 160
        s.crossfeed = 0.5
        s.dialogue = 3
        s.room = 0.6
        s.distance = 0.4
        s.span = 0.6
        s.center = -1
        s.size = 0.5
        s.night = 0.4
        return s
    }

    private static func deterministicStereo(frames: Int) -> [Float] {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: state)) / Float(Int64.max) * 0.15
            let tone = Float(sin(Double(i) * 0.031)) * 0.35
            out[i * 2] = tone + noise
            out[i * 2 + 1] = tone * 0.8 - noise
        }
        return out
    }

    private func feed(_ p: StageProcessor, frames: Int, value: Float? = nil) {
        let input = Buffers([(1, frames)])
        if let value {
            input.fill(0, [Float](repeating: value, count: frames))
        } else {
            input.fill(0, (0..<frames).map { Float(sin(Double($0) * 0.03)) * 0.4 })
        }
        let output = Buffers([(1, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
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
