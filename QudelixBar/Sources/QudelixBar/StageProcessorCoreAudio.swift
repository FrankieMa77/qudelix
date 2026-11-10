import CoreAudio
import Foundation

extension StageBufferList {
    init(_ list: UnsafePointer<AudioBufferList>) {
        let raw = UnsafeMutableRawPointer(mutating: list)
        let offset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers) ?? 0
        self.init(base: (raw + offset).assumingMemoryBound(to: StageBuffer.self),
                  count: Int(list.pointee.mNumberBuffers))
    }

    static var matchesCoreAudioLayout: Bool {
        MemoryLayout<StageBuffer>.size == MemoryLayout<AudioBuffer>.size
            && MemoryLayout<StageBuffer>.stride == MemoryLayout<AudioBuffer>.stride
            && MemoryLayout<StageBuffer>.alignment == MemoryLayout<AudioBuffer>.alignment
            && MemoryLayout<StageBuffer>.offset(of: \StageBuffer.channels)
                == MemoryLayout<AudioBuffer>.offset(of: \AudioBuffer.mNumberChannels)
            && MemoryLayout<StageBuffer>.offset(of: \StageBuffer.byteSize)
                == MemoryLayout<AudioBuffer>.offset(of: \AudioBuffer.mDataByteSize)
            && MemoryLayout<StageBuffer>.offset(of: \StageBuffer.data)
                == MemoryLayout<AudioBuffer>.offset(of: \AudioBuffer.mData)
    }
}

extension StageProcessor {
    func render(input: UnsafePointer<AudioBufferList>,
                output: UnsafeMutablePointer<AudioBufferList>) {
        render(input: StageBufferList(input), output: StageBufferList(output))
    }
}
