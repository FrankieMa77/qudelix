import XCTest
@testable import QudelixBar

final class ConvolverPortableTests: XCTestCase {
    private func taps(_ count: Int, seed: UInt64) -> [Float] {
        var s = seed
        return (0..<count).map { i in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: s)) / Float(Int64.max) * Float(exp(-Double(i) / 300))
        }
    }

    private func portableState(_ taps: [Float], block: Int) throws -> ConvolverState {
        try ConvolverState(impulse: ConvolverStateTests.response(taps), sampleRate: 48000,
                           blockFrames: block, makeFFT: { PortableRealFFT(length: $0) })
    }

    func testThePortableTransformConvolvesLikeTheDirectSum() throws {
        let h = taps(700, seed: 3)
        let state = try portableState(h, block: 256)
        XCTAssertGreaterThan(state.partitions, 2)
        let source = ConvolverStateTests.signal(2048)
        var left = source, right = source
        ConvolverStateTests.run(state, &left, &right, wet: 1, block: 256)
        let expected = ConvolverStateTests.convolve(source, h)
        for i in 0..<source.count {
            XCTAssertEqual(left[i], expected[i], accuracy: 2e-4, "sample \(i)")
            XCTAssertEqual(right[i], expected[i], accuracy: 2e-4, "sample \(i)")
        }
    }

    func testThePortableTransformMixesWetAndDry() throws {
        let h = taps(64, seed: 5)
        let state = try portableState(h, block: 128)
        let source = ConvolverStateTests.signal(512)
        var left = source, right = source
        ConvolverStateTests.run(state, &left, &right, wet: 0.5, block: 128)
        let wet = ConvolverStateTests.convolve(source, h)
        for i in 0..<source.count {
            XCTAssertEqual(left[i], 0.5 * source[i] + 0.5 * wet[i], accuracy: 2e-4)
        }
    }

    func testTheDefaultTransformIsAvailableOnThisPlatform() throws {
        let state = try ConvolverState(impulse: ConvolverStateTests.response([1]),
                                       sampleRate: 48000, blockFrames: 128)
        XCTAssertEqual(state.fftSize, 256)
    }

    func testAMissingTransformIsReportedNotCrashed() {
        XCTAssertThrowsError(try ConvolverState(
            impulse: ConvolverStateTests.response([1]), sampleRate: 48000, blockFrames: 128,
            makeFFT: { _ in nil })) {
            XCTAssertTrue(($0 as? ImpulseError)?.message.contains("transform") ?? false)
        }
    }
}
