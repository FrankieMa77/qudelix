import CoreAudio
import XCTest
@testable import QudelixBar

final class StageRoomRateTests: XCTestCase {
    private static func roomStage(size: Double = 1, distance: Double = 1) -> StageSettings {
        var s = StageSettings()
        s.enabled = true
        s.width = 100
        s.crossfeed = 0
        s.dialogue = 0
        s.room = 1
        s.distance = distance
        s.size = size
        s.center = 0
        s.night = 0
        return s
    }

    private static func impulseResponse(rate: Double, seconds: Double,
                                        stage: StageSettings) -> [Float] {
        let frames = Int(rate * seconds)
        let p = StageProcessor()
        p.prepare(sampleRate: rate)
        p.applyStage(stage)
        let input = Buffers([(2, frames)])
        var samples = [Float](repeating: 0, count: frames * 2)
        samples[0] = 0.1
        samples[1] = 0.1
        input.fill(0, samples)
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        let all = output.samples(0, count: frames * 2)
        return (0..<frames).map { all[$0 * 2] }
    }

    private static func binEnergies(_ response: [Float], rate: Double,
                                    binMs: Double = 5) -> [Double] {
        let bin = max(1, Int(rate * binMs / 1000))
        var out = [Double]()
        var start = 0
        while start < response.count {
            let end = min(start + bin, response.count)
            var e = 0.0
            for i in start..<end { e += Double(response[i]) * Double(response[i]) }
            out.append(e)
            start = end
        }
        return out
    }

    private static let directMs = 20.0

    private static func decayMilliseconds(_ response: [Float], rate: Double,
                                          belowDb: Double) -> Double {
        let bins = binEnergies(response, rate: rate)
        let first = Int(directMs / 5)
        let peak = bins[first...].max() ?? 0
        let floor = peak * pow(10, -belowDb / 10)
        var last = first
        for i in first..<bins.count where bins[i] >= floor { last = i }
        return Double(last + 1) * 5
    }

    private static func energyFractionBefore(_ response: [Float], rate: Double,
                                             ms: Double) -> Double {
        let start = Int(rate * directMs / 1000)
        let cut = Int(rate * ms / 1000)
        var head = 0.0, total = 0.0
        for i in start..<response.count {
            let e = Double(response[i]) * Double(response[i])
            total += e
            if i < cut { head += e }
        }
        return head / total
    }

    func testTheRoomHasTheSameLengthAndShapeAtEveryRate() {
        let rates = [44100.0, 48000, 96000, 192000, 768000]
        var decays = [Double: Double]()
        var fractions = [Double: Double]()
        for rate in rates {
            let r = Self.impulseResponse(rate: rate, seconds: 0.9, stage: Self.roomStage())
            XCTAssertTrue(r.allSatisfy(\.isFinite))
            decays[rate] = Self.decayMilliseconds(r, rate: rate, belowDb: 40)
            fractions[rate] = Self.energyFractionBefore(r, rate: rate, ms: 100)
        }
        let referenceDecay = decays[48000] ?? 0
        let referenceFraction = fractions[48000] ?? 0
        XCTAssertGreaterThan(referenceDecay, 300)
        for rate in rates {
            XCTAssertEqual(decays[rate] ?? 0, referenceDecay, accuracy: referenceDecay * 0.1,
                           "-40 dB decay at \(Int(rate)) Hz: \(decays[rate] ?? 0) ms "
                           + "against \(referenceDecay) ms at 48 kHz")
            XCTAssertEqual(fractions[rate] ?? 0, referenceFraction,
                           accuracy: referenceFraction * 0.05,
                           "energy in the first 100 ms at \(Int(rate)) Hz")
        }
    }

    func testTheLongestEarlyReflectionReachesTheSameTimeAtHighRates() {
        for rate in [48000.0, 192000, 768000] {
            var stage = Self.roomStage()
            stage.room = 0.01
            let r = Self.impulseResponse(rate: rate, seconds: 0.25, stage: stage)
            let bins = Self.binEnergies(r, rate: rate, binMs: 2)
            let late = bins.enumerated().filter { $0.offset * 2 >= 90 && $0.offset * 2 < 100 }
                .map(\.element).reduce(0, +)
            XCTAssertGreaterThan(late, 0, "the last early reflections at \(Int(rate)) Hz")
        }
    }

    func testTheTailDampingIsTheSameCutoffAtEveryRate() {
        let coefficient = 1 - exp(-2 * Double.pi * StageProcessor.tailDampHz / 48000)
        XCTAssertEqual(coefficient, 0.35, accuracy: 1e-12)
        let at96 = 1 - exp(-2 * Double.pi * StageProcessor.tailDampHz / 96000)
        XCTAssertLessThan(at96, coefficient)
    }

    func testAWipeAtAHighRateLeavesNoTraceOfTheOldRoom() {
        let rate = 384000.0
        let frames = 4096
        var state: UInt64 = 0x1234_5678_9ABC_DEF1
        var noise = [Float](repeating: 0, count: frames * 2)
        for i in 0..<noise.count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            noise[i] = Float(Int64(bitPattern: state)) / Float(Int64.max) * 0.3
        }
        func render(_ p: StageProcessor) -> [Float] {
            let input = Buffers([(2, frames)])
            input.fill(0, noise)
            let output = Buffers([(2, frames)])
            p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
            return output.samples(0, count: frames * 2)
        }

        let used = StageProcessor()
        used.prepare(sampleRate: rate)
        used.applyStage(Self.roomStage())
        for _ in 0..<40 { _ = render(used) }
        used.prepare(sampleRate: rate)

        let fresh = StageProcessor()
        fresh.prepare(sampleRate: rate)
        fresh.applyStage(Self.roomStage())

        XCTAssertEqual(render(used).map(\.bitPattern), render(fresh).map(\.bitPattern))
        XCTAssertEqual(render(used).map(\.bitPattern), render(fresh).map(\.bitPattern))
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
