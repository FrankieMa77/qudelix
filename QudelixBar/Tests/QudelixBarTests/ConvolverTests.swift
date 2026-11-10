import AVFoundation
import CoreAudio
import XCTest
@testable import QudelixBar

final class StageImpulseRenderTests: XCTestCase {
    func testNoImpulseRendersExactlyWhatItAlwaysDid() {
        let plain = render(impulse: nil, settings: Self.stage())
        var withFile = Self.stage()
        withFile.impulseFile = nil
        let loaded = render(impulse: ConvolverStateTests.response([0, 0, 1]),
                            settings: withFile)
        XCTAssertEqual(loaded.map(\.bitPattern), plain.map(\.bitPattern))
    }

    func testAMixOfZeroIsTheSameSamplesAsNoResponseAtAll() {
        let plain = render(impulse: nil, settings: Self.stage())
        var mixed = Self.stage()
        mixed.impulseFile = "test-00000000.wav"
        mixed.impulseMix = 0
        let convolved = render(impulse: ConvolverStateTests.response([0, 0, 1]),
                               settings: mixed)
        XCTAssertEqual(convolved.map(\.bitPattern), plain.map(\.bitPattern))
    }

    func testAUnitResponseAtFullMixLeavesTheStageWhereItWas() {
        let plain = render(impulse: nil, settings: Self.stage())
        var wet = Self.stage()
        wet.impulseFile = "test-00000000.wav"
        let convolved = render(impulse: ConvolverStateTests.response([1]),
                               settings: wet)
        for i in 0..<plain.count {
            XCTAssertEqual(convolved[i], plain[i], accuracy: 2e-5, "sample \(i)")
        }
    }

    func testAResponseActuallyChangesTheOutput() {
        let plain = render(impulse: nil, settings: Self.stage())
        var wet = Self.stage()
        wet.impulseFile = "test-00000000.wav"
        let convolved = render(impulse: ConvolverStateTests.response([0, 0, 0, 1]),
                               settings: wet)
        let difference = zip(plain, convolved).map { abs($0 - $1) }.max() ?? 0
        XCTAssertGreaterThan(difference, 0.01)
        XCTAssertTrue(convolved.allSatisfy(\.isFinite))
    }

    func testABlockTheSetWasNotBuiltForPassesStraightThrough() {
        let plain = render(impulse: nil, settings: Self.stage(), frames: 500)
        var wet = Self.stage()
        wet.impulseFile = "test-00000000.wav"
        let convolved = render(impulse: ConvolverStateTests.response([0, 0, 0, 1]),
                               settings: wet, frames: 500)
        XCTAssertEqual(convolved.map(\.bitPattern), plain.map(\.bitPattern))
    }

    func testTheSetIsRebuiltForTheRateThatPrepareAnnounces() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.setImpulse(ConvolverStateTests.response([1], rate: 48000))
        guard case .ready(_, _, _, let hop, let rate) = p.impulseStatus else {
            return XCTFail("no set was built: \(p.impulseStatus)")
        }
        XCTAssertEqual(rate, 48000)
        XCTAssertEqual(hop, StageProcessor.defaultBlockFrames)

        p.prepare(sampleRate: 44100)
        guard case .ready(_, _, _, _, let after) = p.impulseStatus else {
            return XCTFail("the rate change lost the set: \(p.impulseStatus)")
        }
        XCTAssertEqual(after, 44100)
    }

    func testTheLayoutFollowsTheBlockSizeTheDeviceActuallyHandsOver() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.setImpulse(ConvolverStateTests.response([1]))
        XCTAssertEqual(p.observedBlockFrames, 0)

        feed(p, frames: 128)
        XCTAssertEqual(p.observedBlockFrames, 128)
        p.refreshImpulseLayout()
        guard case .ready(_, _, _, let hop, _) = p.impulseStatus else {
            return XCTFail("no set after the rebuild: \(p.impulseStatus)")
        }
        XCTAssertEqual(hop, 128)
    }

    func testARefusedLayoutSaysWhyRatherThanFallingSilent() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        feed(p, frames: 100)
        p.setImpulse(ConvolverStateTests.response([1]))
        guard case .refused(let message) = p.impulseStatus else {
            return XCTFail("a block of 100 has no partition: \(p.impulseStatus)")
        }
        XCTAssertTrue(message.contains("100"), message)
    }

    func testDroppingTheResponseClearsTheSet() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.setImpulse(ConvolverStateTests.response([1]))
        XCTAssertNotNil(p.impulseName)
        p.setImpulse(nil)
        XCTAssertNil(p.impulseName)
        XCTAssertEqual(p.impulseStatus, .off)
    }

    private static func stage() -> StageSettings {
        var s = StageSettings()
        s.enabled = true
        s.width = 140
        s.crossfeed = 0.3
        s.dialogue = 2
        s.room = 0.3
        s.distance = 0.3
        s.span = 0.5
        s.center = 0
        s.size = 0.5
        return s
    }

    private func render(impulse: ImpulseResponse?, settings: StageSettings,
                        frames: Int = 512) -> [Float] {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        if let impulse { p.setImpulse(impulse) }
        p.applyStage(settings)

        var out: [Float] = []
        for block in 0..<4 {
            let input = Buffers([(2, frames)])
            input.fill(0, Self.stereo(frames: frames, block: block))
            let output = Buffers([(2, frames)])
            p.render(input: input.constPointer,
                     output: output.list.unsafeMutablePointer)
            out.append(contentsOf: output.samples(0, count: frames * 2))
        }
        return out
    }

    private func feed(_ p: StageProcessor, frames: Int) {
        let input = Buffers([(2, frames)])
        input.fill(0, Self.stereo(frames: frames, block: 0))
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
    }

    private static func stereo(frames: Int, block: Int) -> [Float] {
        var seed = UInt64(0x2545_F491_4F6C_DD1D) &+ UInt64(block)
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: seed)) / Float(Int64.max) * 0.12
            let tone = Float(sin(Double(i + block * frames) * 0.029)) * 0.35
            out[i * 2] = tone + noise
            out[i * 2 + 1] = tone * 0.8 - noise
        }
        return out
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

