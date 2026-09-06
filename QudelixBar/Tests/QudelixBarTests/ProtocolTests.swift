import XCTest
@testable import QudelixBar

/// The protocol layer's invariants, previously enforced only by comments.
/// Every input here models something a real device (or a hostile one) can
/// send; several payloads are captured from real hardware.
final class ProtocolTests: XCTestCase {

    // MARK: - Packet framing

    func testParseRxHappyPath() {
        // [len, cmdHi, cmdLo, data...]
        let parsed = QxPacket.parseRx([4, 0x01, 0x11, 0xAA, 0xBB])
        XCTAssertEqual(parsed?.cmdId, 0x0111)
        XCTAssertEqual(parsed?.data, [0xAA, 0xBB])
    }

    func testParseRxTruncatedAndHostileLengths() {
        XCTAssertNil(QxPacket.parseRx([]))
        XCTAssertNil(QxPacket.parseRx([1, 0x01]))
        XCTAssertNil(QxPacket.parseRx([0, 0x01, 0x11]))          // len < 2
        // Length claims more than the buffer holds: clamped, no trap.
        let over = QxPacket.parseRx([200, 0x01, 0x11, 0x01])
        XCTAssertEqual(over?.data, [0x01])
    }

    func testTxReportFramingAndBounds() {
        let report = QxPacket.txReport(.reqInitData, [0, 0, 4], reportSize: 63)
        XCTAssertEqual(report.count, 63)
        XCTAssertEqual(report[0], 6)      // payload (2 cmd + 3 data) + 1
        XCTAssertEqual(report[1], 0x80)
        XCTAssertEqual(Array(report[2...6]), [0x01, 0x00, 0, 0, 4])
        // A report too small for the framing must refuse, not overflow.
        XCTAssertTrue(QxPacket.txReport(.reqInitData, [0, 0, 4], reportSize: 3).isEmpty)
    }

    func testBitReaderSignExtend() {
        XCTAssertEqual(QxBitReader.signExtend(0x3FF, bits: 10), -1)
        XCTAssertEqual(QxBitReader.signExtend(0x200, bits: 10), -512)
        XCTAssertEqual(QxBitReader.signExtend(0x1FF, bits: 10), 511)
        XCTAssertEqual(QxBitReader.signExtend(0xFFDB, bits: 16), -37)   // -3.7 dB pre-gain
    }

    // MARK: - Preset assembler

    private func segment(group: UInt8, total: Int, idx: Int, offset: Int,
                         chunk: [UInt8]) -> [UInt8] {
        [group, UInt8(total << 4 | idx), 0, UInt8(chunk.count),
         UInt8(offset >> 8), UInt8(offset & 0xFF)] + chunk
    }

    func testAssemblerCompletesByCoverageNotByClaim() {
        var a = QxPresetAssembler()
        a.group = .user
        // A single segment claiming to be the whole preset must NOT complete
        // an 88-byte buffer.
        XCTAssertFalse(a.ingest(segment(group: 0, total: 0, idx: 0, offset: 0,
                                        chunk: [UInt8](repeating: 1, count: 50))))
        // Real two-segment coverage completes.
        var b = QxPresetAssembler()
        b.group = .user
        XCTAssertFalse(b.ingest(segment(group: 0, total: 1, idx: 0, offset: 0,
                                        chunk: [UInt8](repeating: 1, count: 50))))
        XCTAssertTrue(b.ingest(segment(group: 0, total: 1, idx: 1, offset: 50,
                                       chunk: [UInt8](repeating: 2, count: 38))))
    }

    func testAssemblerRejectsWrongGroupAndOutOfBounds() {
        var a = QxPresetAssembler()
        a.group = .b20
        // Stale user-group segments during a group switch must be dropped.
        XCTAssertFalse(a.ingest(segment(group: 0, total: 1, idx: 0, offset: 0,
                                        chunk: [UInt8](repeating: 1, count: 50))))
        // A chunk that would write past the buffer is ignored, not trapped.
        XCTAssertFalse(a.ingest(segment(group: 2, total: 1, idx: 0, offset: 120,
                                        chunk: [UInt8](repeating: 1, count: 50))))
    }

