import Combine
import XCTest
@testable import QudelixBar

@MainActor
final class ReadbackRepaintTests: XCTestCase {
    private func readback(gain: Double = 3, preGain: Double = -2) -> QxUserEqPreset {
        var p = QxUserEqPreset()
        p.preGain = preGain
        p.preGainCh1 = preGain
        p.crossfeedLevel = 0
        p.bands = QxEq.defaultFreqs.map {
            QxEqBandValue(filter: .peak, freq: $0, gain: gain, q: 1.0)
        }
        return p
    }

    func testAnUnchangedReadbackDoesNotRepublishTheBands() {
        let c = QudelixController()
        var emissions = 0
        let sub = c.$bands.sink { _ in emissions += 1 }
        XCTAssertEqual(emissions, 1, "the subscription itself sees the current value")

        c.applyPreset(readback())
        XCTAssertEqual(emissions, 2, "the first read-back really did change the curve")
        XCTAssertEqual(c.bands.first?.gain, 3)

        c.applyPreset(readback())
        c.applyPreset(readback())
        XCTAssertEqual(emissions, 2, "identical polls must not repaint the band table")

        c.applyPreset(readback(gain: 4))
        XCTAssertEqual(emissions, 3, "a curve that really moved still gets through")
        XCTAssertEqual(c.bands.first?.gain, 4)
        sub.cancel()
    }

    func testAnUnchangedReadbackDoesNotRepublishThePreGain() {
        let c = QudelixController()
        var emissions = 0
        let sub = c.$preGain.sink { _ in emissions += 1 }
        XCTAssertEqual(emissions, 1)

        c.applyPreset(readback())
        XCTAssertEqual(emissions, 2)
        XCTAssertEqual(c.preGain, -2)

        c.applyPreset(readback())
        c.applyPreset(readback())
        XCTAssertEqual(emissions, 2, "identical polls must not redraw the pre-gain row")

        c.applyPreset(readback(preGain: -4))
        XCTAssertEqual(emissions, 3)
        XCTAssertEqual(c.preGain, -4)
        sub.cancel()
    }

    func testAPreGainTheDeviceReportsOutOfRangeIsStillClampedOnce() {
        let c = QudelixController()
        c.applyPreset(readback(preGain: -20))
        XCTAssertEqual(c.preGain, EQHeadroom.range.lowerBound)
        var emissions = 0
        let sub = c.$preGain.sink { _ in emissions += 1 }
        c.applyPreset(readback(preGain: -20))
        XCTAssertEqual(emissions, 1, "the clamped value is what the comparison sees")
        sub.cancel()
    }

    func testTheHeadroomAdviceIsWorkedOutOncePerCurve() {
        let c = QudelixController()
        c.bands = [QxEqBandValue(filter: .peak, freq: 1000, gain: 6, q: 1)]
        let before = c.headroomComputations

        let first = c.eqHeadroom
        XCTAssertEqual(c.headroomComputations, before + 1)

        for _ in 0..<50 { _ = c.eqHeadroom }
        XCTAssertEqual(c.headroomComputations, before + 1,
                       "a drag frame reads this several times and must pay once")
        XCTAssertEqual(c.eqHeadroom, first)

        c.preGain = -3
        _ = c.eqHeadroom
        XCTAssertEqual(c.headroomComputations, before + 2, "a pre-gain write invalidates it")

        c.bands[0].gain = 9
        _ = c.eqHeadroom
        XCTAssertEqual(c.headroomComputations, before + 3, "a band edit invalidates it")
    }

    func testTheRememberedAdviceIsTheSameAnswerAFreshOneWouldGive() {
        let c = QudelixController()
        let curve: [QxEqBandValue] = [
            QxEqBandValue(filter: .lowShelf, freq: 105, gain: 6.4, q: 0.7),
            QxEqBandValue(filter: .peak, freq: 1200, gain: 2.2, q: 4.0),
            QxEqBandValue(filter: .highShelf, freq: 10000, gain: -4.8, q: 0.7),
        ]
        for preGain in [0.0, -3.5, -12, 6] {
            c.bands = curve
            c.preGain = preGain
            XCTAssertEqual(c.eqHeadroom, EQHeadroom.advice(for: curve, preGain: preGain))
            XCTAssertEqual(c.eqHeadroom, EQHeadroom.advice(for: curve, preGain: preGain))
        }

        c.bands = curve
        c.preGain = 0
        _ = c.eqHeadroom
        let computed = c.headroomComputations
        c.bands[1].gain = 11
        XCTAssertEqual(c.eqHeadroom, EQHeadroom.advice(for: c.bands, preGain: 0))
        XCTAssertEqual(c.headroomComputations, computed + 1)
    }
}
