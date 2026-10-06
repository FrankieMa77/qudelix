import XCTest
@testable import QudelixBar

@MainActor
final class QuitFlushTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("quit-flush-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testQuittingWritesTheBatteryTailAndTheLibraryNameStillInItsWindow() {
        let batteryURL = scratch.appendingPathComponent("battery-history.json")
        let libraryURL = scratch.appendingPathComponent("library.json")
        let log = BatteryLog(fileURL: batteryURL)
        let library = PresetLibrary()
        library.nameCommitDelay = 3600
        library.start(fileURL: libraryURL)

        let now = Date()
        log.record(percent: 80, charging: false, at: now.addingTimeInterval(-120))
        log.record(percent: 79, charging: false, at: now.addingTimeInterval(-60))
        library.setHeadphoneName("HD 650")
        library.setHeadphoneName("HD 650S")

        XCTAssertFalse(FileManager.default.fileExists(atPath: batteryURL.path))
        XCTAssertEqual(PresetLibraryFile.load(from: libraryURL)?.headphoneName, "HD 650")

        AppDelegate.flushPendingWrites(batteryLog: log, presetLibrary: library)

        let samples = BatteryHistoryFile.load(from: batteryURL).samples
        XCTAssertEqual(samples.map { $0.percent }, [80, 79, nil],
                       "the close of the run is written as a gap, not left open")
        XCTAssertEqual(PresetLibraryFile.load(from: libraryURL)?.headphoneName, "HD 650S")
        XCTAssertEqual(library.committedHeadphoneName, "HD 650S")
    }
}
