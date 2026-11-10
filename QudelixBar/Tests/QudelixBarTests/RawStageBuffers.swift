import Foundation
@testable import QudelixBar

final class RawStageBuffers {
    private let storage: UnsafeMutablePointer<StageBuffer>
    private var blocks: [UnsafeMutablePointer<Float>] = []
    let count: Int
    let layout: [(channels: Int, frames: Int)]

    init(_ layout: [(channels: Int, frames: Int)]) {
        self.layout = layout
        count = layout.count
        storage = UnsafeMutablePointer<StageBuffer>.allocate(capacity: max(1, layout.count))
        for (i, entry) in layout.enumerated() {
            let n = entry.channels * entry.frames
            let block = UnsafeMutablePointer<Float>.allocate(capacity: max(1, n))
            block.initialize(repeating: 0, count: max(1, n))
            blocks.append(block)
            (storage + i).initialize(to: StageBuffer(
                channels: UInt32(entry.channels),
                byteSize: UInt32(n * MemoryLayout<Float>.size),
                data: UnsafeMutableRawPointer(block)))
        }
    }

    deinit {
        for block in blocks { block.deallocate() }
        storage.deallocate()
    }

    var list: StageBufferList { StageBufferList(base: storage, count: count) }

    func fill(_ index: Int, _ values: [Float]) {
        for (i, v) in values.enumerated() { blocks[index][i] = v }
    }

    func samples(_ index: Int, count: Int) -> [Float] {
        (0..<count).map { blocks[index][$0] }
    }
}
