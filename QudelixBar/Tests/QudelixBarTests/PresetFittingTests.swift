import XCTest
@testable import QudelixBar

final class PresetFittingTests: XCTestCase {
    private let apoText = "Preamp: -3.0 dB\r\nFilter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q 1.00\r\n"

    func testUtf16FilesWithAByteOrderMarkAreDecoded() throws {
        let littleBody = try XCTUnwrap(apoText.data(using: .utf16LittleEndian))
        let bigBody = try XCTUnwrap(apoText.data(using: .utf16BigEndian))
        for data in [Data([0xFF, 0xFE]) + littleBody, Data([0xFE, 0xFF]) + bigBody] {
            let text = try XCTUnwrap(ParametricEQFile.decodeText(data))
            let file = ParametricEQFile.parse(text)
            XCTAssertEqual(file?.preamp, -3)
            XCTAssertEqual(file?.bands.first?.freq, 1000)
        }
    }

    func testUtf16FilesWithoutAByteOrderMarkAreDecoded() throws {
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
            let data = try XCTUnwrap(apoText.data(using: encoding))
            let file = ParametricEQFile.decodeText(data).flatMap(ParametricEQFile.parse)
            XCTAssertEqual(file?.bands.first?.freq, 1000, "\(encoding)")
        }
    }

    func testUtf8WithAndWithoutAByteOrderMarkAndLatinOneAreDecoded() throws {
        let plain = Data(apoText.utf8)
        XCTAssertEqual(ParametricEQFile.decodeText(plain), apoText)
        XCTAssertEqual(ParametricEQFile.decodeText(Data([0xEF, 0xBB, 0xBF]) + plain), apoText)
        let latin = try XCTUnwrap("# caf\u{E9} \u{B5}\n\(apoText)".data(using: .isoLatin1))
        XCTAssertNil(String(data: latin, encoding: .utf8))
        XCTAssertEqual(ParametricEQFile.decodeText(latin).flatMap(ParametricEQFile.parse)?.bands.count, 1)
    }

    func testEmptyAndTinyDataDecodeWithoutTrapping() {
        XCTAssertEqual(ParametricEQFile.decodeText(Data()), "")
        XCTAssertEqual(ParametricEQFile.decodeText(Data([0x41])), "A")
        XCTAssertNotNil(ParametricEQFile.decodeText(Data([0xFF, 0xFE])))
    }

    private func peak(_ freq: Int, _ gain: Double) -> QxEqBandValue {
        QxEqBandValue(filter: .peak, freq: freq, gain: gain, q: 1)
    }

    private func shelf(_ filter: QxFilter, _ freq: Int, _ gain: Double) -> QxEqBandValue {
        QxEqBandValue(filter: filter, freq: freq, gain: gain, q: 0.7)
    }

    func testFittingIntoASmallerBankKeepsTheShelvesAndDropsTheWeakestPeaks() {
        var file = ParametricEQFile()
        file.preamp = -9
        var bands = (1...10).map { peak(100 * $0, 0.2 + Double($0) * 0.01) }
        bands.append(shelf(.highShelf, 10000, 8))
        bands.append(shelf(.lowShelf, 60, 7))
        file.bands = bands
        let fitted = file.fitted(toBandCount: 10)
        XCTAssertEqual(fitted.bands.count, 10)
        XCTAssertEqual(fitted.droppedBands, 2)
        XCTAssertEqual(fitted.bands.filter { $0.filter == .highShelf || $0.filter == .lowShelf }.count, 2)
        XCTAssertEqual(fitted.bands.filter { $0.filter == .peak }.map(\.freq),
                       Array(3...10).map { 100 * $0 })
    }

    func testFittingKeepsTheOriginalOrderOfWhatItKeeps() {
        var file = ParametricEQFile()
        file.bands = [peak(100, 0.1), shelf(.lowShelf, 60, 5), peak(500, 3),
                      peak(1000, 0.1), peak(2000, 4), shelf(.highShelf, 9000, -4)]
        let fitted = file.fitted(toBandCount: 4)
        XCTAssertEqual(fitted.bands.map(\.freq), [60, 500, 2000, 9000])
    }

    func testAShelfTooSmallToHearDoesNotOutrankARealPeak() {
        var file = ParametricEQFile()
        file.bands = [shelf(.lowShelf, 60, 0.2), peak(500, 3), peak(1000, 2), peak(2000, 1)]
        let fitted = file.fitted(toBandCount: 3)
        XCTAssertEqual(fitted.bands.map(\.freq), [500, 1000, 2000])
    }

    func testPassFiltersSurviveFittingAndBypassedSlotsGoFirst() {
        var file = ParametricEQFile()
        file.bands = [QxEqBandValue(filter: .hpf, freq: 30, gain: 0, q: 0.7),
                      QxEqBandValue(filter: .bypass, freq: 100, gain: 0, q: 1),
                      peak(500, 3), peak(1000, 2)]
        let fitted = file.fitted(toBandCount: 3)
        XCTAssertEqual(fitted.bands.map(\.freq), [30, 500, 1000])
    }

    func testAFileThatAlreadyFitsIsReturnedUntouched() {
        var file = ParametricEQFile()
        file.preamp = -2
        file.bands = (1...5).map { peak(100 * $0, 1) }
        file.notes = ["kept"]
        let fitted = file.fitted(toBandCount: 10)
        XCTAssertEqual(fitted.bands, file.bands)
        XCTAssertEqual(fitted.preamp, -2)
        XCTAssertEqual(fitted.droppedBands, 0)
        XCTAssertEqual(fitted.notes, ["kept"])
    }

    func testFittingCountsWhatTheFileAlreadyDroppedToo() {
        var file = ParametricEQFile()
        file.droppedBands = 3
        file.bands = (1...12).map { peak(100 * $0, Double($0)) }
        XCTAssertEqual(file.fitted(toBandCount: 10).droppedBands, 5)
    }

    func testFittingLowersAPreampThatCannotCoverWhatWasKept() {
        var file = ParametricEQFile()
        file.preamp = 0
        file.bands = (1...12).map { peak(200 * $0, 6) }
        let fitted = file.fitted(toBandCount: 10)
        XCTAssertEqual(fitted.preamp, EQHeadroom.suggestedPreGain(for: fitted.bands), accuracy: 1e-9)
        XCTAssertLessThan(fitted.preamp, 0)
        XCTAssertTrue(fitted.notes.contains { $0.hasPrefix("pre-gain lowered to") }, "\(fitted.notes)")
    }

    func testFittingNeverRaisesAPreampTheFileAlreadyHadDeeper() {
        var file = ParametricEQFile()
        file.preamp = -12
        file.bands = (1...12).map { peak(200 * $0, 1) }
        let fitted = file.fitted(toBandCount: 10)
        XCTAssertEqual(fitted.preamp, -12)
        XCTAssertFalse(fitted.notes.contains { $0.hasPrefix("pre-gain lowered") })
    }

    func testParsingPastTheLargestBankKeepsShelvesToo() {
        var lines = ["Filter 1: ON LSC Fc 60 Hz Gain 0.8 dB Q 0.7"]
        for i in 1...25 {
            lines.append("Filter \(i + 1): ON PK Fc \(100 * i) Hz Gain \(Double(i) / 20 + 0.1) dB Q 1")
        }
        let file = ParametricEQFile.parse(lines.joined(separator: "\n"))
        XCTAssertEqual(file?.bands.count, 20)
        XCTAssertEqual(file?.bands.first?.filter, .lowShelf)
    }
}