    // MARK: - Status parser truncation poisoning

    func testTruncatedStatusBlockConsumesWholePacket() {
        var state = QxDeviceState()
        // Mask claims audio (4B) + power (8B) but only 6 bytes follow: the
        // parser must consume everything so a caller can't misparse a
        // following config block from a misaligned offset.
        let consumed = QxStatusParser.parseDevStatus(
            [QxStatusMask.audio | QxStatusMask.power, 0, 0, 0, 0, 1, 2],
            into: &state)
        XCTAssertEqual(consumed, 7)
    }

    func testTruncatedConfigBlockCannotFakeEqMode() {
        var state = QxDeviceState()
        // sys block truncated: eq_mode must stay unset rather than being
        // read from garbage.
        _ = QxStatusParser.parseDevConfig([QxConfigMask.sys, 1, 2, 3],
                                          into: &state)
        XCTAssertNil(state.eqMode)
    }

    // MARK: - Audio status block

    /// Hand-built audio ($c) block: mute=0, running=1, active_call=0,
    /// hfp_codec=0, a2dp_codec=6 (LDAC), in_source=1 (USB), in_bits=0,
    /// out_unbalanced=1, out_power=0, sample_rate_index=4 (48 kHz).
    private let audioBlockBytes: [UInt8] = [0xC2, 0x42, 0x04, 0x00]

    func testAudioBlockDecodesCodecGainAndJackFields() {
        var state = QxDeviceState()
        let data = [QxStatusMask.audio] + audioBlockBytes
        let consumed = QxStatusParser.parseDevStatus(data, into: &state)
        XCTAssertEqual(consumed, data.count)
        XCTAssertEqual(state.audioMuted, false)
        XCTAssertEqual(state.audioRunning, true)
        XCTAssertEqual(state.activeCall, false)
        XCTAssertEqual(state.codecLabel, "LDAC")
        XCTAssertEqual(state.inputSourceLabel, "USB")
        XCTAssertEqual(state.outputJackUnbalanced, true)
        XCTAssertEqual(state.outputHighGain, false)
        XCTAssertEqual(state.sampleRateLabel, "48 kHz")
    }

    func testAudioBlockOutOfRangeCodecIndexStaysNil() {
        var state = QxDeviceState()
        // a2dp_codec = 15 (0b1111), past the end of the codec label table.
        let data: [UInt8] = [QxStatusMask.audio, 0xE0, 0x01, 0x00, 0x00]
        _ = QxStatusParser.parseDevStatus(data, into: &state)
        XCTAssertNil(state.codecLabel)
    }

    func testTruncatedAudioBlockConsumesWholePacketAndSetsNothing() {
        var state = QxDeviceState()
        // Mask claims the audio block (4B) but only 3 bytes follow it.
        let data: [UInt8] = [QxStatusMask.audio, 0, 0, 0]
        let consumed = QxStatusParser.parseDevStatus(data, into: &state)
        XCTAssertEqual(consumed, data.count)
        XCTAssertNil(state.audioMuted)
        XCTAssertNil(state.audioRunning)
        XCTAssertNil(state.activeCall)
        XCTAssertNil(state.codecLabel)
        XCTAssertNil(state.outputJackUnbalanced)
        XCTAssertNil(state.outputHighGain)
        XCTAssertNil(state.sampleRateLabel)
        XCTAssertNil(state.inputSourceLabel)
    }

    // MARK: - Play-time config block

    func testPlayTimeBlockRoundTrips() {
        var state = QxDeviceState()
        let total: UInt32 = 123_456
        let atCharge: UInt32 = 42
        func le32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        let data = [QxConfigMask.playTime] + le32(total) + le32(atCharge)
        let consumed = QxStatusParser.parseDevConfig(data, into: &state)
        XCTAssertEqual(consumed, data.count)
        XCTAssertEqual(state.totalPlayTime, Int(total))
        XCTAssertEqual(state.totalPlayTimeAtLastCharge, Int(atCharge))
    }

