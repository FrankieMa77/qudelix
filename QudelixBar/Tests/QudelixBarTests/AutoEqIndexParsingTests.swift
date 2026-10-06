import XCTest
@testable import QudelixBar

final class AutoEqIndexParsingTests: XCTestCase {
    private let readmeExcerpt = """
        # Recommended results
        [full index](./INDEX.md).
        [Equalizing Headphones the Easy Way](https://medium.com/@jaakkopasanen/x)
        [Headphone Ranking](./RANKING.md).

        - [1Custom SA02](./crinacle/711%20in-ear/1Custom%20SA02)
        - [1MORE Aero (ANC Off)](./HypetheSonics/GRAS%20RA0045%20in-ear/1MORE%20Aero%20(ANC%20Off))
        - [Beyerdynamic DT 770 (Alpha earpads)](./oratory1990/over-ear/Beyerdynamic%20DT%20770%20(Alpha%20earpads))
        - [Beyerdynamic DT 770 Pro (32 ohm Limited Edition, pleather earpads)](./Kuulokenurkka/over-ear/Beyerdynamic%20DT%20770%20Pro%20(32%20ohm%20Limited%20Edition,%20pleather%20earpads))
        - [HIFIMAN Sundara](./crinacle/GRAS%2043AG-7%20over-ear/HIFIMAN%20Sundara)
        - [HIFIMAN Sundara (2018)](./Innerfidelity/over-ear/HIFIMAN%20Sundara%20(2018))
        - [Sennheiser HD 600](./oratory1990/over-ear/Sennheiser%20HD%20600)
        - [Sennheiser HD 600 (2020)](./crinacle/GRAS%2043AG-7%20over-ear/Sennheiser%20HD%20600%20(2020))
        - [Sennheiser HD 600 (2020, worn earpads)](./crinacle/GRAS%2043AG-7%20over-ear/Sennheiser%20HD%20600%20(2020,%20worn%20earpads))
        - [Sony WH-1000XM4 (ANC on)](./HypetheSonics/over-ear/Sony%20WH-1000XM4%20(ANC%20on))
        """

    private let root = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results"

    func testTitlesWithParenthesesKeepTheirTitleSourceAndPath() throws {
        let entries = AutoEqIndex.parseIndex(readmeExcerpt)
        XCTAssertEqual(entries.count, 10)
        let hd600 = try XCTUnwrap(entries.first { $0.title == "Sennheiser HD 600 (2020)" })
        XCTAssertEqual(hd600.source, "crinacle")
        XCTAssertEqual(hd600.path,
                       "crinacle/GRAS%2043AG-7%20over-ear/Sennheiser%20HD%20600%20(2020)")
        XCTAssertEqual(hd600.presetURL?.absoluteString,
                       root + "/crinacle/GRAS%2043AG-7%20over-ear/Sennheiser%20HD%20600%20(2020)"
                       + "/Sennheiser%20HD%20600%20(2020)%20ParametricEQ.txt")
    }

    func testNoEntryIsLeftWithLinkSyntaxInItsSourceOrPath() {
        for entry in AutoEqIndex.parseIndex(readmeExcerpt) {
            XCTAssertFalse(entry.path.contains("]("), entry.path)
            XCTAssertFalse(entry.source.contains(")"), entry.source)
            XCTAssertFalse(entry.source.contains("]"), entry.source)
            XCTAssertNotNil(entry.presetURL, entry.title)
            XCTAssertTrue(entry.path.hasPrefix(entry.source.replacingOccurrences(of: " ", with: "%20")),
                          "\(entry.title) \(entry.path) \(entry.source)")
        }
    }

    func testATitleWithACommaInItsParenthesesStaysWhole() throws {
        let entries = AutoEqIndex.parseIndex(readmeExcerpt)
        let worn = try XCTUnwrap(entries.first { $0.title == "Sennheiser HD 600 (2020, worn earpads)" })
        XCTAssertEqual(worn.source, "crinacle")
        let limited = try XCTUnwrap(entries.first { $0.title.hasPrefix("Beyerdynamic DT 770 Pro (32 ohm") })
        XCTAssertEqual(limited.source, "Kuulokenurkka")
        XCTAssertEqual(limited.title,
                       "Beyerdynamic DT 770 Pro (32 ohm Limited Edition, pleather earpads)")
    }

    func testPlainTitlesAndDocumentLinksAreAsBefore() {
        let entries = AutoEqIndex.parseIndex(readmeExcerpt)
        XCTAssertEqual(entries.first?.title, "1Custom SA02")
        XCTAssertEqual(entries.first?.path, "crinacle/711%20in-ear/1Custom%20SA02")
        XCTAssertFalse(entries.contains { $0.title.contains("index") || $0.title.contains("Ranking") })
    }

    func testABracketInsideTheTitleDoesNotCutItShort() throws {
        let entries = AutoEqIndex.parseIndex(
            "- [Sony WH-1000XM4 [ANC]](./oratory1990/over-ear/Sony%20WH-1000XM4%20%5BANC%5D)")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.title, "Sony WH-1000XM4 [ANC]")
        XCTAssertEqual(entry.path, "oratory1990/over-ear/Sony%20WH-1000XM4%20%5BANC%5D")
    }

    func testTextAfterTheLinkIsIgnored() throws {
        let entries = AutoEqIndex.parseIndex(
            "- [Sennheiser HD 600 (2020)](./crinacle/over-ear/Sennheiser%20HD%20600%20(2020)) - 4.5 stars (new)")
        XCTAssertEqual(entries.first?.title, "Sennheiser HD 600 (2020)")
        XCTAssertEqual(entries.first?.path, "crinacle/over-ear/Sennheiser%20HD%20600%20(2020)")
    }

    func testMalformedLinesAreSkippedNotTrapped() {
        let junk = [
            "- [no link at all",
            "- [title](",
            "- [title]()",
            "- [](./a/b)",
            "- ](",
            "- [x](./a/b",
            "* [",
        ]
        XCTAssertNoThrow(junk.forEach { _ = AutoEqIndex.parseIndex($0) })
        XCTAssertTrue(AutoEqIndex.parseIndex("- [title](").isEmpty)
        XCTAssertTrue(AutoEqIndex.parseIndex("- [](./a/b)").isEmpty)
    }
}
