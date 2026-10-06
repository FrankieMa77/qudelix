import XCTest
@testable import QudelixBar

final class ProfileRulesTests: XCTestCase {
    private var sandbox: URL!

    override func setUp() {
        super.setUp()
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("profile-rules-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox,
                                                 withIntermediateDirectories: true)
        ProfileRulesFile.urlOverride = sandbox.appendingPathComponent("profiles.json")
    }

    override func tearDown() {
        ProfileRulesFile.urlOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
        sandbox = nil
        super.tearDown()
    }

    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-rules-test-\(UUID().uuidString).json")
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

    @MainActor
    func testUnknownOutputProducesNoSuggestionAndNoApply() {
        let rules = ProfileRules()
        var applied: Int?
        rules.onApplyPreset = { applied = $0; return true }

        rules.outputChanged(uid: "unknown-uid", name: "Mystery Adapter")

        XCTAssertNil(rules.suggestion)
        XCTAssertNil(applied)
    }

    @MainActor
    func testKnownOutputWithAutomaticOffOffersASuggestionRatherThanApplying() {
        let rules = ProfileRules()
        rules.bind(outputUID: "uid-1", outputName: "Studio Cans", presetIndex: 3)
        var applied: Int?
        rules.onApplyPreset = { applied = $0; return true }

        rules.outputChanged(uid: "uid-1", name: "Studio Cans")

        XCTAssertNil(applied, "automatic is off by default even after binding")
        XCTAssertEqual(rules.suggestion?.outputUID, "uid-1")
        XCTAssertEqual(rules.suggestion?.presetIndex, 3)
    }

    @MainActor
    func testRepeatedReportOfTheSameOutputDoesNotResurfaceADismissedSuggestion() {
        let rules = ProfileRules()
        rules.bind(outputUID: "uid-1", outputName: "Studio Cans", presetIndex: 3)

        rules.outputChanged(uid: "uid-1", name: "Studio Cans")
        XCTAssertNotNil(rules.suggestion)
        rules.dismissSuggestion()
        XCTAssertNil(rules.suggestion)

        rules.outputChanged(uid: "uid-1", name: "Studio Cans")
        XCTAssertNil(rules.suggestion)
    }

    @MainActor
    func testConfirmingASuggestionAppliesOnceAndMarksTheRuleConfirmed() {
        let rules = ProfileRules()
        rules.previewSet(rules: [ProfileRule(outputUID: "uid-2", outputName: "Desk Speakers",
                                             presetIndex: 5)])
        var applied: [Int] = []
        rules.onApplyPreset = { applied.append($0); return true }

        rules.outputChanged(uid: "uid-2", name: "Desk Speakers")
        XCTAssertNotNil(rules.suggestion)
        rules.confirmSuggestion()

        XCTAssertEqual(applied, [5])
        XCTAssertNil(rules.suggestion)
        XCTAssertEqual(rules.rules.first(where: { $0.outputUID == "uid-2" })?.confirmed, true)
    }

    @MainActor
    func testAutomaticCannotBeTurnedOnBeforeTheRuleIsConfirmed() {
        let rules = ProfileRules()
        rules.previewSet(rules: [ProfileRule(outputUID: "uid-3", outputName: "Travel IEMs",
                                             presetIndex: 1, confirmed: false)])

        rules.setAutomatic(true, forUID: "uid-3")

        XCTAssertEqual(rules.rules.first?.automatic, false,
                       "the confirm gate must hold even against a direct call")
    }

    @MainActor
    func testAutomaticTurnsOnOnceConfirmedAndThenAppliesSilently() {
        let rules = ProfileRules()
        rules.bind(outputUID: "uid-4", outputName: "Home Rig", presetIndex: 7)
        rules.canApplyNow = { true }
        var applied: [Int] = []
        rules.onApplyPreset = { applied.append($0); return true }

        rules.setAutomatic(true, forUID: "uid-4")
        XCTAssertEqual(rules.rules.first?.automatic, true)

        rules.outputChanged(uid: "uid-4", name: "Home Rig")

        XCTAssertEqual(applied, [7])
        XCTAssertNil(rules.suggestion, "an automatic switch has nothing left to ask")
    }

