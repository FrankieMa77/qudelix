import XCTest
@testable import QudelixBar

/// The by-ear tuner runs a whole session at one fixed pre-gain, on the grounds
/// that a pre-gain moving between options would be a loudness cue and loudness
/// beats timbre. That only holds if the fixed value is actually low enough for
/// the loudest thing the session can produce.
final class ABTunerHeadroomTests: XCTestCase {

    private func peak(_ freq: Int, _ gain: Double, _ q: Double) -> QxEqBandValue {
        QxEqBandValue(filter: .peak, freq: freq, gain: gain, q: q)
    }

    private func flat() -> [QxEqBandValue] {
        QxEq.defaultFreqs.map { QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1.0) }
    }

    /// The regression. Three wide bands stacked at nearby frequencies each ask
    /// for +3 dB, so the largest single gain is 3 — but they overlap, and the
    /// response they sum to is meaningfully higher. The old code read the
    /// former and left the difference as clipping.
    func testOverlappingBandsSumBeyondTheLargestSingleGain() {
        let bands = [peak(950, 3, 0.7), peak(1000, 3, 0.7), peak(1050, 3, 0.7)]
        let largestSingle = bands.map(\.gain).max() ?? 0
        let summed = EQHeadroom.peakBoost(of: bands)

        XCTAssertGreaterThan(summed, largestSingle + 1.0,
                             "overlapping bands must sum well past any one of them")

        // The pre-gain has to cover the summed peak, not the single band.
        let g = ABTuner.safePreGain(for: bands, notAbove: 0)
        XCTAssertLessThanOrEqual(g, -summed + 0.05)
        XCTAssertLessThan(g, -largestSingle,
                          "this is the value the old single-band math produced")
    }

    /// A high-Q shelf peaks off its nominal corner and past its nominal gain,
    /// so its band gain alone also under-reports.
    func testShelfOvershootIsCovered() {
        let bands = [QxEqBandValue(filter: .lowShelf, freq: 105, gain: 9, q: 0.9)]
        let summed = EQHeadroom.peakBoost(of: bands)
        XCTAssertGreaterThan(summed, 9.0, "a resonant shelf overshoots its gain")
        XCTAssertLessThanOrEqual(ABTuner.safePreGain(for: bands, notAbove: 0),
                                 -summed + 0.05)
    }

    /// The trials add tilt on top of the curve being measured, and the session
    /// pre-gain has to have paid for that in advance.
    func testSessionPreGainPaysForTheTiltTheTrialsCanAdd() {
        let bands = [peak(1000, 4, 1.0)]
        let withoutTilt = ABTuner.safePreGain(for: bands, notAbove: 0)
        let withTilt = ABTuner.safePreGain(for: bands, notAbove: 0,
                                           plusBoost: ABTuner.tiltCap)
        XCTAssertLessThan(withTilt, withoutTilt)
        XCTAssertEqual(withTilt, EQHeadroom.clamp(withoutTilt - ABTuner.tiltCap),
                       accuracy: 0.001)
    }

    /// Never louder than the user had it, even when the curve needs nothing.
    func testNeverRaisesTheUsersPreGain() {
        XCTAssertEqual(ABTuner.safePreGain(for: flat(), notAbove: -5), -5, accuracy: 0.001)
        XCTAssertEqual(ABTuner.safePreGain(for: flat(), notAbove: -11), -11, accuracy: 0.001)
    }

    /// A flat curve with the pre-gain already at 0 stays at 0 — attenuation is
    /// only ever paid for a reason.
    func testFlatCurveAtZeroStaysAtZero() {
        XCTAssertEqual(ABTuner.safePreGain(for: flat(), notAbove: 0), 0, accuracy: 0.001)
    }

    /// The result is never positive, whatever the caller passes as the user's
    /// value — a positive pre-gain would reintroduce the clipping.
    func testNeverPositive() {
        for userValue in stride(from: -12.0, through: 12.0, by: 1.5) {
            XCTAssertLessThanOrEqual(ABTuner.safePreGain(for: flat(), notAbove: userValue), 0)
            XCTAssertLessThanOrEqual(
                ABTuner.safePreGain(for: [peak(1000, 6, 1.0)], notAbove: userValue), 0)
        }
    }

    /// A curve asking for more attenuation than the device can hold lands on
    /// the floor rather than off the end of it.
    func testClampsToTheDeviceFloor() {
        let huge = QxEq.defaultFreqs.map { QxEqBandValue(filter: .peak, freq: $0, gain: 12, q: 0.5) }
        let g = ABTuner.safePreGain(for: huge, notAbove: 0, plusBoost: ABTuner.tiltCap)
        XCTAssertEqual(g, EQHeadroom.range.lowerBound, accuracy: 0.001)
    }
}
