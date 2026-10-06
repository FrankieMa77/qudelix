import XCTest
@testable import QudelixBar

final class EngineRateWitnessTests: XCTestCase {
    func testWithNoWitnessTheOutputRateStands() {
        let d = StageEngine.designRate(output: 44100, aggregate: nil, tap: nil)
        XCTAssertEqual(d.rate, 44100)
        XCTAssertFalse(d.mismatch)
    }

    func testWitnessesThatAgreeWithTheOutputChangeNothing() {
        let d = StageEngine.designRate(output: 48000, aggregate: 48000, tap: 48000)
        XCTAssertEqual(d.rate, 48000)
        XCTAssertFalse(d.mismatch)
    }

    func testTwoWitnessesAgreeingOnAnotherRateOverrideTheOutput() {
        let d = StageEngine.designRate(output: 44100, aggregate: 48000, tap: 48000)
        XCTAssertEqual(d.rate, 48000, "every analyzer bin would be mislabelled otherwise")
        XCTAssertTrue(d.mismatch)
    }

    func testAWitnessAloneDisagreeingIsTrustedWhenNothingContradictsIt() {
        XCTAssertEqual(StageEngine.designRate(output: 44100, aggregate: nil, tap: 48000).rate,
                       48000)
        XCTAssertEqual(StageEngine.designRate(output: 44100, aggregate: 48000, tap: nil).rate,
                       48000)
    }

    func testWitnessesThatContradictEachOtherLeaveTheOutputRateAndAreFlagged() {
        let d = StageEngine.designRate(output: 48000, aggregate: 48000, tap: 44100)
        XCTAssertEqual(d.rate, 48000,
                       "a tap resampled onto the engine's clock is correctly labelled by that clock")
        XCTAssertTrue(d.mismatch)

        let split = StageEngine.designRate(output: 96000, aggregate: 44100, tap: 48000)
        XCTAssertEqual(split.rate, 96000)
        XCTAssertTrue(split.mismatch)
    }

    func testImplausibleWitnessesAreIgnored() {
        let d = StageEngine.designRate(output: 44100, aggregate: 0, tap: .nan)
        XCTAssertEqual(d.rate, 44100)
        XCTAssertFalse(d.mismatch)
        let huge = StageEngine.designRate(output: 44100, aggregate: 1e12, tap: .infinity)
        XCTAssertEqual(huge.rate, 44100)
        XCTAssertFalse(huge.mismatch)
    }

    func testAFractionOfAHertzIsNotAMismatch() {
        let d = StageEngine.designRate(output: 44100, aggregate: 44100.2, tap: 44099.9)
        XCTAssertEqual(d.rate, 44100)
        XCTAssertFalse(d.mismatch)
    }
}
