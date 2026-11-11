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

    private final class OffloadQueue {
        var pending: [() -> Void] = []

        var offload: AudioStack.Offload {
            { [self] work in pending.append(work) }
        }

        func run() {
            let work = pending
            pending = []
            for item in work { item() }
        }
    }

    private func wiredBackend() -> FakeAudioBackend {
        let backend = FakeAudioBackend()
        backend.sinks = [StageRig.fiveK, StageRig.speakers]
        backend.defaultSinkName = "qx_5k"
        backend.configuredDefaultSinkName = "qx_5k"
        backend.volumes["qx_5k"] = AudioSinkVolume(volume: 1, channelVolume: 1, muted: false)
        return backend
    }

    @MainActor
    func testTheWindowDoesNotWaitForTheAudioServer() async {
        let app = makeApp(EqTestDevice())
        let queue = OffloadQueue()
        var created = 0
        let backend = wiredBackend()
        let stack = AudioStack(app: app, backendFactory: { created += 1; return backend },
                               locations: .isolated(in: directory), clock: clock, hop: hops.hop,
                               offload: queue.offload)
        XCTAssertEqual(stack.status, .connecting)
        XCTAssertEqual(stack.status.message, "Connecting to the audio server\u{2026}")
        XCTAssertTrue(stack.available)
        stack.start()
        XCTAssertEqual(created, 0)
        XCTAssertEqual(stack.status, .connecting)
        XCTAssertEqual(queue.pending.count, 1)
        queue.run()
        XCTAssertEqual(created, 1)
        XCTAssertEqual(stack.status, .connecting)
        hops.drain()
        XCTAssertEqual(stack.status, .ready)
        XCTAssertNil(stack.status.message)
        XCTAssertEqual(stack.routing?.realOutput?.name, "qx_5k")
        await stack.shutdown()
        XCTAssertTrue(backend.isShutDown)
    }

    @MainActor
    func testNoAudioServerKeepsTheAppWorkingAndRetriesEveryFiveSeconds() async {
        let app = makeApp(EqTestDevice())
        let queue = OffloadQueue()
        var attempts = 0
        let backend = wiredBackend()
        let stack = AudioStack(app: app, backendFactory: { attempts += 1; return attempts < 3 ? nil : backend },
                               locations: .isolated(in: directory), clock: clock, hop: hops.hop,
                               offload: queue.offload)
        stack.start()
        app.start()
        queue.run()
        hops.drain()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(stack.status, .unavailable)
        XCTAssertEqual(stack.status.message, AudioStack.unavailableMessage)
        await until("connected") { app.state.connection.isConnected && app.eq.state.ready }
        clock.advance(4)
        XCTAssertTrue(queue.pending.isEmpty)
        clock.advance(1.5)
        XCTAssertEqual(queue.pending.count, 1)
        clock.advance(20)
        XCTAssertEqual(queue.pending.count, 1)
        queue.run()
        hops.drain()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(stack.status, .unavailable)
        clock.advance(5)
        queue.run()
        hops.drain()
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(stack.status, .ready)
        XCTAssertEqual(stack.routing?.realOutput?.name, "qx_5k")
        await stack.shutdown()
    }

    @MainActor
    func testAServerThatRestartsStopsStageReconnectsAndRunsItAgain() async {
        let app = makeApp(EqTestDevice())
        let queue = OffloadQueue()
        let first = wiredBackend()
        let second = wiredBackend()
        var made: [FakeAudioBackend] = [first, second]
        var attempts = 0
        let stack = AudioStack(app: app, backendFactory: { attempts += 1; return made.isEmpty ? nil : made.removeFirst() },
                               locations: .isolated(in: directory), clock: clock, hop: hops.hop,
                               offload: queue.offload)
        stack.start()
        queue.run()
        hops.drain()
        var settings = StageSettings.music
        settings.enabled = true
        stack.stage?.setStage(settings, editedFor: stack.stage?.outputKey)
        for _ in 0..<6 {
            clock.advance(0.5)
            hops.drain()
        }
        XCTAssertTrue(stack.stage?.isRunning == true)
        XCTAssertEqual(stack.status, .ready)

        first.connected = false
        first.changeHandler?()
        hops.drain()
        XCTAssertEqual(stack.status, .reconnecting)
        XCTAssertEqual(stack.status.message, "The audio server restarted \u{2014} reconnecting\u{2026}")
        XCTAssertFalse(stack.stage?.isRunning ?? true)
        XCTAssertTrue(first.isShutDown)
        XCTAssertEqual(stack.routing?.connected, false)

        clock.advance(2)
        XCTAssertTrue(queue.pending.isEmpty)
        clock.advance(3.5)
        XCTAssertEqual(queue.pending.count, 1)
        clock.advance(20)
        XCTAssertEqual(queue.pending.count, 1)
        queue.run()
        hops.drain()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(stack.status, .ready)
        for _ in 0..<8 {
            clock.advance(0.5)
            hops.drain()
        }
        XCTAssertTrue(stack.stage?.isRunning == true)
        XCTAssertEqual(second.inserts.count, 1)
        await stack.shutdown()
        XCTAssertTrue(second.isShutDown)
    }

    @MainActor
    func testShuttingDownWhileTheBackendIsStillBeingCreatedDiscardsIt() async {
        let app = makeApp(EqTestDevice())
        let queue = OffloadQueue()
        let backend = wiredBackend()
        let stack = AudioStack(app: app, backendFactory: { backend },
                               locations: .isolated(in: directory), clock: clock, hop: hops.hop,
                               offload: queue.offload)
        stack.start()
        await stack.shutdown()
        queue.run()
        hops.drain()
        XCTAssertTrue(backend.isShutDown)
        XCTAssertEqual(stack.status, .connecting)
    }

    @MainActor
    func testTheSwappableBackendFailsStreamsAndReportsDisconnectedUntilOneIsInstalled() throws {
        let swappable = SwappableAudioBackend()
        XCTAssertFalse(swappable.connected)
        XCTAssertTrue(swappable.sinks.isEmpty)
        XCTAssertFalse(swappable.setDefaultSink(named: "x"))
        XCTAssertFalse(swappable.scaleSinkVolume(named: "x", by: 0.5, muted: nil))
        XCTAssertThrowsError(try swappable.startTone(sink: "x") { _, _, _, _ in })
        var fired = 0
        swappable.changeHandler = { fired += 1 }
        let backend = wiredBackend()
        swappable.install(backend)
        XCTAssertTrue(swappable.connected)
        XCTAssertEqual(swappable.defaultSinkName, "qx_5k")
        XCTAssertEqual(fired, 1)
        backend.changeHandler?()
        XCTAssertEqual(fired, 2)
        XCTAssertTrue(swappable.scaleSinkVolume(named: "qx_5k", by: 0.5, muted: nil))
        XCTAssertTrue(swappable.detach() === backend)
        XCTAssertFalse(swappable.connected)
    }
}
