import XCTest
@testable import QudelixBar

final class BatteryRecordingTests: XCTestCase {
    private var directory: URL!
    private var clock: ManualClock!
    private var savedDataHome: String?

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("battery-recording-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActiveSlotFile.directoryOverride = directory
        EqHistoryFile.directoryOverride = directory
        savedDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        clock = ManualClock(start: Date())
    }

    override func tearDown() {
        ActiveSlotFile.directoryOverride = nil
        EqHistoryFile.directoryOverride = nil
        if let savedDataHome { setenv("XDG_DATA_HOME", savedDataHome, 1) } else { unsetenv("XDG_DATA_HOME") }
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private func link() -> FakeLink {
        let link = QxFixtures.answeringLink()
        link.autoConnectOnStart = true
        return link
    }

    @MainActor
    private func makeModel(_ links: [FakeLink], store: BatteryStore = .memory) -> AppModel {
        var remaining = links
        let lock = directory.appendingPathComponent("qudelix.lock")
        let model = AppModel(makeLinks: {
            guard !remaining.isEmpty else { return [] }
            return [remaining.count > 1 ? remaining.removeFirst() : remaining[0]]
        }, acquireLock: { QxInstanceLock.acquire(at: lock) },
                             probeDevice: { AppDeviceProbe(present: true) },
                             batteryStore: store, clock: clock, retryInterval: 2, connectTimeout: 2)
        model.batteryLog.schedule = { _, _ in }
        return model
    }

    @MainActor
    private func until(_ what: String, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(4)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func power(_ percent: Int, charging: Bool) -> [UInt8] {
        [0, QxNotifyMask.status] + QxDemoFrames.devStatus(
            power: QxDemoFrames.powerBlock(percent: percent, milliVolts: 3800,
                                           chargerConnected: charging, charging: charging))
    }

    @MainActor
    func testEachDistinctReadingIsRecordedOnceByTheOneLog() async {
        let device = link()
        let model = makeModel([device])
        model.start()
        await until("connected") { model.state.connection.isConnected }
        XCTAssertEqual(model.batteryLog.history.samples.count, 1)
        XCTAssertEqual(model.batteryLog.history.samples.last?.percent, 77)
        XCTAssertEqual(model.batteryLog.history.samples.last?.charging, true)
        device.deliver(.notification, power(77, charging: true))
        device.deliver(.notification, power(77, charging: true))
        await model.waitForIdle()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.batteryLog.history.samples.count, 1)
        device.deliver(.notification, power(74, charging: false))
        await until("second reading") { model.batteryLog.history.samples.count == 2 }
        XCTAssertEqual(model.batteryLog.history.samples.last?.percent, 74)
        XCTAssertEqual(model.batteryLog.history.samples.last?.charging, false)
        XCTAssertEqual(model.batteryGraph.state.latest?.y, 74)
        await model.shutdown()
    }

    @MainActor
    func testLosingTheLinkRecordsAGapAndStopsTheHeartbeat() async {
        let first = link()
        let model = makeModel([first, link()])
        model.start()
        await until("connected") { model.state.connection.isConnected }
        first.drop()
        await until("searching") { model.state.connection == .searching }
        XCTAssertEqual(model.batteryLog.history.samples.last?.isGap, true)
        let count = model.batteryLog.history.samples.count
        clock.advance(BatteryHistory.heartbeat - 5)
        XCTAssertEqual(model.batteryLog.history.samples.count, count)
        await model.shutdown()
    }

    @MainActor
    func testAHeartbeatKeepsAReadingEveryTenMinutes() async {
        let model = makeModel([link()])
        model.start()
        await until("connected") { model.state.connection.isConnected }
        XCTAssertEqual(model.batteryLog.history.samples.count, 1)
        clock.advance(BatteryHistory.heartbeat + 1)
        XCTAssertEqual(model.batteryLog.history.samples.count, 2)
        clock.advance(BatteryHistory.heartbeat + 1)
        XCTAssertEqual(model.batteryLog.history.samples.count, 3)
        XCTAssertEqual(Set(model.batteryLog.history.samples.compactMap(\.percent)), [77])
        await model.shutdown()
    }

    @MainActor
    func testShutdownWritesTheHistoryOnceWithAClosingGap() async {
        let url = directory.appendingPathComponent("history.json")
        let model = makeModel([link()], store: .file(url))
        model.start()
        await until("connected") { model.state.connection.isConnected }
        clock.advance(BatteryHistory.heartbeat + 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(model.batteryLog.saveCount, 0)
        await model.shutdown()
        XCTAssertEqual(model.batteryLog.saveCount, 1)
        let stored = BatteryHistoryFile.load(from: url, now: clock.now())
        XCTAssertEqual(stored.samples.count, 3)
        XCTAssertEqual(stored.samples.last?.isGap, true)
    }

    @MainActor
    func testAnExistingFileIsLoadedAndExtended() async {
        let url = directory.appendingPathComponent("history.json")
        var earlier = BatteryHistory()
        earlier.record(percent: 90, charging: false, at: clock.now().addingTimeInterval(-3600))
        earlier.recordGap(at: clock.now().addingTimeInterval(-3000))
        XCTAssertTrue(BatteryHistoryFile.save(earlier, to: url))
        let model = makeModel([link()], store: .file(url))
        XCTAssertEqual(model.batteryLog.history.samples.count, 2)
        model.start()
        await until("connected") { model.state.connection.isConnected }
        XCTAssertEqual(model.batteryLog.history.samples.count, 3)
        await model.shutdown()
        XCTAssertEqual(BatteryHistoryFile.load(from: url, now: clock.now()).samples.count, 4)
    }

    @MainActor
    func testTheMemoryStoreNeverTouchesTheDisk() async {
        setenv("XDG_DATA_HOME", directory.path, 1)
        let model = makeModel([link()])
        model.start()
        await until("connected") { model.state.connection.isConnected }
        await model.shutdown()
        let created = (try? FileManager.default.subpathsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(created.contains { $0.hasSuffix("battery-history.json") })
        XCTAssertEqual(model.batteryLog.saveCount, 0)
    }

    @MainActor
    func testTheSystemStoreUsesTheXdgDataDirectory() async {
        setenv("XDG_DATA_HOME", directory.path, 1)
        let expected = directory.appendingPathComponent("QudelixBar/battery-history.json").path
        XCTAssertEqual(BatteryHistoryFile.url.path, expected)
        let model = makeModel([link()], store: .system)
        model.start()
        await until("connected") { model.state.connection.isConnected }
        await model.shutdown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected))
        XCTAssertEqual(BatteryHistoryFile.load(from: URL(fileURLWithPath: expected), now: clock.now()).samples.count, 2)
    }

    @MainActor
    func testTheDemoModelStartsWithASeededHistoryAndNoFile() async {
        setenv("XDG_DATA_HOME", directory.path, 1)
        let model = AppModel.demo(clock: clock)
        XCTAssertGreaterThan(model.batteryLog.history.readingCount, 60)
        XCTAssertFalse(model.batteryGraph.state.isEmpty)
        let created = (try? FileManager.default.subpathsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(created.contains { $0.hasSuffix("battery-history.json") })
    }
}
