import Foundation

package struct RoutingMemory: Codable, Equatable {
    package var target: String
    package var previousConfigured: String?

    package init(target: String, previousConfigured: String?) {
        self.target = target
        self.previousConfigured = previousConfigured
    }
}

package struct RoutingSnapshot: Equatable {
    package var sinks: [AudioSink] = []
    package var stageSinkPresent = false
    package var defaultName: String?
    package var configuredName: String?

    package init() {}
}

@MainActor
package final class OutputRouting {
    package typealias Hop = (@escaping () -> Void) -> Void

    package static let restoreRetry: TimeInterval = 3
    package static let memoryCap = 16_384

    nonisolated package static func defaultMemoryURL() -> URL {
        StageStateFile.directory.appendingPathComponent("routing.json")
    }

    nonisolated package static let mainHop: Hop = { work in DispatchQueue.main.async(execute: work) }

    private let backend: LinuxAudioBackend
    private let clock: AppClock
    private let hop: Hop
    private let memoryURL: URL?
    private var memory: RoutingMemory?
    private var insertHeld = false
    private var activationRequested = false
    private var activationConfirmed = false
    private var started = false
    private var lastRestore: Date?
    private var snapshot = RoutingSnapshot()
    private var observers: [Int: () -> Void] = [:]
    private var nextObserverID = 0

    package init(backend: LinuxAudioBackend,
                 clock: AppClock = SystemClock(),
                 hop: @escaping Hop = OutputRouting.mainHop,
                 memoryURL: URL? = OutputRouting.defaultMemoryURL()) {
        self.backend = backend
        self.clock = clock
        self.hop = hop
        self.memoryURL = memoryURL
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

    package func refresh() {
        var next = RoutingSnapshot()
        let all = backend.sinks
        next.sinks = all.filter { !$0.isStageSink }
        next.stageSinkPresent = all.contains { $0.isStageSink }
        next.defaultName = backend.defaultSinkName
        next.configuredName = backend.configuredDefaultSinkName
        let changed = next != snapshot
        snapshot = next
        if insertHeld, next.defaultName == LinuxAudioNames.stageSinkName { activationConfirmed = true }
        settleMemory()
        restoreStaleDefault()
        if changed {
            for observer in observers.values { observer() }
        }
    }

    package func prepareInsert(target: String) {
        refresh()
        insertHeld = true
        activationRequested = false
        activationConfirmed = false
        let stale = snapshot.configuredName == LinuxAudioNames.stageSinkName
        let previous = stale ? memory?.previousConfigured : snapshot.configuredName
        memory = RoutingMemory(target: target, previousConfigured: previous)
        saveMemory()
    }

    @discardableResult
    package func activateStage() -> Bool {
        guard insertHeld else { return false }
        activationRequested = true
        return backend.setDefaultSink(named: LinuxAudioNames.stageSinkName)
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
            requestRestore()
        } else {
            clearMemory()
        }
    }

    private func requestRestore() {
        lastRestore = clock.now()
        let previous = memory?.previousConfigured
        let usable = previous.flatMap { name in
            snapshot.sinks.contains { $0.name == name } ? name : nil
        }
        _ = backend.setDefaultSink(named: usable)
    }

    private func restoreStaleDefault() {
        guard started, !insertHeld, !snapshot.stageSinkPresent, !snapshot.sinks.isEmpty else { return }
        guard snapshot.configuredName == LinuxAudioNames.stageSinkName
            || snapshot.defaultName == LinuxAudioNames.stageSinkName else { return }
        if let last = lastRestore, clock.now().timeIntervalSince(last) < Self.restoreRetry { return }
        requestRestore()
    }

    private func settleMemory() {
        guard memory != nil, !insertHeld, !activationRequested else { return }
        guard snapshot.configuredName != LinuxAudioNames.stageSinkName,
              snapshot.defaultName != LinuxAudioNames.stageSinkName else { return }
        clearMemory()
    }

    private func clearMemory() {
        memory = nil
        if let memoryURL { try? FileManager.default.removeItem(at: memoryURL) }
    }

    private func saveMemory() {
        guard let memoryURL, let memory else { return }
        guard let data = try? JSONEncoder().encode(memory) else { return }
        _ = SafeFile.writeAtomic(data, to: memoryURL)
    }

    private func loadMemory() -> RoutingMemory? {
        guard let memoryURL, let data = SafeFile.read(memoryURL, cap: Self.memoryCap) else { return nil }
        return try? JSONDecoder().decode(RoutingMemory.self, from: data)
    }
}
