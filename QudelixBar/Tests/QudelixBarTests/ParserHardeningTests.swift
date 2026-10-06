import XCTest
@testable import QudelixBar

final class ParserHardeningTests: XCTestCase {
    private func elapsed(_ work: () -> Void) -> Duration {
        (0..<5).map { _ in ContinuousClock().measure(work) }.min() ?? .zero
    }

    private func warmUp() {
        _ = ParametricEQFile.parse("""
            Preamp: -1 dB
            Filter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1
            Filter 2: ON HPQ Fc 30 Hz Q 0.7
            Filter 3: OFF PK Fc 1000 Hz Gain 1 dB Q 1
            """)
    }

    private func hostileLines(width: Int = ParametricEQFile.maxLineLength) -> [String] {
        let spaces = { (n: Int) in String(repeating: " ", count: max(0, n)) }
        return [
            "Filter" + spaces(width - 7) + "X",
            "Filter" + String(repeating: "\t", count: width - 7) + "X",
            "Preamp" + spaces(width - 7) + "x",
            "Preamp:" + spaces(width - 8) + "x",
            "Filter 1:" + spaces(width - 20) + "ON PK Fc x",
            "Filter 1" + spaces((width - 12) / 2) + ":" + spaces((width - 12) / 2) + "X",
            "Filter 1: ON PK Fc" + spaces(width - 25) + "x",
            "Filter 1: ON PK Fc 1 Hz Gain " + String(repeating: "1", count: width - 40) + " x",
            String(repeating: "Filter ", count: width / 7),
            String(repeating: "Preamp ", count: width / 7),
        ]
    }

    func testAHostileSpaceRunOnOneLineParsesInWellUnderFiftyMilliseconds() {
        warmUp()
        for line in hostileLines() {
            XCTAssertLessThanOrEqual(line.count, ParametricEQFile.maxLineLength)
            var parsed: ParametricEQFile?
            let took = elapsed { parsed = ParametricEQFile.parse(line) }
            XCTAssertNil(parsed, "nothing in a hostile line is a filter: \(line.prefix(24))")
            XCTAssertLessThan(took, .milliseconds(50), "\(line.prefix(24)) took \(took)")
        }
    }

    func testASixtyFourKilobyteFileOfHostileLinesParsesInWellUnderFiftyMilliseconds() {
        warmUp()
        let line = "Filter" + String(repeating: " ", count: ParametricEQFile.maxLineLength - 7) + "X"
        let text = Array(repeating: line, count: 16).joined(separator: "\n")
        XCTAssertGreaterThanOrEqual(text.utf8.count, 64 * 1024)
        var parsed: ParametricEQFile?
        let took = elapsed { parsed = ParametricEQFile.parse(text) }
        XCTAssertNil(parsed)
        XCTAssertLessThan(took, .milliseconds(50), "took \(took)")
    }

    func testASingleSixtyFourKilobyteLineIsRefusedOutright() {
        warmUp()
        let line = "Filter" + String(repeating: " ", count: 64 * 1024) + "X"
        var parsed: ParametricEQFile?
        let took = elapsed { parsed = ParametricEQFile.parse(line) }
        XCTAssertNil(parsed)
        XCTAssertLessThan(took, .milliseconds(50), "took \(took)")
    }

    func testHostileLinesDoNotStopRealFiltersAroundThemFromImporting() {
        warmUp()
        let hostile = hostileLines().joined(separator: "\n")
        let text = "Preamp: -3 dB\n" + hostile
            + "\nFilter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.0\n"
        var parsed: ParametricEQFile?
        let took = elapsed { parsed = ParametricEQFile.parse(text) }
        XCTAssertEqual(parsed?.bands.count, 1)
        XCTAssertEqual(parsed?.preamp, -3)
        XCTAssertLessThan(took, .milliseconds(50), "took \(took)")
    }