final class StageImpulseSettingsTests: XCTestCase {
    func testAStageWithNoResponseEncodesExactlyWhatItUsedTo() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(StageSettings.movie.clamped())
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertFalse(text.contains("impulse"), text)
    }

    func testTheStoredNameAndMixSurviveARoundTrip() throws {
        var s = StageSettings.music
        s.impulseFile = "room-1a2b3c4d.wav"
        s.impulseMix = 0.4
        let data = try JSONEncoder().encode(s.clamped())
        let back = try JSONDecoder().decode(StageSettings.self, from: data)
        XCTAssertEqual(back.impulseFileValue, "room-1a2b3c4d.wav")
        XCTAssertEqual(back.impulseMixValue, 0.4)
    }

    func testAHandEditedNameIsDroppedOnTheWayToTheDsp() {
        var s = StageSettings()
        s.impulseFile = "../../../etc/passwd"
        s.impulseMix = 0.5
        let clamped = s.clamped()
        XCTAssertNil(clamped.impulseFile)
        XCTAssertNil(clamped.impulseMix)
        XCTAssertFalse(clamped.hasImpulse)
    }

    func testAMixOutsideTheRangeIsPulledBackIn() {
        var s = StageSettings()
        s.impulseFile = "room-1a2b3c4d.wav"
        s.impulseMix = 9
        XCTAssertEqual(s.clamped().impulseMixValue, 1)
        s.impulseMix = -2
        XCTAssertEqual(s.clamped().impulseMixValue, 0)
        s.impulseMix = .nan
        XCTAssertEqual(s.clamped().impulseMixValue, 1)
    }

    func testTwoStagesDifferingOnlyByTheirResponseAreNotTheSameStage() {
        var a = StageSettings.music
        var b = StageSettings.music
        XCTAssertTrue(a.audiblyEquals(b))
        a.impulseFile = "room-1a2b3c4d.wav"
        XCTAssertFalse(a.audiblyEquals(b))
        b.impulseFile = "room-1a2b3c4d.wav"
        XCTAssertTrue(a.audiblyEquals(b))
        b.impulseMix = 0.2
        XCTAssertFalse(a.audiblyEquals(b))
    }

    func testAStageCarryingAResponseIsNeverAudiblyNeutral() {
        var s = StageSettings()
        s.enabled = true
        s.width = 100
        s.crossfeed = 0
        s.dialogue = 0
        s.room = 0
        s.distance = 0
        s.center = 0
        s.night = 0
        XCTAssertTrue(s.isAudiblyNeutral)
        s.impulseFile = "room-1a2b3c4d.wav"
        XCTAssertFalse(s.isAudiblyNeutral)
        XCTAssertTrue(s.doesAnything)
    }

    func testTheSignalPathNamesTheResponseOnlyWhenASetIsBuilt() {
        var stage = StageSettings.music
        stage.enabled = true
        stage.impulseFile = "room-1a2b3c4d.wav"

        let named = SignalPath.rows(.init(engineMode: .insert, stage: stage,
                                          impulseActive: true))
            .first { $0.id == "app" }
        XCTAssertTrue(named?.state.contains("impulse response") ?? false,
                      named?.state ?? "")

        let quiet = SignalPath.rows(.init(engineMode: .insert, stage: stage,
                                          impulseActive: false))
            .first { $0.id == "app" }
        XCTAssertFalse(quiet?.state.contains("impulse response") ?? true,
                       quiet?.state ?? "")
    }
}
