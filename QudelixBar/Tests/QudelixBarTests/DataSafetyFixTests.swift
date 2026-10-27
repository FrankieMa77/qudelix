import XCTest
@testable import QudelixBar

final class DataSafetyFixTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("datasafety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let items = try? FileManager.default.contentsOfDirectory(atPath: scratch.path) {
            for item in items {
                chmod(scratch.appendingPathComponent(item).path, 0o600)
            }
        }
        try? FileManager.default.removeItem(at: scratch)
    }

    private func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).sorted()
    }

    func testUnreadableAutofitFileIsMovedAsideNotReplaced() throws {
        let url = scratch.appendingPathComponent("autofit.json")
        try Data("{\"x\":1}".utf8).write(to: url)
        chmod(url.path, 0)
        XCTAssertNil(AutofitFile.load(from: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(names(), ["autofit.json.recovered"])
    }

    func testUnreadableProfilesFileIsMovedAside() throws {
        let url = scratch.appendingPathComponent("profiles.json")
        try Data("[]  ".utf8).write(to: url)
        chmod(url.path, 0)
        XCTAssertEqual(ProfileRulesFile.load(from: url).count, 0)
        XCTAssertEqual(names(), ["profiles.json.recovered"])
    }

    func testUnreadableBatteryAndSnapshotFilesAreMovedAside() throws {
        let battery = scratch.appendingPathComponent("battery-history.json")
        let snapshot = scratch.appendingPathComponent("last-eq.json")
        for url in [battery, snapshot] {
            try Data("{}  ".utf8).write(to: url)
            chmod(url.path, 0)
        }
        _ = BatteryHistoryFile.load(from: battery)
        _ = EqSnapshotFile.load(from: snapshot)
        XCTAssertEqual(names(), ["battery-history.json.recovered", "last-eq.json.recovered"])
    }

    func testEmptyAndMissingFilesAreNotParked() throws {
        let url = scratch.appendingPathComponent("autofit.json")
        XCTAssertNil(AutofitFile.load(from: url))
        try Data().write(to: url)
        XCTAssertNil(AutofitFile.load(from: url))
        XCTAssertEqual(names(), ["autofit.json"])
    }

    func testAutofitParksEachCorruptionUnderItsOwnName() throws {
        let url = scratch.appendingPathComponent("autofit.json")
        try Data("first".utf8).write(to: url)
        XCTAssertNil(AutofitFile.load(from: url))
        try Data("second".utf8).write(to: url)
        XCTAssertNil(AutofitFile.load(from: url))
        XCTAssertEqual(try Data(contentsOf: scratch.appendingPathComponent("autofit.json.recovered")),
                       Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: scratch.appendingPathComponent("autofit.json.recovered-2")),
                       Data("second".utf8))
    }

    func testStageParksEachCorruptionUnderItsOwnName() throws {
        let url = scratch.appendingPathComponent("stage.json")
        try Data("first".utf8).write(to: url)
        _ = StageStateFile.loadOutcome(url)
        try Data("second".utf8).write(to: url)
        _ = StageStateFile.loadOutcome(url)
        XCTAssertEqual(names(), ["stage.json", "stage.json.recovered", "stage.json.recovered-2"])
    }

    func testStaleTempFilesAreSweptAndOthersKept() throws {
        let stale = scratch.appendingPathComponent(".stage.json.0A1B2C3D")
        let fresh = scratch.appendingPathComponent(".last-eq.json.0A1B2C3D")
        let real = scratch.appendingPathComponent("stage.json")
        let dotted = scratch.appendingPathComponent(".hidden.note")
        for url in [stale, fresh, real, dotted] { try Data("x".utf8).write(to: url) }
        let old = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)
        XCTAssertEqual(SafeFile.sweepStaleTemps(in: scratch), 1)
        XCTAssertEqual(names(), [".hidden.note", ".last-eq.json.0A1B2C3D", "stage.json"])
    }

    func testSweepingAMissingDirectoryIsHarmless() {
        XCTAssertEqual(SafeFile.sweepStaleTemps(in: scratch.appendingPathComponent("none")), 0)
    }

    func testScrubbedDropsFormatAndControlCategories() {
        let text = "a\u{180E}b\u{FFF9}c\u{1D173}d\u{0600}e\u{0085}f\u{200B}g"
        XCTAssertEqual(SafeText.scrubbed(text), "abcdefg")
    }

    func testScrubbedCapsStackedCombiningMarks() {
        let stacked = "e" + String(repeating: "\u{0301}", count: 40) + "x"
        let out = SafeText.scrubbed(stacked)
        XCTAssertEqual(out.unicodeScalars.count, 1 + SafeText.maxCombiningRun + 1)
        XCTAssertTrue(out.hasSuffix("x"))
    }

    func testScrubbedKeepsOrdinaryAccentedText() {
        XCTAssertEqual(SafeText.scrubbed("Sennheiser HD 650 Über"), "Sennheiser HD 650 Über")
    }

    func testTerminationHandlerRunsTheTerminateClosureOnSigterm() async throws {
        let fired = expectation(description: "terminate")
        var holder: DispatchSourceSignal?
        await MainActor.run {
            AppDelegate.installTerminationHandler(into: &holder) { fired.fulfill() }
        }
        kill(getpid(), SIGTERM)
        await fulfillment(of: [fired], timeout: 5)
        holder?.cancel()
        signal(SIGTERM, SIG_DFL)
    }

    func testInstallerAsksTheAppToQuitBeforeTheKill() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("make-dmg.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        let quit = try XCTUnwrap(text.range(of: "tell application id \"com.qudelixbar.app\" to quit"))
        let wait = try XCTUnwrap(text.range(of: "pgrep -x QudelixBar"))
        let kill = try XCTUnwrap(text.range(of: "pkill -x QudelixBar"))
        XCTAssertLessThan(quit.lowerBound, wait.lowerBound)
        XCTAssertLessThan(wait.lowerBound, kill.lowerBound)
    }
}