    func testTruncatedPlayTimeBlockConsumesWholePacket() {
        var state = QxDeviceState()
        let data: [UInt8] = [QxConfigMask.playTime, 1, 2, 3]
        let consumed = QxStatusParser.parseDevConfig(data, into: &state)
        XCTAssertEqual(consumed, data.count)
        XCTAssertNil(state.totalPlayTime)
        XCTAssertNil(state.totalPlayTimeAtLastCharge)
    }

    // MARK: - Preset decode against REAL hardware bytes

    /// Captured live: a 20-band preset struct corrupted by both-channel
    /// writes (the bug fixed in cc4848d). The low bands' parameters were
    /// overwritten with frequency-table echoes; the plausibility guard must
    /// keep refusing it — this is the exact buffer that turned "preset is
    /// dropped" from a mystery into a diagnosis.
    private let corruptedB20Hex = """
        01 00 00 00 DB FF DB FF 1F 00 2C 00 3F 00 58 00 7D 00 B4 00 FA 00 63 01 \
        F4 01 C6 02 E8 03 78 05 D0 07 F0 0A A0 0F E0 15 40 1F 24 2C 80 3E 20 4E \
        E8 03 78 05 D0 07 F0 0A A0 0F E0 15 40 1F 24 2C 80 3E 20 4E B5 7E 33 02 \
        55 7F 33 02 95 7F 33 02 55 40 33 02 25 41 33 02 25 40 33 02 E5 7F 33 02 \
        05 7F 33 02 B5 40 33 02 E5 41 33 02 35 40 33 02 D5 40 33 02 45 7E 33 02 \
        E5 7B 33 02 95 78 33 02
        """

    func testCorruptedB20BufferStaysImplausible() {
        let buf = corruptedB20Hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        XCTAssertEqual(buf.count, 128)
        let decoded = QxUserEqPreset.decode(buf, group: .b20)
        XCTAssertEqual(decoded.preGain, -3.7, accuracy: 0.01)
        XCTAssertFalse(decoded.looksPlausible)
    }

    func testWriteChannelMaskNeverBothOnSingleChannelGroups() {
        XCTAssertEqual(QxEqGroup.user.writeChannelMask, 1)
        XCTAssertEqual(QxEqGroup.b20.writeChannelMask, 1)
        XCTAssertEqual(QxEqGroup.speaker.writeChannelMask, 3)
    }

    // MARK: - Parametric file parsing

    func testParametricParseTwentyBandsAndBounds() {
        var lines = ["Preamp: -3.5 dB"]
        for i in 1...22 {
            lines.append("Filter \(i): ON PK Fc \(100 * i) Hz Gain 1.0 dB Q 1.00")
        }
        let file = ParametricEQFile.parse(lines.joined(separator: "\n"))
        XCTAssertEqual(file?.bands.count, 20)
        XCTAssertEqual(file?.droppedBands, 2)
    }

    func testParametricParseRejectsNonFinite() {
        let text = """
        Preamp: nan dB
        Filter 1: ON PK Fc inf Hz Gain 1e400 dB Q 0.5
        Filter 2: ON PK Fc 1000 Hz Gain 3.0 dB Q 1.0
        """
        let file = ParametricEQFile.parse(text)
        // The poisoned band is dropped; the good one survives.
        XCTAssertEqual(file?.bands.count, 1)
        XCTAssertEqual(file?.bands.first?.freq, 1000)
    }

    func testParametricParseIsCaseInsensitive() {
        let file = ParametricEQFile.parse("""
            preamp: -3.5 db
            filter 1: on pk fc 1000 hz gain 3.0 db q 1.00
            """)
        XCTAssertEqual(file?.preamp, -3.5)
        XCTAssertEqual(file?.bands.first?.filter, .peak)
        XCTAssertEqual(file?.bands.first?.gain, 3.0)
    }

    func testParametricParseToleratesTabsAndRunsOfSpaces() {
        let file = ParametricEQFile.parse(
            "Filter 1:\tON\tPK\tFc\t1000\tHz\tGain\t3.0\tdB\tQ\t1.00")
        XCTAssertEqual(file?.bands.count, 1)
        XCTAssertEqual(file?.bands.first?.freq, 1000)
        XCTAssertEqual(ParametricEQFile.parse(
            "Filter  1:   ON   PK   Fc  1000 Hz  Gain  3.0 dB  Q  1.00")?.bands.count, 1)
    }

