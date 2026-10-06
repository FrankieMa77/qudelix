import XCTest
@testable import QudelixBar

final class ImpulsePrimeGateTests: XCTestCase {
    func testWithNoResponseLoadedTheEngineStartsAtOnce() {
        var gate = ImpulsePrimeGate()
        XCTAssertEqual(gate.verdict(sourceRate: nil, targetRate: 44100), .proceed)
    }

    func testAResponseAlreadyAtTheDeviceRateNeedsNoPriming() {
        var gate = ImpulsePrimeGate()
        XCTAssertEqual(gate.verdict(sourceRate: 48000, targetRate: 48000), .proceed)
    }

    func testAResponseAtAnotherRateIsPrimedOnceAndTheStartWaitsForIt() {
        var gate = ImpulsePrimeGate()
        XCTAssertEqual(gate.verdict(sourceRate: 48000, targetRate: 44100),
                       .prime(rate: 44100))
        XCTAssertEqual(gate.verdict(sourceRate: 48000, targetRate: 44100), .wait,
                       "a second reconcile while the first prime runs must not start another")
        gate.finished(generation: gate.generation, rate: 44100)
        XCTAssertEqual(gate.verdict(sourceRate: 48000, targetRate: 44100), .proceed)
    }

    func testAPrimedRateIsRememberedUntilTheDeviceMovesToAnother() {
        var gate = ImpulsePrimeGate()
        _ = gate.verdict(sourceRate: 48000, targetRate: 44100)
        gate.finished(generation: gate.generation, rate: 44100)
        XCTAssertEqual(gate.verdict(sourceRate: 48000, targetRate: 44100), .proceed)
        XCTAssertEqual(gate.verdict(sourceRate: 48000, targetRate: 96000),
                       .prime(rate: 96000))
    }

    func testTheRateTheEngineStartedAtCountsAsPrimed() {
        var gate = ImpulsePrimeGate()
        gate.engineStarted(at: 96000)
        XCTAssertEqual(gate.verdict(sourceRate: 48000, targetRate: 96000), .proceed)
        XCTAssertEqual(gate.verdict(sourceRate: 48000, targetRate: 44100),
                       .prime(rate: 44100))
    }

    func testAReplacedResponseForgetsWhatWasPrimedForTheOldOne() {
        var gate = ImpulsePrimeGate()
        gate.engineStarted(at: 44100)
        gate.adopted()
        XCTAssertEqual(gate.verdict(sourceRate: 48000, targetRate: 44100),
                       .prime(rate: 44100),
                       "the cache belongs to the response that was replaced")
    }

    func testAPrimeFinishingForAReplacedResponseDoesNotMarkTheNewOneReady() {
        var gate = ImpulsePrimeGate()
        XCTAssertEqual(gate.verdict(sourceRate: 48000, targetRate: 44100),
                       .prime(rate: 44100))
        let stale = gate.generation
        gate.adopted()
        XCTAssertEqual(gate.verdict(sourceRate: 48000, targetRate: 44100), .wait,
                       "the old prime still holds the single cache entry")
        gate.finished(generation: stale, rate: 44100)
        XCTAssertNil(gate.cachedRate)
        XCTAssertEqual(gate.verdict(sourceRate: 48000, targetRate: 44100),
                       .prime(rate: 44100))
    }

    func testRemovingTheResponseNeverLeavesTheEngineWaiting() {
        var gate = ImpulsePrimeGate()
        _ = gate.verdict(sourceRate: 48000, targetRate: 44100)
        gate.adopted()
        XCTAssertEqual(gate.verdict(sourceRate: nil, targetRate: 44100), .proceed)
    }
}
