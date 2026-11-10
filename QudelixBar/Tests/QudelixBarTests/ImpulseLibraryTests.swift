import XCTest
@testable import QudelixBar

final class ImpulseLibraryTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("impulse-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testAWavFileInstallsAndComesBackWithItsShape() throws {
        let source = scratch.appendingPathComponent("Room Sweep.wav")
        try WavFixture.write(source, samples: taps(2048))

        let response = try IRLibrary.install(source: source, into: scratch)
        XCTAssertEqual(response.sourceChannels, 1)
        XCTAssertEqual(response.sourceRate, 48000)
        XCTAssertEqual(response.sourceFrames, 2048)
        XCTAssertTrue(response.fileName.hasPrefix("Room_Sweep-"))
        XCTAssertTrue(response.fileName.hasSuffix(".wav"))
        XCTAssertEqual(response.displayName, "Room_Sweep")

        var st = stat()
        let stored = IRLibrary.storedURL(response.fileName, in: scratch)
        XCTAssertEqual(lstat(stored.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)

        let again = try IRLibrary.load(name: response.fileName, from: scratch)
        XCTAssertEqual(again.sourceFrames, 2048)
    }

    func testASymlinkIsNeverOpenedAsAnImpulseResponse() throws {
        let real = scratch.appendingPathComponent("real.wav")
        try WavFixture.write(real, samples: taps(512))
        let link = scratch.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertThrowsError(try IRLibrary.install(source: link, into: scratch)) {
            XCTAssertTrue(($0 as? ImpulseError)?.message.contains("link") ?? false,
                          "\($0)")
        }
    }

    func testAFifoIsRefusedInsteadOfBlockingForever() throws {
        let fifo = scratch.appendingPathComponent("pipe.wav")
        let made = fifo.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return mkfifo(path, 0o600)
        }
        XCTAssertEqual(made, 0, "could not create the FIFO this test is about")

        let returned = expectation(description: "install returned")
        var refused = false
        let dir = scratch!
        DispatchQueue.global().async {
            refused = (try? IRLibrary.install(source: fifo, into: dir)) == nil
            returned.fulfill()
        }
        wait(for: [returned], timeout: 3)
        XCTAssertTrue(refused)
    }

    func testAFileBiggerThanTheCapIsRefusedBeforeItIsRead() throws {
        let big = scratch.appendingPathComponent("huge.wav")
        let fd = big.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        }
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, off_t(ImpulseLimits.maxFileBytes + 1)), 0)
        close(fd)

        XCTAssertThrowsError(try IRLibrary.install(source: big, into: scratch)) {
            XCTAssertTrue(($0 as? ImpulseError)?.message.contains("64 MB") ?? false,
                          "\($0)")
        }
    }

    func testAThreeSecondRecordingIsNotAnImpulseResponse() throws {
        let long = scratch.appendingPathComponent("hall.wav")
        try WavFixture.write(long, samples: taps(48000 * 3))

        XCTAssertThrowsError(try IRLibrary.install(source: long, into: scratch)) {
            XCTAssertTrue(($0 as? ImpulseError)?.message.contains("3.0") ?? false,
                          "\($0)")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        XCTAssertEqual(left, ["hall.wav"], "the refused copy was left behind")
    }

    func testAFileWithNoAudioInItIsRefused() throws {
        let silent = scratch.appendingPathComponent("silent.wav")
        try WavFixture.write(silent, samples: [Float](repeating: 0, count: 1024))

        XCTAssertThrowsError(try IRLibrary.install(source: silent, into: scratch)) {
            XCTAssertTrue(($0 as? ImpulseError)?.message.contains("silent") ?? false,
                          "\($0)")
        }
    }

    func testAnUnreadableExtensionIsRefusedByName() throws {
        let text = scratch.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)

        XCTAssertThrowsError(try IRLibrary.install(source: text, into: scratch)) {
            XCTAssertTrue(($0 as? ImpulseError)?.message.contains(".txt") ?? false,
                          "\($0)")
        }
    }

    func testTheSweepRemovesEveryCopyNoProfileStillNames() throws {
        let keep = scratch.appendingPathComponent("keep.wav")
        let drop = scratch.appendingPathComponent("drop.wav")
        try WavFixture.write(keep, samples: taps(512))
        try WavFixture.write(drop, samples: taps(512))
        let kept = try IRLibrary.install(source: keep, into: scratch)
        let dropped = try IRLibrary.install(source: drop, into: scratch)

        let swept = IRLibrary.sweep(keeping: [kept.fileName, "keep.wav", "drop.wav"],
                                    in: scratch)
        XCTAssertEqual(swept, [dropped.fileName])
        let left = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        XCTAssertTrue(left.contains(kept.fileName))
        XCTAssertFalse(left.contains(dropped.fileName))
    }

    func testAStoredNameThatTriesToLeaveTheFolderIsNotAName() {
        XCTAssertNil(IRLibrary.safeName("../../etc/passwd.wav"))
        XCTAssertNil(IRLibrary.safeName("sub/room.wav"))
        XCTAssertNil(IRLibrary.safeName("room.exe"))
        XCTAssertNil(IRLibrary.safeName(""))
        XCTAssertNil(IRLibrary.safeName(nil))
        XCTAssertNil(IRLibrary.safeName(String(repeating: "a", count: 200) + ".wav"))
        XCTAssertEqual(IRLibrary.safeName("room-1a2b3c4d.wav"), "room-1a2b3c4d.wav")
    }

    private func taps(_ count: Int) -> [Float] {
        var seed: UInt64 = 7
        return (0..<count).map { i in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed)) / Float(Int64.max)
                * Float(exp(-Double(i) / 500))
        }
    }
}