    func testParametricParseAcceptsGainlessPassFiltersAndQlessShelves() {
        let file = ParametricEQFile.parse("""
            Filter 1: ON HPQ Fc 30 Hz
            Filter 2: ON LPQ Fc 16000 Hz Q 0.5
            Filter 3: ON LSC Fc 105 Hz Gain 6.4 dB
            """)
        XCTAssertEqual(file?.bands.count, 3)
        XCTAssertEqual(file?.bands[0].filter, .hpf)
        XCTAssertEqual(file?.bands[0].q, ParametricEQFile.defaultShelfQ)
        XCTAssertEqual(file?.bands[1].q, 0.5)
        XCTAssertEqual(file?.bands[2].filter, .lowShelf)
        XCTAssertEqual(file?.bands[2].q, ParametricEQFile.defaultShelfQ)
    }

    func testAPassFilterCarriesNoGainOutOfTheFile() {
        let file = ParametricEQFile.parse("Filter 1: ON LPQ Fc 8000 Hz Gain -9.0 dB Q 0.7")
        XCTAssertEqual(file?.bands.first?.filter, .lpf)
        XCTAssertEqual(file?.bands.first?.gain, 0)
    }

    func testParametricParseAcceptsAColonlessPreambleAndNoSpaceBeforeDB() {
        XCTAssertEqual(ParametricEQFile.parse("Preamp -6.4dB\nFilter 1: ON PK Fc 100 Hz "
                                              + "Gain 1 dB Q 1")?.preamp, -6.4)
    }

    func testParametricParseSkipsCommentsAndHostileMegaLines() {
        let monster = "Filter 1: ON PK Fc 100 Hz Gain "
            + String(repeating: "1", count: ParametricEQFile.maxLineLength) + " dB Q 1"
        let file = ParametricEQFile.parse("""
            # oratory1990's correction, do not edit
            \(monster)
            Filter 2: ON PK Fc 1000 Hz Gain 3.0 dB Q 1.0
            """)
        XCTAssertEqual(file?.bands.count, 1)
        XCTAssertEqual(file?.bands.first?.freq, 1000)
    }

    func testDuplicateCentresAreNudgedApartWithoutReorderingTheBands() {
        let file = ParametricEQFile.parse("""
            Filter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q 1.0
            Filter 2: ON PK Fc 1000 Hz Gain -2.0 dB Q 1.0
            Filter 3: ON PK Fc 1000 Hz Gain 1.0 dB Q 1.0
            """)
        let freqs = file?.bands.map(\.freq) ?? []
        XCTAssertEqual(Set(freqs).count, 3, "every band needs its own centre: \(freqs)")
        XCTAssertEqual(file?.bands.map(\.gain), [3.0, -2.0, 1.0])
    }

    func testTrimmingKeepsTheFiltersDoingTheMostWork() {
        func gain(_ i: Int) -> Double { (Double(i) * 4).rounded() / 10 }
        var lines: [String] = []
        for i in 1...25 {
            lines.append(String(format: "Filter %d: ON PK Fc %d Hz Gain %.1f dB Q 1.00",
                                i, 100 * i, gain(i)))
        }
        let file = ParametricEQFile.parse(lines.joined(separator: "\n"))
        XCTAssertEqual(file?.bands.count, 20)
        XCTAssertEqual(file?.droppedBands, 5)
        XCTAssertEqual(file?.bands.map(\.gain), (6...25).map(gain))
    }

    func testAPassFilterIsNeverTrimmedAwayAsWeak() {
        var lines = ["Filter 1: ON HPQ Fc 30 Hz Q 0.7"]
        for i in 1...25 {
            lines.append("Filter \(i + 1): ON PK Fc \(100 * i) Hz Gain 5.0 dB Q 1.00")
        }
        let file = ParametricEQFile.parse(lines.joined(separator: "\n"))
        XCTAssertEqual(file?.bands.first?.filter, .hpf)
    }

