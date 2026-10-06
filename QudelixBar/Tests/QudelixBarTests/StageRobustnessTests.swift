import CoreAudio
import XCTest
@testable import QudelixBar

final class StageRobustnessTests: XCTestCase {
    private static let block = 256

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

    private static func music(_ frame: Int) -> (Float, Float) {
        let t = Double(frame)
        let l = 0.25 * sin(t * 0.031) + 0.1 * sin(t * 0.37)
        let r = 0.25 * sin(t * 0.029 + 0.5) + 0.1 * sin(t * 0.41)
        return (Float(l), Float(r))
    }

    private static func renderBlocks(_ p: StageProcessor, blocks: Int,
                                     spikeAt: Int? = nil, spike: Float = 0,
                                     spikeFrames: Int = 4) -> [[Float]] {
        var out = [[Float]]()
        for b in 0..<blocks {
            let input = Buffers([(2, block)])
            var samples = [Float](repeating: 0, count: block * 2)
            for f in 0..<block {
                let (l, r) = music(b * block + f)
                samples[f * 2] = l
                samples[f * 2 + 1] = r
            }
            if let spikeAt, b == spikeAt {
                for f in 10..<(10 + spikeFrames) {
                    samples[f * 2] = spike
                    samples[f * 2 + 1] = spike
                }
            }
            input.fill(0, samples)
            let output = Buffers([(2, block)])
            p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
            out.append(output.samples(0, count: block * 2))
        }
        return out
    }

    private static func rms(_ blocks: ArraySlice<[Float]>) -> Double {
        var sum = 0.0
        var n = 0
        for b in blocks { for v in b { sum += Double(v) * Double(v); n += 1 } }
        return (sum / Double(max(n, 1))).squareRoot()
    }

    private func stage() -> StageProcessor {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyStage(Self.fullStage())
        return p
    }

    func testAHugeFiniteSpikeDoesNotRingTheRoomForSeconds() {
        let clean = Self.renderBlocks(stage(), blocks: 60)
        for spike in [Float(1e20), 1e30, 3e38, -1e25] {
            let hit = Self.renderBlocks(stage(), blocks: 60, spikeAt: 10, spike: spike)
            XCTAssertTrue(hit.allSatisfy { $0.allSatisfy(\.isFinite) })
            let cleanTail = Self.rms(clean[20..<60])
            let hitTail = Self.rms(hit[20..<60])
            XCTAssertEqual(hitTail, cleanTail, accuracy: cleanTail * 0.05, "spike \(spike)")
            XCTAssertGreaterThan(hitTail, 0.02, "the stage must not go silent after \(spike)")
        }
    }

    func testTheSaneRangeEndsWhereTheScrubSays() {
        for (value, expected) in [(Float(64), Float(1)), (65, 0), (-64, -1), (-65, 0),
                                  (.nan, 0), (.infinity, 0), (-.infinity, 0)] {
            var s = StageSettings()
            s.enabled = true
            s.width = 100
            s.crossfeed = 0
            s.dialogue = 0
            s.room = 0
            s.distance = 0
            s.center = 0
            s.night = 0
            let p = StageProcessor()
            p.prepare(sampleRate: 48000)
            p.applyStage(s)
            let input = Buffers([(2, 64)])
            input.fill(0, [Float](repeating: value, count: 128))
            let output = Buffers([(2, 64)])
            p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
            let last = output.samples(0, count: 128)[126]
            XCTAssertEqual(last, expected, accuracy: 1e-5, "input \(value)")
        }
    }

    func testAHugeSampleInAnAppStreamIsDroppedAtTheDoor() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyAppChains([
            AppCurve(bundleID: "com.a", preGain: 0, bands: [
                QxEqBandValue(filter: .peak, freq: 1000, gain: 6, q: 1)]),
            AppCurve(bundleID: "com.b", preGain: 0, bands: []),
        ])
        let frames = 128
        let input = Buffers([(2, frames), (2, frames), (2, frames)])
        var clean = [Float](repeating: 0.1, count: frames * 2)
        input.fill(1, clean)
        input.fill(2, clean)
        clean[40] = 1e30
        clean[41] = 1e30
        input.fill(0, clean)
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        let out = output.samples(0, count: frames * 2)
        XCTAssertTrue(out.allSatisfy { $0.isFinite && abs($0) < 4 })

        let wild = Buffers([(2, frames), (2, frames), (2, frames)])
        var spiky = [Float](repeating: 0.1, count: frames * 2)
        spiky[40] = 1e30
        wild.fill(0, [Float](repeating: 0.1, count: frames * 2))
        wild.fill(1, spiky)
        wild.fill(2, [Float](repeating: 0.1, count: frames * 2))
        p.render(input: wild.constPointer, output: output.list.unsafeMutablePointer)
        let after = output.samples(0, count: frames * 2)
        XCTAssertTrue(after.allSatisfy { $0.isFinite && abs($0) < 4 })
    }

    #if DEBUG
    func testANonFiniteStateInsideTheStageIsWipedNotLeftToSilenceItForever() {
        let p = stage()
        let before = Self.renderBlocks(p, blocks: 20)
        let resets = p.stageResetCount
        p.poisonStageStateForTesting()
        let after = Self.renderBlocks(p, blocks: 20)
        XCTAssertEqual(p.stageResetCount, resets + 1)
        XCTAssertTrue(after.allSatisfy { $0.allSatisfy(\.isFinite) })
        XCTAssertGreaterThan(Self.rms(after[5..<20]), Self.rms(before[5..<20]) * 0.5,
                             "the stage must come back, not stay at zero")
    }
    #endif

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