    func testEveryLegitimateFilterLineLayoutParsesToTheSameBand() {
        let layouts = [
            "Filter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q 1.00",
            "Filter: ON PK Fc 1000 Hz Gain 3.0 dB Q 1.00",
            "Filter 12 : ON PK Fc 1000 Hz Gain 3.0 dB Q 1.00",
            "filter ON PK Fc 1000 Hz Gain 3.0 dB Q 1.00",
            "Filter1:ON PK Fc 1000 Hz Gain 3.0 dB Q 1.00",
            "FILTER 3 ON PK FC 1000 HZ GAIN 3.0 DB Q 1.00",
            "Filter  1:\tON\tPK\tFc\t1000\tHz\tGain\t3.0\tdB\tQ\t1.00",
            "  Filter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q 1.00  ",
        ]
        for layout in layouts {
            let band = ParametricEQFile.parse(layout)?.bands.first
            XCTAssertEqual(band?.filter, .peak, layout)
            XCTAssertEqual(band?.freq, 1000, layout)
            XCTAssertEqual(band?.gain, 3.0, layout)
            XCTAssertEqual(band?.q, 1.0, layout)
        }
    }

    func testEveryLegitimatePassFilterLayoutParsesToTheSameBand() {
        let layouts = [
            "Filter 1: ON HPQ Fc 30 Hz Q 0.70",
            "Filter: ON HPQ Fc 30 Hz Q 0.70",
            "Filter 12 : ON HPQ Fc 30 Hz Q 0.70",
            "filter ON HPQ Fc 30 Hz Q 0.70",
            "Filter1:ON HPQ Fc 30 Hz Q 0.70",
        ]
        for layout in layouts {
            let band = ParametricEQFile.parse(layout)?.bands.first
            XCTAssertEqual(band?.filter, .hpf, layout)
            XCTAssertEqual(band?.freq, 30, layout)
            XCTAssertEqual(band?.q, 0.7, layout)
        }
    }

    func testEveryLegitimatePreampLayoutParsesToTheSameValue() {
        let layouts = [
            "Preamp: -6.1 dB", "Preamp -6.1 dB", "Preamp:-6.1dB", "preamp : -6.1 db",
            "PREAMP:   -6.1   DB", "Preamp: -6,1 dB",
        ]
        for layout in layouts {
            let file = ParametricEQFile.parse(layout + "\nFilter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1")
            XCTAssertEqual(file?.preamp ?? 0, -6.1, accuracy: 1e-9, layout)
        }
    }

    func testOffSwitchesAreSkippedQuietlyInEveryLayout() {
        let file = ParametricEQFile.parse("""
            Filter 1: OFF PK Fc 1000 Hz Gain 3.0 dB Q 1.00
            Filter: OFF PK Fc 1000 Hz Gain 3.0 dB Q 1.00
            Filter 12 : OFF BP Fc 1000 Hz Gain 3.0 dB Q 1.00
            filter OFF PK Fc 1000 Hz Gain 3.0 dB Q 1.00
            Filter1:OFF PK Fc 1000 Hz Gain 3.0 dB Q 1.00
            Filter 6: ON PK Fc 2000 Hz Gain 1.0 dB Q 1.00
            """)
        XCTAssertEqual(file?.bands.count, 1)
        XCTAssertEqual(file?.notes, [])
    }

    func testACommaDecimalPreampIsReadLikeADotOne() {
        let file = ParametricEQFile.parse("""
            Preamp: -6,1 dB
            Filter 1: ON PK Fc 1000 Hz Gain 3,5 dB Q 0,70
            """)
        XCTAssertEqual(file?.preamp ?? 0, -6.1, accuracy: 1e-9)
        XCTAssertEqual(file?.bands.first?.gain ?? 0, 3.5, accuracy: 1e-9)
        XCTAssertEqual(file?.bands.first?.q ?? 0, 0.7, accuracy: 1e-9)
        XCTAssertEqual(file?.notes, [])
    }

    func testAPreampLineThatCannotBeReadIsReportedNotIgnored() {
        let file = ParametricEQFile.parse("""
            Preamp: loud dB
            Preamp: 1.2.3 dB
            Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1
            """)
        XCTAssertEqual(file?.preamp, 0)
        XCTAssertTrue(file?.notes.contains { $0.contains("2 Preamp lines that could not be read") } ?? false,
                      "\(file?.notes ?? [])")
    }

