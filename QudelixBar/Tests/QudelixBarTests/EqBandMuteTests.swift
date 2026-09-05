import XCTest
@testable import QudelixBar

/// Per-band mute: encoding, domain, write gating, and what happens to a mute
/// when the curve underneath it is replaced.
///
/// Muting is not a separate command here. The band's filter type is set to
/// bypass — the one type that contributes nothing to the response — and the
/// gain, frequency and Q go out unchanged in the very same packet. That is
/// the whole design, and it is what these tests pin: the wire difference
/// between a live band and a muted one is a single byte, so the value the
/// user is listening against stays on the device rather than being parked in
/// this app where anything else could write over it.
///
/// The controller tests below authorise writes but leave the link down, so
/// nothing reaches hardware. The debounced snapshot those edits queue holds
/// the controller weakly and each test's controller is gone before it could
/// run, so none of this can touch the saved EQ on disk either.
final class EqBandMuteTests: XCTestCase {

    private func band(_ filter: QxFilter = .peak, _ freq: Int = 1000,
                      _ gain: Double = 3.0, _ q: Double = 1.0) -> QxEqBandValue {
        QxEqBandValue(filter: filter, freq: freq, gain: gain, q: q)
    }

    /// A controller the handshake has accepted. The link stays down, so every
    /// send is dropped at the transport — local state is the only observable.
    @MainActor
    private func authorised() -> QudelixController {
        let c = QudelixController()
        c.connection = .connected(name: "Qudelix 5K")
        c.compatibility = .ok
        return c
    }

    // MARK: - Encoding

    /// `[group, channelMask, band, filter, freq BE, gain BE ×10, Q BE ×1024]`.
    func testBandParamPayloadBytes() {
        // Band 3 of the user group: peak, 1000 Hz, +3.0 dB, Q 1.0.
        XCTAssertEqual(
            QxPacket.bandParamPayload(group: .user, band: 3, band(.peak, 1000, 3.0, 1.0)),
            [0, 1, 3, 5, 0x03, 0xE8, 0x00, 0x1E, 0x04, 0x00])
        // A cut, and a Q off the integer grid: -7.5 dB → -75 → 0xFFB5,
        // Q 0.707 → 724 → 0x02D4.
        XCTAssertEqual(
            QxPacket.bandParamPayload(group: .user, band: 0, band(.lowShelf, 105, -7.5, 0.707)),
            [0, 1, 0, 3, 0x00, 0x69, 0xFF, 0xB5, 0x02, 0xD4])
        // The 20-band group differs only in the group byte and the band range.
        XCTAssertEqual(
            QxPacket.bandParamPayload(group: .b20, band: 19, band(.highShelf, 16000, 12, 10)),
            [2, 1, 19, 4, 0x3E, 0x80, 0x00, 0x78, 0x28, 0x00])
    }