    @MainActor
    func testAutomaticFallsBackToASuggestionWhenApplyingWouldNotBeSafe() {
        let rules = ProfileRules()
        rules.bind(outputUID: "uid-5", outputName: "Night Setup", presetIndex: 2)
        rules.setAutomatic(true, forUID: "uid-5")
        rules.canApplyNow = { false }
        var applied: [Int] = []
        rules.onApplyPreset = { applied.append($0); return true }

        rules.outputChanged(uid: "uid-5", name: "Night Setup")

        XCTAssertTrue(applied.isEmpty, "must not apply silently when it isn't safe to")
        XCTAssertEqual(rules.suggestion?.outputUID, "uid-5",
                       "the switch is still offered, just not done unannounced")
    }

    @MainActor
    func testARefusedApplyDoesNotConfirmTheRule() {
        let rules = ProfileRules()
        rules.previewSet(rules: [ProfileRule(outputUID: "uid-r", outputName: "Refused",
                                             presetIndex: 6)])
        var attempts = 0
        rules.onApplyPreset = { _ in attempts += 1; return false }

        rules.outputChanged(uid: "uid-r", name: "Refused")
        XCTAssertNotNil(rules.suggestion)
        rules.confirmSuggestion()

        XCTAssertEqual(attempts, 1, "it should still have tried")
        XCTAssertEqual(rules.rules.first?.confirmed, false,
                       "a refused switch must not unlock automatic switching")
        XCTAssertNotNil(rules.suggestion,
                        "the offer stays up so the user can see it did not take")
    }

    @MainActor
    func testAutomaticFallsBackToAskingWhenTheWriteIsRefused() {
        let rules = ProfileRules()
        rules.bind(outputUID: "uid-s", outputName: "Silent Fail", presetIndex: 8)
        rules.canApplyNow = { true }
        rules.setAutomatic(true, forUID: "uid-s")
        rules.onApplyPreset = { _ in false }

        rules.outputChanged(uid: "uid-s", name: "Silent Fail")

        XCTAssertEqual(rules.suggestion?.presetIndex, 8,
                       "a dropped automatic switch must surface, not vanish")
    }

    @MainActor
    func testARuleFromAnotherEqGroupNeitherSwitchesNorOffersTo() {
        let rules = ProfileRules()
        rules.currentEqGroupRaw = QxEqGroup.user.rawValue
        rules.bind(outputUID: "uid-g", outputName: "Studio Cans", presetIndex: 3)
        rules.canApplyNow = { true }
        rules.setAutomatic(true, forUID: "uid-g")
        var applied: [Int] = []
        rules.onApplyPreset = { applied.append($0); return true }

        rules.currentEqGroupRaw = QxEqGroup.b20.rawValue
        rules.outputChanged(uid: "uid-g", name: "Studio Cans")

        XCTAssertTrue(applied.isEmpty, "slot 3 of the 20-band bank is not what this rule means")
        XCTAssertNil(rules.suggestion,
                     "offering it would label the other bank's slot from this bank's names")
    }

    @MainActor
    func testBindingRecordsTheGroupItWasMadeIn() {
        let rules = ProfileRules()
        rules.currentEqGroupRaw = QxEqGroup.b20.rawValue
        rules.bind(outputUID: "uid-h", outputName: "Twenty Band", presetIndex: 4)

        XCTAssertEqual(rules.rules.first?.eqGroupRaw, QxEqGroup.b20.rawValue)
    }

