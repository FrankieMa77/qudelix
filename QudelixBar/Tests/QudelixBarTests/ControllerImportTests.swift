import XCTest
@testable import QudelixBar

@MainActor
final class ControllerImportTests: XCTestCase {
    override func tearDown() async throws {
        DeviceRig.cleanUp()
    }

    private func peak(_ hz: Int, _ gain: Double) -> QxEqBandValue {
        QxEqBandValue(filter: .peak, freq: hz, gain: gain, q: 1.0)
    }

    private func twelveBands() -> ParametricEQFile {
        var file = ParametricEQFile()
        let gains: [Double] = [0.4, 0.6, 5, 4, -6, 3, -2, 7, 8, -5, 2, 6]
        file.bands = gains.enumerated().map { peak(100 * ($0.offset + 1), $0.element) }
        return file
    }

    func testALongerFileKeepsTheStrongestBandsNotTheFirstOnes() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connect()
        let file = twelveBands()

        c.apply(file, named: "Twelve")

        XCTAssertEqual(c.bands.count, 10)
        XCTAssertEqual(c.bands.map(\.gain), [5, 4, -6, 3, -2, 7, 8, -5, 2, 6],
                       "the two weakest filters are the ones left out")
        XCTAssertEqual(c.requestedCorrection?.bands.count, 12,
                       "the overlay still shows the whole requested correction")
        XCTAssertTrue(c.lastImportSummary?.contains("2 band(s) dropped") ?? false,
                      c.lastImportSummary ?? "")
        XCTAssertTrue(c.lastImportSummary?.contains("(fit in 20-band mode)") ?? false,
                      c.lastImportSummary ?? "")
    }

    func testTheFitLowersThePreGainForWhatWasKept() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connect()
        var file = twelveBands()
        file.preamp = 0

        c.apply(file, named: "Twelve")
        let fitted = file.fitted(toBandCount: 10)
        XCTAssertEqual(c.preGain, EQHeadroom.clamp(fitted.preamp), accuracy: 0.05)
    }

    func testAFileThatFitsIsAppliedAsItWas() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connect()
        var file = ParametricEQFile()
        file.bands = [peak(100, 3), peak(1000, -2)]
        file.preamp = -3

        c.apply(file, named: "Two")
        XCTAssertEqual(c.bands[0].gain, 3)
        XCTAssertEqual(c.bands[1].gain, -2)
        XCTAssertEqual(c.bands[2].filter, .bypass)
        XCTAssertEqual(c.preGain, -3, accuracy: 0.05)
        XCTAssertFalse(c.lastImportSummary?.contains("dropped") ?? true)
    }

    func testTheSummaryPrintsTheClampedPreGainItActuallyWrote() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connect()
        var file = ParametricEQFile()
        file.bands = [peak(1000, 2)]
        file.preamp = -20

        c.apply(file, named: "Quiet")
        XCTAssertEqual(c.preGain, -12, accuracy: 0.05)
        XCTAssertTrue(c.lastImportSummary?.contains("pre-gain -12.0 dB") ?? false,
                      c.lastImportSummary ?? "")
    }

    func testAnImportWithNoDeviceSaysToConnectFirstAndSendsNothing() {
        let rig = DeviceRig()
        let c = rig.controller
        c.clearSendTrace()
        var file = ParametricEQFile()
        file.bands = [peak(1000, 2)]

        XCTAssertFalse(c.apply(file, named: "Nothing"))
        XCTAssertEqual(c.lastImportSummary, "Connect the 5K first — nothing was applied.")
        XCTAssertTrue(c.sendTrace.isEmpty)
    }

    func testAnUnsupportedDeviceStillGetsItsOwnMessage() async {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.attachUSB()
        c.debugIngest(Wire.initData(deviceId: 2))
        XCTAssertNotEqual(c.compatibility, .ok)
        var file = ParametricEQFile()
        file.bands = [peak(1000, 2)]

        XCTAssertFalse(c.apply(file, named: "No"))
        XCTAssertEqual(c.lastImportSummary, "Not applied — this device isn't supported.")
    }

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qa-rig", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("import-\(UUID().uuidString).txt")
        try Data(bytes).write(to: url)
        return url
    }

    func testAUTF16FileIsReadByTheControllerImport() async throws {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connect()
        let text = "Preamp: -3.0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 4.0 dB Q 1.00\n"
        var bytes: [UInt8] = [0xFF, 0xFE]
        for unit in text.utf16 { bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }

        c.importFile(at: try tempFile(bytes))
        XCTAssertEqual(c.bands[0].freq, 1000)
        XCTAssertEqual(c.bands[0].gain, 4)
    }

    func testALatin1FileStillImports() async throws {
        let rig = DeviceRig()
        let c = rig.controller
        await rig.connect()
        let text = "Preamp: -3.0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 4.0 dB Q 1.00 \u{00E9}\n"
        let url = try tempFile([UInt8](text.data(using: .isoLatin1)!))

        c.importFile(at: url)
        XCTAssertEqual(c.bands[0].gain, 4)
    }
}
