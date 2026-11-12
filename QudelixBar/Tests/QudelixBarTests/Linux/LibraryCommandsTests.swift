import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import QudelixBar

private struct CatalogueTransport: HTTPTransport {
    let entries: String
    let targets: String
    var equalize: String = ""

    func send(_ request: URLRequest, limit: Int) async throws -> Data {
        switch request.url?.path {
        case "/entries": return Data(entries.utf8)
        case "/targets": return Data(targets.utf8)
        case "/equalize": return Data(equalize.utf8)
        default: throw LibraryError(description: "unexpected request")
        }
    }
}

final class LibraryCommandsTests: XCTestCase {
    private var libraryFile = URL(fileURLWithPath: "/dev/null")
    private var searchFile = URL(fileURLWithPath: "/dev/null")

    override func setUp() {
        super.setUp()
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qudelix-library-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        libraryFile = root.appendingPathComponent("presets.json")
        searchFile = root.appendingPathComponent("autoeq-search.json")
        LibraryCommand.fileOverride = libraryFile
        LibraryCommand.searchFileOverride = searchFile
        EqHistoryFile.directoryOverride = root
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: libraryFile.deletingLastPathComponent())
        LibraryCommand.fileOverride = nil
        LibraryCommand.searchFileOverride = nil
        LibraryCommand.transportOverride = nil
        EqHistoryFile.directoryOverride = nil
        super.tearDown()
    }

    private func parse(_ line: String) throws -> CLICommand {
        try CLI.parse(line.split(separator: " ").map(String.init)).command
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

    private func run(_ arguments: [String], _ link: FakeLink? = nil) async -> Int32 {
        let links = link.map { [$0 as QxLink] } ?? []
        return await QudelixCLI.run(arguments: ["--timeout", "2"] + arguments,
                                    makeLinks: { _ in links })
    }

    private func deviceLink(bands: [QxEqBandValue] = QxFixtures.tenBands,
                            preGain: Double = -3) -> FakeLink {
        let link = QxFixtures.answeringLink(preGain: preGain, bands: bands)
        link.autoConnectOnStart = true
        return link
    }

    private func expect(_ code: Int32, _ arguments: [String], _ link: FakeLink? = nil,
                        file: StaticString = #filePath, line: UInt = #line) async {
        let exit = await run(arguments, link)
        XCTAssertEqual(exit, code, "\(arguments)", file: file, line: line)
    }

    private func write(_ presets: [LibraryPreset]) {
        PresetLibraryFile.save(PresetLibraryDocument(presets: presets), to: libraryFile)
    }

    private func stored() -> [LibraryPreset] {
        PresetLibraryFile.load(from: libraryFile)?.presets ?? []
    }

    private func preset(_ name: String, group: QxEqGroup = .user,
                        gain: Double = 1.5, source: String? = nil) -> LibraryPreset {
        LibraryPreset(name: name, scope: .global, group: group,
                      bands: group.defaultFreqs.map {
                          QxEqBandValue(filter: .peak, freq: $0, gain: gain, q: 1.2)
                      },
                      preGain: -2, sourceName: source)
    }

    func testEverySubcommandParses() throws {
        XCTAssertEqual(try parse("library list"), .library(.list))
        XCTAssertEqual(try parse("library show 2"), .library(.show("2")))
        XCTAssertEqual(try parse("library apply Bassy"), .library(.apply("Bassy")))
        XCTAssertEqual(try parse("library delete 3"), .library(.delete("3")))
        XCTAssertEqual(try parse("library remove 3"), .library(.delete("3")))
        XCTAssertEqual(try parse("library save Bassy"),
                       .library(.save(name: "Bassy", replacing: false)))
        XCTAssertEqual(try parse("library save replace Bassy"),
                       .library(.save(name: "Bassy", replacing: true)))
        XCTAssertEqual(try parse("library search HD 650"), .library(.search("HD 650")))
        XCTAssertEqual(try parse("library fetch 4"),
                       .library(.fetch(reference: "4", target: nil, saveAs: nil)))
        XCTAssertEqual(try parse("library fetch 4 target Harman save Mine"),
                       .library(.fetch(reference: "4", target: "Harman", saveAs: "Mine")))
    }

    func testTheDashedSpellingsWorkOnceFlagParsingHasEnded() throws {
        XCTAssertEqual(try CLI.parse(["--", "library", "save", "--replace", "Bassy"]).command,
                       .library(.save(name: "Bassy", replacing: true)))
        XCTAssertEqual(try CLI.parse(["--", "library", "fetch", "2",
                                      "--target", "Harman", "--save", "Mine"]).command,
                       .library(.fetch(reference: "2", target: "Harman", saveAs: "Mine")))
    }

    func testParseErrorsAreUsageErrors() {
        XCTAssertEqual(usageMessage(["library"]),
                       "library needs list, show, apply, save, delete, import, export, search or fetch")
        XCTAssertNotNil(usageMessage(["library", "sideways"]))
        XCTAssertNotNil(usageMessage(["library", "list", "now"]))
        XCTAssertNotNil(usageMessage(["library", "show"]))
        XCTAssertNotNil(usageMessage(["library", "show", "1", "2"]))
        XCTAssertNotNil(usageMessage(["library", "apply"]))
        XCTAssertNotNil(usageMessage(["library", "delete"]))
        XCTAssertNotNil(usageMessage(["library", "save"]))
        XCTAssertNotNil(usageMessage(["library", "save", "replace"]))
        XCTAssertNotNil(usageMessage(["library", "save", "a", "b"]))
        XCTAssertNotNil(usageMessage(["library", "search"]))
        XCTAssertNotNil(usageMessage(["library", "fetch"]))
        XCTAssertNotNil(usageMessage(["library", "search", "--bogus"]))
        XCTAssertNotNil(usageMessage(["library", "search", "HD", "-x"]))
        XCTAssertNotNil(usageMessage(["library", "fetch", "1", "target"]))
        XCTAssertNotNil(usageMessage(["library", "fetch", "1", "sideways", "x"]))
        XCTAssertNotNil(usageMessage(["library", "fetch", "1", "target", "a", "target", "b"]))
        XCTAssertNotNil(usageMessage(["library", "fetch", "1", "save", "a", "save", "b"]))
    }

    func testImportAndExportParse() throws {
        XCTAssertEqual(try parse("library import eq.txt"), .library(.importFile(path: "eq.txt", name: nil)))
        XCTAssertEqual(try CLI.parse(["library", "import", "eq.txt", "--name", "My EQ"]).command,
                       .library(.importFile(path: "eq.txt", name: "My EQ")))
        XCTAssertEqual(try CLI.parse(["library", "import", "--name", "My EQ", "eq.txt"]).command,
                       .library(.importFile(path: "eq.txt", name: "My EQ")))
        XCTAssertEqual(try parse("library export 2"), .library(.export(reference: "2", file: nil)))
        XCTAssertEqual(try parse("library export Bassy out.txt"),
                       .library(.export(reference: "Bassy", file: "out.txt")))
        XCTAssertNotNil(usageMessage(["library", "import"]))
        XCTAssertNotNil(usageMessage(["library", "import", "a.txt", "b.txt"]))
        XCTAssertNotNil(usageMessage(["library", "import", "a.txt", "--name"]))
        XCTAssertNotNil(usageMessage(["library", "import", "a.txt", "--name", "x", "--name", "y"]))
        XCTAssertNotNil(usageMessage(["library", "export"]))
        XCTAssertNotNil(usageMessage(["library", "export", "1", "a.txt", "b.txt"]))
        XCTAssertFalse(QudelixCLI.persistsToFlash(try parse("library import eq.txt")))
        XCTAssertFalse(QudelixCLI.persistsToFlash(try parse("library export 1")))
        XCTAssertTrue(CLI.needsDevice(try parse("library import eq.txt")))
        XCTAssertFalse(CLI.needsDevice(try parse("library export 1")))
        XCTAssertTrue(CLI.usageText.contains("library import <file>"))
        XCTAssertTrue(CLI.usageText.contains("library export <n|name>"))
    }

    private func captured(_ body: () async -> Void) async -> [String] {
        let capture = StdIOCapture()
        StdIO.outSink = { line in capture.append(line) }
        defer { StdIO.outSink = nil }
        await body()
        return capture.all
    }

    private func eqFile(_ name: String, _ text: String) -> String {
        let url = libraryFile.deletingLastPathComponent().appendingPathComponent(name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private let apoText = "Preamp: -3.0 dB\nFilter 1: ON PK Fc 100 Hz Gain 2.0 dB Q 1.00\n"
        + "Filter 2: ON LSC Fc 105 Hz Gain 4.0 dB Q 0.70\n"

    func testImportFilesTheTextUnderTheDeviceModeAndWritesNothingToTheDevice() async throws {
        let link = deviceLink()
        let path = eqFile("HD 650.txt", apoText)
        let lines = await captured { await expect(CLIExit.ok, ["library", "import", path], link) }
        let presets = stored()
        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(presets[0].name, "HD 650")
        XCTAssertEqual(presets[0].scope, .global)
        XCTAssertEqual(presets[0].group, .user)
        XCTAssertEqual(presets[0].preGain, -3, accuracy: 0.001)
        XCTAssertEqual(presets[0].bands.map(\.freq), [100, 105])
        XCTAssertTrue(lines.joined(separator: "\n").contains("nothing has been sent to the 5K"))
        XCTAssertTrue(link.sentCommands.allSatisfy { QxCompatibility.isRequest($0) })
        XCTAssertTrue(link.payloads(for: .saveAll).isEmpty)
    }

    func testImportTakesANameAndNeverOverwritesAnExistingOne() async throws {
        let path = eqFile("a.txt", apoText)
        await expect(CLIExit.ok, ["library", "import", path, "--name", "Mine"], deviceLink())
        await expect(CLIExit.ok, ["library", "import", "--name", "Mine", path], deviceLink())
        let names = stored().map(\.name)
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(names[0], "Mine")
        XCTAssertNotEqual(names[1], "Mine")
        XCTAssertTrue(names[1].hasPrefix("Mine"))
    }

    func testImportJsonNamesWhatWasAdded() async throws {
        let path = eqFile("b.txt", apoText)
        let lines = await captured {
            await expect(CLIExit.ok, ["library", "import", "--json", path], deviceLink())
        }
        let object = try JSONSerialization.jsonObject(with: Data(lines.joined().utf8)) as? [String: Any]
        XCTAssertEqual(object?["imported"] as? String, "b")
        XCTAssertEqual(object?["index"] as? Int, 1)
        XCTAssertEqual(object?["bands"] as? Int, 2)
    }

    func testImportRefusesWhatIsNotAnEqFileOrCannotBeRead() async throws {
        let junk = eqFile("junk.txt", "hello there\n")
        let junkExit = await run(["library", "import", junk], deviceLink())
        XCTAssertEqual(junkExit, CLIExit.deviceError)
        let missing = await run(["library", "import", junk + ".missing"], deviceLink())
        XCTAssertEqual(missing, CLIExit.usageError)
        XCTAssertTrue(stored().isEmpty)
    }

    func testImportLeavesAnUnreadableLibraryAlone() async throws {
        try? Data("{not json".utf8).write(to: libraryFile)
        let path = eqFile("c.txt", apoText)
        let exit = await run(["library", "import", path], deviceLink())
        XCTAssertNotEqual(exit, CLIExit.ok)
        XCTAssertEqual(try? Data(contentsOf: libraryFile), Data("{not json".utf8))
    }

    func testExportPrintsTheSameTextTheAppExportsOrWritesAFile() async throws {
        write([preset("Bassy", gain: 2.5), preset("Bright")])
        let expected = QudelixController.exportText(bands: preset("Bassy", gain: 2.5).bands, preGain: -2)
        let printed = await captured { await expect(CLIExit.ok, ["library", "export", "bassy"]) }
        XCTAssertEqual(printed.joined(separator: "\n") + "\n", expected)
        let target = libraryFile.deletingLastPathComponent().appendingPathComponent("out.txt").path
        await expect(CLIExit.ok, ["library", "export", "1", target])
        XCTAssertEqual(try? String(contentsOfFile: target, encoding: .utf8), expected)
        let json = await captured { await expect(CLIExit.ok, ["library", "export", "--json", "2"]) }
        let object = try JSONSerialization.jsonObject(with: Data(json.joined().utf8)) as? [String: Any]
        XCTAssertEqual(object?["name"] as? String, "Bright")
        await expect(CLIExit.usageError, ["library", "export", "9"])
        let unwritable = await run(["library", "export", "1", target + "/no/such/x.txt"])
        XCTAssertEqual(unwritable, CLIExit.deviceError)
    }

    func testExportedTextImportsBackThroughTheSameParser() async throws {
        write([preset("Round", gain: 3)])
        let target = libraryFile.deletingLastPathComponent().appendingPathComponent("round.txt").path
        await expect(CLIExit.ok, ["library", "export", "Round", target])
        await expect(CLIExit.ok, ["library", "import", target, "--name", "Back"], deviceLink())
        let presets = stored()
        XCTAssertEqual(presets.count, 2)
        XCTAssertEqual(presets[0].bands.map(\.freq), presets[1].bands.map(\.freq))
        XCTAssertEqual(presets[0].bands.map(\.gain), presets[1].bands.map(\.gain))
    }

    func testSearchRefusesAFlagRatherThanLookingForItsText() {
        XCTAssertEqual(usageMessage(["library", "search", "--bogus"]),
                       "library search takes words to look for, "
                           + "and takes no flags — not --bogus")
        XCTAssertEqual(try? parse("library search HD 650"), .library(.search("HD 650")))
    }

    func testWhichSubcommandsNeedTheDeviceAndWhichPersist() throws {
        for line in ["library list", "library show 1", "library delete 1",
                     "library search HD"] {
            XCTAssertFalse(CLI.needsDevice(try parse(line)), line)
            XCTAssertFalse(QudelixCLI.persistsToFlash(try parse(line)), line)
        }
        for line in ["library apply 1", "library save Bassy", "library fetch 1"] {
            XCTAssertTrue(CLI.needsDevice(try parse(line)), line)
        }
        XCTAssertFalse(QudelixCLI.persistsToFlash(try parse("library save Bassy")))
        XCTAssertTrue(QudelixCLI.persistsToFlash(try parse("library apply 1")))
        XCTAssertTrue(QudelixCLI.persistsToFlash(try parse("library fetch 1")))
    }

    func testUsageLinesLineUpWithTheOnesAlreadyInTheHelp() {
        XCTAssertEqual(LibraryCommand.usageLines.count, 9)
        for line in LibraryCommand.usageLines {
            XCTAssertTrue(line.hasPrefix("  library "), line)
            XCTAssertFalse(line.hasPrefix("   "), line)
            let description = line.dropFirst(28)
            XCTAssertFalse(description.isEmpty, line)
            XCTAssertFalse(description.hasPrefix(" "), line)
        }
        XCTAssertTrue(CLI.usageText.contains("library search <query>"))
    }

    func testResolutionTakesAnIndexAnExactNameOrAUniquePrefix() throws {
        let presets = [preset("Bassy"), preset("Bright"), preset("Bass Lift")]
        XCTAssertEqual(try LibraryCommand.resolve("1", in: presets), 0)
        XCTAssertEqual(try LibraryCommand.resolve("3", in: presets), 2)
        XCTAssertEqual(try LibraryCommand.resolve("bassy", in: presets), 0)
        XCTAssertEqual(try LibraryCommand.resolve("BASSY", in: presets), 0)
        XCTAssertEqual(try LibraryCommand.resolve("bri", in: presets), 1)
        XCTAssertEqual(try LibraryCommand.resolve("Bass L", in: presets), 2)
    }

    func testAnAmbiguousPrefixListsTheMatches() {
        let presets = [preset("Bassy"), preset("Bass Lift")]
        do {
            _ = try LibraryCommand.resolve("bass", in: presets)
            XCTFail("an ambiguous prefix should not resolve")
        } catch let error as CLIUsageError {
            XCTAssertTrue(error.message.contains("matches 2 saved presets"), error.message)
            XCTAssertTrue(error.message.contains("1 Bassy"), error.message)
            XCTAssertTrue(error.message.contains("2 Bass Lift"), error.message)
        } catch {
            XCTFail("expected a CLIUsageError, got \(error)")
        }
    }

    func testAnExactNameWinsOverALongerPrefixMatch() throws {
        let presets = [preset("Bass Lift"), preset("Bass")]
        XCTAssertEqual(try LibraryCommand.resolve("Bass", in: presets), 1)
    }

    func testOutOfRangeAndMissingNamesAreUsageErrors() {
        let presets = [preset("Bassy")]
        XCTAssertThrowsError(try LibraryCommand.resolve("0", in: presets))
        XCTAssertThrowsError(try LibraryCommand.resolve("2", in: presets))
        XCTAssertThrowsError(try LibraryCommand.resolve("Sparkle", in: presets))
        XCTAssertThrowsError(try LibraryCommand.resolve("1", in: []))
    }

    func testAnEmptyLibraryListsCleanly() async {
        await expect(CLIExit.ok, ["library", "list"])
        await expect(CLIExit.ok, ["library", "list", "--json"])
        let empty = LibraryCommand.jsonArray([])
        XCTAssertTrue(empty.hasPrefix("["))
        XCTAssertTrue(empty.hasSuffix("]"))
        XCTAssertEqual(((try? JSONSerialization.jsonObject(
            with: Data(empty.utf8))) as? [Any])?.count, 0)
    }

    func testListLinesCarryIndexNameBandsScopeAndSource() {
        let presets = [preset("Bassy", source: "AutoEq: HD 650"),
                       LibraryPreset(name: "Desk", scope: .output(uid: "u1", name: "Speakers"),
                                     group: .b20,
                                     bands: QxEqGroup.b20.defaultFreqs.map {
                                         QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1)
                                     },
                                     preGain: 0)]
        let lines = LibraryCommand.listLines(presets)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("#"))
        XCTAssertTrue(lines[1].hasPrefix("1  Bassy"))
        XCTAssertTrue(lines[1].contains("10-band"))
        XCTAssertTrue(lines[1].contains("Every output"))
        XCTAssertTrue(lines[1].hasSuffix("AutoEq: HD 650"))
        XCTAssertTrue(lines[2].hasPrefix("2  Desk"))
        XCTAssertTrue(lines[2].contains("20-band"))
        XCTAssertTrue(lines[2].hasSuffix("Speakers"))
        for line in lines { XCTAssertFalse(line.hasSuffix(" "), line) }
    }

    func testListObjectNamesEveryColumn() {
        let object = LibraryCommand.listObject(2, preset("Bassy", source: "HD 650"))
        XCTAssertEqual(object["index"] as? Int, 3)
        XCTAssertEqual(object["name"] as? String, "Bassy")
        XCTAssertEqual(object["bands"] as? Int, 10)
        XCTAssertEqual(object["band_label"] as? String, "10-band")
        XCTAssertEqual(object["scope"] as? String, "Every output")
        XCTAssertEqual(object["global"] as? Bool, true)
        XCTAssertEqual(object["source"] as? String, "HD 650")
        XCTAssertNil(object["output_uid"])
        XCTAssertTrue(LibraryCommand.jsonArray([object]).hasPrefix("["))
    }

    func testListAndShowNeedNoDevice() async {
        write([preset("Bassy"), preset("Bright")])
        await expect(CLIExit.ok, ["library", "list"])
        await expect(CLIExit.ok, ["library", "list", "--json"])
        await expect(CLIExit.ok, ["library", "show", "2"])
        await expect(CLIExit.ok, ["library", "show", "bassy"])
        await expect(CLIExit.ok, ["library", "show", "--json", "1"])
        await expect(CLIExit.usageError, ["library", "show", "9"])
        await expect(CLIExit.usageError, ["library", "show", "nothing"])
    }

    func testSaveKeepsTheLiveCurve() async throws {
        let link = deviceLink(preGain: -4.5)
        await expect(CLIExit.ok, ["library", "save", "Bassy"], link)
        let presets = stored()
        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(presets[0].name, "Bassy")
        XCTAssertEqual(presets[0].scope, .global)
        XCTAssertEqual(presets[0].group, .user)
        XCTAssertEqual(presets[0].bands.count, 10)
        XCTAssertEqual(presets[0].preGain, -4.5, accuracy: 0.05)
        XCTAssertTrue(link.payloads(for: .setEqBandParam).isEmpty)
        XCTAssertTrue(link.payloads(for: .saveAll).isEmpty)
    }

    func testSaveRefusesADuplicateNameUntilReplaceIsAsked() async throws {
        await expect(CLIExit.ok, ["library", "save", "Bassy"], deviceLink())
        let again = await run(["library", "save", "bassy"], deviceLink())
        XCTAssertEqual(again, CLIExit.usageError)
        XCTAssertEqual(stored().count, 1)

        let firstID = stored()[0].id
        let replaced = await run(["library", "save", "replace", "Bassy"],
                                 deviceLink(preGain: -8))
        XCTAssertEqual(replaced, CLIExit.ok)
        XCTAssertEqual(stored().count, 1)
        XCTAssertEqual(stored()[0].id, firstID)
        XCTAssertEqual(stored()[0].preGain, -8, accuracy: 0.05)
    }

    func testSaveScrubsTheNameAndRefusesOneWithNothingInIt() throws {
        var document = PresetLibraryDocument()
        let stored = try LibraryCommand.store(preset("  Bassy\u{202E}  "), replacing: false,
                                              in: &document)
        XCTAssertEqual(stored.name, "Bassy")
        XCTAssertEqual(stored.index, 0)
        XCTAssertEqual(document.presets.count, 1)
        XCTAssertThrowsError(try LibraryCommand.store(preset("\n\t "), replacing: false,
                                                      in: &document))
        XCTAssertThrowsError(try LibraryCommand.store(preset(String(repeating: "\u{202E}", count: 4)),
                                                      replacing: false, in: &document))
    }

    func testSaveStopsAtTheLibraryCeiling() throws {
        var document = PresetLibraryDocument(
            presets: (0..<PresetLibraryFile.maxPresets).map { preset("Preset \($0)") })
        XCTAssertThrowsError(try LibraryCommand.store(preset("One more"), replacing: false,
                                                      in: &document))
        XCTAssertEqual(document.presets.count, PresetLibraryFile.maxPresets)
        let replaced = try LibraryCommand.store(preset("Preset 7"), replacing: true,
                                                in: &document)
        XCTAssertEqual(replaced.index, 7)
        XCTAssertEqual(document.presets.count, PresetLibraryFile.maxPresets)
    }

    func testALongNameIsCutToTheStoredLimit() throws {
        var document = PresetLibraryDocument()
        let long = String(repeating: "a", count: PresetLibraryFile.maxNameLength + 40)
        let stored = try LibraryCommand.store(preset(long), replacing: false, in: &document)
        XCTAssertEqual(stored.name.count, PresetLibraryFile.maxNameLength)
    }

    func testApplyWritesTheSavedCurveAndPersistsIt() async throws {
        write([preset("Bassy", gain: 2.5)])
        let link = deviceLink()
        await expect(CLIExit.ok, ["library", "apply", "Bassy"], link)
        XCTAssertEqual(link.payloads(for: .setEqBandParam).count, 10)
        XCTAssertEqual(link.payload(for: .setEqType), [0, 1])
        XCTAssertEqual(link.payloads(for: .setEqPreGain).count, 2)
        XCTAssertEqual(link.payloads(for: .setEqPreGain)[0], [0, 1, 0] + QxPacket.int16BE(-20))
        XCTAssertEqual(link.payloads(for: .saveAll).count, 1)
        for command in link.sentCommands {
            XCTAssertTrue(QxSession.allowed.contains(command), "\(command)")
        }
    }

    func testApplyRecordsTheSavedNameInTheHistory() async throws {
        write([preset("Bassy", gain: 2.5)])
        await expect(CLIExit.ok, ["library", "apply", "Bassy"], deviceLink())
        XCTAssertEqual(EqHistoryFile.load().entries.map(\.label), ["library Bassy"])
    }

    func testFetchRecordsTheMeasurementTitleInTheHistory() async throws {
        useFakeCatalogue()
        await expect(CLIExit.ok, ["library", "fetch", "Sennheiser HD 600"], deviceLink())
        XCTAssertEqual(EqHistoryFile.load().entries.map(\.label),
                       ["fetch Sennheiser HD 600"])
    }

    func testApplyByIndexAndAsJson() async throws {
        write([preset("Bassy"), preset("Bright")])
        await expect(CLIExit.ok, ["library", "apply", "2"], deviceLink())
        await expect(CLIExit.ok, ["library", "apply", "--json", "1"], deviceLink())
    }

    func testApplyRefusesACurveMadeForTheOtherBank() async throws {
        write([preset("Wide", group: .b20)])
        let link = deviceLink()
        await expect(CLIExit.usageError, ["library", "apply", "Wide"], link)
        XCTAssertTrue(link.payloads(for: .setEqBandParam).isEmpty)
        XCTAssertTrue(link.payloads(for: .saveAll).isEmpty)
    }

    func testApplyOfAMissingPresetTouchesNothing() async throws {
        write([preset("Bassy")])
        let link = deviceLink()
        await expect(CLIExit.usageError, ["library", "apply", "Sparkle"], link)
        XCTAssertTrue(link.payloads(for: .setEqBandParam).isEmpty)
    }

    func testDeleteByNameAndByIndex() async throws {
        write([preset("Bassy"), preset("Bright"), preset("Warm")])
        await expect(CLIExit.ok, ["library", "delete", "Bright"])
        XCTAssertEqual(stored().map(\.name), ["Bassy", "Warm"])
        await expect(CLIExit.ok, ["library", "delete", "2"])
        XCTAssertEqual(stored().map(\.name), ["Bassy"])
        await expect(CLIExit.ok, ["library", "delete", "--json", "1"])
        XCTAssertTrue(stored().isEmpty)
        await expect(CLIExit.usageError, ["library", "delete", "1"])
    }

    func testAFileThisToolDidNotWriteIsRefusedRatherThanOverwritten() async throws {
        try Data("not json at all".utf8).write(to: libraryFile)
        await expect(CLIExit.deviceError, ["library", "list"])
        await expect(CLIExit.deviceError, ["library", "save", "Bassy"], deviceLink())
        let parked = libraryFile.deletingLastPathComponent()
            .appendingPathComponent(libraryFile.lastPathComponent + ".recovered")
        XCTAssertTrue(FileManager.default.fileExists(atPath: parked.path))
    }

    func testAnUnwritablePathIsReportedRatherThanIgnored() throws {
        LibraryCommand.fileOverride = URL(fileURLWithPath: "/nope/qudelix/presets.json")
        XCTAssertThrowsError(try LibraryCommand.persist(
            PresetLibraryDocument(presets: [preset("Bassy")])))
        LibraryCommand.fileOverride = libraryFile
    }

    func testSaveAndLoadRoundTripThroughTheMacAppsOwnFileFormat() throws {
        let one = preset("Bassy", source: "AutoEq: HD 650")
        write([one])
        let loaded = try LibraryCommand.document().presets
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Bassy")
        XCTAssertEqual(loaded[0].sourceName, "AutoEq: HD 650")
        XCTAssertEqual(loaded[0].bands, one.bands)
        XCTAssertEqual(loaded[0].preGain, one.preGain)
        XCTAssertEqual(loaded[0].scope, .global)
    }

    private static let entriesJSON = """
    {
      "Sennheiser HD 650": [
        {"form": "over-ear", "rig": "GRAS 43AG", "source": "oratory1990"},
        {"form": "over-ear", "rig": "711", "source": "crinacle"}
      ],
      "Sennheiser HD 600": [
        {"form": "over-ear", "rig": "GRAS 43AG", "source": "oratory1990"}
      ],
      "Moondrop Aria": [
        {"form": "in-ear", "rig": "711", "source": "crinacle"}
      ]
    }
    """

    private static let targetsJSON = """
    [
      {"label": "Harman over-ear 2018",
       "recommended": [{"source": "oratory1990", "form": "over-ear"}],
       "compatible": []}
    ]
    """

    private static let equalizeJSON = """
    {
      "parametric_eq": {
        "preamp": -3.2,
        "filters": [
          {"type": "LOW_SHELF", "fc": 105, "q": 0.7, "gain": 4.5},
          {"type": "PEAKING", "fc": 1200, "q": 1.1, "gain": -2.5},
          {"type": "HIGH_SHELF", "fc": 9000, "q": 0.7, "gain": 1.5}
        ]
      }
    }
    """

    private func useFakeCatalogue() {
        LibraryCommand.transportOverride = CatalogueTransport(entries: Self.entriesJSON,
                                                              targets: Self.targetsJSON,
                                                              equalize: Self.equalizeJSON)
    }

    func testSearchRanksTheFakeCatalogueAndRemembersTheResults() async throws {
        useFakeCatalogue()
        let found = try await LibraryCommand.catalogueMatches("HD 6", budget: 5)
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(Set(found.map(\.title)), ["Sennheiser HD 650", "Sennheiser HD 600"])
        XCTAssertTrue(found.contains { $0.source == "oratory1990" && $0.rig == "GRAS 43AG" })

        LibraryCommand.remember(query: "HD 6", found)
        let remembered = LibraryCommand.rememberedSearch()
        XCTAssertEqual(remembered, found)

        let picked = try await LibraryCommand.candidate(for: "2", budget: 5)
        XCTAssertEqual(picked, found[1])
    }

    func testSearchPrintsAnIndexedRowPerMeasurement() async throws {
        useFakeCatalogue()
        let found = try await LibraryCommand.catalogueMatches("Sennheiser HD 650", budget: 5)
        let lines = LibraryCommand.searchLines(found)
        XCTAssertEqual(lines.count, found.count)
        XCTAssertTrue(lines[0].hasPrefix("1  Sennheiser HD 650"))
        XCTAssertTrue(lines.contains { $0.contains("oratory1990 · GRAS 43AG") })
        XCTAssertTrue(lines.contains { $0.hasSuffix("over-ear") })
        for line in lines { XCTAssertFalse(line.hasSuffix(" "), line) }

        let object = LibraryCommand.searchObject(0, found[0])
        XCTAssertEqual(object["index"] as? Int, 1)
        XCTAssertEqual(object["title"] as? String, "Sennheiser HD 650")
        XCTAssertEqual(object["form"] as? String, "over-ear")
    }

    func testSearchNeverReturnsMoreThanTheDisplayLimit() async throws {
        var models: [String: [[String: String]]] = [:]
        for index in 0..<40 {
            models["Model \(index)"] = [["form": "over-ear", "rig": "711",
                                         "source": "crinacle"]]
        }
        let data = try JSONSerialization.data(withJSONObject: models)
        LibraryCommand.transportOverride = CatalogueTransport(
            entries: String(data: data, encoding: .utf8) ?? "{}",
            targets: Self.targetsJSON)
        let found = try await LibraryCommand.catalogueMatches("Model", budget: 5)
        XCTAssertEqual(found.count, LibraryCommand.searchLimit)
        LibraryCommand.remember(query: "Model", found)
        XCTAssertEqual(LibraryCommand.rememberedSearch().count, LibraryCommand.searchLimit)
    }

    func testAFailedCatalogueIsADeviceErrorNotAUsageError() async throws {
        LibraryCommand.transportOverride = CatalogueTransport(entries: "[]", targets: "[]")
        do {
            _ = try await LibraryCommand.catalogueMatches("HD 6", budget: 5)
            XCTFail("a catalogue that does not parse should throw")
        } catch is CLIUsageError {
            XCTFail("a network failure is not a usage error")
        } catch {
            XCTAssertFalse(QudelixCLI.describe(error).isEmpty)
        }
        await expect(CLIExit.deviceError, ["library", "search", "HD650"])
    }

    func testFetchByNumberNeedsARememberedSearch() async {
        do {
            _ = try await LibraryCommand.candidate(for: "1", budget: 5)
            XCTFail("there is nothing remembered to index into")
        } catch let error as CLIUsageError {
            XCTAssertTrue(error.message.contains("library search"), error.message)
        } catch {
            XCTFail("expected a CLIUsageError, got \(error)")
        }
    }

    func testFetchByNumberRejectsAnIndexOutsideTheRememberedList() async throws {
        let one = LibraryCommand.RememberedCandidate(title: "Sennheiser HD 650",
                                                     source: "oratory1990",
                                                     form: "over-ear", rig: "GRAS 43AG",
                                                     token: "")
        LibraryCommand.remember(query: "HD 650", [one])
        let first = try await LibraryCommand.candidate(for: "1", budget: 5)
        XCTAssertEqual(first, one)
        await XCTAssertThrowsErrorAsync {
            _ = try await LibraryCommand.candidate(for: "2", budget: 5)
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await LibraryCommand.candidate(for: "0", budget: 5)
        }
    }

    func testFetchByNameNeedsAUniqueMeasurement() async throws {
        useFakeCatalogue()
        let one = try await LibraryCommand.candidate(for: "Moondrop Aria", budget: 5)
        XCTAssertEqual(one.title, "Moondrop Aria")
        XCTAssertEqual(one.source, "crinacle")

        do {
            _ = try await LibraryCommand.candidate(for: "Sennheiser HD 650", budget: 5)
            XCTFail("two rigs are two different curves")
        } catch let error as CLIUsageError {
            XCTAssertTrue(error.message.contains("matches 2 measurements"), error.message)
            XCTAssertTrue(error.message.contains("oratory1990"), error.message)
        } catch {
            XCTFail("expected a CLIUsageError, got \(error)")
        }

        do {
            _ = try await LibraryCommand.candidate(for: "Nothing At All", budget: 5)
            XCTFail("an unknown headphone should not resolve")
        } catch let error as CLIUsageError {
            XCTAssertTrue(error.message.contains("no headphone matches"), error.message)
        } catch {
            XCTFail("expected a CLIUsageError, got \(error)")
        }
    }

    func testARememberedRowWithAnAbsurdStringIsDropped() throws {
        let bad = LibraryCommand.RememberedCandidate(
            title: String(repeating: "a", count: AutoEqService.maxCatalogueStringLength + 1),
            source: "oratory1990", form: nil, rig: nil, token: "")
        let good = LibraryCommand.RememberedCandidate(title: "HD 650", source: "oratory1990",
                                                      form: nil, rig: nil, token: "")
        XCTAssertFalse(bad.admissible)
        XCTAssertTrue(good.admissible)
        LibraryCommand.remember(query: "x", [bad, good])
        XCTAssertEqual(LibraryCommand.rememberedSearch(), [good])
    }

    func testARememberedFileThatIsNotOursIsIgnored() throws {
        try Data("{".utf8).write(to: searchFile)
        XCTAssertTrue(LibraryCommand.rememberedSearch().isEmpty)
    }

    func testEveryLibraryCommandThatNeedsNoDeviceExitsZeroOnAFreshMachine() async {
        for arguments in [["library", "list"], ["library", "list", "--json"]] {
            await expect(CLIExit.ok, arguments)
        }
        for arguments in [["library", "show", "1"], ["library", "delete", "1"]] {
            await expect(CLIExit.usageError, arguments)
        }
    }

    func testADeviceCommandWithNoTransportSaysSo() async {
        write([preset("Bassy")])
        await expect(CLIExit.noTransport, ["library", "apply", "1"])
        await expect(CLIExit.noTransport, ["library", "save", "Bright"])
    }
}

private func XCTAssertThrowsErrorAsync(_ body: () async throws -> Void,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) async {
    do {
        try await body()
        XCTFail("expected an error", file: file, line: line)
    } catch {
    }
}