    @MainActor
    func testARuleReturnsToLifeWhenTheDeviceIsBackInItsGroup() {
        let rules = ProfileRules()
        rules.currentEqGroupRaw = QxEqGroup.user.rawValue
        rules.bind(outputUID: "uid-i", outputName: "Ten Band", presetIndex: 2)
        rules.canApplyNow = { true }
        rules.setAutomatic(true, forUID: "uid-i")
        var applied: [Int] = []
        rules.onApplyPreset = { applied.append($0); return true }

        rules.currentEqGroupRaw = QxEqGroup.b20.rawValue
        rules.outputChanged(uid: "uid-i", name: "Ten Band")
        XCTAssertTrue(applied.isEmpty)

        rules.currentEqGroupRaw = QxEqGroup.user.rawValue
        rules.outputChanged(uid: "other", name: "Something Else")
        rules.outputChanged(uid: "uid-i", name: "Ten Band")

        XCTAssertEqual(applied, [2])
    }

    @MainActor
    func testAnUnmarkedRuleAsksRatherThanSwitchingSilently() {
        let rules = ProfileRules()
        rules.previewSet(rules: [ProfileRule(outputUID: "uid-j", outputName: "Old Rule",
                                             presetIndex: 5, confirmed: true, automatic: true)])
        rules.currentEqGroupRaw = QxEqGroup.user.rawValue
        rules.canApplyNow = { true }
        var applied: [Int] = []
        rules.onApplyPreset = { applied.append($0); return true }

        rules.outputChanged(uid: "uid-j", name: "Old Rule")

        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(rules.suggestion?.presetIndex, 5)
    }

    @MainActor
    func testConfirmingAnUnmarkedRuleRecordsTheGroupItWasUsedIn() {
        let rules = ProfileRules()
        rules.previewSet(rules: [ProfileRule(outputUID: "uid-k", outputName: "Old Rule",
                                             presetIndex: 5)])
        rules.currentEqGroupRaw = QxEqGroup.b20.rawValue
        rules.onApplyPreset = { _ in true }

        rules.outputChanged(uid: "uid-k", name: "Old Rule")
        rules.confirmSuggestion()

        XCTAssertEqual(rules.rules.first?.eqGroupRaw, QxEqGroup.b20.rawValue)
    }

    @MainActor
    func testWithNoKnownGroupTheRulesBehaveAsBefore() {
        let rules = ProfileRules()
        rules.bind(outputUID: "uid-l", outputName: "Home Rig", presetIndex: 7)
        rules.canApplyNow = { true }
        rules.setAutomatic(true, forUID: "uid-l")
        var applied: [Int] = []
        rules.onApplyPreset = { applied.append($0); return true }

        rules.outputChanged(uid: "uid-l", name: "Home Rig")

        XCTAssertEqual(applied, [7])
    }

    private func twentyBandRule(automatic: Bool = true) -> ProfileRule {
        ProfileRule(outputUID: "uid-20", outputName: "Twenty", presetIndex: 4,
                    eqGroupRaw: QxEqGroup.b20.rawValue, confirmed: true, automatic: automatic)
    }

    @MainActor
    func testARuleForTheTwentyBandBankIsJudgedAgainOnceTheDeviceReportsIt() {
        let rules = ProfileRules()
        rules.previewSet(rules: [twentyBandRule()])
        rules.canApplyNow = { false }
        var applied: [Int] = []
        rules.onApplyPreset = { applied.append($0); return true }

        rules.currentEqGroupRaw = QxEqGroup.user.rawValue
        rules.currentEqGroupRaw = nil
        rules.outputChanged(uid: "uid-20", name: "Twenty")
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(rules.suggestion?.presetIndex, 4)

        rules.canApplyNow = { true }
        rules.currentEqGroupRaw = QxEqGroup.b20.rawValue

        XCTAssertEqual(applied, [4])
        XCTAssertNil(rules.suggestion)
    }

