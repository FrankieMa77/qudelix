import CoreAudio
import XCTest
@testable import QudelixBar

final class StageLoudnessTests: XCTestCase {
    func testTheDeficitBelowReferenceSetsTheShelf() {
        XCTAssertEqual(EarLevel.shelfDb(earLevelDb: EarLevel.referenceDb - 20,
                                        strength: 1), 7, accuracy: 1e-9)
        XCTAssertEqual(EarLevel.shelfDb(earLevelDb: EarLevel.referenceDb - 10,
                                        strength: 1), 3.5, accuracy: 1e-9)
    }

    func testAtReferenceAndAboveNothingIsOwed() {
        XCTAssertEqual(EarLevel.shelfDb(earLevelDb: EarLevel.referenceDb, strength: 1), 0)
        XCTAssertEqual(EarLevel.shelfDb(earLevelDb: 95, strength: 1), 0)
    }

    func testTheShelfStopsClimbingAtItsCeiling() {
        XCTAssertEqual(EarLevel.shelfDb(earLevelDb: 40, strength: 1),
                       EarLevel.maxShelfDb)
        XCTAssertEqual(EarLevel.shelfDb(earLevelDb: -200, strength: 1),
                       EarLevel.maxShelfDb)
    }

    func testStrengthScalesTheWholeContour() {
        let full = EarLevel.shelfDb(earLevelDb: 63, strength: 1)
        XCTAssertEqual(EarLevel.shelfDb(earLevelDb: 63, strength: 0.5),
                       full / 2, accuracy: 1e-9)
        XCTAssertEqual(EarLevel.shelfDb(earLevelDb: 63, strength: 0), 0)
        XCTAssertEqual(EarLevel.shelfDb(earLevelDb: 63, strength: 4), full,
                       accuracy: 1e-9)
        XCTAssertEqual(EarLevel.shelfDb(earLevelDb: 63, strength: .nan), 0)
    }

    func testWithNoEstimateThereIsNoShelfAtAll() {
        XCTAssertEqual(EarLevel.shelfDb(earLevelDb: nil, strength: 1), 0)
        XCTAssertEqual(EarLevel.shelfDb(earLevelDb: .nan, strength: 1), 0)
        XCTAssertEqual(EarLevel.shelfDb(earLevelDb: -.infinity, strength: 1), 0)
    }

    func testCompensationIsOffByDefaultAndSavesNothing() {
        let s = StageSettings()
        XCTAssertFalse(s.loudnessValue)
        XCTAssertEqual(s.loudnessStrengthValue, 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try! encoder.encode(s.clamped()), encoding: .utf8)
        XCTAssertFalse(json?.contains("loudness") ?? true, json ?? "")
    }

    func testAStageSavedBeforeCompensationExistedStillDecodes() {
        let legacy = """
        {"enabled": true, "width": 130, "crossfeed": 0.3,
         "dialogue": 0, "room": 0}
        """
        guard let s = try? JSONDecoder().decode(StageSettings.self,
                                                from: Data(legacy.utf8)) else {
            return XCTFail("a pre-change document must still decode")
        }
        XCTAssertNil(s.loudness)
        XCTAssertNil(s.loudnessStrength)
        var explicit = s
        explicit.loudness = false
        explicit.loudnessStrength = 1
        XCTAssertTrue(s.audiblyEquals(explicit))
    }

    func testTheStrengthIsClampedWhereverItCameFrom() {
        var s = StageSettings()
        s.loudnessStrength = 4
        XCTAssertEqual(s.clamped().loudnessStrengthValue, 1)
        s.loudnessStrength = -3
        XCTAssertEqual(s.clamped().loudnessStrengthValue, 0)
        s.loudnessStrength = .nan
        XCTAssertEqual(s.clamped().loudnessStrengthValue, 1)
    }

