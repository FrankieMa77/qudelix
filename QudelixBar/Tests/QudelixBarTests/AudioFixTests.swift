import CoreAudio
import XCTest
@testable import QudelixBar

final class AudioFixTests: XCTestCase {
    private func entry(_ id: String, _ objects: [AudioObjectID]) -> StageEngine.AppTapEntry {
        StageEngine.AppTapEntry(bundleID: id, objects: objects,
                                chain: AppCurve(bundleID: id, preGain: 0, bands: []))
    }

    func testAFailedTapDoesNotMakeTheActivePlanLookStale() {
        let plan = [entry("com.a", [1]), entry("com.b", [2])]
        let active = [entry("com.a", [1])]
        XCTAssertFalse(StageEngine.sameTaps(active, plan))
        let reachable = StageEngine.reachablePlan(plan, failed: ["com.b"])
        XCTAssertTrue(StageEngine.sameTaps(active, reachable))
        XCTAssertEqual(StageEngine.reachablePlan(plan, failed: []), plan)
    }

    func testPerAppSectionsMatchTheDrawnCurve() {
        let cases: [(Int, Double, Double)] = [
            (10000, 6, 1), (14000, -9, 1), (16000, 8, 1), (6000, 7, 0.5),
            (3000, -5, 0.5), (200, 6, 1.2),
        ]
        let probes = (0..<60).map { 20 * pow(1000.0, Double($0) / 59) }
        for (freq, gain, q) in cases {
            let band = QxEqBandValue(filter: .peak, freq: freq, gain: gain, q: q)
            let drawn = EQCurve.response(bands: [band], preGain: 0, at: probes)
            let section = StageProcessor.appSection(band, sampleRate: EQCurve.sampleRate)
            XCTAssertNotNil(section)
            for (hz, expected) in zip(probes, drawn) {
                let heard = section?.magnitudeDb(at: hz, sampleRate: EQCurve.sampleRate) ?? .nan
                XCTAssertEqual(heard, expected, accuracy: 0.1,
                               "\(freq) Hz \(gain) dB Q \(q) at \(hz) Hz")
            }
        }
    }

    func testAPerAppBufferLongerThanTheOldScratchHasNoZeroedTail() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyAppChains([AppCurve(bundleID: "com.a", preGain: 0, bands: []),
                          AppCurve(bundleID: "com.b", preGain: 0, bands: [])])
        let frames = 20000
        let shapes = [(2, frames), (2, frames), (2, frames)]
        let blocks = shapes.map { shape -> UnsafeMutablePointer<Float> in
            let b = UnsafeMutablePointer<Float>.allocate(capacity: shape.0 * shape.1)
            b.initialize(repeating: 0.1, count: shape.0 * shape.1)
            return b
        }
        let outBlock = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        outBlock.initialize(repeating: 0, count: frames * 2)
        defer {
            blocks.forEach { $0.deallocate() }
            outBlock.deallocate()
        }
        let input = AudioBufferList.allocate(maximumBuffers: 3)
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        defer {
            free(input.unsafeMutablePointer)
            free(output.unsafeMutablePointer)
        }
        for (i, b) in blocks.enumerated() {
            input[i] = AudioBuffer(mNumberChannels: 2,
                                   mDataByteSize: UInt32(frames * 2 * 4),
                                   mData: UnsafeMutableRawPointer(b))
        }
        output[0] = AudioBuffer(mNumberChannels: 2,
                                mDataByteSize: UInt32(frames * 2 * 4),
                                mData: UnsafeMutableRawPointer(outBlock))
        p.render(input: UnsafePointer(input.unsafeMutablePointer),
                 output: output.unsafeMutablePointer)
        for f in [0, 8191, 8192, 12000, frames - 1] {
            XCTAssertEqual(outBlock[f * 2], 0.3, accuracy: 1e-4, "frame \(f)")
            XCTAssertEqual(outBlock[f * 2 + 1], 0.3, accuracy: 1e-4, "frame \(f)")
        }
    }

    func testABluetoothOutputIsNeverSetToACallModeRate() {
        XCTAssertFalse(AudioOutputs.rateChangeAllowed(bluetooth: true, rate: 16000))
        XCTAssertFalse(AudioOutputs.rateChangeAllowed(bluetooth: true, rate: 8000))
        XCTAssertTrue(AudioOutputs.rateChangeAllowed(bluetooth: true, rate: 44100))
        XCTAssertTrue(AudioOutputs.rateChangeAllowed(bluetooth: false, rate: 16000))
        XCTAssertTrue(AudioOutputs.rateChangeAllowed(bluetooth: false, rate: 48000))
    }
}
