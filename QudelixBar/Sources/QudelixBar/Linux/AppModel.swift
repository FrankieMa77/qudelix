import Foundation

package enum AppConnection: Equatable {
    case noTransport(String?)
    case permissionDenied(String)
    case searching
    case busy
    case connecting
    case connected(QxLinkKind)
    case unsupported(String)
    case error(String)

    package var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

package struct AppModelState: Equatable {
    package var connection: AppConnection = .searching
    package var status: QxStatusSnapshot?

    package init() {}
}

package enum AppNoticeKind: Equatable {
    case success
    case failure
}

package struct AppNotice: Equatable {
    package var kind: AppNoticeKind
    package var message: String

    package init(kind: AppNoticeKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

package struct AppDeviceProbe: Sendable {
    package var present: Bool
    package var advice: String?

    package init(present: Bool, advice: String? = nil) {
        self.present = present
        self.advice = advice
    }

    package static func system() -> AppDeviceProbe {
        let report = Probe.report(.system())
        let usb = report.nodes.contains { $0.isQudelix }
        let present = BluezPresence.resolve(usb: usb, pinned: BluezTransport.pinnedDevicePath() != nil,
                                            bluez: { BluezPresence.system().qudelixPresent() })
        return AppDeviceProbe(present: present, advice: Probe.permissionAdvice(report))
    }
}

package extension QxStatusSnapshot {
    var eqGroupLabel: String { QxFormat.groupLabel(eqGroup) }

    var activePresetLabel: String {
        activePresetIndex.map { "\($0 + 1) — \(QxFormat.presetLabel($0, activePresetName))" }
            ?? "None (live EQ)"
    }

    var volumeRange: ClosedRange<Double> {
        let ceiling = volumeCeilingDb ?? 0
        return (ceiling - 60)...ceiling
    }

    var eqBandsLabel: String { "\(eqGroup.bandCount)-band" }

    var activeSlotLabel: String {
        activePresetIndex.map { "Slot \($0 + 1) \u{00B7} \(QxFormat.presetLabel($0, activePresetName))" }
            ?? "None (live EQ)"
    }

    var linkLabel: String { linkKind == .usb ? "USB" : "Bluetooth" }

    var batteryLabel: String {
        guard let percent = batteryPercent else { return "Unknown" }
        if charging { return "\(percent)% — plugged in, charging" }
        return chargerConnected ? "\(percent)% — plugged in, not charging" : "\(percent)%"
    }
}

@MainActor
package final class AppModel {
    package static let saveDelay: TimeInterval = 5
    package static let echoWindow: TimeInterval = 1.5

    package static var dacFilters: [String] { QxStatusParser.dacFilters }

    private enum Write {
        case mute(Bool)
        case filter(Int)
        case eq(Bool, persist: Bool)
        case volume(Double)
    }

    private struct Hold<Value> {
        var value: Value
        var until: Date
    }

    private let linkFactory: () -> [QxLink]
    private let acquireLock: () -> QxInstanceLock?
    private let lockProblem: () -> String?
    private let probeDevice: @Sendable () -> AppDeviceProbe
    let clock: AppClock
    private let retryInterval: TimeInterval
    private let connectTimeout: TimeInterval
    private let bluetoothConnectTimeout: TimeInterval

    private var observers: [Int: (AppModelState) -> Void] = [:]
    private var nextObserverID = 0
    private var noticeObservers: [Int: (AppNotice) -> Void] = [:]
    private var nextNoticeObserverID = 0
    package private(set) var state = AppModelState()

    private(set) var session: QxSession?
    private var lock: QxInstanceLock?
    private var retryTimer: AppTimer?
    private var saveTimer: AppTimer?
    private var heartbeatTimer: AppTimer?
    private var notificationTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var attempting = false
    private var stopped = false
    private var started = false
    private var pendingSave = false
    private var requestedNames: Set<Int> = []
    private var failureStreak = 0
    private var retryDelay: TimeInterval
    private var lastProbe: (present: Bool, advice: String?)?

    package private(set) lazy var eq = EqEditorModel(host: self)
    package private(set) lazy var presets = PresetSlotsModel(host: self)
    private(set) lazy var eqHost = LinuxEqHost(app: self)
    let batteryLog: BatteryLog
    package private(set) lazy var batteryGraph = BatteryGraphModel(host: self, log: batteryLog)
    var libraryEnvironment = LibraryEnvironment.system()
    package private(set) lazy var library = LibraryModel(host: self, environment: libraryEnvironment)

    private var pendingVolume: Double?
    private var pendingWrites: [Write] = []
    private var volumeHold: Hold<Double>?
    private var muteHold: Hold<Bool>?
    private var filterHold: Hold<Int>?
    private var eqHold: Hold<Bool>?

    package init(makeLinks: @escaping () -> [QxLink],
                 acquireLock: @escaping () -> QxInstanceLock? = {
                     QxInstanceLock.acquire(at: QxInstanceLock.defaultURL)
                 },
                 lockProblem: @escaping () -> String? = {
                     QxInstanceLock.unavailability(at: QxInstanceLock.defaultURL)
                 },
                 probeDevice: @escaping @Sendable () -> AppDeviceProbe = { AppDeviceProbe.system() },
                 batteryStore: BatteryStore = .memory,
                 clock: AppClock = SystemClock(),
                 retryInterval: TimeInterval = 2,
                 connectTimeout: TimeInterval = 3,
                 bluetoothConnectTimeout: TimeInterval = QxLinkTimeouts.bluetoothAppearance) {
        self.linkFactory = makeLinks
        self.acquireLock = acquireLock
        self.lockProblem = lockProblem
        self.probeDevice = probeDevice
        self.batteryLog = batteryStore.makeLog(now: clock.now())
        self.clock = clock
        self.retryInterval = retryInterval
        self.retryDelay = retryInterval
        self.connectTimeout = connectTimeout
        self.bluetoothConnectTimeout = bluetoothConnectTimeout
    }

    @discardableResult
    package func addObserver(_ observer: @escaping (AppModelState) -> Void) -> Int {
        nextObserverID += 1
        observers[nextObserverID] = observer
        observer(state)
        return nextObserverID
    }

    package func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    @discardableResult
    package func addNoticeObserver(_ observer: @escaping (AppNotice) -> Void) -> Int {
        nextNoticeObserverID += 1
        noticeObservers[nextNoticeObserverID] = observer
        return nextNoticeObserverID
    }

    package func removeNoticeObserver(_ id: Int) {
        noticeObservers[id] = nil
    }

    func notify(_ kind: AppNoticeKind, _ message: String) {
        let notice = AppNotice(kind: kind, message: message)
        for observer in noticeObservers.values { observer(notice) }
    }

    static let retryAdvice = " Check the connection and try again."

    package var hasPendingSave: Bool { pendingSave }

    package func start() {
        guard !started, !stopped else { return }
        started = true
        Task { @MainActor in await self.attempt() }
    }

    package func shutdown() async {
        guard !stopped else { return }
        stopped = true
        retryTimer?.cancel()
        retryTimer = nil
        eqHost.onTuneShutdown?()
        eqHost.onQuit?()
        await drainTask?.value
        await flushSave()
        saveTimer?.cancel()
        saveTimer = nil
        notificationTask?.cancel()
        notificationTask = nil
        releaseSession()
        publish { $0.status = nil; $0.connection = .searching }
        batteryLog.appWillTerminate(at: clock.now())
    }

    package func waitForIdle() async {
        await drainTask?.value
    }

    package func setVolume(db: Double) {
        guard db.isFinite, state.connection.isConnected else { return }
        let range = state.status?.volumeRange ?? -60...0
        let clamped = max(range.lowerBound, min(range.upperBound, db))
        volumeHold = Hold(value: clamped, until: clock.now().addingTimeInterval(Self.echoWindow))
        pendingVolume = clamped
        republishLocal()
        kick()
    }

    package func setMute(_ on: Bool) {
        guard state.connection.isConnected else { return }
        muteHold = Hold(value: on, until: clock.now().addingTimeInterval(Self.echoWindow))
        pendingWrites.append(.mute(on))
        republishLocal()
        kick()
    }

    package func setDacFilter(index: Int) {
        guard state.connection.isConnected,
              QxStatusParser.dacFilters.indices.contains(index) else { return }
        filterHold = Hold(value: index, until: clock.now().addingTimeInterval(Self.echoWindow))
        pendingWrites.append(.filter(index))
        republishLocal()
        kick()
    }

    package func setEqEnabled(_ on: Bool) {
        setEqEnabled(on, persist: true)
    }

    func setEqEnabled(_ on: Bool, persist: Bool) {
        guard state.connection.isConnected else { return }
        eqHold = Hold(value: on, until: clock.now().addingTimeInterval(Self.echoWindow))
        pendingWrites.append(.eq(on, persist: persist))
        republishLocal()
        kick()
    }

    package func flushSave() async {
        saveTimer?.cancel()
        saveTimer = nil
        await eq.flushWrites()
        guard pendingSave, let session, session.isConnected, !eq.sessionActive else { return }
        pendingSave = false
        let committed = await eq.committingToFlash(session) {
            _ = await eq.writeRealShapes(session)
            DebugLog.shared.log("asking the device to persist settings")
            try? await session.saveAll()
        }
        guard !committed else { return }
        DebugLog.shared.log("flash save skipped: could not put the base EQ back first")
        pendingSave = true
        if !stopped { armSave() }
    }

    private func publish(_ change: (inout AppModelState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        let previous = state
        state = next
        recordBattery(previous: previous.status, current: next.status)
        for observer in observers.values { observer(next) }
        eq.statusChanged(next.status)
        presets.statusChanged(next.status)
        batteryGraph.refresh()
    }

    private func recordBattery(previous: QxStatusSnapshot?, current: QxStatusSnapshot?) {
        if let current, let percent = current.batteryPercent {
            batteryLog.record(percent: percent, charging: current.charging, at: clock.now())
            if heartbeatTimer == nil { scheduleHeartbeat() }
        } else if previous != nil, current == nil {
            batteryLog.recordGap(at: clock.now())
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
        }
    }

    private func scheduleHeartbeat() {
        heartbeatTimer = clock.schedule(after: BatteryHistory.heartbeat) { [weak self] in
            guard let self else { return }
            self.heartbeatTimer = nil
            guard !self.stopped, let status = self.state.status, let percent = status.batteryPercent else { return }
            self.batteryLog.record(percent: percent, charging: status.charging, at: self.clock.now())
            self.batteryGraph.refresh()
            self.scheduleHeartbeat()
        }
    }

    func refreshStatus() async {
        guard let active = session else { return }
        await refresh(active)
    }

    private func scheduleRetry() {
        guard !stopped, session == nil else { return }
        retryTimer?.cancel()
        retryTimer = clock.schedule(after: retryDelay) { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.attempt() }
        }
    }

    private func attempt() async {
        guard !attempting, !stopped, session == nil else { return }
        attempting = true
        defer { attempting = false }
        await connectOnce()
        if session == nil { scheduleRetry() }
    }

    private func runProbe() async -> AppDeviceProbe {
        let probe = probeDevice
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: probe())
            }
        }
    }

    package var beforeCompatibilityCheck: (() async -> Void)?

    private func connectOnce() async {
        let links = linkFactory()
        let probe = await runProbe()
        guard !stopped, session == nil else { return }
        retryDelay = retryInterval
        if let last = lastProbe, last.present != probe.present || last.advice != probe.advice {
            failureStreak = 0
        }
        lastProbe = (probe.present, probe.advice)
        guard !links.isEmpty else {
            publish { $0.status = nil; $0.connection = .noTransport(probe.advice) }
            return
        }
        if let advice = probe.advice {
            publish { $0.status = nil; $0.connection = .permissionDenied(advice) }
            return
        }
        guard probe.present else {
            publish { $0.status = nil; $0.connection = .searching }
            return
        }
        guard let held = acquireLock() else {
            if let problem = lockProblem() {
                backOff()
                publish { $0.status = nil; $0.connection = .error(problem) }
            } else {
                publish { $0.status = nil; $0.connection = .busy }
            }
            return
        }
        switch state.connection {
        case .searching, .noTransport, .permissionDenied:
            publish { $0.connection = .connecting }
        default:
            break
        }

        var connected: QxSession?
        var failures: [Error] = []
        var attention: String?
        var bluetoothFailed = false
        for link in links {
            let candidate = QxSession(link: link, timeout: connectTimeout)
            do {
                try await candidate.connect(timeout: QxLinkTimeouts.appearance(
                    kind: link.kind, explicit: nil, fallback: connectTimeout,
                    bluetooth: bluetoothConnectTimeout))
                connected = candidate
                break
            } catch {
                failures.append(error)
                if link.kind == .bluetooth {
                    bluetoothFailed = true
                    if link.failureNeedsAttention, let reason = link.failureReason { attention = reason }
                }
                candidate.close()
            }
        }
        guard let opened = connected, !stopped else {
            connected?.close()
            held.release()
            if failures.contains(where: { QudelixCLI.isDeviceBusy($0) }) {
                publish { $0.status = nil; $0.connection = .busy }
                return
            }
            let missing = failures.allSatisfy { QudelixCLI.isMissingTransport($0) }
            if missing, !bluetoothFailed { failureStreak = 0 } else { backOff() }
            publish {
                $0.status = nil
                if missing, let reason = attention {
                    $0.connection = .error(reason)
                } else if missing {
                    $0.connection = .searching
                } else {
                    $0.connection = .error(failures.last.map { QudelixCLI.describe($0) }
                                           ?? "could not connect")
                }
            }
            return
        }

        await beforeCompatibilityCheck?()
        if let reason = await opened.compatibilityRefusal() {
            opened.close()
            held.release()
            backOff()
            publish { $0.status = nil; $0.connection = .unsupported(reason) }
            return
        }
        guard !stopped else {
            opened.close()
            held.release()
            return
        }

        session = opened
        lock = held
        requestedNames = []
        _ = try? await opened.readPreset()
        guard isLive(opened) else { return }
        let first = await opened.snapshot()
        guard isLive(opened) else { return }
        if let index = first.activePresetIndex {
            requestedNames.insert(index)
            _ = try? await opened.presetName(index: index)
            guard isLive(opened) else { return }
        }
        let snapshot = await opened.snapshot()
        guard isLive(opened) else { return }
        let kind = snapshot.linkKind
        await eq.sessionOpened(opened, snapshot: snapshot)
        guard isLive(opened) else { return }
        guard opened.isConnected else {
            linkLost(opened)
            return
        }
        failureStreak = 0
        presets.sessionOpened(opened, snapshot: snapshot)
        publish {
            $0.status = applyHolds(to: snapshot)
            $0.connection = .connected(kind)
        }
        guard isLive(opened) else { return }
        watch(opened)
        if !opened.isConnected { linkLost(opened) }
    }

    private func isLive(_ candidate: QxSession) -> Bool {
        !stopped && session === candidate
    }

    private func backOff() {
        retryDelay = min(30, retryInterval * pow(2, Double(failureStreak)))
        failureStreak += 1
    }

    private func watch(_ watched: QxSession) {
        let lines = watched.notifications()
        notificationTask = Task { @MainActor [weak self] in
            for await _ in lines {
                guard let self, !Task.isCancelled else { return }
                guard watched.isConnected else {
                    self.linkLost(watched)
                    return
                }
                await self.refresh(watched)
                if !watched.isConnected {
                    self.linkLost(watched)
                    return
                }
            }
        }
    }

    private func refresh(_ watched: QxSession) async {
        guard session === watched else { return }
        let snapshot = await watched.snapshot()
        guard session === watched else { return }
        publish { $0.status = applyHolds(to: snapshot) }
        if let index = snapshot.activePresetIndex, snapshot.activePresetName == nil,
           !requestedNames.contains(index) {
            requestedNames.insert(index)
            Task { @MainActor in
                _ = try? await watched.presetName(index: index)
                await self.refresh(watched)
            }
        }
    }

    private func linkLost(_ lost: QxSession) {
        guard session === lost else { return }
        DebugLog.shared.log("device link lost")
        pendingSave = false
        saveTimer?.cancel()
        saveTimer = nil
        pendingVolume = nil
        pendingWrites.removeAll()
        notificationTask?.cancel()
        notificationTask = nil
        releaseSession()
        publish { $0.status = nil; $0.connection = .searching }
        scheduleRetry()
    }

    private func releaseSession() {
        eq.sessionClosed()
        presets.sessionClosed()
        session?.close()
        session = nil
        lock?.release()
        lock = nil
        volumeHold = nil
        muteHold = nil
        filterHold = nil
        eqHold = nil
    }

    private func applyHolds(to snapshot: QxStatusSnapshot) -> QxStatusSnapshot {
        var result = snapshot
        let now = clock.now()
        if let hold = volumeHold, now < hold.until { result.volumeDb = hold.value }
        if let hold = muteHold, now < hold.until { result.muted = hold.value }
        if let hold = filterHold, now < hold.until {
            result.dacFilterIndex = hold.value
            result.dacFilterName = QxStatusParser.dacFilters[hold.value]
        }
        if let hold = eqHold, now < hold.until { result.eqEnabled = hold.value }
        return result
    }

    private func republishLocal() {
        guard let current = state.status else { return }
        publish { $0.status = applyHolds(to: current) }
    }

    private func kick() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor in
            while let work = self.nextWrite() { await self.perform(work) }
            self.drainTask = nil
        }
    }

    private func nextWrite() -> Write? {
        guard session != nil else {
            pendingWrites.removeAll()
            pendingVolume = nil
            return nil
        }
        if !pendingWrites.isEmpty { return pendingWrites.removeFirst() }
        if let volume = pendingVolume {
            pendingVolume = nil
            return .volume(volume)
        }
        return nil
    }

    private func perform(_ write: Write) async {
        guard let active = session else { return }
        do {
            switch write {
            case .mute(let on):
                try await active.setMute(on)
            case .filter(let index):
                try await active.setDacFilter(index: index)
            case .eq(let on, let persist):
                try await active.setEqEnabled(on)
                if persist { armSave() }
            case .volume(let db):
                try await active.setVolume(db: db)
            }
        } catch {
            DebugLog.shared.log("device write failed: \(QudelixCLI.describe(error))")
            notify(.failure, Self.failureMessage(for: write))
        }
        await refresh(active)
    }

    private static func failureMessage(for write: Write) -> String {
        switch write {
        case .mute: return "Could not change mute." + retryAdvice
        case .filter: return "Could not change the DAC filter." + retryAdvice
        case .eq(let on, _): return "Could not turn the EQ \(on ? "on" : "off")." + retryAdvice
        case .volume: return "Could not change the volume." + retryAdvice
        }
    }

    func armSave() {
        pendingSave = true
        saveTimer?.cancel()
        saveTimer = nil
        guard !eq.hasMutes, !eq.sessionActive else { return }
        saveTimer = clock.schedule(after: Self.saveDelay) { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.timedSave() }
        }
    }

    private func timedSave() async {
        guard !eq.hasMutes, !eq.sessionActive else {
            saveTimer?.cancel()
            saveTimer = nil
            return
        }
        await flushSave()
    }

    func parkSaveForMute() {
        saveTimer?.cancel()
        saveTimer = nil
    }

    func parkSaveForSession() {
        saveTimer?.cancel()
        saveTimer = nil
    }

    func releaseParkedSave() {
        guard pendingSave, saveTimer == nil, !stopped, !eq.hasMutes, !eq.sessionActive else { return }
        armSave()
    }

    func mutesCleared() {
        guard pendingSave, saveTimer == nil, !stopped else { return }
        armSave()
    }
}