    func testTurningCompensationOnIsAnAudibleDifference() {
        var off = StageSettings()
        off.enabled = true
        var on = off
        on.loudness = true
        XCTAssertFalse(off.audiblyEquals(on))
        XCTAssertFalse(on.isAudiblyNeutral)
        var strength = on
        strength.loudnessStrength = 0.4
        XCTAssertFalse(on.audiblyEquals(strength))
    }

    func testTheSignalPathNamesTheCompensation() {
        var stage = StageSettings()
        stage.enabled = true
        stage.loudness = true
        let row = SignalPath.rows(.init(engineMode: .insert, stage: stage))
            .first { $0.id == "app" }
        XCTAssertEqual(row?.indicator, .altering)
        XCTAssertTrue(row?.state.contains("loudness compensation") ?? false,
                      row?.state ?? "")

        stage.loudness = false
        let quiet = SignalPath.rows(.init(engineMode: .insert, stage: stage))
            .first { $0.id == "app" }
        XCTAssertFalse(quiet?.state.contains("loudness") ?? true)
    }

    func testCompensationOffRendersExactlyTheSameSamples() {
        let samples = Self.stereoNoise(frames: 2048)
        let plain = render(flatStage(), input: samples)

        var off = flatStage()
        off.loudness = false
        let asked = render(off, input: samples, shelfDb: 12)
        XCTAssertEqual(asked.map(\.bitPattern), plain.map(\.bitPattern))
    }

    func testALoudEstimateAsksForNothingAndChangesNothing() {
        let samples = Self.stereoNoise(frames: 2048)
        var on = flatStage()
        on.loudness = true
        let shelf = EarLevel.shelfDb(earLevelDb: 90, strength: 1)
        XCTAssertEqual(shelf, 0)
        XCTAssertEqual(render(on, input: samples, shelfDb: shelf).map(\.bitPattern),
                       render(flatStage(), input: samples).map(\.bitPattern))
    }

    func testAQuietEstimateLandsTheShelfWhereItWasDesigned() {
        let shelf = 10.0
        for hz in [50.0, 12000.0] {
            let measured = gainDb(at: hz, shelfDb: shelf)
            let expected = Self.responseDb(low(shelf), high(shelf), hz: hz)
            XCTAssertEqual(measured, expected, accuracy: 0.06, "at \(hz) Hz")
        }
        XCTAssertGreaterThan(gainDb(at: 50, shelfDb: shelf), 8)
    }

    func testTheTrebleShelfRidesAtAFractionOfTheBassOne() {
        let shelf = 10.0
        let treble = Self.responseDb(low(shelf), high(shelf), hz: 12000)
        XCTAssertEqual(treble, shelf * EarLevel.trebleShelfRatio, accuracy: 0.35)
        XCTAssertLessThan(treble, Self.responseDb(low(shelf), high(shelf), hz: 50))
    }

    func testHalfStrengthAsksForHalfTheShelfAndDeliversIt() {
        let full = EarLevel.shelfDb(earLevelDb: 63, strength: 1)
        let half = EarLevel.shelfDb(earLevelDb: 63, strength: 0.5)
        XCTAssertEqual(half, full / 2, accuracy: 1e-9)
        XCTAssertEqual(gainDb(at: 50, shelfDb: half),
                       Self.responseDb(low(half), high(half), hz: 50),
                       accuracy: 0.06)
        XCTAssertLessThan(gainDb(at: 50, shelfDb: half),
                          gainDb(at: 50, shelfDb: full) - 1)
    }

