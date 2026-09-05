import CoreAudio
import XCTest
@testable import QudelixBar

final class StageLimiterTests: XCTestCase {

    private static let ceiling: Float = 0.891_250_9

    func testTheLimiterOffRendersExactlyTheSameSamples() {
        var off = fullStage()
        off.limiter = nil
        var explicitlyOff = fullStage()
        explicitlyOff.limiter = false

        let noise = Self.stereoNoise(frames: 1024)
        let a = render(off, input: noise)
        let b = render(explicitlyOff, input: noise)
        XCTAssertEqual(a.map(\.bitPattern), b.map(\.bitPattern))

        var on = fullStage()
        on.limiter = true
        XCTAssertNotEqual(render(on, input: noise).map(\.bitPattern), a.map(\.bitPattern))
    }

    func testTheLimiterOffCostsNoLookaheadDelay() {
        var s = flatStage()
        s.limiter = nil
        var input = [Float](repeating: 0, count: 256 * 2)
        input[0] = 0.5
        input[1] = 0.5
        let out = render(s, input: input)
        XCTAssertGreaterThan(abs(out[0]), 0.2)

        s.limiter = true
        let delayed = render(s, input: input)
        XCTAssertTrue(Array(delayed[0..<(StageProcessor.limLookahead * 2)])
            .allSatisfy { $0 == 0 })
        XCTAssertGreaterThan(abs(delayed[StageProcessor.limLookahead * 2]), 0.2)
    }

