#if os(Linux)
import XCTest
import Glibc
@testable import QudelixBar

final class LinkServiceTests: XCTestCase {
    private var harness: ServiceHarness!

    override func setUp() {
        super.setUp()
        harness = ServiceHarness()
    }

    override func tearDown() {
        if harness.status == nil { harness.stop() }
        harness.cleanUp()
        harness = nil
        super.tearDown()
    }

    private func nextState(_ peer: TestPeer, _ matches: @escaping (LinkServiceState) -> Bool)
        -> LinkServiceState? {
        let frame = peer.next(where: {
            if case .state(let state) = $0 { return matches(state) }
            return false
        })
        if case .state(let state)? = frame { return state }
        return nil
    }

    func testFramesRoundTrip() {
        let state = LinkServiceState(connected: true, attachedName: "Qudelix 5K",
                                     failureReason: "waiting", needsAttention: true,
                                     unusable: "bad", busy: "other")
        let frames: [LinkServiceFrame] = [
            .hello(version: 1), .send(cmd: QxCmd.setVolume.rawValue, data: [1, 2, 3]),
            .shutdown, .welcome(version: 1), .state(state), .packet([9, 8, 7]),
        ]
        for frame in frames {
            XCTAssertEqual(LinkServiceFrame.decode(frame.encoded()), frame)
        }
        XCTAssertEqual(LinkServiceFrame.send(cmd: 0x0200, data: []).encoded(), [0x02, 0x00, 0x02])
        XCTAssertNil(LinkServiceFrame.decode([]))
        XCTAssertNil(LinkServiceFrame.decode([0x7F]))
        XCTAssertNil(LinkServiceFrame.decode([0x01]))
        XCTAssertNil(LinkServiceFrame.decode([0x82, 0x00]))
    }

