import XCTest
@testable import QudelixBar

/// Byte-level tests for the device-control writes: channel trim, volume limit,
/// and the read-only fields that arrive with them. Nothing here needs (or
/// touches) hardware — the point is that every value which *would* reach the
/// wire is in range and correctly encoded before it gets there, because an
/// out-of-range report is what knocks this device off the bus.
final class DeviceControlTests: XCTestCase {

    // MARK: - SetVolume payload shape

    /// `[sub-param, int16 BE dB×60]`.
    func testTrimPayloadBytes() {
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimL, db: 0), [8, 0x00, 0x00])
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimR, db: 0), [16, 0x00, 0x00])
        // -3.5 dB → -210 → 0xFF2E
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimL, db: -3.5), [8, 0xFF, 0x2E])
        // One step of the device's own 0.1 dB grid: -6 → 0xFFFA
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimR, db: -0.1), [16, 0xFF, 0xFA])
        // Bottom of the range: -24 dB → -1440 → 0xFA60
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimL, db: -24), [8, 0xFA, 0x60])
    }

    func testVolumeLimitPayloadBytes() {
        // Top of the range: +6 dB → 360 → 0x0168
        XCTAssertEqual(QxPacket.volumePayload(.sysLimit, db: 6), [32, 0x01, 0x68])
        XCTAssertEqual(QxPacket.volumePayload(.sysLimit, db: 0), [32, 0x00, 0x00])
        // Bottom: -60 dB → -3600 → 0xF1F0
        XCTAssertEqual(QxPacket.volumePayload(.sysLimit, db: -60), [32, 0xF1, 0xF0])
        // -12 dB → -720 → 0xFD30
        XCTAssertEqual(QxPacket.volumePayload(.sysLimit, db: -12), [32, 0xFD, 0x30])
    }

    // MARK: - Clamping

    func testOutOfRangeValuesClampToTheBoundaryBytes() {
        // Trim never attenuates past -24 dB and never boosts.
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimL, db: 100), [8, 0x00, 0x00])
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimL, db: -1000), [8, 0xFA, 0x60])
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimR, db: 0.5), [16, 0x00, 0x00])
        // Limit clamps to the same bytes as its boundaries.
        XCTAssertEqual(QxPacket.volumePayload(.sysLimit, db: 1000), [32, 0x01, 0x68])
        XCTAssertEqual(QxPacket.volumePayload(.sysLimit, db: -1e9), [32, 0xF1, 0xF0])
        // A value large enough to overflow int16 after ×60 scaling still lands
        // on the boundary rather than wrapping.
        XCTAssertEqual(QxPacket.volumePayload(.sysLimit, db: 1e300), [32, 0x01, 0x68])
    }

    func testNonFiniteInputProducesNoPayloadRatherThanTrapping() {
        XCTAssertNil(QxPacket.volumePayload(.sysTrimL, db: .nan))
        XCTAssertNil(QxPacket.volumePayload(.sysTrimR, db: .infinity))
        XCTAssertNil(QxPacket.volumePayload(.sysLimit, db: -.infinity))
        XCTAssertNil(QxPacket.volumePayload(.sysLimit, db: .signalingNaN))
    }

    func testSubParametersWithoutAFixedRangeAreNotSilentlyClamped() {
        // The master level's window is runtime state (limit + output mode), so
        // clamping it here would quietly cap a legitimate value.
        XCTAssertNil(QxVolumeParam.sink.dbRange)
        XCTAssertNil(QxVolumeParam.call.dbRange)
        XCTAssertNil(QxVolumeParam.source.dbRange)
        XCTAssertEqual(QxVolumeParam.sysTrimL.dbRange, QxVolumeRange.trim)
        XCTAssertEqual(QxVolumeParam.sysLimit.dbRange, QxVolumeRange.limit)
    }

    func testRoundingLandsOnTheDeviceGrid() {
        // dB×60 is fixed point: sub-step values round, they don't truncate.
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimL, db: -0.009), [8, 0xFF, 0xFF])  // -0.54 → -1
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimL, db: -0.004), [8, 0x00, 0x00])  // -0.24 → 0
    }

    // MARK: - Write gating

    /// Nothing may reach the device before the handshake has identified it.
    /// A fresh controller is disconnected, so every setter must be a no-op —
    /// including the optimistic local update, which is the observable half of
    /// a send that must not have happened.
    @MainActor
    func testSettersDoNothingWhileWritesAreUnauthorised() {
        let c = QudelixController()
        XCTAssertEqual(c.connection, .disconnected)

        c.setTrimLeft(-6)
        c.setTrimRight(-6)
        c.setVolumeLimit(-30)

        XCTAssertEqual(c.trimLeftDb, 0)
        XCTAssertEqual(c.trimRightDb, 0)
        XCTAssertEqual(c.volumeLimitDb, 0)
        XCTAssertEqual(c.volumeMax, 0)
    }

    @MainActor
    func testUnauthorisedSettersRejectNonFiniteWithoutTrapping() {
        let c = QudelixController()
        c.setTrimLeft(.nan)
        c.setTrimRight(.infinity)
        c.setVolumeLimit(.nan)
        XCTAssertEqual(c.trimLeftDb, 0)
        XCTAssertEqual(c.trimRightDb, 0)
        XCTAssertEqual(c.volumeLimitDb, 0)
    }

    @MainActor
    func testRangesExposedToTheUIMatchTheWireBounds() {
        let c = QudelixController()
        XCTAssertEqual(c.trimRange, QxVolumeRange.trim)
        XCTAssertEqual(c.volumeLimitRange, QxVolumeRange.limit)
    }

    // MARK: - Read-only fields

    func testVolumeBlockCarriesLimitAndBothTrims() {
        // cy volume block: 8 × int16 LE, dB×60. sink -24, limit -6,
        // call 0, trim L -1.5, trim R 0, rest 0.
        func le(_ db: Double) -> [UInt8] {
            let v = Int16(clamping: Int((db * 60).rounded()))
            let u = UInt16(bitPattern: v)
            return [UInt8(u & 0xFF), UInt8(u >> 8)]
        }
        let block = le(-24) + le(-6) + le(0) + le(-1.5) + le(0) + le(0) + le(0) + le(0)
        var state = QxDeviceState()
        let consumed = QxStatusParser.parseDevConfig([QxConfigMask.vol] + block, into: &state)
        XCTAssertEqual(consumed, 17)
        XCTAssertEqual(state.volumeDb ?? 0, -24, accuracy: 0.001)
        XCTAssertEqual(state.volumeLimitDb ?? 0, -6, accuracy: 0.001)
        XCTAssertEqual(state.trimLeftDb ?? 0, -1.5, accuracy: 0.001)
        XCTAssertEqual(state.trimRightDb ?? 0, 0, accuracy: 0.001)
    }

    /// The preset bitstream opens with a 32-bit header — type, impedance,
    /// sensitivity, then a 6-bit crossfeed level — before the pre-gain pair.
    /// Decoding the level must not shift anything after it.
    func testPresetHeaderDecodesCrossfeedWithoutDisturbingPreGain() {
        var buf = [UInt8](repeating: 0, count: 88)
        // Crossfeed occupies bits 26…31, i.e. the top six bits of byte 3.
        buf[3] = UInt8(42 << 2)
        // Pre-gain ch0 is the next int16 LE, dB×10: 0xFFDB = -37 → -3.7 dB.
        buf[4] = 0xDB
        buf[5] = 0xFF
        let decoded = QxUserEqPreset.decode(buf, group: .user)
        XCTAssertEqual(decoded.crossfeedLevel, 42)
        XCTAssertEqual(decoded.preGain, -3.7, accuracy: 0.001)
        XCTAssertEqual(decoded.bands.count, 10)
    }

    func testCrossfeedDefaultsToZeroOnAnEmptyPreset() {
        let decoded = QxUserEqPreset.decode([UInt8](repeating: 0, count: 88), group: .user)
        XCTAssertEqual(decoded.crossfeedLevel, 0)
    }
}
