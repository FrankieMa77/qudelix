import XCTest
@testable import QudelixBar

final class BatteryCareTests: XCTestCase {
    private func power(_ bytes: [UInt8]) -> QxDeviceState {
        var state = QxDeviceState()
        let consumed = QxStatusParser.parseDevStatus([QxStatusMask.power] + bytes, into: &state)
        XCTAssertEqual(consumed, 9)
        return state
    }

    func testIdleOnChargerDecodesEveryFieldOfTheByte() {
        let s = power([0x65, 0x9E, 0x12, 0x10, 0x00, 0x00, 0x2E, 0x1C])
        XCTAssertTrue(s.chargerConnected)
        XCTAssertFalse(s.charging)
        XCTAssertEqual(s.chargerState, 1)
        XCTAssertEqual(s.dacState, 3)
        XCTAssertEqual(s.batteryLow, false)
        XCTAssertEqual(s.batteryPercent, 79)
        XCTAssertEqual(s.batteryMilliVolts, 4114)
    }

    func testChargingSetsBothTheFlagAndTheChargerState() {
        let s = power([0x73, 0x9E, 0x12, 0x10, 0x00, 0x00, 0x2E, 0x1C])
        XCTAssertTrue(s.chargerConnected)
        XCTAssertTrue(s.charging)
        XCTAssertEqual(s.chargerState, 4)
        XCTAssertEqual(s.batteryPercent, 79)
    }

    func testDacStateIsTheOnlyFieldThatMovesWithTheAudioPath() {
        let stopped = power([0x25, 0x9C, 0x0F, 0x10, 0x00, 0x00, 0xE6, 0x1B])
        let running = power([0x65, 0x9C, 0x0F, 0x10, 0x00, 0x00, 0xE6, 0x1B])
        XCTAssertEqual(stopped.dacState, 1)
        XCTAssertEqual(running.dacState, 3)
        XCTAssertEqual(stopped.chargerState, running.chargerState)
        XCTAssertEqual(stopped.charging, running.charging)
        XCTAssertEqual(stopped.batteryPercent, running.batteryPercent)
        XCTAssertEqual(stopped.batteryPercent, 78)
    }

