import XCTest
@testable import QudelixGtk

final class FileDialogTests: XCTestCase {
    func testTextFiltersOfferTextFilesThenEverything() {
        XCTAssertEqual(TextFileFilters.specs.map(\.name), ["Text files", "All files"])
        XCTAssertTrue(TextFileFilters.specs[1].suffixes.isEmpty)
    }

    func testTheTextFilterIgnoresCaseAndTheAllFilterTakesAnything() {
        let text = TextFileFilters.specs[0]
        let all = TextFileFilters.specs[1]
        XCTAssertTrue(TextFileFilters.matches("HD 650 ParametricEQ.txt", text))
        XCTAssertTrue(TextFileFilters.matches("PHONES.TXT", text))
        XCTAssertFalse(TextFileFilters.matches("curve.json", text))
        XCTAssertFalse(TextFileFilters.matches("txt", text))
        XCTAssertTrue(TextFileFilters.matches("anything.bin", all))
    }
}

final class EqTextFileFilterTests: XCTestCase {
    func testTheEqFilterIsFirstAndMatchesTxtIgnoringCaseThenEverything() {
        XCTAssertEqual(EqTextFileFilters.specs.map(\.name), ["EQ text (*.txt)", "All files"])
        let text = EqTextFileFilters.specs[0]
        XCTAssertTrue(EqTextFileFilters.matches("HD 650.TXT", text))
        XCTAssertFalse(EqTextFileFilters.matches("HD 650.json", text))
        XCTAssertTrue(EqTextFileFilters.matches("anything.bin", EqTextFileFilters.specs[1]))
    }
}

final class WavFileFilterTests: XCTestCase {
    func testWavFilterIsFirstAndMatchesBothSuffixesIgnoringCase() {
        XCTAssertEqual(WavFileFilters.specs.map(\.name), ["WAV files", "All files"])
        let wav = WavFileFilters.specs[0]
        XCTAssertTrue(WavFileFilters.matches("Room.WAV", wav))
        XCTAssertTrue(WavFileFilters.matches("hall.wave", wav))
        XCTAssertFalse(WavFileFilters.matches("hall.flac", wav))
        XCTAssertTrue(WavFileFilters.matches("hall.flac", WavFileFilters.specs[1]))
    }
}
