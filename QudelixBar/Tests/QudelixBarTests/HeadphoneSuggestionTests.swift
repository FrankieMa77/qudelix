import XCTest
@testable import QudelixBar

@MainActor
final class FakeHeadphoneCatalogue: HeadphoneCatalogue {
    var catalogueEntries: [AutoEqEntry] = []
    var catalogueReady = false
    var catalogueFailed = false
    private(set) var loads = 0

    func loadCatalogue() { loads += 1 }
}

@MainActor
final class HeadphoneSuggestionTests: XCTestCase {

    private func entry(_ title: String, _ source: String) -> AutoEqEntry {
        AutoEqEntry(title: title, source: source,
                    path: "\(source)/over-ear/\(title.replacingOccurrences(of: " ", with: "%20"))")
    }

    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("suggest-\(UUID().uuidString).json")
    }

    private func library(at url: URL) -> PresetLibrary {
        let library = PresetLibrary()
        library.start(fileURL: url)
        return library
    }

    private func engine(_ library: PresetLibrary,
                        _ catalogue: FakeHeadphoneCatalogue) -> HeadphoneSuggestions {
        let engine = HeadphoneSuggestions(library: library, catalogue: catalogue)
        engine.pollAttempts = 3
        engine.pollInterval = .milliseconds(1)
        return engine
    }

    func testNormalisationKeepsOnlyLettersAndDigits() {
        XCTAssertEqual(HeadphoneSuggestions.normalized("Sennheiser HD 650!"),
                       "sennheiserhd650")
        XCTAssertEqual(HeadphoneSuggestions.normalized("  hd-650  "), "hd650")
        XCTAssertEqual(HeadphoneSuggestions.normalized("— · —"), "")
    }

    func testShortNamesNeverMatch() {
        let entries = [entry("Sennheiser HD 650", "oratory1990")]
        XCTAssertTrue(HeadphoneSuggestions.matches(for: "HD", in: entries).isEmpty)
        XCTAssertTrue(HeadphoneSuggestions.matches(for: "6 5", in: entries).isEmpty)
        XCTAssertEqual(HeadphoneSuggestions.matches(for: "HD 650", in: entries).count, 1)
    }

    func testContainmentWorksInBothDirections() {
        let entries = [entry("Marshall Major IV", "rtings"),
                       entry("HD 6", "oratory1990")]
        XCTAssertEqual(HeadphoneSuggestions.matches(for: "MAJOR IV", in: entries)
            .map(\.title), ["Marshall Major IV"])
        XCTAssertEqual(HeadphoneSuggestions.matches(for: "Sennheiser HD 6", in: entries)
            .map(\.title), ["HD 6"])
    }

    func testEntriesWithNoLettersOrDigitsNeverMatchEverything() {
        let entries = [entry("— —", "oratory1990"),
                       entry("Sennheiser HD 650", "oratory1990")]
        XCTAssertEqual(HeadphoneSuggestions.matches(for: "Sennheiser HD 650", in: entries)
            .map(\.title), ["Sennheiser HD 650"])
    }

    func testRankingPrefersMeasurementSourceThenNameCloseness() {
        let entries = [entry("Sennheiser HD 650 Special", "rtings"),
                       entry("Sennheiser HD 650", "crinacle"),
                       entry("Sennheiser HD 650 Reissue", "oratory1990"),
                       entry("Sennheiser HD 650", "oratory1990")]
        XCTAssertEqual(
            HeadphoneSuggestions.matches(for: "Sennheiser HD 650", in: entries)
                .map { "\($0.title)/\($0.source)" },
            ["Sennheiser HD 650/oratory1990",
             "Sennheiser HD 650 Reissue/oratory1990",
             "Sennheiser HD 650/crinacle",
             "Sennheiser HD 650 Special/rtings"])
    }

    func testTiesBreakDeterministicallyOnTitle() {
        let a = [entry("Sennheiser HD 650 B", "oratory1990"),
                 entry("Sennheiser HD 650 A", "oratory1990")]
        let b = [entry("Sennheiser HD 650 A", "oratory1990"),
                 entry("Sennheiser HD 650 B", "oratory1990")]
        let wanted = ["Sennheiser HD 650 A", "Sennheiser HD 650 B"]
        XCTAssertEqual(HeadphoneSuggestions.matches(for: "Sennheiser HD 650", in: a)
            .map(\.title), wanted)
        XCTAssertEqual(HeadphoneSuggestions.matches(for: "Sennheiser HD 650", in: b)
            .map(\.title), wanted)
    }

    func testSourceRankOrdersTheTwoNamedSourcesFirst() {
        XCTAssertEqual(HeadphoneSuggestions.sourceRank("oratory1990"), 0)
        XCTAssertEqual(HeadphoneSuggestions.sourceRank("Crinacle"), 1)
        XCTAssertEqual(HeadphoneSuggestions.sourceRank("rtings"), 2)
    }

    func testOffersOnceAndKeepsTheNameOutOfTheDiagnostic() async {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let library = library(at: url)
        let catalogue = FakeHeadphoneCatalogue()
        catalogue.catalogueEntries = [entry("Sennheiser HD 650", "oratory1990")]
        catalogue.catalogueReady = true
        let engine = engine(library, catalogue)

        engine.nameChanged("Sennheiser HD 650")
        XCTAssertEqual(engine.diagSummary, "suggest=pending")
        await engine.resolveTask?.value

        XCTAssertEqual(engine.banner?.entry.title, "Sennheiser HD 650")
        XCTAssertEqual(engine.match?.entry.title, "Sennheiser HD 650")
        XCTAssertEqual(engine.diagSummary, "suggest=offered")
        XCTAssertFalse(engine.diagSummary.lowercased().contains("sennheiser"))
        XCTAssertEqual(library.suggestedHeadphones, ["sennheiserhd650"])

        engine.dismiss()
        XCTAssertNil(engine.banner)
        XCTAssertNotNil(engine.match)

        engine.nameChanged("Something Else Entirely")
        await engine.resolveTask?.value
        engine.nameChanged("Sennheiser HD 650")
        XCTAssertNil(engine.resolveTask)
        XCTAssertNil(engine.banner)
        XCTAssertNil(engine.match)
    }

    func testAMissStillCountsAsLookedUp() async {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let library = library(at: url)
        let catalogue = FakeHeadphoneCatalogue()
        catalogue.catalogueEntries = [entry("Sennheiser HD 650", "oratory1990")]
        catalogue.catalogueReady = true
        let engine = engine(library, catalogue)

        engine.nameChanged("Nothing Like It")
        await engine.resolveTask?.value

        XCTAssertNil(engine.banner)
        XCTAssertEqual(engine.diagSummary, "suggest=none")
        XCTAssertEqual(library.suggestedHeadphones, ["nothinglikeit"])
        XCTAssertEqual(catalogue.loads, 1)
    }

    func testAnUnloadedCatalogueDoesNotBurnTheSingleShot() async {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let library = library(at: url)
        let catalogue = FakeHeadphoneCatalogue()
        catalogue.catalogueEntries = [entry("Sennheiser HD 650", "oratory1990")]
        let engine = engine(library, catalogue)

        engine.nameChanged("Sennheiser HD 650")
        await engine.resolveTask?.value

        XCTAssertNil(engine.banner)
        XCTAssertTrue(library.suggestedHeadphones.isEmpty)
        XCTAssertFalse(library.hasSuggested("sennheiserhd650"))

        catalogue.catalogueReady = true
        engine.nameChanged("")
        engine.nameChanged("Sennheiser HD 650")
        await engine.resolveTask?.value
        XCTAssertEqual(engine.banner?.entry.title, "Sennheiser HD 650")
    }

    func testAFailedCatalogueDoesNotBurnTheSingleShotEither() async {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let library = library(at: url)
        let catalogue = FakeHeadphoneCatalogue()
        catalogue.catalogueFailed = true
        let engine = engine(library, catalogue)

        engine.nameChanged("Sennheiser HD 650")
        await engine.resolveTask?.value

        XCTAssertNil(engine.banner)
        XCTAssertTrue(library.suggestedHeadphones.isEmpty)
    }

    func testAlreadySuggestedNamesNeverTouchTheCatalogue() async {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let library = library(at: url)
        library.markSuggested("sennheiserhd650")
        let catalogue = FakeHeadphoneCatalogue()
        catalogue.catalogueEntries = [entry("Sennheiser HD 650", "oratory1990")]
        catalogue.catalogueReady = true
        let engine = engine(library, catalogue)

        engine.nameChanged("Sennheiser HD 650")
        XCTAssertNil(engine.resolveTask)
        XCTAssertEqual(catalogue.loads, 0)
        XCTAssertNil(engine.banner)
        XCTAssertEqual(engine.diagSummary, "suggest=none")
    }

    func testTooShortANameNeverTouchesTheCatalogue() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let library = library(at: url)
        let catalogue = FakeHeadphoneCatalogue()
        catalogue.catalogueReady = true
        let engine = engine(library, catalogue)

        engine.nameChanged("HD")
        XCTAssertNil(engine.resolveTask)
        XCTAssertEqual(catalogue.loads, 0)
        XCTAssertTrue(library.suggestedHeadphones.isEmpty)
    }

    func testOnlyThreeAlternativesAreOffered() async {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let library = library(at: url)
        let catalogue = FakeHeadphoneCatalogue()
        catalogue.catalogueEntries = [entry("Sennheiser HD 650", "oratory1990"),
                                      entry("Sennheiser HD 650", "crinacle"),
                                      entry("Sennheiser HD 650", "rtings"),
                                      entry("Sennheiser HD 650", "innerfidelity")]
        catalogue.catalogueReady = true
        let engine = engine(library, catalogue)

        engine.nameChanged("Sennheiser HD 650")
        await engine.resolveTask?.value

        XCTAssertEqual(engine.banner?.alternatives.count, 3)
        XCTAssertEqual(engine.banner?.alternatives.first?.source, "oratory1990")
        XCTAssertEqual(engine.banner?.entry, engine.banner?.alternatives.first)
    }

    func testBannerWording() {
        XCTAssertEqual(HeadphoneSuggestions.headline("Sennheiser HD 650"),
                       "Sennheiser HD 650 \u{2014} measured correction available")
        XCTAssertEqual(HeadphoneSuggestions.measuredBy("oratory1990"),
                       "Measured by oratory1990")
        XCTAssertEqual(HeadphoneSuggestions.bannerDetail(source: "crinacle", bandCount: 10),
                       "Measured by crinacle \u{2014} fitted to this device's 10 bands "
                       + "before anything is written.")
        XCTAssertEqual(HeadphoneSuggestions.notificationTitle("Sennheiser HD 650"),
                       "Correction available for Sennheiser HD 650")
        XCTAssertEqual(HeadphoneSuggestions.applyLinkLabel, "Apply correction")
        XCTAssertTrue(HeadphoneSuggestions.notificationBody.contains("AutoEq"))
    }

    func testWordingStripsControlCharactersFromCatalogueText() {
        XCTAssertEqual(HeadphoneSuggestions.headline("HD\n650"),
                       "HD650 \u{2014} measured correction available")
        XCTAssertEqual(HeadphoneSuggestions.measuredBy("orat\u{202E}ory1990"),
                       "Measured by oratory1990")
        XCTAssertFalse(HeadphoneSuggestions.notificationTitle("a\nb").contains("\n"))
    }
}