    func testTheFileSaysWhatItCouldNotHonour() {
        let file = ParametricEQFile.parse("""
            Preamp: -18.0 dB
            Filter 1: ON BP Fc 1000 Hz Gain 3.0 dB Q 1.0
            Filter 2: ON PK Fc 2000 Hz Gain 3.0 dB
            Filter 3: ON PK Fc 4000 Hz Gain -20.0 dB Q 1.0
            """)
        let notes = file?.notes ?? []
        XCTAssertTrue(notes.contains { $0.contains("skipped 1 filter line") }, "\(notes)")
        XCTAssertTrue(notes.contains { $0.contains("pre-gain") }, "\(notes)")
        XCTAssertTrue(notes.contains { $0.contains("clamped") }, "\(notes)")
    }

    func testAFileWithNothingToReportSaysNothing() {
        let file = ParametricEQFile.parse("""
            Preamp: -6.1 dB
            Filter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q 1.0
            """)
        XCTAssertEqual(file?.notes, [])
    }

    // MARK: - String scrubbing

    func testDisplayNameScrubsControlAndBidi() {
        let hostile = "Qude\u{202E}lix\nX" + String(repeating: "A", count: 100)
        let cleaned = QudelixController.displayName(hostile)
        XCTAssertFalse(cleaned.unicodeScalars.contains { $0.value == 0x202E })
        XCTAssertFalse(cleaned.contains("\n"))
        XCTAssertLessThanOrEqual(cleaned.count, QudelixController.maxPresetNameLength)
    }

    func testSafeTextDropsEveryInvisibleItClaimsTo() {
        let hostile = "a\u{0}b\u{1B}c\u{7F}d\u{9B}e\n\u{2028}\u{2029}"
            + "\u{200B}\u{200E}\u{202E}\u{2066}\u{FEFF}\u{00AD}\u{061C}"
            + "\u{FE0F}\u{115F}\u{1160}\u{3164}\u{E0041}\u{E007F}f"
        XCTAssertEqual(SafeText.scrubbed(hostile), "abcdef")
    }

    func testSafeTextKeepsOrdinaryTextIncludingEmoji() {
        XCTAssertEqual(SafeText.scrubbed("Sennheiser HD 650 — oratory1990"),
                       "Sennheiser HD 650 — oratory1990")
    }

    func testSafeTextCapsLengthAndSaysItDidSo() {
        let capped = SafeText.scrubbed(String(repeating: "A", count: 500), limit: 16)
        XCTAssertEqual(capped, String(repeating: "A", count: 16) + "…")
    }

    func testDisplayNameDropsTheMarksTheCategoryFilterMisses() {
        let hostile = "Qu\u{FE0F}de\u{115F}li\u{3164}x\u{E0041}"
        XCTAssertEqual(QudelixController.displayName(hostile), "Qudelix")
    }

    func testOnlyTheShapesWithAGainParameterSayTheyHaveOne() {
        XCTAssertEqual(QxFilter.allCases.filter(\.hasGain),
                       [.lowShelf, .highShelf, .peak])
    }

    func testLogSanitizerEscapesForgery() {
        let line = DebugLog.sanitized("evil\ninjected\u{202E}")
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(line.contains("\\u{000A}"))
        XCTAssertTrue(line.contains("\\u{202E}"))
    }

    // MARK: - Snapshot tolerance

    func testSnapshotMatchesUsesDeviceScaleTolerances() {
        let bands = [QxEqBandValue(filter: .peak, freq: 1000, gain: 2.0, q: 1.0)]
        let snap = EqSnapshot(groupRaw: 0, bands: bands, preGain: -3.7,
                              enabled: true, name: nil)
        // The device echoes through fixed-point scaling: tiny drift matches…
        var echoed = bands
        echoed[0].gain = 2.05
        echoed[0].q = 1.01
        XCTAssertTrue(snap.matches(bands: echoed, preGain: -3.72))
        // …a real difference doesn't.
        echoed[0].gain = 2.4
        XCTAssertFalse(snap.matches(bands: echoed, preGain: -3.7))
    }
}
