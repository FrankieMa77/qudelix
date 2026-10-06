import CoreAudio
import XCTest
@testable import QudelixBar

final class StageChannelMapTests: XCTestCase {
    private func run(tap tapChannels: Int, outputs: [Int], frames: Int = 16,
                     stage: Bool = false) -> [[Float]] {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        if stage {
            var s = StageSettings()
            s.enabled = true
            s.width = 100
            s.crossfeed = 0
            s.dialogue = 0
            s.room = 0
            s.distance = 0
            s.center = 0
            s.night = 0
            p.applyStage(s)
        }
        let input = Buffers([(tapChannels, frames)])
        var samples = [Float](repeating: 0, count: tapChannels * frames)
        for f in 0..<frames {
            for c in 0..<tapChannels { samples[f * tapChannels + c] = Float(c + 1) / 10 }
        }
        input.fill(0, samples)
        let output = Buffers(outputs.map { ($0, frames) })
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        return outputs.indices.map { output.samples($0, count: outputs[$0] * frames) }
    }

    private func frame(_ interleaved: [Float], channels: Int, at f: Int) -> [Float] {
        Array(interleaved[(f * channels)..<(f * channels + channels)])
    }

    func testAStereoTapOnAnEightChannelOutputFillsOnlyTheFrontPair() {
        for stage in [false, true] {
            let out = run(tap: 2, outputs: [8], stage: stage)
            let row = frame(out[0], channels: 8, at: 10)
            XCTAssertEqual(row[0], 0.1, accuracy: 1e-6)
            XCTAssertEqual(row[1], 0.2, accuracy: 1e-6)
            XCTAssertEqual(Array(row[2...]), [Float](repeating: 0, count: 6),
                           "the surround and centre channels must not carry the right channel")
        }
    }

    func testAStereoTapOnTwoStereoStreamsFeedsTheFirstOnly() {
        let out = run(tap: 2, outputs: [2, 2])
        XCTAssertEqual(frame(out[0], channels: 2, at: 5), [0.1, 0.2])
        XCTAssertEqual(frame(out[1], channels: 2, at: 5), [0, 0])
    }

    func testAStereoTapOnAMonoOutputIsMixedDownNotTruncated() {
        for stage in [false, true] {
            let out = run(tap: 2, outputs: [1], stage: stage)
            XCTAssertEqual(frame(out[0], channels: 1, at: 7)[0], 0.15, accuracy: 1e-6)
        }
    }

    func testAMonoTapStillFeedsEveryOutputChannel() {
        let stereo = run(tap: 1, outputs: [2])
        XCTAssertEqual(frame(stereo[0], channels: 2, at: 3), [0.1, 0.1])
        let wide = run(tap: 1, outputs: [8])
        XCTAssertEqual(frame(wide[0], channels: 8, at: 3), [Float](repeating: 0.1, count: 8))
    }

    func testChannelsMapOneToOneWhenTheTapHasAsManyAsTheOutput() {
        let out = run(tap: 4, outputs: [4])
        XCTAssertEqual(frame(out[0], channels: 4, at: 2), [0.1, 0.2, 0.3, 0.4])
        let narrower = run(tap: 4, outputs: [2])
        XCTAssertEqual(frame(narrower[0], channels: 2, at: 2), [0.1, 0.2])
        let wider = run(tap: 4, outputs: [6])
        XCTAssertEqual(frame(wider[0], channels: 6, at: 2), [0.1, 0.2, 0.3, 0.4, 0, 0])
    }

    func testSeparateMonoStreamsGetLeftThenRight() {
        let out = run(tap: 2, outputs: [1, 1])
        XCTAssertEqual(out[0][4], 0.1, accuracy: 1e-6)
        XCTAssertEqual(out[1][4], 0.2, accuracy: 1e-6)
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
