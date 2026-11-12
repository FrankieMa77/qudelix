import XCTest
@testable import QudelixBar

final class ManualClock: AppClock {
    final class Entry: AppTimer {
        let due: Date
        let work: @MainActor () -> Void
        var cancelled = false

        init(due: Date, work: @escaping @MainActor () -> Void) {
            self.due = due
            self.work = work
        }

        func cancel() { cancelled = true }
    }

    private let guardLock = NSLock()
    private var current: Date
    private var entries: [Entry] = []

    init(start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        current = start
    }

    func now() -> Date {
        guardLock.lock()
        defer { guardLock.unlock() }
        return current
    }

    func schedule(after seconds: TimeInterval,
                  _ work: @escaping @MainActor () -> Void) -> AppTimer {
        guardLock.lock()
        defer { guardLock.unlock() }
        let entry = Entry(due: current.addingTimeInterval(seconds), work: work)
        entries.append(entry)
        return entry
    }

    var pendingCount: Int {
        guardLock.lock()
        defer { guardLock.unlock() }
        return entries.filter { !$0.cancelled }.count
    }

    @MainActor
    func advance(_ seconds: TimeInterval) {
        guardLock.lock()
        let target = current.addingTimeInterval(seconds)
        guardLock.unlock()
        while true {
            guardLock.lock()
            let due = entries.filter { !$0.cancelled && $0.due <= target }
                .min { $0.due < $1.due }
            if let due {
                current = max(current, due.due)
                entries.removeAll { $0 === due }
            } else {
                current = target
            }
            guardLock.unlock()
            guard let due else { return }
            due.work()
        }
    }
}

final class AppModelTests: XCTestCase {
    private var directory: URL!
    private var lockURL: URL!
    private var clock: ManualClock!
    private var states: [AppConnection] = []

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("app-model-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActiveSlotFile.directoryOverride = directory
        EqHistoryFile.directoryOverride = directory
        lockURL = directory.appendingPathComponent("qudelix.lock")
        clock = ManualClock()
        states = []
    }

