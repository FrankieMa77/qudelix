import XCTest
@testable import QudelixBar

final class PresetLibraryTests: XCTestCase {

    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("preset-library-test-\(UUID().uuidString).json")
    }

    private func bands(_ count: Int, gain: Double = 3) -> [QxEqBandValue] {
        (0..<count).map { i in
            QxEqBandValue(filter: .peak, freq: 100 * (i + 1), gain: gain, q: 1.0)
        }
    }

    private func preset(_ name: String, scope: LibraryScope = .global,
                        group: QxEqGroup = .user, bandCount: Int = 10,
                        preGain: Double = -3) -> LibraryPreset {
        LibraryPreset(name: name, scope: scope, group: group,
                      bands: bands(bandCount), preGain: preGain)
    }

    @MainActor
    private func library(at url: URL,
                         group: QxEqGroup? = .user,
                         curve: [QxEqBandValue]? = nil,
                         preGain: Double = -4,
                         sourceName: String? = nil,
                         applies: Bool = true) -> (PresetLibrary, () -> [LibraryPreset]) {
        let library = PresetLibrary()
        var applied: [LibraryPreset] = []
        library.currentCurve = {
            guard let group else { return nil }
            return PresetLibrary.LiveCurve(bands: curve ?? self.bands(group.bandCount),
                                           preGain: preGain, group: group,
                                           sourceName: sourceName)
        }
        library.onApply = { preset in
            guard applies else { return false }
            applied.append(preset)
            return true
        }
        library.start(fileURL: url)
        return (library, { applied })
    }


    func testADocumentSurvivesTheRoundTripThroughDisk() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let saved = PresetLibraryDocument(
            headphoneName: "Alder AR-5",
            presets: [preset("Harman"),
                      preset("Late night",
                             scope: .output(uid: "uid-1", name: "Qudelix-5K"),
                             group: .b20, bandCount: 20)])

        PresetLibraryFile.save(saved, to: url)
        let loaded = PresetLibraryFile.load(from: url)

        XCTAssertEqual(loaded?.headphoneName, "Alder AR-5")
        XCTAssertEqual(loaded?.presets.count, 2)
        XCTAssertEqual(loaded?.presets.first?.name, "Harman")
        XCTAssertEqual(loaded?.presets.first?.scope, .global)
        XCTAssertEqual(loaded?.presets.first?.group, .user)
        XCTAssertEqual(loaded?.presets.first?.bands.count, 10)
        XCTAssertEqual(loaded?.presets.last?.scope,
                       .output(uid: "uid-1", name: "Qudelix-5K"))
        XCTAssertEqual(loaded?.presets.last?.group, .b20)
        XCTAssertEqual(loaded?.presets.last?.bands.count, 20)
        XCTAssertEqual(loaded?.presets.last?.preGain, -3)
        XCTAssertEqual(loaded?.presets.first?.id, saved.presets.first?.id)
    }

    func testTheFileIsWrittenAtOwnerOnlyPermissions() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        PresetLibraryFile.save(PresetLibraryDocument(presets: [preset("One")]), to: url)

        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        XCTAssertEqual(mode as? NSNumber, 0o600)
    }

    func testAnAbsentFileLoadsAsAnEmptyLibraryRatherThanAFailure() {
        let loaded = PresetLibraryFile.load(from: tempFileURL())
        XCTAssertEqual(loaded, PresetLibraryDocument())
    }


    func testABareArrayOfPresetsStillLoads() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        [{"id":"\(UUID().uuidString)","name":"Old shape","groupRaw":0,"preGain":-2.0,
          "bands":[{"filter":5,"freq":1000,"gain":2.5,"q":1.0}]}]
        """
        try? Data(json.utf8).write(to: url)

        let loaded = PresetLibraryFile.load(from: url)

        XCTAssertEqual(loaded?.presets.count, 1)
        XCTAssertEqual(loaded?.presets.first?.name, "Old shape")
        XCTAssertEqual(loaded?.presets.first?.group, .user)
        XCTAssertEqual(loaded?.headphoneName, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".recovered"))
    }

    func testOneUnreadableRecordDoesNotCostTheRestOfTheLibrary() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        {"schemaVersion":1,"headphoneName":"HD 650","presets":[
          {"name":"No group named here","preGain":0,
           "bands":[{"filter":5,"freq":1000,"gain":1,"q":1}]},
          {"name":"Group that does not exist","groupRaw":9,"preGain":0,
           "bands":[{"filter":5,"freq":1000,"gain":1,"q":1}]},
          {"name":"Good","groupRaw":2,"preGain":-1.5,
           "bands":[{"filter":5,"freq":1000,"gain":1,"q":1}]}]}
        """
        try? Data(json.utf8).write(to: url)

        let loaded = PresetLibraryFile.load(from: url)

        XCTAssertEqual(loaded?.presets.map(\.name), ["Good"])
        XCTAssertEqual(loaded?.headphoneName, "HD 650")
    }

    func testAnUnknownFilterShapeDoesNotCostTheWholeFile() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        {"presets":[{"name":"Odd","groupRaw":0,"preGain":0,
          "bands":[{"filter":99,"freq":1000,"gain":1,"q":1}]}]}
        """
        try? Data(json.utf8).write(to: url)

        let loaded = PresetLibraryFile.load(from: url)

        XCTAssertEqual(loaded?.presets.count, 1)
        XCTAssertEqual(loaded?.presets.first?.bands.first?.filter, .bypass)
    }


    func testAnUndecodableFileIsParkedAndReportedAsUnreadable() {
        let url = tempFileURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ".recovered"))
        }
        try? Data("this is not JSON at all".utf8).write(to: url)

        XCTAssertNil(PresetLibraryFile.load(from: url))
        XCTAssertEqual(try? String(contentsOf: URL(fileURLWithPath: url.path + ".recovered"),
                                   encoding: .utf8),
                       "this is not JSON at all")
    }

    @MainActor
    func testAFileThatFailedToReadIsNeverWrittenOver() {
        let url = tempFileURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ".recovered"))
        }
        try? Data("{ not json".utf8).write(to: url)

        let (library, _) = self.library(at: url)
        library.saveCurrent(name: "Something new", scope: .global)

        XCTAssertEqual(library.presets.count, 1)
        XCTAssertEqual(try? String(contentsOf: url, encoding: .utf8), "{ not json")
    }


    func testThePresetCountIsCapped() {
        let many = (0..<(PresetLibraryFile.maxPresets + 40)).map { preset("Preset \($0)") }
        let out = PresetLibraryFile.sanitize(PresetLibraryDocument(presets: many))
        XCTAssertEqual(out.presets.count, PresetLibraryFile.maxPresets)
    }

    func testNamesAreScrubbedAndCapped() {
        let hostile = "Bass\u{202E}boost\n" + String(repeating: "x", count: 200)
        let out = PresetLibraryFile.sanitize(
            PresetLibraryDocument(headphoneName: hostile, presets: [preset(hostile)]))

        let name = out.presets.first?.name ?? ""
        XCTAssertFalse(name.unicodeScalars.contains { $0.value == 0x202E })
        XCTAssertFalse(name.contains("\n"))
        XCTAssertLessThanOrEqual(name.count, PresetLibraryFile.maxNameLength)
        XCTAssertLessThanOrEqual(out.headphoneName.count, PresetLibraryFile.maxNameLength)
    }

    func testBandsAreCappedToTheBankTheyWereMadeFor() {
        let tooMany = LibraryPreset(name: "Wide", group: .user,
                                    bands: bands(40), preGain: 0)
        let out = PresetLibraryFile.sanitize(PresetLibraryDocument(presets: [tooMany]))
        XCTAssertEqual(out.presets.first?.bands.count, 10)

        let twenty = LibraryPreset(name: "Wide", group: .b20,
                                   bands: bands(40), preGain: 0)
        let outB20 = PresetLibraryFile.sanitize(PresetLibraryDocument(presets: [twenty]))
        XCTAssertEqual(outB20.presets.first?.bands.count, 20)
        XCTAssertLessThanOrEqual(outB20.presets.first?.bands.count ?? 0, QxEq.maxBandCount)
    }

    func testEveryBandAndThePreGainAreClampedToWhatTheDeviceAccepts() {
        let wild = LibraryPreset(
            name: "Wild", group: .user,
            bands: [QxEqBandValue(filter: .peak, freq: 99_000, gain: 400, q: 90),
                    QxEqBandValue(filter: .peak, freq: 1, gain: -400, q: 0.0001),
                    QxEqBandValue(filter: .peak, freq: 1000, gain: .nan, q: .infinity)],
            preGain: 99)

        let out = PresetLibraryFile.sanitize(PresetLibraryDocument(presets: [wild]))
        let got = out.presets.first

        XCTAssertEqual(got?.preGain, 12)
        XCTAssertEqual(got?.bands[0].freq, 20000)
        XCTAssertEqual(got?.bands[0].gain, 12)
        XCTAssertEqual(got?.bands[0].q, 10)
        XCTAssertEqual(got?.bands[1].freq, 20)
        XCTAssertEqual(got?.bands[1].gain, -12)
        XCTAssertEqual(got?.bands[1].q, 0.1)
        XCTAssertEqual(got?.bands[2].gain, 0)
        XCTAssertEqual(got?.bands[2].q, 1.0)
    }

    func testAPresetWithNoBandsIsDroppedRatherThanFlatteningTheCurve() {
        let empty = LibraryPreset(name: "Nothing", group: .user, bands: [], preGain: 0)
        let out = PresetLibraryFile.sanitize(PresetLibraryDocument(presets: [empty]))
        XCTAssertTrue(out.presets.isEmpty)
    }

    func testAnOutputScopeWithNoUsableUIDFallsBackToEveryOutput() {
        let orphan = LibraryPreset(name: "Orphan", scope: .output(uid: "", name: "Gone"),
                                   group: .user, bands: bands(4), preGain: 0)
        let huge = LibraryPreset(
            name: "Huge",
            scope: .output(uid: String(repeating: "u", count: 900), name: "Long"),
            group: .user, bands: bands(4), preGain: 0)

        let out = PresetLibraryFile.sanitize(PresetLibraryDocument(presets: [orphan, huge]))

        XCTAssertEqual(out.presets[0].scope, .global)
        XCTAssertEqual(out.presets[1].scope, .global)
    }

    func testTwoRecordsSharingAnIdentifierAreSeparatedOnLoad() {
        let id = UUID()
        var first = preset("First"); first.id = id
        var second = preset("Second"); second.id = id

        let out = PresetLibraryFile.sanitize(PresetLibraryDocument(presets: [first, second]))

        XCTAssertEqual(out.presets.count, 2)
        XCTAssertNotEqual(out.presets[0].id, out.presets[1].id)
    }


    @MainActor
    func testVisiblePresetsAreTheGlobalOnesPlusThisOutputs() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        library.saveCurrent(name: "Everywhere", scope: .global)
        library.saveCurrent(name: "Mine", scope: .output(uid: "uid-1", name: "Cans"))
        library.saveCurrent(name: "Theirs", scope: .output(uid: "uid-2", name: "Speakers"))

        XCTAssertEqual(library.visible(for: "uid-1").map(\.name), ["Everywhere", "Mine"])
        XCTAssertEqual(library.otherOutputs(for: "uid-1").map(\.name), ["Theirs"])
        XCTAssertEqual(library.visible(for: nil).map(\.name), ["Everywhere"])
        XCTAssertEqual(library.otherOutputs(for: nil).map(\.name), ["Mine", "Theirs"])
    }

    @MainActor
    func testChangingScopeMovesAPresetBetweenTheTwoLists() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        guard let saved = library.saveCurrent(name: "Moving", scope: .global) else {
            return XCTFail("the preset should have been saved")
        }

        library.setScope(saved, to: .output(uid: "uid-9", name: "Desk"))

        XCTAssertTrue(library.visible(for: "uid-1").isEmpty)
        XCTAssertEqual(library.visible(for: "uid-9").map(\.name), ["Moving"])
        XCTAssertEqual(PresetLibraryFile.load(from: url)?.presets.first?.scope,
                       .output(uid: "uid-9", name: "Desk"))
    }

    @MainActor
    func testAScopeWithNoUIDIsRefusedRatherThanHidingThePreset() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        guard let saved = library.saveCurrent(name: "Staying", scope: .global) else {
            return XCTFail("the preset should have been saved")
        }

        library.setScope(saved, to: .output(uid: "", name: "Nothing"))

        XCTAssertEqual(library.presets.first?.scope, .global)
    }


    func testUniqueNameCountsUpAndTerminates() {
        XCTAssertEqual(PresetLibrary.uniqueName("Harman", taken: []), "Harman")
        XCTAssertEqual(PresetLibrary.uniqueName("Harman", taken: ["Harman"]), "Harman 2")
        XCTAssertEqual(PresetLibrary.uniqueName("Harman", taken: ["Harman", "Harman 2"]),
                       "Harman 3")
    }

    @MainActor
    func testSavingTheSameNameTwiceInOneScopeMakesTheSecondUnique() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        library.saveCurrent(name: "Harman", scope: .global)
        library.saveCurrent(name: "Harman", scope: .global)

        XCTAssertEqual(library.presets.map(\.name), ["Harman", "Harman 2"])
    }

    @MainActor
    func testTheSameNameIsFreeAgainInADifferentScope() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        library.saveCurrent(name: "Harman", scope: .global)
        library.saveCurrent(name: "Harman", scope: .output(uid: "uid-1", name: "Cans"))

        XCTAssertEqual(library.presets.map(\.name), ["Harman", "Harman"])
    }

    @MainActor
    func testRenamingOntoATakenNameCountsUpAndAnEmptyNameIsRefused() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        library.saveCurrent(name: "Harman", scope: .global)
        guard let second = library.saveCurrent(name: "Other", scope: .global) else {
            return XCTFail("the preset should have been saved")
        }

        library.rename(second, to: "Harman")
        XCTAssertEqual(library.presets.map(\.name), ["Harman", "Harman 2"])

        library.rename(library.presets[1], to: "   ")
        XCTAssertEqual(library.presets.map(\.name), ["Harman", "Harman 2"])
    }

    @MainActor
    func testRenamingAPresetToTheNameItAlreadyHasDoesNotCountUp() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        guard let only = library.saveCurrent(name: "Harman", scope: .global) else {
            return XCTFail("the preset should have been saved")
        }

        library.rename(only, to: "Harman")

        XCTAssertEqual(library.presets.map(\.name), ["Harman"])
    }


    @MainActor
    func testSavingTheCurrentCurveRecordsTheGroupAndTheSourceName() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url, group: .b20,
                                        curve: bands(20, gain: 5), preGain: -6.5,
                                        sourceName: "Alder AR-5")

        let saved = library.saveCurrent(name: "Twenty", scope: .global)

        XCTAssertEqual(saved?.group, .b20)
        XCTAssertEqual(saved?.bands.count, 20)
        XCTAssertEqual(saved?.preGain, -6.5)
        XCTAssertEqual(saved?.sourceName, "Alder AR-5")
        XCTAssertEqual(PresetLibraryFile.load(from: url)?.presets.count, 1)
    }

    @MainActor
    func testSavingWithNoDeviceSaysSoAndKeepsTheLibraryEmpty() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url, group: nil)

        XCTAssertNil(library.saveCurrent(name: "Nothing to save", scope: .global))
        XCTAssertTrue(library.presets.isEmpty)
        XCTAssertNotNil(library.lastMessage)
    }


    @MainActor
    func testApplyingAMatchingPresetGoesThroughTheWritePath() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, applied) = self.library(at: url)
        guard let saved = library.saveCurrent(name: "Harman", scope: .global) else {
            return XCTFail("the preset should have been saved")
        }

        XCTAssertTrue(library.apply(saved))
        XCTAssertEqual(applied().map(\.name), ["Harman"])
        XCTAssertNil(library.lastMessage)
    }

    @MainActor
    func testAPresetMadeForTheOtherBankIsRefusedAndBothModesAreNamed() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, applied) = self.library(at: url, group: .user)
        library.previewSet(presets: [preset("Studio reference", group: .b20,
                                            bandCount: 20)])

        guard let stored = library.presets.first else {
            return XCTFail("the preset should be in the library")
        }
        XCTAssertFalse(library.apply(stored))
        XCTAssertTrue(applied().isEmpty)

        let message = library.lastMessage ?? ""
        XCTAssertTrue(message.contains("20-band"), message)
        XCTAssertTrue(message.contains("10-band"), message)
        XCTAssertTrue(message.contains("Studio reference"), message)
    }

    @MainActor
    func testAWriteTheDeviceRefusesIsReportedRatherThanCountedAsApplied() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, applied) = self.library(at: url, applies: false)
        guard let saved = library.saveCurrent(name: "Harman", scope: .global) else {
            return XCTFail("the preset should have been saved")
        }

        XCTAssertFalse(library.apply(saved))
        XCTAssertTrue(applied().isEmpty)
        XCTAssertNotNil(library.lastMessage)
    }

    @MainActor
    func testApplyingWithNoDeviceIsRefused() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, applied) = self.library(at: url, group: nil)
        library.previewSet(presets: [preset("Harman")])

        guard let stored = library.presets.first else {
            return XCTFail("the preset should be in the library")
        }
        XCTAssertFalse(library.apply(stored))
        XCTAssertTrue(applied().isEmpty)
    }


    @MainActor
    func testDeletingRemovesThePresetFromDiskToo() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        library.saveCurrent(name: "Keep", scope: .global)
        guard let doomed = library.saveCurrent(name: "Drop", scope: .global) else {
            return XCTFail("the preset should have been saved")
        }

        library.delete(doomed)

        XCTAssertEqual(library.presets.map(\.name), ["Keep"])
        XCTAssertEqual(PresetLibraryFile.load(from: url)?.presets.map(\.name), ["Keep"])
    }

    @MainActor
    func testTheHeadphoneNameIsScrubbedAndPersisted() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)

        library.setHeadphoneName("Alder\u{202E} AR-5\n")

        XCTAssertFalse(library.headphoneName.unicodeScalars.contains { $0.value == 0x202E })
        XCTAssertFalse(library.headphoneName.contains("\n"))
        XCTAssertEqual(PresetLibraryFile.load(from: url)?.headphoneName,
                       library.headphoneName)
    }

    @MainActor
    func testImportingTextAddsAPresetWithoutTouchingTheDevice() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, applied) = self.library(at: url)
        let text = """
        Preamp: -6.1 dB
        Filter 1: ON LSC Fc 105 Hz Gain 6.4 dB Q 0.70
        Filter 2: ON PK Fc 8800 Hz Gain 5.1 dB Q 1.42
        """

        let saved = library.importText(text, name: "Alder AR-5")

        XCTAssertEqual(saved?.name, "Alder AR-5")
        XCTAssertEqual(saved?.bands.count, 2)
        XCTAssertEqual(saved?.preGain ?? 0, -6.1, accuracy: 0.001)
        XCTAssertEqual(saved?.group, .user)
        XCTAssertTrue(applied().isEmpty)
    }

    @MainActor
    func testImportingTextWithNoFiltersIsRefused() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)

        XCTAssertNil(library.importText("nothing to see here", name: "Empty"))
        XCTAssertTrue(library.presets.isEmpty)
        XCTAssertNotNil(library.lastMessage)
    }

    @MainActor
    func testExportedTextParsesBackIntoTheSameCurve() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        let original = LibraryPreset(
            name: "Round trip", group: .user,
            bands: [QxEqBandValue(filter: .lowShelf, freq: 105, gain: 6.4, q: 0.7),
                    QxEqBandValue(filter: .peak, freq: 8800, gain: -5.1, q: 1.42)],
            preGain: -6.1)

        guard let parsed = ParametricEQFile.parse(library.exportText(original)) else {
            return XCTFail("the export should parse back")
        }

        XCTAssertEqual(parsed.preamp, -6.1, accuracy: 0.05)
        XCTAssertEqual(parsed.bands.count, 2)
        XCTAssertEqual(parsed.bands[0].filter, .lowShelf)
        XCTAssertEqual(parsed.bands[0].freq, 105)
        XCTAssertEqual(parsed.bands[0].gain, 6.4, accuracy: 0.05)
        XCTAssertEqual(parsed.bands[1].filter, .peak)
        XCTAssertEqual(parsed.bands[1].gain, -5.1, accuracy: 0.05)
    }

    @MainActor
    func testTheLibraryRefusesToGrowPastItsCap() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        library.previewSet(presets: (0..<PresetLibraryFile.maxPresets).map {
            preset("Preset \($0)")
        })

        XCTAssertNil(library.saveCurrent(name: "One too many", scope: .global))
        XCTAssertEqual(library.presets.count, PresetLibraryFile.maxPresets)
        XCTAssertNotNil(library.lastMessage)
    }

    @MainActor
    func testSuggestedNamesSurviveAReload() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (first, _) = self.library(at: url)
        first.start(fileURL: url)
        first.setHeadphoneName("Sennheiser HD 650")
        first.markSuggested("sennheiserhd650")
        XCTAssertTrue(first.hasSuggested("sennheiserhd650"))

        let (second, _) = self.library(at: url)
        second.start(fileURL: url)
        XCTAssertEqual(second.headphoneName, "Sennheiser HD 650")
        XCTAssertTrue(second.hasSuggested("sennheiserhd650"))
        XCTAssertFalse(second.hasSuggested("beyerdynamicdt770"))
        XCTAssertFalse(second.hasSuggested(""))
    }

    @MainActor
    func testSuggestedNamesAreBoundedAndDropTheOldestFirst() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        library.start(fileURL: url)
        for i in 0..<(PresetLibraryFile.maxSuggestedNames + 5) {
            library.markSuggested("name\(i)")
        }
        XCTAssertEqual(library.suggestedHeadphones.count,
                       PresetLibraryFile.maxSuggestedNames)
        XCTAssertFalse(library.hasSuggested("name0"))
        XCTAssertFalse(library.hasSuggested("name4"))
        XCTAssertTrue(library.hasSuggested("name5"))
        XCTAssertTrue(library.hasSuggested(
            "name\(PresetLibraryFile.maxSuggestedNames + 4)"))
    }

    @MainActor
    func testRepeatingASuggestedNameMovesItToTheFreshEnd() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        library.start(fileURL: url)
        library.markSuggested("alpha")
        library.markSuggested("beta")
        library.markSuggested("alpha")
        XCTAssertEqual(library.suggestedHeadphones, ["beta", "alpha"])
        library.markSuggested("")
        XCTAssertEqual(library.suggestedHeadphones, ["beta", "alpha"])
    }

    func testASuggestedNameListIsSanitisedOnTheWayIn() {
        let over = (0..<(PresetLibraryFile.maxSuggestedNames + 8)).map { "n\($0)" }
        let trimmed = PresetLibraryFile.trimmedSuggestions(over + ["", "n0", "a\u{0}b"])
        XCTAssertEqual(trimmed.count, PresetLibraryFile.maxSuggestedNames)
        XCTAssertEqual(trimmed.last, "ab")
        XCTAssertFalse(trimmed.contains(""))
        XCTAssertEqual(Set(trimmed).count, trimmed.count)
    }

    func testAFileWithoutTheSuggestedFieldStillDecodes() throws {
        let json = Data("""
            {"schemaVersion": 1, "headphoneName": "HD 650", "presets": []}
            """.utf8)
        let document = try JSONDecoder().decode(PresetLibraryDocument.self, from: json)
        XCTAssertEqual(document.headphoneName, "HD 650")
        XCTAssertTrue(document.suggestedHeadphones.isEmpty)
    }

    func testAMalformedSuggestedFieldIsIgnoredRatherThanFatal() throws {
        let json = Data("""
            {"schemaVersion": 1, "headphoneName": "HD 650",
             "suggestedHeadphones": {"nope": 1}, "presets": []}
            """.utf8)
        let document = try JSONDecoder().decode(PresetLibraryDocument.self, from: json)
        XCTAssertEqual(document.headphoneName, "HD 650")
        XCTAssertTrue(document.suggestedHeadphones.isEmpty)
    }
}