    @MainActor
    func testARuleForTheOtherBankStaysQuietWhenTheDeviceReportsItsGroup() {
        let rules = ProfileRules()
        rules.previewSet(rules: [ProfileRule(outputUID: "uid-10", outputName: "Ten",
                                             presetIndex: 3,
                                             eqGroupRaw: QxEqGroup.user.rawValue,
                                             confirmed: true, automatic: true)])
        rules.canApplyNow = { true }
        var applied: [Int] = []
        rules.onApplyPreset = { applied.append($0); return true }
        rules.outputChanged(uid: "uid-10", name: "Ten")
        XCTAssertEqual(applied, [3])
        rules.currentEqGroupRaw = nil

        rules.currentEqGroupRaw = QxEqGroup.b20.rawValue

        XCTAssertEqual(applied, [3])
        XCTAssertNil(rules.suggestion)
    }

    @MainActor
    func testReconnectingInTheSameGroupDoesNotSwitchAgain() {
        let rules = ProfileRules()
        rules.previewSet(rules: [twentyBandRule()])
        rules.canApplyNow = { true }
        var applied: [Int] = []
        rules.onApplyPreset = { applied.append($0); return true }
        rules.currentEqGroupRaw = QxEqGroup.b20.rawValue
        rules.outputChanged(uid: "uid-20", name: "Twenty")
        XCTAssertEqual(applied, [4])

        rules.currentEqGroupRaw = nil
        rules.currentEqGroupRaw = QxEqGroup.b20.rawValue

        XCTAssertEqual(applied, [4], "the output never changed, so nothing is decided again")
    }

    @MainActor
    func testSwitchingBanksWhileConnectedNeverSwitchesAPresetByItself() {
        let rules = ProfileRules()
        rules.previewSet(rules: [twentyBandRule()])
        rules.canApplyNow = { true }
        var applied: [Int] = []
        rules.onApplyPreset = { applied.append($0); return true }
        rules.currentEqGroupRaw = QxEqGroup.user.rawValue
        rules.outputChanged(uid: "uid-20", name: "Twenty")
        XCTAssertTrue(applied.isEmpty)

        rules.currentEqGroupRaw = QxEqGroup.b20.rawValue

        XCTAssertTrue(applied.isEmpty)
    }

    @MainActor
    func testABannerForOneBankDisappearsWhenTheDeviceChangesBank() {
        let rules = ProfileRules()
        rules.currentEqGroupRaw = QxEqGroup.user.rawValue
        rules.bind(outputUID: "uid-b", outputName: "Cans", presetIndex: 2)
        rules.outputChanged(uid: "uid-b", name: "Cans")
        XCTAssertNotNil(rules.suggestion)
        var applied: [Int] = []
        rules.onApplyPreset = { applied.append($0); return true }

        rules.currentEqGroupRaw = QxEqGroup.b20.rawValue

        XCTAssertNil(rules.suggestion)
        rules.confirmSuggestion()
        XCTAssertTrue(applied.isEmpty)
    }

    @MainActor
    func testConfirmingChecksTheBankAgainAndRefusesAStaleBanner() {
        let rules = ProfileRules()
        rules.currentEqGroupRaw = QxEqGroup.b20.rawValue
        rules.previewSet(
            rules: [ProfileRule(outputUID: "uid-s", outputName: "Cans", presetIndex: 6,
                                eqGroupRaw: QxEqGroup.user.rawValue)],
            suggestion: ProfileRules.Suggestion(outputUID: "uid-s", outputName: "Cans",
                                                presetIndex: 6, presetLabel: "Preset 7"))
        var applied: [Int] = []
        rules.onApplyPreset = { applied.append($0); return true }

        rules.confirmSuggestion()

        XCTAssertTrue(applied.isEmpty, "slot 6 of the other bank is not what this rule means")
        XCTAssertNil(rules.suggestion)
        XCTAssertEqual(rules.rules.first?.confirmed, false)
        XCTAssertEqual(rules.rules.first?.eqGroupRaw, QxEqGroup.user.rawValue)
    }

