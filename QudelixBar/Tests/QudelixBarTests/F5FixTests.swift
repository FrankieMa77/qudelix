import XCTest
@testable import QudelixBar

@MainActor
final class F5FixTests: XCTestCase {
    private var scratch: URL!
    private let orig = DeviceRig.curve(first: 3)

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("f5fix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let items = try? FileManager.default.contentsOfDirectory(atPath: scratch.path) {
            for item in items { chmod(scratch.appendingPathComponent(item).path, 0o600) }
        }
        try? FileManager.default.removeItem(at: scratch)
        DeviceRig.cleanUp()
    }

    private func connected() async -> DeviceRig {
        let rig = DeviceRig()
        await rig.connect(bands: orig, preGain: 0, slot: 255)
        try? await Task.sleep(for: .milliseconds(400))
        return rig
    }

    private func userEdit(_ c: QudelixController) {
        var b = c.bands[2]
        b.gain = 4.5
        c.updateBand(2, b, persistToFlash: false, recordUndo: false)
    }

    func testCancellingABTunerAfterTheControllerEndedTheSessionWritesNothing() async {
        let rig = await connected()
        let c = rig.controller
        let tuner = ABTuner()
        tuner.start(c, chance: .seeded(3))
        XCTAssertEqual(tuner.phase, .running)
        c.endEqSession()
        userEdit(c)
        let edited = c.bands
        let pre = c.preGain
        tuner.cancel(c)
        XCTAssertEqual(c.bands, edited)
        XCTAssertEqual(c.preGain, pre)
    }

    func testCancellingABlindTrimAfterTheControllerEndedTheSessionWritesNothing() async {
        let rig = await connected()
        let c = rig.controller
        c.eqEnabled = true
        let blind = BlindTuner()
        blind.startTrim(c, trim: TrimGains(bassDb: 1.2, tiltDbPerOctave: -0.3,
                                           presenceDb: 0.8, airDb: 0.5),
                        chance: Chance(coin: { true }, index: { _ in 0 }))
        XCTAssertEqual(blind.phase, .running)
        c.endEqSession()
        userEdit(c)
        let edited = c.bands
        blind.cancel(c)
        XCTAssertEqual(c.bands, edited)
    }

    func testTheSessionRefusalTextDoesNotOutliveTheSession() async {
        let rig = await connected()
        let c = rig.controller
        c.setByEarSessionActive(true)
        XCTAssertFalse(c.apply(ParametricEQFile()))
        XCTAssertNotNil(c.lastImportSummary)
        c.setByEarSessionActive(false)
        XCTAssertNil(c.lastImportSummary)
    }

    func testAnotherSummaryIsLeftAloneWhenTheSessionEnds() async {
        let rig = await connected()
        let c = rig.controller
        c.setByEarSessionActive(true)
        c.lastImportSummary = "Something else"
        c.setByEarSessionActive(false)
        XCTAssertEqual(c.lastImportSummary, "Something else")
    }

    func testAnUnreadableFileThatCannotBeParkedIsNeverOverwritten() throws {
        let url = scratch.appendingPathComponent("autofit.json")
        try Data("{\"x\":1}".utf8).write(to: url)
        for candidate in ParkedCopy.candidates(beside: url) {
            try Data("old".utf8).write(to: candidate)
        }
        chmod(url.path, 0)
        XCTAssertNil(AutofitFile.load(from: url))
        XCTAssertFalse(AutofitFile.save(PersistedAutofit(), to: url))
        chmod(url.path, 0o600)
        XCTAssertEqual(try Data(contentsOf: url), Data("{\"x\":1}".utf8))
    }

    func testBatteryHistoryAndProfilesStayReadOnlyWhenParkingFails() throws {
        let battery = scratch.appendingPathComponent("battery-history.json")
        try Data("garbage".utf8).write(to: battery)
        for candidate in ParkedCopy.candidates(beside: battery) {
            try Data("old".utf8).write(to: candidate)
        }
        chmod(battery.path, 0)
        _ = BatteryHistoryFile.load(from: battery)
        XCTAssertTrue(SafeFile.isHeld(battery))
        XCTAssertFalse(SafeFile.writeAtomic(Data("new".utf8), to: battery))
    }

    func testAMissingFileIsNotHeld() {
        let url = scratch.appendingPathComponent("last-eq.json")
        _ = EqSnapshotFile.load(from: url)
        XCTAssertFalse(SafeFile.isHeld(url))
        XCTAssertTrue(SafeFile.writeAtomic(Data("{}".utf8), to: url))
    }

    func testANegativeZeroPreGainNeverPrintsAsMinusZero() async {
        let rig = await connected()
        let c = rig.controller
        var file = ParametricEQFile()
        file.preamp = -0.04
        file.bands = [QxEqBandValue(filter: .peak, freq: 1000, gain: 1, q: 1)]
        c.apply(file, named: "Tiny")
        let text = c.lastImportSummary ?? ""
        XCTAssertFalse(text.contains("-0.0"), text)
        XCTAssertFalse(text.contains("\u{2212}0.0"), text)
        XCTAssertTrue(text.contains("+0.0 dB"), text)
    }
}
