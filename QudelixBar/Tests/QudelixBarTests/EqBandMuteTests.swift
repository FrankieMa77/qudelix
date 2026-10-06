import XCTest
@testable import QudelixBar

final class EqBandMuteTests: XCTestCase {
    private func band(_ filter: QxFilter = .peak, _ freq: Int = 1000,
                      _ gain: Double = 3.0, _ q: Double = 1.0) -> QxEqBandValue {
        QxEqBandValue(filter: filter, freq: freq, gain: gain, q: q)
    }

    @MainActor
    private func authorised() -> QudelixController {
        let c = QudelixController()
        c.connection = .connected(name: "Qudelix 5K")
        c.compatibility = .ok
        return c
    }

    func testBandParamPayloadBytes() {
        XCTAssertEqual(
            QxPacket.bandParamPayload(group: .user, band: 3, band(.peak, 1000, 3.0, 1.0)),
            [0, 1, 3, 5, 0x03, 0xE8, 0x00, 0x1E, 0x04, 0x00])
        XCTAssertEqual(
            QxPacket.bandParamPayload(group: .user, band: 0, band(.lowShelf, 105, -7.5, 0.707)),
            [0, 1, 0, 3, 0x00, 0x69, 0xFF, 0xB5, 0x02, 0xD4])
        XCTAssertEqual(
            QxPacket.bandParamPayload(group: .b20, band: 19, band(.highShelf, 16000, 12, 10)),
            [2, 1, 19, 4, 0x3E, 0x80, 0x00, 0x78, 0x28, 0x00])
    }

    func testMuteChangesOnlyTheFilterByte() {
        let live = band(.peak, 2500, -4.5, 2.5)
        var muted = live
        muted.filter = .bypass

        guard let on = QxPacket.bandParamPayload(group: .user, band: 6, live),
              let off = QxPacket.bandParamPayload(group: .user, band: 6, muted) else {
            return XCTFail("both payloads must build")
        }
        XCTAssertEqual(on.count, 10)
        XCTAssertEqual(off.count, 10)
        XCTAssertEqual(on[3], QxFilter.peak.rawValue)
        XCTAssertEqual(off[3], QxFilter.bypass.rawValue)
        XCTAssertEqual(Array(on[0..<3]), Array(off[0..<3]))
        XCTAssertEqual(Array(on[4...]), Array(off[4...]))
        XCTAssertEqual(Array(off[6...7]), [0xFF, 0xD3])
    }

    func testChannelMaskStaysTheGroupsOwn() {
        for group in [QxEqGroup.user, .speaker, .b20] {
            var v = band()
            v.filter = .bypass
            let payload = QxPacket.bandParamPayload(group: group, band: 0, v)
            XCTAssertEqual(payload?[1], group.writeChannelMask)
        }
        XCTAssertEqual(QxEqGroup.user.writeChannelMask, 1)
        XCTAssertEqual(QxEqGroup.b20.writeChannelMask, 1)
    }

    func testRejectsBandIndicesTheGroupDoesNotHave() {
        for i in [-1, 10, 20, 255, Int.max, Int.min] {
            XCTAssertNil(QxPacket.bandParamPayload(group: .user, band: i, band()),
                         "user group must refuse band \(i)")
        }
        for i in 10..<20 {
            XCTAssertNotNil(QxPacket.bandParamPayload(group: .b20, band: i, band()))
        }
        XCTAssertNil(QxPacket.bandParamPayload(group: .b20, band: 20, band()))
    }

    func testRejectsNonFiniteAndOutOfRangeValues() {
        XCTAssertNil(QxPacket.bandParamPayload(group: .user, band: 0, band(.peak, 1000, .nan, 1)))
        XCTAssertNil(QxPacket.bandParamPayload(group: .user, band: 0, band(.peak, 1000, .infinity, 1)))
        XCTAssertNil(QxPacket.bandParamPayload(group: .user, band: 0, band(.peak, 1000, 0, .nan)))
        XCTAssertNil(QxPacket.bandParamPayload(group: .user, band: 0, band(.peak, 1000, 0, -.infinity)))
        XCTAssertNil(QxPacket.bandParamPayload(group: .user, band: 0, band(.peak, 19, 0, 1)))
        XCTAssertNil(QxPacket.bandParamPayload(group: .user, band: 0, band(.peak, 20001, 0, 1)))
        XCTAssertNil(QxPacket.bandParamPayload(group: .user, band: 0, band(.peak, 1000, 12.1, 1)))
        XCTAssertNil(QxPacket.bandParamPayload(group: .user, band: 0, band(.peak, 1000, -12.1, 1)))
        XCTAssertNil(QxPacket.bandParamPayload(group: .user, band: 0, band(.peak, 1000, 0, 0.09)))
        XCTAssertNil(QxPacket.bandParamPayload(group: .user, band: 0, band(.peak, 1000, 0, 10.1)))
        XCTAssertNotNil(QxPacket.bandParamPayload(group: .user, band: 0, band(.peak, 20, -12, 0.1)))
        XCTAssertNotNil(QxPacket.bandParamPayload(group: .user, band: 0, band(.peak, 20000, 12, 10)))
    }

