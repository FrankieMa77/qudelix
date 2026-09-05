import CoreAudio
import XCTest
@testable import QudelixBar

final class StageBalanceTests: XCTestCase {

    func testUnityBandTrimsRenderExactlyTheSameSamplesAsNoTrimsAtAll() {
        var untrimmed = fullStage()
        untrimmed.crossLowTrim = nil
        untrimmed.crossMidTrim = nil
        untrimmed.crossHighTrim = nil
        untrimmed.balanceDb = nil
        untrimmed.alignMs = nil

        var unity = fullStage()
        unity.crossLowTrim = 1
        unity.crossMidTrim = 1
        unity.crossHighTrim = 1
        unity.balanceDb = 0
        unity.alignMs = 0

        XCTAssertEqual(render(untrimmed), render(unity))
    }

    func testAStageSavedBeforeTheseControlsExistedStillDecodes() {
        let legacy = """
        {
          "exposure": [],
          "levelTracking": false,
          "stageByDevice": {
            "AppleHDA:0": {
              "center": -1,
              "crossfeed": 0.5,
              "dialogue": 3,
              "distance": 0.4,
              "enabled": true,
              "night": 0.4,
              "room": 0.6,
              "size": 0.5,
              "span": 0.6,
              "width": 160
            }
          }
        }
        """
        let decoded = try? JSONDecoder().decode(PersistedStageState.self,
                                                from: Data(legacy.utf8))
        guard let s = decoded?.stageByDevice["AppleHDA:0"] else {
            return XCTFail("a pre-change document must still decode")
        }
        XCTAssertNil(s.crossLowTrim)
        XCTAssertNil(s.balanceDb)
        XCTAssertNil(s.alignMs)
        XCTAssertEqual(s.crossLowTrimValue, 1)
        XCTAssertEqual(s.crossMidTrimValue, 1)
        XCTAssertEqual(s.crossHighTrimValue, 1)
        XCTAssertEqual(s.balanceDbValue, 0)
        XCTAssertEqual(s.alignMsValue, 0)
        XCTAssertTrue(s.clamped().crossLowTrim == nil)

        var explicit = s
        explicit.crossLowTrim = 1
        explicit.crossMidTrim = 1
        explicit.crossHighTrim = 1
        explicit.balanceDb = 0
        explicit.alignMs = 0
        XCTAssertTrue(s.audiblyEquals(explicit))
        XCTAssertEqual(render(s), render(explicit))
    }

    func testEasingTheTopBandOffChangesTheSound() {
        var trimmed = fullStage()
        trimmed.crossHighTrim = 0
        XCTAssertNotEqual(render(trimmed), render(fullStage()))
    }

    func testLiftingABandAboveUnityChangesTheSound() {
        var lifted = fullStage()
        lifted.crossLowTrim = 2
        XCTAssertNotEqual(render(lifted), render(fullStage()))
    }

    func testTheBandTrimsDoNothingWithCrossfeedAtZero() {
        var plain = fullStage()
        plain.crossfeed = 0
        var trimmed = plain
        trimmed.crossLowTrim = 0
        trimmed.crossMidTrim = 2
        trimmed.crossHighTrim = 0.25
        XCTAssertEqual(render(plain), render(trimmed))
    }

    func testACentredBalanceLeavesTheSamplesAlone() {
        var centred = fullStage()
        centred.balanceDb = 0
        centred.alignMs = 0
        var unset = fullStage()
        unset.balanceDb = nil
        unset.alignMs = nil
        XCTAssertEqual(render(centred), render(unset))
    }

    func testTheLevelDifferenceIsSplitHalfToEachSide() {
        var centred = flatStage()
        centred.balanceDb = 0
        var tilted = flatStage()
        tilted.balanceDb = 3

        let base = render(centred, input: tone(frames: 2048))
        let moved = render(tilted, input: tone(frames: 2048))

        let dropped = db(rms(moved, channel: 0)) - db(rms(base, channel: 0))
        let lifted = db(rms(moved, channel: 1)) - db(rms(base, channel: 1))
        XCTAssertEqual(dropped, -1.5, accuracy: 0.02)
        XCTAssertEqual(lifted, 1.5, accuracy: 0.02)
        XCTAssertEqual(db(rms(moved, channel: 1)) - db(rms(moved, channel: 0)),
                       3, accuracy: 0.02)
    }

    func testANegativeLevelMovesTheImageTheOtherWay() {
        var left = flatStage()
        left.balanceDb = -3
        let out = render(left, input: tone(frames: 2048))
        XCTAssertGreaterThan(rms(out, channel: 0), rms(out, channel: 1))
    }

    func testTimeAlignmentHoldsBackTheSideItNames() {
        var right = flatStage()
        right.alignMs = 0.5
        let heldRight = render(right, input: impulse(frames: 256))
        XCTAssertEqual(onset(heldRight, channel: 0), 0)
        XCTAssertEqual(onset(heldRight, channel: 1), 24)

        var left = flatStage()
        left.alignMs = -0.5
        let heldLeft = render(left, input: impulse(frames: 256))
        XCTAssertEqual(onset(heldLeft, channel: 0), 24)
        XCTAssertEqual(onset(heldLeft, channel: 1), 0)
    }

    func testTheAlignmentRingHoldsHalfAMillisecondAtTheFastestRateADeviceCanReport() {
        var s = flatStage()
        s.alignMs = 0.5
        let out = render(s, input: impulse(frames: 1024), sampleRate: 768_000)
        XCTAssertEqual(onset(out, channel: 1), 384)
    }

