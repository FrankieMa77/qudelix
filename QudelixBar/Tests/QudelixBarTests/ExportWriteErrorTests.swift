import XCTest
@testable import QudelixBar

@MainActor
final class ExportWriteErrorTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-errors-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var unwritable: URL {
        scratch.appendingPathComponent("missing-folder").appendingPathComponent("QudelixEQ.txt")
    }

    func testAnImportPaneExportThatCannotBeWrittenSaysSo() {
        let rig = DeviceRig()
        let controller = rig.controller

        XCTAssertFalse(controller.exportFile(to: unwritable))

        let summary = controller.lastImportSummary ?? ""
        XCTAssertTrue(summary.contains("Couldn't save QudelixEQ.txt"), summary)
    }

    func testAnImportPaneExportThatWorksWritesTheCurveAndStaysQuiet() throws {
        let rig = DeviceRig()
        let controller = rig.controller
        let url = scratch.appendingPathComponent("QudelixEQ.txt")

        XCTAssertTrue(controller.exportFile(to: url))

        XCTAssertNil(controller.lastImportSummary)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), controller.exportText())
    }

    func testALibraryExportThatCannotBeWrittenSaysSoThroughTheLibraryMessage() {
        let library = PresetLibrary()
        library.start(fileURL: scratch.appendingPathComponent("library.json"))
        let preset = LibraryPreset(name: "Harman", scope: .global, group: .user,
                                   bands: DeviceRig.curve(), preGain: -3)

        XCTAssertFalse(library.exportFile(preset, to: unwritable))

        XCTAssertTrue(library.lastMessage?.contains("Couldn't save QudelixEQ.txt") == true,
                      library.lastMessage ?? "no message")
    }

    func testALibraryExportThatWorksWritesTheFile() throws {
        let library = PresetLibrary()
        library.start(fileURL: scratch.appendingPathComponent("library.json"))
        let preset = LibraryPreset(name: "Harman", scope: .global, group: .user,
                                   bands: DeviceRig.curve(), preGain: -3)
        let url = scratch.appendingPathComponent("Harman.txt")

        XCTAssertTrue(library.exportFile(preset, to: url))

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), library.exportText(preset))
    }
}
