import XCTest
@testable import QudelixBar

final class ConvolverStateTests: XCTestCase {
    func testAUnitImpulseGivesTheSignalBackUnchanged() throws {
        let state = try ConvolverState(impulse: Self.response([1]),
                                       sampleRate: 48000, blockFrames: 128)
        XCTAssertEqual(state.hop, 128)
        XCTAssertEqual(state.partitions, 1)

        let source = Self.signal(512)
        var left = source, right = source
        Self.run(state, &left, &right, wet: 1, block: 128)
        for i in 0..<source.count {
            XCTAssertEqual(left[i], source[i], accuracy: 1e-5, "sample \(i)")
            XCTAssertEqual(right[i], source[i], accuracy: 1e-5, "sample \(i)")
        }
    }

    func testAnImpulseOneSampleInDelaysBySpecificallyOneSample() throws {
        let state = try ConvolverState(impulse: Self.response([0, 1]),
                                       sampleRate: 48000, blockFrames: 128)
        let source = Self.signal(512)
        var left = source, right = source
        Self.run(state, &left, &right, wet: 1, block: 128)

        XCTAssertEqual(left[0], 0, accuracy: 1e-5)
        for i in 1..<source.count {
            XCTAssertEqual(left[i], source[i - 1], accuracy: 1e-5, "sample \(i)")
        }
    }

    func testATwoPartitionResponseMatchesDirectConvolution() throws {
        var taps = [Float](repeating: 0, count: 100)
        var seed: UInt64 = 99
        for i in taps.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            taps[i] = Float(Int64(bitPattern: seed)) / Float(Int64.max)
                * Float(exp(-Double(i) / 25))
        }
        let state = try ConvolverState(impulse: Self.response(taps),
                                       sampleRate: 48000, blockFrames: 64)
        XCTAssertEqual(state.hop, 64)
        XCTAssertEqual(state.partitions, 2)

