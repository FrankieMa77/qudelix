import XCTest
@testable import QudelixBar

/// The power/charging fields: the bitfields the status parser used to step
/// over, the two charge settings in the sys config block, and the fact that
/// neither setting is ever written.
///
/// The byte patterns below are the shapes this device actually puts on the
/// wire. They are pinned here rather than described, because the whole risk
/// in a packed bitfield is an off-by-one in the walk: every field added to
/// the front of one shifts everything behind it, and the only cheap way to
/// notice is to check a field on each side of the new ones.
final class BatteryCareTests: XCTestCase {

    // MARK: - Power status block (mask 0x02, 8 bytes)

    private func power(_ bytes: [UInt8]) -> QxDeviceState {
        var state = QxDeviceState()
        let consumed = QxStatusParser.parseDevStatus([QxStatusMask.power] + bytes, into: &state)
        XCTAssertEqual(consumed, 9)
        return state
    }

    /// Charger attached, idle, DAC running, 79% at 4.114 V.
    ///
    /// Byte 0 = 0x65 = 0b0110_0101, read LSB-first: charger_connected 1,
    /// charging 0, charger_state 0b001, dac_state 0b011. Byte 1 = 0x9E:
    /// batt_low 0, then 79 in the seven bits above it.
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

    /// The same device a moment into a charge cycle: 0x73 = 0b0111_0011 —
    /// charging set, and charger_state moved from 1 to 4 with it. That the
    /// two move together is what identifies the 3-bit field as the charger's.
    func testChargingSetsBothTheFlagAndTheChargerState() {
        let s = power([0x73, 0x9E, 0x12, 0x10, 0x00, 0x00, 0x2E, 0x1C])
        XCTAssertTrue(s.chargerConnected)
        XCTAssertTrue(s.charging)
        XCTAssertEqual(s.chargerState, 4)
        XCTAssertEqual(s.batteryPercent, 79)
    }

    /// dac_state is the only field that differs between these two, and it
    /// tracks the audio-running flag: 0x25 arrives with audio stopped, 0x65
    /// with audio playing. Everything else in the byte is identical.
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

