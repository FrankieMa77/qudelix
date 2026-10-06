import CoreAudio
import Foundation
import XCTest
@testable import QudelixBar

final class StageRenderEdgeTests: XCTestCase {
    func testAnEpochEdgeWipesTheStageOnceAndNotTwice() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyStage(Self.fullStage())
        XCTAssertEqual(p.stageResetCount, 0)

        let samples = Self.deterministicStereo(frames: 256)
        _ = Self.renderOnce(p, samples)
        XCTAssertEqual(p.stageResetCount, 1, "the engage edge wipes once")
        _ = Self.renderOnce(p, samples)
        XCTAssertEqual(p.stageResetCount, 1, "a steady render wipes nothing")

        p.prepare(sampleRate: 96000)
        _ = Self.renderOnce(p, samples)
        XCTAssertEqual(p.stageResetCount, 2, "a rate change wipes once, not twice")

        var off = Self.fullStage()
        off.enabled = false
        p.applyStage(off)
        p.prepare(sampleRate: 48000)
        _ = Self.renderOnce(p, samples)
        XCTAssertEqual(p.stageResetCount, 2, "an idle stage has nothing to wipe")
        p.applyStage(Self.fullStage())
        _ = Self.renderOnce(p, samples)
        XCTAssertEqual(p.stageResetCount, 3, "re-engaging wipes once")
    }

    func testARenderAfterARateChangeIsBitIdenticalToAFreshStart() {
        let samples = Self.deterministicStereo(frames: 1024)

        let used = StageProcessor()
        used.prepare(sampleRate: 44100)
        used.applyStage(Self.fullStage())
        used.applyLoudness(shelfDb: 6)
        used.applyBassGuard(ceilingDb: 8, predictedBoostDb: 14)
        for _ in 0..<4 {
            _ = Self.renderOnce(used, Self.tone(hz: 60, frames: 1024, amplitude: 0.6))
        }
        used.prepare(sampleRate: 48000)

        let fresh = StageProcessor()
        fresh.prepare(sampleRate: 48000)
        fresh.applyStage(Self.fullStage())
        fresh.applyLoudness(shelfDb: 6)
        fresh.applyBassGuard(ceilingDb: 8, predictedBoostDb: 14)

        XCTAssertEqual(Self.renderOnce(used, samples).map(\.bitPattern),
                       Self.renderOnce(fresh, samples).map(\.bitPattern),
                       "the epoch wipe must leave no trace of the old rate")
    }

    func testWipingTheRingsCostsMicrosecondsNotHundredsOfThem() {
        let p = StageProcessor()
        p.prepare(sampleRate: 96000)
        p.applyStage(Self.fullStage())
        let samples = Self.deterministicStereo(frames: 64)
        let rounds = 200

        for _ in 0..<20 { _ = Self.renderOnce(p, samples) }
        var steady: [Double] = []
        for _ in 0..<rounds {
            let start = CFAbsoluteTimeGetCurrent()
            _ = Self.renderOnce(p, samples)
            steady.append(CFAbsoluteTimeGetCurrent() - start)
        }

        var wiping: [Double] = []
        for _ in 0..<rounds {
            p.prepare(sampleRate: 96000)
            let start = CFAbsoluteTimeGetCurrent()
            _ = Self.renderOnce(p, samples)
            wiping.append(CFAbsoluteTimeGetCurrent() - start)
        }

        let steadyUs = (steady.min() ?? 0) * 1e6
        let wipingUs = (wiping.min() ?? 0) * 1e6
        print(String(format: "reset edge: %.1f us steady, %.1f us wiping, "
                     + "%.1f us for the wipe itself",
                     steadyUs, wipingUs, wipingUs - steadyUs))
        XCTAssertLessThan(wipingUs - steadyUs, 150,
                          "zeroing 51,200 floats belongs in the microseconds")
    }

    func testTheBassGuardMeasuresTheSignalBeforeTheLoudnessShelf() {
        let frames = 48000
        let samples = Self.tone(hz: 60, frames: frames, amplitude: 0.1)

        func run(shelfDb: Double) -> (out: [Float], reduction: Double) {
            var s = Self.flatStage()
            s.bassGuard = true
            s.loudness = shelfDb > 0
            let p = StageProcessor()
            p.prepare(sampleRate: 48000)
            p.applyLoudness(shelfDb: shelfDb)
            p.applyStage(s)
            p.applyBassGuard(ceilingDb: 12, predictedBoostDb: 20)
            let out = Self.renderOnce(p, samples)
            return (out, Double(p.drainBassGuardReduction()))
        }

        let plain = run(shelfDb: 0)
        let shelved = run(shelfDb: 6)
        XCTAssertGreaterThan(plain.reduction, 4, "the guard had work to do")
        XCTAssertEqual(shelved.reduction, plain.reduction, accuracy: 0.02,
                       "the shelf is in the prediction already; measuring it "
                       + "again would guard against it twice")

        let from = frames / 2
        let gap = 20 * log10(Self.bandRms(shelved.out, hz: 60, from: from)
                             / Self.bandRms(plain.out, hz: 60, from: from))
        let low = BiquadSection.lowShelf(freq: StageProcessor.loudnessLowHz,
                                         gainDb: 6,
                                         q: StageProcessor.loudnessShelfQ,
                                         sampleRate: 48000)
        let high = BiquadSection.highShelf(
            freq: StageProcessor.loudnessHighHz,
            gainDb: 6 * EarLevel.trebleShelfRatio,
            q: StageProcessor.loudnessShelfQ, sampleRate: 48000)
        let expected = low.magnitudeDb(at: 60, sampleRate: 48000)
            + high.magnitudeDb(at: 60, sampleRate: 48000)
        XCTAssertEqual(gap, expected, accuracy: 0.5,
                       "the guard must not eat the shelf it was told about")
    }

    func testNightModeReEngagesWhereAFreshEngageWould() {
        let loud = Self.tone(hz: 200, frames: 24000, amplitude: 0.5)
        let quiet = Self.tone(hz: 200, frames: 2400, amplitude: 0.05)
        var on = Self.flatStage()
        on.night = 0.6
        var off = on
        off.night = 0

        let cycled = StageProcessor()
        cycled.prepare(sampleRate: 48000)
        cycled.applyStage(on)
        _ = Self.renderOnce(cycled, loud)
        cycled.applyStage(off)
        _ = Self.renderOnce(cycled, quiet)
        cycled.applyStage(on)
        let resumed = Self.renderOnce(cycled, quiet)

        let held = StageProcessor()
        held.prepare(sampleRate: 48000)
        held.applyStage(on)
        _ = Self.renderOnce(held, loud)
        let stale = Self.renderOnce(held, quiet)

        let fresh = StageProcessor()
        fresh.prepare(sampleRate: 48000)
        fresh.applyStage(on)
        let engaged = Self.renderOnce(fresh, quiet)

        let resumedDb = 20 * log10(Self.rms(resumed) / Self.rms(quiet))
        let engagedDb = 20 * log10(Self.rms(engaged) / Self.rms(quiet))
        let staleDb = 20 * log10(Self.rms(stale) / Self.rms(quiet))
        XCTAssertEqual(resumedDb, engagedDb, accuracy: 0.05,
                       "Night off and on again must start where Night does")
        XCTAssertGreaterThan(abs(staleDb - engagedDb), 1,
                             "a minutes-old envelope really is a different gain")
    }

    func testAShortAggregateKeepsItsChainsOffTheWrongStreams() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyAppChains([AppCurve(bundleID: "com.a", preGain: -6.020_6, bands: []),
                          AppCurve(bundleID: "com.b", preGain: 6.020_6, bands: [])])

        let frames = 8
        let short = Buffers([(2, frames), (2, frames)])
        short.fill(0, [Float](repeating: 0.1, count: frames * 2))
        short.fill(1, [Float](repeating: 0.05, count: frames * 2))
        let output = Buffers([(2, frames)])
        p.render(input: short.constPointer, output: output.list.unsafeMutablePointer)

        for value in output.samples(0, count: frames * 2) {
            XCTAssertEqual(value, 0.05, accuracy: 1e-6,
                           "two buffers for a three-stream plan is the catch-all")
        }
        XCTAssertEqual(p.renderDiagnostics().inputBuffers, 2)

        let full = Buffers([(2, frames), (2, frames), (2, frames)])
        full.fill(0, [Float](repeating: 0.1, count: frames * 2))
        full.fill(1, [Float](repeating: 0.1, count: frames * 2))
        full.fill(2, [Float](repeating: 0.05, count: frames * 2))
        p.render(input: full.constPointer, output: output.list.unsafeMutablePointer)
        for value in output.samples(0, count: frames * 2) {
            XCTAssertEqual(value, 0.05 + 0.2 + 0.05, accuracy: 1e-5,
                           "the whole plan present is still the per-app path")
        }
        XCTAssertEqual(p.renderDiagnostics().inputBuffers, 3)
    }

    func testTheCarriedClipperValueMatchesRecomputingIt() {
        let p = StageProcessor()
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var prev: Float = 0
        var prevF: Double?
        var carried = [UInt32]()
        var recomputed = [UInt32]()
        for i in 0..<4096 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: state)) / Float(Int64.max)
            let x = i % 512 < 8 ? prev : noise * 2.5
            let step = p.softClipADAAStep(x, prev: prev, prevF: prevF)
            carried.append(step.out.bitPattern)
            recomputed.append(p.softClipADAA(x, prev: prev).bitPattern)
            prev = x
            prevF = step.f
        }
        XCTAssertEqual(carried, recomputed,
                       "carrying F must be the same curve, sample for sample")
    }

    private static func flatStage() -> StageSettings {
        var s = StageSettings()
        s.enabled = true
        s.width = 100
        s.crossfeed = 0
        s.dialogue = 0
        s.room = 0
        s.distance = 0
        s.span = 0.5
        s.center = 0
        s.size = 0.5
        s.night = 0
        return s
    }

    private static func fullStage() -> StageSettings {
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

    private static func renderOnce(_ p: StageProcessor, _ samples: [Float]) -> [Float] {
        let frames = samples.count / 2
        let input = Buffers([(2, frames)])
        input.fill(0, samples)
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        return output.samples(0, count: frames * 2)
    }

    private static func tone(hz: Double, frames: Int, amplitude: Double) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Float(amplitude * sin(2 * .pi * hz * Double(i) / 48000))
            out[i * 2] = v
            out[i * 2 + 1] = v
        }
        return out
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

    private static func rms(_ interleaved: [Float]) -> Double {
        var sum = 0.0
        for v in interleaved { sum += Double(v) * Double(v) }
        return interleaved.isEmpty ? 0 : (sum / Double(interleaved.count)).squareRoot()
    }

    private static func bandRms(_ interleaved: [Float], hz: Double,
                                from: Int) -> Double {
        var re = 0.0, im = 0.0
        var n = 0
        var frame = from
        let last = interleaved.count / 2
        while frame < last {
            let v = Double(interleaved[frame * 2])
            let w = 2 * Double.pi * hz * Double(frame) / 48000
            re += v * cos(w)
            im += v * sin(w)
            n += 1
            frame += 1
        }
        guard n > 0 else { return 0 }
        return (re * re + im * im).squareRoot() / Double(n) * 2
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
