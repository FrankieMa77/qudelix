import XCTest
@testable import QudelixBar

final class DeviceControlTests: XCTestCase {
    func testTrimPayloadBytes() {
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimL, db: 0), [8, 0x00, 0x00])
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimR, db: 0), [16, 0x00, 0x00])
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimL, db: -3.5), [8, 0xFF, 0x2E])
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimR, db: -0.1), [16, 0xFF, 0xFA])
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimL, db: -24), [8, 0xFA, 0x60])
    }

    func testVolumeLimitPayloadBytes() {
        XCTAssertEqual(QxPacket.volumePayload(.sysLimit, db: 6), [32, 0x01, 0x68])
        XCTAssertEqual(QxPacket.volumePayload(.sysLimit, db: 0), [32, 0x00, 0x00])
        XCTAssertEqual(QxPacket.volumePayload(.sysLimit, db: -60), [32, 0xF1, 0xF0])
        XCTAssertEqual(QxPacket.volumePayload(.sysLimit, db: -12), [32, 0xFD, 0x30])
    }

    @MainActor
    func testASlotSaveFlushesTheCoalescedBandWritesBeforeItGoesOut() {
        let c = QudelixController()
        c.connection = .connected(name: "Qudelix 5K")
        c.compatibility = .ok
        c.clearSendTrace()

        var band = c.bands[0]
        band.gain = 5
        c.updateBand(0, band)
        c.savePreset(3)

        let trace = c.sendTrace
        guard let edit = trace.firstIndex(where: { $0.hasPrefix("coalesced:") }),
              let flush = trace.firstIndex(of: "flush"),
              let save = trace.firstIndex(where: { $0.contains("saveEqPreset") }) else {
            return XCTFail("expected an edit, a flush and a slot save: \(trace)")
        }
        XCTAssertLessThan(edit, flush)
        XCTAssertLessThan(flush, save,
                          "the curve has to reach the device before the slot is written")
    }

    func testOutOfRangeValuesClampToTheBoundaryBytes() {
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimL, db: 100), [8, 0x00, 0x00])
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimL, db: -1000), [8, 0xFA, 0x60])
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimR, db: 0.5), [16, 0x00, 0x00])
        XCTAssertEqual(QxPacket.volumePayload(.sysLimit, db: 1000), [32, 0x01, 0x68])
        XCTAssertEqual(QxPacket.volumePayload(.sysLimit, db: -1e9), [32, 0xF1, 0xF0])
        XCTAssertEqual(QxPacket.volumePayload(.sysLimit, db: 1e300), [32, 0x01, 0x68])
    }

    func testNonFiniteInputProducesNoPayloadRatherThanTrapping() {
        XCTAssertNil(QxPacket.volumePayload(.sysTrimL, db: .nan))
        XCTAssertNil(QxPacket.volumePayload(.sysTrimR, db: .infinity))
        XCTAssertNil(QxPacket.volumePayload(.sysLimit, db: -.infinity))
        XCTAssertNil(QxPacket.volumePayload(.sysLimit, db: .signalingNaN))
    }

    func testSubParametersWithoutAFixedRangeAreNotSilentlyClamped() {
        XCTAssertNil(QxVolumeParam.sink.dbRange)
        XCTAssertNil(QxVolumeParam.call.dbRange)
        XCTAssertNil(QxVolumeParam.source.dbRange)
        XCTAssertEqual(QxVolumeParam.sysTrimL.dbRange, QxVolumeRange.trim)
        XCTAssertEqual(QxVolumeParam.sysLimit.dbRange, QxVolumeRange.limit)
    }

    func testRoundingLandsOnTheDeviceGrid() {
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimL, db: -0.009), [8, 0xFF, 0xFF])
        XCTAssertEqual(QxPacket.volumePayload(.sysTrimL, db: -0.004), [8, 0x00, 0x00])
    }

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

    func testVolumeBlockCarriesLimitAndBothTrims() {
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

    func testPresetHeaderDecodesCrossfeedWithoutDisturbingPreGain() {
        var buf = [UInt8](repeating: 0, count: 88)
        buf[3] = UInt8(42 << 2)
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
