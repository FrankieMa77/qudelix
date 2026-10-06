import Foundation
import XCTest
@testable import QudelixBar

final class ImpulseResponseCacheTests: XCTestCase {
    private static func response(frames: Int = 1500) -> ImpulseResponse {
        var state: UInt64 = 0xA5A5_1234_9E37_79B9
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            left[i] = Float(Int64(bitPattern: state)) / Float(Int64.max)
                * Float(exp(-Double(i) / 400))
            state = state &* 6364136223846793005 &+ 1442695040888963407
            right[i] = Float(Int64(bitPattern: state)) / Float(Int64.max)
                * Float(exp(-Double(i) / 400))
        }
        return ImpulseResponse(fileName: "cache-00000000.wav", displayName: "cache",
                               hash: "0", sourceRate: 48000, sourceChannels: 2,
                               channels: [left, right])
    }

    func testTwoThreadsAtTwoRatesEachGetTheRightSamples() {
        let reference = Self.response()
        let at44 = reference.channels.map { Resampler.convert($0, from: 48000, to: 44100) }
        let at96 = reference.channels.map { Resampler.convert($0, from: 48000, to: 96000) }

        for _ in 0..<12 {
            let shared = Self.response()
            let group = DispatchGroup()
            let failures = NSLock()
            var wrong = 0
            for (rate, expected) in [(44100.0, at44), (96000.0, at96)] {
                group.enter()
                DispatchQueue.global().async {
                    for _ in 0..<25 {
                        if shared.samples(at: rate) != expected {
                            failures.lock()
                            wrong += 1
                            failures.unlock()
                        }
                    }
                    group.leave()
                }
            }
            group.wait()
            XCTAssertEqual(wrong, 0)
        }
    }

    func testTwoThreadsAskingForTheSameRateResampleOnce() {
        for _ in 0..<10 {
            let shared = Self.response()
            let group = DispatchGroup()
            let start = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var results = [[[Float]]]()
            for _ in 0..<2 {
                group.enter()
                DispatchQueue.global().async {
                    start.wait()
                    let r = shared.samples(at: 96000)
                    lock.lock()
                    results.append(r)
                    lock.unlock()
                    group.leave()
                }
            }
            start.signal()
            start.signal()
            group.wait()
            XCTAssertEqual(results.count, 2)
            XCTAssertEqual(results[0], results[1])
            XCTAssertEqual(shared.resampleRuns, 1)
        }
    }

    func testTheTwoMostRecentRatesStayCached() {
        let r = Self.response()
        XCTAssertEqual(r.resampleRuns, 0)
        _ = r.samples(at: 44100)
        _ = r.samples(at: 96000)
        XCTAssertEqual(r.resampleRuns, 2)
        _ = r.samples(at: 44100)
        _ = r.samples(at: 96000)
        _ = r.samples(at: 44100)
        XCTAssertEqual(r.resampleRuns, 2, "going back to the previous rate must not thrash")

        _ = r.samples(at: 88200)
        XCTAssertEqual(r.resampleRuns, 3)
        _ = r.samples(at: 44100)
        XCTAssertEqual(r.resampleRuns, 3, "the most recently used rate survives eviction")
        _ = r.samples(at: 96000)
        XCTAssertEqual(r.resampleRuns, 4, "the least recently used rate was dropped")
    }

    func testTheSourceRateNeverTouchesTheCache() {
        let r = Self.response()
        XCTAssertEqual(r.samples(at: 48000), r.channels)
        XCTAssertEqual(r.resampleRuns, 0)
    }

    func testAPrimedRateIsWhatTheConvolverBuildsFrom() throws {
        let r = Self.response()
        r.prime(at: 44100)
        XCTAssertEqual(r.resampleRuns, 1)
        _ = try ConvolverState(impulse: r, sampleRate: 44100, blockFrames: 128)
        XCTAssertEqual(r.resampleRuns, 1, "building after priming reuses the primed samples")
    }
}
