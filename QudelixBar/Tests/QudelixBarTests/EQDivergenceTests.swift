import XCTest
@testable import QudelixBar

/// The comparison behind the requested-versus-applied overlay.
///
/// The property that matters most here is the negative one: a curve the device
/// took verbatim must produce *nothing*. A ghost line that is always present
/// teaches the user to stop seeing it, and by the time a correction really is
/// being reshaped there is no signal left in the ink.
final class EQDivergenceTests: XCTestCase {

    // MARK: - Helpers

    private func peak(_ freq: Int, _ gain: Double, q: Double = 1.0) -> QxEqBandValue {
        QxEqBandValue(filter: .peak, freq: freq, gain: gain, q: q)
    }

    private var flat: [QxEqBandValue] {
        QxEq.defaultFreqs.map { QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1.0) }
    }

    private func response(_ bands: [QxEqBandValue]) -> [Double] {
        EQCurve.response(bands: bands, preGain: 0)
    }

    /// What `QudelixController.apply` does to a parsed file on the way to the
    /// wire, so the tests compare against the real reshaping rather than an
    /// idealised one.
    private func clampedForDevice(_ bands: [QxEqBandValue], bandCount: Int = 10) -> [QxEqBandValue] {
        bands.prefix(bandCount).map { band in
            var b = band
            b.gain = max(-12, min(12, b.gain))
            b.q = max(0.1, min(10, b.q))
            b.freq = max(20, min(20000, b.freq))
            return b
        }
    }

    // MARK: - Nothing to say

    func testIdenticalCurvesReadAsNoDivergence() {
        let bands = [peak(100, 4), peak(1000, -3), peak(8000, 6, q: 2)]
        let curve = response(bands)
        XCTAssertNil(EQDivergence.reading(requested: curve, applied: curve))
    }

    func testCurveTheDeviceTookVerbatimReadsAsNoDivergence() {
        // Every band already inside ±12 dB, Q 0.1…10, 20 Hz…20 kHz, and fewer
        // bands than the mode holds: clamping is a no-op and there is nothing
        // to draw.
        let asked = [peak(60, -5, q: 0.7), peak(900, 3.5), peak(11000, 11.9, q: 4)]
        XCTAssertNil(EQDivergence.reading(requested: response(asked),
                                          applied: response(clampedForDevice(asked))))
    }

    func testFlatAgainstFlatReadsAsNoDivergence() {
        XCTAssertNil(EQDivergence.reading(requested: response(flat),
                                          applied: response(flat)))
    }

    func testDifferenceInsideToleranceReadsAsNoDivergence() {
        let applied = response([peak(1000, 6)])
        let requested = applied.map { $0 + EQDivergence.tolerance * 0.9 }
        XCTAssertNil(EQDivergence.reading(requested: requested, applied: applied))
    }

    func testDifferenceJustOverToleranceIsReported() {
        let applied = response([peak(1000, 6)])
        let requested = applied.map { $0 + EQDivergence.tolerance * 1.1 }
        let gap = EQDivergence.reading(requested: requested, applied: applied)
        XCTAssertNotNil(gap)
        XCTAssertEqual(gap?.peak ?? 0, EQDivergence.tolerance * 1.1,
                       accuracy: 1e-9)
    }

    func testMismatchedGridsReadAsNothing() {
        XCTAssertNil(EQDivergence.reading(requested: [1, 2, 3], applied: [1, 2]))
    }

    func testTooFewSamplesReadAsNothing() {
        XCTAssertNil(EQDivergence.reading(requested: [], applied: []))
        XCTAssertNil(EQDivergence.reading(requested: [9], applied: [0]))
    }

    func testNonFiniteSampleReadsAsNothingRatherThanAgreement() {
        // Silence is the honest answer: a zero gap here would be a claim that
        // the device matched the request.
        XCTAssertNil(EQDivergence.reading(requested: [0, .nan, 0, 0],
                                          applied: [0, 0, 0, 0]))
        XCTAssertNil(EQDivergence.reading(requested: [0, .infinity, 0, 0],
                                          applied: [0, 0, 0, 0]))
    }

    // MARK: - The gap itself

    func testClampedGainShowsUpAsTheGainThatWasLost() {
        // A +18 dB request against the +12 dB the device accepts: the widest
        // gap is 6 dB, at the band's own centre frequency.
        let asked = [peak(1000, 18, q: 1.4)]
        let gap = EQDivergence.reading(requested: response(asked),
                                       applied: response(clampedForDevice(asked)))
        let reading = try! XCTUnwrap(gap)
        XCTAssertEqual(reading.peak, 6, accuracy: 0.05)
        let freqs = EQCurve.logSweep(count: reading.deltas.count)
        XCTAssertEqual(freqs[reading.peakIndex], 1000, accuracy: 25)
    }

    func testTheSignSaysWhichWayTheDeviceMissed() {
        // Asked for less cut than the device could take? Impossible. Asked for
        // more cut than ±12 allows: the applied curve sits *above* the request,
        // so the gap is negative.
        let asked = [peak(200, -20)]
        let reading = try! XCTUnwrap(EQDivergence.reading(
            requested: response(asked), applied: response(clampedForDevice(asked))))
        XCTAssertLessThan(reading.peak, 0)
        XCTAssertEqual(reading.peak, -8, accuracy: 0.05)
    }

    func testBandsDroppedForTheModeShowUpAtTheirOwnFrequency() {
        // Eleven bands into a ten-band mode: the eleventh never reaches the
        // device, and the divergence should land where that band lived rather
        // than being smeared across the axis.
        var asked = (0..<10).map { peak(100 + $0 * 100, 0) }
        asked.append(peak(6000, 9, q: 1.2))
        let reading = try! XCTUnwrap(EQDivergence.reading(
            requested: response(asked),
            applied: response(clampedForDevice(asked, bandCount: 10))))
        XCTAssertEqual(reading.peak, 9, accuracy: 0.1)
        let freqs = EQCurve.logSweep(count: reading.deltas.count)
        XCTAssertEqual(freqs[reading.peakIndex], 6000, accuracy: 150)
    }

    func testDivergenceIsLocalToTheBandThatWasReshaped() {
        // A clamp at 40 Hz must not colour the top of the axis: "where" is the
        // whole reason this drawing exists.
        let asked = [peak(40, 20, q: 1.0)]
        let reading = try! XCTUnwrap(EQDivergence.reading(
            requested: response(asked), applied: response(clampedForDevice(asked))))
        let freqs = EQCurve.logSweep(count: reading.deltas.count)
        for (i, f) in freqs.enumerated() where f > 2000 {
            XCTAssertLessThan(abs(reading.deltas[i]), EQDivergence.tolerance,
                              "bass clamp leaked to \(Int(f)) Hz")
        }
        XCTAssertTrue(reading.spans.allSatisfy { freqs[$0.upperBound] < 2000 })
    }

    func testClampsThatCancelAreNotReportedAsDivergence() {
        // Two reshaped bands whose errors happen to undo each other leave the
        // response where it was asked to be, and a per-band count would still
        // report two. Comparing responses reports none, which is what the user
        // is actually hearing.
        let asked = [peak(1000, 14, q: 1.0), peak(1000, -14, q: 1.0)]
        let applied = [peak(1000, 12, q: 1.0), peak(1000, -12, q: 1.0)]
        XCTAssertNil(EQDivergence.reading(requested: response(asked),
                                          applied: response(applied)))
    }

    // MARK: - Spans

    func testSpansCoverTheRunAndOneSampleEitherSide() {
        let deltas: [Double] = [0, 0, 1, 1, 0, 0, 0]
        XCTAssertEqual(EQDivergence.spans(of: deltas, above: 0.25), [1...4])
    }

    func testSpansUseMagnitudeSoCutsCountToo() {
        XCTAssertEqual(EQDivergence.spans(of: [0, -1, 0], above: 0.25), [0...2])
    }

    func testSpansClampToTheEndsOfTheGrid() {
        XCTAssertEqual(EQDivergence.spans(of: [1, 1, 0, 0], above: 0.25), [0...2])
        XCTAssertEqual(EQDivergence.spans(of: [0, 0, 1, 1], above: 0.25), [1...3])
    }

    func testSpansMergeWhenWideningMakesThemTouch() {
        // One sample under the tolerance between two divergent runs is not two
        // separate stories.
        XCTAssertEqual(EQDivergence.spans(of: [0, 1, 0, 1, 0], above: 0.25), [0...4])
    }

    func testDistantSpansStaySeparate() {
        let deltas: [Double] = [1, 0, 0, 0, 0, 0, 1]
        XCTAssertEqual(EQDivergence.spans(of: deltas, above: 0.25), [0...1, 5...6])
    }

    func testNoSpansWhenNothingExceedsTheThreshold() {
        XCTAssertEqual(EQDivergence.spans(of: [0, 0.2, -0.1], above: 0.25), [])
        XCTAssertEqual(EQDivergence.spans(of: [], above: 0.25), [])
    }

    func testSpansStayInsideTheGridForARunThatFillsIt() {
        XCTAssertEqual(EQDivergence.spans(of: [1, 1, 1], above: 0.25), [0...2])
    }

    func testEveryReportedSpanContainsAnAboveToleranceSample() {
        // Guards the widening against creeping into regions that were never
        // divergent in the first place.
        let asked = [peak(120, 16, q: 0.8), peak(9000, -18, q: 3)]
        let reading = try! XCTUnwrap(EQDivergence.reading(
            requested: response(asked), applied: response(clampedForDevice(asked))))
        XCTAssertFalse(reading.spans.isEmpty)
        for span in reading.spans {
            XCTAssertTrue(span.contains { abs(reading.deltas[$0]) > EQDivergence.tolerance })
            XCTAssertTrue(reading.deltas.indices.contains(span.lowerBound))
            XCTAssertTrue(reading.deltas.indices.contains(span.upperBound))
        }
        XCTAssertTrue(reading.deltas.indices.contains(reading.peakIndex))
    }
}
