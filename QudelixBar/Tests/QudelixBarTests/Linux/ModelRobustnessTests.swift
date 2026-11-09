import XCTest
@testable import QudelixBar

private final class ReplyGate {
    private let lock = NSLock()
    private var holding = false
    private var queued: [(QxCmd, [UInt8])] = []
    private var forward: ((QxCmd, [UInt8]) -> Void)?
    private let commands: Set<QxCmd>

    init(_ commands: Set<QxCmd>) {
        self.commands = commands
    }

    func install(on link: FakeLink, holding initially: Bool) {
        forward = link.onSend
        holding = initially
        link.onSend = { [weak self] cmd, data in
            guard let self else { return }
            self.lock.lock()
            let hold = self.holding && self.commands.contains(cmd)
            if hold { self.queued.append((cmd, data)) }
            self.lock.unlock()
            if !hold { self.forward?(cmd, data) }
        }
    }

    func hold() {
        lock.lock()
        holding = true
        lock.unlock()
    }

    func release(replay: Bool) {
        lock.lock()
        holding = false
        let pending = queued
        queued = []
        lock.unlock()
        if replay { for (cmd, data) in pending { forward?(cmd, data) } }
    }

    var heldCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queued.count
    }
}

private final class OpGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false

    func wait() async {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

final class ModelRobustnessTests: XCTestCase {
    private var directory: URL!
    private var lockURL: URL!
    private var clock: ManualClock!
    private var states: [AppConnection] = []
    private var notices: [AppNotice] = []

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("model-robust-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActiveSlotFile.directoryOverride = directory
        EqHistoryFile.directoryOverride = directory
        lockURL = directory.appendingPathComponent("qudelix.lock")
        clock = ManualClock()
        states = []
        notices = []
    }

    override func tearDown() {
        ActiveSlotFile.directoryOverride = nil
        EqHistoryFile.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    @MainActor
    private func makeModel(_ links: @escaping () -> [QxLink],
                           present: @escaping @Sendable () -> Bool = { true },
                           timeout: TimeInterval = 2) -> AppModel {
        let url = lockURL
        let model = AppModel(makeLinks: links,
                             acquireLock: { QxInstanceLock.acquire(at: url) },
                             probeDevice: { AppDeviceProbe(present: present()) },
                             clock: clock, retryInterval: 2, connectTimeout: timeout)
        model.addObserver { [weak self] in self?.states.append($0.connection) }
        model.addNoticeObserver { [weak self] in self?.notices.append($0) }
        return model
    }

    private func queue(_ links: [FakeLink]) -> () -> [QxLink] {
        var remaining = links
        return {
            guard !remaining.isEmpty else { return [] }
            return [remaining.count > 1 ? remaining.removeFirst() : remaining[0]]
        }
    }

    @MainActor
    private func until(_ what: String, timeout: TimeInterval = 4,
                       _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    private func ready(_ model: AppModel) async {
        await until("connected and read") {
            model.state.connection.isConnected && model.eq.state.ready
                && model.presets.state.slots.count == 20
        }
        await model.presets.waitForIdle()
    }

    private func device(slot: Int = 2) -> EqTestDevice {
        let device = EqTestDevice(group: .b20, bands: EqTestSupport.shaped(.b20), preGain: -2,
                                  slot: slot, names: [2: "Warm", 5: "Vocal"])
        var other = EqTestSupport.shaped(.b20)
        for index in other.indices { other[index].gain = 2 }
        device.slots[5] = (-1, other)
        device.slots[2] = (-2, EqTestSupport.shaped(.b20))
        return device
    }

    private func lockIsFree() -> Bool {
        guard let probe = QxInstanceLock.acquire(at: lockURL) else { return false }
        probe.release()
        return true
    }

    @MainActor
    func testALinkThatDropsDuringTheConnectedPublishReturnsToSearchingAndReconnects() async {
        let first = device()
        let second = device()
        let model = makeModel(queue([first.link, second.link]))
        var dropped = false
        model.addObserver { state in
            if case .connected = state.connection, !dropped {
                dropped = true
                first.link.drop()
            }
        }
        model.start()
        await until("searching again") { dropped && model.state.connection == .searching }
        XCTAssertTrue(first.link.stopped)
        XCTAssertTrue(lockIsFree())
        clock.advance(2)
        await ready(model)
        XCTAssertEqual(model.state.connection, .connected(.usb))
        await model.shutdown()
    }

    @MainActor
    func testALinkThatDropsWhileTheEqIsBeingReadReturnsToSearchingAndReconnects() async {
        let first = device()
        let second = device()
        let gate = ReplyGate([.reqEqPreset])
        gate.install(on: first.link, holding: true)
        let model = makeModel(queue([first.link, second.link]))
        model.start()
        await until("preset read requested") { gate.heldCount > 0 }
        first.link.drop()
        gate.release(replay: false)
        await until("searching again") { model.state.connection == .searching && first.link.stopped }
        XCTAssertFalse(states.contains { $0.isConnected })
        XCTAssertTrue(lockIsFree())
        clock.advance(2)
        await ready(model)
        XCTAssertEqual(model.state.connection, .connected(.usb))
        await model.shutdown()
    }

    @MainActor
    func testShuttingDownWhileConnectingNeverPublishesConnected() async {
        let slow = device()
        let gate = ReplyGate([.reqEqPreset])
        gate.install(on: slow.link, holding: true)
        let model = makeModel(queue([slow.link]))
        model.start()
        await until("preset read requested") { gate.heldCount > 0 }
        await model.shutdown()
        gate.release(replay: false)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(states.contains { $0.isConnected })
        XCTAssertEqual(model.state.connection, .searching)
        XCTAssertTrue(lockIsFree())
    }

    @MainActor
    func testAnUnsupportedDeviceIsRetriedWithGrowingDelays() async {
        var other = QxFixtures.initData
        other[1] = 0x02
        let link = QxFixtures.answeringLink(initData: other)
        link.autoConnectOnStart = true
        var opens = 0
        let model = makeModel({ opens += 1; return [link] })
        model.start()
        await until("unsupported") {
            if case .unsupported = model.state.connection { return true }
            return false
        }
        for _ in 0..<60 {
            clock.advance(1)
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTAssertGreaterThanOrEqual(opens, 5)
        XCTAssertLessThanOrEqual(opens, 7)
        await model.shutdown()
    }

    @MainActor
    func testTheBackoffEndsWhenTheDeviceDisappearsAndReturns() async {
        var other = QxFixtures.initData
        other[1] = 0x02
        let link = QxFixtures.answeringLink(initData: other)
        link.autoConnectOnStart = true
        let presence = PresenceFlag()
        var opens = 0
        let model = makeModel({ opens += 1; return [link] }, present: { presence.value })
        model.start()
        await until("unsupported") {
            if case .unsupported = model.state.connection { return true }
            return false
        }
        for _ in 0..<16 {
            clock.advance(1)
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        presence.value = false
        for _ in 0..<20 {
            clock.advance(1)
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        await until("searching") { model.state.connection == .searching }
        presence.value = true
        let before = opens
        for _ in 0..<3 {
            clock.advance(1)
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        XCTAssertGreaterThan(opens, before)
        await model.shutdown()
    }

    @MainActor
    func testASlotSaveLoadAndRenameEachReportTheirOutcome() async {
        let dev = device()
        let model = makeModel(queue([dev.link]))
        model.start()
        await ready(model)
        model.presets.save(slot: 2)
        await model.presets.waitForIdle()
        model.presets.load(slot: 5)
        await model.presets.waitForIdle()
        model.presets.rename(slot: 2, to: "Mine")
        await model.presets.waitForIdle()
        XCTAssertEqual(notices.map(\.message),
                       ["Saved to slot 3.", "Loaded slot 6.", "Renamed slot 3."])
        XCTAssertTrue(notices.allSatisfy { $0.kind == .success })
        await model.shutdown()
    }

    @MainActor
    func testAFailedLoadReportsAFailureNotice() async {
        let dev = device()
        let gate = ReplyGate([.reqEqPreset])
        gate.install(on: dev.link, holding: false)
        let model = makeModel(queue([dev.link]), timeout: 0.3)
        model.start()
        await ready(model)
        gate.hold()
        model.presets.load(slot: 5)
        await until("failure notice") { !notices.isEmpty }
        XCTAssertEqual(notices.first?.kind, .failure)
        XCTAssertEqual(notices.first?.message,
                       "Could not load slot 6. Check the connection and try again.")
        gate.release(replay: false)
        await model.shutdown()
    }

    @MainActor
    func testAFailedSaveAndAFailedDeviceWriteReportFailureNotices() async {
        let dev = device()
        let model = makeModel(queue([dev.link]))
        model.start()
        await ready(model)
        var other = QxFixtures.initData
        other[1] = 0x02
        dev.link.deliver(.rspInitData, other)
        try? await Task.sleep(nanoseconds: 150_000_000)
        model.presets.save(slot: 3)
        await model.presets.waitForIdle()
        model.setMute(true)
        model.setVolume(db: -20)
        model.setDacFilter(index: 1)
        model.setEqEnabled(false)
        await model.waitForIdle()
        XCTAssertEqual(notices.map(\.message), [
            "Could not save to slot 4. Check the connection and try again.",
            "Could not change mute. Check the connection and try again.",
            "Could not change the DAC filter. Check the connection and try again.",
            "Could not turn the EQ off. Check the connection and try again.",
            "Could not change the volume. Check the connection and try again."
        ])
        XCTAssertTrue(notices.allSatisfy { $0.kind == .failure })
        await model.shutdown()
    }

    @MainActor
    func testASlotActionAfterADisconnectIsNeverSilent() async {
        let first = device()
        let model = makeModel(queue([first.link]))
        model.start()
        await ready(model)
        first.link.drop()
        await until("searching") { model.state.connection == .searching }
        model.presets.save(slot: 0)
        model.presets.load(slot: 1)
        model.presets.rename(slot: 2, to: "x")
        XCTAssertEqual(notices.map(\.message), [
            "Could not save to slot 1. Connect the 5K and try again.",
            "Could not load slot 2. Connect the 5K and try again.",
            "Could not rename slot 3. Connect the 5K and try again."
        ])
        await model.shutdown()
    }

    @MainActor
    func testEditsAreRefusedWhileAnOperationRunsAndTheModelMatchesTheDevice() async {
        let dev = device()
        let gate = ReplyGate([.reqEqPreset])
        gate.install(on: dev.link, holding: false)
        let model = makeModel(queue([dev.link]))
        model.start()
        await ready(model)
        dev.link.clearSends()
        gate.hold()
        model.presets.load(slot: 5)
        await until("load waiting for the device") { gate.heldCount > 0 }
        XCTAssertFalse(model.eq.canEdit)
        XCTAssertFalse(model.eq.state.canEdit)
        XCTAssertEqual(model.eq.writeRefusal, "The 5K is busy \u{2014} try again in a moment.")
        var edited = model.eq.state.bands[0]
        edited.gain = 9
        model.eq.setBand(0, edited)
        model.eq.setPreGain(-8)
        model.eq.undo()
        gate.release(replay: true)
        await model.presets.waitForIdle()
        await model.eq.waitForIdle()
        XCTAssertTrue(dev.link.payloads(for: .setEqBandParam).isEmpty)
        XCTAssertTrue(dev.link.payloads(for: .setEqPreGain).isEmpty)
        XCTAssertEqual(model.eq.state.bands, dev.bands.map(EqBand.init))
        XCTAssertEqual(model.eq.state.preGain, dev.preGain, accuracy: 0.01)
        XCTAssertTrue(model.eq.canEdit)
        XCTAssertTrue(model.eq.state.canEdit)
        await model.shutdown()
    }

    @MainActor
    func testASlotChangeThatArrivesWhileBusyIsAppliedWhenTheQueueDrains() async {
        let dev = device()
        let model = makeModel(queue([dev.link]))
        model.start()
        await ready(model)
        let gate = OpGate()
        model.eq.enqueueOperation { await gate.wait() }
        await until("operation running") { gate.waiting }
        var changed = EqTestSupport.shaped(.b20)
        for index in changed.indices { changed[index].gain = -4 }
        dev.bands = changed
        dev.notifyPreset(slot: 7)
        await until("status moved") { model.state.status?.activePresetIndex == 7 }
        XCTAssertNotEqual(model.eq.state.bands, changed.map(EqBand.init))
        gate.open()
        await until("reloaded") { model.eq.state.bands == changed.map(EqBand.init) }
        await model.shutdown()
    }

    @MainActor
    func testAnAbandonedOperationDoesNotClearTheBusyStateOfANewOne() async {
        let first = device()
        let second = device()
        let model = makeModel(queue([first.link, second.link]))
        model.start()
        await ready(model)
        let old = OpGate()
        let oldSlots = OpGate()
        model.eq.enqueueOperation { await old.wait() }
        model.presets.run { _ in await oldSlots.wait() }
        await until("first operation running") { old.waiting }
        first.link.drop()
        await until("searching") { model.state.connection == .searching }
        clock.advance(2)
        await ready(model)
        let fresh = OpGate()
        let freshSlots = OpGate()
        model.presets.run { _ in await freshSlots.wait() }
        model.eq.enqueueOperation { await fresh.wait() }
        await until("new slot operation running") { freshSlots.waiting }
        XCTAssertTrue(model.presets.state.busy)
        old.open()
        oldSlots.open()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(model.presets.state.busy)
        XCTAssertTrue(model.eq.isBusy)
        freshSlots.open()
        await until("idle") { !model.presets.state.busy }
        fresh.open()
        await model.shutdown()
    }

    @MainActor
    func testTheEqIsLoadingThenReady() async {
        let dev = device()
        let model = makeModel(queue([dev.link]))
        var seen: [EqLoadState] = []
        model.eq.addObserver { seen.append($0.loadState) }
        model.start()
        await ready(model)
        XCTAssertEqual(seen.first, .loading)
        XCTAssertEqual(seen.last, .ready)
        XCTAssertFalse(seen.contains(.failed))
        await model.shutdown()
    }

    @MainActor
    func testAFailedReadIsReportedAndRetryReadReadsAgain() async {
        let dev = device()
        let gate = ReplyGate([.reqEqPreset])
        gate.install(on: dev.link, holding: true)
        let model = makeModel(queue([dev.link]), timeout: 0.3)
        var seen: [EqLoadState] = []
        model.eq.addObserver { seen.append($0.loadState) }
        model.start()
        await until("connected with a failed read") {
            model.state.connection.isConnected && model.eq.state.loadState == .failed
        }
        XCTAssertFalse(model.eq.state.ready)
        gate.release(replay: false)
        model.eq.retryRead()
        XCTAssertEqual(model.eq.state.loadState, .loading)
        await until("ready") { model.eq.state.loadState == .ready }
        XCTAssertEqual(model.eq.state.bands, dev.bands.map(EqBand.init))
        var steps: [EqLoadState] = []
        for step in seen where steps.last != step { steps.append(step) }
        XCTAssertEqual(steps, [.loading, .failed, .loading, .ready])
        model.eq.retryRead()
        XCTAssertEqual(model.eq.state.loadState, .ready)
        await model.shutdown()
    }
}

private final class PresenceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = true

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}
