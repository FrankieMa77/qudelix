import XCTest
@testable import QudelixBar

final class ReferenceCurveTests: XCTestCase {
    private func file() -> ParametricEQFile {
        var f = ParametricEQFile()
        f.preamp = -4.5
        f.bands = [QxEqBandValue(filter: .lowShelf, freq: 105, gain: 3, q: 0.7),
                   QxEqBandValue(filter: .peak, freq: 3000, gain: -2.5, q: 1.4)]
        return f
    }

    private func make() -> ReferenceCurve {
        var options = CorrectionOptions()
        options.bassBoostGain = 2
        options.tilt = -0.25
        options.target = "Harman over-ear 2018"
        options.maxCorrectionHz = 12000
        return ReferenceCurve(file: file(), source: "oratory1990", headphone: "Px8",
                              rig: "GRAS 45BC-10", options: options,
                              fittedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    private func decode(_ json: String) throws -> ReferenceCurve {
        try JSONDecoder().decode(ReferenceCurve.self, from: Data(json.utf8))
    }

    func testBuildsFromAFileAndOptions() {
        let r = make()
        XCTAssertEqual(r.bands, file().bands)
        XCTAssertEqual(r.preGain, -4.5)
        XCTAssertEqual(r.source, "oratory1990")
        XCTAssertEqual(r.headphone, "Px8")
        XCTAssertEqual(r.rig, "GRAS 45BC-10")
        XCTAssertEqual(r.target, "Harman over-ear 2018")
        XCTAssertEqual(r.bassBoostDb, 2)
        XCTAssertEqual(r.tilt, -0.25)
        XCTAssertEqual(r.ceilingHz, 12000)
        XCTAssertEqual(r.measuredBy, "GRAS 45BC-10")
    }

    func testMeasuredByFallsBackToTheSource() {
        var r = make()
        r.rig = "  "
        XCTAssertEqual(r.measuredBy, "oratory1990")
    }

    func testRoundTrip() throws {
        let r = make()
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(ReferenceCurve.self, from: data), r)
    }

    func testMissingFieldsDecodeToDefaults() throws {
        let r = try decode(#"{"bands": [{"filter": 5, "freq": 1000, "gain": 2, "q": 1}]}"#)
        XCTAssertEqual(r.preGain, 0)
        XCTAssertEqual(r.source, "")
        XCTAssertEqual(r.bassBoostDb, 0)
        XCTAssertEqual(r.tilt, 0)
        XCTAssertNil(r.ceilingHz)
        XCTAssertEqual(r.fittedAt, .distantPast)
    }

    func testWrongTypedFieldsDecodeToDefaults() throws {
        let r = try decode(#"""
        {"bands": [{"filter": 5, "freq": 1000, "gain": 2, "q": 1}],
         "preGain": "loud", "source": 4, "tilt": [], "fittedAt": "yesterday"}
        """#)
        XCTAssertEqual(r.preGain, 0)
        XCTAssertEqual(r.source, "")
        XCTAssertEqual(r.tilt, 0)
        XCTAssertEqual(r.fittedAt, .distantPast)
    }

    func testBadBandDropsOnlyItself() throws {
        let r = try decode(#"""
        {"bands": [{"filter": 5, "freq": 1000, "gain": 2, "q": 1},
                   {"filter": 5, "freq": "x"},
                   7,
                   {"filter": 3, "freq": 105, "gain": -1, "q": 0.7}]}
        """#)
        XCTAssertEqual(r.bands.map(\.freq), [1000, 105])
    }

    func testUnknownFilterBecomesBypassAndIsDropped() throws {
        let r = try decode(#"""
        {"bands": [{"filter": 99, "freq": 1000, "gain": 2, "q": 1},
                   {"filter": 5, "freq": 2000, "gain": 1, "q": 1}]}
        """#)
        XCTAssertEqual(r.bands.map(\.freq), [2000])
    }

    func testNoUsableBandsFailsTheDecode() {
        XCTAssertThrowsError(try decode(#"{"bands": []}"#))
        XCTAssertThrowsError(try decode(#"{"bands": [{"filter": 0, "freq": 1000}]}"#))
        XCTAssertThrowsError(try decode(#"{"preGain": 1}"#))
        XCTAssertThrowsError(try decode(#"{"bands": "no"}"#))
    }

    func testValuesAreClampedOnDecode() throws {
        let r = try decode(#"""
        {"bands": [{"filter": 5, "freq": 90000, "gain": 500, "q": 0},
                   {"filter": 5, "freq": 1, "gain": -500, "q": 9999}],
         "preGain": 77, "bassBoostDb": 50, "tilt": -9, "ceilingHz": 100}
        """#)
        XCTAssertEqual(r.bands[0].freq, 20000)
        XCTAssertEqual(r.bands[0].gain, 12)
        XCTAssertEqual(r.bands[0].q, 0.05)
        XCTAssertEqual(r.bands[1].freq, 20)
        XCTAssertEqual(r.bands[1].gain, -12)
        XCTAssertEqual(r.bands[1].q, 100)
        XCTAssertEqual(r.preGain, 12)
        XCTAssertEqual(r.bassBoostDb, 6)
        XCTAssertEqual(r.tilt, -1)
        XCTAssertEqual(r.ceilingHz, CorrectionOptions.minCorrectionHz)
    }

    func testNonFiniteValuesAreRepairedOnSanitize() {
        var r = make()
        r.bands[0].gain = .nan
        r.bands[1].q = .infinity
        r.preGain = .nan
        r.bassBoostDb = .nan
        r.tilt = .infinity
        r.ceilingHz = .nan
        r.fittedAt = Date(timeIntervalSinceReferenceDate: .infinity)
        let s = r.sanitized()
        XCTAssertEqual(s.bands[0].gain, 0)
        XCTAssertEqual(s.bands[1].q, 1)
        XCTAssertEqual(s.preGain, 0)
        XCTAssertEqual(s.bassBoostDb, 0)
        XCTAssertEqual(s.tilt, 0)
        XCTAssertNil(s.ceilingHz)
        XCTAssertEqual(s.fittedAt, .distantPast)
    }

    func testTextIsScrubbedAndLimited() throws {
        let long = String(repeating: "a", count: 500)
        let r = try decode("""
        {"bands": [{"filter": 5, "freq": 1000, "gain": 2, "q": 1}],
         "source": "x\\u0007y\\u202Ez", "headphone": "\(long)"}
        """)
        XCTAssertEqual(r.source, "xyz")
        XCTAssertEqual(r.headphone.count, ReferenceCurve.maxTextLength + 1)
        XCTAssertTrue(r.headphone.hasSuffix("…"))
    }

    func testBandCountIsCapped() throws {
        let band = #"{"filter": 5, "freq": 1000, "gain": 1, "q": 1}"#
        let many = [String](repeating: band, count: 100).joined(separator: ",")
        let r = try decode("{\"bands\": [\(many)]}")
        XCTAssertEqual(r.bands.count, ReferenceCurve.maxBands)
    }

    func testLossyEntryYieldsNilForABadCurveAndKeepsTheGoodOne() throws {
        let json = #"""
        {"good": {"bands": [{"filter": 5, "freq": 1000, "gain": 2, "q": 1}], "preGain": -2},
         "bad": {"bands": []},
         "worse": 12}
        """#
        let map = try JSONDecoder().decode([String: ReferenceCurve.Lossy].self,
                                           from: Data(json.utf8))
        XCTAssertEqual(map["good"]?.value?.preGain, -2)
        XCTAssertNil(map["bad"]?.value)
        XCTAssertNil(map["worse"]?.value)
        XCTAssertEqual(map.count, 3)
    }

    func testInitSanitizesItsInputs() {
        var f = file()
        f.preamp = -50
        f.bands.append(QxEqBandValue(filter: .peak, freq: 1000, gain: 40, q: 1))
        let r = ReferenceCurve(file: f, source: "s\u{7}", headphone: "h")
        XCTAssertEqual(r.preGain, -12)
        XCTAssertEqual(r.bands.last?.gain, 12)
        XCTAssertEqual(r.source, "s")
    }
}

@MainActor
final class HeadphoneRelativesTests: XCTestCase {
    private func entries(_ titles: [String]) -> [AutoEqEntry] {
        titles.enumerated().map {
            AutoEqEntry(title: $1, source: "oratory1990", path: "p/\($0)")
        }
    }

    func testFamilyIsFoundByDroppingTrailingWords() throws {
        let list = entries(["Sennheiser HD 650", "Sennheiser HD 600", "Sennheiser HD 800",
                            "Sony WH-1000XM4"])
        let found = try XCTUnwrap(HeadphoneSuggestions.relatives(for: "Sennheiser HD 650 Special",
                                                                 in: list))
        XCTAssertEqual(found.family, "Sennheiser HD 650")
        XCTAssertEqual(found.entries.map(\.title), ["Sennheiser HD 650"])
    }

    func testBroaderFamilyWhenTheNarrowerOneIsEmpty() throws {
        let list = entries(["Sennheiser HD 600", "Sennheiser HD 800"])
        let found = try XCTUnwrap(HeadphoneSuggestions.relatives(for: "Sennheiser HD 999",
                                                                 in: list))
        XCTAssertEqual(found.family, "Sennheiser HD")
        XCTAssertEqual(found.entries.count, 2)
    }

    func testTooShortFamiliesAreSkippedAndASingleWordHasNone() {
        let list = entries(["Px8 Special", "Px7"])
        XCTAssertNil(HeadphoneSuggestions.relatives(for: "Px8", in: list))
        XCTAssertNil(HeadphoneSuggestions.relatives(for: "Zz Yy", in: list))
        XCTAssertNil(HeadphoneSuggestions.relatives(for: "", in: list))
    }
}
