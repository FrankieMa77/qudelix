import AVFoundation
import Foundation

private struct AVImpulseSource: ImpulseAudioSource {
    let file: AVAudioFile

    var channelCount: Int { Int(file.processingFormat.channelCount) }
    var sampleRate: Double { file.processingFormat.sampleRate }
    var frameCount: Int64 { file.length }

    func readChannels() throws -> [[Float]] {
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              buffer.frameLength > 0,
              let raw = buffer.floatChannelData else {
            throw ImpulseError(message: "macOS read that file but produced no "
                + "audio from it.")
        }
        let read = Int(buffer.frameLength)
        var decoded: [[Float]] = []
        for c in 0..<channels {
            var samples = [Float](repeating: 0, count: read)
            samples.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: raw[c], count: read)
            }
            decoded.append(samples)
        }
        return decoded
    }
}

extension ImpulseAudio {
    static func open(url: URL, bytes: Data) throws -> ImpulseAudioSource {
        do {
            return AVImpulseSource(file: try AVAudioFile(forReading: url))
        } catch {
            throw ImpulseError(message: "macOS couldn't read that as audio. "
                + "Impulse responses are WAV, AIFF or CAF files.")
        }
    }
}