    func testBatteryLowSetsWithoutShiftingThePercentage() {
        let s = power([0x65, 0x25, 0x8C, 0x0E, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(s.batteryLow, true)
        XCTAssertEqual(s.batteryPercent, 18)
        XCTAssertEqual(s.batteryMilliVolts, 3724)
    }

    func testUnpluggedReadsAsZeroesNotAsAbsentFields() {
        let s = power([0x00, 0x64, 0xE8, 0x0F, 0x00, 0x00, 0x00, 0x00])
        XCTAssertFalse(s.chargerConnected)
        XCTAssertFalse(s.charging)
        XCTAssertEqual(s.chargerState, 0)
        XCTAssertEqual(s.dacState, 0)
        XCTAssertEqual(s.batteryLow, false)
        XCTAssertEqual(s.batteryPercent, 50)
    }

    func testImplausiblePercentageIsCappedAtFull() {
        let s = power([0x00, 0xFE, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(s.batteryPercent, 100)
    }

    func testTruncatedPowerBlockLeavesTheFieldsUnset() {
        var state = QxDeviceState()
        let short: [UInt8] = [QxStatusMask.power, 0x65, 0x9E, 0x12]
        XCTAssertEqual(QxStatusParser.parseDevStatus(short, into: &state), short.count)
        XCTAssertNil(state.chargerState)
        XCTAssertNil(state.dacState)
        XCTAssertNil(state.batteryLow)
        XCTAssertNil(state.batteryPercent)
    }

    private func sys(_ first: UInt8) -> QxDeviceState {
        var state = QxDeviceState()
        let block: [UInt8] = [first, 0x24, 0xFF, 0x40, 0x9F, 0x3C,
                              0x8E, 0x98, 0x79, 0x19, 0x8E, 0x00]
        let consumed = QxStatusParser.parseDevConfig([QxConfigMask.sys] + block, into: &state)
        XCTAssertEqual(consumed, 13)
        return state
    }

    func testSysBlockCarriesBothChargeSettingsWithoutMovingEqMode() {
        let s = sys(0xB0)
        XCTAssertEqual(s.chargerEnabled, true)
        XCTAssertEqual(s.batteryCare, true)
        XCTAssertEqual(s.eqMode, 1)
        XCTAssertEqual(s.usbFsMode, 4)
    }

    func testTheTwoSettingsDecodeIndependently() {
        XCTAssertEqual(sys(0x80).chargerEnabled, false)
        XCTAssertEqual(sys(0x80).batteryCare, false)
        XCTAssertEqual(sys(0x90).chargerEnabled, true)
        XCTAssertEqual(sys(0x90).batteryCare, false)
        XCTAssertEqual(sys(0xA0).chargerEnabled, false)
        XCTAssertEqual(sys(0xA0).batteryCare, true)
    }

    func testAdjacentFlagsDoNotBleedIntoTheChargeSettings() {
        XCTAssertEqual(sys(0x0F).chargerEnabled, false)
        XCTAssertEqual(sys(0x0F).batteryCare, false)
        XCTAssertEqual(sys(0xC0).chargerEnabled, false)
        XCTAssertEqual(sys(0xC0).batteryCare, false)
    }

    func testTruncatedSysBlockLeavesTheChargeSettingsUnset() {
        var state = QxDeviceState()
        let short: [UInt8] = [QxConfigMask.sys, 0xB0, 0x24]
        XCTAssertEqual(QxStatusParser.parseDevConfig(short, into: &state), short.count)
        XCTAssertNil(state.chargerEnabled)
        XCTAssertNil(state.batteryCare)
        XCTAssertNil(state.eqMode)
    }

    func testSys2IsSteppedOverAtItsFullWidth() {
        var state = QxDeviceState()
        let block = [UInt8](repeating: 0, count: 32)
        let consumed = QxStatusParser.parseDevConfig([QxConfigMask.sys2] + block, into: &state)
        XCTAssertEqual(consumed, 33)
        XCTAssertNil(state.chargerEnabled)
        XCTAssertNil(state.batteryCare)
    }

    @MainActor
    func testChargeSummaryStaysSilentBeforeAnyReport() {
        let c = QudelixController()
        XCTAssertNil(c.chargeSummary)
        XCTAssertNil(c.chargerEnabled)
        XCTAssertNil(c.batteryCare)
        XCTAssertFalse(c.batteryLow)
        XCTAssertFalse(c.chargerConnected)
    }

    @MainActor
    func testChargeSummaryDistinguishesTheStatesItCanTellApart() {
        let c = QudelixController()
        c.chargerState = 1

        c.chargerConnected = false
        XCTAssertEqual(c.chargeSummary, "On battery")

        c.chargerConnected = true
        c.charging = true
        XCTAssertEqual(c.chargeSummary, "Plugged in, charging")

        c.charging = false
        XCTAssertEqual(c.chargeSummary, "Plugged in, not charging")

        c.chargerEnabled = false
        XCTAssertEqual(c.chargeSummary, "Plugged in — charging is switched off")

        c.chargerEnabled = true
        c.batteryCare = true
        XCTAssertEqual(c.chargeSummary, "Plugged in, not charging")
    }

    func testTheTwoChargeCommandsAreDeclaredButHaveNoEncoder() {
        XCTAssertEqual(QxCmd.setCharger.rawValue, 0x0201)
        XCTAssertEqual(QxCmd.setBatteryCare.rawValue, 0x0213)
    }

    @MainActor
    func testDisplayedChargeSettingsAreNotAWritePath() {
        let c = QudelixController()
        XCTAssertEqual(c.connection, .disconnected)
        XCTAssertFalse(c.canWriteNow)

        c.batteryCare = false
        c.chargerEnabled = false
        XCTAssertEqual(c.batteryCare, false)
        XCTAssertEqual(c.chargerEnabled, false)
        XCTAssertFalse(c.canWriteNow)
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @MainActor
    func testAGenuineChargeEventIsAnnouncedExactlyOnce() {
        let alerts = BatteryAlerts()
        XCTAssertNil(alerts.step(batteryPercent: 55, charging: false, now: t0))
        XCTAssertEqual(alerts.step(batteryPercent: 55, charging: true, now: t0 + 1),
                       .charging(percent: 55))
        XCTAssertNil(alerts.step(batteryPercent: 60, charging: true, now: t0 + 600))
    }

    @MainActor
    func testConnectingToAnAlreadyChargingDeviceSaysNothing() {
        let alerts = BatteryAlerts()
        XCTAssertNil(alerts.step(batteryPercent: 55, charging: true, now: t0),
                     "the charge did not start just because the app noticed it")
    }

    @MainActor
    func testAFlappingChargingBitCannotProduceAStreamOfBanners() {
        let alerts = BatteryAlerts()
        var alertsSeen: [BatteryAlerts.Alert] = []
        for second in 0..<200 {
            if let alert = alerts.step(batteryPercent: 18, charging: second.isMultiple(of: 2),
                                       now: t0 + Double(second)) {
                alertsSeen.append(alert)
            }
        }

        XCTAssertLessThanOrEqual(alertsSeen.count, 2,
                                 "at most one of each kind inside one interval")
        XCTAssertEqual(Set(alertsSeen.map(\.title)).count, alertsSeen.count,
                       "and never the same kind twice")
    }

    @MainActor
    func testOneNotChargingReadingDoesNotReArmTheChargingAlert() {
        let alerts = BatteryAlerts()
        _ = alerts.step(batteryPercent: 40, charging: false, now: t0)
        XCTAssertEqual(alerts.step(batteryPercent: 40, charging: true, now: t0 + 1),
                       .charging(percent: 40))

        XCTAssertNil(alerts.step(batteryPercent: 41, charging: false, now: t0 + 3600))
        XCTAssertNil(alerts.step(batteryPercent: 41, charging: true, now: t0 + 3601))
    }

    @MainActor
    func testAConfirmedUnplugAndReplugIsAnnouncedAgain() {
        let alerts = BatteryAlerts()
        _ = alerts.step(batteryPercent: 40, charging: false, now: t0)
        XCTAssertEqual(alerts.step(batteryPercent: 40, charging: true, now: t0 + 1),
                       .charging(percent: 40))

        for i in 0..<BatteryAlerts.dischargeConfirmations {
            _ = alerts.step(batteryPercent: 39, charging: false, now: t0 + 10 + Double(i))
        }
        let later = t0 + BatteryAlerts.minimumInterval + 60
        XCTAssertEqual(alerts.step(batteryPercent: 38, charging: true, now: later),
                       .charging(percent: 38))
    }

    @MainActor
    func testTheLowAndVeryLowThresholdsStillFireOncePerEpisode() {
        let alerts = BatteryAlerts()
        XCTAssertNil(alerts.step(batteryPercent: 40, charging: false, now: t0))
        XCTAssertEqual(alerts.step(batteryPercent: 20, charging: false, now: t0 + 60),
                       .low(percent: 20))
        XCTAssertNil(alerts.step(batteryPercent: 19, charging: false, now: t0 + 120))
        XCTAssertEqual(alerts.step(batteryPercent: 10, charging: false, now: t0 + 180),
                       .veryLow(percent: 10))
        XCTAssertNil(alerts.step(batteryPercent: 9, charging: false, now: t0 + 240))
    }

    @MainActor
    func testARateLimitedAlertIsOfferedAgainRatherThanDropped() {
        let alerts = BatteryAlerts()
        _ = alerts.step(batteryPercent: 12, charging: false, now: t0)
        XCTAssertEqual(alerts.step(batteryPercent: 8, charging: false, now: t0 + 1),
                       .veryLow(percent: 8),
                       "low and very low keep separate clocks")

        let alerts2 = BatteryAlerts()
        XCTAssertEqual(alerts2.step(batteryPercent: 8, charging: false, now: t0),
                       .veryLow(percent: 8))
        _ = alerts2.step(batteryPercent: 8, charging: true, now: t0 + 10)
        for i in 0..<BatteryAlerts.dischargeConfirmations {
            XCTAssertNil(alerts2.step(batteryPercent: 8, charging: false,
                                      now: t0 + 20 + Double(i)))
        }
        XCTAssertEqual(alerts2.step(batteryPercent: 8, charging: false,
                                    now: t0 + BatteryAlerts.minimumInterval + 30),
                       .veryLow(percent: 8))
    }
}
