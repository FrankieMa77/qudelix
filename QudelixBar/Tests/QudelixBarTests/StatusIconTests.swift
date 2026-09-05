import AppKit
import XCTest
@testable import QudelixBar

final class StatusIconStateTests: XCTestCase {
    private func state(connected: Bool = true,
                       eqEnabled: Bool = true,
                       stageOn: Bool = false,
                       verdict: QualityAnalyzer.Verdict? = nil,
                       batteryPercent: Int? = nil,
                       charging: Bool = false,
                       onCall: Bool = false) -> StatusIcon.State {
        StatusIcon.State.from(connected: connected, eqEnabled: eqEnabled,
                              stageOn: stageOn, verdict: verdict,
                              batteryPercent: batteryPercent, charging: charging,
                              onCall: onCall)
    }

    func testLosslessClassVerdictsBecomeTheSparkle() {
        XCTAssertEqual(state(verdict: .losslessLike(cutoffKHz: 21.4)).quality, .hi)
        XCTAssertEqual(state(verdict: .hiRes(cutoffKHz: 30)).quality, .hi)
    }

    func testLossyVerdictsBecomeTheRing() {
        XCTAssertEqual(state(verdict: .lossy(cutoffKHz: 16)).quality, .low)
        XCTAssertEqual(state(verdict: .lossyHigh(cutoffKHz: 19.0)).quality, .low)
    }

    func testUndecidedVerdictsShowNoBadge() {
        XCTAssertEqual(state(verdict: nil).quality, .unknown)
        XCTAssertEqual(state(verdict: .tooQuiet).quality, .unknown)
        XCTAssertEqual(state(verdict: .noTreble).quality, .unknown)
        XCTAssertEqual(state(verdict: .natural(cutoffKHz: 15)).quality, .unknown)
        XCTAssertEqual(state(verdict: .lossyHigh(cutoffKHz: 20.0)).quality, .unknown)
    }

    func testBatteryBadgeFollowsTheAlertThreshold() {
        XCTAssertTrue(state(batteryPercent: BatteryAlerts.lowThreshold).batteryLow)
        XCTAssertFalse(state(batteryPercent: BatteryAlerts.lowThreshold + 1).batteryLow)
        XCTAssertFalse(state(batteryPercent: nil).batteryLow)
    }

    func testLowAndChargingCoexist() {
        let s = state(batteryPercent: 4, charging: true)
        XCTAssertTrue(s.batteryLow)
        XCTAssertTrue(s.charging)
    }

    func testAwayDeviceReportsNoBatteryOfItsOwn() {
        let s = state(connected: false, batteryPercent: 4, charging: true)
        XCTAssertFalse(s.batteryLow)
        XCTAssertFalse(s.charging)
        XCTAssertFalse(s.connected)
    }

    func testCallSurvivesTheDeviceGoingAway() {
        let s = state(connected: false, onCall: true)
        XCTAssertTrue(s.onCall)
        XCTAssertTrue(StatusIcon.describe(s).contains("on a call"))
    }

    func testDescriptionNamesTheCallInsteadOfTheStream() {
        let calling = state(verdict: .losslessLike(cutoffKHz: 21.4), onCall: true)
        let listening = state(verdict: .losslessLike(cutoffKHz: 21.4))
        XCTAssertEqual(calling.quality, .hi)
        XCTAssertTrue(StatusIcon.describe(calling).contains("on a call"))
        XCTAssertFalse(StatusIcon.describe(calling).contains("lossless"))
        XCTAssertTrue(StatusIcon.describe(listening).contains("lossless"))
    }

    func testDescriptionCoversEveryLayer() {
        let s = state(eqEnabled: false, stageOn: true,
                      verdict: .lossy(cutoffKHz: 16), batteryPercent: 5, charging: true)
        let text = StatusIcon.describe(s)
        XCTAssertTrue(text.contains("EQ off"))
        XCTAssertTrue(text.contains("Soundstage on"))
        XCTAssertTrue(text.contains("lossy"))
        XCTAssertTrue(text.contains("battery low"))
        XCTAssertTrue(text.contains("charging"))
    }

    @MainActor
    func testRenderedImagesAreCachedPerStateAndTemplated() {
        let s = state(verdict: .hiRes(cutoffKHz: 30), batteryPercent: 6)
        let first = StatusIcon.image(for: s)
        XCTAssertTrue(first === StatusIcon.image(for: s))
        XCTAssertTrue(first.isTemplate)
        XCTAssertEqual(first.size, NSSize(width: 18, height: 18))
        XCTAssertFalse(first === StatusIcon.image(for: state()))
    }
}

final class StatusVisibilityGateTests: XCTestCase {
    @MainActor
    func testMeteredValuesOnlyPublishWhileThePopoverIsOpen() {
        let stage = StageState()
        stage.previewDisablePersistence()

        stage.previewPublishLevel(-30)
        XCTAssertEqual(stage.currentLevelDbLive, -30)
        XCTAssertNil(stage.currentLevelDb)

        stage.setUIVisible(true)
        XCTAssertEqual(stage.currentLevelDb, -30)

        stage.previewPublishLevel(-20)
        XCTAssertEqual(stage.currentLevelDb, -20)

        stage.setUIVisible(false)
        stage.previewPublishLevel(-10)
        XCTAssertEqual(stage.currentLevelDbLive, -10)
        XCTAssertEqual(stage.currentLevelDb, -20)

        stage.setUIVisible(true)
        XCTAssertEqual(stage.currentLevelDb, -10)
    }

    @MainActor
    func testOpeningFlushesEveryMirrorAtOnce() {
        let stage = StageState()
        stage.previewDisablePersistence()
        stage.previewPublishLevel(-42)
        stage.previewPublishVerdict(.lossy(cutoffKHz: 16))
        XCTAssertNil(stage.qualityVerdict)

        stage.setUIVisible(true)
        XCTAssertEqual(stage.currentLevelDb, -42)
        XCTAssertEqual(stage.qualityVerdict, .lossy(cutoffKHz: 16))
    }

    @MainActor
    func testTooltipDescribesAnAbsentDevice() {
        let controller = QudelixController()
        XCTAssertEqual(StatusIconModel.tooltip(controller),
                       "Qudelix — no device connected")
    }

    @MainActor
    func testTooltipCarriesChargeAndCharger() {
        let controller = QudelixController()
        controller.connection = .connected(name: "Qudelix-5K USB DAC 96KHz")
        controller.batteryPercent = 8
        controller.charging = false
        controller.chargerConnected = true
        let tip = StatusIconModel.tooltip(controller)
        XCTAssertTrue(tip.contains("Battery 8%"))
        XCTAssertTrue(tip.contains("very low"))
        XCTAssertTrue(tip.contains("plugged in, not charging"))
        XCTAssertTrue(tip.contains("Preset: custom"))
        XCTAssertFalse(tip.contains("USB DAC 96KHz"))
    }
}
