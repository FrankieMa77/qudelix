import XCTest
@testable import QudelixBar

/// What `SafeFile.read` will and will not open, and the mode of the directory
/// the state files live in.
///
/// These paths are all user-writable, and every one of them is read on the
/// main actor while the app is starting up — `StageState.init()` loads
/// `stage.json` before there is a window to put an error in. So the failure
/// that matters here is not a wrong answer; it is not answering at all.
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

    /// The one that used to hang the app. A FIFO is not a symlink, so
    /// `O_NOFOLLOW` lets it through, and a blocking `open` on one waits for a
    /// writer that never arrives — on the main actor, during launch, with no
    /// window up yet and nothing to say why.
    ///
    /// Driven off the main thread against a deadline so that a regression
    /// fails this test in a second rather than wedging the whole suite.
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

    func testADirectoryIsRefused() throws {
        let dir = scratch.appendingPathComponent("stage.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)

        XCTAssertNil(SafeFile.read(dir, cap: 1000))
    }

    /// The files inside are written 0600 on purpose; a 0755 directory around
    /// them still lets every other account on the machine list what outputs
    /// and headphones someone owns.
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
