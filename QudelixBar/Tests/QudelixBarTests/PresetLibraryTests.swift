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

    private func parkedURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path + ".recovered")
    }

    private func removeWithParkedCopy(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        for copy in ParkedCopy.candidates(beside: url) {
            try? FileManager.default.removeItem(at: copy)
        }
    }

    func testOneUnreadableRecordDoesNotCostTheRestOfTheLibrary() {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
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
        XCTAssertEqual(try? String(contentsOf: parkedURL(url), encoding: .utf8), json,
                       "records the loader drops are kept in the original file's copy")
    }

    func testOneMalformedBandCostsThatBandRatherThanTheWholePreset() {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        let json = """
        {"schemaVersion":1,"headphoneName":"HD 650","presets":[
          {"name":"Mostly good","groupRaw":0,"preGain":-1.5,
           "bands":[{"filter":5,"freq":1000,"gain":1,"q":1},
                    {"filter":5,"freq":"two thousand","gain":2,"q":1},
                    {"filter":5,"freq":3000,"gain":3,"q":1}]}]}
        """
        try? Data(json.utf8).write(to: url)

        let loaded = PresetLibraryFile.load(from: url)

        XCTAssertEqual(loaded?.presets.map(\.name), ["Mostly good"],
                       "one unreadable band must not cost the preset")
        XCTAssertEqual(loaded?.presets.first?.bands.map(\.freq), [1000, 3000])
        XCTAssertEqual(loaded?.presets.first?.preGain, -1.5)
        XCTAssertEqual(try? String(contentsOf: parkedURL(url), encoding: .utf8), json)
    }

    @MainActor
    func testAnUnreadableFileIsLeftAloneRatherThanReplacedWithAnEmptyLibrary() throws {
        try XCTSkipIf(getuid() == 0, "root reads a 0000-mode file regardless")
        let url = tempFileURL()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ".recovered"))
        }
        PresetLibraryFile.save(PresetLibraryDocument(presets: [preset("Keep me")]), to: url)
        let before = try String(contentsOf: url, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: url.path)
        try XCTSkipIf(SafeFile.read(url, cap: 2_000_000) != nil,
                      "this filesystem ignores the mode bits")

        XCTAssertNil(PresetLibraryFile.load(from: url),
                     "a file that exists but cannot be read is not an empty library")

        let (library, _) = self.library(at: url)
        XCTAssertTrue(library.presets.isEmpty)
        XCTAssertNotNil(library.lastMessage, "the user is told the library is not live")

        library.saveCurrent(name: "Something new", scope: .global)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before,
                       "an unreadable library is never written over")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".recovered"),
                       "nothing can be parked when the bytes could not be read")
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

    private func validPresetJSON(_ name: String, group: Int = 0) -> String {
        """
        {"id":"\(UUID().uuidString)","name":"\(name)","groupRaw":\(group),"preGain":-2.0,
         "bands":[{"filter":5,"freq":1000,"gain":2.5,"q":1.0}]}
        """
    }

    @MainActor
    func testTheWarningOfAnUnreadableFileSurvivesEverySaveAndApply() throws {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        let original = "{ not json"
        try Data(original.utf8).write(to: url)
        let (library, _) = self.library(at: url)
        let warning = try XCTUnwrap(library.lastMessage)
        XCTAssertTrue(warning.contains("left alone"))
        XCTAssertTrue(warning.contains("memory"), "the user is told nothing is being kept")

        let saved = library.saveCurrent(name: "Session preset", scope: .global)
        XCTAssertNotNil(saved)
        XCTAssertTrue(library.lastMessage?.contains("left alone") == true)
        XCTAssertTrue(library.apply(try XCTUnwrap(saved)))
        XCTAssertTrue(library.lastMessage?.contains("left alone") == true)

        library.clearMessage()
        XCTAssertNil(library.lastMessage)
        library.saveCurrent(name: "Another", scope: .global)
        XCTAssertTrue(library.lastMessage?.contains("left alone") == true,
                      "the next save puts the reminder back")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    @MainActor
    func testNothingTheLibraryDoesWhileReadOnlyTouchesTheFile() throws {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        let original = #"{"schemaVersion":3,"library":{"items":[]}}"#
        try Data(original.utf8).write(to: url)
        let (library, _) = self.library(at: url)

        let a = try XCTUnwrap(library.saveCurrent(name: "One", scope: .global))
        let b = try XCTUnwrap(library.saveCurrent(name: "Two", scope: .global))
        library.rename(a, to: "Renamed")
        library.setScope(b, to: .output(uid: "uid-1", name: "Cans"))
        library.delete(a)
        library.setHeadphoneName("Sennheiser HD 650")
        library.markSuggested("sennheiserhd650")
        library.setAppAssignments([AppAssignment(bundleID: "com.example.app",
                                                 displayName: "Example", presetID: b.id)])
        library.flushPendingWrites()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
        XCTAssertEqual(library.presets.map(\.name), ["Two"])
    }

    func testANewerFormatIsParkedAndNeverLoadedAsEmpty() throws {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        let json = """
        {"schemaVersion":\(PresetLibraryFile.currentSchemaVersion + 1),"headphoneName":"HD 650",
         "presets":[\(validPresetJSON("Kept"))],"somethingNew":{"a":1}}
        """
        try Data(json.utf8).write(to: url)

        guard case .newer(let version, _) = PresetLibraryFile.outcome(from: url) else {
            return XCTFail("a newer format must not be treated as loadable")
        }
        XCTAssertEqual(version, PresetLibraryFile.currentSchemaVersion + 1)
        XCTAssertNil(PresetLibraryFile.load(from: url))
        XCTAssertEqual(try String(contentsOf: parkedURL(url), encoding: .utf8), json)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), json)
    }

    @MainActor
    func testALibraryFromANewerVersionIsReadOnlyAndSaysSo() throws {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        let json = """
        {"schemaVersion":7,"presets":[\(validPresetJSON("Future bank", group: 3))]}
        """
        try Data(json.utf8).write(to: url)

        let (library, _) = self.library(at: url)
        library.saveCurrent(name: "Mine", scope: .global)
        library.setHeadphoneName("HD 650")
        library.flushPendingWrites()

        XCTAssertTrue(library.lastMessage?.contains("newer") == true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), json)
        XCTAssertEqual(try String(contentsOf: parkedURL(url), encoding: .utf8), json)
    }

    func testADocumentWithNoPresetsListIsParkedRatherThanLoadedAsEmpty() throws {
        for json in [#"{"library":{"presets":[]}}"#, "{}", #"{"presets":"none"}"#, "42", "null"] {
            let url = tempFileURL()
            defer { removeWithParkedCopy(url) }
            try Data(json.utf8).write(to: url)

            guard case .undecodable = PresetLibraryFile.outcome(from: url) else {
                return XCTFail("\(json) must be parked, not loaded as an empty library")
            }
            XCTAssertEqual(try String(contentsOf: parkedURL(url), encoding: .utf8), json)
        }
    }

    func testAnEmptyButValidLibraryIsNotMistakenForADamagedOne() throws {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        try Data(#"{"schemaVersion":1,"headphoneName":"HD 650","presets":[]}"#.utf8).write(to: url)

        guard case .loaded(let document) = PresetLibraryFile.outcome(from: url) else {
            return XCTFail("an empty library is a library")
        }
        XCTAssertEqual(document.headphoneName, "HD 650")
        XCTAssertFalse(FileManager.default.fileExists(atPath: parkedURL(url).path))
    }

    @MainActor
    func testEntriesTheLoaderCannotKeepAreReportedAndTheOriginalIsParkedFirst() throws {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        let json = """
        {"schemaVersion":1,"presets":[\(validPresetJSON("Good")),\(validPresetJSON("Odd bank", group: 9)),
        {"id":"\(UUID().uuidString)","name":"Fractional","groupRaw":0,"preGain":0,
         "bands":[{"filter":5,"freq":1000.5,"gain":1,"q":1}]}]}
        """
        try Data(json.utf8).write(to: url)

        let (library, _) = self.library(at: url)

        XCTAssertEqual(library.presets.map(\.name), ["Good"])
        XCTAssertTrue(library.lastMessage?.contains("left out") == true)
        XCTAssertEqual(try String(contentsOf: parkedURL(url), encoding: .utf8), json)
        library.rename(try XCTUnwrap(library.presets.first), to: "Renamed")
        XCTAssertEqual(PresetLibraryFile.load(from: url)?.presets.map(\.name), ["Renamed"])
        XCTAssertEqual(try String(contentsOf: parkedURL(url), encoding: .utf8), json,
                       "the copy still holds everything that was in the file")
    }

    @MainActor
    func testAFailedWriteIsReportedAndTheReportClearsOnceWritingWorksAgain() throws {
        try XCTSkipIf(getuid() == 0, "root writes into a read-only folder regardless")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("preset-library-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let url = folder.appendingPathComponent("presets.json")
        let (library, _) = self.library(at: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: folder.path)
        let probe = folder.appendingPathComponent("probe")
        try XCTSkipIf(FileManager.default.createFile(atPath: probe.path, contents: Data()),
                      "this filesystem ignores the mode bits")

        let kept = library.saveCurrent(name: "In memory only", scope: .global)

        XCTAssertNotNil(kept)
        XCTAssertEqual(library.presets.count, 1)
        let message = try XCTUnwrap(library.lastMessage)
        XCTAssertTrue(message.contains("Couldn't write presets.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        library.saveCurrent(name: "Still failing", scope: .global)
        XCTAssertTrue(library.lastMessage?.contains("Couldn't write") == true)

        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: folder.path)
        library.saveCurrent(name: "Back to normal", scope: .global)

        XCTAssertNil(library.lastMessage)
        XCTAssertEqual(PresetLibraryFile.load(from: url)?.presets.count, 3)
    }

    func testSavingReportsFailureThroughItsReturnValue() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-folder-\(UUID().uuidString)")
            .appendingPathComponent("presets.json")
        XCTAssertFalse(PresetLibraryFile.save(PresetLibraryDocument(presets: [preset("X")]),
                                              to: missing))
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(PresetLibraryFile.save(PresetLibraryDocument(presets: [preset("X")]),
                                             to: url))
    }

    private func storedName(_ url: URL) -> String? {
        PresetLibraryFile.load(from: url)?.headphoneName
    }

    @MainActor
    func testTypingANameWritesTheFirstKeystrokeAndTheSettledNameNotEveryPrefix() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        library.nameCommitDelay = 0.05
        let typed = "Sennheiser HD 650"

        var seen: [String?] = []
        for end in typed.indices {
            library.setHeadphoneName(String(typed[...end]))
            seen.append(storedName(url))
        }

        XCTAssertEqual(library.headphoneName, typed)
        XCTAssertEqual(Set(seen.compactMap { $0 }), ["S"],
                       "no half-typed name reaches the disk while keys are still arriving")
        XCTAssertEqual(library.committedHeadphoneName, "S")

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(library.committedHeadphoneName, typed)
        XCTAssertEqual(storedName(url), typed)
    }

    @MainActor
    func testAPastedNameIsCommittedAtOnce() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)

        library.setHeadphoneName("Sennheiser HD 650")

        XCTAssertEqual(library.committedHeadphoneName, "Sennheiser HD 650")
        XCTAssertEqual(storedName(url), "Sennheiser HD 650")
    }

    @MainActor
    func testFlushingWritesAPendingNameWithoutWaiting() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        library.nameCommitDelay = 30

        library.setHeadphoneName("Se")
        library.setHeadphoneName("Sennheiser")
        XCTAssertEqual(storedName(url), "Se")
        library.flushPendingWrites()

        XCTAssertEqual(storedName(url), "Sennheiser")
        XCTAssertEqual(library.committedHeadphoneName, "Sennheiser")
    }

    @MainActor
    func testAnotherSaveCarriesTheNameBeingTypedWithIt() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        library.nameCommitDelay = 30

        library.setHeadphoneName("Se")
        library.setHeadphoneName("Sennheiser")
        library.saveCurrent(name: "Mine", scope: .global)

        XCTAssertEqual(storedName(url), "Sennheiser")
        library.flushPendingWrites()
    }

    @MainActor
    func testOnlyTheNameThatSettlesIsRememberedAsAlreadySuggested() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        library.nameCommitDelay = 0.05

        library.setHeadphoneName("S")
        library.setHeadphoneName("Senn")
        library.markSuggested("senn")
        library.setHeadphoneName("Sennheiser HD 6")
        library.markSuggested("sennheiserhd6")
        library.setHeadphoneName("Sennheiser HD 650")
        library.markSuggested("sennheiserhd650")
        XCTAssertTrue(library.suggestedHeadphones.isEmpty, "nothing is final while typing")

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(library.suggestedHeadphones, ["sennheiserhd650"])
        XCTAssertEqual(PresetLibraryFile.load(from: url)?.suggestedHeadphones,
                       ["sennheiserhd650"])
    }

    @MainActor
    func testAMarkForANameThatChangedAgainIsDiscarded() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        library.nameCommitDelay = 0.05

        library.setHeadphoneName("S")
        library.setHeadphoneName("Sennheiser HD 650")
        library.markSuggested("sennheiserhd650")
        library.setHeadphoneName("Beyerdynamic DT 770")

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(library.suggestedHeadphones.isEmpty)
    }

    @MainActor
    func testAMarkWithNoNameBeingTypedIsRecordedAtOnce() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)

        library.setHeadphoneName("Sennheiser HD 650")
        library.markSuggested("sennheiserhd650")

        XCTAssertEqual(library.suggestedHeadphones, ["sennheiserhd650"])
        XCTAssertEqual(PresetLibraryFile.load(from: url)?.suggestedHeadphones,
                       ["sennheiserhd650"])
    }

    @MainActor
    func testALongerFileKeepsTheBandsDoingTheMostWorkAndEveryShelf() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        var lines = ["Preamp: 0 dB", "Filter 1: ON LSC Fc 60 Hz Gain 2 dB Q 0.7"]
        for i in 1...9 {
            let gain = (i == 3 || i == 7) ? 0.1 : 3.0
            lines.append("Filter \(i + 1): ON PK Fc \(100 * i + 50) Hz Gain \(gain) dB Q 1")
        }
        lines.append("Filter 11: ON HSC Fc 9000 Hz Gain -2 dB Q 0.7")
        lines.append("Filter 12: ON PK Fc 5000 Hz Gain 2 dB Q 1")

        let saved = try XCTUnwrap(library.importText(lines.joined(separator: "\n"),
                                                     name: "Long"))

        XCTAssertEqual(saved.bands.count, 10)
        XCTAssertFalse(saved.bands.contains { abs($0.gain - 0.1) < 0.001 },
                       "the two bands doing next to nothing are the ones that go")
        XCTAssertEqual(saved.bands.filter { $0.filter == .lowShelf || $0.filter == .highShelf }.count, 2)
        XCTAssertEqual(saved.bands.map(\.freq), [60, 150, 250, 450, 550, 650, 850, 950, 9000, 5000],
                       "what is kept stays in the file's order")
        let message = try XCTUnwrap(library.lastMessage)
        XCTAssertTrue(message.contains("2 band(s) dropped"), message)
        XCTAssertLessThan(saved.preGain, 0, "the pre-gain is lowered for what was kept")
        XCTAssertTrue(message.contains("pre-gain lowered"), message)
    }

    @MainActor
    func testAFileThatFitsIsImportedWithoutNotesAboutDroppedBands() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)

        _ = try XCTUnwrap(library.importText("Filter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1",
                                             name: "Short"))

        XCTAssertFalse(library.lastMessage?.contains("dropped") == true)
    }

    @MainActor
    func testAUTF16FileImportsAndAFailureNamesTheFileNotWhatWasPasted() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("preset-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)
        let text = "Preamp: -3 dB\nFilter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1\n"
        let good = folder.appendingPathComponent("Alder UTF16.txt")
        try XCTUnwrap(text.data(using: .utf16)).write(to: good)
        let empty = folder.appendingPathComponent("Nothing here.txt")
        try XCTUnwrap("just words".data(using: .utf16)).write(to: empty)

        let saved = library.importFile(at: good)

        XCTAssertEqual(saved?.name, "Alder UTF16")
        XCTAssertEqual(saved?.bands.count, 1)
        XCTAssertEqual(saved?.preGain ?? 0, -3, accuracy: 0.001)

        XCTAssertNil(library.importFile(at: empty))
        let message = try XCTUnwrap(library.lastMessage)
        XCTAssertTrue(message.contains("Nothing here.txt"), message)
        XCTAssertFalse(message.contains("pasted"), message)
    }

    @MainActor
    func testPastedTextStillSaysPasted() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (library, _) = self.library(at: url)

        XCTAssertNil(library.importText("words only", name: "Empty"))

        XCTAssertTrue(library.lastMessage?.contains("what was pasted") == true)
    }

    func testParkedCopiesAreNumberedAndAnEarlierOneIsNeverOverwritten() throws {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        let candidates = ParkedCopy.candidates(beside: url)

        XCTAssertEqual(ParkedCopy.park(Data("first".utf8), beside: url), candidates[0])
        XCTAssertEqual(ParkedCopy.park(Data("second".utf8), beside: url), candidates[1])
        XCTAssertEqual(ParkedCopy.park(Data("third".utf8), beside: url), candidates[2])

        XCTAssertEqual(try String(contentsOf: candidates[0], encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: candidates[1], encoding: .utf8), "second")
        XCTAssertEqual(try String(contentsOf: candidates[2], encoding: .utf8), "third")
        XCTAssertTrue(candidates[1].lastPathComponent.hasSuffix(".recovered-2"))
    }

    func testTheSameBytesAreNotParkedTwice() throws {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        let candidates = ParkedCopy.candidates(beside: url)

        ParkedCopy.park(Data("same".utf8), beside: url)
        ParkedCopy.park(Data("other".utf8), beside: url)
        let again = ParkedCopy.park(Data("same".utf8), beside: url)

        XCTAssertEqual(again, candidates[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidates[2].path))
    }

    @MainActor
    func testTwoDifferentDamagedFilesKeepTwoCopies() throws {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        let candidates = ParkedCopy.candidates(beside: url)

        try Data("{ first damage".utf8).write(to: url)
        _ = self.library(at: url)
        try Data("{ second damage".utf8).write(to: url)
        _ = self.library(at: url)

        XCTAssertEqual(try String(contentsOf: candidates[0], encoding: .utf8), "{ first damage")
        XCTAssertEqual(try String(contentsOf: candidates[1], encoding: .utf8), "{ second damage")
    }

    @MainActor
    func testReopeningTheSameReadOnlyFileDoesNotPileUpCopies() throws {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        let candidates = ParkedCopy.candidates(beside: url)
        try Data(#"{"schemaVersion":9,"presets":[]}"#.utf8).write(to: url)

        for _ in 0..<4 { _ = self.library(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: candidates[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidates[1].path))
    }

    @MainActor
    func testTheNoticeNamesTheCopyThatWasActuallyMade() throws {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        try Data("{ earlier damage".utf8).write(to: url)
        _ = self.library(at: url)
        try Data("{ later damage".utf8).write(to: url)

        let (library, _) = self.library(at: url)

        let message = try XCTUnwrap(library.lastMessage)
        XCTAssertTrue(message.contains("presets.json.recovered-2")
                      || message.contains(url.lastPathComponent + ".recovered-2"), message)
    }
}
