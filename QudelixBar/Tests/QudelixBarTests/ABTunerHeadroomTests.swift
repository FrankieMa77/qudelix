import XCTest
@testable import QudelixBar

final class ABTunerHeadroomTests: XCTestCase {
    private func peak(_ freq: Int, _ gain: Double, _ q: Double) -> QxEqBandValue {
        QxEqBandValue(filter: .peak, freq: freq, gain: gain, q: q)
    }

    private func flat() -> [QxEqBandValue] {
        QxEq.defaultFreqs.map { QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1.0) }
    }

    func testOverlappingBandsSumBeyondTheLargestSingleGain() {
        let bands = [peak(950, 3, 0.7), peak(1000, 3, 0.7), peak(1050, 3, 0.7)]
        let largestSingle = bands.map(\.gain).max() ?? 0
        let summed = EQHeadroom.peakBoost(of: bands)

        XCTAssertGreaterThan(summed, largestSingle + 1.0,
                             "overlapping bands must sum well past any one of them")

        let g = ABTuner.safePreGain(for: bands, notAbove: 0)
        XCTAssertLessThanOrEqual(g, -summed + 0.05)
        XCTAssertLessThan(g, -largestSingle,
                          "this is the value the old single-band math produced")
    }

    func testShelfOvershootIsCovered() {
        let bands = [QxEqBandValue(filter: .lowShelf, freq: 105, gain: 9, q: 0.9)]
        let summed = EQHeadroom.peakBoost(of: bands)
        XCTAssertGreaterThan(summed, 9.0, "a resonant shelf overshoots its gain")
        XCTAssertLessThanOrEqual(ABTuner.safePreGain(for: bands, notAbove: 0),
                                 -summed + 0.05)
    }

    func testSessionPreGainPaysForTheTiltTheTrialsCanAdd() {
        let bands = [peak(1000, 4, 1.0)]
        let withoutTilt = ABTuner.safePreGain(for: bands, notAbove: 0)
        let withTilt = ABTuner.safePreGain(for: bands, notAbove: 0,
                                           plusBoost: ABTuner.tiltCap)
        XCTAssertLessThan(withTilt, withoutTilt)
        XCTAssertEqual(withTilt, EQHeadroom.clamp(withoutTilt - ABTuner.tiltCap),
                       accuracy: 0.001)
    }

    func testTrebleMacroWeightsTrebleFrequenciesNotBandIndices() {
        let treble = ABTuner.macros.first { $0.name.hasPrefix("Treble") }!

        XCTAssertEqual(ABTuner.weight(treble.shape, atHz: 250), 0, accuracy: 0.01)
        XCTAssertEqual(ABTuner.weight(treble.shape, atHz: 710), 0, accuracy: 0.01)
        XCTAssertGreaterThan(ABTuner.weight(treble.shape, atHz: 8000), 0.9)
        XCTAssertGreaterThan(ABTuner.weight(treble.shape, atHz: 16000), 0.9)
    }

    func testWeightMatchesTheAuthoredShapeAtItsOwnFrequencies() {
        for m in ABTuner.macros {
            for (i, hz) in QxEq.defaultFreqs.enumerated() {
                XCTAssertEqual(ABTuner.weight(m.shape, atHz: hz), m.shape[i], accuracy: 0.0001,
                               "\(m.name) at \(hz) Hz")
            }
        }
    }

    func testWeightHoldsAtTheEdgesRatherThanCollapsing() {
        let treble = ABTuner.macros.first { $0.name.hasPrefix("Treble") }!
        XCTAssertEqual(ABTuner.weight(treble.shape, atHz: 20000),
                       treble.shape.last!, accuracy: 0.0001)
        XCTAssertEqual(ABTuner.weight(treble.shape, atHz: 20),
                       treble.shape.first!, accuracy: 0.0001)
    }

    func testNeverRaisesTheUsersPreGain() {
        XCTAssertEqual(ABTuner.safePreGain(for: flat(), notAbove: -5), -5, accuracy: 0.001)
        XCTAssertEqual(ABTuner.safePreGain(for: flat(), notAbove: -11), -11, accuracy: 0.001)
    }

    func testFlatCurveAtZeroStaysAtZero() {
        XCTAssertEqual(ABTuner.safePreGain(for: flat(), notAbove: 0), 0, accuracy: 0.001)
    }

    func testNeverPositive() {
        for userValue in stride(from: -12.0, through: 12.0, by: 1.5) {
            XCTAssertLessThanOrEqual(ABTuner.safePreGain(for: flat(), notAbove: userValue), 0)
            XCTAssertLessThanOrEqual(
                ABTuner.safePreGain(for: [peak(1000, 6, 1.0)], notAbove: userValue), 0)
        }
    }

    func testClampsToTheDeviceFloor() {
        let huge = QxEq.defaultFreqs.map { QxEqBandValue(filter: .peak, freq: $0, gain: 12, q: 0.5) }
        let g = ABTuner.safePreGain(for: huge, notAbove: 0, plusBoost: ABTuner.tiltCap)
        XCTAssertEqual(g, EQHeadroom.range.lowerBound, accuracy: 0.001)
    }
}
