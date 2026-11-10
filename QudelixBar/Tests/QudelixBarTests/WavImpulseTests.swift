import XCTest
@testable import QudelixBar

final class WavImpulseTests: XCTestCase {
    private let ramp: [Float] = (0..<64).map { Float($0) / 64 - 0.5 }

    private func parse(_ data: Data) throws -> WavImpulse {
        try WavImpulse.parse(data)
    }

    private func refusal(_ data: Data) -> String? {
        do {
            _ = try WavImpulse.parse(data)
            return nil
        } catch {
            return (error as? ImpulseError)?.message
        }
    }

    func testEveryEncodingDecodesWithinItsOwnResolution() throws {
        let cases: [(WavFixture.Encoding, Float)] = [(.int16, 1.0 / 32768), (.int24, 1.0 / 8_388_608),
                                                      (.int32, 1e-6), (.float32, 0)]
        for (encoding, tolerance) in cases {
            for extensible in [false, true] {
                let wav = try parse(WavFixture.data(samples: [ramp], rate: 44100,
                                                    encoding: encoding, extensible: extensible))
                XCTAssertEqual(wav.channelCount, 1)
                XCTAssertEqual(wav.sampleRate, 44100)
                XCTAssertEqual(wav.frameCount, 64)
                let channels = try wav.readChannels()
                XCTAssertEqual(channels.count, 1)
                for i in 0..<64 {
                    XCTAssertEqual(channels[0][i], ramp[i], accuracy: tolerance + 1e-7,
                                   "\(encoding) extensible=\(extensible) sample \(i)")
                }
            }
        }
    }

    func testStereoKeepsTheChannelsApart() throws {
        let right = ramp.map { -$0 }
        let wav = try parse(WavFixture.data(samples: [ramp, right], rate: 96000,
                                            encoding: .int24))
        XCTAssertEqual(wav.channelCount, 2)
        XCTAssertEqual(wav.sampleRate, 96000)
        let channels = try wav.readChannels()
        for i in 0..<64 {
            XCTAssertEqual(channels[0][i], ramp[i], accuracy: 1e-6)
            XCTAssertEqual(channels[1][i], right[i], accuracy: 1e-6)
        }
    }

    func testFloatNaNsSurviveSoTheLibraryCanCountThem() throws {
        var samples = ramp
        samples[3] = .nan
        let channels = try parse(WavFixture.data(samples: [samples], rate: 48000)).readChannels()
        XCTAssertTrue(channels[0][3].isNaN)
    }

    func testUnknownChunksAreSkipped() throws {
        var wav = WavFixture.data(samples: [ramp], rate: 48000, encoding: .int16)
        var extra = Data("LIST".utf8)
        extra.append(contentsOf: [3, 0, 0, 0, 1, 2, 3, 0])
        wav.insert(contentsOf: extra, at: 12)
        let parsed = try parse(wav)
        XCTAssertEqual(parsed.frameCount, 64)
    }

    func testATruncatedDataChunkYieldsTheFramesThatAreThere() throws {
        var wav = WavFixture.data(samples: [ramp], rate: 48000, encoding: .int16)
        wav.removeLast(20)
        XCTAssertEqual(try parse(wav).frameCount, 54)
    }

    func testRefusalsSayWhatTheFileIs() {
        let good = WavFixture.data(samples: [ramp], rate: 48000, encoding: .int16)
        XCTAssertTrue(refusal(Data("nope".utf8))?.contains("too short") ?? false)
        XCTAssertTrue(refusal(Data("RIFX".utf8 + [UInt8](repeating: 0, count: 20)))?
            .contains("big-endian") ?? false)
        XCTAssertTrue(refusal(Data("RF64".utf8 + [UInt8](repeating: 0, count: 20)))?
            .contains("RF64") ?? false)
        XCTAssertTrue(refusal(Data("FORM".utf8 + [UInt8](repeating: 0, count: 20)))?
            .contains("AIFF") ?? false)
        XCTAssertTrue(refusal(Data("ABCD".utf8 + [UInt8](repeating: 0, count: 20)))?
            .contains("isn't a WAV") ?? false)

        var noData = good
        noData.replaceSubrange(36..<40, with: Data("junk".utf8))
        XCTAssertTrue(refusal(noData)?.contains("no audio data") ?? false)

        var adpcm = good
        adpcm[20] = 2
        XCTAssertTrue(refusal(adpcm)?.contains("ADPCM") ?? false)

        var alaw = good
        alaw[20] = 6
        XCTAssertTrue(refusal(alaw)?.contains("companded") ?? false)

        var eightBit = good
        eightBit[34] = 8
        XCTAssertTrue(refusal(eightBit)?.contains("8-bit PCM") ?? false)

        var double = WavFixture.data(samples: [ramp], rate: 48000, encoding: .float32)
        double[34] = 64
        XCTAssertTrue(refusal(double)?.contains("64-bit float") ?? false)

        var misaligned = good
        misaligned[32] = 3
        XCTAssertTrue(refusal(misaligned)?.contains("block size") ?? false)

        var zeroRate = good
        for i in 24..<28 { zeroRate[i] = 0 }
        XCTAssertTrue(refusal(zeroRate)?.contains("no sample rate") ?? false)

        var noChannels = good
        noChannels[22] = 0
        XCTAssertTrue(refusal(noChannels)?.contains("no channels") ?? false)
    }

    func testEveryRefusalNamesTheSupportedFormats() {
        let message = refusal(Data("RIFX".utf8 + [UInt8](repeating: 0, count: 20))) ?? ""
        XCTAssertTrue(message.contains("PCM 16, 24 or 32-bit integer, or 32-bit float"))
        XCTAssertTrue(message.contains("mono or stereo"))
    }

    func testMoreThanTwoChannelsParseSoTheLibraryCanRefuseThem() throws {
        let wav = try parse(WavFixture.data(samples: [ramp, ramp, ramp], rate: 48000,
                                            encoding: .int16))
        XCTAssertEqual(wav.channelCount, 3)
    }
}
