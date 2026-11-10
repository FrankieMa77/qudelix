import CoreAudio
import XCTest
@testable import QudelixBar

final class StageBufferLayoutTests: XCTestCase {
    func testTheBufferStructMirrorsTheCoreAudioBuffer() {
        XCTAssertTrue(StageBufferList.matchesCoreAudioLayout)
    }

    func testTheAdapterSeesEveryBufferOfTheList() {
        let list = Buffers([(1, 8), (2, 8), (2, 4)])
        list.fill(1, (0..<16).map(Float.init))
        let view = StageBufferList(list.constPointer)
        XCTAssertEqual(view.count, 3)
        XCTAssertEqual(view[0].channels, 1)
        XCTAssertEqual(view[1].channels, 2)
        XCTAssertEqual(view[1].byteSize, UInt32(16 * MemoryLayout<Float>.size))
        XCTAssertEqual(view[2].byteSize, UInt32(8 * MemoryLayout<Float>.size))
        let data = view[1].data!.assumingMemoryBound(to: Float.self)
        XCTAssertEqual(data[5], 5)
    }

    func testTheAudioBufferListEntryAndTheRawEntryRenderIdentically() {
        let frames = 512
        let source = (0..<(frames * 2)).map { Float(sin(Double($0 / 2) * 0.04)) * 0.4 }

        var settings = StageSettings()
        settings.enabled = true
        settings.crossfeed = 0.6
        settings.room = 30

        let viaList = StageProcessor()
        viaList.prepare(sampleRate: 48000)
        viaList.applyStage(settings)
        let input = Buffers([(2, frames)])
        input.fill(0, source)
        let output = Buffers([(2, frames)])
        viaList.render(input: input.constPointer, output: output.list.unsafeMutablePointer)

        let viaRaw = StageProcessor()
        viaRaw.prepare(sampleRate: 48000)
        viaRaw.applyStage(settings)
        let rawInput = RawStageBuffers([(2, frames)])
        rawInput.fill(0, source)
        let rawOutput = RawStageBuffers([(2, frames)])
        viaRaw.render(input: rawInput.list, output: rawOutput.list)

        XCTAssertEqual(output.samples(0, count: frames * 2),
                       rawOutput.samples(0, count: frames * 2))
        XCTAssertNotEqual(rawOutput.samples(0, count: frames * 2), source)
    }
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
        (0..<count).map { blocks[buffer][$0] }
    }
}