    func testTheShelfGlidesToItsTargetInsideASecond() {
        let shelf = 12.0
        let rate = 48000.0
        let frames = Int(rate)
        let level: Float = 0.02
        var on = flatStage()
        on.loudness = true

        let out = render(on, input: [Float](repeating: level, count: frames * 2),
                         shelfDb: shelf, sampleRate: rate)
        let target = pow(10, shelf / 20)

        let atOneSecond = Double(out[(frames - 1) * 2]) / Double(level)
        XCTAssertEqual(20 * log10(atOneSecond), shelf, accuracy: 0.15)

        let atTenMs = Double(out[480 * 2]) / Double(level)
        XCTAssertLessThan(20 * log10(atTenMs), shelf / 3,
                          "the shelf stepped instead of gliding")
        XCTAssertGreaterThan(atTenMs, 1.0)
        XCTAssertLessThan(atTenMs, target)

        var previous = 0.0
        for frame in stride(from: 0, to: frames, by: 512) {
            let g = Double(out[frame * 2]) / Double(level)
            XCTAssertGreaterThanOrEqual(g, previous - 1e-4, "frame \(frame)")
            previous = g
        }
    }

    func testTheMeasurementBehindTheShelfIsUntouchedByTheShelf() {
        let samples = Self.stereoNoise(frames: 4096)
        var on = flatStage()
        on.loudness = true
        var off = flatStage()
        off.loudness = false

        let quiet = loudness(off, input: samples, shelfDb: 0)
        let boosted = loudness(on, input: samples, shelfDb: 12)
        XCTAssertEqual(boosted.frames, quiet.frames)
        XCTAssertEqual(boosted.sumSquares, quiet.sumSquares)
    }