    /// batt_low is the low bit of byte 1, immediately under the percentage.
    /// Setting it must not move the percentage — the failure mode of reading
    /// it wrong is a battery that reads half what it is.
    func testBatteryLowSetsWithoutShiftingThePercentage() {
        let s = power([0x65, 0x25, 0x8C, 0x0E, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(s.batteryLow, true)
        XCTAssertEqual(s.batteryPercent, 18)
        XCTAssertEqual(s.batteryMilliVolts, 3724)
    }

    /// Nothing attached: every flag clear, and the 3-bit states read zero
    /// rather than staying nil.
    func testUnpluggedReadsAsZeroesNotAsAbsentFields() {
        let s = power([0x00, 0x64, 0xE8, 0x0F, 0x00, 0x00, 0x00, 0x00])
        XCTAssertFalse(s.chargerConnected)
        XCTAssertFalse(s.charging)
        XCTAssertEqual(s.chargerState, 0)
        XCTAssertEqual(s.dacState, 0)
        XCTAssertEqual(s.batteryLow, false)
        XCTAssertEqual(s.batteryPercent, 50)
    }

    /// The 7-bit field can carry 127; a percentage is capped at 100 rather
    /// than shown as it arrives.
    func testImplausiblePercentageIsCappedAtFull() {
        let s = power([0x00, 0xFE, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(s.batteryPercent, 100)
    }

    /// A truncated power block must consume the remainder rather than let a
    /// later block be parsed from a misaligned offset — and must not have
    /// left half-read fields behind.
    func testTruncatedPowerBlockLeavesTheFieldsUnset() {
        var state = QxDeviceState()
        let short: [UInt8] = [QxStatusMask.power, 0x65, 0x9E, 0x12]
        XCTAssertEqual(QxStatusParser.parseDevStatus(short, into: &state), short.count)
        XCTAssertNil(state.chargerState)
        XCTAssertNil(state.dacState)
        XCTAssertNil(state.batteryLow)
        XCTAssertNil(state.batteryPercent)
    }

    // MARK: - Sys config block (mask 0x01, 12 bytes)

    private func sys(_ first: UInt8) -> QxDeviceState {
        var state = QxDeviceState()
        let block: [UInt8] = [first, 0x24, 0xFF, 0x40, 0x9F, 0x3C,
                              0x8E, 0x98, 0x79, 0x19, 0x8E, 0x00]
        let consumed = QxStatusParser.parseDevConfig([QxConfigMask.sys] + block, into: &state)
        XCTAssertEqual(consumed, 13)
        return state
    }

    /// Byte 0 = 0xB0 = 0b1011_0000: charger_enable and batt_care are bits 4
    /// and 5, both set. The eq_mode and usb_fs_mode assertions are the point
    /// of the test as much as the two new ones — they sit 30 bits further
    /// along the same walk, so they are what proves the walk still lands
    /// where it did before these fields were read out of it.
    func testSysBlockCarriesBothChargeSettingsWithoutMovingEqMode() {
        let s = sys(0xB0)
        XCTAssertEqual(s.chargerEnabled, true)
        XCTAssertEqual(s.batteryCare, true)
        XCTAssertEqual(s.eqMode, 1)
        XCTAssertEqual(s.usbFsMode, 4)
    }

    /// Each bit on its own, so neither can be reading the other's position.
    func testTheTwoSettingsDecodeIndependently() {
        XCTAssertEqual(sys(0x80).chargerEnabled, false)
        XCTAssertEqual(sys(0x80).batteryCare, false)
        XCTAssertEqual(sys(0x90).chargerEnabled, true)   // bit 4 only
        XCTAssertEqual(sys(0x90).batteryCare, false)
        XCTAssertEqual(sys(0xA0).chargerEnabled, false)  // bit 5 only
        XCTAssertEqual(sys(0xA0).batteryCare, true)
    }

    /// The bits below them belong to other settings and must not leak in.
    func testAdjacentFlagsDoNotBleedIntoTheChargeSettings() {
        // 0b0000_1111: everything under bit 4 set, neither charge bit.
        XCTAssertEqual(sys(0x0F).chargerEnabled, false)
        XCTAssertEqual(sys(0x0F).batteryCare, false)
        // 0b1100_0000: everything above bit 5 set, neither charge bit.
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

    /// The sys2 block is still stepped over, and must stay 32 bytes wide:
    /// the eq block behind it is parsed from wherever this leaves the cursor.
    func testSys2IsSteppedOverAtItsFullWidth() {
        var state = QxDeviceState()
        let block = [UInt8](repeating: 0, count: 32)
        let consumed = QxStatusParser.parseDevConfig([QxConfigMask.sys2] + block, into: &state)
        XCTAssertEqual(consumed, 33)
        XCTAssertNil(state.chargerEnabled)
        XCTAssertNil(state.batteryCare)
    }

    // MARK: - What the controller publishes

    /// The summary is nil until a power block has actually been read, so a
    /// fresh controller cannot claim the device is on battery.
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
        c.chargerState = 1          // a power block has been read

        c.chargerConnected = false
        XCTAssertEqual(c.chargeSummary, "On battery")

        c.chargerConnected = true
        c.charging = true
        XCTAssertEqual(c.chargeSummary, "Plugged in, charging")

        c.charging = false
        XCTAssertEqual(c.chargeSummary, "Plugged in, not charging")

        // Charging switched off is the one reason for "not charging" the
        // device states outright, so it is the only one the line names.
        c.chargerEnabled = false
        XCTAssertEqual(c.chargeSummary, "Plugged in — charging is switched off")

        // Battery care is reported separately and must not be folded into
        // the line: "not charging" has causes this app cannot distinguish.
        c.chargerEnabled = true
        c.batteryCare = true
        XCTAssertEqual(c.chargeSummary, "Plugged in, not charging")
    }

    // MARK: - Neither setting is written

    /// SetCharger and SetBatteryCare are declared so the ids are recorded,
    /// and are never sent: the read side gives their domain but nothing
    /// gives the shape of the payload. This pins the ids, and the absence of
    /// any encoder for them is the rest of the guarantee — there is no
    /// `QxPacket` function that produces a payload for either, and no
    /// controller method that could reach the wire with one.
    func testTheTwoChargeCommandsAreDeclaredButHaveNoEncoder() {
        XCTAssertEqual(QxCmd.setCharger.rawValue, 0x0201)
        XCTAssertEqual(QxCmd.setBatteryCare.rawValue, 0x0213)
    }

    /// The charge settings are device truth only. Nothing in the app writes
    /// them, so a disconnected controller — the state in which every write
    /// is refused anyway — must still be able to display whatever the device
    /// last said without that display becoming a write path.
    @MainActor
    func testDisplayedChargeSettingsAreNotAWritePath() {
        let c = QudelixController()
        XCTAssertEqual(c.connection, .disconnected)
        XCTAssertFalse(c.canWriteNow)

        // Setting the published values directly is what a device report
        // does; it must remain purely local state.
        c.batteryCare = false
        c.chargerEnabled = false
        XCTAssertEqual(c.batteryCare, false)
        XCTAssertEqual(c.chargerEnabled, false)
        XCTAssertFalse(c.canWriteNow)
    }
}