    @MainActor
    func testAnAutomaticSwitchThatCouldNotRunYetIsRetriedWhenTheDeviceIsReady() {
        let rules = ProfileRules()
        rules.previewSet(rules: [twentyBandRule()])
        var ready = false
        rules.canApplyNow = { ready }
        var applied: [Int] = []
        rules.onApplyPreset = { applied.append($0); return true }
        rules.currentEqGroupRaw = QxEqGroup.b20.rawValue
        rules.outputChanged(uid: "uid-20", name: "Twenty")
        XCTAssertTrue(applied.isEmpty)
        XCTAssertNotNil(rules.suggestion)

        rules.retryDeferredAutomatic()
        XCTAssertTrue(applied.isEmpty, "still not safe, so still just a banner")

        ready = true
        rules.retryDeferredAutomatic()
        XCTAssertEqual(applied, [4])
        XCTAssertNil(rules.suggestion)

        rules.retryDeferredAutomatic()
        XCTAssertEqual(applied, [4], "an automatic switch happens once")
    }

    @MainActor
    func testADismissedBannerIsNotRetriedAsAnAutomaticSwitch() {
        let rules = ProfileRules()
        rules.previewSet(rules: [twentyBandRule()])
        var ready = false
        rules.canApplyNow = { ready }
        var applied: [Int] = []
        rules.onApplyPreset = { applied.append($0); return true }
        rules.currentEqGroupRaw = QxEqGroup.b20.rawValue
        rules.outputChanged(uid: "uid-20", name: "Twenty")
        rules.dismissSuggestion()

        ready = true
        rules.retryDeferredAutomatic()

        XCTAssertTrue(applied.isEmpty)
        XCTAssertNil(rules.suggestion)
    }

    @MainActor
    func testARuleNeverSwitchesWhenThereIsNoCurrentOutput() {
        let rules = ProfileRules()
        rules.previewSet(rules: [twentyBandRule()])
        rules.canApplyNow = { true }
        var applied: [Int] = []
        rules.onApplyPreset = { applied.append($0); return true }

        rules.currentEqGroupRaw = QxEqGroup.b20.rawValue

        XCTAssertTrue(applied.isEmpty)
    }

