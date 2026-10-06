import CoreAudio
import XCTest
@testable import QudelixBar

final class PerAppCeilingTests: XCTestCase {
    private func render(curves: [AppCurve], stage: StageSettings? = nil,
                        amplitude: Double, hz: Double = 100,
                        frames: Int = 4800) -> [Float] {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        if let stage { p.applyStage(stage) }
        p.applyAppChains(curves)
        let streams = curves.count + 1
        let input = Buffers((0..<streams).map { _ in (2, frames) })
        var tone = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Float(amplitude * sin(2 * .pi * hz * Double(i) / 48000))
            tone[i * 2] = v
            tone[i * 2 + 1] = v
        }
        input.fill(0, tone)
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        return output.samples(0, count: frames * 2)
    }

    private func boost(_ gain: Double, preGain: Double = 0) -> [AppCurve] {
        [AppCurve(bundleID: "com.test.app", preGain: preGain, bands: [
            QxEqBandValue(filter: .peak, freq: 100, gain: gain, q: 1)])]
    }

    private func peak(_ samples: [Float]) -> Float { samples.map { abs($0) }.max() ?? 0 }

    func testABoostWithTheStageOffNeverLeavesAboveFullScale() {
        let out = render(curves: boost(12), amplitude: 1)
        XCTAssertLessThanOrEqual(peak(out), 1)
        XCTAssertGreaterThan(peak(out), 0.97, "the boost still gets as loud as the ceiling")
        XCTAssertTrue(out.allSatisfy(\.isFinite))
    }

    func testAMaximumPreGainWithTheStageOffNeverLeavesAboveFullScale() {
        let out = render(curves: boost(0, preGain: 24), amplitude: 0.5)
        XCTAssertLessThanOrEqual(peak(out), 1)
        XCTAssertGreaterThan(peak(out), 0.97)
    }

    func testEverythingBelowTheCeilingKneeIsLeftAloneBitForBit() {
        let flat = [AppCurve(bundleID: "com.test.app", preGain: 0, bands: [])]
        let amplitude = 0.88
        let out = render(curves: flat, amplitude: amplitude, hz: 997, frames: 2400)
        for i in 0..<2400 {
            let expected = Float(amplitude * sin(2 * .pi * 997 * Double(i) / 48000))
            XCTAssertEqual(out[i * 2], expected, accuracy: 1e-6, "frame \(i)")
        }
    }

    func testTheCeilingIsSmoothAndMonotonicThroughItsKnee() {
        let flat = [AppCurve(bundleID: "com.test.app", preGain: 0, bands: [])]
        var previous: Float = -1
        for level in stride(from: 0.8, through: 3.0, by: 0.05) {
            let out = render(curves: flat, amplitude: level, hz: 50, frames: 960)
            let top = peak(out)
            XCTAssertGreaterThanOrEqual(top, previous - 1e-6, "level \(level)")
            XCTAssertLessThanOrEqual(top, 1)
            previous = top
        }
    }

    func testTheStageStaysTheOnlyClipperWhenItIsOn() {
        var stage = StageSettings()
        stage.enabled = true
        stage.width = 100
        stage.crossfeed = 0
        stage.dialogue = 0
        stage.room = 0
        stage.distance = 0
        stage.center = 0
        stage.night = 0
        let out = render(curves: boost(12), stage: stage, amplitude: 1)
        XCTAssertLessThanOrEqual(peak(out), 1)
    }

    private final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        private var blocks: [UnsafeMutablePointer<Float>] = []

        init(_ shapes: [(channels: Int, frames: Int)]) {
            list = AudioBufferList.allocate(maximumBuffers: shapes.count)
            for (i, shape) in shapes.enumerated() {
                let count = shape.channels * shape.frames
                let block = UnsafeMutablePointer<Float>.allocate(capacity: count)
                block.initialize(repeating: 0, count: count)
                blocks.append(block)
                list[i] = AudioBuffer(
                    mNumberChannels: UInt32(shape.channels),
                    mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(block))
            }
        }

        deinit {
            for block in blocks { block.deallocate() }
            free(list.unsafeMutablePointer)
        }

        var constPointer: UnsafePointer<AudioBufferList> {
            UnsafePointer(list.unsafeMutablePointer)
        }

        func fill(_ buffer: Int, _ samples: [Float]) {
            for (i, v) in samples.enumerated() { blocks[buffer][i] = v }
        }

        func samples(_ buffer: Int, count: Int) -> [Float] {
            Array(UnsafeBufferPointer(start: blocks[buffer], count: count))
        }
    }
}