    func testThousandsGroupedCentreFrequenciesAreNotReadAsHertz() {
        let file = ParametricEQFile.parse("""
            Filter 1: ON PK Fc 1,000 Hz Gain 3 dB Q 1
            Filter 2: ON PK Fc 10,000 Hz Gain 3 dB Q 1
            Filter 3: ON PK Fc 105,5 Hz Gain 3 dB Q 1
            Filter 4: ON PK Fc 2.500 Hz Gain 3 dB Q 1
            Filter 5: ON PK Fc 20,000 Hz Gain 3 dB Q 1
            """)
        XCTAssertEqual(file?.bands.map(\.freq), [1000, 10000, 106, 3, 20000])
    }

    func testABandwidthInOctavesBecomesTheEquivalentQ() throws {
        let file = try XCTUnwrap(ParametricEQFile.parse("""
            Filter 1: ON PK Fc 1000 Hz Gain -3 dB BW Oct 1.0
            Filter 2: ON PK Fc 2000 Hz Gain -3 dB BW Oct 2.0
            Filter 3: ON PK Fc 3000 Hz Gain -3 dB bw oct 0,5
            """))
        XCTAssertEqual(file.bands[0].q, 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(file.bands[1].q, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(file.bands[2].q, 2.0.squareRoot().squareRoot() / (2.0.squareRoot() - 1),
                       accuracy: 1e-9)
        XCTAssertEqual(file.notes, [])
    }

    func testANonsenseBandwidthSkipsTheLineAndSaysSo() {
        let file = ParametricEQFile.parse("""
            Filter 1: ON PK Fc 1000 Hz Gain -3 dB BW Oct 0
            Filter 2: ON PK Fc 2000 Hz Gain -3 dB BW Oct 1.2.3
            Filter 3: ON PK Fc 3000 Hz Gain -3 dB Q 1
            """)
        XCTAssertEqual(file?.bands.map(\.freq), [3000])
        XCTAssertTrue(file?.notes.contains { $0.contains("skipped 2 filter lines") } ?? false,
                      "\(file?.notes ?? [])")
    }

    func testAPeakWithNeitherQNorBandwidthIsImportedAndSaidOutLoud() {
        let file = ParametricEQFile.parse("""
            Filter 1: ON PK Fc 1000 Hz Gain -3 dB
            Filter 2: ON LSC Fc 105 Hz Gain 3 dB
            """)
        XCTAssertEqual(file?.bands.count, 2)
        XCTAssertEqual(file?.bands.first?.q, ParametricEQFile.defaultShelfQ)
        XCTAssertEqual(file?.notes, ["1 peak filter has no Q or bandwidth — Q 0.71 assumed"])
    }

    func testOffFilterLinesAreNotReportedAsUnsupported() {
        let file = ParametricEQFile.parse("""
            Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1
            Filter 2: OFF PK Fc 2000 Hz Gain 3 dB Q 1
            Filter 3: OFF
            """)
        XCTAssertEqual(file?.bands.count, 1)
        XCTAssertEqual(file?.notes, [])
    }

    func testAFileOfOnlyOffFiltersHasNothingToImport() {
        XCTAssertNil(ParametricEQFile.parse("Filter 1: OFF PK Fc 2000 Hz Gain 3 dB Q 1"))
    }

    func testSeveralPreampLinesAreAddedTogetherAndSaid() {
        let file = ParametricEQFile.parse("""
            Preamp: -3 dB
            Preamp: -2 dB
            Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1
            """)
        XCTAssertEqual(file?.preamp, -5)
        XCTAssertEqual(file?.notes, ["2 Preamp lines were added together"])
    }

    func testTheSummedPreampIsStillBoundedByTheSanityLimit() {
        let file = ParametricEQFile.parse("""
            Preamp: -20 dB
            Preamp: -20 dB
            Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1
            """)
        XCTAssertEqual(file?.preamp, -24)
    }

    func testAByteOrderMarkAtTheStartOfTheTextIsIgnored() {
        let file = ParametricEQFile.parse("\u{FEFF}Preamp: -3 dB\nFilter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1")
        XCTAssertEqual(file?.preamp, -3)
        XCTAssertEqual(file?.bands.count, 1)
    }
}
