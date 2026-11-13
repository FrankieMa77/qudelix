#if os(Linux)
import XCTest
import Glibc
@testable import QudelixBar

final class ServiceLinkTests: XCTestCase {
    private var harnesses: [ServiceHarness] = []
    private var links: [ServiceLink] = []
    private var directory: URL!
    private var socketPath: String!
    private let counter = NSLock()
    private var spawnCount = 0

    private var spawns: Int {
        counter.lock()
        defer { counter.unlock() }
        return spawnCount
    }

    override func setUp() {
        super.setUp()
        directory = makeTemporaryDirectory()
        socketPath = directory.appendingPathComponent("link.sock").path
    }

    override func tearDown() {
        for link in links { link.stopAndWait(timeout: 1) }
        for harness in harnesses where harness.status == nil { harness.stop() }
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var timing: ServiceLink.Timing {
        ServiceLink.Timing(retryInterval: 0.02, spawnWindow: 3, reconnectPause: 0.1,
                           welcomeTimeout: 2, shutdownWait: 3, writeTimeout: 1, shutdownPoll: 0.02)
    }

    private func makeHarness(_ transport: FakeLink = FakeLink(kind: .bluetooth)) -> ServiceHarness {
        let harness = ServiceHarness(directory: directory, transport: transport)
        harnesses.append(harness)
        return harness
    }

    private func makeLink(spawning next: @escaping () -> ServiceHarness?,
                          peerExecutable: @escaping (Int32) -> String? = { _ in nil }) -> ServiceLink {
        let link = ServiceLink(socketPath: { self.socketPath },
                               spawner: {
                                   self.counter.lock()
                                   self.spawnCount += 1
                                   self.counter.unlock()
                                   next()?.startInBackground()
                                   return true
                               },
                               timing: timing,
                               peerExecutable: peerExecutable)
        links.append(link)
        return link
    }

    func testSpawnsWhenThereIsNoSocketAndConnectsOnceTheServiceAppears() {
        let service = makeHarness()
        service.transport.bringUp()
        let link = makeLink { service }
        let name = LockedBox<String>()
        link.onConnected = { name.value = $0 }
        XCTAssertFalse(link.isConnected)
        link.start()
        XCTAssertTrue(awaitCondition { link.isConnected })
        XCTAssertEqual(spawns, 1)
        XCTAssertEqual(name.value, "Qudelix 5K")
        XCTAssertEqual(link.attachedName, "Qudelix 5K")
        XCTAssertEqual(link.kind, .bluetooth)
        XCTAssertTrue(link.keepsArmed)
        XCTAssertFalse(link.needsInstanceLock)
    }

    func testDoesNotSpawnWhenAServiceIsAlreadyListening() {
        let service = makeHarness()
        service.start()
        let link = makeLink { nil }
        link.start()
        service.transport.bringUp()
        XCTAssertTrue(awaitCondition { link.isConnected })
        XCTAssertEqual(spawns, 0)
    }

    func testMirrorsStateIntoPropertiesAndCallbacks() {
        let service = makeHarness()
        service.transport.failureReason = "Waiting for the 5K"
        service.transport.failureNeedsAttention = true
        service.start()
        let link = makeLink { nil }
        let events = ServiceLinkEvents()
        link.onConnected = { events.add("up:\($0)") }
        link.onDisconnected = { events.add("down") }
        link.onLinkBusy = { events.add("busy:\($0)") }
        link.onLinkUnusable = { events.add("unusable:\($0)") }
        link.onPacket = { events.add("packet:\($0.count)") }
        link.start()
        XCTAssertTrue(awaitCondition { link.failureReason == "Waiting for the 5K" })
        XCTAssertTrue(link.failureNeedsAttention)
        XCTAssertFalse(link.isConnected)
        XCTAssertNil(link.attachedName)
        service.transport.onLinkBusy?("another program")
        service.transport.onLinkUnusable?("writes failing")
        XCTAssertTrue(awaitCondition { events.all.contains("unusable:writes failing") })
        XCTAssertTrue(events.all.contains("busy:another program"))
        service.transport.failureReason = nil
        service.transport.failureNeedsAttention = false
        service.transport.bringUp("Qudelix 5K")
        XCTAssertTrue(awaitCondition { link.isConnected })
        XCTAssertTrue(events.all.contains("up:Qudelix 5K"))
        XCTAssertNil(link.failureReason)
        service.transport.deliverRaw([1, 2, 3, 4])
        XCTAssertTrue(awaitCondition { events.all.contains("packet:4") })
        service.transport.drop()
        XCTAssertTrue(awaitCondition { !link.isConnected })
        XCTAssertTrue(awaitCondition { events.all.contains("down") })
    }

    func testSendReachesTheServicesTransport() {
        let service = makeHarness()
        service.transport.bringUp()
        service.start()
        let link = makeLink { nil }
        link.start()
        XCTAssertTrue(awaitCondition { link.isConnected })
        link.send(.setVolume, [7, 8])
        XCTAssertTrue(awaitCondition { !service.transport.sent.isEmpty })
        XCTAssertEqual(service.transport.sentCommands, [.setVolume])
        XCTAssertEqual(service.transport.sent[0].data, [7, 8])
    }

    func testStopClosesOnlyTheClientAndTheTransportKeepsRunning() throws {
        let service = makeHarness()
        service.transport.bringUp()
        service.start()
        let link = makeLink { nil }
        let events = ServiceLinkEvents()
        link.onDisconnected = { events.add("down") }
        link.start()
        XCTAssertTrue(awaitCondition { link.isConnected })
        link.send(.setVolume, [1])
        link.stopAndWait(timeout: 2)
        XCTAssertTrue(awaitCondition { service.transport.sentCommands.contains(.setVolume) })
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(service.transport.stopCount, 0)
        XCTAssertNil(service.status)
        XCTAssertFalse(events.all.contains("down"))
        let peer = try XCTUnwrap(TestPeer(path: socketPath))
        XCTAssertNotNil(peer.greet())
        XCTAssertEqual(spawns, 0)
    }

    func testRecycleWhileConnectedReachesTheTransportOnce() {
        let service = makeHarness()
        service.transport.bringUp()
        service.start()
        let link = makeLink { nil }
        link.start()
        XCTAssertTrue(awaitCondition { link.isConnected })
        link.recycle()
        XCTAssertTrue(awaitCondition { service.transport.recycles == 1 })
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(service.transport.recycles, 1)
        XCTAssertEqual(service.transport.stopCount, 0)
    }

    func testRecycleWhileNotConnectedSendsNothing() {
        let service = makeHarness()
        service.start()
        let link = makeLink { nil }
        link.start()
        link.recycle()
        XCTAssertTrue(awaitCondition { service.logLines.contains { $0.hasPrefix("client attached") } })
        link.recycle()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(service.transport.recycles, 0)
        XCTAssertFalse(service.logLines.contains("a client asked to restart the link"))
    }

    func testReconnectsWhenTheServiceGoesAwayAndComesBack() {
        let first = makeHarness()
        first.transport.bringUp()
        let second = ServiceHarness(directory: directory, transport: {
            let fake = FakeLink(kind: .bluetooth)
            fake.bringUp()
            return fake
        }())
        harnesses.append(second)
        let link = makeLink { second }
        let events = ServiceLinkEvents()
        link.onConnected = { _ in events.add("up") }
        link.onDisconnected = { events.add("down") }
        first.start()
        link.start()
        XCTAssertTrue(awaitCondition { link.isConnected })
        XCTAssertEqual(spawns, 0)
        first.stop()
        XCTAssertTrue(awaitCondition { !link.isConnected })
        XCTAssertTrue(awaitCondition { link.isConnected })
        XCTAssertEqual(spawns, 1)
        XCTAssertEqual(events.all, ["up", "down", "up"])
    }

    func testVersionMismatchShutsTheOldServiceDownThenRespawns() throws {
        let raw = try XCTUnwrap(RawServer(path: socketPath))
        raw.welcomeVersion = 2
        raw.serveOnce()
        let service = makeHarness()
        service.transport.bringUp()
        let link = makeLink { service }
        link.start()
        XCTAssertTrue(awaitCondition(6) { link.isConnected })
        XCTAssertEqual(raw.frames, [.hello(version: 1), .shutdown])
        XCTAssertEqual(spawns, 1)
    }

    func testVersionMismatchWaitsForTheOldServiceToCloseBeforeClosingItself() throws {
        let raw = try XCTUnwrap(RawServer(path: socketPath))
        raw.welcomeVersion = 2
        raw.holdOpen = 0.4
        raw.serveOnce()
        let service = makeHarness()
        service.transport.bringUp()
        let link = makeLink { service }
        link.start()
        XCTAssertTrue(awaitCondition(10) { link.isConnected })
        XCTAssertEqual(raw.frames, [.hello(version: 1), .shutdown])
        XCTAssertFalse(raw.closedWhileHeld)
        XCTAssertEqual(spawns, 1)
    }

    func testTheReplacementAllowanceStartsOverWithEachStart() {
        let old = makeHarness()
        old.transport.bringUp()
        old.start()
        let successor = freshHarness()
        let second = freshHarness()
        let order = LockedBox<[ServiceHarness]>()
        order.value = [successor, second]
        let link = makeLink(spawning: {
            let next = order.value?.first
            order.value = Array((order.value ?? []).dropFirst())
            return next
        }, peerExecutable: { _ in "/usr/bin/qudelix (deleted)" })
        link.start()
        XCTAssertTrue(awaitCondition(10) { link.isConnected })
        XCTAssertTrue(old.waitForExit())
        link.stopAndWait(timeout: 3)
        XCTAssertTrue(awaitCondition { !link.isConnected })
        link.start()
        XCTAssertTrue(awaitCondition(10) { link.isConnected })
        XCTAssertTrue(successor.waitForExit())
        XCTAssertEqual(spawns, 2)
        XCTAssertTrue(second.logLines.contains { $0.hasPrefix("client attached") })
    }

    private func freshHarness() -> ServiceHarness {
        let fake = FakeLink(kind: .bluetooth)
        fake.bringUp()
        return makeHarness(fake)
    }

    func testReplacedBinaryGetsShutdownAndTheLinkReconnectsToAFreshService() {
        let old = makeHarness()
        old.transport.bringUp()
        old.start()
        let successor = freshHarness()
        let lookups = LockedBox<Int>()
        let link = makeLink(spawning: { successor }, peerExecutable: { _ in
            lookups.value = (lookups.value ?? 0) + 1
            return "/usr/bin/qudelix (deleted)"
        })
        let events = ServiceLinkEvents()
        link.onConnected = { _ in events.add("up") }
        link.start()
        XCTAssertTrue(awaitCondition(6) { link.isConnected })
        XCTAssertTrue(old.waitForExit())
        XCTAssertEqual(spawns, 1)
        XCTAssertTrue(successor.logLines.contains { $0.hasPrefix("client attached") })
        XCTAssertEqual(events.all, ["up"])
        XCTAssertEqual(lookups.value, 1)
    }

    func testReplacedAgainAfterTheReplacementIsAcceptedWithoutASecondShutdown() {
        let old = makeHarness()
        old.transport.bringUp()
        old.start()
        let successor = freshHarness()
        let link = makeLink(spawning: { successor },
                            peerExecutable: { _ in "/usr/bin/qudelix (deleted)" })
        link.start()
        XCTAssertTrue(awaitCondition(6) { link.isConnected })
        XCTAssertTrue(link.isConnected)
        XCTAssertEqual(spawns, 1)
        XCTAssertNil(successor.status)
        XCTAssertEqual(successor.transport.stopCount, 0)
    }

    func testFailedLookupIsAcceptedWithoutShutdown() {
        let service = makeHarness()
        service.transport.bringUp()
        service.start()
        let link = makeLink(spawning: { nil }, peerExecutable: { _ in nil })
        link.start()
        XCTAssertTrue(awaitCondition { link.isConnected })
        XCTAssertTrue(link.isConnected)
        XCTAssertNil(service.status)
        XCTAssertEqual(spawns, 0)
    }

    func testFreshBinaryIsAcceptedWithoutShutdown() {
        let service = makeHarness()
        service.transport.bringUp()
        service.start()
        let link = makeLink(spawning: { nil }, peerExecutable: { _ in "/usr/bin/qudelix" })
        link.start()
        XCTAssertTrue(awaitCondition { link.isConnected })
        XCTAssertTrue(link.isConnected)
        XCTAssertNil(service.status)
        XCTAssertEqual(spawns, 0)
    }

    func testRealPeerLookupSeesThisProcessAsCurrent() {
        let service = makeHarness()
        service.transport.bringUp()
        service.start()
        let connection = LinkServiceSocket.connect(path: socketPath)
        defer { close(connection) }
        XCTAssertGreaterThanOrEqual(connection, 0)
        let executable = LinkServiceSpawner.peerExecutable(connection)
        XCTAssertNotNil(executable)
        XCTAssertFalse(LinkServiceSpawner.isReplaced(peerExecutable: executable))
        XCTAssertTrue(LinkServiceSpawner.isReplaced(peerExecutable: "/opt/qudelix (deleted)"))
        XCTAssertFalse(LinkServiceSpawner.isReplaced(peerExecutable: nil))
    }

    func testQxSessionOverTheLinkCompletesItsHandshake() async throws {
        let transport = QxFixtures.answeringLink(kind: .bluetooth)
        let service = makeHarness(transport)
        transport.bringUp()
        let link = makeLink { service }
        let session = QxSession(link: link, timeout: 5)
        defer { session.close(waitForLink: true) }
        try await session.connect(timeout: 5)
        XCTAssertTrue(link.isConnected)
        XCTAssertEqual(spawns, 1)
        XCTAssertTrue(transport.sentCommands.contains(.reqDevStatus))
        XCTAssertTrue(transport.sentCommands.contains(.reqEqPreset))
        let snapshot = await session.snapshot()
        XCTAssertNotNil(snapshot)
    }
}

final class LockedBox<T> {
    private let lock = NSLock()
    private var stored: T?

    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

final class ServiceLinkEvents {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ item: String) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
#endif
