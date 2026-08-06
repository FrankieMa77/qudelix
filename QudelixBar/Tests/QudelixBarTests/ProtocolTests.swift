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

    // MARK: - String scrubbing

    @MainActor
    func testDisplayNameScrubsControlAndBidi() {
        let hostile = "Qude\u{202E}lix\nX" + String(repeating: "A", count: 100)
        let cleaned = QudelixController.displayName(hostile)
        XCTAssertFalse(cleaned.unicodeScalars.contains { $0.value == 0x202E })
        XCTAssertFalse(cleaned.contains("\n"))
        XCTAssertLessThanOrEqual(cleaned.count, QudelixController.maxPresetNameLength)
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
