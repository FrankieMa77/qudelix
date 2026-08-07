import XCTest
@testable import QudelixBar

/// Profile auto-switching: rule matching, the durable-identifier collision
/// case, persistence round-trip, hostile files, and the confirm-vs-automatic
/// decision. Nothing here touches CoreAudio or the device — `ProfileRules`
/// is driven directly through `outputChanged(uid:name:)`, and persistence is
/// driven through `ProfileRulesFile`'s own `from:`/`to:` overrides, so both
/// are exercised exactly as a headless test can.
final class ProfileRulesTests: XCTestCase {

    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-rules-test-\(UUID().uuidString).json")
    }

    // MARK: - Rule matching

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

        // `bind` itself never runs the matching logic — it only records the
        // pairing — so this is the first `outputChanged` this instance sees.
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

        // Same device, no change — must not re-nag.
        rules.outputChanged(uid: "uid-1", name: "Studio Cans")
        XCTAssertNil(rules.suggestion)
    }

    // MARK: - Confirm vs. automatic

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
        // Unwired canApplyNow reads as "never safe" — e.g. mid-edit, or a
        // custom curve with nowhere to fall back to silently.
        rules.canApplyNow = { false }
        var applied: [Int] = []
        rules.onApplyPreset = { applied.append($0); return true }

        rules.outputChanged(uid: "uid-5", name: "Night Setup")

        XCTAssertTrue(applied.isEmpty, "must not apply silently when it isn't safe to")
        XCTAssertEqual(rules.suggestion?.outputUID, "uid-5",
                       "the switch is still offered, just not done unannounced")
    }

    /// A load the write path refuses must not be recorded as a switch that
    /// happened. `confirmed` is the single gate that later allows an output to
    /// switch presets silently, so earning it on a write nobody performed
    /// would arm the feature on the strength of nothing.
    @MainActor
    func testARefusedApplyDoesNotConfirmTheRule() {
        let rules = ProfileRules()
        rules.previewSet(rules: [ProfileRule(outputUID: "uid-r", outputName: "Refused",
                                             presetIndex: 6)])
        var attempts = 0
        rules.onApplyPreset = { _ in attempts += 1; return false }   // device refused

        rules.outputChanged(uid: "uid-r", name: "Refused")
        XCTAssertNotNil(rules.suggestion)
        rules.confirmSuggestion()

        XCTAssertEqual(attempts, 1, "it should still have tried")
        XCTAssertEqual(rules.rules.first?.confirmed, false,
                       "a refused switch must not unlock automatic switching")
        XCTAssertNotNil(rules.suggestion,
                        "the offer stays up so the user can see it did not take")
    }

    /// An automatic rule whose write is refused falls back to asking, rather
    /// than leaving the previous headphone's preset running and saying nothing.
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

    // MARK: - Durable-identifier collisions

    /// Two physically different adapters can legitimately report the same
    /// CoreAudio UID (common on cheap, serial-less USB-C dongles) — the
    /// brief for this feature calls this out explicitly rather than
    /// pretending the identifier is unique. `bind` must not grow a second,
    /// disagreeing rule for a UID that's already known: it replaces.
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

    // MARK: - Persistence round-trip

    @MainActor
    func testSavedRulesLoadBackIdentically() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = [
            ProfileRule(outputUID: "uid-a", outputName: "Studio Cans", presetIndex: 2,
                       confirmed: true, automatic: true),
            ProfileRule(outputUID: "uid-b", outputName: "Travel IEMs", presetIndex: 11),
        ]

        ProfileRulesFile.save(original, to: url)
        let loaded = ProfileRulesFile.load(from: url)

        XCTAssertEqual(loaded, original)
    }

    // MARK: - Hostile / corrupted files

    func testMissingFileLoadsAsEmptyRatherThanThrowing() {
        let url = tempFileURL()   // never written
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
        // Larger than the read cap — a well-formed document this big is not
        // plausibly ours, and reading it fully into memory is the wrong move
        // regardless of what it contains.
        let huge = String(repeating: "x", count: 5_000_000)
        try? huge.data(using: .utf8)?.write(to: url)

        XCTAssertEqual(ProfileRulesFile.load(from: url), [])
    }

    func testHandEditedFileWithOutOfRangePresetIndexIsDropped() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        [{"outputUID":"uid-x","outputName":"Something","presetIndex":999}]
        """
        try? json.data(using: .utf8)?.write(to: url)

        XCTAssertEqual(ProfileRulesFile.load(from: url), [])
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
        defer { try? FileManager.default.removeItem(at: url) }
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
        // No outputName, confirmed, or automatic — only the load-bearing
        // fields a rule can't function without.
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
        defer { try? FileManager.default.removeItem(at: url) }
        let many = (0..<500).map {
            ProfileRule(outputUID: "uid-\($0)", outputName: "Output \($0)", presetIndex: $0 % 20)
        }
        try? JSONEncoder().encode(many).write(to: url)

        let loaded = ProfileRulesFile.load(from: url)

        XCTAssertEqual(loaded.count, ProfileRulesFile.maxRules)
    }
}

