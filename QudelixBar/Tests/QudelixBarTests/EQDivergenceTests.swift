import XCTest
@testable import QudelixBar

final class EQDivergenceTests: XCTestCase {
    private func peak(_ freq: Int, _ gain: Double, q: Double = 1.0) -> QxEqBandValue {
        QxEqBandValue(filter: .peak, freq: freq, gain: gain, q: q)
    }

    private var flat: [QxEqBandValue] {
        QxEq.defaultFreqs.map { QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1.0) }
    }

    private func response(_ bands: [QxEqBandValue]) -> [Double] {
        EQCurve.response(bands: bands, preGain: 0)
    }

    private func clampedForDevice(_ bands: [QxEqBandValue], bandCount: Int = 10) -> [QxEqBandValue] {
        bands.prefix(bandCount).map { band in
            var b = band
            b.gain = max(-12, min(12, b.gain))
            b.q = max(0.1, min(10, b.q))
            b.freq = max(20, min(20000, b.freq))
            return b
        }
    }

    func testIdenticalCurvesReadAsNoDivergence() {
        let bands = [peak(100, 4), peak(1000, -3), peak(8000, 6, q: 2)]
        let curve = response(bands)
        XCTAssertNil(EQDivergence.reading(requested: curve, applied: curve))
    }

    func testCurveTheDeviceTookVerbatimReadsAsNoDivergence() {
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
        XCTAssertNil(EQDivergence.reading(requested: [0, .nan, 0, 0],
                                          applied: [0, 0, 0, 0]))
        XCTAssertNil(EQDivergence.reading(requested: [0, .infinity, 0, 0],
                                          applied: [0, 0, 0, 0]))
    }

    func testClampedGainShowsUpAsTheGainThatWasLost() {
        let asked = [peak(1000, 18, q: 1.4)]
        let gap = EQDivergence.reading(requested: response(asked),
                                       applied: response(clampedForDevice(asked)))
        let reading = try! XCTUnwrap(gap)
        XCTAssertEqual(reading.peak, 6, accuracy: 0.05)
        let freqs = EQCurve.logSweep(count: reading.deltas.count)
        XCTAssertEqual(freqs[reading.peakIndex], 1000, accuracy: 25)
    }

    func testTheSignSaysWhichWayTheDeviceMissed() {
        let asked = [peak(200, -20)]
        let reading = try! XCTUnwrap(EQDivergence.reading(
            requested: response(asked), applied: response(clampedForDevice(asked))))
        XCTAssertLessThan(reading.peak, 0)
        XCTAssertEqual(reading.peak, -8, accuracy: 0.05)
    }

    func testBandsDroppedForTheModeShowUpAtTheirOwnFrequency() {
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
        let asked = [peak(1000, 14, q: 1.0), peak(1000, -14, q: 1.0)]
        let applied = [peak(1000, 12, q: 1.0), peak(1000, -12, q: 1.0)]
        XCTAssertNil(EQDivergence.reading(requested: response(asked),
                                          applied: response(applied)))
    }

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
