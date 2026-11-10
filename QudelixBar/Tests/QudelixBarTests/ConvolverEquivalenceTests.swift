import XCTest
@testable import QudelixBar

final class ConvolverEquivalenceTests: XCTestCase {
    func testPortableAndAccelerateTransformsRenderTheSameAudio() throws {
        var seed: UInt64 = 11
        let taps: [Float] = (0..<900).map { i in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed)) / Float(Int64.max) * Float(exp(-Double(i) / 300))
        }
        let impulse = ConvolverStateTests.response(taps)
        let accelerate = try ConvolverState(impulse: impulse, sampleRate: 48000, blockFrames: 256,
                                            makeFFT: { AccelerateRealFFT(length: $0) })
        let portable = try ConvolverState(impulse: impulse, sampleRate: 48000, blockFrames: 256,
                                          makeFFT: { PortableRealFFT(length: $0) })
        let source = ConvolverStateTests.signal(4096)
        var aL = source, aR = source, pL = source, pR = source
        ConvolverStateTests.run(accelerate, &aL, &aR, wet: 1, block: 256)
        ConvolverStateTests.run(portable, &pL, &pR, wet: 1, block: 256)
        for i in 0..<source.count {
            XCTAssertEqual(pL[i], aL[i], accuracy: 1e-4, "sample \(i)")
            XCTAssertEqual(pR[i], aR[i], accuracy: 1e-4, "sample \(i)")
        }
    }
}
