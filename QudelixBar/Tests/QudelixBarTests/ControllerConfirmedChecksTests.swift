import XCTest
@testable import QudelixBar

@MainActor
final class ControllerConfirmedChecksTests: XCTestCase {
    override func tearDown() async throws {
        DeviceRig.cleanUp()
    }

    private func settled(slot: Int = 3, bluetooth: Bool = false) async -> DeviceRig {
        let rig = DeviceRig()
        if bluetooth {
            await rig.connectBluetooth(slot: slot)
        } else {
            await rig.connect(slot: slot)
        }
        try? await Task.sleep(for: .milliseconds(400))
        rig.controller.clearSendTrace()
        return rig
    }

    private func push(_ c: QudelixController, volume: Double, muted: Bool = false) {
        c.debugIngest(Wire.statusNotification(volume: volume, muted: muted))
    }

    func testAStaleVolumePushDoesNotSnapTheSliderBackMidDrag() async {
        let rig = await settled()
        let c = rig.controller
        push(c, volume: -30)
        XCTAssertEqual(c.volumeDb, -30, accuracy: 0.02)

        c.setVolume(-12)
        push(c, volume: -30)

        XCTAssertEqual(c.volumeDb, -12, accuracy: 0.02, "the push carries the pre-drag level")
    }

    func testAStaleMutePushDoesNotFlipTheSwitchBack() async {
        let rig = await settled()
        let c = rig.controller
        push(c, volume: -30, muted: false)

        c.setMute(true)
        push(c, volume: -30, muted: false)

        XCTAssertTrue(c.muted)
    }

    func testTheDeviceRulesAgainOnceTheEchoWindowHasPassed() async throws {
        let rig = await settled()
        let c = rig.controller
        push(c, volume: -30)
        c.setVolume(-12)
        push(c, volume: -30)
        XCTAssertEqual(c.volumeDb, -12, accuracy: 0.02)

        try await Task.sleep(for: .milliseconds(1700))
        push(c, volume: -25)
        XCTAssertEqual(c.volumeDb, -25, accuracy: 0.02)
    }

    func testAnEchoWindowOnTheVolumeDoesNotBlockUnrelatedPushes() async {
        let rig = await settled()
        let c = rig.controller
        c.setVolume(-12)
        c.debugIngest(Wire.statusNotification(percent: 55, volume: -30))
        XCTAssertEqual(c.batteryPercent, 55)
    }

    func testABandEditThenASlotLoadFlushesTheEditBeforeTheLoad() async {
        let rig = await settled()
        let c = rig.controller
        var band = c.bands[0]
        band.gain = 5
        c.updateBand(0, band)

        XCTAssertTrue(c.loadPreset(6))

        let trace = c.sendTrace
        guard let edit = trace.firstIndex(of: "coalesced:setEqBandParam"),
              let flush = trace.firstIndex(of: "flush"),
              let load = trace.firstIndex(where: { $0.contains("loadEqPreset") }) else {
            return XCTFail("expected an edit, a flush and a load: \(trace)")
        }
        XCTAssertLessThan(edit, flush)
        XCTAssertLessThan(flush, load, "the stale band write must not land on the loaded slot")
    }

    func testABandEditThenAModeSwitchFlushesTheEditFirst() async {
        let rig = await settled()
        let c = rig.controller
        var band = c.bands[0]
        band.gain = 5
        c.updateBand(0, band)

        c.setEqMode(twentyBand: true)

        let trace = c.sendTrace
        guard let flush = trace.firstIndex(of: "flush"),
              let mode = trace.firstIndex(where: { $0.contains("setEqMode") }) else {
            return XCTFail("expected a flush and the switch: \(trace)")
        }
        XCTAssertLessThan(flush, mode)
    }

    func testAThrottledModeSwitchFlushesNothing() async {
        let rig = await settled()
        let c = rig.controller
        c.setEqMode(twentyBand: true)
        c.clearSendTrace()
        c.setEqMode(twentyBand: false)
        XCTAssertTrue(c.sendTrace.isEmpty, "\(c.sendTrace)")
    }

    func testTheHighGainFlagAndCodecBelongToTheLinkThatReportedThem() async {
        let rig = await settled(bluetooth: true)
        let c = rig.controller
        c.debugIngest(Wire.statusNotification(audio: Wire.audioBlock(highGain: true, codec: 6)))
        XCTAssertEqual(c.outputHighGain, true)
        XCTAssertEqual(c.codecLabel, "LDAC")

        await rig.detachBluetooth()
        XCTAssertNil(c.outputHighGain)
        XCTAssertNil(c.codecLabel)
    }

    func testASlotChangePushedByTheDeviceRefreshesTheBands() async {
        let rig = await settled(slot: 3)
        let c = rig.controller
        XCTAssertEqual(c.activePreset, 3)

        c.debugIngest(Wire.presetChanged(group: 0, slot: 5))

        XCTAssertEqual(c.activePreset, 5)
        XCTAssertEqual(c.sendTrace.filter { $0.contains("reqEqPreset") }.count, 1)
    }

    func testTheEchoOfAnOwnSlotLoadAsksForNothingExtra() async {
        let rig = await settled(slot: 3)
        let c = rig.controller
        XCTAssertTrue(c.loadPreset(5))
        let asked = c.sendTrace.filter { $0.contains("reqEqPreset") }.count
        XCTAssertEqual(asked, 1, "the load's own refresh")

        c.debugIngest(Wire.presetChanged(group: 0, slot: 5))
        XCTAssertEqual(c.sendTrace.filter { $0.contains("reqEqPreset") }.count, asked)
    }

    func testSlotChangesAreRefreshedAtMostOncePerSecond() async {
        let rig = await settled(slot: 3)
        let c = rig.controller
        for slot in [5, 6, 7, 8] { c.debugIngest(Wire.presetChanged(group: 0, slot: slot)) }
        XCTAssertEqual(c.activePreset, 8)
        XCTAssertEqual(c.sendTrace.filter { $0.contains("reqEqPreset") }.count, 1)
    }

    func testTheFirstSlotReportOfAConnectionAsksForNothing() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.attachUSB()
        c.clearSendTrace()
        rig.handshake(group: .user, bands: nil, preGain: 0, slot: 3, enabled: true)
        XCTAssertEqual(c.activePreset, 3)
        XCTAssertTrue(c.sendTrace.filter { $0.contains("reqEqPreset") }.isEmpty, "\(c.sendTrace)")
    }

    func testAReportForTheOtherGroupIsIgnored() async {
        let rig = await settled(slot: 3)
        let c = rig.controller
        c.debugIngest(Wire.presetChanged(group: 2, slot: 9))
        XCTAssertEqual(c.activePreset, 3)
        XCTAssertTrue(c.sendTrace.filter { $0.contains("reqEqPreset") }.isEmpty)
    }

    func testACustomCurveReportClearsTheHighlightWithoutARefresh() async {
        let rig = await settled(slot: 3)
        let c = rig.controller
        c.debugIngest(Wire.presetChanged(group: 0, slot: 255))
        XCTAssertNil(c.activePreset)
        XCTAssertTrue(c.sendTrace.filter { $0.contains("reqEqPreset") }.isEmpty)
    }
}
