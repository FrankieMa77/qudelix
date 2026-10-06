import XCTest
@testable import QudelixBar

final class StageSettingsRecoveryTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("stage-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let url = scratch.appendingPathComponent("stage.json")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: scratch)
    }

    private var stageURL: URL { scratch.appendingPathComponent("stage.json") }
    private var parkedURL: URL { scratch.appendingPathComponent("stage.json.recovered") }

    private func bytes(_ url: URL) -> Data? { SafeFile.read(url, cap: 1 << 20) }

    @MainActor
    private func makeState() -> StageState {
        let state = StageState(settingsURL: stageURL)
        return state
    }

    func testAnUndecodableFileIsParkedAndReportedAsSuch() throws {
        let garbage = Data("{\"stageByDevice\": 7".utf8)
        XCTAssertTrue(SafeFile.writeAtomic(garbage, to: stageURL))

        let outcome = StageStateFile.loadOutcome(stageURL)
        guard case .unreadable(let parked) = outcome else {
            return XCTFail("a document that cannot be decoded is not a clean slate")
        }
        XCTAssertTrue(parked)
        XCTAssertFalse(outcome.permitsSaving)
        XCTAssertEqual(bytes(parkedURL), garbage)
    }

    func testOneBadExposureRowMakesTheWholeFileUnreadableAndKeepsItIntact() throws {
        let original = Data("""
        {"stageByDevice":{},"exposure":[{"day":"2026-10-01","audibleSeconds":5}],
         "levelTracking":true}
        """.utf8)
        XCTAssertTrue(SafeFile.writeAtomic(original, to: stageURL))

        guard case .unreadable(let parked) = StageStateFile.loadOutcome(stageURL) else {
            return XCTFail("a row missing a field fails the whole decode")
        }
        XCTAssertTrue(parked)
        XCTAssertEqual(bytes(stageURL), original)
    }

    func testAFileThatCannotBeOpenedIsUnreadableButNotParked() throws {
        XCTAssertTrue(SafeFile.writeAtomic(Data("{}".utf8), to: stageURL))
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: stageURL.path)

        let outcome = StageStateFile.loadOutcome(stageURL)
        guard case .unreadable(let parked) = outcome else {
            return XCTFail("a present file that cannot be read is not absent")
        }
        XCTAssertFalse(parked, "there is nothing readable to copy")
        XCTAssertFalse(outcome.permitsSaving)
        XCTAssertNil(bytes(parkedURL))
    }

    func testAnEmptyFileHoldsNothingToProtect() throws {
        try Data().write(to: stageURL)
        let outcome = StageStateFile.loadOutcome(stageURL)
        guard case .absent = outcome else {
            return XCTFail("a zero-byte file carries no settings")
        }
        XCTAssertTrue(outcome.permitsSaving)
    }

    func testAnOversizedFileIsLeftAloneNotMistakenForEmpty() throws {
        try Data(repeating: 0x20, count: 1_100_000).write(to: stageURL)
        let outcome = StageStateFile.loadOutcome(stageURL)
        guard case .unreadable(let parked) = outcome else {
            return XCTFail("a file past the cap is not ours to replace")
        }
        XCTAssertFalse(parked)
    }

    func testOnlyAnUnreadableFileProducesANotice() {
        XCTAssertNil(StageStateFile.notice(for: .absent))
        XCTAssertNil(StageStateFile.notice(for: .loaded(PersistedStageState())))

        let parked = StageStateFile.notice(for: .unreadable(parked: true)) ?? ""
        XCTAssertTrue(parked.contains("stage.json.recovered"))
        XCTAssertTrue(parked.contains("not saved"))

        let unparked = StageStateFile.notice(for: .unreadable(parked: false)) ?? ""
        XCTAssertFalse(unparked.contains(".recovered"))
        XCTAssertTrue(unparked.contains("permissions"))
    }

    @MainActor
    func testTheSaveTimerNeverOverwritesAFileItCouldNotLoad() throws {
        let original = Data("{\"exposure\": [{\"day\": 3}]}".utf8)
        XCTAssertTrue(SafeFile.writeAtomic(original, to: stageURL))

        let state = makeState()
        XCTAssertNotNil(state.settingsNotice)
        state.setPerAppEQ(false)
        state.saveNow()
        state.clearExposureHistory()

        XCTAssertEqual(bytes(stageURL), original,
                       "every profile in it is still recoverable by hand")
        XCTAssertEqual(bytes(parkedURL), original)
    }

    @MainActor
    func testAnAbsentFileIsCreatedByTheFirstSave() throws {
        let state = makeState()
        XCTAssertNil(state.settingsNotice)
        state.setPerAppEQ(false)
        state.saveNow()

        guard case .loaded(let back) = StageStateFile.loadOutcome(stageURL) else {
            return XCTFail("a first run must be able to persist")
        }
        XCTAssertEqual(back.perAppEQ, false)
    }

    @MainActor
    func testAGoodFileKeepsSavingAndRaisesNoNotice() throws {
        var saved = PersistedStageState()
        saved.levelTracking = true
        XCTAssertTrue(StageStateFile.save(saved, to: stageURL))

        let state = makeState()
        XCTAssertNil(state.settingsNotice)
        XCTAssertTrue(state.levelTracking)
        state.setPerAppEQ(false)
        state.saveNow()

        guard case .loaded(let back) = StageStateFile.loadOutcome(stageURL) else {
            return XCTFail("a readable file must stay writable")
        }
        XCTAssertEqual(back.perAppEQ, false)
        XCTAssertTrue(back.levelTracking)
        XCTAssertNil(bytes(parkedURL))
    }

    func testSaveReportsWhetherTheWriteLanded() {
        XCTAssertTrue(StageStateFile.save(PersistedStageState(), to: stageURL))
        let nowhere = scratch.appendingPathComponent("missing/stage.json")
        XCTAssertFalse(StageStateFile.save(PersistedStageState(), to: nowhere))
    }
}
