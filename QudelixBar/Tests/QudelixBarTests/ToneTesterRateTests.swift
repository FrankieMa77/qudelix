import AVFoundation
import XCTest
@testable import QudelixBar

@MainActor
final class ToneTesterRateTests: XCTestCase {
    private func renderOffline(rate: Double, hz: Double, ms: Int)
        throws -> (samples: [Float], scheduledFrames: Int, tester: ToneTester) {
        let engine = AVAudioEngine()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate,
                                                 channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4096)
        let tester = ToneTester(engine: engine)
        tester.startEngine()
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(tester.sampleRate, rate)

        let buffer = try XCTUnwrap(tester.buffer(hz: hz, dbfs: -20, ms: ms,
                                                 pulses: 1, gapMs: 0))
        tester.player.scheduleBuffer(buffer, at: nil, options: [],
                                     completionHandler: nil)
        tester.player.play()

        let scheduled = Int(buffer.frameLength)
        let total = scheduled + Int(rate * 0.2)
        let chunk = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                   frameCapacity: 4096))
        var samples = [Float]()
        while samples.count < total {
            let status = try engine.renderOffline(4096, to: chunk)
            guard status == .success else { break }
            let data = try XCTUnwrap(chunk.floatChannelData)
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0],
                                                           count: Int(chunk.frameLength)))
        }
        engine.stop()
        return (samples, scheduled, tester)
    }

    private func zeroCrossingHz(_ samples: [Float], rate: Double, from: Int,
                                to: Int) -> Double {
        var crossings = 0
        var first = -1
        var last = -1
        for i in (from + 1)..<to where samples[i - 1] <= 0 && samples[i] > 0 {
            if first < 0 { first = i }
            last = i
            crossings += 1
        }
        guard crossings > 1 else { return 0 }
        return Double(crossings - 1) * rate / Double(last - first)
    }

    func testEveryToneIsAtItsNamedFrequencyWhateverTheOutputRate() throws {
        for rate in [44100.0, 48000.0, 96000.0] {
            for hz in [250.0, 1000.0, 4000.0] {
                let ms = 300
                let r = try renderOffline(rate: rate, hz: hz, ms: ms)
                let from = Int(0.06 * rate)
                let to = Int(0.24 * rate)
                let measured = zeroCrossingHz(r.samples, rate: rate, from: from, to: to)
                XCTAssertEqual(measured, hz, accuracy: hz * 0.01,
                               "\(hz) Hz asked for at \(rate) Hz played as \(measured)")
            }
        }
    }

    func testThePlayerRunsAtTheDeviceRateAndTheToneKeepsItsLength() throws {
        for rate in [44100.0, 48000.0, 96000.0] {
            let r = try renderOffline(rate: rate, hz: 1000, ms: 200)
            let output = r.tester.player.outputFormat(forBus: 0)
            XCTAssertEqual(output.sampleRate, rate)
            XCTAssertEqual(r.scheduledFrames, Int(0.2 * rate))
            var lastAudible = 0
            for (i, v) in r.samples.enumerated() where abs(v) > 1e-4 { lastAudible = i }
            XCTAssertEqual(Double(lastAudible), Double(r.scheduledFrames),
                           accuracy: rate * 0.002,
                           "the tone must last as long as it was built to at \(rate) Hz")
        }
    }
}
