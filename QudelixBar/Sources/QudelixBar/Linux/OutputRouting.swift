import Foundation

package struct DeferredHandover: Codable, Equatable {
    package var target: String
    package var gain: Float
    package var muted: Bool

    package init(target: String, gain: Float, muted: Bool) {
        self.target = target
        self.gain = gain
        self.muted = muted
    }
}

package struct RoutingMemory: Codable, Equatable {
    package var target: String
    package var previousConfigured: String?
    package var stageGain: Float?
    package var stageMuted: Bool?
    package var handedOver: Bool?
    package var deferred: [DeferredHandover]?

    package init(target: String, previousConfigured: String?,
                 stageGain: Float? = nil, stageMuted: Bool? = nil, handedOver: Bool? = nil,
                 deferred: [DeferredHandover]? = nil) {
        self.target = target
        self.previousConfigured = previousConfigured
        self.stageGain = stageGain
        self.stageMuted = stageMuted
        self.handedOver = handedOver
        self.deferred = deferred
    }

    package var pendingEntries: [DeferredHandover] {
        (deferred ?? []) + (primaryPending.map { [$0] } ?? [])
    }

    package var primaryPending: DeferredHandover? {
        guard handedOver != true, let gain = stageGain, gain.isFinite else { return nil }
        let muted = stageMuted == true
        guard gain < 0.9999 || muted else { return nil }
        return DeferredHandover(target: target, gain: gain, muted: muted)
    }
}

package struct RoutingSnapshot: Equatable {
    package var sinks: [AudioSink] = []
    package var stageSinkPresent = false
    package var defaultName: String?
    package var configuredName: String?
    package var connected = true

    package init() {}
}

