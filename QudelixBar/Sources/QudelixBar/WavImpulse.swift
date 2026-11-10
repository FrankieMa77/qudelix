import Foundation

struct WavImpulse: ImpulseAudioSource {
    enum Encoding: Equatable {
        case int16, int24, int32, float32

        var bytesPerSample: Int {
            switch self {
            case .int16: return 2
            case .int24: return 3
            case .int32, .float32: return 4
            }
        }
    }

    let channelCount: Int
    let sampleRate: Double
    let frameCount: Int64
    let encoding: Encoding
    private let data: Data
    private let dataStart: Int

    static let supportedText = "PCM 16, 24 or 32-bit integer, or 32-bit float"

    private static func refusal(_ reason: String) -> ImpulseError {
        ImpulseError(message: reason + " This build reads WAV impulse responses "
            + "(\(supportedText)), mono or stereo.")
    }

    private static func u16(_ d: Data, _ at: Int) -> Int {
        Int(d[d.startIndex + at]) | Int(d[d.startIndex + at + 1]) << 8
    }

    private static func u32(_ d: Data, _ at: Int) -> Int {
        u16(d, at) | u16(d, at + 2) << 16
    }

    static func parse(_ data: Data) throws -> WavImpulse {
        guard data.count >= 12 else {
            throw refusal("That file is too short to be a WAV file.")
        }
        let tag = String(decoding: data.prefix(4), as: UTF8.self)
        switch tag {
        case "RIFF": break
        case "RF64", "BW64":
            throw refusal("That is an RF64 WAV file.")
        case "RIFX":
            throw refusal("That is a big-endian WAV file.")
        case "FORM":
            throw refusal("That is an AIFF file.")
        default:
            throw refusal("That file isn't a WAV file.")
        }
        guard String(decoding: data[(data.startIndex + 8)..<(data.startIndex + 12)],
                     as: UTF8.self) == "WAVE" else {
            throw refusal("That file isn't a WAV file.")
        }

        var formatTag = 0
        var channels = 0
        var rate = 0
        var blockAlign = 0
        var bits = 0
        var haveFormat = false
        var dataRange: Range<Int>?
        var cursor = 12
        while cursor + 8 <= data.count {
            let id = String(decoding: data[(data.startIndex + cursor)..<(data.startIndex + cursor + 4)],
                            as: UTF8.self)
            let declared = u32(data, cursor + 4)
            let body = cursor + 8
            switch id {
            case "fmt ":
                guard declared >= 16, body + 16 <= data.count else {
                    throw refusal("That WAV file's format block is damaged.")
                }
                formatTag = u16(data, body)
                channels = u16(data, body + 2)
                rate = u32(data, body + 4)
                blockAlign = u16(data, body + 12)
                bits = u16(data, body + 14)
                if formatTag == 0xFFFE {
                    guard declared >= 40, body + 26 <= data.count else {
                        throw refusal("That WAV file's format block is damaged.")
                    }
                    formatTag = u16(data, body + 24)
                }
                haveFormat = true
            case "data":
                let available = data.count - body
                let size = declared == 0xFFFF_FFFF || declared > available ? available : declared
                dataRange = body..<(body + size)
            default:
                break
            }
            if dataRange != nil, haveFormat { break }
            cursor = body + declared + (declared & 1)
        }
        guard haveFormat else { throw refusal("That WAV file has no format block.") }
        guard let dataRange else { throw refusal("That WAV file has no audio data.") }
        guard channels >= 1 else { throw refusal("That WAV file has no channels.") }
        guard rate > 0 else { throw refusal("That WAV file has no sample rate.") }

        let encoding: Encoding
        switch (formatTag, bits) {
        case (1, 16): encoding = .int16
        case (1, 24): encoding = .int24
        case (1, 32): encoding = .int32
        case (3, 32): encoding = .float32
        case (1, _), (3, _):
            throw refusal("That WAV file is \(bits)-bit \(formatTag == 3 ? "float" : "PCM").")
        case (2, _), (17, _):
            throw refusal("That WAV file is ADPCM.")
        case (6, _), (7, _):
            throw refusal("That WAV file is companded (A-law or mu-law).")
        case (0x55, _):
            throw refusal("That WAV file is MP3-encoded.")
        default:
            throw refusal("That WAV file uses an unsupported encoding (code \(formatTag)).")
        }
        let frameBytes = channels * encoding.bytesPerSample
        guard blockAlign == frameBytes else {
            throw refusal("That WAV file's block size doesn't match its format.")
        }
        return WavImpulse(channelCount: channels, sampleRate: Double(rate),
                          frameCount: Int64(dataRange.count / frameBytes), encoding: encoding,
                          data: data, dataStart: dataRange.lowerBound)
    }

    func readChannels() throws -> [[Float]] {
        let frames = Int(frameCount)
        guard frames > 0 else {
            throw ImpulseError(message: "That WAV file has no audio in it.")
        }
        let width = encoding.bytesPerSample
        let stride = channelCount * width
        var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channelCount)
        data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress! + dataStart
            for f in 0..<frames {
                for c in 0..<channelCount {
                    let p = base + f * stride + c * width
                    switch encoding {
                    case .int16:
                        let v = Int16(bitPattern: UInt16(p[0]) | UInt16(p[1]) << 8)
                        out[c][f] = Float(v) / 32768
                    case .int24:
                        let raw24 = Int32(p[0]) | Int32(p[1]) << 8 | Int32(p[2]) << 16
                        let v = (raw24 << 8) >> 8
                        out[c][f] = Float(v) / 8_388_608
                    case .int32:
                        let bits32 = UInt32(p[0]) | UInt32(p[1]) << 8
                            | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
                        out[c][f] = Float(Int32(bitPattern: bits32)) / 2_147_483_648
                    case .float32:
                        let bits32 = UInt32(p[0]) | UInt32(p[1]) << 8
                            | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
                        out[c][f] = Float(bitPattern: bits32)
                    }
                }
            }
        }
        return out
    }
}