    func testSocketPathPrefersTheRuntimeDirectoryAndFallsBackToTheLockDirectory() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = root.appendingPathComponent("state/link-service.lock")
        let runtime = root.appendingPathComponent("run").path
        try? FileManager.default.createDirectory(atPath: runtime, withIntermediateDirectories: true)
        XCTAssertEqual(LinkServicePaths.socketPath(environment: ["XDG_RUNTIME_DIR": runtime],
                                                   lockURL: lock),
                       runtime + "/qudelix/link.sock")
        var info = stat()
        XCTAssertEqual(stat(runtime + "/qudelix", &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(LinkServicePaths.socketPath(environment: [:], lockURL: lock),
                       root.path + "/state/link.sock")
        XCTAssertEqual(LinkServicePaths.socketPath(environment: ["XDG_RUNTIME_DIR": "relative"],
                                                   lockURL: lock),
                       root.path + "/state/link.sock")
        XCTAssertNil(LinkServicePaths.socketPath(environment: [:], lockURL: nil))
    }

    func testHelloGetsWelcomeThenState() throws {
        harness.start()
        let peer = try XCTUnwrap(TestPeer(path: harness.socketPath))
        peer.send(.hello(version: 1))
        XCTAssertEqual(peer.next(), .welcome(version: 1))
        XCTAssertEqual(peer.next(), .state(LinkServiceState()))
    }

    func testStateAfterHelloReflectsTheLiveLink() throws {
        harness.transport.bringUp()
        harness.start()
        let peer = try XCTUnwrap(TestPeer(path: harness.socketPath))
        let state = try XCTUnwrap(peer.greet())
        XCTAssertTrue(state.connected)
        XCTAssertEqual(state.attachedName, "Qudelix 5K")
    }

    func testPacketReachesTwoAttachedClients() throws {
        harness.start()
        let first = try XCTUnwrap(TestPeer(path: harness.socketPath))
        let second = try XCTUnwrap(TestPeer(path: harness.socketPath))
        first.greet()
        second.greet()
        harness.transport.deliverRaw([0xAA, 0xBB, 0xCC])
        XCTAssertEqual(first.next(), .packet([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(second.next(), .packet([0xAA, 0xBB, 0xCC]))
    }

    func testSendsFromTwoClientsReachTheTransportInArrivalOrder() throws {
        harness.start()
        let first = try XCTUnwrap(TestPeer(path: harness.socketPath))
        let second = try XCTUnwrap(TestPeer(path: harness.socketPath))
        first.greet()
        second.greet()
        let steps: [(TestPeer, QxCmd, [UInt8])] = [
            (first, .setVolume, [1]), (second, .setDacFilter, [2]),
            (first, .setEqEnable, [3]), (second, .setVolume, [4]),
        ]
        for (index, step) in steps.enumerated() {
            step.0.send(.send(cmd: step.1.rawValue, data: step.2))
            XCTAssertTrue(awaitCondition { self.harness.transport.sent.count == index + 1 })
        }
        XCTAssertEqual(harness.transport.sentCommands,
                       [.setVolume, .setDacFilter, .setEqEnable, .setVolume])
        XCTAssertEqual(harness.transport.sent.map(\.data), [[1], [2], [3], [4]])
    }

    func testCommandsOutsideTheAllowedSetAreNotForwarded() throws {
        harness.start()
        let peer = try XCTUnwrap(TestPeer(path: harness.socketPath))
        peer.greet()
        peer.send(.send(cmd: QxCmd.setUsbFsMode.rawValue, data: [1]))
        peer.send(.send(cmd: 0xFFFF, data: [1]))
        peer.send(.send(cmd: QxCmd.setVolume.rawValue, data: [5]))
        XCTAssertTrue(awaitCondition { !self.harness.transport.sent.isEmpty })
        XCTAssertEqual(harness.transport.sentCommands, [.setVolume])
    }

    func testSendBeforeHelloIsIgnored() throws {
        harness.start()
        let peer = try XCTUnwrap(TestPeer(path: harness.socketPath))
        peer.send(.send(cmd: QxCmd.setVolume.rawValue, data: [5]))
        peer.greet()
        peer.send(.send(cmd: QxCmd.setDacFilter.rawValue, data: [6]))
        XCTAssertTrue(awaitCondition { !self.harness.transport.sent.isEmpty })
        XCTAssertEqual(harness.transport.sentCommands, [.setDacFilter])
    }

    func testClientDetachingLeavesTheTransportRunning() throws {
        harness.start()
        var peer = try XCTUnwrap(TestPeer(path: harness.socketPath))
        peer.greet()
        peer = try XCTUnwrap(TestPeer(path: harness.socketPath))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(harness.transport.startCount, 1)
        XCTAssertEqual(harness.transport.stopCount, 0)
        XCTAssertNotNil(peer.greet())
        XCTAssertEqual(harness.transport.stopCount, 0)
    }

    func testLinkComingUpWithNoClientSendsTheInitRequestAtOnce() {
        harness.start()
        harness.transport.bringUp()
        XCTAssertTrue(awaitCondition { !self.harness.transport.sent.isEmpty })
        XCTAssertEqual(harness.transport.sentCommands, [.reqInitData])
        XCTAssertEqual(harness.transport.sent[0].data, QxInit.requestPayload)
    }

    func testStateChangesAreRelayed() throws {
        harness.start()
        let peer = try XCTUnwrap(TestPeer(path: harness.socketPath))
        peer.greet()
        harness.transport.failureReason = "Waiting for the 5K to offer a connection"
        let first = try XCTUnwrap(nextState(peer) { $0.failureReason != nil })
        XCTAssertEqual(first.failureReason, "Waiting for the 5K to offer a connection")
        XCTAssertFalse(first.needsAttention)
        harness.transport.failureReason = "Another program is searching for Bluetooth devices"
        harness.transport.failureNeedsAttention = true
        let second = try XCTUnwrap(nextState(peer) { $0.failureReason?.hasPrefix("Another") == true })
        XCTAssertTrue(second.needsAttention)
        harness.transport.failureReason = nil
        harness.transport.failureNeedsAttention = false
        harness.transport.bringUp("Qudelix 5K")
        let third = try XCTUnwrap(nextState(peer) { $0.connected })
        XCTAssertNil(third.failureReason)
        XCTAssertEqual(third.attachedName, "Qudelix 5K")
    }

    func testBusyAndUnusableTextsAreRelayedAndClearedWhenTheLinkComesUp() throws {
        harness.start()
        let peer = try XCTUnwrap(TestPeer(path: harness.socketPath))
        peer.greet()
        harness.transport.onLinkBusy?("held by another program")
        let busy = try XCTUnwrap(nextState(peer) { $0.busy != nil })
        XCTAssertEqual(busy.busy, "held by another program")
        harness.transport.onLinkUnusable?("writes keep failing")
        let unusable = try XCTUnwrap(nextState(peer) { $0.unusable != nil })
        XCTAssertEqual(unusable.unusable, "writes keep failing")
        harness.transport.bringUp()
        let up = try XCTUnwrap(nextState(peer) { $0.connected })
        XCTAssertNil(up.busy)
        XCTAssertNil(up.unusable)
    }

    func testSecondServiceOnTheSameLockExitsWithoutTouchingTheSocket() throws {
        harness.start()
        let built = LockedBox<Bool>()
        let second = LinkService(socketPath: harness.socketPath, lockURL: harness.lockURL,
                                 makeTransport: { built.value = true; return FakeLink(kind: .bluetooth) },
                                 log: { _ in })
        XCTAssertEqual(second.run(), 0)
        XCTAssertNil(built.value)
        XCTAssertTrue(harness.socketExists)
        let peer = try XCTUnwrap(TestPeer(path: harness.socketPath))
        XCTAssertNotNil(peer.greet())
        XCTAssertNil(harness.status)
    }

    func testStaleSocketFileIsReplaced() throws {
        let stale = LinkServiceSocket.listen(path: harness.socketPath)
        XCTAssertGreaterThanOrEqual(stale, 0)
        close(stale)
        XCTAssertTrue(harness.socketExists)
        XCTAssertFalse(harness.acceptsConnections())
        harness.start()
        let peer = try XCTUnwrap(TestPeer(path: harness.socketPath))
        XCTAssertNotNil(peer.greet())
    }

    func testShutdownMessageStopsTheTransportAndRemovesTheSocket() throws {
        harness.start()
        let peer = try XCTUnwrap(TestPeer(path: harness.socketPath))
        peer.greet()
        peer.send(.shutdown)
        XCTAssertTrue(harness.waitForExit())
        XCTAssertEqual(harness.status, 0)
        XCTAssertEqual(harness.transport.stopWaits.count, 1)
        XCTAssertEqual(harness.transport.stopCount, 1)
        XCTAssertFalse(harness.socketExists)
        XCTAssertTrue(peer.isClosed())
    }

    func testSigtermStopsTheTransportAndRemovesTheSocket() {
        harness.cleanUp()
        harness = ServiceHarness(handlesSignals: true)
        harness.start()
        kill(getpid(), SIGTERM)
        XCTAssertTrue(harness.waitForExit())
        XCTAssertEqual(harness.status, 0)
        XCTAssertEqual(harness.transport.stopWaits.count, 1)
        XCTAssertFalse(harness.socketExists)
    }

    func testSocketIsPrivateToTheUser() {
        harness.start()
        var info = stat()
        XCTAssertEqual(stat(harness.socketPath, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }
}

final class LinkServiceSpawnerTests: XCTestCase {
    func testLocateBinaryPrefersTheRunningExecutablesDirectoryThenPath() {
        let present: Set<String> = ["/opt/app/qudelix", "/usr/bin/qudelix"]
        let exists: (String) -> Bool = { present.contains($0) }
        XCTAssertEqual(LinkServiceSpawner.locateBinary(executable: "/opt/app/qudelix-app",
                                                       searchPath: "/usr/bin", isExecutable: exists),
                       "/opt/app/qudelix")
        XCTAssertEqual(LinkServiceSpawner.locateBinary(executable: "/elsewhere/qudelix-app",
                                                       searchPath: "/bin:/usr/bin", isExecutable: exists),
                       "/usr/bin/qudelix")
        XCTAssertNil(LinkServiceSpawner.locateBinary(executable: "/elsewhere/x", searchPath: "/bin",
                                                     isExecutable: exists))
        XCTAssertNil(LinkServiceSpawner.locateBinary(executable: nil, searchPath: nil,
                                                     isExecutable: exists))
    }

    func testSpawnDetachedRunsAStubWithTrimmedDescriptorsAndReapsIt() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = directory.appendingPathComponent("stub")
        let marker = directory.appendingPathComponent("marker")
        let script = "#!/bin/sh\nls /proc/self/fd | wc -l > '\(marker.path)'\necho \"$1\" >> '\(marker.path)'\n"
        try script.write(to: stub, atomically: true, encoding: .utf8)
        chmod(stub.path, 0o755)
        XCTAssertTrue(LinkServiceSpawner.spawnDetached(binary: stub.path, arguments: ["hello"],
                                                       waitForChild: true))
        let lines = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.last, "hello")
        let count = Int(lines.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "") ?? 99
        XCTAssertLessThanOrEqual(count, 5)
    }

    func testSpawnDetachedReportsAMissingBinary() {
        XCTAssertFalse(LinkServiceSpawner.spawnDetached(binary: "/nonexistent/qudelix",
                                                        arguments: [], waitForChild: true))
    }
}
#endif
