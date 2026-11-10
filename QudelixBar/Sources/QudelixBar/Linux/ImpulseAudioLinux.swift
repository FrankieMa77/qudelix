#if os(Linux)
import Foundation

extension ImpulseAudio {
    static func open(url: URL, bytes: Data) throws -> ImpulseAudioSource {
        try WavImpulse.parse(bytes)
    }
}
#endif