@MainActor
package final class OutputRouting {
    package typealias Hop = (@escaping () -> Void) -> Void

    package static let restoreRetry: TimeInterval = 3
    package static let memoryCap = 16_384
    package static let deferredCap = 4
    package static let maxVolumeFactor: Float = 16
    package static let restoreCheckDelay: TimeInterval = 3
    package static let volumeSaveGap: TimeInterval = 0.1
    package static let volumeLazySaveGap: TimeInterval = 1
    package static let restoreFailedNotice =
        "Couldn\u{2019}t put your default output back \u{2014} choose it in Sound settings."
    package static let recordFailedNotice =
        "Couldn\u{2019}t write Qudelix\u{2019}s recovery record, so Stage can\u{2019}t run safely. "
        + "Check that its data folder is writable."
    package static let volumeHandoverFailedNotice =
        "Couldn\u{2019}t carry the Stage volume over to your output \u{2014} check your volume before playing."

    nonisolated package static func defaultMemoryURL() -> URL {
        StageStateFile.directory.appendingPathComponent("routing.json")
    }

    nonisolated package static let mainHop: Hop = { work in DispatchQueue.main.async(execute: work) }

    private let backend: LinuxAudioBackend
    private let clock: AppClock
    private let hop: Hop
    private let memoryURL: URL?
    private let fiveKLookup: (() -> Set<String>)?
    private let offload: Hop
    private var fiveKAddresses = Set<String>()
    private var lookedUp = Set<String>()
    private var lookupRunning = false
    private var memory: RoutingMemory?
    private var insertHeld = false
    private var activationRequested = false
    private var activationConfirmed = false
    private var started = false
    private var lastRestore: Date?
    private var restoreCheckAt: Date?
    private var memoryDirty = false
    private var lastMemorySave = Date.distantPast
    private var snapshot = RoutingSnapshot()
    package private(set) var notice: String?
    private var observers: [Int: () -> Void] = [:]
    private var nextObserverID = 0

    package init(backend: LinuxAudioBackend,
                 clock: AppClock = SystemClock(),
                 hop: @escaping Hop = OutputRouting.mainHop,
                 memoryURL: URL? = OutputRouting.defaultMemoryURL(),
                 fiveKLookup: (() -> Set<String>)? = nil,
                 offload: @escaping Hop = OutputRouting.backgroundHop) {
        self.backend = backend
        self.clock = clock
        self.hop = hop
        self.memoryURL = memoryURL
        self.fiveKLookup = fiveKLookup
        self.offload = offload
    }

    nonisolated package static let backgroundHop: Hop = { work in
        DispatchQueue.global(qos: .utility).async(execute: work)
    }

    private func requestFiveKLookup(for addresses: Set<String>) {
        guard let lookup = fiveKLookup, !addresses.isEmpty, addresses != lookedUp, !lookupRunning else { return }
        lookupRunning = true
        lookedUp = addresses
        let hop = self.hop
        weak var weakSelf = self
        offload {
            let found = lookup()
            hop {
                MainActor.assumeIsolated { weakSelf?.finishFiveKLookup(found) }
            }
        }
    }

    private func finishFiveKLookup(_ found: Set<String>) {
        lookupRunning = false
        fiveKAddresses = found
        guard started else { return }
        refresh()
    }

    nonisolated private static func changeHandler(target: OutputRouting?,
                                                  hop: @escaping Hop) -> () -> Void {
        weak var weakTarget = target
        return {
            hop {
                MainActor.assumeIsolated { weakTarget?.refresh() }
            }
        }
    }

    package func start() {
        guard !started else { return }
        started = true
        memory = loadMemory()
        backend.changeHandler = Self.changeHandler(target: self, hop: hop)
        refresh()
    }

    package func shutdown() {
        endInsert()
        backend.changeHandler = nil
        started = false
    }

    @discardableResult
    package func addObserver(_ observer: @escaping () -> Void) -> Int {
        nextObserverID += 1
        observers[nextObserverID] = observer
        return nextObserverID
    }

    package func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    package var sinks: [AudioSink] { snapshot.sinks }
    package var stageSinkPresent: Bool { snapshot.stageSinkPresent }
    package var defaultName: String? { snapshot.defaultName }
    package var configuredName: String? { snapshot.configuredName }
    package var isStageDefault: Bool { snapshot.defaultName == LinuxAudioNames.stageSinkName }
    package var rememberedTarget: String? { memory?.target }
    package var connected: Bool { snapshot.connected }
    package var rememberedStageGain: Float? { memory?.stageGain }
    package var rememberedStageMuted: Bool? { memory?.stageMuted }

    package var realOutput: AudioSink? {
        guard let name = snapshot.defaultName else { return nil }
        let wanted = name == LinuxAudioNames.stageSinkName ? memory?.target : name
        guard let wanted else { return nil }
        return snapshot.sinks.first { $0.name == wanted }
    }

    package var qudelixSink: AudioSink? {
        snapshot.sinks.first { $0.isQudelix5K && $0.transport == .usb }
            ?? snapshot.sinks.first { $0.isQudelix5K }
    }

    package var outputIsQudelix: Bool { realOutput?.isQudelix5K == true }

    package var outputIsQudelixUsb: Bool {
        guard let output = realOutput else { return false }
        return output.isQudelix5K && output.transport == .usb
    }

    package func sinkVolumeDb(named name: String) -> Double? {
        guard let volume = backend.sinkVolume(named: name), !volume.muted else { return nil }
        let amplitude = Double(volume.volume) * Double(volume.channelVolume)
        guard amplitude.isFinite, amplitude > 0 else { return nil }
        let db = 20 * log10(amplitude)
        return db.isFinite ? db : nil
    }

    package var stageVolumeKnown: Bool {
        backend.sinkVolume(named: LinuxAudioNames.stageSinkName) != nil
    }

    package func stageVolumeDb() -> Double? {
        sinkVolumeDb(named: LinuxAudioNames.stageSinkName)
    }

    package func refresh() {
        var next = RoutingSnapshot()
        next.connected = backend.connected
        let all = backend.sinks
        requestFiveKLookup(for: Set(all.filter { $0.transport == .bluetooth && !$0.bluezAddress.isEmpty }
            .map { AudioSink.normalizedAddress($0.bluezAddress) }))
        let known = fiveKAddresses
        next.sinks = all.filter { !$0.isStageSink }.map { sink in
            var marked = sink
            marked.bluezIsFiveK = !sink.bluezAddress.isEmpty
                && known.contains(AudioSink.normalizedAddress(sink.bluezAddress))
            return marked
        }
        next.stageSinkPresent = all.contains { $0.isStageSink }
        next.defaultName = backend.defaultSinkName
        next.configuredName = backend.configuredDefaultSinkName
        let changed = next != snapshot
        snapshot = next
        if insertHeld, next.defaultName == LinuxAudioNames.stageSinkName { activationConfirmed = true }
        observeStageVolume()
        applyPendingHandover()
        settleMemory()
        checkRestoreOutcome()
        restoreStaleDefault()
        if changed {
            for observer in observers.values { observer() }
        }
    }

    @discardableResult
    package func prepareInsert(target: String) -> Bool {
        refresh()
        insertHeld = true
        activationRequested = false
        activationConfirmed = false
        lastRestore = nil
        restoreCheckAt = nil
        let stale = snapshot.configuredName == LinuxAudioNames.stageSinkName
        let previous = stale ? memory?.previousConfigured : snapshot.configuredName
        let carried = memory?.pendingEntries ?? []
        memory = RoutingMemory(target: target, previousConfigured: previous, stageGain: 1, stageMuted: false,
                               deferred: carried.isEmpty ? nil : Array(carried.suffix(Self.deferredCap)))
        guard saveMemory() else {
            memory = nil
            insertHeld = false
            publishNotice(Self.recordFailedNotice)
            return false
        }
        publishNotice(nil)
        return true
    }

    @discardableResult
    package func activateStage() -> Bool {
        guard insertHeld else { return false }
        resetStageVolume()
        activationRequested = true
        return backend.setDefaultSink(named: LinuxAudioNames.stageSinkName)
    }

    private func resetStageVolume() {
        let stage = LinuxAudioNames.stageSinkName
        guard let volume = backend.sinkVolume(named: stage) else { return }
        let gain = volume.gain
        guard gain.isFinite, gain > 0 else { return }
        if abs(gain - 1) > 0.001 || volume.muted {
            _ = backend.scaleSinkVolume(named: stage, by: min(1 / gain, Self.maxVolumeFactor), muted: false)
        }
    }

    package func endInsert() {
        let held = insertHeld
        insertHeld = false
        guard held || memory != nil else { return }
        refresh()
        let staged = (activationRequested && !activationConfirmed)
            || snapshot.defaultName == LinuxAudioNames.stageSinkName
            || snapshot.configuredName == LinuxAudioNames.stageSinkName
        activationRequested = false
        activationConfirmed = false
        if staged {
            if !restoredRecently { requestRestore() }
        } else if memory?.deferred == nil {
            clearMemory()
        }
    }

    private var restoredRecently: Bool {
        guard let last = lastRestore else { return false }
        return clock.now().timeIntervalSince(last) < Self.restoreRetry
    }

    private func requestRestore() {
        guard backend.connected else { return }
        handOverVolume()
        lastRestore = clock.now()
        if backend.setDefaultSink(named: memory?.previousConfigured) {
            restoreCheckAt = clock.now().addingTimeInterval(Self.restoreCheckDelay)
        } else {
            restoreCheckAt = nil
            DebugLog.shared.log("restoring the default output failed")
            publishNotice(Self.restoreFailedNotice)
        }
    }

    private func handOverVolume() {
        guard var current = memory, current.handedOver != true else { return }
        let stage = LinuxAudioNames.stageSinkName
        let live = backend.sinkVolume(named: stage)
        guard let gain = live?.gain ?? current.stageGain, gain.isFinite else { return }
        let muted = live?.muted ?? current.stageMuted ?? false
        guard snapshot.sinks.contains(where: { $0.name == current.target }) else {
            current.stageGain = gain
            current.stageMuted = muted
            memory = current
            saveMemory()
            return
        }
        let factor = min(max(gain, 0), 1)
        var delivered = true
        if factor < 0.9999 || muted {
            delivered = backend.scaleSinkVolume(named: current.target, by: factor, muted: muted ? true : nil)
        }
        if delivered {
            current.handedOver = true
            memory = current
            saveMemory()
        } else {
            DebugLog.shared.log("carrying the Stage volume over to the output failed")
            publishNotice(Self.volumeHandoverFailedNotice)
        }
    }

    private func observeStageVolume() {
        guard insertHeld, snapshot.stageSinkPresent, var current = memory,
              let volume = backend.sinkVolume(named: LinuxAudioNames.stageSinkName) else {
            flushDirtyMemory()
            return
        }
        let gain = volume.gain
        guard gain.isFinite else { return }
        let gainChanged = current.stageGain.map { abs($0 - gain) > 0.0005 } ?? true
        let muteChanged = current.stageMuted != volume.muted
        if gainChanged || muteChanged {
            let quieter = (current.stageGain.map { gain < $0 } ?? true) || (volume.muted && current.stageMuted != true)
            current.stageGain = gain
            current.stageMuted = volume.muted
            memory = current
            memoryDirty = true
            let gap = clock.now().timeIntervalSince(lastMemorySave)
            if quieter ? gap >= Self.volumeSaveGap : gap >= Self.volumeLazySaveGap {
                saveMemory()
            }
        } else {
            flushDirtyMemory()
        }
    }

    private func flushDirtyMemory() {
        guard memoryDirty, clock.now().timeIntervalSince(lastMemorySave) >= Self.volumeLazySaveGap else { return }
        saveMemory()
    }

    private func checkRestoreOutcome() {
        guard let due = restoreCheckAt, clock.now() >= due else { return }
        restoreCheckAt = nil
        let stillStaged = snapshot.defaultName == LinuxAudioNames.stageSinkName
            || snapshot.configuredName == LinuxAudioNames.stageSinkName
        if stillStaged {
            DebugLog.shared.log("the default output still names Stage after the restore")
            publishNotice(Self.restoreFailedNotice)
        } else if notice == Self.restoreFailedNotice {
            publishNotice(nil)
        }
    }

    private func publishNotice(_ text: String?) {
        guard notice != text else { return }
        notice = text
        for observer in observers.values { observer() }
    }

    private func restoreStaleDefault() {
        guard started, !insertHeld, !snapshot.stageSinkPresent, !snapshot.sinks.isEmpty else { return }
        guard snapshot.configuredName == LinuxAudioNames.stageSinkName
            || snapshot.defaultName == LinuxAudioNames.stageSinkName else { return }
        if let last = lastRestore, clock.now().timeIntervalSince(last) < Self.restoreRetry { return }
        requestRestore()
    }

    private var stageIsLive: Bool {
        insertHeld || activationRequested
            || snapshot.configuredName == LinuxAudioNames.stageSinkName
            || snapshot.defaultName == LinuxAudioNames.stageSinkName
    }

    private func applyPendingHandover() {
        guard started, var current = memory else { return }
        let live = stageIsLive
        var entries = current.deferred ?? []
        if !live, let primary = current.primaryPending { entries.append(primary) }
        var applied: [String] = []
        for entry in entries {
            guard snapshot.sinks.contains(where: { $0.name == entry.target }),
                  backend.sinkVolume(named: entry.target) != nil else { continue }
            let factor = min(max(entry.gain, 0), 1)
            if !backend.scaleSinkVolume(named: entry.target, by: factor, muted: entry.muted ? true : nil) {
                DebugLog.shared.log("carrying the Stage volume over to the returning output failed")
                publishNotice(Self.volumeHandoverFailedNotice)
            }
            applied.append(entry.target)
        }
        guard !applied.isEmpty else { return }
        let rest = (current.deferred ?? []).filter { !applied.contains($0.target) }
        current.deferred = rest.isEmpty ? nil : rest
        if !live, applied.contains(current.target) { current.handedOver = true }
        memory = current
        saveMemory()
    }

    private func settleMemory() {
        guard let current = memory, !insertHeld, !activationRequested, current.pendingEntries.isEmpty else { return }
        guard snapshot.configuredName != LinuxAudioNames.stageSinkName,
              snapshot.defaultName != LinuxAudioNames.stageSinkName else { return }
        clearMemory()
    }

    private func clearMemory() {
        memory = nil
        memoryDirty = false
        if let memoryURL { try? FileManager.default.removeItem(at: memoryURL) }
    }

    @discardableResult
    private func saveMemory() -> Bool {
        guard let memoryURL, let memory else { return true }
        guard let data = try? JSONEncoder().encode(memory) else { return false }
        let written = SafeFile.writeAtomic(data, to: memoryURL)
        if written {
            memoryDirty = false
            lastMemorySave = clock.now()
        }
        return written
    }

    private func loadMemory() -> RoutingMemory? {
        guard let memoryURL, let data = SafeFile.read(memoryURL, cap: Self.memoryCap) else { return nil }
        return try? JSONDecoder().decode(RoutingMemory.self, from: data)
    }
}
