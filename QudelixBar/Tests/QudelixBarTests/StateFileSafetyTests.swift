import XCTest
@testable import QudelixBar

final class StateFileSafetyTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("safefile-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testAnOrdinaryFileReadsBack() throws {
        let url = scratch.appendingPathComponent("plain.json")
        try Data("{\"a\":1}".utf8).write(to: url)

        XCTAssertEqual(SafeFile.read(url, cap: 1000), Data("{\"a\":1}".utf8))
    }

    func testAFileLargerThanTheCapIsRefused() throws {
        let url = scratch.appendingPathComponent("huge.json")
        try Data(repeating: 0x41, count: 4096).write(to: url)

        XCTAssertNil(SafeFile.read(url, cap: 100))
    }

    func testASymlinkIsNotFollowed() throws {
        let target = scratch.appendingPathComponent("target.json")
        try Data("secret".utf8).write(to: target)
        let link = scratch.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertNil(SafeFile.read(link, cap: 1000))
    }

    func testAFifoIsRefusedInsteadOfBlockingForever() throws {
        let fifo = scratch.appendingPathComponent("stage.json")
        let made = fifo.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return mkfifo(path, 0o600)
        }
        XCTAssertEqual(made, 0, "could not create the FIFO this test is about")

        let returned = expectation(description: "SafeFile.read returned")
        var result: Data? = Data()
        DispatchQueue.global().async {
            result = SafeFile.read(fifo, cap: 1000)
            returned.fulfill()
        }

        wait(for: [returned], timeout: 2)
        XCTAssertNil(result, "a FIFO is not a state file this app ever wrote")
    }

    func testAFileLargerThanOneReadComesBackWhole() throws {
        let url = scratch.appendingPathComponent("long.json")
        let payload = Data((0..<(512 << 10)).map { UInt8($0 % 251) })
        try payload.write(to: url)

        XCTAssertEqual(SafeFile.read(url, cap: 1 << 20), payload)
    }

    func testAnEmptyFileIsNotAReadableDocument() throws {
        let url = scratch.appendingPathComponent("empty.json")
        try Data().write(to: url)

        XCTAssertNil(SafeFile.read(url, cap: 1000))
    }

    func testAnAtomicWriteLandsOwnerOnlyAndReadsBack() throws {
        let url = scratch.appendingPathComponent("state.json")
        XCTAssertTrue(SafeFile.writeAtomic(Data("{\"a\":1}".utf8), to: url))

        XCTAssertEqual(SafeFile.read(url, cap: 1000), Data("{\"a\":1}".utf8))
        var st = stat()
        _ = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &st)
        }
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
    }

    func testAReplacementNeverLeavesAHalfWrittenDocument() throws {
        let url = scratch.appendingPathComponent("state.json")
        XCTAssertTrue(SafeFile.writeAtomic(Data(repeating: 0x41, count: 4096), to: url))
        XCTAssertTrue(SafeFile.writeAtomic(Data(repeating: 0x42, count: 200_000), to: url))

        let back = try XCTUnwrap(SafeFile.read(url, cap: 1 << 20))
        XCTAssertEqual(back.count, 200_000)
        XCTAssertTrue(back.allSatisfy { $0 == 0x42 })
    }

    func testTheTemporaryFileDoesNotSurviveTheWrite() throws {
        let url = scratch.appendingPathComponent("state.json")
        XCTAssertTrue(SafeFile.writeAtomic(Data("x".utf8), to: url))

        let left = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        XCTAssertEqual(left, ["state.json"], "left behind: \(left)")
    }

    func testAWriteWithNowhereToPutItFails() {
        let url = scratch.appendingPathComponent("missing-dir/state.json")
        XCTAssertFalse(SafeFile.writeAtomic(Data("x".utf8), to: url))
    }

    func testADirectoryIsRefused() throws {
        let dir = scratch.appendingPathComponent("stage.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)

        XCTAssertNil(SafeFile.read(dir, cap: 1000))
    }

    func testTheStateDirectoryIsARealDirectoryPrivateToTheUser() throws {
        let dir = StageStateFile.directory

        var st = stat()
        let statted = dir.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &st)
        }
        XCTAssertEqual(statted, 0, "the state directory should exist by now")
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFDIR,
                       "a symlink here would redirect every state file the app writes")
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
    }
}