        let source = Self.signal(1024)
        var left = source, right = source
        Self.run(state, &left, &right, wet: 1, block: 64)
        let expected = Self.convolve(source, taps)
        for i in 0..<source.count {
            XCTAssertEqual(left[i], expected[i], accuracy: 1e-4, "sample \(i)")
        }
    }

    func testAStereoResponseAppliesOneSidePerChannel() throws {
        let impulse = ImpulseResponse(fileName: "pair-00000000.wav",
                                      displayName: "pair", hash: "0",
                                      sourceRate: 48000, sourceChannels: 2,
                                      channels: [[1], [0, 0, 1]])
        let state = try ConvolverState(impulse: impulse, sampleRate: 48000,
                                       blockFrames: 128)
        XCTAssertTrue(state.stereo)
        let source = Self.signal(256)
        var left = source, right = source
        Self.run(state, &left, &right, wet: 1, block: 128)

        XCTAssertEqual(left[10], source[10], accuracy: 1e-5)
        XCTAssertEqual(right[10], source[8], accuracy: 1e-5)
    }

    func testAMixOfZeroLeavesTheDrySignalExactlyWhereItWas() throws {
        let state = try ConvolverState(impulse: Self.response([0, 0, 0.5]),
                                       sampleRate: 48000, blockFrames: 128)
        let source = Self.signal(256)
        var left = source, right = source
        Self.run(state, &left, &right, wet: 0, block: 128)
        XCTAssertEqual(left.map(\.bitPattern), source.map(\.bitPattern))
        XCTAssertEqual(right.map(\.bitPattern), source.map(\.bitPattern))
    }

    func testABlockLargerThanTheOneItWasBuiltForIsRefusedRatherThanRead() throws {
        let state = try ConvolverState(impulse: Self.response([1]),
                                       sampleRate: 48000, blockFrames: 128)
        XCTAssertTrue(state.accepts(frames: 128))
        XCTAssertFalse(state.accepts(frames: 256))
        XCTAssertFalse(state.accepts(frames: 100))
        XCTAssertFalse(state.accepts(frames: 0))

        var left = Self.signal(256), right = Self.signal(256)
        let before = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                state.render(left: l.baseAddress!, right: r.baseAddress!,
                             frames: 256, wet: 1)
            }
        }
        XCTAssertEqual(left.map(\.bitPattern), before.map(\.bitPattern))
    }

    func testABlockSizeThatCannotBePartitionedIsRefusedOutright() {
        XCTAssertEqual(ImpulseLimits.hop(forBlock: 512), 512)
        XCTAssertEqual(ImpulseLimits.hop(forBlock: 480), 32)
        XCTAssertEqual(ImpulseLimits.hop(forBlock: 4096), 2048)
        XCTAssertEqual(ImpulseLimits.hop(forBlock: 16), 0)
        XCTAssertEqual(ImpulseLimits.hop(forBlock: 100), 0)

        XCTAssertThrowsError(try ConvolverState(impulse: Self.response([1]),
                                                sampleRate: 48000,
                                                blockFrames: 100))
    }

    func testAResponseBeyondTheArithmeticBudgetIsRefusedWithAReason() {
        let budget = ImpulseLimits.maxPartitions(sampleRate: 48000)
        XCTAssertGreaterThan(budget, 100)
        let taps = [Float](repeating: 0.001, count: (budget + 2) * 32)
        do {
            _ = try ConvolverState(impulse: Self.response(taps),
                                   sampleRate: 48000, blockFrames: 480)
            XCTFail("a response past the budget should be refused")
        } catch let error as ImpulseError {
            XCTAssertTrue(error.message.contains("partitions"), error.message)
            XCTAssertTrue(error.message.contains("\(budget)"), error.message)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAResponseLongerThanTheCeilingIsCutRatherThanRefused() throws {
        let taps = [Float](repeating: 0.0001, count: 48000 * 3)
        let state = try ConvolverState(impulse: Self.response(taps),
                                       sampleRate: 48000, blockFrames: 512)
        XCTAssertEqual(state.taps, Int(48000 * ImpulseLimits.maxSeconds))
    }

    func testResamplingLandsOnTheRightLengthAndKeepsTheEnergy() {
        let source = Self.signal(2048)
        let up = Resampler.convert(source, from: 48000, to: 96000)
        XCTAssertEqual(up.count, 4096)
        let down = Resampler.convert(source, from: 48000, to: 24000)
        XCTAssertEqual(down.count, 1024)
        XCTAssertTrue(up.allSatisfy(\.isFinite))
        XCTAssertTrue(down.allSatisfy(\.isFinite))

        let dc = [Float](repeating: 0.5, count: 1024)
        let resampled = Resampler.convert(dc, from: 44100, to: 48000)
        for v in resampled[200..<800] {
            XCTAssertEqual(v, 0.5, accuracy: 0.01)
        }
    }

    func testANonFiniteSampleNeverLeavesTheConvolver() throws {
        let state = try ConvolverState(impulse: Self.response([1, 0.5]),
                                       sampleRate: 48000, blockFrames: 128)
        var left = Self.signal(256), right = Self.signal(256)
        left[7] = .nan
        right[9] = .infinity
        Self.run(state, &left, &right, wet: 1, block: 128)
        XCTAssertTrue(left.allSatisfy(\.isFinite))
        XCTAssertTrue(right.allSatisfy(\.isFinite))
    }

    static func response(_ taps: [Float], rate: Double = 48000) -> ImpulseResponse {
        ImpulseResponse(fileName: "test-00000000.wav", displayName: "test",
                        hash: "0", sourceRate: rate, sourceChannels: 1,
                        channels: [taps])
    }

    static func signal(_ count: Int) -> [Float] {
        var seed: UInt64 = 0x1234_5678_9abc_def0
        return (0..<count).map { i in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: seed)) / Float(Int64.max) * 0.1
            return Float(sin(Double(i) * 0.07)) * 0.4 + noise
        }
    }

    static func run(_ state: ConvolverState, _ left: inout [Float],
                    _ right: inout [Float], wet: Float, block: Int) {
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var base = 0
                while base + block <= l.count {
                    state.render(left: l.baseAddress! + base,
                                 right: r.baseAddress! + base,
                                 frames: block, wet: wet)
                    base += block
                }
            }
        }
    }

    static func convolve(_ x: [Float], _ h: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        for n in 0..<x.count {
            var acc = 0.0
            for k in 0..<min(h.count, n + 1) {
                acc += Double(h[k]) * Double(x[n - k])
            }
            out[n] = Float(acc)
        }
        return out
    }
}
