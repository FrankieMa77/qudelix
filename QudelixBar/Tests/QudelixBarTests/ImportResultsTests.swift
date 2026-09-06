import XCTest
@testable import QudelixBar

@MainActor
final class ImportResultsTests: XCTestCase {

    private func entries(_ titles: [String]) -> [AutoEqEntry] {
        titles.map { AutoEqEntry(title: $0, source: "oratory1990", path: "\($0).txt") }
    }

    private func seededIndex(_ titles: [String], query: String = "") -> AutoEqIndex {
        let index = AutoEqIndex()
        index.seedForPreview(entries(titles), query: query)
        return index
    }

    private let catalogue = [
        "Sennheiser HD 650", "Sennheiser HD 600", "Sennheiser HD 660S",
        "HiFiMan Sundara", "Beyerdynamic DT 990", "Focal Clear",
        "Audeze LCD-2", "AKG K371", "Sony WH-1000XM4", "Apple AirPods Max",
    ]

    func testTheRowsDependOnNothingButTheQueryAndTheCatalogue() {
        let index = seededIndex(catalogue)
        let first = index.search("hd")
        XCTAssertFalse(first.isEmpty)
        for _ in 0..<20 {
            XCTAssertEqual(index.search("hd"), first,
                           "repeating the search must not reshuffle the list")
        }
        XCTAssertEqual(index.search("HD"), first, "the search is case-insensitive")
        XCTAssertNotEqual(index.search("sundara"), first)
    }

    func testPrefixMatchesStayAheadOfTheRest() {
        let index = seededIndex(["Clear HD", "Sennheiser HD 650", "HD 800 S"])
        let rows = index.search("hd")
        XCTAssertEqual(rows.map(\.title), ["HD 800 S", "Clear HD", "Sennheiser HD 650"])
    }

    func testAGrowingCatalogueChangesTheRowsAndIsTheOnlyOtherThingThatCan() {
        let index = seededIndex(catalogue)
        let before = index.search("sennheiser")
        XCTAssertEqual(before.count, 3)
        index.seedForPreview(entries(catalogue + ["Sennheiser HD 800 S"]), query: "")
        XCTAssertEqual(index.search("sennheiser").count, 4)
    }

    func testTheOverflowCaptionCountsTheSameListTheRowsCameFrom() {
        let many = (0..<40).map { "Sennheiser HD \(600 + $0)" }
        let index = seededIndex(many)
        let rows = index.search("sennheiser")
        XCTAssertEqual(rows.count, 40)
        XCTAssertEqual(rows.prefix(AutoEqIndex.displayLimit).count, AutoEqIndex.displayLimit)
        XCTAssertEqual(rows.count - AutoEqIndex.displayLimit, 34)
        XCTAssertEqual(index.search("sennheiser").count, rows.count)
    }

    func testAnEmptyQueryMatchesNothingSoTheCountLineIsShownInstead() {
        let index = seededIndex(catalogue)
        XCTAssertTrue(index.search("").isEmpty)
        XCTAssertTrue(index.search("   ").isEmpty)
        XCTAssertEqual(index.entries.count, catalogue.count)
    }

    func testASecondCorrectionCannotStartWhileOneIsInFlight() {
        var gate = ImportApplyGate()
        XCTAssertFalse(gate.isBusy)

        XCTAssertTrue(gate.begin("hd650"))
        XCTAssertTrue(gate.isBusy)
        XCTAssertTrue(gate.isApplying("hd650"))

        XCTAssertFalse(gate.begin("sundara"), "the slower fetch must never get to win")
        XCTAssertFalse(gate.begin("hd650"), "not even the same row twice")
        XCTAssertTrue(gate.isApplying("hd650"))
        XCTAssertFalse(gate.isApplying("sundara"))
    }

    func testTheGateReopensWhenTheFetchThatHeldItFinishes() {
        var gate = ImportApplyGate()
        XCTAssertTrue(gate.begin("hd650"))
        gate.finish("hd650")
        XCTAssertFalse(gate.isBusy)
        XCTAssertTrue(gate.begin("sundara"))
        XCTAssertTrue(gate.isApplying("sundara"))
    }

    func testAFinishFromSomethingElseCannotOpenTheGate() {
        var gate = ImportApplyGate()
        XCTAssertTrue(gate.begin("hd650"))
        gate.finish("sundara")
        XCTAssertTrue(gate.isApplying("hd650"))
        XCTAssertFalse(gate.begin("sundara"))
    }
}