    @MainActor
    func testMuteDoesNothingWhileWritesAreUnauthorised() {
        let c = QudelixController()
        XCTAssertEqual(c.connection, .disconnected)
        let before = c.bands

        c.setBandMuted(2, true)

        XCTAssertEqual(c.bands, before)
        XCTAssertTrue(c.mutedBands.isEmpty)
        XCTAssertFalse(c.isBandMuted(2))
    }

    @MainActor
    func testMuteRejectsAnImpossibleBandIndexEvenWhenAuthorised() {
        let c = authorised()
        c.setBandMuted(-1, true)
        c.setBandMuted(c.bandCount, true)
        c.setBandMuted(Int.max, true)
        XCTAssertTrue(c.mutedBands.isEmpty)
    }

    @MainActor
    func testMuteKeepsTheGainAndUnmuteRestoresTheShape() {
        let c = authorised()
        c.updateBand(4, band(.lowShelf, 105, 7.5, 0.7))

        c.setBandMuted(4, true)
        XCTAssertTrue(c.isBandMuted(4))
        XCTAssertEqual(c.bands[4].filter, .bypass)
        XCTAssertEqual(c.bands[4].gain, 7.5, accuracy: 0.0001)
        XCTAssertEqual(c.bands[4].freq, 105)
        XCTAssertEqual(c.bands[4].q, 0.7, accuracy: 0.0001)

        c.setBandMuted(4, false)
        XCTAssertFalse(c.isBandMuted(4))
        XCTAssertTrue(c.mutedBands.isEmpty)
        XCTAssertEqual(c.bands[4].filter, .lowShelf)
        XCTAssertEqual(c.bands[4].gain, 7.5, accuracy: 0.0001)
        XCTAssertEqual(c.bands[4].freq, 105)
        XCTAssertEqual(c.bands[4].q, 0.7, accuracy: 0.0001)
    }

    @MainActor
    func testGainCanBeSetWhileMutedAndTheMuteSurvives() {
        let c = authorised()
        c.updateBand(1, band(.peak, 250, 2, 1.4))
        c.setBandMuted(1, true)

        var v = c.bands[1]
        v.gain = -6
        c.updateBand(1, v)

        XCTAssertTrue(c.isBandMuted(1))
        c.setBandMuted(1, false)
        XCTAssertEqual(c.bands[1].filter, .peak)
        XCTAssertEqual(c.bands[1].gain, -6, accuracy: 0.0001)
    }

    @MainActor
    func testGivingTheBandAFilterAgainEndsTheMute() {
        let c = authorised()
        c.updateBand(0, band(.peak, 60, 4, 1))
        c.setBandMuted(0, true)

        var v = c.bands[0]
        v.filter = .highShelf
        c.updateBand(0, v)

        XCTAssertFalse(c.isBandMuted(0))
        XCTAssertTrue(c.mutedBands.isEmpty)
    }

    @MainActor
    func testMutingAnAlreadyBypassedBandIsRefused() {
        let c = authorised()
        c.updateBand(7, band(.bypass, 8000, 0, 1))
        c.setBandMuted(7, true)
        XCTAssertTrue(c.mutedBands.isEmpty)
        XCTAssertFalse(c.isBandMuted(7))
    }

    @MainActor
    func testBandsAnImportLeavesBypassedAreNotReportedAsMuted() {
        let c = authorised()
        var file = ParametricEQFile()
        file.bands = [band(.peak, 100, 3, 1), band(.peak, 4000, -2, 2)]
        c.apply(file, named: "two bands")

        XCTAssertEqual(c.bands[9].filter, .bypass)
        XCTAssertFalse(c.isBandMuted(9))
        XCTAssertTrue(c.mutedBands.isEmpty)
    }

    @MainActor
    func testImportClearsTheMute() {
        let c = authorised()
        c.updateBand(4, band(.peak, 1000, 5, 1))
        c.setBandMuted(4, true)
        XCTAssertFalse(c.mutedBands.isEmpty)

        var file = ParametricEQFile()
        file.bands = [band(.peak, 100, 3, 1)]
        c.apply(file, named: "one band")

        XCTAssertTrue(c.mutedBands.isEmpty)
        XCTAssertFalse(c.isBandMuted(4))
    }