    func testASineFarAboveFullScaleLeavesAtTheCeiling() {
        var s = flatStage()
        s.limiter = true
        let frames = 8192
        var input = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Float(2 * sin(2 * .pi * 997 * Double(i) / 48000))
            input[i * 2] = v
            input[i * 2 + 1] = v
        }
        let out = render(s, input: input)
        let tail = Array(out[(1024 * 2)...])
        let sample = Self.samplePeak(tail, channel: 0)
        let truePeak = Self.truePeak(tail, channel: 0)
        XCTAssertLessThanOrEqual(Self.db(truePeak), -1)
        XCTAssertGreaterThan(Self.db(truePeak), -1.3)
        XCTAssertLessThan(sample, 1)
    }

    func testAPeakBetweenTwoSamplesIsCaughtEvenThoughNoSampleClips() {
        var s = flatStage()
        let peakAmplitude = 3.0
        let frames = 4096
        var input = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Float(peakAmplitude * sin(.pi / 2 * Double(i)))
            input[i * 2] = v
            input[i * 2 + 1] = v
        }

        s.limiter = nil
        let bare = Array(render(s, input: input)[(512 * 2)...])
        let bareSample = Self.samplePeak(bare, channel: 0)
        let bareTrue = Self.truePeak(bare, channel: 0)
        XCTAssertLessThan(bareSample, Self.ceiling)
        XCTAssertGreaterThan(Self.db(bareTrue), 0)

        s.limiter = true
        let limited = Array(render(s, input: input)[(512 * 2)...])
        XCTAssertLessThanOrEqual(Self.db(Self.truePeak(limited, channel: 0)), -1)
        XCTAssertLessThan(Self.samplePeak(limited, channel: 0), 1)
    }

    func testTheGainWalksBackUpOverAboutEightyMilliseconds() {
        var s = flatStage()
        s.limiter = true
        let rate = 48000.0
        let burst = 2048
        let quiet = 24576
        let frames = burst + quiet
        var input = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let amplitude = i < burst ? 2.0 : 0.05
            let v = Float(amplitude * sin(2 * .pi * 997 * Double(i) / rate))
            input[i * 2] = v
            input[i * 2 + 1] = v
        }
        let out = render(s, input: input)

        func gain(atFrame f: Int) -> Double {
            let window = 96
            var peak: Float = 0
            for i in f..<min(f + window, frames) {
                peak = max(peak, abs(out[i * 2]))
            }
            return Double(peak)
        }
        let start = burst + StageProcessor.limLookahead + 96
        let g0 = gain(atFrame: start)
        let settled = gain(atFrame: frames - 200)
        XCTAssertLessThan(g0, settled * 0.95)

        var crossing = -1
        var f = start
        while f < frames - 200 {
            if (gain(atFrame: f) - g0) / (settled - g0) >= 0.632 {
                crossing = f
                break
            }
            f += 24
        }
        XCTAssertGreaterThan(crossing, 0)
        let ms = Double(crossing - start) / rate * 1000
        XCTAssertEqual(ms, 80, accuracy: 24)
    }

    func testAOneChannelBufferDoesNotTrap() {
        var s = fullStage()
        s.limiter = true
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyStage(s)
        let frames = 512
        let input = Buffers([(1, frames)])
        input.fill(0, (0..<frames).map { Float(1.5 * sin(Double($0) * 0.05)) })
        let output = Buffers([(1, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        let out = output.samples(0, count: frames)
        XCTAssertTrue(out.allSatisfy(\.isFinite))
        XCTAssertLessThan(out.map(abs).max() ?? 0, 1)
    }

    func testNonFiniteSamplesNeverLodgeInTheLimiter() {
        var s = flatStage()
        s.limiter = true
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyStage(s)
        let frames = 256
        let poison = Buffers([(1, frames)])
        var samples = [Float](repeating: 0.3, count: frames)
        samples[10] = .nan
        samples[11] = .infinity
        poison.fill(0, samples)
        let sink = Buffers([(1, frames)])
        p.render(input: poison.constPointer, output: sink.list.unsafeMutablePointer)

        let clean = Buffers([(1, frames)])
        clean.fill(0, [Float](repeating: 0.3, count: frames))
        p.render(input: clean.constPointer, output: sink.list.unsafeMutablePointer)
        let out = sink.samples(0, count: frames)
        XCTAssertTrue(out.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(out.map(abs).max() ?? 0, 0.1)
    }

    func testANewEpochWipesTheLookaheadRing() {
        var s = flatStage()
        s.limiter = true

        let used = StageProcessor()
        used.prepare(sampleRate: 48000)
        used.applyStage(s)
        let loud = Buffers([(2, 1024)])
        loud.fill(0, (0..<2048).map { Float(sin(Double($0) * 0.07)) * 1.8 })
        let sink = Buffers([(2, 1024)])
        used.render(input: loud.constPointer, output: sink.list.unsafeMutablePointer)
        used.prepare(sampleRate: 48000)

        let quiet = Self.stereoNoise(frames: 512)
        let after = Buffers([(2, 512)])
        after.fill(0, quiet)
        let afterOut = Buffers([(2, 512)])
        used.render(input: after.constPointer, output: afterOut.list.unsafeMutablePointer)

        let replayed = afterOut.samples(0, count: 1024)
        XCTAssertEqual(replayed, render(s, input: quiet))
        XCTAssertTrue(Array(replayed[0..<(StageProcessor.limLookahead * 2)])
            .allSatisfy { $0 == 0 })
    }

    func testSwitchingTheLimiterOnMidStreamStartsFromSilenceNotStaleAudio() {
        var s = flatStage()
        s.limiter = true
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyStage(s)
        let loud = Buffers([(2, 512)])
        loud.fill(0, (0..<1024).map { Float(sin(Double($0) * 0.07)) * 1.8 })
        let sink = Buffers([(2, 512)])
        p.render(input: loud.constPointer, output: sink.list.unsafeMutablePointer)

        s.limiter = false
        p.applyStage(s)
        p.render(input: loud.constPointer, output: sink.list.unsafeMutablePointer)

        s.limiter = true
        p.applyStage(s)
        let quiet = Buffers([(2, 512)])
        quiet.fill(0, [Float](repeating: 0, count: 1024))
        let quietOut = Buffers([(2, 512)])
        p.render(input: quiet.constPointer, output: quietOut.list.unsafeMutablePointer)
        XCTAssertTrue(Array(quietOut.samples(0, count: 1024)[0..<(StageProcessor.limLookahead * 2)])
            .allSatisfy { $0 == 0 })
    }

    func testTheGainReductionFloorIsReportedAndThenReset() {
        var s = flatStage()
        s.limiter = true
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyStage(s)
        XCTAssertEqual(p.drainLimiterFloor(), 1)

        let loud = Buffers([(2, 2048)])
        loud.fill(0, (0..<4096).map { Float(sin(Double($0) * 0.07)) * 2 })
        let sink = Buffers([(2, 2048)])
        p.render(input: loud.constPointer, output: sink.list.unsafeMutablePointer)

        let floor = p.drainLimiterFloor()
        let db = -20 * log10(Double(floor))
        XCTAssertLessThan(floor, 1)
        XCTAssertGreaterThan(db, 0.5)
        XCTAssertEqual(p.drainLimiterFloor(), 1)
    }

    func testMonitorModeNeverEngagesTheLimiter() {
        var s = flatStage()
        s.limiter = true
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.setMonitorOnly(true)
        p.applyStage(s)
        let frames = 512
        let samples = (0..<frames * 2).map { Float(2 * sin(Double($0) * 0.05)) }
        let input = Buffers([(2, frames)])
        input.fill(0, samples)
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)

        XCTAssertEqual(input.samples(0, count: frames * 2).map(\.bitPattern),
                       samples.map(\.bitPattern))
        XCTAssertTrue(output.samples(0, count: frames * 2).allSatisfy { $0 == 0 })
        XCTAssertEqual(p.drainLimiterFloor(), 1)
    }

    func testTheLimiterIsDeadWhileTheSoundstageIsOff() {
        var s = flatStage()
        s.enabled = false
        s.limiter = true
        let frames = 256
        var input = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Float(2 * sin(Double(i) * 0.05))
            input[i * 2] = v
            input[i * 2 + 1] = v
        }
        XCTAssertEqual(render(s, input: input).map(\.bitPattern), input.map(\.bitPattern))
    }

    func testTheReleaseIsDesignedFromTheRunningRate() {
        var s = flatStage()
        s.limiter = true
        for rate in [44100.0, 96000] {
            let p = StageProcessor()
            p.prepare(sampleRate: rate)
            p.applyStage(s)
            let frames = Int(rate / 4)
            let input = Buffers([(2, frames)])
            input.fill(0, (0..<frames * 2).map {
                $0 < 4096 ? Float(2 * sin(Double($0) * 0.05)) : 0.05
            })
            let output = Buffers([(2, frames)])
            p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
            XCTAssertTrue(output.samples(0, count: frames * 2).allSatisfy(\.isFinite),
                          "rate \(rate)")
        }
    }

    func testASavedStageFromBeforeTheLimiterStillDecodesAsOff() {
        let legacy = """
        {"enabled": true, "width": 130, "crossfeed": 0.3, "dialogue": 0, "room": 0}
        """
        let s = try? JSONDecoder().decode(StageSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(s?.limiterValue, false)
        XCTAssertEqual(s?.limiter, nil)
        var explicit = StageSettings()
        explicit.limiter = false
        XCTAssertNil(explicit.clamped().limiter)
        XCTAssertTrue(explicit.audiblyEquals(StageSettings()))
    }

    func testAStageWithOnlyTheLimiterOnIsNotInert() {
        var s = StageSettings()
        s.enabled = true
        s.width = 100
        s.crossfeed = 0
        s.dialogue = 0
        s.room = 0
        s.distance = 0
        s.center = 0
        s.night = 0
        XCTAssertTrue(s.isAudiblyNeutral)
        s.limiter = true
        XCTAssertFalse(s.isAudiblyNeutral)
        XCTAssertTrue(s.doesAnything)
    }

    func testTheSignalPathNamesTheLimiter() {
        var stage = StageSettings()
        stage.enabled = true
        stage.width = 100
        stage.crossfeed = 0
        stage.dialogue = 0
        stage.room = 0
        stage.distance = 0
        stage.center = 0
        stage.night = 0
        stage.limiter = true
        let rows = SignalPath.rows(.init(engineMode: .insert, stage: stage))
        let app = rows.first { $0.id == "app" }
        XCTAssertTrue(app?.state.contains("true-peak limiter") ?? false, app?.state ?? "")

        stage.limiter = false
        let without = SignalPath.rows(.init(engineMode: .insert, stage: stage))
            .first { $0.id == "app" }
        XCTAssertFalse(without?.state.contains("limiter") ?? true)
    }

    private static func samplePeak(_ interleaved: [Float], channel: Int) -> Float {
        var peak: Float = 0
        var i = channel
        while i < interleaved.count {
            peak = max(peak, abs(interleaved[i]))
            i += 2
        }
        return peak
    }

    private static let phases = [StageProcessor.sincPhase(0.25),
                                 StageProcessor.sincPhase(0.5),
                                 StageProcessor.sincPhase(0.75)]

    private static func truePeak(_ interleaved: [Float], channel: Int) -> Float {
        var mono = [Float]()
        var i = channel
        while i < interleaved.count {
            mono.append(interleaved[i])
            i += 2
        }
        var peak: Float = 0
        for n in 0..<mono.count {
            peak = max(peak, abs(mono[n]))
            guard n >= 7 else { continue }
            for phase in phases {
                var acc: Float = 0
                for t in 0..<8 { acc += mono[n - 7 + t] * phase[t] }
                peak = max(peak, abs(acc))
            }
        }
        return peak
    }

    private static func db(_ v: Float) -> Double { 20 * log10(Double(max(v, 1e-9))) }

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

    private func flatStage() -> StageSettings {
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

    private func render(_ settings: StageSettings, input samples: [Float],
                        sampleRate: Double = 48000) -> [Float] {
        let frames = samples.count / 2
        let p = StageProcessor()
        p.prepare(sampleRate: sampleRate)
        p.applyStage(settings)
        let input = Buffers([(2, frames)])
        input.fill(0, samples)
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        return output.samples(0, count: frames * 2)
    }

    private static func stereoNoise(frames: Int) -> [Float] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: state)) / Float(Int64.max) * 0.12
            let tone = Float(sin(Double(i) * 0.027)) * 0.3
            out[i * 2] = tone + noise
            out[i * 2 + 1] = tone * 0.7 - noise
        }
        return out
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
