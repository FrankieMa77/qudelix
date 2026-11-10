import Foundation

struct StageBuffer {
    var channels: UInt32
    var byteSize: UInt32
    var data: UnsafeMutableRawPointer?

    init(channels: UInt32, byteSize: UInt32, data: UnsafeMutableRawPointer?) {
        self.channels = channels
        self.byteSize = byteSize
        self.data = data
    }
}

struct StageBufferList: RandomAccessCollection {
    private let base: UnsafeMutablePointer<StageBuffer>?
    let count: Int

    init(base: UnsafeMutablePointer<StageBuffer>?, count: Int) {
        self.base = base
        self.count = base == nil ? 0 : Swift.max(0, count)
    }

    var startIndex: Int { 0 }
    var endIndex: Int { count }

    subscript(index: Int) -> StageBuffer { base![index] }
}
