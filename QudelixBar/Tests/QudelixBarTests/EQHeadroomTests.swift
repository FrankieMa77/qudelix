import XCTest
@testable import QudelixBar

/// The pre-gain suggestion, tested against what the filters actually do.
///
/// The property that matters is one-sided: reading the peak too *high* costs a
/// fraction of a dB of level, while reading it too low is a dB of clipping the
/// user was told had been handled. So every accuracy check here compares
/// against a brute-force scan far denser than anything the app would run, and
/// asserts the suggestion is never the optimistic side of it.
final class EQHeadroomTests: XCTestCase {

    // MARK: - Helpers

    private func peak(_ freq: Int, _ gain: Double, q: Double = 1.0) -> QxEqBandValue {
        QxEqBandValue(filter: .peak, freq: freq, gain: gain, q: q)
    }

    private var flat: [QxEqBandValue] {
        QxEq.defaultFreqs.map { QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1.0) }
    }

    /// Brute force: 120k log-spaced points over the same span the search
    /// covers — a hundred-odd samples across even the narrowest feature the
    /// device can hold. Slow, exact enough to be the referee, and sharing
    /// nothing with the code under test but the biquad maths.
    private func bruteForcePeak(_ bands: [QxEqBandValue]) -> Double {
        let freqs = EQCurve.logSweep(count: 120_000, from: 10, to: 22000)
        return max(0, EQCurve.response(bands: bands, preGain: 0, at: freqs).max() ?? 0)
    }

    /// Deterministic noise, so a fuzz failure is reproducible.
    private var lcgState: UInt64 = 0x9E37_79B9_7F4A_7C15

    private func random(_ lo: Double, _ hi: Double) -> Double {
        lcgState = lcgState &* 6364136223846793005 &+ 1442695040888963407
        return lo + (hi - lo) * Double(lcgState >> 11) / Double(1 << 53)
    }

    /// A band set inside the limits `updateBand` enforces, so nothing here is
    /// a curve the device could never be holding.
    private func randomBands(count: Int) -> [QxEqBandValue] {
        let filters: [QxFilter] = [.peak, .peak, .peak, .lowShelf, .highShelf, .lpf, .hpf, .bypass]
        return (0..<count).map { _ in
            QxEqBandValue(filter: filters[Int(random(0, Double(filters.count)))],
                          freq: Int(random(20, 20000)),
                          gain: random(-12, 12),
                          q: random(0.1, 10))
        }
    }

    // MARK: - Nothing to do

    func testFlatCurveNeedsNoAttenuation() {
        XCTAssertEqual(EQHeadroom.peakBoost(of: flat), 0, accuracy: 1e-9)
        XCTAssertEqual(EQHeadroom.suggestedPreGain(for: flat), 0)

        let advice = EQHeadroom.advice(for: flat, preGain: 0)
        XCTAssertNil(advice.suggestion, "a flat curve must not offer an action")
        XCTAssertEqual(advice.shortfall, 0)
    }

    /// Cuts are free: nothing about them threatens the EQ stage's ceiling.
    func testCutOnlyCurveNeedsNoAttenuation() {
        let bands = [peak(120, -6, q: 1.4), peak(3000, -9, q: 2)]
        XCTAssertEqual(EQHeadroom.peakBoost(of: bands), 0, accuracy: 1e-9)
        XCTAssertNil(EQHeadroom.advice(for: bands, preGain: 0).suggestion)
    }

    /// A bypassed band is not in the signal path, whatever its stored gain.
    func testBypassedBandsAreIgnored() {
        var band = peak(1000, 12, q: 4)
        band.filter = .bypass
        XCTAssertEqual(EQHeadroom.peakBoost(of: [band]), 0, accuracy: 1e-9)
    }

    // MARK: - Known answers

    /// A peaking biquad's gain at its own centre is exactly the band gain, so
    /// this case has an arithmetic answer rather than a measured one.
    func testSingleBoostPeaksAtExactlyItsOwnGain() {
        for gain in [1.0, 4.5, 9.0, 12.0] {
            for f in [40, 400, 1000, 8000, 16000] {
                XCTAssertEqual(EQHeadroom.peakBoost(of: [peak(f, gain, q: 2)]), gain,
                               accuracy: 0.01, "peak \(gain) dB at \(f) Hz")
            }
        }
    }

    func testCoincidentBoostsSumExactly() {
        let stack = (0..<3).map { _ in peak(1000, 3, q: 1) }
        XCTAssertEqual(EQHeadroom.peakBoost(of: stack), 9, accuracy: 1e-6)
        XCTAssertEqual(EQHeadroom.suggestedPreGain(for: stack), -9, accuracy: 1e-9)
    }

    /// Overlapping but not coincident: the answer is no band's own gain, so
    /// the referee decides it.
    func testOverlappingBoostsSumToTheirCombinedPeak() {
        let cases: [[QxEqBandValue]] = [
            [peak(1000, 6, q: 1), peak(1260, 6, q: 1)],
            [peak(1000, 6, q: 1), peak(1260, 6, q: 1), peak(1580, 6, q: 1)],
            [peak(80, 5, q: 0.7), peak(140, 4, q: 0.7), peak(240, 3, q: 0.7)],
            [peak(2000, 9, q: 6), peak(2100, 9, q: 6)],
        ]
        for bands in cases {
            let reference = bruteForcePeak(bands)
            let found = EQHeadroom.peakBoost(of: bands)
            XCTAssertEqual(found, reference, accuracy: 0.05, "bands \(bands)")
            XCTAssertGreaterThan(found, bands.map(\.gain).max()!,
                                 "overlap must read higher than any one band")
        }
    }

    // MARK: - The under-sampling trap

    /// The case a drawing-resolution grid gets wrong.
    ///
    /// A biquad's width is `sin(w0)/Q` radians, so a Q = 10 band is far
    /// narrower at 6 kHz than at 1 kHz and can fall clean between two points
    /// of a 220-point log grid. The search has to find it wherever it sits.
    func testNarrowPeaksAreFoundWhereverTheySit() {
        for f in [50, 63, 125, 315, 800, 1000, 3150, 6300, 9000, 12000, 16000, 19000] {
            let bands = [peak(f, 12, q: 10)]
            XCTAssertEqual(EQHeadroom.peakBoost(of: bands), 12, accuracy: 0.05,
                           "Q=10 peak at \(f) Hz")
        }
    }

    /// And a demonstration that the grid the curve is drawn with really would
    /// have missed it — this is what the extra sampling is buying.
    func testDrawingResolutionWouldUnderreadANarrowPeak() {
        let bands = [peak(6300, 12, q: 10)]
        let drawn = EQCurve.response(bands: bands, preGain: 0, count: 220).max() ?? 0
        XCTAssertLessThan(drawn, 11.4, "the 220-point grid should miss this peak")
        XCTAssertEqual(EQHeadroom.peakBoost(of: bands), 12, accuracy: 0.05)
    }

    // MARK: - Shelves

    /// A shelf's boost is its asymptote, which lies outside the drawn window
    /// when the corner is near the edge of the band.
    func testShelvesReportTheirFullAsymptote() {
        for f in [100, 1000, 8000, 16000] {
            XCTAssertEqual(EQHeadroom.peakBoost(of: [QxEqBandValue(
                filter: .highShelf, freq: f, gain: 6, q: 0.707)]), 6, accuracy: 0.1,
                "high shelf at \(f) Hz")
            XCTAssertEqual(EQHeadroom.peakBoost(of: [QxEqBandValue(
                filter: .lowShelf, freq: f, gain: 6, q: 0.707)]), 6, accuracy: 0.1,
                "low shelf at \(f) Hz")
        }
    }

    /// A high-Q shelf overshoots its asymptote, and does it half an octave off
    /// the nominal corner — looking only at the corner reads it more than a dB
    /// low.
    func testHighQShelfOvershootIsFound() {
        let cases: [[QxEqBandValue]] = [
            [QxEqBandValue(filter: .lowShelf, freq: 120, gain: 10, q: 8)],
            [QxEqBandValue(filter: .highShelf, freq: 12000, gain: 10, q: 8)],
            [QxEqBandValue(filter: .highShelf, freq: 19400, gain: 7, q: 7.8)],
            [QxEqBandValue(filter: .lowShelf, freq: 10500, gain: 11, q: 9)],
        ]
        for bands in cases {
            let reference = bruteForcePeak(bands)
            XCTAssertEqual(EQHeadroom.peakBoost(of: bands), reference, accuracy: 0.05,
                           "bands \(bands)")
            XCTAssertGreaterThan(reference, bands[0].gain,
                                 "a Q this high should ring past the shelf's own gain")
        }
    }

    /// A resonant LPF boosts even though it has no gain of its own.
    func testResonantFilterBoostIsCounted() {
        let bands = [QxEqBandValue(filter: .lpf, freq: 1000, gain: 0, q: 10)]
        XCTAssertEqual(EQHeadroom.peakBoost(of: bands), bruteForcePeak(bands), accuracy: 0.05)
        XCTAssertGreaterThan(EQHeadroom.peakBoost(of: bands), 15)
    }

    // MARK: - The device's range

    func testClampHoldsTheDeviceRange() {
        XCTAssertEqual(EQHeadroom.range, -12...12)
        XCTAssertEqual(EQHeadroom.clamp(-40), -12)
        XCTAssertEqual(EQHeadroom.clamp(40), 12)
        XCTAssertEqual(EQHeadroom.clamp(-3.5), -3.5)
        // Nothing finite is a sensible reading of a non-finite input, so it
        // resolves to no pre-gain at all rather than to either extreme.
        XCTAssertEqual(EQHeadroom.clamp(.nan), 0)
        XCTAssertEqual(EQHeadroom.clamp(.infinity), 0)
        XCTAssertEqual(EQHeadroom.clamp(-.infinity), 0)
    }

    /// Four coincident +6 dB bands need 24 dB of headroom; the device has 12.
    func testSuggestionIsClampedAndTheShortfallIsReported() {
        let stack = (0..<4).map { _ in peak(1000, 6, q: 1) }
        XCTAssertEqual(EQHeadroom.peakBoost(of: stack), 24, accuracy: 1e-6)
        XCTAssertEqual(EQHeadroom.suggestedPreGain(for: stack), -12)

        let advice = EQHeadroom.advice(for: stack, preGain: 0)
        XCTAssertEqual(advice.suggestion, -12)
        XCTAssertEqual(advice.shortfall, 12, accuracy: 1e-6)
    }

    /// The number offered is one the device can store, so the value written is
    /// the value shown.
    func testSuggestionLandsOnTheDevicesOwnStep() {
        for _ in 0..<60 {
            let value = EQHeadroom.suggestedPreGain(for: randomBands(count: 6))
            XCTAssertEqual((value * 10).rounded(), value * 10, accuracy: 1e-9,
                           "\(value) is not a whole 0.1 dB step")
        }
    }

    // MARK: - Attenuation only

    func testSuggestionIsNeverPositiveAcrossRandomCurves() {
        for _ in 0..<120 {
            let bands = randomBands(count: 10)
            let value = EQHeadroom.suggestedPreGain(for: bands)
            XCTAssertTrue(EQHeadroom.range.contains(value), "\(value) out of range")
            XCTAssertLessThanOrEqual(value, 0, "pre-gain must never be proposed upward")

            // And the same through the advice, from wherever the user is now.
            for current in [-12.0, -0.5, 0.0, 12.0] {
                guard let offered = EQHeadroom.advice(for: bands, preGain: current).suggestion
                else { continue }
                XCTAssertLessThanOrEqual(offered, 0)
                XCTAssertTrue(EQHeadroom.range.contains(offered))
                XCTAssertLessThan(offered, current, "an offer must be more attenuation")
            }
        }
    }

    /// The referee, over random curves: the suggestion may be generous, never
    /// optimistic.
    func testSuggestionNeverUnderreadsTheBruteForcePeak() {
        for _ in 0..<15 {
            let bands = randomBands(count: 5)
            let reference = bruteForcePeak(bands)
            let found = EQHeadroom.peakBoost(of: bands)
            XCTAssertEqual(found, reference, accuracy: 0.05, "bands \(bands)")

            // Whatever slack is left has to be inside the step the device
            // stores, or the rounded suggestion would be short.
            if reference > 0.1 && reference < 12 {
                XCTAssertLessThanOrEqual(-EQHeadroom.suggestedPreGain(for: bands),
                                         reference + 0.1)
                XCTAssertGreaterThanOrEqual(-EQHeadroom.suggestedPreGain(for: bands),
                                            reference - 0.1)
            }
        }
    }

    // MARK: - When to keep quiet

    func testNoActionOfferedWhenThePreGainAlreadyCoversTheBoost() {
        let bands = [peak(1000, 6, q: 1)]
        XCTAssertEqual(EQHeadroom.advice(for: bands, preGain: 0).suggestion, -6)
        XCTAssertNil(EQHeadroom.advice(for: bands, preGain: -6).suggestion,
                     "exactly enough is enough")
        XCTAssertNil(EQHeadroom.advice(for: bands, preGain: -9).suggestion,
                     "deeper than needed is the user's choice, not a fault")
        // Still reported, so the row can say what the curve is doing.
        XCTAssertEqual(EQHeadroom.advice(for: bands, preGain: -9).peakBoost, 6, accuracy: 0.01)
    }

    func testAnUpwardPreGainStillGetsAnOffer() {
        let bands = [peak(1000, 3, q: 1)]
        XCTAssertEqual(EQHeadroom.advice(for: bands, preGain: 6).suggestion, -3)
    }

    // MARK: - Through the controller

    @MainActor
    func testControllerReportsHeadroomForTheCurveItHolds() {
        let c = QudelixController()
        c.bands = [peak(1000, 6, q: 1)]
        XCTAssertEqual(c.eqHeadroom.peakBoost, 6, accuracy: 0.01)
        XCTAssertEqual(c.eqHeadroom.suggestion, -6)
    }

    /// Applying the suggestion is an ordinary pre-gain write, so it obeys the
    /// same gate: a disconnected controller must not move.
    @MainActor
    func testApplyingTheSuggestionRespectsTheWriteGate() {
        let c = QudelixController()
        c.bands = [peak(1000, 6, q: 1)]
        XCTAssertEqual(c.connection, .disconnected)
        c.applySuggestedPreGain()
        XCTAssertEqual(c.preGain, 0, "no write is authorised yet")
    }
}
