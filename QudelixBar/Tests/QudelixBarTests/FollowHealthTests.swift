import XCTest
@testable import QudelixBar

final class FollowHealthTests: XCTestCase {
    private typealias Health = ReferenceFollower.FollowHealth
    private typealias Band = QxEqBandValue

    private let mild = ReferenceFollower.Target(
        bands: [Band(filter: .peak, freq: 1000, gain: 3, q: 1)], anchors: [], offsetDb: 0)
    private let wide = ReferenceFollower.Target(
        bands: [Band(filter: .peak, freq: 1000, gain: 9, q: 1)], anchors: [], offsetDb: 0)

    private func display(gain: Double) -> [Band] {
        [Band(filter: .peak, freq: 1000, gain: gain, q: 1),
         Band(filter: .peak, freq: 4000, gain: 0, q: 1)]
    }

    private func feed(_ health: inout Health, _ values: [Double], target: ReferenceFollower.Target,
                      changed: Bool = false) -> [Bool] {
        values.map {
            health.failing(deviationDb: $0, display: display(gain: 0), target: target,
                           pinned: [0, 1], targetChanged: changed)
        }
    }

    func testHealthyRunNeverTrips() {
        var health = Health()
        XCTAssertEqual(feed(&health, [2, 1.5, 1, 0.5, 0.2, 0.2, 0.2, 0.2], target: mild),
                       [Bool](repeating: false, count: 8))
    }

    func testRisingDeviationTripsOnTheFifthRise() {
        var health = Health()
        let flags = feed(&health, [2.0, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6], target: mild)
        XCTAssertEqual(flags, [false, false, false, false, false, true, true])
    }

    func testRiseBelowTheFloorIsIgnored() {
        var health = Health()
        let flags = feed(&health, [0.1, 0.4, 0.7, 1.0, 1.3, 1.45, 1.49], target: mild)
        XCTAssertFalse(flags.contains(true))
        XCTAssertEqual(health.risingTicks, 0)
    }

    func testRiseWithinTheNoiseBandIsIgnored() {
        var health = Health()
        let flags = feed(&health, [3.00, 3.04, 3.08, 3.12, 3.16, 3.20, 3.24], target: mild)
        XCTAssertFalse(flags.contains(true))
    }

    func testAFallResetsTheRisingCount() {
        var health = Health()
        _ = feed(&health, [2.0, 2.2, 2.4, 2.6, 2.8], target: mild)
        XCTAssertEqual(health.risingTicks, 4)
        _ = feed(&health, [2.0], target: mild)
        XCTAssertEqual(health.risingTicks, 0)
        XCTAssertFalse(feed(&health, [2.2, 2.4, 2.6], target: mild).contains(true))
    }

    func testAChangedTargetResetsTheRisingCount() {
        var health = Health()
        _ = feed(&health, [2.0, 2.2, 2.4, 2.6, 2.8], target: mild)
        XCTAssertEqual(feed(&health, [3.5], target: mild, changed: true), [false])
        XCTAssertEqual(health.risingTicks, 0)
    }

    func testStuckHighDeviationTripsOnTheFifthTick() {
        var health = Health()
        let flags = feed(&health, [6, 6, 6, 6, 6], target: wide)
        XCTAssertEqual(flags, [false, false, false, false, true])
    }

    func testStuckCountResetsBelowTheLimit() {
        var health = Health()
        _ = feed(&health, [7, 7, 7, 7], target: wide)
        XCTAssertEqual(health.stuckTicks, 4)
        _ = feed(&health, [5.9], target: wide)
        XCTAssertEqual(health.stuckTicks, 0)
        XCTAssertFalse(feed(&health, [7, 7, 7, 7], target: wide).contains(true))
    }

    func testClampOnAGentleReferenceTripsImmediately() {
        var health = Health()
        let clamped = display(gain: 11.95)
        XCTAssertTrue(health.failing(deviationDb: 1, display: clamped, target: mild,
                                     pinned: [0, 1], targetChanged: true))
    }

    func testClampNegativeAlsoTrips() {
        var health = Health()
        XCTAssertTrue(health.failing(deviationDb: 1, display: display(gain: -12), target: mild,
                                     pinned: [0, 1], targetChanged: true))
    }

    func testClampOnAReferenceThatNeedsItDoesNotTrip() {
        var health = Health()
        XCTAssertFalse(health.failing(deviationDb: 1, display: display(gain: 12), target: wide,
                                      pinned: [0, 1], targetChanged: true))
    }

    func testClampOnAnUnpinnedBandDoesNotTrip() {
        var health = Health()
        XCTAssertFalse(health.failing(deviationDb: 1, display: display(gain: 12), target: mild,
                                      pinned: [1], targetChanged: true))
    }

    func testTrimOffsetCountsInTheReferenceSpan() {
        var health = Health()
        let shifted = ReferenceFollower.Target(
            bands: mild.bands, anchors: [], offsetDb: -4)
        XCTAssertTrue(health.failing(deviationDb: 1, display: display(gain: 12), target: shifted,
                                     pinned: [0], targetChanged: true))
        let boosted = ReferenceFollower.Target(bands: mild.bands, anchors: [], offsetDb: 4)
        XCTAssertFalse(health.failing(deviationDb: 1, display: display(gain: 12), target: boosted,
                                      pinned: [0], targetChanged: true))
    }

    func testMeasuredVariantComputesTheDeviationItself() {
        var health = Health()
        let flat = display(gain: 0)
        var tripped = false
        for _ in 0..<5 {
            tripped = health.failing(display: flat, target: wide, pinned: [0, 1],
                                     targetChanged: false)
        }
        XCTAssertTrue(tripped)
        XCTAssertGreaterThan(health.lastDeviationDb ?? 0, 6)
    }

    func testMeasuredVariantIsQuietWhenTheBandsMatch() {
        var health = Health()
        let matched = display(gain: 3)
        for _ in 0..<10 {
            XCTAssertFalse(health.failing(display: matched, target: mild, pinned: [0, 1],
                                          targetChanged: false))
        }
        XCTAssertLessThan(health.lastDeviationDb ?? 9, 0.01)
    }

    func testConstantsMatchTheDesign() {
        XCTAssertEqual(Health.risingLimit, 5)
        XCTAssertEqual(Health.stuckLimit, 5)
        XCTAssertEqual(Health.riseDb, 0.05)
        XCTAssertEqual(Health.riseFloorDb, 1.5)
        XCTAssertEqual(Health.stuckDb, 6)
        XCTAssertEqual(Health.clampDb, 11.95)
        XCTAssertEqual(Health.tameReferenceDb, 6)
    }
}
