import XCTest
@testable import QudelixBar

final class AudioStackTests: XCTestCase {
    private var directory: URL!
    private var clock: ManualClock!
    private var hops: HopQueue!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("audio-stack-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActiveSlotFile.directoryOverride = directory
        EqHistoryFile.directoryOverride = directory
        clock = ManualClock()
        hops = HopQueue()
    }

    override func tearDown() {
        ActiveSlotFile.directoryOverride = nil
        EqHistoryFile.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    @MainActor
    private func makeApp(_ device: EqTestDevice) -> AppModel {
        let url = directory.appendingPathComponent("qudelix.lock")
        return AppModel(makeLinks: { [device.link] },
                        acquireLock: { QxInstanceLock.acquire(at: url) },
                        probeDevice: { AppDeviceProbe(present: true) },
                        clock: clock, retryInterval: 2, connectTimeout: 2)
    }

    @MainActor
    private func until(_ what: String, timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    func testWithABackendEveryAudioModelIsComposedAndStarted() async {
        let backend = FakeAudioBackend()
        backend.sinks = [StageRig.fiveK, StageRig.speakers]
        backend.defaultSinkName = "qx_5k"
        backend.configuredDefaultSinkName = "qx_5k"
        let app = makeApp(EqTestDevice())
        let stack = AudioStack(app: app, backend: backend, locations: .isolated(in: directory),
                               clock: clock, hop: hops.hop)
        XCTAssertTrue(stack.available)
        XCTAssertNotNil(stack.routing)
        XCTAssertNotNil(stack.stage)
        XCTAssertNotNil(stack.stage?.reporter)
        stack.start()
        hops.drain()
        XCTAssertEqual(stack.routing?.realOutput?.name, "qx_5k")
        XCTAssertNotNil(backend.changeHandler)
        await stack.shutdown()
        XCTAssertTrue(backend.isShutDown)
    }

    @MainActor
    func testWithoutABackendTheDeviceModelsStillComposeAndTheAudioOnesAreOff() async {
        let app = makeApp(EqTestDevice())
        let stack = AudioStack(app: app, backend: nil, locations: .isolated(in: directory), clock: clock)
        XCTAssertFalse(stack.available)
        XCTAssertNil(stack.stage)
        XCTAssertNil(stack.routing)
        XCTAssertTrue(AudioStack.unavailableMessage.hasPrefix("Needs PipeWire"))
        stack.start()
        app.start()
        await until("connected") { app.state.connection.isConnected && app.eq.state.ready }
        XCTAssertFalse(stack.automation.state.following)
        XCTAssertNil(stack.tune.state.busy)
        await stack.shutdown()
    }

    @MainActor
    func testShutdownEndsTheTuneSessionWritesTheBaseBackStopsStageAndThenFlushes() async {
        let backend = FakeAudioBackend()
        backend.sinks = [StageRig.fiveK, StageRig.speakers]
        backend.defaultSinkName = "qx_5k"
        backend.configuredDefaultSinkName = "qx_5k"
        let device = EqTestDevice(bands: EqTestSupport.shaped(), preGain: -3)
        let app = makeApp(device)
        let stack = AudioStack(app: app, backend: backend, locations: .isolated(in: directory),
                               clock: clock, hop: hops.hop)
        stack.start()
        hops.drain()
        app.start()
        await until("connected") { app.state.connection.isConnected && app.eq.state.ready }
        var settings = StageSettings.music
        settings.enabled = true
        stack.stage?.setStage(settings, editedFor: stack.stage?.outputKey)
        for _ in 0..<10 {
            clock.advance(0.5)
            hops.drain()
            await Task.yield()
        }
        let before = device.bands
        await stack.shutdown()
        XCTAssertEqual(device.bands, before)
        XCTAssertTrue(backend.isShutDown)
        XCTAssertEqual(backend.defaultSinkName, "qx_5k")
        XCTAssertFalse(stack.stage?.isRunning ?? true)
        XCTAssertEqual(app.state.connection, .searching)
    }

    func testTheDemoBackendHasAFiveKAndOtherOutputsAndNeverStreams() {
        let backend = DemoAudioBackend()
        XCTAssertEqual(backend.sinks.count, 2)
        XCTAssertTrue(backend.sinks[0].isQudelix5K)
        XCTAssertEqual(backend.defaultSinkName, backend.sinks[0].name)
        XCTAssertThrowsError(try backend.startMonitor(sink: "x") { _, _, _, _ in })
        XCTAssertThrowsError(try backend.startTone(sink: "x") { _, _, _, _ in })
        XCTAssertFalse(backend.setDefaultSink(named: "x"))
        XCTAssertFalse(backend.setForceRate(48000))
    }
}