    func testAFractionOfASampleLandsBetweenTwoSamples() {
        var s = flatStage()
        s.alignMs = 0.5

        let whole = render(s, input: impulse(frames: 256), sampleRate: 48000)
        XCTAssertEqual(onset(whole, channel: 1), 24)
        XCTAssertEqual(sample(whole, channel: 1, at: 26), 0, accuracy: 1e-7)

        let half = render(s, input: impulse(frames: 256), sampleRate: 49000)
        XCTAssertEqual(onset(half, channel: 1), 24)
        XCTAssertGreaterThan(abs(sample(half, channel: 1, at: 26)), 1e-4)
    }

    func testBalanceActsOnMonoContentToo() {
        var s = flatStage()
        s.balanceDb = 3
        var interleaved = [Float](repeating: 0, count: 512)
        for i in 0..<256 {
            let v = Float(sin(Double(i) * 0.09)) * 0.05
            interleaved[i * 2] = v
            interleaved[i * 2 + 1] = v
        }
        let out = render(s, input: interleaved)
        XCTAssertGreaterThan(rms(out, channel: 1), rms(out, channel: 0) * 1.3)
    }

    func testAStageWithOnlyBalanceSetIsNotInert() {
        var s = StageSettings()
        s.width = 100
        s.crossfeed = 0
        s.dialogue = 0
        s.room = 0
        s.distance = 0
        s.center = 0
        s.night = 0
        XCTAssertTrue(s.isAudiblyNeutral)

        var moved = s
        moved.balanceDb = 1
        XCTAssertFalse(moved.isAudiblyNeutral)

        var held = s
        held.alignMs = 0.2
        XCTAssertFalse(held.isAudiblyNeutral)
    }

    func testASettingsFileCannotPushTheseOutOfRange() {
        var wild = StageSettings()
        wild.crossLowTrim = 50
        wild.crossMidTrim = -3
        wild.crossHighTrim = .nan
        wild.balanceDb = 40
        wild.alignMs = -9
        let c = wild.clamped()
        XCTAssertEqual(c.crossLowTrimValue, 2)
        XCTAssertEqual(c.crossMidTrimValue, 0)
        XCTAssertEqual(c.crossHighTrimValue, 1)
        XCTAssertEqual(c.balanceDbValue, 3)
        XCTAssertEqual(c.alignMsValue, -0.5)

        var infinite = StageSettings()
        infinite.balanceDb = .infinity
        infinite.alignMs = .nan
        XCTAssertEqual(infinite.clamped().balanceDbValue, 0)
        XCTAssertEqual(infinite.clamped().alignMsValue, 0)
    }

    func testAnOutOfRangeTrimNeverReachesTheRenderPath() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        var wild = fullStage()
        wild.crossLowTrim = 1e9
        wild.balanceDb = 1e9
        wild.alignMs = 1e9
        p.applyStage(wild)

        let input = Buffers([(2, 512)])
        input.fill(0, Self.stereoNoise(frames: 512))
        let output = Buffers([(2, 512)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        XCTAssertTrue(output.samples(0, count: 1024).allSatisfy(\.isFinite))
        XCTAssertTrue(output.samples(0, count: 1024).allSatisfy { abs($0) <= 2 })
    }

    func testANewEpochWipesTheBandSplitAndTheAlignmentRing() {
        var s = fullStage()
        s.crossLowTrim = 1.6
        s.crossHighTrim = 0.2
        s.alignMs = 0.4
        s.balanceDb = -2

        let used = StageProcessor()
        used.prepare(sampleRate: 48000)
        used.applyStage(s)
        let loud = Buffers([(2, 1024)])
        loud.fill(0, (0..<2048).map { Float(sin(Double($0) * 0.07)) * 0.9 })
        let sink = Buffers([(2, 1024)])
        used.render(input: loud.constPointer, output: sink.list.unsafeMutablePointer)
        used.prepare(sampleRate: 48000)

        let quiet = Self.stereoNoise(frames: 512)
        let after = Buffers([(2, 512)])
        after.fill(0, quiet)
        let afterOut = Buffers([(2, 512)])
        used.render(input: after.constPointer, output: afterOut.list.unsafeMutablePointer)

        XCTAssertEqual(afterOut.samples(0, count: 1024), render(s, input: quiet))
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

    private func render(_ settings: StageSettings,
                        input samples: [Float]? = nil,
                        sampleRate: Double = 48000) -> [Float] {
        let data = samples ?? Self.stereoNoise(frames: 1024)
        let frames = data.count / 2
        let p = StageProcessor()
        p.prepare(sampleRate: sampleRate)
        p.applyStage(settings)
        let input = Buffers([(2, frames)])
        input.fill(0, data)
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        return output.samples(0, count: frames * 2)
    }

    private func tone(frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Float(sin(Double(i) * 0.11)) * 0.05
            out[i * 2] = v
            out[i * 2 + 1] = v
        }
        return out
    }

    private func impulse(frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        out[0] = 0.25
        out[1] = 0.25
        return out
    }

    private func rms(_ interleaved: [Float], channel: Int) -> Double {
        var sum = 0.0
        var n = 0
        var i = channel
        while i < interleaved.count {
            sum += Double(interleaved[i]) * Double(interleaved[i])
            n += 1
            i += 2
        }
        return n > 0 ? (sum / Double(n)).squareRoot() : 0
    }

    private func db(_ v: Double) -> Double { 20 * log10(max(v, 1e-12)) }

    private func sample(_ interleaved: [Float], channel: Int, at frame: Int) -> Float {
        interleaved[frame * 2 + channel]
    }

    private func onset(_ interleaved: [Float], channel: Int) -> Int {
        var i = channel
        var frame = 0
        while i < interleaved.count {
            if abs(interleaved[i]) > 1e-6 { return frame }
            frame += 1
            i += 2
        }
        return -1
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
