import Foundation

enum WavFixture {
    enum Encoding {
        case int16, int24, int32, float32
    }

    static func data(samples: [[Float]], rate: Double, encoding: Encoding = .float32,
                     extensible: Bool = false) -> Data {
        let channels = samples.count
        let frames = samples.first?.count ?? 0
        let width: Int
        switch encoding {
        case .int16: width = 2
        case .int24: width = 3
        case .int32, .float32: width = 4
        }
        var body = Data()
        for f in 0..<frames {
            for c in 0..<channels {
                let v = samples[c][f]
                switch encoding {
                case .int16:
                    let i = Int16(max(-32768, min(32767, (v * 32768).rounded())))
                    body.append(contentsOf: withUnsafeBytes(of: i.littleEndian) { Array($0) })
                case .int24:
                    let i = Int32(max(-8_388_608, min(8_388_607, (v * 8_388_608).rounded())))
                    let u = UInt32(bitPattern: i)
                    body.append(contentsOf: [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF),
                                             UInt8((u >> 16) & 0xFF)])
                case .int32:
                    let i = Int32(max(-2_147_483_648, min(2_147_483_647,
                                                           (Double(v) * 2_147_483_648).rounded())))
                    body.append(contentsOf: withUnsafeBytes(of: i.littleEndian) { Array($0) })
                case .float32:
                    body.append(contentsOf: withUnsafeBytes(of: v.bitPattern.littleEndian) {
                        Array($0)
                    })
                }
            }
        }
        let isFloat = encoding == .float32
        var format = Data()
        func put16(_ v: Int) { format.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func put32(_ v: Int) {
            format.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                                       UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
        }
        put16(extensible ? 0xFFFE : (isFloat ? 3 : 1))
        put16(channels)
        put32(Int(rate))
        put32(Int(rate) * channels * width)
        put16(channels * width)
        put16(width * 8)
        if extensible {
            put16(22)
            put16(width * 8)
            put32(channels == 1 ? 4 : 3)
            put16(isFloat ? 3 : 1)
            format.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00,
                                       0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        }
        var out = Data("RIFF".utf8)
        func le32(_ v: Int) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF),
             UInt8((v >> 24) & 0xFF)]
        }
        out.append(contentsOf: le32(4 + 8 + format.count + 8 + body.count))
        out.append(Data("WAVE".utf8))
        out.append(Data("fmt ".utf8))
        out.append(contentsOf: le32(format.count))
        out.append(format)
        out.append(Data("data".utf8))
        out.append(contentsOf: le32(body.count))
        out.append(body)
        return out
    }

    static func write(_ url: URL, samples: [Float], rate: Double = 48000,
                      channels: Int = 1, encoding: Encoding = .float32) throws {
        let wav = data(samples: Array(repeating: samples, count: channels), rate: rate,
                       encoding: encoding)
        try wav.write(to: url)
    }
}