    func testMonoContentIsCompensatedIdenticallyOnBothEars() {
        let frames = 48000
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Float(sin(2 * .pi * 60 * Double(i) / 48000)) * 0.05
            samples[i * 2] = v
            samples[i * 2 + 1] = v
        }
        var on = flatStage()
        on.loudness = true
        let out = render(on, input: samples, shelfDb: 9)
        for frame in stride(from: 0, to: frames, by: 97) {
            XCTAssertEqual(out[frame * 2], out[frame * 2 + 1], accuracy: 1e-7)
        }
        XCTAssertTrue(out.allSatisfy(\.isFinite))
        let settled = frames * 3 / 4
        let plain = render(flatStage(), input: samples)
        XCTAssertGreaterThan(Self.rms(out, channel: 0, from: settled),
                             Self.rms(plain, channel: 0, from: settled) * 1.5)
    }

    func testASingleChannelTapIsLeftAloneRatherThanCrashing() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        var on = flatStage()
        on.loudness = true
        p.applyStage(on)
        p.applyLoudness(shelfDb: 12)
        let input = Buffers([(1, 256)])
        input.fill(0, (0..<256).map { Float(sin(Double($0) * 0.05)) * 0.2 })
        let output = Buffers([(1, 256)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        XCTAssertTrue(output.samples(0, count: 256).allSatisfy(\.isFinite))
        XCTAssertFalse(p.renderDiagnostics().stageRan)
    }

    func testTheCompensationNeverTouchesTheAudioInMonitorMode() {
        let frames = 1024
        let samples = Self.stereoNoise(frames: frames)
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.setMonitorOnly(true)
        var on = flatStage()
        on.loudness = true
        p.applyStage(on)
        p.applyLoudness(shelfDb: 12)

        let input = Buffers([(2, frames)])
        input.fill(0, samples)
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        XCTAssertEqual(input.samples(0, count: frames * 2).map(\.bitPattern),
                       samples.map(\.bitPattern))
    }

    func testAnEpochWipeStartsTheShelfFromFlatAgain() {
        let rate = 48000.0
        let level: Float = 0.02
        let frames = 24000
        let p = StageProcessor()
        p.prepare(sampleRate: rate)
        var on = flatStage()
        on.loudness = true
        p.applyStage(on)
        p.applyLoudness(shelfDb: 12)

        let flat = [Float](repeating: level, count: frames * 2)
        let settled = renderOnce(p, flat)
        XCTAssertGreaterThan(Double(settled[(frames - 1) * 2]) / Double(level), 3.5)

        p.prepare(sampleRate: rate)
        let again = renderOnce(p, flat)
        XCTAssertEqual(Double(again[20]) / Double(level), 1, accuracy: 0.02)
        XCTAssertGreaterThan(Double(again[(frames - 1) * 2]) / Double(level), 3.5)
    }

    func testAMoveTooSmallToHearIsNotRedesigned() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        var on = flatStage()
        on.loudness = true
        p.applyStage(on)
        p.applyLoudness(shelfDb: 6)
        XCTAssertEqual(p.appliedLoudnessShelfDb, 6, accuracy: 1e-9)
        p.applyLoudness(shelfDb: 6.05)
        XCTAssertEqual(p.appliedLoudnessShelfDb, 6, accuracy: 1e-9)
        p.applyLoudness(shelfDb: 6.2)
        XCTAssertEqual(p.appliedLoudnessShelfDb, 6.2, accuracy: 1e-9)
    }

    func testTheAppliedShelfIsZeroWhileTheStageOrTheSwitchIsOff() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyLoudness(shelfDb: 9)

        var off = flatStage()
        off.loudness = false
        p.applyStage(off)
        XCTAssertEqual(p.appliedLoudnessShelfDb, 0)

        var on = off
        on.loudness = true
        p.applyStage(on)
        XCTAssertEqual(p.appliedLoudnessShelfDb, 9, accuracy: 1e-9)

        var idle = on
        idle.enabled = false
        p.applyStage(idle)
        XCTAssertEqual(p.appliedLoudnessShelfDb, 0)
    }

    func testAHandEditedShelfCannotClimbPastTheCeiling() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        var on = flatStage()
        on.loudness = true
        p.applyStage(on)
        p.applyLoudness(shelfDb: 400)
        XCTAssertEqual(p.appliedLoudnessShelfDb, EarLevel.maxShelfDb)
        p.applyLoudness(shelfDb: .nan)
        XCTAssertEqual(p.appliedLoudnessShelfDb, 0)
        p.applyLoudness(shelfDb: -30)
        XCTAssertEqual(p.appliedLoudnessShelfDb, 0)
    }

    func testTheShelfSurvivesRatesNoDeviceCouldRunAt() {
        for rate in [Double.infinity, .nan, 0, -48000, 1e30] {
            let p = StageProcessor()
            p.prepare(sampleRate: rate)
            var on = flatStage()
            on.loudness = true
            p.applyStage(on)
            p.applyLoudness(shelfDb: 12)
            let input = Buffers([(2, 128)])
            input.fill(0, (0..<256).map { Float(sin(Double($0) * 0.1)) * 0.3 })
            let output = Buffers([(2, 128)])
            p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
            XCTAssertTrue(output.samples(0, count: 256).allSatisfy(\.isFinite),
                          "rate \(rate)")
        }
    }

    func testNonFiniteSamplesNeverLodgeInTheShelf() {
        let frames = 512
        var samples = [Float](repeating: 0.1, count: frames * 2)
        samples[8] = .nan
        samples[9] = .infinity
        var on = flatStage()
        on.loudness = true
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyStage(on)
        p.applyLoudness(shelfDb: 12)
        XCTAssertTrue(renderOnce(p, samples).allSatisfy(\.isFinite))
        let clean = renderOnce(p, [Float](repeating: 0.1, count: frames * 2))
        XCTAssertTrue(clean.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(Self.rms(clean, channel: 0), 0.1)
    }

    private func low(_ shelfDb: Double) -> BiquadSection {
        BiquadSection.lowShelf(freq: StageProcessor.loudnessLowHz, gainDb: shelfDb,
                               q: StageProcessor.loudnessShelfQ, sampleRate: 48000)
    }

    private func high(_ shelfDb: Double) -> BiquadSection {
        BiquadSection.highShelf(freq: StageProcessor.loudnessHighHz,
                                gainDb: shelfDb * EarLevel.trebleShelfRatio,
                                q: StageProcessor.loudnessShelfQ, sampleRate: 48000)
    }

    private func gainDb(at hz: Double, shelfDb: Double) -> Double {
        let frames = 48000 * 3
        let samples = Self.tone(hz: hz, frames: frames, amplitude: 0.01)
        var on = flatStage()
        on.loudness = true
        let boosted = render(on, input: samples, shelfDb: shelfDb)
        let plain = render(flatStage(), input: samples)
        let from = frames * 3 / 4
        return 20 * log10(Self.rms(boosted, channel: 0, from: from)
                          / Self.rms(plain, channel: 0, from: from))
    }

    private static func responseDb(_ a: BiquadSection, _ b: BiquadSection,
                                   hz: Double, sampleRate: Double = 48000) -> Double {
        func magnitude(_ s: BiquadSection, _ w: Double) -> Double {
            let cos1 = cos(w), cos2 = cos(2 * w)
            let sin1 = sin(w), sin2 = sin(2 * w)
            let numRe = s.b0 + s.b1 * cos1 + s.b2 * cos2
            let numIm = -(s.b1 * sin1 + s.b2 * sin2)
            let denRe = 1 + s.a1 * cos1 + s.a2 * cos2
            let denIm = -(s.a1 * sin1 + s.a2 * sin2)
            return ((numRe * numRe + numIm * numIm)
                    / (denRe * denRe + denIm * denIm)).squareRoot()
        }
        let w = 2 * Double.pi * hz / sampleRate
        return 20 * log10(magnitude(a, w) * magnitude(b, w))
    }

    private func flatStage() -> StageSettings {
        var s = StageSettings()
        s.enabled = true
        s.width = 100
        s.crossfeed = 0
        s.dialogue = 0
        s.room = 0
        s.distance = 0
        s.span = 0.5
        s.center = 0
        s.size = 0.5
        s.night = 0
        return s
    }

    private func render(_ settings: StageSettings, input samples: [Float],
                        shelfDb: Double = 0,
                        sampleRate: Double = 48000) -> [Float] {
        let p = StageProcessor()
        p.prepare(sampleRate: sampleRate)
        p.applyStage(settings)
        if shelfDb > 0 { p.applyLoudness(shelfDb: shelfDb) }
        return renderOnce(p, samples)
    }

    private func loudness(_ settings: StageSettings, input samples: [Float],
                          shelfDb: Double) -> (sumSquares: Double, frames: Int) {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyStage(settings)
        if shelfDb > 0 { p.applyLoudness(shelfDb: shelfDb) }
        _ = renderOnce(p, samples)
        return p.drainLoudnessMeter()
    }

    private func renderOnce(_ p: StageProcessor, _ samples: [Float]) -> [Float] {
        let frames = samples.count / 2
        let input = Buffers([(2, frames)])
        input.fill(0, samples)
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        return output.samples(0, count: frames * 2)
    }

    private static func tone(hz: Double, frames: Int, amplitude: Double) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Float(amplitude * sin(2 * .pi * hz * Double(i) / 48000))
            out[i * 2] = v
            out[i * 2 + 1] = v
        }
        return out
    }

    private static func stereoNoise(frames: Int) -> [Float] {
        var state: UInt64 = 0xD1B5_4A32_D192_ED03
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: state)) / Float(Int64.max) * 0.1
            let tone = Float(sin(Double(i) * 0.019)) * 0.25
            out[i * 2] = tone + noise
            out[i * 2 + 1] = tone * 0.9 - noise
        }
        return out
    }

    private static func rms(_ interleaved: [Float], channel: Int,
                            from: Int = 0) -> Double {
        var sum = 0.0
        var n = 0
        var i = from * 2 + channel
        while i < interleaved.count {
            sum += Double(interleaved[i]) * Double(interleaved[i])
            n += 1
            i += 2
        }
        return n > 0 ? (sum / Double(n)).squareRoot() : 0
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
