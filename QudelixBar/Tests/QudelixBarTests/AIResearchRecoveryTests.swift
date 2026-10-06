import XCTest
@testable import QudelixBar

@MainActor
final class AIResearchRecoveryTests: XCTestCase {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-research-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func dossier(_ signature: String) -> HeadphoneDossier {
        let now = Date()
        return HeadphoneDossier(signature: signature, bass: "b", mids: "m", treble: "t",
                                soundstage: "s", knownIssues: [], confidence: "high",
                                measurement: nil, researchedAt: now, provider: "mistral",
                                model: "m", lastUsedAt: now)
    }

    private func file(_ dir: URL, _ name: String) -> URL { dir.appendingPathComponent(name) }

    private func contents(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func testAnUndecodableFileIsParkedBeforeTheNextStoreReplacesIt() throws {
        let dir = try directory()
        let main = file(dir, AIResearchStore.fileName)
        try Data("not json {".utf8).write(to: main)

        let store = AIResearchStore(directory: dir)
        XCTAssertNil(store.dossier(for: "k"))
        XCTAssertEqual(contents(file(dir, "ai-research.json.recovered")), "not json {")

        store.store(dossier("fresh"), for: "k")
        XCTAssertEqual(AIResearchStore(directory: dir).dossier(for: "k", touch: false)?.signature,
                       "fresh")
        XCTAssertEqual(contents(file(dir, "ai-research.json.recovered")), "not json {")
    }

    func testASecondCorruptionDoesNotOverwriteTheFirstParkedCopy() throws {
        let dir = try directory()
        let main = file(dir, AIResearchStore.fileName)
        try Data("first corruption".utf8).write(to: main)
        _ = AIResearchStore(directory: dir).dossier(for: "k")

        try Data("[1, 2, 3]".utf8).write(to: main)
        _ = AIResearchStore(directory: dir).dossier(for: "k")

        try Data("third".utf8).write(to: main)
        _ = AIResearchStore(directory: dir).dossier(for: "k")

        XCTAssertEqual(contents(file(dir, "ai-research.json.recovered")), "first corruption")
        XCTAssertEqual(contents(file(dir, "ai-research.json.recovered-2")), "[1, 2, 3]")
        XCTAssertEqual(contents(file(dir, "ai-research.json.recovered-3")), "third")
    }

    func testAHealthyFileIsNeverParked() throws {
        let dir = try directory()
        let store = AIResearchStore(directory: dir)
        store.store(dossier("kept"), for: "k")
        _ = AIResearchStore(directory: dir).dossier(for: "k")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: file(dir, "ai-research.json.recovered").path))
    }

    func testAMissingFileLeavesNothingParked() throws {
        let dir = try directory()
        XCTAssertNil(AIResearchStore(directory: dir).dossier(for: "k"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testAnEmptyDocumentIsAValidCacheNotACorruptOne() throws {
        let dir = try directory()
        try Data("{}".utf8).write(to: file(dir, AIResearchStore.fileName))
        XCTAssertNil(AIResearchStore(directory: dir).dossier(for: "k"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: file(dir, "ai-research.json.recovered").path))
    }

    func testOneBadRecordAmongGoodOnesIsNotAReasonToParkTheFile() throws {
        let dir = try directory()
        let store = AIResearchStore(directory: dir)
        store.store(dossier("good"), for: "good")
        let url = file(dir, AIResearchStore.fileName)
        var text = try XCTUnwrap(contents(url))
        text = text.replacingOccurrences(of: "\"good\" :", with: "\"bad\" : 7, \"good\" :")
        try Data(text.utf8).write(to: url)

        let reopened = AIResearchStore(directory: dir)
        XCTAssertEqual(reopened.dossier(for: "good", touch: false)?.signature, "good")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: file(dir, "ai-research.json.recovered").path))
    }

    func testAnOversizedFileIsMovedAsideNotOverwritten() throws {
        let dir = try directory()
        let main = file(dir, AIResearchStore.fileName)
        let padding = String(repeating: "x", count: AIResearchStore.maxBytes)
        try Data("{\"k\": \"\(padding)\"}".utf8).write(to: main)

        let store = AIResearchStore(directory: dir)
        XCTAssertNil(store.dossier(for: "k"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: main.path))
        let parked = file(dir, "ai-research.json.recovered")
        XCTAssertTrue(FileManager.default.fileExists(atPath: parked.path))

        store.store(dossier("fresh"), for: "k")
        XCTAssertEqual(AIResearchStore(directory: dir).dossier(for: "k", touch: false)?.signature,
                       "fresh")
        XCTAssertGreaterThan(try Data(contentsOf: parked).count, AIResearchStore.maxBytes)
    }

    func testAnEmptyFileIsNotWorthParking() throws {
        let dir = try directory()
        try Data().write(to: file(dir, AIResearchStore.fileName))
        XCTAssertNil(AIResearchStore(directory: dir).dossier(for: "k"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: file(dir, "ai-research.json.recovered").path))
    }

    func testASymlinkedCacheIsMovedAsideAndItsTargetLeftAlone() throws {
        let dir = try directory()
        let target = file(dir, "elsewhere.json")
        try Data("{}".utf8).write(to: target)
        let link = file(dir, AIResearchStore.fileName)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let store = AIResearchStore(directory: dir)
        XCTAssertNil(store.dossier(for: "k"))
        store.store(dossier("fresh"), for: "k")

        XCTAssertEqual(contents(target), "{}")
        XCTAssertEqual(AIResearchStore(directory: dir).dossier(for: "k", touch: false)?.signature,
                       "fresh")
    }
}
