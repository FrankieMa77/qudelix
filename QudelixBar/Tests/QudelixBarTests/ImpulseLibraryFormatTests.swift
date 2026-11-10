import XCTest
@testable import QudelixBar

final class ImpulseLibraryFormatTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("impulse-format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func ramp(_ count: Int) -> [Float] {
        (0..<count).map { Float(sin(Double($0) * 0.3)) * Float(exp(-Double($0) / 200)) * 0.8 }
    }

    func testEveryPcmWidthInstallsAndLoadsMono() throws {
        for (index, encoding) in [WavFixture.Encoding.int16, .int24, .int32, .float32].enumerated() {
            let url = scratch.appendingPathComponent("mono\(index).wav")
            try WavFixture.write(url, samples: ramp(1024), rate: 44100, encoding: encoding)
            let response = try IRLibrary.install(source: url, into: scratch)
            XCTAssertEqual(response.sourceChannels, 1)
            XCTAssertEqual(response.sourceRate, 44100)
            XCTAssertEqual(response.sourceFrames, 1024)
            for i in 0..<1024 {
                XCTAssertEqual(response.channels[0][i], ramp(1024)[i], accuracy: 1e-4)
            }
        }
    }

    func testStereoInstallsWithBothSides() throws {
        let url = scratch.appendingPathComponent("stereo.wav")
        let left = ramp(512)
        let right = left.map { -$0 }
        try WavFixture.data(samples: [left, right], rate: 96000, encoding: .int24).write(to: url)
        let response = try IRLibrary.install(source: url, into: scratch)
        XCTAssertTrue(response.isStereo)
        XCTAssertEqual(response.sourceRate, 96000)
        XCTAssertEqual(response.channels[1][5], right[5], accuracy: 1e-4)
    }

    func testThreeChannelsAreRefusedWithTheCount() throws {
        let url = scratch.appendingPathComponent("three.wav")
        try WavFixture.data(samples: [ramp(256), ramp(256), ramp(256)], rate: 48000,
                            encoding: .int16).write(to: url)
        XCTAssertThrowsError(try IRLibrary.install(source: url, into: scratch)) {
            XCTAssertTrue(($0 as? ImpulseError)?.message.contains("3 channels") ?? false, "\($0)")
        }
    }

    func testAnImplausibleRateIsRefused() throws {
        let url = scratch.appendingPathComponent("slow.wav")
        try WavFixture.write(url, samples: ramp(256), rate: 4000)
        XCTAssertThrowsError(try IRLibrary.install(source: url, into: scratch)) {
            XCTAssertTrue(($0 as? ImpulseError)?.message.contains("sample rate") ?? false, "\($0)")
        }
    }

    func testAnAllNaNFileIsRefused() throws {
        let url = scratch.appendingPathComponent("nan.wav")
        try WavFixture.write(url, samples: [Float](repeating: .nan, count: 256))
        XCTAssertThrowsError(try IRLibrary.install(source: url, into: scratch)) {
            XCTAssertTrue(($0 as? ImpulseError)?.message.contains("NaN") ?? false, "\($0)")
        }
    }

    func testAFileThatIsNotAudioIsRefusedWithAReason() throws {
        let url = scratch.appendingPathComponent("junk.wav")
        try Data(repeating: 0x41, count: 4096).write(to: url)
        XCTAssertThrowsError(try IRLibrary.install(source: url, into: scratch)) {
            XCTAssertNotNil(($0 as? ImpulseError)?.message, "\($0)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path),
                       ["junk.wav"])
    }
}
