import XCTest
@testable import QudelixBar

final class StatusMaskTests: XCTestCase {
    private let junk = [UInt8](repeating: 0x7F, count: 40)

    func testAnUnknownBlockBeforeTheVolumeBlockStopsTheWalk() {
        var state = QxDeviceState()
        let data = [QxStatusMask.runtimeEq | QxStatusMask.vol] + junk
        let consumed = QxStatusParser.parseDevStatus(data, into: &state)

        XCTAssertEqual(consumed, data.count)
        XCTAssertNil(state.volumeDb, "the volume block cannot be located behind an unknown one")
        XCTAssertNil(state.usbMute)
    }

    func testBlocksBeforeTheUnknownBitAreStillRead() {
        var state = QxDeviceState()
        let data = [QxStatusMask.power | QxStatusMask.runtimeEq]
            + Wire.powerBlock(percent: 61) + junk
        let consumed = QxStatusParser.parseDevStatus(data, into: &state)

        XCTAssertEqual(consumed, data.count)
        XCTAssertEqual(state.batteryPercent, 61)
    }

    func testTheTopBitIsNotMistakenForAKnownBlock() {
        var state = QxDeviceState()
        let data = [QxStatusMask.power | QxStatusMask.reserved]
            + Wire.powerBlock(percent: 44) + junk
        let consumed = QxStatusParser.parseDevStatus(data, into: &state)

        XCTAssertEqual(consumed, data.count, "everything after an unknown block is unlocatable")
        XCTAssertEqual(state.batteryPercent, 44)
    }

    func testTheVolumeBlockIsStillReadWhenOnlyTheTopBitFollowsIt() {
        var state = QxDeviceState()
        let data = [QxStatusMask.vol | QxStatusMask.reserved]
            + Wire.volumeBlock(volume: -12) + [1] + junk
        let consumed = QxStatusParser.parseDevStatus(data, into: &state)

        XCTAssertEqual(consumed, data.count)
        XCTAssertEqual(state.volumeDb ?? 0, -12, accuracy: 0.02)
        XCTAssertEqual(state.usbMute, true)
    }

    func testTheMasksARealDeviceSendsParseExactlyAsBefore() {
        for mask in [UInt8(0x01), 0x02, 0x04, 0x40, 0x47] {
            var state = QxDeviceState()
            var data: [UInt8] = [mask]
            if mask & QxStatusMask.audio != 0 { data += Wire.audioBlock() }
            if mask & QxStatusMask.power != 0 { data += Wire.powerBlock(percent: 70) }
            if mask & QxStatusMask.conn != 0 { data += [UInt8](repeating: 0, count: 16) }
            if mask & QxStatusMask.vol != 0 { data += Wire.volumeBlock(volume: -9) + [0] }
            let consumed = QxStatusParser.parseDevStatus(data, into: &state)

            XCTAssertEqual(consumed, data.count, "mask \(mask)")
            if mask & QxStatusMask.power != 0 { XCTAssertEqual(state.batteryPercent, 70) }
            if mask & QxStatusMask.vol != 0 {
                XCTAssertEqual(state.volumeDb ?? 0, -9, accuracy: 0.02)
                XCTAssertEqual(state.usbMute, false)
            }
        }
    }

    @MainActor
    func testAnUnknownStatusBitCannotMakeTheNextConfigBlockFlipTheEqGroup() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connect()
        XCTAssertEqual(c.eqGroup, .user)

        c.debugIngest(Wire.notification(
            [0, QxNotifyMask.status | QxNotifyMask.config, QxStatusMask.power | QxStatusMask.reserved]
            + Wire.powerBlock(percent: 50)
            + [QxConfigMask.sys] + Wire.sysBlock(eqMode: 1)))

        XCTAssertEqual(c.batteryPercent, 50)
        XCTAssertEqual(c.eqGroup, .user, "bytes behind an unknown block are not a config block")
        DeviceRig.cleanUp()
    }
}
