import XCTest
@testable import QudelixBar

private final class LockBox: @unchecked Sendable {
    var lock: InstanceLock?
}

final class InstanceLockTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("instance-lock-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testASecondClaimOnTheSameFileIsRefusedAndNamesTheHolder() throws {
        let url = scratch.appendingPathComponent(InstanceLock.fileName)
        guard case .held(let first) = InstanceLock.claim(at: url) else {
            return XCTFail("the first claim should hold the lock")
        }
        guard case .taken(let holder) = InstanceLock.claim(at: url) else {
            return XCTFail("the second claim should be refused")
        }
        XCTAssertEqual(holder, getpid())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "\(getpid())\n")
        withExtendedLifetime(first) {}
    }

    func testReleasingTheLockLetsTheNextClaimThrough() {
        let url = scratch.appendingPathComponent(InstanceLock.fileName)
        var first: InstanceLock?
        if case .held(let lock) = InstanceLock.claim(at: url) { first = lock }
        XCTAssertNotNil(first)
        first = nil

        guard case .held = InstanceLock.claim(at: url) else {
            return XCTFail("a released lock should be claimable")
        }
    }

    func testAClaimWaitsForAHolderThatIsLeaving() {
        let url = scratch.appendingPathComponent(InstanceLock.fileName)
        let box = LockBox()
        if case .held(let lock) = InstanceLock.claim(at: url) { box.lock = lock }
        XCTAssertNotNil(box.lock)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { box.lock = nil }

        let started = Date()
        guard case .held = InstanceLock.claim(at: url, patience: 5) else {
            return XCTFail("the claim should have outlasted the holder")
        }
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(waited, 0.2)
        XCTAssertLessThan(waited, 3)
    }

    func testAClaimGivesUpAfterItsPatience() {
        let url = scratch.appendingPathComponent(InstanceLock.fileName)
        guard case .held(let first) = InstanceLock.claim(at: url) else {
            return XCTFail("the first claim should hold the lock")
        }
        let started = Date()
        guard case .taken = InstanceLock.claim(at: url, patience: 0.3) else {
            return XCTFail("a live holder should win")
        }
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(waited, 0.3)
        XCTAssertLessThan(waited, 2)
        withExtendedLifetime(first) {}
    }

    func testASecondCopyIsTurnedAwayAndTheLogSaysWhy() throws {
        let url = scratch.appendingPathComponent(InstanceLock.fileName)
        XCTAssertTrue(SingleInstance.admit(at: url, patience: 0))
        XCTAssertFalse(SingleInstance.admit(at: url, patience: 0))

        let log = try XCTUnwrap(DebugLog.shared.fileURL)
        let text = [log, log.appendingPathExtension("1")]
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertTrue(text.contains("second copy refused: process \(getpid()) already has Qudelix running"))
    }

    func testAnUnusableLockFileDoesNotStopTheAppFromStarting() {
        let url = scratch.appendingPathComponent("missing/\(InstanceLock.fileName)")
        XCTAssertTrue(SingleInstance.admit(at: url, patience: 0))
    }

    func testALinkAtTheLockPathIsNotFollowed() throws {
        let target = scratch.appendingPathComponent("elsewhere")
        try Data("untouched".utf8).write(to: target)
        let url = scratch.appendingPathComponent(InstanceLock.fileName)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

        guard case .unavailable = InstanceLock.claim(at: url) else {
            return XCTFail("a symlink must not be opened")
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "untouched")
    }

    func testAFolderThatCannotBeWrittenMeansNoGuardRatherThanNoApp() {
        let url = scratch.appendingPathComponent("missing/\(InstanceLock.fileName)")
        guard case .unavailable = InstanceLock.claim(at: url) else {
            return XCTFail("an unopenable lock file must not be reported as a second copy")
        }
    }
}