    @MainActor
    func testFlattenLeavesTheMuteAlone() {
        let c = authorised()
        c.updateBand(2, band(.peak, 500, -8, 3))
        c.setBandMuted(2, true)

        c.flatten()

        XCTAssertTrue(c.isBandMuted(2))
        XCTAssertEqual(c.mutedBands[2], .peak)
        XCTAssertEqual(c.bands[2].filter, .bypass)
        XCTAssertEqual(c.bands[2].freq, 500)
    }

    @MainActor
    func testResettingTheBandLayoutClearsTheMute() {
        let c = authorised()
        c.updateBand(2, band(.peak, 500, -8, 3))
        c.setBandMuted(2, true)

        c.resetBandLayout()

        XCTAssertTrue(c.mutedBands.isEmpty)
        XCTAssertEqual(c.bands[2].filter, .peak)
        XCTAssertEqual(c.bands[2].gain, 0)
    }

    @MainActor
    func testLoadingAPresetClearsTheMute() {
        let c = authorised()
        c.updateBand(3, band(.peak, 700, 6, 1))
        c.setBandMuted(3, true)

        c.loadPreset(5)

        XCTAssertTrue(c.mutedBands.isEmpty)
        XCTAssertFalse(c.isBandMuted(3))
    }

    @MainActor
    func testABandTheDeviceReportsAsLiveIsNoLongerMuted() {
        let c = authorised()
        c.updateBand(8, band(.peak, 12000, 3, 1))
        c.setBandMuted(8, true)
        XCTAssertTrue(c.isBandMuted(8))

        c.bands[8].filter = .peak

        XCTAssertFalse(c.isBandMuted(8))
    }

    @MainActor
    func testAMuteBeyondTheCurrentBandCountIsNotReported() {
        let c = authorised()
        c.updateBand(9, band(.peak, 16000, -3, 1))
        c.setBandMuted(9, true)
        XCTAssertTrue(c.isBandMuted(9))

        c.bands = Array(c.bands.prefix(5))

        XCTAssertFalse(c.isBandMuted(9))
    }

    func testAMutedBandContributesNothingToTheCurve() {
        let live = [band(.peak, 100, 6, 1), band(.peak, 1000, -6, 2), band(.peak, 8000, 4, 1.5)]
        var muted = live
        muted[1].filter = .bypass
        let without = [live[0], live[2]]

        let a = EQCurve.response(bands: muted, preGain: 0)
        let b = EQCurve.response(bands: without, preGain: 0)
        XCTAssertEqual(a.count, b.count)
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 1e-9) }

        let full = EQCurve.response(bands: live, preGain: 0)
        XCTAssertTrue(zip(a, full).contains { abs($0 - $1) > 0.5 })
    }

    func testMutingABoostRemovesItsHeadroomCost() {
        let live = [band(.peak, 1000, 10, 1)]
        var muted = live
        muted[0].filter = .bypass
        XCTAssertGreaterThan(EQHeadroom.advice(for: live, preGain: 0).peakBoost, 9)
        XCTAssertLessThan(EQHeadroom.advice(for: muted, preGain: 0).peakBoost, 0.05)
    }

    func testASnapshotWrittenWithoutAnyMuteKeyStillDecodes() {
        let json = """
        {"groupRaw":0,"preGain":-3.5,"enabled":true,"name":"HD 650",
         "bands":[{"filter":5,"freq":1000,"gain":2.5,"q":1.0},
                  {"filter":0,"freq":4000,"gain":-6.0,"q":2.0}]}
        """
        let snap = try? JSONDecoder().decode(EqSnapshot.self, from: Data(json.utf8))
        XCTAssertNotNil(snap, "the snapshot schema must not have gained a required key")
        XCTAssertEqual(snap?.bands.count, 2)
        XCTAssertEqual(snap?.preGain, -3.5)
        XCTAssertEqual(snap?.bands[1].filter, .bypass)
        XCTAssertEqual(snap?.bands[1].gain, -6.0)
    }

    func testTheSnapshotComparisonSeesAMute() {
        let live = [band(.peak, 1000, 4, 1)]
        var muted = live
        muted[0].filter = .bypass
        let snap = EqSnapshot(groupRaw: 0, bands: muted, preGain: 0, enabled: true, name: nil)
        XCTAssertTrue(snap.matches(bands: muted, preGain: 0))
        XCTAssertFalse(snap.matches(bands: live, preGain: 0))
    }
}
