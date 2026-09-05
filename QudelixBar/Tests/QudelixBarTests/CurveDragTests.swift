import XCTest
@testable import QudelixBar

/// Dragging a node on the response curve. The gesture itself isn't unit
/// testable, but the rule that decides where a dragged band is allowed to land
/// is — and it is the part that fails quietly: a band that slips past its
/// neighbour reorders the curve underneath the band table without anything
/// looking wrong on screen.
@MainActor
final class CurveDragTests: XCTestCase {

    private func bands(_ freqs: [Int]) -> [QxEqBandValue] {
        freqs.map { QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1.0) }
    }

    private var ratio: Double { EQCurveView.minNeighbourRatio }

    func testADragInsideTheGapIsLeftAlone() {
        let b = bands([100, 1000, 10000])
        XCTAssertEqual(EQCurveView.clampedFrequency(2000, forBand: 1, in: b), 2000)
        XCTAssertEqual(EQCurveView.clampedFrequency(500, forBand: 1, in: b), 500)
    }

    /// The whole point: a band cannot be dragged past the one below it.
    func testCannotBeDraggedBelowItsLowerNeighbour() {
        let b = bands([100, 1000, 10000])
        let got = EQCurveView.clampedFrequency(20, forBand: 1, in: b)
        XCTAssertGreaterThan(got, 100, "must stay above the 100 Hz band")
        XCTAssertEqual(Double(got), 100 * ratio, accuracy: 1.5)
    }

    func testCannotBeDraggedAboveItsUpperNeighbour() {
        let b = bands([100, 1000, 10000])
        let got = EQCurveView.clampedFrequency(19000, forBand: 1, in: b)
        XCTAssertLessThan(got, 10000, "must stay below the 10 kHz band")
        XCTAssertEqual(Double(got), 10000 / ratio, accuracy: 60)
    }

    /// The outermost bands have only one neighbour and are free to the edge.
    func testEdgeBandsAreOnlyClampedOnTheSideThatHasANeighbour() {
        let b = bands([100, 1000, 10000])
        XCTAssertEqual(EQCurveView.clampedFrequency(20, forBand: 0, in: b), 20)
        XCTAssertEqual(EQCurveView.clampedFrequency(20000, forBand: 2, in: b), 20000)
    }

    func testResultNeverLeavesTheDevicesFrequencyRange() {
        let b = bands([100, 1000, 10000])
        for wanted in [-500.0, 0, 1, 19_999, 50_000, 1_000_000] {
            for i in 0..<b.count {
                let got = EQCurveView.clampedFrequency(wanted, forBand: i, in: b)
                XCTAssertTrue((20...20000).contains(got), "\(wanted) on band \(i) gave \(got)")
            }
        }
    }

    /// Neighbours are decided by frequency, not array position. A typed edit
    /// can leave the array unsorted, and an index-based clamp would then let a
    /// drag jump the wrong band — or pin it against one that isn't adjacent.
    func testUnsortedBandArrayStillClampsAgainstTheRealNeighbours() {
        let b = bands([10000, 100, 1000])          // deliberately out of order
        // Band 2 is 1000 Hz; its true neighbours are 100 and 10000.
        XCTAssertEqual(Double(EQCurveView.clampedFrequency(20, forBand: 2, in: b)),
                       100 * ratio, accuracy: 1.5)
        XCTAssertEqual(Double(EQCurveView.clampedFrequency(19000, forBand: 2, in: b)),
                       10000 / ratio, accuracy: 60)
    }

    /// A bypassed band draws no marker, so it is not something a drag can
    /// collide with — treating it as an obstacle would pin a drag against a
    /// band the user cannot see.
    func testBypassedBandsAreNotObstacles() {
        var b = bands([100, 1000, 10000])
        b[0].filter = .bypass
        XCTAssertEqual(EQCurveView.clampedFrequency(30, forBand: 1, in: b), 30,
                       "the bypassed 100 Hz band must not block the drag")
    }

    func testOutOfRangeBandIndexIsRefusedRatherThanTrapping() {
        let b = bands([100, 1000])
        for i in [-1, 2, 99] {
            XCTAssertEqual(EQCurveView.clampedFrequency(500, forBand: i, in: b), 1000)
        }
    }

    /// Two bands already at the same frequency must not deadlock the clamp
    /// into an impossible range.
    func testDuplicateFrequenciesDoNotProduceAnInvalidResult() {
        let b = bands([1000, 1000, 1000])
        for i in 0..<b.count {
            let got = EQCurveView.clampedFrequency(1500, forBand: i, in: b)
            XCTAssertTrue((20...20000).contains(got))
        }
    }

    func testATiedNeighbourStillBlocksTheDrag() {
        let b = bands([1000, 1000])
        let lower = EQCurveView.clampedFrequency(200, forBand: 1, in: b)
        XCTAssertGreaterThan(lower, 1000, "band 1 sits above the tie, and must stay there")
        let upper = EQCurveView.clampedFrequency(9000, forBand: 0, in: b)
        XCTAssertLessThan(upper, 1000, "band 0 sits below the tie, and must stay there")
    }

    func testOrderingIsPreservedAcrossADuplicatedLayout() {
        let b = bands([500, 500, 500, 500])
        var placed: [Int] = []
        for i in 0..<b.count {
            placed.append(EQCurveView.clampedFrequency(Double(20 + i * 7000), forBand: i, in: b))
        }
        XCTAssertEqual(placed, placed.sorted(), "a drag must not reorder the bands: \(placed)")
    }

    func testPassFiltersMarkAtZeroRegardlessOfTheStoredGain() {
        var band = QxEqBandValue(filter: .lpf, freq: 8000, gain: -9, q: 0.7)
        XCTAssertEqual(EQCurveView.markerGain(band), 0)
        band.filter = .hpf
        XCTAssertEqual(EQCurveView.markerGain(band), 0)
        band.filter = .peak
        XCTAssertEqual(EQCurveView.markerGain(band), -9)
    }
}
