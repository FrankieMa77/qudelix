import XCTest
@testable import QudelixBar

final class HistoryCommandsTests: XCTestCase {
    private var directory: URL!
    private var output: StdIOCapture!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qx-history-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        EqHistoryFile.directoryOverride = directory
        output = StdIOCapture()
        let capture = output
        StdIO.outSink = { line in capture?.append(line) }
    }

    override func tearDown() {
        StdIO.outSink = nil
        EqHistoryFile.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        output = nil
        directory = nil
        super.tearDown()
    }

    private func connected(_ link: FakeLink,
                           timeout: TimeInterval = 2) async throws -> QxSession {
        let session = QxSession(link: link, timeout: timeout)
        async let connecting: Void = session.connect(timeout: timeout)
        link.bringUp()
        try await connecting
        return session
    }

    private func entry(_ label: String, bands: Int = 10, preGain: Double = 0,
                       at date: Date = Date()) -> EqHistoryEntry {
        let freqs = bands == 20 ? QxEqGroup.b20.defaultFreqs : QxEqGroup.user.defaultFreqs
        let values = freqs.prefix(bands).map {
            QxEqBandValue(filter: .peak, freq: $0, gain: 1.5, q: 1.0)
        }
        return EqHistoryEntry(
            recordedAt: date,
            label: label,
            snapshot: EqSnapshot(groupRaw: bands == 20 ? QxEqGroup.b20.rawValue
                                                       : QxEqGroup.user.rawValue,
                                 bands: Array(values),
                                 preGain: preGain,
                                 enabled: true,
                                 name: nil,
                                 mutedBands: [:],
                                 deviceIdentity: "usb:Qudelix 5K"))
    }

    func testParseAcceptsEverySubcommand() throws {
        XCTAssertEqual(try HistoryCommand.parse(["list"]), .list)
        XCTAssertEqual(try HistoryCommand.parse(["show", "3"]), .show(3))
        XCTAssertEqual(try HistoryCommand.parse(["restore", "1"]), .restore(1))
        XCTAssertEqual(try HistoryCommand.parse(["clear"]), .clear)
    }

    func testParseRejectsAMissingSubcommand() {
        assertUsage([], contains: "history needs list, show, restore or clear")
    }

    func testParseRejectsAnUnknownSubcommand() {
        assertUsage(["undo"], contains: "not undo")
    }

    func testParseRejectsAShowWithoutANumber() {
        assertUsage(["show"], contains: "needs an entry number")
        assertUsage(["restore"], contains: "needs an entry number")
    }

    func testParseRejectsAShowWithTooManyNumbers() {
        assertUsage(["show", "1", "2"], contains: "takes one entry number")
    }

    func testParseRejectsANumberThatIsNotAPosition() {
        assertUsage(["show", "0"], contains: "whole number from 1")
        assertUsage(["show", "-2"], contains: "whole number from 1")
        assertUsage(["restore", "newest"], contains: "whole number from 1")
    }

    func testParseRejectsExtraArgumentsOnListAndClear() {
        assertUsage(["list", "3"], contains: "history list takes no arguments")
        assertUsage(["clear", "all"], contains: "history clear takes no arguments")
    }

    private func assertUsage(_ rest: [String], contains needle: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try HistoryCommand.parse(rest)
            XCTFail("expected \(rest) to be rejected", file: file, line: line)
        } catch let error as CLIUsageError {
            XCTAssertTrue(error.message.contains(needle),
                          "\(error.message) does not mention \(needle)",
                          file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    func testOnlyRestoreNeedsTheDeviceAndTheFlashSave() {
        XCTAssertFalse(HistoryCommand.list.needsDevice)
        XCTAssertFalse(HistoryCommand.show(1).needsDevice)
        XCTAssertFalse(HistoryCommand.clear.needsDevice)
        XCTAssertTrue(HistoryCommand.restore(1).needsDevice)
        XCTAssertFalse(HistoryCommand.list.persistsToFlash)
        XCTAssertFalse(HistoryCommand.show(1).persistsToFlash)
        XCTAssertFalse(HistoryCommand.clear.persistsToFlash)
        XCTAssertTrue(HistoryCommand.restore(1).persistsToFlash)
    }

    func testUsageLinesAreIndentedAndPaddedLikeTheRest() {
        XCTAssertEqual(HistoryCommand.usageLines.count, 4)
        for line in HistoryCommand.usageLines {
            XCTAssertTrue(line.hasPrefix("  history "), line)
            XCTAssertFalse(line.hasPrefix("   "), line)
            let body = Array(line.dropFirst(2))
            XCTAssertGreaterThan(body.count, 26, line)
            let field = String(body[0..<26])
            XCTAssertEqual(field, QxFormat.pad(field.trimmingCharacters(in: .whitespaces), 26),
                           line)
            XCTAssertNotEqual(body[26], " ", line)
        }
        for line in HistoryCommand.usageLines {
            XCTAssertTrue(CLI.usageText.contains(line), line)
        }
    }

    func testApplyRecordsExactlyOneEntryPerApply() async throws {
        let link = QxFixtures.answeringLink(preGain: -3)
        let session = try await connected(link)
        defer { session.close() }

        var file = ParametricEQFile()
        file.preamp = -6
        file.bands = QxFixtures.tenBands
        _ = try await session.applyParametric(file)

        var history = EqHistoryFile.load()
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries[0].label, "import")
        XCTAssertEqual(history.entries[0].snapshot.bands.count, 10)
        XCTAssertEqual(history.entries[0].snapshot.preGain, -3, accuracy: 0.06)
        XCTAssertEqual(history.entries[0].snapshot.groupRaw, QxEqGroup.user.rawValue)
        XCTAssertEqual(history.entries[0].snapshot.deviceIdentity, "usb:Qudelix 5K")

        _ = try await session.applyParametric(file)
        history = EqHistoryFile.load()
        XCTAssertEqual(history.entries.count, 2)
        XCTAssertEqual(history.entries.map(\.label), ["import", "import"])
    }

    func testApplyRecordsNothingWhenTheRecordingLabelIsWithheld() async throws {
        let link = QxFixtures.answeringLink()
        let session = try await connected(link)
        defer { session.close() }

        var file = ParametricEQFile()
        file.bands = QxFixtures.tenBands
        _ = try await session.applyParametric(file, recording: nil)
        XCTAssertTrue(EqHistoryFile.load().entries.isEmpty)
    }

    func testLoadPresetRecordsTheLabelTheControllerWouldUse() async throws {
        let link = QxFixtures.answeringLink(nameMask: 1 << 2)
        let session = try await connected(link)
        defer { session.close() }

        _ = try await session.loadPreset(index: 4)
        XCTAssertEqual(EqHistoryFile.load().entries.map(\.label), ["load Preset 5"])

        _ = try await session.presetName(index: 2)
        _ = try await session.loadPreset(index: 2)
        XCTAssertEqual(EqHistoryFile.load().entries.map(\.label),
                       ["load Preset 5", "load Slot 3"])
    }

    func testHistoryIsCappedAtTheRecordedDepth() {
        for index in 0..<(EqHistoryFile.depth + 5) {
            EqHistoryFile.append(entry("edit \(index)"))
        }
        let history = EqHistoryFile.load()
        XCTAssertEqual(history.entries.count, EqHistoryFile.depth)
        XCTAssertEqual(history.entries.first?.label, "edit 5")
        XCTAssertEqual(history.entries.last?.label,
                       "edit \(EqHistoryFile.depth + 4)")
    }

    func testLoadClampsValuesComingOffDisk() {
        var wild = entry("hand-edited")
        wild.snapshot.preGain = 400
        wild.snapshot.bands[0].gain = 900
        wild.snapshot.bands[0].q = -5
        wild.snapshot.bands[1].freq = 99999
        EqHistoryFile.append(wild)
        let loaded = EqHistoryFile.load().entries[0].snapshot
        XCTAssertEqual(loaded.preGain, 12, accuracy: 0.001)
        XCTAssertEqual(loaded.bands[0].gain, 12, accuracy: 0.001)
        XCTAssertEqual(loaded.bands[0].q, 0.1, accuracy: 0.001)
        XCTAssertEqual(loaded.bands[1].freq, 20000)
    }

    func testALabelOffDiskCannotForgeALineOrReorderOne() {
        EqHistoryFile.append(entry("import\nqudelix: wiped\u{202E}"))
        let label = EqHistoryFile.load().entries[0].label
        XCTAssertFalse(label.contains("\n"), label)
        XCTAssertFalse(label.unicodeScalars.contains { $0.value == 0x202E }, label)
        XCTAssertTrue(label.hasPrefix("import"), label)
    }

    func testALabelKeepsTheWholePresetNameItWasBuiltFrom() {
        let name = String(repeating: "L", count: QudelixController.maxPresetNameLength)
        EqHistoryFile.append(entry("load " + name))
        XCTAssertEqual(EqHistoryFile.load().entries[0].label, "load " + name)
    }

    func testAnUnreadableFileIsParkedRatherThanRead() throws {
        let url = EqHistoryFile.url
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(EqHistoryFile.load().entries.isEmpty)
        let parked = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".recovered")
        XCTAssertTrue(FileManager.default.fileExists(atPath: parked.path))
    }

    func testListPrintsIndexTimeLabelAndBandCount() async throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        EqHistoryFile.append(entry("import", at: when))
        EqHistoryFile.append(entry("load Preset 2", bands: 20, at: when.addingTimeInterval(60)))

        try await HistoryCommand.list.run(options: CLIOptions(), session: nil)
        let lines = output.all
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("#"))
        XCTAssertTrue(lines[1].hasPrefix("1    "), lines[1])
        XCTAssertTrue(lines[1].contains("load Preset 2"), lines[1])
        XCTAssertTrue(lines[1].contains(QxFormat.timestamp(when.addingTimeInterval(60))),
                      lines[1])
        XCTAssertTrue(lines[1].hasSuffix("20"), lines[1])
        XCTAssertTrue(lines[2].hasPrefix("2    "), lines[2])
        XCTAssertTrue(lines[2].contains("import"), lines[2])
        XCTAssertTrue(lines[2].hasSuffix("10"), lines[2])
    }

    func testListSaysSoWhenNothingIsRecorded() async throws {
        try await HistoryCommand.list.run(options: CLIOptions(), session: nil)
        XCTAssertEqual(output.all, ["no EQ edits recorded yet"])
    }

    func testListAsJson() async throws {
        EqHistoryFile.append(entry("import"))
        EqHistoryFile.append(entry("load Preset 2", bands: 20))
        var options = CLIOptions()
        options.json = true
        try await HistoryCommand.list.run(options: options, session: nil)
        let entries = output.object["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, 2)
        XCTAssertEqual(entries?[0]["index"] as? Int, 1)
        XCTAssertEqual(entries?[0]["label"] as? String, "load Preset 2")
        XCTAssertEqual(entries?[0]["bands"] as? Int, 20)
        XCTAssertEqual(entries?[1]["index"] as? Int, 2)
        XCTAssertEqual(entries?[1]["label"] as? String, "import")
        XCTAssertNotNil(entries?[0]["recorded_at"] as? String)
    }

    func testShowPrintsTheBandTable() async throws {
        EqHistoryFile.append(entry("import", preGain: -4))
        try await HistoryCommand.show(1).run(options: CLIOptions(), session: nil)
        let lines = output.all
        XCTAssertTrue(lines[0].contains("import"), lines[0])
        XCTAssertTrue(lines.contains("pre-gain  -4.0 dB"), output.text)
        XCTAssertEqual(lines.filter { $0.contains("Hz") }.count, 10)
    }

    func testShowAsJson() async throws {
        EqHistoryFile.append(entry("import", preGain: -4))
        var options = CLIOptions()
        options.json = true
        try await HistoryCommand.show(1).run(options: options, session: nil)
        let object = output.object
        XCTAssertEqual(object["index"] as? Int, 1)
        XCTAssertEqual(object["label"] as? String, "import")
        XCTAssertEqual(object["pre_gain_db"] as? Double, -4)
        XCTAssertEqual(object["enabled"] as? Bool, true)
        XCTAssertNotNil(object["recorded_at"] as? String)
        XCTAssertEqual((object["bands"] as? [[String: Any]])?.count, 10)
    }

    func testShowRejectsAnEntryThatIsNotThere() async {
        EqHistoryFile.append(entry("import"))
        await assertUsageAtRun(.show(2), contains: "there is no entry 2")
        EqHistoryFile.clear()
        await assertUsageAtRun(.show(1), contains: "no EQ edits recorded yet")
    }

    private func assertUsageAtRun(_ command: HistoryCommand, contains needle: String,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await command.run(options: CLIOptions(), session: nil)
            XCTFail("expected \(command) to be rejected", file: file, line: line)
        } catch let error as CLIUsageError {
            XCTAssertTrue(error.message.contains(needle),
                          "\(error.message) does not mention \(needle)",
                          file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    func testClearForgetsEverything() async throws {
        EqHistoryFile.append(entry("import"))
        XCTAssertFalse(EqHistoryFile.load().entries.isEmpty)
        try await HistoryCommand.clear.run(options: CLIOptions(), session: nil)
        XCTAssertEqual(output.all, ["history cleared"])
        XCTAssertTrue(EqHistoryFile.load().entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: EqHistoryFile.url.path))
    }

    func testClearOnAnEmptyHistoryIsNotAnError() async throws {
        try await HistoryCommand.clear.run(options: CLIOptions(), session: nil)
        XCTAssertEqual(output.all, ["history cleared"])
    }

    func testRestoreWritesTheCurveAndSendsOnlyAllowedCommands() async throws {
        EqHistoryFile.append(entry("import", preGain: -4))
        let link = QxFixtures.answeringLink()
        let session = try await connected(link)
        defer { session.close() }
        link.clearSends()

        try await HistoryCommand.restore(1).run(options: CLIOptions(), session: session)

        for command in link.sentCommands {
            XCTAssertTrue(QxSession.allowed.contains(command),
                          "\(command) is not a command this tool may send")
        }
        XCTAssertTrue(link.sentCommands.contains(.setEqType))
        XCTAssertEqual(link.payloads(for: .setEqPreGain).count, 2)
        XCTAssertEqual(link.payloads(for: .setEqBandParam).count, 10)
        XCTAssertFalse(link.sentCommands.contains(.saveAll))
        XCTAssertTrue(output.all[0].hasPrefix("restored entry 1 — import"), output.text)
    }

    func testRestoreRecordsThePreRestoreCurve() async throws {
        EqHistoryFile.append(entry("import", preGain: -4))
        let link = QxFixtures.answeringLink(preGain: -3)
        let session = try await connected(link)
        defer { session.close() }

        try await HistoryCommand.restore(1).run(options: CLIOptions(), session: session)
        let labels = EqHistoryFile.load().entries.map(\.label)
        XCTAssertEqual(labels, ["import", "restore 1"])
        XCTAssertEqual(EqHistoryFile.load().entries[1].snapshot.preGain, -3, accuracy: 0.06)
    }

    func testRestoreRefusesACurveOfTheWrongWidth() async throws {
        EqHistoryFile.append(entry("import", bands: 20))
        let link = QxFixtures.answeringLink()
        let session = try await connected(link)
        defer { session.close() }
        link.clearSends()

        do {
            try await HistoryCommand.restore(1).run(options: CLIOptions(), session: session)
            XCTFail("expected the width mismatch to be refused")
        } catch let error as CLIUsageError {
            XCTAssertTrue(error.message.contains("20 bands"), error.message)
        }
        XCTAssertTrue(link.sentCommands.isEmpty)
    }

    func testRestoreWithoutASessionIsAUsageError() async {
        EqHistoryFile.append(entry("import"))
        await assertUsageAtRun(.restore(1), contains: "needs the device")
    }

    func testRestoreAsJson() async throws {
        EqHistoryFile.append(entry("import", preGain: -4))
        let link = QxFixtures.answeringLink(preGain: -4)
        let session = try await connected(link)
        defer { session.close() }
        var options = CLIOptions()
        options.json = true

        try await HistoryCommand.restore(1).run(options: options, session: session)
        let object = output.object
        XCTAssertEqual(object["restored"] as? Int, 1)
        XCTAssertEqual(object["label"] as? String, "import")
        XCTAssertEqual((object["bands"] as? [[String: Any]])?.count, 10)
    }
}
