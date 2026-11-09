import XCTest
@testable import QudelixBar

private final class ProbeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var threads: [Bool] = []

    func record() {
        lock.lock()
        threads.append(Thread.isMainThread)
        lock.unlock()
    }

    var ranOnMain: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return threads
    }
}

final class ProbeOffMainTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("probe-off-main-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActiveSlotFile.directoryOverride = directory
        EqHistoryFile.directoryOverride = directory
    }

    override func tearDown() {
        ActiveSlotFile.directoryOverride = nil
        EqHistoryFile.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    @MainActor
    private func makeModel(probe: @escaping @Sendable () -> AppDeviceProbe) -> AppModel {
        let lock = directory.appendingPathComponent("qudelix.lock")
        return AppModel(makeLinks: {
            let link = QxFixtures.answeringLink()
            link.autoConnectOnStart = true
            return [link]
        },
                        acquireLock: { QxInstanceLock.acquire(at: lock) },
                        probeDevice: probe, clock: SystemClock(), retryInterval: 0.2, connectTimeout: 2)
    }

    @MainActor
    func testASlowProbeDoesNotBlockMainActorWork() async {
        let log = ProbeLog()
        let model = makeModel {
            log.record()
            Thread.sleep(forTimeInterval: 0.8)
            return AppDeviceProbe(present: false)
        }
        model.start()
        var ticks = 0
        let end = Date().addingTimeInterval(0.6)
        while Date() < end {
            ticks += 1
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(ticks, 15)
        XCTAssertEqual(log.ranOnMain.first, false)
        await model.shutdown()
    }

    @MainActor
    func testTheProbeRunsOffTheMainThreadEveryTime() async {
        let log = ProbeLog()
        let model = makeModel {
            log.record()
            return AppDeviceProbe(present: false)
        }
        model.start()
        let deadline = Date().addingTimeInterval(4)
        while log.ranOnMain.count < 3, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThanOrEqual(log.ranOnMain.count, 3)
        XCTAssertFalse(log.ranOnMain.contains(true))
        await model.shutdown()
    }

    @MainActor
    func testResultsHopBackAndConnect() async {
        let model = makeModel { AppDeviceProbe(present: true) }
        model.start()
        let deadline = Date().addingTimeInterval(4)
        while !model.state.connection.isConnected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(model.state.connection.isConnected)
        await model.shutdown()
    }

    @MainActor
    func testShuttingDownDuringAProbeNeverConnects() async {
        let model = makeModel {
            Thread.sleep(forTimeInterval: 0.4)
            return AppDeviceProbe(present: true)
        }
        model.start()
        try? await Task.sleep(nanoseconds: 100_000_000)
        await model.shutdown()
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(model.state.connection.isConnected)
        XCTAssertNil(model.state.status)
    }
}
