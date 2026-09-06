import XCTest
@testable import QudelixBar

final class CLITests: XCTestCase {
    private func parse(_ line: String) throws -> CLIInvocation {
        try CLI.parse(line.split(separator: " ").map(String.init))
    }

    private func command(_ line: String) throws -> CLICommand {
        try parse(line).command
    }

    private func usageMessage(_ arguments: [String]) -> String? {
        do {
            _ = try CLI.parse(arguments)
            return nil
        } catch let error as CLIUsageError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    func testDefaultOptions() throws {
        let options = try parse("status").options
        XCTAssertNil(options.preferred)
        XCTAssertFalse(options.json)
        XCTAssertFalse(options.verbose)
        XCTAssertEqual(options.timeout, 5)
    }

    func testGlobalFlagsAreAcceptedBeforeAndAfterTheCommand() throws {
        let before = try parse("--usb --json --verbose --timeout 12 status")
        XCTAssertEqual(before.options.preferred, .usb)
        XCTAssertTrue(before.options.json)
        XCTAssertTrue(before.options.verbose)
        XCTAssertEqual(before.options.timeout, 12)
        XCTAssertEqual(before.command, .status)

        let after = try parse("status --ble --timeout=0.5")
        XCTAssertEqual(after.options.preferred, .bluetooth)
        XCTAssertEqual(after.options.timeout, 0.5)
        XCTAssertEqual(after.command, .status)
    }

    func testHelpWins() throws {
        XCTAssertEqual(try command("--help"), .help)
        XCTAssertEqual(try command("status --help"), .help)
        XCTAssertEqual(try command("help"), .help)
        XCTAssertFalse(CLI.usageText.isEmpty)
    }

    func testBadTimeoutsAreUsageErrors() {
        XCTAssertNotNil(usageMessage(["--timeout"]))
        XCTAssertNotNil(usageMessage(["--timeout", "zero", "status"]))
        XCTAssertNotNil(usageMessage(["--timeout", "0", "status"]))
        XCTAssertNotNil(usageMessage(["--timeout", "-4", "status"]))
        XCTAssertNotNil(usageMessage(["--timeout", "9999", "status"]))
    }

    func testUnknownOptionAndUnknownCommandAreUsageErrors() {
        XCTAssertEqual(usageMessage(["--wat", "status"]), "unknown option --wat")
        XCTAssertEqual(usageMessage(["frobnicate"]), "unknown command frobnicate")
        XCTAssertEqual(usageMessage([]), "no command given")
    }

    func testProbeStatusAndWatchTakeNoArguments() throws {
        XCTAssertEqual(try command("probe"), .probe)
        XCTAssertEqual(try command("status"), .status)
        XCTAssertEqual(try command("watch"), .watch)
        XCTAssertEqual(usageMessage(["probe", "now"]), "probe takes no arguments")
        XCTAssertEqual(usageMessage(["status", "now"]), "status takes no arguments")
        XCTAssertEqual(usageMessage(["watch", "now"]), "watch takes no arguments")
    }

    func testProbeAndHelpNeedNoDevice() {
        XCTAssertFalse(CLI.needsDevice(.probe))
        XCTAssertFalse(CLI.needsDevice(.help))
        XCTAssertTrue(CLI.needsDevice(.status))
        XCTAssertTrue(CLI.needsDevice(.watch))
    }

    func testVolume() throws {
        XCTAssertEqual(try command("volume"), .volumeShow)
        XCTAssertEqual(try command("volume mute"), .volumeMute(true))
        XCTAssertEqual(try command("volume UNMUTE"), .volumeMute(false))
        XCTAssertEqual(try command("volume -12.5"), .volumeSet(-12.5))
        XCTAssertEqual(try command("volume 0"), .volumeSet(0))
        XCTAssertNotNil(usageMessage(["volume", "loud"]))
        XCTAssertNotNil(usageMessage(["volume", "nan"]))
        XCTAssertNotNil(usageMessage(["volume", "-3", "-6"]))
    }

    func testFilter() throws {
        XCTAssertEqual(try command("filter"), .filterList)
        XCTAssertEqual(try command("filter 0"), .filterSet(0))
        XCTAssertEqual(try command("filter 7"), .filterSet(7))
        XCTAssertEqual(try command("filter NOS"), .filterSet(7))
        XCTAssertEqual(try command("filter hybrid"), .filterSet(6))
        XCTAssertNotNil(usageMessage(["filter", "8"]))
        XCTAssertNotNil(usageMessage(["filter", "-1"]))
        XCTAssertNotNil(usageMessage(["filter", "nonsense"]))
        XCTAssertNotNil(usageMessage(["filter", "phase"]))
        XCTAssertNotNil(usageMessage(["filter", "0", "1"]))
    }

    func testEveryFilterNameResolvesToItsOwnIndex() throws {
        for (index, name) in QxStatusParser.dacFilters.enumerated() {
            XCTAssertEqual(try CLI.resolveFilter(name), index)
        }
    }

    func testEq() throws {
        XCTAssertEqual(try command("eq show"), .eqShow)
        XCTAssertEqual(try command("eq on"), .eqEnable(true))
        XCTAssertEqual(try command("eq off"), .eqEnable(false))
        XCTAssertEqual(try command("eq enable"), .eqEnable(true))
        XCTAssertEqual(try command("eq disable"), .eqEnable(false))
        XCTAssertNotNil(usageMessage(["eq"]))
        XCTAssertNotNil(usageMessage(["eq", "sideways"]))
        XCTAssertNotNil(usageMessage(["eq", "show", "please"]))
    }

    func testPresetSlotsAreOneBased() throws {
        XCTAssertEqual(try command("preset list"), .presetList)
        XCTAssertEqual(try command("preset load 1"), .presetLoad(0))
        XCTAssertEqual(try command("preset load 20"), .presetLoad(19))
        XCTAssertEqual(try command("preset save 7"), .presetSave(6))
        XCTAssertEqual(try command("preset name 3 Bassy"), .presetRename(index: 2, name: "Bassy"))
        XCTAssertEqual(try command("preset pull /tmp/eq.json"), .presetPull("/tmp/eq.json"))
        XCTAssertEqual(try command("preset push /tmp/eq.json"), .presetPush("/tmp/eq.json"))
    }

    func testPresetUsageErrors() {
        XCTAssertNotNil(usageMessage(["preset"]))
        XCTAssertNotNil(usageMessage(["preset", "sideways"]))
        XCTAssertNotNil(usageMessage(["preset", "list", "all"]))
        XCTAssertNotNil(usageMessage(["preset", "load"]))
        XCTAssertNotNil(usageMessage(["preset", "load", "0"]))
        XCTAssertNotNil(usageMessage(["preset", "load", "21"]))
        XCTAssertNotNil(usageMessage(["preset", "load", "first"]))
        XCTAssertNotNil(usageMessage(["preset", "save", "0"]))
        XCTAssertNotNil(usageMessage(["preset", "name", "3"]))
        XCTAssertNotNil(usageMessage(["preset", "name", "3", "a", "b"]))
        XCTAssertNotNil(usageMessage(["preset", "pull"]))
        XCTAssertNotNil(usageMessage(["preset", "push"]))
    }

    func testDoubleDashKeepsANameThatLooksLikeAFlag() throws {
        let invocation = try CLI.parse(["preset", "name", "4", "--", "--json"])
        XCTAssertEqual(invocation.command, .presetRename(index: 3, name: "--json"))
        XCTAssertFalse(invocation.options.json)
    }

    func testImport() throws {
        XCTAssertEqual(try command("import /tmp/harman.txt"), .importFile("/tmp/harman.txt"))
        XCTAssertNotNil(usageMessage(["import"]))
        XCTAssertNotNil(usageMessage(["import", "a", "b"]))
    }

    func testExitCodes() {
        XCTAssertEqual(CLIExit.ok, 0)
        XCTAssertEqual(CLIExit.deviceError, 1)
        XCTAssertEqual(CLIExit.usageError, 2)
        XCTAssertEqual(CLIExit.noTransport, 3)
    }

    func testUsageErrorsExitTwoAndNoTransportExitsThree() async {
        let usage = await QudelixCLI.run(arguments: ["frobnicate"], makeLinks: { _ in [] })
        XCTAssertEqual(usage, CLIExit.usageError)
        let help = await QudelixCLI.run(arguments: ["--help"], makeLinks: { _ in [] })
        XCTAssertEqual(help, CLIExit.ok)
        let probe = await QudelixCLI.run(arguments: ["probe"], makeLinks: { _ in [] })
        XCTAssertEqual(probe, CLIExit.ok)
        let noTransport = await QudelixCLI.run(arguments: ["status"], makeLinks: { _ in [] })
        XCTAssertEqual(noTransport, CLIExit.noTransport)
    }

    func testDeviceErrorExitsOneWhenTheLinkNeverAnswers() async {
        let link = FakeLink()
        link.onSend = { _, _ in }
        let exit = await QudelixCLI.run(arguments: ["--timeout", "0.2", "status"],
                                        makeLinks: { _ in [link] })
        XCTAssertEqual(exit, CLIExit.deviceError)
    }

    private func deviceLink(nameMask: Int = 0) -> FakeLink {
        let link = QxFixtures.answeringLink(nameMask: nameMask)
        link.autoConnectOnStart = true
        return link
    }

    private func run(_ arguments: [String], _ link: FakeLink) async -> Int32 {
        await QudelixCLI.run(arguments: ["--timeout", "2"] + arguments,
                             makeLinks: { _ in [link] })
    }

    func testEveryDeviceCommandRunsAgainstAFakeDevice() async {
        for arguments in [["status"], ["status", "--json"],
                          ["volume"], ["volume", "-20"], ["volume", "mute"],
                          ["filter"], ["filter", "2"],
                          ["eq", "show"], ["eq", "show", "--json"], ["eq", "off"],
                          ["preset", "list"], ["preset", "save", "3"],
                          ["preset", "load", "3"]] {
            let exit = await run(arguments, deviceLink(nameMask: 0b101))
            XCTAssertEqual(exit, CLIExit.ok, "\(arguments)")
        }
    }

    func testOnlyAllowedCommandsEverReachTheLink() async {
        for arguments in [["status"], ["volume", "-20"], ["volume", "mute"],
                          ["filter", "2"], ["eq", "show"], ["eq", "off"],
                          ["preset", "list"], ["preset", "save", "3"],
                          ["preset", "load", "3"], ["preset", "name", "3", "Bassy"]] {
            let link = deviceLink(nameMask: 0b101)
            _ = await run(arguments, link)
            for command in link.sentCommands {
                XCTAssertTrue(QxSession.allowed.contains(command),
                              "\(arguments) sent \(command)")
            }
        }
    }

    func testPullThenPushRoundTripsThroughAFile() async throws {
        let path = NSTemporaryDirectory() + "/qudelix-pull-" + UUID().uuidString + ".json"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let pull = await run(["preset", "pull", path], deviceLink())
        XCTAssertEqual(pull, CLIExit.ok)

        let record = try QudelixCLI.loadSnapshotFile(path, group: .user)
        XCTAssertEqual(record.groupRaw, QxEqGroup.user.rawValue)
        XCTAssertEqual(record.bands.count, 10)
        XCTAssertEqual(record.preGain, -3, accuracy: 0.05)
        XCTAssertEqual(record.deviceIdentity, "usb:Qudelix 5K")

        let pushLink = deviceLink()
        let push = await run(["preset", "push", path], pushLink)
        XCTAssertEqual(push, CLIExit.ok)
        XCTAssertEqual(pushLink.payloads(for: .setEqBandParam).count, 10)
        XCTAssertEqual(pushLink.payload(for: .setEqType), [0, 1])
    }

    func testImportAppliesAParametricFile() async throws {
        let path = NSTemporaryDirectory() + "/qudelix-autoeq-" + UUID().uuidString + ".txt"
        try """
        Preamp: -6.1 dB
        Filter 1: ON LSC Fc 105 Hz Gain 6.4 dB Q 0.70
        Filter 2: ON PK Fc 8800 Hz Gain -5.1 dB Q 1.42
        """.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let link = deviceLink()
        let exit = await run(["import", path], link)
        XCTAssertEqual(exit, CLIExit.ok)
        XCTAssertEqual(link.payload(for: .setEqEnable), [0, 1])
        XCTAssertEqual(link.payloads(for: .setEqPreGain).count, 2)
        XCTAssertEqual(link.payloads(for: .setEqPreGain)[0],
                       [0, 1, 0] + QxPacket.int16BE(-61))
        let bandWrites = link.payloads(for: .setEqBandParam)
        XCTAssertEqual(bandWrites.count, 10)
        XCTAssertEqual(bandWrites[0][3], QxFilter.lowShelf.rawValue)
        XCTAssertEqual(Array(bandWrites[0][4...5]), QxPacket.int16BE(105))
        XCTAssertEqual(bandWrites[1][3], QxFilter.peak.rawValue)
        XCTAssertEqual(Array(bandWrites[1][4...5]), QxPacket.int16BE(8800))
        for write in bandWrites.dropFirst(2) {
            XCTAssertEqual(write[3], QxFilter.bypass.rawValue)
        }
    }

    func testImportOfANonPresetFileIsADeviceLevelFailureNotACrash() async throws {
        let path = NSTemporaryDirectory() + "/qudelix-junk-" + UUID().uuidString + ".txt"
        try "nothing here".write(to: URL(fileURLWithPath: path),
                                 atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let link = deviceLink()
        let exit = await run(["import", path], link)
        XCTAssertEqual(exit, CLIExit.deviceError)
        XCTAssertTrue(link.payloads(for: .setEqBandParam).isEmpty)
    }

    private func fakeTree(_ nodes: [(String, String)]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qudelix-probe-" + UUID().uuidString, isDirectory: true)
        let classRoot = root.appendingPathComponent("class/hidraw", isDirectory: true)
        try FileManager.default.createDirectory(at: classRoot, withIntermediateDirectories: true)
        for (name, uevent) in nodes {
            let device = classRoot.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("device", isDirectory: true)
            try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
            try uevent.write(to: device.appendingPathComponent("uevent"),
                             atomically: true, encoding: .utf8)
        }
        return root
    }

    private func environment(root: URL,
                             accessible: Bool = true,
                             tools: [String: String?] = [:]) -> ProbeEnvironment {
        var env = ProbeEnvironment.system()
        env.sysfsRoot = root
        env.devRoot = URL(fileURLWithPath: "/dev", isDirectory: true)
        env.logPath = "/tmp/qudelix.log"
        env.kernelRelease = { "5.15.0-generic" }
        env.access = { _ in (accessible, accessible) }
        env.runTool = { tool, _ in tools[tool] ?? nil }
        return env
    }

    func testProbeReadsAFakeSysfsTree() throws {
        let root = try fakeTree([
            ("hidraw0", "HID_ID=0003:00000A12:00004003\nHID_NAME=Qudelix-5K\nDEVTYPE=usb\n"),
            ("hidraw1", "HID_ID=0003:0000046D:0000C52B\nHID_NAME=Logitech Receiver\n"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let report = Probe.report(environment(root: root,
                                              tools: ["bluetoothctl": "bluetoothctl: 5.64\n",
                                                      "busctl": "NAME PID\norg.bluez 812\n"]))
        XCTAssertEqual(report.kernelRelease, "5.15.0-generic")
        XCTAssertTrue(report.hidrawClassExists)
        XCTAssertEqual(report.nodes.count, 2)
        XCTAssertEqual(report.nodes[0].name, "hidraw0")
        XCTAssertEqual(report.nodes[0].devicePath, "/dev/hidraw0")
        XCTAssertEqual(report.nodes[0].hidId, "0003:00000A12:00004003")
        XCTAssertEqual(report.nodes[0].hidName, "Qudelix-5K")
        XCTAssertTrue(report.nodes[0].isQudelix)
        XCTAssertFalse(report.nodes[1].isQudelix)
        XCTAssertEqual(report.bluetoothctlVersion, "bluetoothctl: 5.64")
        XCTAssertTrue(report.busctlPresent)
        XCTAssertEqual(report.bluezOnDBus, true)
        XCTAssertEqual(report.logPath, "/tmp/qudelix.log")

        let lines = Probe.lines(report)
        XCTAssertTrue(lines.contains { $0.contains("5.15.0-generic") })
        XCTAssertTrue(lines.contains { $0.contains("/dev/hidraw0") && $0.contains("Qudelix 5K") })
        XCTAssertTrue(lines.contains { $0.contains("read+write") })
        XCTAssertTrue(lines.contains { $0.contains("/tmp/qudelix.log") })
        XCTAssertNil(Probe.permissionAdvice(report))

        let object = Probe.object(report)
        XCTAssertEqual(object["kernel_release"] as? String, "5.15.0-generic")
        XCTAssertEqual((object["hidraw_nodes"] as? [[String: Any]])?.count, 2)
        XCTAssertFalse(QxFormat.json(object).isEmpty)
    }

    func testProbeReportsAMissingHidrawClass() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qudelix-probe-" + UUID().uuidString, isDirectory: true)
        let report = Probe.report(environment(root: root))
        XCTAssertFalse(report.hidrawClassExists)
        XCTAssertTrue(report.nodes.isEmpty)
        XCTAssertNil(report.bluetoothctlVersion)
        XCTAssertFalse(report.busctlPresent)
        XCTAssertNil(report.bluezOnDBus)
        XCTAssertTrue(Probe.lines(report).contains { $0.contains("busctl not installed") })
    }

    func testPermissionAdviceNamesTheUdevRuleAndReplugging() throws {
        let root = try fakeTree([
            ("hidraw0", "HID_ID=0003:00000A12:00004003\nHID_NAME=Qudelix-5K\n"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let report = Probe.report(environment(root: root, accessible: false))
        let advice = Probe.permissionAdvice(report)
        XCTAssertNotNil(advice)
        XCTAssertTrue(advice?.contains("70-qudelix.rules") ?? false)
        XCTAssertTrue(advice?.contains("replug") ?? false)
        XCTAssertTrue(advice?.contains("/dev/hidraw0") ?? false)
        XCTAssertTrue(Probe.lines(report).contains { $0.contains("no read") })
    }

    func testUeventParsingKeepsValuesWithEqualsSigns() {
        let fields = Probe.parseUevent("HID_NAME=A=B\nJUNK\n=nothing\nHID_ID=0003:1:2\n")
        XCTAssertEqual(fields["HID_NAME"], "A=B")
        XCTAssertEqual(fields["HID_ID"], "0003:1:2")
        XCTAssertNil(fields["JUNK"])
        XCTAssertEqual(fields.count, 2)
    }

    func testPresetPullFormatRoundTripsThroughTheMacAppsDecoder() throws {
        let bands = QxEqGroup.user.defaultFreqs.map {
            QxEqBandValue(filter: .peak, freq: $0, gain: 1.5, q: 1.2)
        }
        let record = EqSnapshot(groupRaw: QxEqGroup.user.rawValue,
                                bands: bands,
                                preGain: -4.5,
                                enabled: true,
                                name: "Slot 3",
                                mutedBands: [:],
                                deviceIdentity: "usb:Qudelix 5K")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        let path = NSTemporaryDirectory() + "/qudelix-eq-" + UUID().uuidString + ".json"
        try data.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let loaded = try QudelixCLI.loadSnapshotFile(path, group: .user)
        XCTAssertEqual(loaded.groupRaw, QxEqGroup.user.rawValue)
        XCTAssertEqual(loaded.preGain, -4.5)
        XCTAssertEqual(loaded.bands, bands)
        XCTAssertEqual(loaded.name, "Slot 3")
        XCTAssertEqual(loaded.deviceIdentity, "usb:Qudelix 5K")

        XCTAssertThrowsError(try QudelixCLI.loadSnapshotFile(path, group: .b20))
        XCTAssertThrowsError(try QudelixCLI.loadSnapshotFile(path + ".missing", group: .user))
    }

    func testUnreadableImportPathIsAnActionableError() {
        do {
            _ = try QudelixCLI.readText("/nonexistent/qudelix/autoeq.txt")
            XCTFail("reading a missing file should have thrown")
        } catch let error as CLIUsageError {
            XCTAssertTrue(error.message.contains("plain text file"))
        } catch {
            XCTFail("expected a CLIUsageError, got \(error)")
        }
    }

    func testStatusLinesAndObjectCoverEveryReportedField() {
        var snapshot = QxStatusSnapshot()
        snapshot.linkKind = .usb
        snapshot.deviceId = QxDeviceModel.qudelix5K
        snapshot.modelName = "Qudelix 5K"
        snapshot.firmware = "3.2.7"
        snapshot.batteryPercent = 77
        snapshot.charging = true
        snapshot.chargerConnected = true
        snapshot.volumeDb = -18.5
        snapshot.muted = false
        snapshot.dacFilterIndex = 5
        snapshot.dacFilterName = QxStatusParser.dacFilters[5]
        snapshot.eqEnabled = true
        snapshot.eqType = "PEQ"
        snapshot.eqGroup = .user
        snapshot.activePresetIndex = 4
        snapshot.activePresetName = "Harman"
        snapshot.sampleRate = "48 kHz"

        let text = QxFormat.statusLines(snapshot).joined(separator: "\n")
        for needle in ["Qudelix 5K", "3.2.7", "77%", "-18.5 dB", "off",
                       QxStatusParser.dacFilters[5], "user (10-band)", "5 — Harman",
                       "48 kHz"] {
            XCTAssertTrue(text.contains(needle), needle)
        }

        let object = QxFormat.statusObject(snapshot)
        XCTAssertEqual(object["model"] as? String, "Qudelix 5K")
        XCTAssertEqual(object["battery_percent"] as? Int, 77)
        XCTAssertEqual(object["eq_type"] as? String, "PEQ")
        XCTAssertEqual(object["preset_index"] as? Int, 4)
        XCTAssertNil(object["codec"])
        XCTAssertFalse(QxFormat.json(object).isEmpty)
    }

    func testEqLinesShowPreGainAndEveryBand() {
        let bands = QxEqGroup.user.defaultFreqs.map {
            QxEqBandValue(filter: .peak, freq: $0, gain: -1.5, q: 0.71)
        }
        let lines = QxFormat.eqLines(preGain: -3, bands: bands)
        XCTAssertTrue(lines[0].contains("-3.0 dB"))
        XCTAssertEqual(lines.count, 3 + bands.count)
        XCTAssertTrue(lines.last?.contains("16000 Hz") ?? false)
        XCTAssertTrue(lines.last?.contains("-1.5") ?? false)
        XCTAssertTrue(lines.last?.contains("0.71") ?? false)
    }

    func testPresetLinesFallBackToSlotNumbers() {
        let lines = QxFormat.presetLines([2: "Harman"], count: 4, active: 2)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].contains("Preset 1"))
        XCTAssertTrue(lines[2].contains("Harman"))
        XCTAssertTrue(lines[2].hasPrefix("* "))
        XCTAssertTrue(lines[0].hasPrefix("  "))
    }

    func testFilterLinesListEveryDacFilter() {
        XCTAssertEqual(QxFormat.filterLines().count, QxStatusParser.dacFilters.count)
        XCTAssertTrue(QxFormat.filterLines()[0].hasSuffix(QxStatusParser.dacFilters[0]))
        XCTAssertTrue(QxFormat.filterLines(current: 2)[2].hasPrefix("* "))
    }
}