    override func tearDown() {
        ActiveSlotFile.directoryOverride = nil
        EqHistoryFile.directoryOverride = nil
        StdIO.errorSink = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private func linkQueue(_ links: [FakeLink]) -> () -> [QxLink] {
        var remaining = links
        return {
            guard !remaining.isEmpty else { return [] }
            let next = remaining.count > 1 ? remaining.removeFirst() : remaining[0]
            return [next]
        }
    }

    @MainActor
    private func makeModel(links: [FakeLink],
                           present: @escaping () -> Bool = { true },
                           advice: @escaping () -> String? = { nil }) -> AppModel {
        let url = lockURL
        let model = AppModel(makeLinks: linkQueue(links),
                             acquireLock: { QxInstanceLock.acquire(at: url) },
                             lockProblem: { QxInstanceLock.unavailability(at: url) },
                             probeDevice: { AppDeviceProbe(present: present(), advice: advice()) },
                             clock: clock,
                             retryInterval: 2,
                             connectTimeout: 2)
        model.addObserver { [weak self] state in self?.states.append(state.connection) }
        return model
    }

    private func autoLink(volumeDb: Double = -12, initData: [UInt8] = QxFixtures.initData,
                          presetIndex: Int = 2, nameMask: Int = 0) -> FakeLink {
        let link = QxFixtures.answeringLink(initData: initData, volumeDb: volumeDb,
                                            presetIndex: presetIndex, nameMask: nameMask)
        link.autoConnectOnStart = true
        return link
    }

    @MainActor
    private func until(_ what: String = "condition", timeout: TimeInterval = 4,
                       _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    private func connect(_ model: AppModel) async {
        model.start()
        await until("connected") { model.state.connection.isConnected }
    }

    private func lockIsFree() -> Bool {
        guard let probe = QxInstanceLock.acquire(at: lockURL) else { return false }
        probe.release()
        return true
    }

    private func decodeVolume(_ payload: [UInt8]) -> Double {
        let raw = Int16(bitPattern: UInt16(payload[1]) << 8 | UInt16(payload[2]))
        return Double(raw) / QxScale.volume
    }

    @MainActor
    func testSearchesUntilTheDeviceAppearsThenConnects() async {
        var present = false
        let link = autoLink(volumeDb: -14)
        let model = makeModel(links: [link], present: { present })
        model.start()
        await until("searching") { model.state.connection == .searching }
        XCTAssertFalse(link.started)
        XCTAssertNil(model.state.status)
        present = true
        clock.advance(2)
        await until("connected") { model.state.connection.isConnected }
        XCTAssertEqual(model.state.connection, .connected(.usb))
        XCTAssertEqual(model.state.status?.firmware, "3.2.7")
        XCTAssertEqual(model.state.status?.modelName, "Qudelix 5K")
        XCTAssertEqual(model.state.status?.volumeDb ?? 0, -14, accuracy: 0.02)
        XCTAssertEqual(states.first, .searching)
        XCTAssertTrue(states.contains(.connecting))
        XCTAssertEqual(states.last, .connected(.usb))
        XCTAssertFalse(lockIsFree())
        await model.shutdown()
        XCTAssertTrue(lockIsFree())
    }

    @MainActor
    func testTheBluetoothLinkIsNeverStartedWhileTheUsbLinkConnects() async {
        let usb = autoLink(volumeDb: -14)
        let bluetooth = FakeLink(kind: .bluetooth)
        let url = lockURL
        let model = AppModel(makeLinks: { [usb, bluetooth] },
                             acquireLock: { QxInstanceLock.acquire(at: url) },
                             lockProblem: { QxInstanceLock.unavailability(at: url) },
                             probeDevice: { AppDeviceProbe(present: true) },
                             clock: clock,
                             retryInterval: 2,
                             connectTimeout: 2)
        await connect(model)
        XCTAssertEqual(model.state.connection, .connected(.usb))
        XCTAssertFalse(bluetooth.started)
        XCTAssertFalse(bluetooth.stopped)
        await model.shutdown()
        XCTAssertFalse(bluetooth.started)
    }

    private final class ArmedLinks {
        private(set) var created: [FakeLink] = []
        var failureReason: String? = BluezLinkFailure.waitingForLink

        func make() -> FakeLink {
            let link = QxFixtures.answeringLink(kind: .bluetooth)
            link.keepsArmed = true
            link.failureReason = failureReason
            created.append(link)
            return link
        }
    }

    @MainActor
    private func armedModel(_ armed: ArmedLinks, usb: @escaping () -> FakeLink? = { nil },
                            usbPresent: @escaping () -> Bool = { false }) -> AppModel {
        let url = lockURL
        let model = AppModel(makeLinks: { (usb().map { [$0 as QxLink] } ?? []) + [armed.make()] },
                             acquireLock: { QxInstanceLock.acquire(at: url) },
                             lockProblem: { QxInstanceLock.unavailability(at: url) },
                             probeDevice: { AppDeviceProbe(present: true, usbPresent: usbPresent()) },
                             clock: clock,
                             retryInterval: 2,
                             connectTimeout: 2,
                             bluetoothConnectTimeout: 0.05)
        model.addObserver { [weak self] state in self?.states.append(state.connection) }
        return model
    }

    @MainActor
    func testTheBluetoothLinkArmsWhileTheFiveKIsOffAndShowsTheWaitingText() async {
        let armed = ArmedLinks()
        let model = armedModel(armed)
        model.start()
        await until("waiting") { model.state.connection == .waiting(BluezLinkFailure.waitingForLink) }
        XCTAssertEqual(armed.created[0].startCount, 1)
        XCTAssertTrue(lockIsFree())
        XCTAssertFalse(states.contains(.connecting))
        armed.failureReason = nil
        await model.shutdown()
        XCTAssertEqual(armed.created[0].stopCount, 1)
    }

    @MainActor
    func testAnUnknownDeviceTextFromTheTransportIsShownAsIs() async {
        let armed = ArmedLinks()
        armed.failureReason = BluezLinkFailure.noDeviceKnown
        let model = armedModel(armed)
        model.start()
        await until("text") { model.state.connection == .waiting(BluezLinkFailure.noDeviceKnown) }
        await model.shutdown()
    }

    @MainActor
    func testRepeatedBluetoothTimeoutsNeverRestartOrRecreateTheLink() async {
        let armed = ArmedLinks()
        let model = armedModel(armed)
        model.start()
        for round in 1...4 {
            await until("cycle \(round)") { armed.created.count >= round }
            await settle()
            clock.advance(0.25)
        }
        await until("fifth cycle") { armed.created.count >= 5 }
        let first = armed.created[0]
        XCTAssertEqual(first.startCount, 1)
        XCTAssertEqual(first.stopCount, 0)
        XCTAssertFalse(first.stopped)
        for other in armed.created.dropFirst() {
            XCTAssertEqual(other.startCount, 0)
            XCTAssertEqual(other.stopCount, 0)
        }
        XCTAssertEqual(model.state.connection, .waiting(BluezLinkFailure.waitingForLink))
        await model.shutdown()
    }

    @MainActor
    func testTheArmedLinkIsAdoptedTheMomentItComesUpAndTheLockIsTakenThen() async {
        let armed = ArmedLinks()
        let model = armedModel(armed)
        model.start()
        await until("waiting") { model.state.connection == .waiting(BluezLinkFailure.waitingForLink) }
        XCTAssertTrue(lockIsFree())
        armed.created[0].bringUp()
        await until("connected") { model.state.connection.isConnected }
        XCTAssertEqual(model.state.connection, .connected(.bluetooth))
        XCTAssertFalse(lockIsFree())
        XCTAssertEqual(armed.created[0].stopCount, 0)
        XCTAssertEqual(armed.created[0].startCount, 1)
        await model.shutdown()
        XCTAssertTrue(lockIsFree())
    }

    @MainActor
    func testABusyLockTearsTheLinkDownAndKeepsItArmed() async {
        let armed = ArmedLinks()
        let model = armedModel(armed)
        let foreign = QxInstanceLock.acquire(at: lockURL)
        XCTAssertNotNil(foreign)
        model.start()
        await until("waiting") { model.state.connection == .waiting(BluezLinkFailure.waitingForLink) }
        armed.created[0].bringUp()
        await until("busy") { model.state.connection == .busy }
        XCTAssertEqual(armed.created[0].recycles, 1)
        XCTAssertEqual(armed.created[0].stopCount, 0)
        XCTAssertFalse(model.state.connection.isConnected)
        foreign?.release()
        clock.advance(2)
        await until("armed again") { model.state.connection == .waiting(BluezLinkFailure.waitingForLink) }
        armed.created[0].bringUp()
        await until("connected") { model.state.connection.isConnected }
        XCTAssertEqual(armed.created[0].startCount, 1)
        await model.shutdown()
    }

    @MainActor
    func testAUsbSessionConnectingStopsTheArmedBluetoothLink() async {
        let armed = ArmedLinks()
        var usbReady = false
        let usb = autoLink(volumeDb: -14)
        let model = armedModel(armed, usb: { usb }, usbPresent: { usbReady })
        model.start()
        await until("waiting") { model.state.connection == .waiting(BluezLinkFailure.waitingForLink) }
        let link = armed.created[0]
        XCTAssertEqual(link.startCount, 1)
        XCTAssertFalse(usb.started)
        usbReady = true
        await settle()
        clock.advance(0.25)
        await until("usb connected") { model.state.connection == .connected(.usb) }
        XCTAssertEqual(link.stopCount, 1)
        XCTAssertTrue(link.stopped)
        await model.shutdown()
    }

    @MainActor
    func testShutdownDuringTheCompatibilityCheckReleasesTheLinkAndTheLock() async {
        let link = autoLink()
        let model = makeModel(links: [link])
        var shutdown: Task<Void, Never>?
        model.beforeCompatibilityCheck = {
            shutdown = Task { @MainActor in await model.shutdown() }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        model.start()
        await until("link started") { link.started }
        await until("shutdown requested") { shutdown != nil }
        await shutdown?.value
        await until("lock released") { lockIsFree() }
        await until("link closed") { link.stopped }
        XCTAssertFalse(states.contains { $0.isConnected })
        XCTAssertFalse(model.state.connection.isConnected)
    }

    @MainActor
    func testRetriesEveryTwoSecondsWhileSearching() async {
        var probes = 0
        let model = makeModel(links: [autoLink()], present: { probes += 1; return false })
        model.start()
        await until("first probe") { probes == 1 }
        clock.advance(1.9)
        await Task.yield()
        XCTAssertEqual(probes, 1)
        clock.advance(0.2)
        await until("second probe") { probes == 2 }
        await model.shutdown()
    }

    @MainActor
    func testLinkLossClosesTheSessionReleasesTheLockAndSearchesAgain() async {
        let first = autoLink()
        let second = autoLink(volumeDb: -30)
        let model = makeModel(links: [first, second])
        await connect(model)
        first.drop()
        await until("searching again") { model.state.connection == .searching }
        XCTAssertTrue(first.stopped)
        XCTAssertNil(model.state.status)
        XCTAssertTrue(lockIsFree())
        clock.advance(2)
        await until("reconnected") { model.state.connection.isConnected }
        XCTAssertEqual(model.state.status?.volumeDb ?? 0, -30, accuracy: 0.02)
        await model.shutdown()
    }

    @MainActor
    func testBusyWhileAnotherProcessHoldsTheLock() async {
        let held = QxInstanceLock.acquire(at: lockURL)
        XCTAssertNotNil(held)
        let link = autoLink()
        let model = makeModel(links: [link])
        model.start()
        await until("busy") { model.state.connection == .busy }
        XCTAssertFalse(link.started)
        held?.release()
        clock.advance(2)
        await until("connected") { model.state.connection.isConnected }
        await model.shutdown()
    }

    @MainActor
    func testADeviceHeldByAnotherUserIsBusyWithoutBackingOff() async {
        let blocked = autoLink()
        blocked.busyText = "held elsewhere"
        let free = autoLink()
        let model = makeModel(links: [blocked, free])
        model.start()
        await until("busy") { model.state.connection == .busy }
        await until("lock released") { lockIsFree() }
        XCTAssertTrue(blocked.stopped)
        XCTAssertNil(model.state.status)
        let before = states.count
        clock.advance(2)
        await until("connected") { model.state.connection.isConnected }
        XCTAssertGreaterThan(states.count, before)
        XCTAssertFalse(states.contains { if case .error = $0 { return true } else { return false } })
        await model.shutdown()
    }

    @MainActor
    func testAnUnusableLockFileIsAnErrorNamingThePathNotAFreePass() async throws {
        let target = directory.appendingPathComponent("elsewhere")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: lockURL.path, withDestinationPath: target.path)
        let link = autoLink()
        let model = makeModel(links: [link])
        model.start()
        await until("error") {
            if case .error = model.state.connection { return true }
            return false
        }
        guard case .error(let message) = model.state.connection else { return XCTFail() }
        XCTAssertTrue(message.contains(lockURL.path), message)
        XCTAssertFalse(link.started)
        await model.shutdown()
    }

    @MainActor
    func testAnUnsupportedDeviceIsRefusedWithoutAnyWrite() async {
        var other = QxFixtures.initData
        other[1] = 0x02
        let link = autoLink(initData: other)
        let model = makeModel(links: [link])
        model.start()
        await until("unsupported") {
            if case .unsupported = model.state.connection { return true }
            return false
        }
        guard case .unsupported(let reason) = model.state.connection else { return }
        XCTAssertTrue(reason.contains("not supported"))
        XCTAssertFalse(link.sentCommands.isEmpty)
        XCTAssertTrue(link.sentCommands.allSatisfy { QxCompatibility.isRequest($0) })
        XCTAssertTrue(link.stopped)
        XCTAssertTrue(lockIsFree())
        model.setMute(true)
        model.setVolume(db: -5)
        await model.waitForIdle()
        XCTAssertTrue(link.sentCommands.allSatisfy { QxCompatibility.isRequest($0) })
        await model.shutdown()
    }

    @MainActor
    func testNoTransportAndPermissionAdviceAreSurfaced() async {
        let none = AppModel(makeLinks: { [] },
                            acquireLock: { QxInstanceLock.acquire(at: nil) },
                            probeDevice: { AppDeviceProbe(present: false, advice: "fix udev") },
                            clock: clock)
        none.start()
        await until("no transport") { none.state.connection == .noTransport("fix udev") }
        await none.shutdown()

        let link = autoLink()
        let denied = makeModel(links: [link], advice: { "permission denied" })
        denied.start()
        await until("permission") { denied.state.connection == .permissionDenied("permission denied") }
        XCTAssertFalse(link.started)
        await denied.shutdown()
    }

    @MainActor
    func testAFailedHandshakeIsAnErrorAndKeepsRetrying() async {
        let quiet = FakeLink()
        quiet.autoConnectOnStart = true
        quiet.onSend = { _, _ in }
        let model = AppModel(makeLinks: { [quiet] },
                             acquireLock: { QxInstanceLock.acquire(at: nil) },
                             probeDevice: { AppDeviceProbe(present: true) },
                             clock: clock, connectTimeout: 0.3)
        model.start()
        await until("error") {
            if case .error = model.state.connection { return true }
            return false
        }
        XCTAssertTrue(clock.pendingCount > 0)
        await model.shutdown()
    }

    @MainActor
    func testStatusIsPublishedOnNotifications() async {
        let link = autoLink()
        let model = makeModel(links: [link])
        await connect(model)
        var seen: [QxStatusSnapshot] = []
        model.addObserver { if let status = $0.status { seen.append(status) } }
        let before = seen.count
        link.deliver(.notification, [0, QxNotifyMask.status] + QxFixtures.devStatus(volumeDb: -25))
        await until("volume update") { abs((model.state.status?.volumeDb ?? 0) + 25) < 0.05 }
        XCTAssertGreaterThan(seen.count, before)
        link.deliver(.notification, [130, 0, 0])
        await until("eq off") { model.state.status?.eqEnabled == false }
        link.deliver(.notification, [129, 0, 4])
        await until("slot 5") { model.state.status?.activePresetIndex == 4 }
        await model.shutdown()
    }

    @MainActor
    func testTheActivePresetNameIsResolvedLikeStatus() async {
        let link = autoLink(presetIndex: 2)
        let model = makeModel(links: [link])
        await connect(model)
        XCTAssertEqual(model.state.status?.activePresetIndex, 2)
        XCTAssertEqual(model.state.status?.activePresetName, "Slot 3")
        XCTAssertEqual(model.state.status?.activePresetLabel, "3 — Slot 3")
        XCTAssertEqual(model.state.status?.eqType, "PEQ")
        link.deliver(.notification, [129, 0, 6])
        await until("slot 7 named") { model.state.status?.activePresetName == "Slot 7" }
        await model.shutdown()
    }

    @MainActor
    func testRapidVolumeChangesCoalesceAndTheLastValueWins() async {
        let link = autoLink()
        let model = makeModel(links: [link])
        await connect(model)
        link.clearSends()
        for step in 0..<10 { model.setVolume(db: -30 + Double(step)) }
        await model.waitForIdle()
        let writes = link.payloads(for: .setVolume)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(decodeVolume(writes[0]), -21, accuracy: 0.02)
        XCTAssertEqual(model.state.status?.volumeDb ?? 0, -21, accuracy: 0.02)

        link.clearSends()
        for step in 0..<6 {
            model.setVolume(db: -40 + Double(step))
            await Task.yield()
        }
        await model.waitForIdle()
        let spread = link.payloads(for: .setVolume).map(decodeVolume)
        XCTAssertFalse(spread.isEmpty)
        XCTAssertLessThanOrEqual(spread.count, 6)
        XCTAssertEqual(spread, spread.sorted())
        XCTAssertEqual(spread.last ?? 0, -35, accuracy: 0.02)
        await model.shutdown()
    }

    @MainActor
    func testVolumeIsClampedToTheDeviceCeiling() async {
        let link = autoLink()
        let model = makeModel(links: [link])
        await connect(model)
        link.clearSends()
        model.setVolume(db: 9)
        await model.waitForIdle()
        XCTAssertEqual(decodeVolume(link.payloads(for: .setVolume)[0]), 0, accuracy: 0.02)
        model.setVolume(db: -200)
        await model.waitForIdle()
        XCTAssertEqual(decodeVolume(link.payloads(for: .setVolume)[1]), -60, accuracy: 0.02)
        XCTAssertEqual(model.state.status?.volumeRange, -60...0)
        await model.shutdown()
    }

    @MainActor
    func testMuteFilterAndEqSendExactlyTheirCommands() async {
        let link = autoLink()
        let model = makeModel(links: [link])
        await connect(model)
        link.clearSends()
        model.setMute(true)
        model.setDacFilter(index: 2)
        model.setEqEnabled(false)
        await model.waitForIdle()
        XCTAssertEqual(link.sentCommands, [.setVolume, .setDacFilter, .setEqEnable])
        XCTAssertEqual(link.sent[0].data, [QxVolumeParam.mute.rawValue, 0, 1])
        XCTAssertEqual(link.sent[1].data, [2])
        XCTAssertEqual(link.sent[2].data, [QxEqGroup.user.rawValue, 0])
        XCTAssertEqual(model.state.status?.muted, true)
        XCTAssertEqual(model.state.status?.dacFilterIndex, 2)
        XCTAssertEqual(model.state.status?.eqEnabled, false)
        link.clearSends()
        model.setMute(false)
        model.setDacFilter(index: 99)
        await model.waitForIdle()
        XCTAssertEqual(link.sent.map(\.data), [[QxVolumeParam.mute.rawValue, 0, 0]])
        await model.shutdown()
    }

    @MainActor
    func testADeviceEchoDoesNotOverwriteAFreshEdit() async {
        let link = autoLink()
        let model = makeModel(links: [link])
        await connect(model)
        model.setVolume(db: -33)
        await model.waitForIdle()
        link.deliver(.notification, [0, QxNotifyMask.status] + QxFixtures.devStatus(volumeDb: -12))
        await until("a refresh") { model.state.status != nil }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(model.state.status?.volumeDb ?? 0, -33, accuracy: 0.02)
        clock.advance(2)
        link.deliver(.notification, [0, QxNotifyMask.status] + QxFixtures.devStatus(volumeDb: -12))
        await until("echo window over") { abs((model.state.status?.volumeDb ?? 0) + 12) < 0.05 }
        await model.shutdown()
    }

    @MainActor
    func testSaveAllFiresOnceFiveSecondsAfterTheLastPersistingEdit() async {
        let link = autoLink()
        let model = makeModel(links: [link])
        await connect(model)
        link.clearSends()
        model.setEqEnabled(false)
        await model.waitForIdle()
        XCTAssertTrue(model.hasPendingSave)
        clock.advance(4)
        model.setEqEnabled(true)
        await model.waitForIdle()
        clock.advance(4)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(link.sentCommands.contains(.saveAll))
        clock.advance(1.1)
        await until("saveAll") { link.sentCommands.contains(.saveAll) }
        clock.advance(30)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(link.sentCommands.filter { $0 == .saveAll }.count, 1)
        XCTAssertFalse(model.hasPendingSave)
        await model.shutdown()
        XCTAssertEqual(link.sentCommands.filter { $0 == .saveAll }.count, 1)
    }

    @MainActor
    func testEditsTheMacDoesNotPersistNeverSaveAll() async {
        let link = autoLink()
        let model = makeModel(links: [link])
        await connect(model)
        link.clearSends()
        model.setVolume(db: -20)
        model.setMute(true)
        model.setDacFilter(index: 4)
        await model.waitForIdle()
        XCTAssertFalse(model.hasPendingSave)
        clock.advance(60)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await model.shutdown()
        XCTAssertFalse(link.sentCommands.contains(.saveAll))
    }

    @MainActor
    func testAPendingSaveIsFlushedBeforeTheSessionCloses() async {
        let link = autoLink()
        let model = makeModel(links: [link])
        await connect(model)
        link.clearSends()
        model.setEqEnabled(false)
        await model.waitForIdle()
        XCTAssertFalse(link.sentCommands.contains(.saveAll))
        await model.shutdown()
        XCTAssertEqual(link.sentCommands.last, .saveAll)
        XCTAssertTrue(link.stopped)
        XCTAssertTrue(lockIsFree())
    }

    @MainActor
    func testALostLinkDropsThePendingSaveInsteadOfWritingToADeadLink() async {
        let link = autoLink()
        let model = makeModel(links: [link, autoLink()])
        await connect(model)
        model.setEqEnabled(false)
        await model.waitForIdle()
        link.clearSends()
        link.drop()
        await until("searching") { model.state.connection == .searching }
        XCTAssertFalse(model.hasPendingSave)
        await model.shutdown()
        XCTAssertFalse(link.sentCommands.contains(.saveAll))
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    @MainActor
    private func bluetoothModel(attention: Bool, built: @escaping () -> Void) -> AppModel {
        let url = lockURL
        let model = AppModel(makeLinks: {
                                 built()
                                 let link = FakeLink(kind: .bluetooth)
                                 link.onSend = { _, _ in }
                                 link.failureReason = "found Qudelix-5K, but it is not connected"
                                 link.failureNeedsAttention = attention
                                 return [link]
                             },
                             acquireLock: { QxInstanceLock.acquire(at: url) },
                             lockProblem: { QxInstanceLock.unavailability(at: url) },
                             probeDevice: { AppDeviceProbe(present: true) },
                             clock: clock,
                             retryInterval: 2,
                             connectTimeout: 2,
                             bluetoothConnectTimeout: 0.05)
        model.addObserver { [weak self] state in self?.states.append(state.connection) }
        return model
    }

    @MainActor
    func testABluetoothAttemptThatSawNothingStaysSearchingAndBacksOff() async {
        var attempts = 0
        let model = bluetoothModel(attention: false, built: { attempts += 1 })
        model.start()
        await until("first attempt") { attempts == 1 }
        await until("searching") { model.state.connection == .searching }
        await settle()
        clock.advance(2)
        await until("second attempt") { attempts == 2 }
        await settle()
        clock.advance(2)
        await settle()
        XCTAssertEqual(attempts, 2)
        clock.advance(2)
        await until("third attempt") { attempts == 3 }
        XCTAssertFalse(states.contains { if case .error = $0 { return true } else { return false } })
        await model.shutdown()
    }

    @MainActor
    func testABluetoothFailureOnAnAudioConnectedDeviceShowsTheReasonAndBacksOff() async {
        var attempts = 0
        let model = bluetoothModel(attention: true, built: { attempts += 1 })
        model.start()
        await until("error") {
            model.state.connection == .error("found Qudelix-5K, but it is not connected")
        }
        await settle()
        clock.advance(2)
        await until("second attempt") { attempts == 2 }
        await settle()
        clock.advance(2)
        await settle()
        XCTAssertEqual(attempts, 2)
        await model.shutdown()
    }
}