    @MainActor
    func testBindingAKnownUIDReplacesRatherThanDuplicates() {
        let rules = ProfileRules()
        rules.bind(outputUID: "shared-uid", outputName: "USB-C to 3.5mm Adapter", presetIndex: 0)
        rules.bind(outputUID: "shared-uid", outputName: "USB-C to 3.5mm Adapter", presetIndex: 9)

        let matches = rules.rules.filter { $0.outputUID == "shared-uid" }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.presetIndex, 9)
    }

    @MainActor
    func testRemovingARuleAlsoClearsAMatchingPendingSuggestion() {
        let rules = ProfileRules()
        rules.bind(outputUID: "uid-6", outputName: "Cans", presetIndex: 4)
        rules.outputChanged(uid: "uid-6", name: "Cans")
        XCTAssertNotNil(rules.suggestion)

        rules.removeRule(outputUID: "uid-6")

        XCTAssertNil(rules.suggestion)
        XCTAssertTrue(rules.rules.isEmpty)
    }

    @MainActor
    func testSavedRulesLoadBackIdentically() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = [
            ProfileRule(outputUID: "uid-a", outputName: "Studio Cans", presetIndex: 2,
                       eqGroupRaw: QxEqGroup.user.rawValue, confirmed: true, automatic: true),
            ProfileRule(outputUID: "uid-b", outputName: "Travel IEMs", presetIndex: 11,
                        eqGroupRaw: QxEqGroup.b20.rawValue),
        ]

        ProfileRulesFile.save(original, to: url)
        let loaded = ProfileRulesFile.load(from: url)

        XCTAssertEqual(loaded, original)
    }

    func testAFileWrittenBeforeGroupsWereRecordedStillLoads() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        [
          {
            "automatic" : true,
            "confirmed" : true,
            "outputName" : "Studio Cans",
            "outputUID" : "uid-old",
            "presetIndex" : 2
          }
        ]
        """
        try? json.data(using: .utf8)?.write(to: url)

        let loaded = ProfileRulesFile.load(from: url)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.outputUID, "uid-old")
        XCTAssertEqual(loaded.first?.presetIndex, 2)
        XCTAssertEqual(loaded.first?.automatic, true)
        XCTAssertNil(loaded.first?.eqGroupRaw,
                     "no group was recorded, and inventing one would be a guess")
        XCTAssertEqual(loaded.first?.standing(inGroup: QxEqGroup.user.rawValue), .unmarked)
    }

    func testAGroupTheDeviceHasNoSuchBankForIsDroppedToUnmarked() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        [{"outputUID":"uid-w","outputName":"Something","presetIndex":1,"eqGroupRaw":200}]
        """
        try? json.data(using: .utf8)?.write(to: url)

        let loaded = ProfileRulesFile.load(from: url)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertNil(loaded.first?.eqGroupRaw)
    }

    func testOneBadRecordCostsOnlyThatRecordAndTheOriginalIsKept() {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        let json = """
        [{"outputUID":"uid-1","outputName":"First","presetIndex":1},
         {"outputUID":"uid-2","outputName":"Broken","presetIndex":"2"},
         {"outputUID":"uid-3","outputName":"Third","presetIndex":3,"confirmed":true}]
        """
        try? json.data(using: .utf8)?.write(to: url)

        let loaded = ProfileRulesFile.load(from: url)

        XCTAssertEqual(loaded.map(\.outputUID), ["uid-1", "uid-3"])
        XCTAssertEqual(loaded.last?.confirmed, true)
        XCTAssertEqual(try? String(contentsOf: parkedURL(url), encoding: .utf8), json)
    }

    func testACleanFileIsNotParked() {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        ProfileRulesFile.save([ProfileRule(outputUID: "uid-a", outputName: "A", presetIndex: 2)],
                              to: url)

        XCTAssertEqual(ProfileRulesFile.load(from: url).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parkedURL(url).path))
    }

    func testAnObjectInsteadOfAListIsParkedWholeAndNothingIsLoaded() {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        let json = #"{"schemaVersion":2,"rules":[{"outputUID":"u","presetIndex":1}]}"#
        try? json.data(using: .utf8)?.write(to: url)

        XCTAssertEqual(ProfileRulesFile.load(from: url), [])
        XCTAssertEqual(try? String(contentsOf: parkedURL(url), encoding: .utf8), json)
    }

    func testAFailedSaveReportsFalseAndLeavesTheOldFileAlone() throws {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        let first = [ProfileRule(outputUID: "uid-a", outputName: "A", presetIndex: 2)]
        XCTAssertTrue(ProfileRulesFile.save(first, to: url))
        let missing = sandbox.appendingPathComponent("no-such-folder/profiles.json")

        XCTAssertFalse(ProfileRulesFile.save(first, to: missing))
        XCTAssertEqual(ProfileRulesFile.load(from: url), first)
    }

    @MainActor
    func testAFailedSaveIsFlaggedOnceAndClearsWhenWritingWorksAgain() throws {
        let missingFolder = sandbox.appendingPathComponent("not-yet", isDirectory: true)
        ProfileRulesFile.urlOverride = missingFolder.appendingPathComponent("profiles.json")
        let rules = ProfileRules()

        rules.bind(outputUID: "uid-1", outputName: "One", presetIndex: 1)
        XCTAssertTrue(rules.lastSaveFailed)
        rules.bind(outputUID: "uid-2", outputName: "Two", presetIndex: 2)
        XCTAssertTrue(rules.lastSaveFailed)
        XCTAssertEqual(rules.rules.count, 2, "the rules stay live in memory")

        try FileManager.default.createDirectory(at: missingFolder,
                                                withIntermediateDirectories: true)
        rules.bind(outputUID: "uid-3", outputName: "Three", presetIndex: 3)
        XCTAssertFalse(rules.lastSaveFailed)
        XCTAssertEqual(ProfileRulesFile.load().count, 3)
    }

    func testTwoDifferentDamagedFilesKeepTwoCopies() throws {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        let candidates = ParkedCopy.candidates(beside: url)

        try Data("[ first damage".utf8).write(to: url)
        XCTAssertEqual(ProfileRulesFile.load(from: url), [])
        try Data("[ second damage".utf8).write(to: url)
        XCTAssertEqual(ProfileRulesFile.load(from: url), [])
        XCTAssertEqual(ProfileRulesFile.load(from: url), [])

        XCTAssertEqual(try String(contentsOf: candidates[0], encoding: .utf8), "[ first damage")
        XCTAssertEqual(try String(contentsOf: candidates[1], encoding: .utf8), "[ second damage")
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidates[2].path))
    }

    func testMissingFileLoadsAsEmptyRatherThanThrowing() {
        let url = tempFileURL()
        XCTAssertEqual(ProfileRulesFile.load(from: url), [])
    }

    func testGarbageJSONLoadsAsEmptyAndParksTheOriginal() {
        let url = tempFileURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("recovered"))
        }
        try? "{ this is not valid JSON at all".data(using: .utf8)?.write(to: url)

        let loaded = ProfileRulesFile.load(from: url)

        XCTAssertEqual(loaded, [])
        let parked = URL(fileURLWithPath: url.path + ".recovered")
        XCTAssertTrue(FileManager.default.fileExists(atPath: parked.path),
                     "a corrupt file must be parked for recovery, not silently destroyed")
    }

    func testOversizedFileIsRefusedOutright() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let huge = String(repeating: "x", count: 5_000_000)
        try? huge.data(using: .utf8)?.write(to: url)

        XCTAssertEqual(ProfileRulesFile.load(from: url), [])
    }

    func testHandEditedFileWithOutOfRangePresetIndexIsDropped() {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        let json = """
        [{"outputUID":"uid-x","outputName":"Something","presetIndex":999}]
        """
        try? json.data(using: .utf8)?.write(to: url)

        XCTAssertEqual(ProfileRulesFile.load(from: url), [])
        XCTAssertEqual(try? String(contentsOf: parkedURL(url), encoding: .utf8), json,
                       "a rule the loader drops leaves the original file beside it")
    }

    func testHandEditedFileClaimingAutomaticWithoutConfirmedIsScrubbed() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        [{"outputUID":"uid-y","outputName":"Something","presetIndex":1,
          "confirmed":false,"automatic":true}]
        """
        try? json.data(using: .utf8)?.write(to: url)

        let loaded = ProfileRulesFile.load(from: url)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.automatic, false,
                       "automatic must never survive loading without confirmed")
    }

    func testHandEditedFileWithDuplicateUIDsCollapsesToOneRule() {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        let json = """
        [{"outputUID":"dup","outputName":"First","presetIndex":0},
         {"outputUID":"dup","outputName":"Second","presetIndex":8}]
        """
        try? json.data(using: .utf8)?.write(to: url)

        let loaded = ProfileRulesFile.load(from: url)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.presetIndex, 0, "first entry for a UID wins")
    }

    func testHandEditedFileMissingOptionalFieldsStillLoads() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        [{"outputUID":"uid-z","presetIndex":6}]
        """
        try? json.data(using: .utf8)?.write(to: url)

        let loaded = ProfileRulesFile.load(from: url)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.outputUID, "uid-z")
        XCTAssertEqual(loaded.first?.presetIndex, 6)
        XCTAssertEqual(loaded.first?.outputName, "")
        XCTAssertEqual(loaded.first?.confirmed, false)
    }

    func testRuleListIsCappedRatherThanGrowingWithoutBound() {
        let url = tempFileURL()
        defer { removeWithParkedCopy(url) }
        let many = (0..<500).map {
            ProfileRule(outputUID: "uid-\($0)", outputName: "Output \($0)", presetIndex: $0 % 20)
        }
        try? JSONEncoder().encode(many).write(to: url)

        let loaded = ProfileRulesFile.load(from: url)

        XCTAssertEqual(loaded.count, ProfileRulesFile.maxRules)
    }
}

