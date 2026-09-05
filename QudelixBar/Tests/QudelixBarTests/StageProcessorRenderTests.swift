import CoreAudio
import XCTest
@testable import QudelixBar

/// The render callback, driven with hand-built buffer lists the way the HAL
/// drives it. What is checked here is the part of the processor no amount of
/// listening reveals: which of the aggregate's input buffers it consumes,
/// what the analyzer is allowed to see, and that the arithmetic survives the
/// values a driver or a tapped app can actually hand it.
final class StageProcessorRenderTests: XCTestCase {

    // MARK: - Which buffer the tap's audio is in

    /// The defect: the aggregate is built over the default output, and its
    /// input list is the tap's buffer preceded by whatever input streams the
    /// output device itself presents. An interface, headset or dock with
    /// microphone inputs contributes those first, so consuming from the front
    /// mixed a live microphone into the output and metered it as the music.
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

    /// The analyzer judges the SOURCE's bandwidth, so it reads the same
    /// buffer the output does — a microphone's spectrum would be classified
    /// as the stream that is playing.
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

    // MARK: - What the analyzer is allowed to see

    /// The window is a peek at the most recent audio. Handing back the same
    /// tail again when nothing new has arrived makes the analyzer re-judge
    /// audio it already classified and max-hold it onto itself, which is how
    /// a frozen ring reaches a stable verdict from no audio at all.
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

    /// A tone test mutes the pipeline, and render stops feeding the ring
    /// before the mute. Everything still in it is pre-mute audio, so the
    /// analyzer must come away empty rather than judging it.
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

    /// A muted render still writes silence rather than the input, and still
    /// reports what it saw — the diagnostics must not lie during a test.
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

    // MARK: - What prepare() is responsible for

    /// The rings, the ring's watermark and the meter all belong to the rate
    /// and the device that produced them. Carried across a restart, the first
    /// second on the new device reports a level nothing played.
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

    /// A driver supplies the rate, and a virtual one can supply anything.
    /// `max(8000, .infinity)` is still infinity, and the delay lengths below
    /// it are `Int(seconds * rate)` — which traps rather than clamps.
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

    // MARK: - Values a tapped app can actually produce

    /// Non-finite samples arriving from a tapped app are scrubbed at the
    /// door, but width on a pair near the float ceiling manufactures one
    /// inside the stage: 200% width doubles the side channel, and doubling
    /// 6e38 is an infinity. A memoryless shaper would merely pass it through;
    /// the anti-aliased one keeps it as the previous sample and hands back
    /// NaN for every sample after it, so it stops before the shaper.
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

        // Everything after it is finite too, where without the guard every
        // sample for the rest of the session was NaN.
        let normal = Buffers([(2, 16)])
        normal.fill(0, (0..<32).map { Float(sin(Double($0) * 0.2)) * 0.4 })
        let out2 = Buffers([(2, 16)])
        p.render(input: normal.constPointer, output: out2.list.unsafeMutablePointer)
        XCTAssertTrue(out2.samples(0, count: 32).allSatisfy(\.isFinite))

        // Silence is where an overflow leaves the stage — the filter states
        // upstream of the shaper absorbed it too — and the epoch wipe is what
        // brings it back, on the same edge an engine restart already uses.
        p.prepare(sampleRate: 48000)
        // A fresh block: the stage filters the input buffers IN PLACE, so the
        // one above now holds what came out of it, not what went in.
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

    // MARK: - The rendered sound itself

    /// The render-path work in this batch — the tail index, the widened
    /// denormal flush, the guard ahead of the clipper — is meant to be
    /// inaudible: every one of them either replaces arithmetic with
    /// equivalent arithmetic or fires only on values no signal reaches. These
    /// are the samples the full stage produced before any of it, so a change
    /// that alters the sound has to answer for itself here.
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
        // The whole block, not only the seven probes: a comb that wrapped one
        // sample early would move every value after it a little.
        let energy = rendered.reduce(0.0) { $0 + Double($1) * Double($1) }
        XCTAssertEqual(energy, 162.362_148_3, accuracy: 1e-4)
    }

    // MARK: - Helpers

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

    /// One stereo block of the same pseudo-random material every run, loud
    /// enough to move the night-mode envelope off its resting point.
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

    /// An AudioBufferList shaped like the HAL's, owning its blocks.
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