final class KeychainSaveFallbackTests: XCTestCase {
    final class Scripted: @unchecked Sendable, KeychainStore {
        var addStatuses: [OSStatus]
        var updateStatus: OSStatus
        var deleteStatus: OSStatus = errSecSuccess
        var deleted = 0
        var adds = 0

        init(add: [OSStatus], update: OSStatus) {
            addStatuses = add
            updateStatus = update
        }

        func add(_ attributes: [String: Any]) -> OSStatus {
            adds += 1
            return addStatuses.isEmpty ? errSecSuccess : addStatuses.removeFirst()
        }
        func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus { updateStatus }
        func copy(_ query: [String: Any]) -> (status: OSStatus, data: Data?) { (errSecItemNotFound, nil) }
        func delete(_ query: [String: Any]) -> OSStatus {
            deleted += 1
            return deleteStatus
        }
    }

    func testFailedUpdateFallsBackToDeleteThenAdd() {
        let store = Scripted(add: [errSecDuplicateItem, errSecSuccess], update: errSecAuthFailed)
        XCTAssertTrue(AIKeychain(store: store).save(key: "sk-test-123", provider: "p"))
        XCTAssertEqual(store.deleted, 1)
        XCTAssertEqual(store.adds, 2)
    }

    func testSuccessfulUpdateDoesNotDelete() {
        let store = Scripted(add: [errSecDuplicateItem], update: errSecSuccess)
        XCTAssertTrue(AIKeychain(store: store).save(key: "sk-test-123", provider: "p"))
        XCTAssertEqual(store.deleted, 0)
    }

    func testFailedDeleteReportsFailure() {
        let store = Scripted(add: [errSecDuplicateItem], update: errSecAuthFailed)
        store.deleteStatus = errSecAuthFailed
        XCTAssertFalse(AIKeychain(store: store).save(key: "sk-test-123", provider: "p"))
    }
}