    /// The load-bearing claim of the whole feature: muting a band changes the
    /// filter byte and nothing else. The gain, frequency and Q bytes are
    /// identical in both directions, so the value survives the mute on the
    /// device — there is nothing for this app to lose.
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
        // Everything either side of byte 3 — group, mask, band, and all six
        // value bytes — matches exactly.
        XCTAssertEqual(Array(on[0..<3]), Array(off[0..<3]))
        XCTAssertEqual(Array(on[4...]), Array(off[4...]))
        // And spelled out: -4.5 dB is still -45 on the wire while muted.
        XCTAssertEqual(Array(off[6...7]), [0xFF, 0xD3])
    }

    /// The channel mask is the group's own. The both-channels mask on a
    /// single-channel group is what makes the firmware write past the struct
    /// it was given, so a mute must never be the thing that introduces one.
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

    // MARK: - Domain

    /// A band index the group doesn't have produces no packet at all. Not the
    /// nearest band — a mute aimed at band 12 of a 10-band group must not
    /// silence band 9 instead.
    func testRejectsBandIndicesTheGroupDoesNotHave() {
        for i in [-1, 10, 20, 255, Int.max, Int.min] {
            XCTAssertNil(QxPacket.bandParamPayload(group: .user, band: i, band()),
                         "user group must refuse band \(i)")
        }
        // The same indices 10…19 are legitimate in the 20-band group, which is
        // why the bound is the group's own count and not a constant.
        for i in 10..<20 {
            XCTAssertNotNil(QxPacket.bandParamPayload(group: .b20, band: i, band()))
        }
        XCTAssertNil(QxPacket.bandParamPayload(group: .b20, band: 20, band()))
    }

    /// Values with no meaningful boundary, and values outside the editor's
    /// own limits, are refused rather than folded to the nearest legal one.
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
        // The boundaries themselves are legal — the editor can reach them.
        XCTAssertNotNil(QxPacket.bandParamPayload(group: .user, band: 0, band(.peak, 20, -12, 0.1)))
        XCTAssertNotNil(QxPacket.bandParamPayload(group: .user, band: 0, band(.peak, 20000, 12, 10)))
    }

    // MARK: - Write gating

    /// Disconnected: a complete no-op, including the local state. Nothing may
    /// be written before the handshake has identified the device, and a mute
    /// recorded against a band that was never silenced would put a slash
    /// through a row that is still playing.
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

    /// Same gate, with a band index that doesn't exist — the two reasons to
    /// refuse must not mask each other into a false pass.
    @MainActor
    func testMuteRejectsAnImpossibleBandIndexEvenWhenAuthorised() {
        let c = authorised()
        c.setBandMuted(-1, true)
        c.setBandMuted(c.bandCount, true)
        c.setBandMuted(Int.max, true)
        XCTAssertTrue(c.mutedBands.isEmpty)
    }

    // MARK: - Round trip

    /// Mute, then unmute: the gain is untouched throughout and the filter
    /// shape comes back exactly as it was — not as a default peak.
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

    /// The gain stays editable while the band is silent, and editing it does
    /// not end the mute — otherwise a nudge of the slider would strand the
    /// user with a bypassed band and no way back to its shape.
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

    /// Choosing a real filter from the type picker ends the mute: there is
    /// nothing left to restore, and a shape kept past that point would later
    /// offer to bring back something the user had since replaced by hand.
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

    /// A band contributing nothing already has no shape to keep. Recording
    /// bypass as the way back would make unmute a button that does nothing.
    @MainActor
    func testMutingAnAlreadyBypassedBandIsRefused() {
        let c = authorised()
        c.updateBand(7, band(.bypass, 8000, 0, 1))
        c.setBandMuted(7, true)
        XCTAssertTrue(c.mutedBands.isEmpty)
        XCTAssertFalse(c.isBandMuted(7))
    }

    /// Bypassed is not muted. An import leaves the bands it didn't fill
    /// bypassed, and those are empty slots: showing them with a slash would
    /// promise an unmute that restores nothing.
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

    // MARK: - What a mute must not outlive

    /// An import replaces every band, so a shape held against band 4 no
    /// longer describes band 4.
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

    /// A preset slot brings its own curve, including whichever of its bands
    /// it stores bypassed. Those are the preset's, not mutes of ours.
    @MainActor
    func testLoadingAPresetClearsTheMute() {
        let c = authorised()
        c.updateBand(3, band(.peak, 700, 6, 1))
        c.setBandMuted(3, true)

        c.loadPreset(5)

        XCTAssertTrue(c.mutedBands.isEmpty)
        XCTAssertFalse(c.isBandMuted(3))
    }

    /// The device's report is the truth. If a band comes back carrying a real
    /// filter — a preset load, another app, a device that reset itself — the
    /// mute is over whatever this app last asked for, and the row must stop
    /// claiming the band is silent.
    @MainActor
    func testABandTheDeviceReportsAsLiveIsNoLongerMuted() {
        let c = authorised()
        c.updateBand(8, band(.peak, 12000, 3, 1))
        c.setBandMuted(8, true)
        XCTAssertTrue(c.isBandMuted(8))

        // What a read-back does to the band table.
        c.bands[8].filter = .peak

        XCTAssertFalse(c.isBandMuted(8))
    }

    /// And an entry outliving the band table itself — a 20-band mute read
    /// against ten bands — must not be reported either.
    @MainActor
    func testAMuteBeyondTheCurrentBandCountIsNotReported() {
        let c = authorised()
        c.updateBand(9, band(.peak, 16000, -3, 1))
        c.setBandMuted(9, true)
        XCTAssertTrue(c.isBandMuted(9))

        c.bands = Array(c.bands.prefix(5))

        XCTAssertFalse(c.isBandMuted(9))
    }

    // MARK: - The drawn curve

    /// A muted band contributes nothing to the response, because bypass is
    /// what the curve maths already treats as no filter at all. Muting must
    /// therefore be exactly as good as deleting the band from the sum.
    func testAMutedBandContributesNothingToTheCurve() {
        let live = [band(.peak, 100, 6, 1), band(.peak, 1000, -6, 2), band(.peak, 8000, 4, 1.5)]
        var muted = live
        muted[1].filter = .bypass
        let without = [live[0], live[2]]

        let a = EQCurve.response(bands: muted, preGain: 0)
        let b = EQCurve.response(bands: without, preGain: 0)
        XCTAssertEqual(a.count, b.count)
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 1e-9) }

        // And it must differ from the unmuted curve somewhere, or the test
        // would pass on a band that was doing nothing to begin with.
        let full = EQCurve.response(bands: live, preGain: 0)
        XCTAssertTrue(zip(a, full).contains { abs($0 - $1) > 0.5 })
    }

    /// The headroom advice reads the same curve, so muting a boost gives the
    /// headroom back rather than leaving the user attenuating for a band that
    /// is silent.
    func testMutingABoostRemovesItsHeadroomCost() {
        let live = [band(.peak, 1000, 10, 1)]
        var muted = live
        muted[0].filter = .bypass
        XCTAssertGreaterThan(EQHeadroom.advice(for: live, preGain: 0).peakBoost, 9)
        XCTAssertLessThan(EQHeadroom.advice(for: muted, preGain: 0).peakBoost, 0.05)
    }

    // MARK: - Persistence

    /// Mute adds no field to the saved EQ. A snapshot written by an earlier
    /// build must still decode, because a synthesised `Decodable` throws on a
    /// missing key rather than falling back to a default — and the load path
    /// swallows that throw, so the symptom would be the user's EQ silently
    /// refusing to restore.
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
        // The muted band round-trips as what it is on the device: bypassed,
        // with its gain intact.
        XCTAssertEqual(snap?.bands[1].filter, .bypass)
        XCTAssertEqual(snap?.bands[1].gain, -6.0)
    }

    /// A mute is a filter change, and the snapshot comparison already treats
    /// a filter change as a difference — so a device that came back with the
    /// band audible again is correctly seen as diverged.
    func testTheSnapshotComparisonSeesAMute() {
        let live = [band(.peak, 1000, 4, 1)]
        var muted = live
        muted[0].filter = .bypass
        let snap = EqSnapshot(groupRaw: 0, bands: muted, preGain: 0, enabled: true, name: nil)
        XCTAssertTrue(snap.matches(bands: muted, preGain: 0))
        XCTAssertFalse(snap.matches(bands: live, preGain: 0))
    }
}
