import Foundation

package struct AudioStackLocations {
    package var stageSettings: URL
    package var routingMemory: URL?
    package var impulseDirectory: (() -> URL)?
    package var autofit: URL
    package var forceMarker: URL?
    package var fiveKLookup: (() -> Set<String>?)?

    package init(stageSettings: URL, routingMemory: URL?, impulseDirectory: (() -> URL)?, autofit: URL,
                 forceMarker: URL? = nil, fiveKLookup: (() -> Set<String>?)? = nil) {
        self.stageSettings = stageSettings
        self.routingMemory = routingMemory
        self.impulseDirectory = impulseDirectory
        self.autofit = autofit
        self.forceMarker = forceMarker
        self.fiveKLookup = fiveKLookup
    }

    private static var systemFiveKLookup: (() -> Set<String>?)? {
        #if os(Linux)
        return { FiveKAddresses.system() }
        #else
        return nil
        #endif
    }

    package static var system: AudioStackLocations {
        AudioStackLocations(stageSettings: StageStateFile.url,
                            routingMemory: OutputRouting.defaultMemoryURL(),
                            impulseDirectory: nil,
                            autofit: AutofitFile.url,
                            forceMarker: StageStateFile.directory.appendingPathComponent("force-rate.json"),
                            fiveKLookup: systemFiveKLookup)
    }

    package static func isolated(in directory: URL) -> AudioStackLocations {
        AudioStackLocations(stageSettings: directory.appendingPathComponent("stage.json"),
                            routingMemory: directory.appendingPathComponent("routing.json"),
                            impulseDirectory: { directory.appendingPathComponent("impulses", isDirectory: true) },
                            autofit: directory.appendingPathComponent("autofit.json"),
                            forceMarker: directory.appendingPathComponent("force-rate.json"))
    }
}

package enum AudioStatus: Equatable {
    case ready
    case connecting
    case reconnecting
    case unavailable

    package var message: String? {
        switch self {
        case .ready: return nil
        case .connecting: return "Connecting to the audio server\u{2026}"
        case .reconnecting: return "The audio server restarted \u{2014} reconnecting\u{2026}"
        case .unavailable: return AudioStack.unavailableMessage
        }
    }
}

@MainActor
package final class AudioStack {
    package static let unavailableMessage =
        "Needs PipeWire. The audio server could not be reached, so this part of Qudelix is off. "
        + "Everything that talks to the 5K still works."

    package let app: AppModel
    package typealias BackendFactory = () -> LinuxAudioBackend?
    package typealias Offload = (@escaping () -> Void) -> Void

    package static let reconnectInterval: TimeInterval = 5
    package static let backgroundOffload: Offload = { work in
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    package let backend: LinuxAudioBackend?
    package let routing: OutputRouting?
    package let stage: StageModel?
    package let automation: AutomationModel
    package let tune: TuneModel
    private let swappable: SwappableAudioBackend?
    private let factory: BackendFactory?
    private let offload: Offload
    private let clock: AppClock
    private let hop: OutputRouting.Hop
    private var started = false
    private var stopped = false
    private var attempting = false
    private var everConnected = false
    private var retryTimer: AppTimer?
    private var routingObserver: Int?
    private var statusObservers: [Int: (AudioStatus) -> Void] = [:]
    private var nextStatusObserverID = 0
    package private(set) var status: AudioStatus

    package var available: Bool { stage != nil }

    package convenience init(app: AppModel,
                             backend: LinuxAudioBackend?,
                             locations: AudioStackLocations = .system,
                             clock: AppClock = SystemClock(),
                             hop: @escaping OutputRouting.Hop = OutputRouting.mainHop) {
        self.init(app: app, backend: backend, factory: nil, locations: locations, clock: clock, hop: hop,
                  offload: AudioStack.backgroundOffload)
    }

    package convenience init(app: AppModel,
                             backendFactory: @escaping BackendFactory,
                             locations: AudioStackLocations = .system,
                             clock: AppClock = SystemClock(),
                             hop: @escaping OutputRouting.Hop = OutputRouting.mainHop,
                             offload: @escaping Offload = AudioStack.backgroundOffload) {
        self.init(app: app, backend: SwappableAudioBackend(), factory: backendFactory, locations: locations,
                  clock: clock, hop: hop, offload: offload)
    }

    private init(app: AppModel,
                 backend: LinuxAudioBackend?,
                 factory: BackendFactory?,
                 locations: AudioStackLocations,
                 clock: AppClock,
                 hop: @escaping OutputRouting.Hop,
                 offload: @escaping Offload) {
        self.app = app
        self.backend = backend
        self.swappable = factory == nil ? nil : backend as? SwappableAudioBackend
        self.factory = factory
        self.offload = offload
        self.clock = clock
        self.hop = hop
        status = factory != nil ? .connecting : (backend != nil ? .ready : .unavailable)
        if let backend {
            let routing = OutputRouting(backend: backend, clock: clock, hop: hop,
                                        memoryURL: locations.routingMemory,
                                        fiveKLookup: locations.fiveKLookup)
            let stage = StageModel(backend: backend, routing: routing, clock: clock,
                                   settingsURL: locations.stageSettings,
                                   impulseDirectory: locations.impulseDirectory,
                                   forceMarkerURL: locations.forceMarker)
            stage.reporter = app
            self.routing = routing
            self.stage = stage
        } else {
            routing = nil
            stage = nil
        }
        automation = AutomationModel(app: app, stage: stage, url: locations.autofit)
        tune = TuneModel(app: app, routing: routing, backend: backend, stage: stage, automation: automation)
    }

    package func start() {
        guard !started, !stopped else { return }
        started = true
        stage?.start()
        if factory != nil {
            routingObserver = routing?.addObserver { [weak self] in self?.connectionChanged() }
            attempt()
        }
    }

    @discardableResult
    package func addStatusObserver(_ observer: @escaping (AudioStatus) -> Void) -> Int {
        nextStatusObserverID += 1
        statusObservers[nextStatusObserverID] = observer
        observer(status)
        return nextStatusObserverID
    }

    package func removeStatusObserver(_ id: Int) {
        statusObservers[id] = nil
    }

    private func setStatus(_ next: AudioStatus) {
        guard next != status else { return }
        status = next
        for observer in statusObservers.values { observer(next) }
    }

    private func attempt() {
        guard !stopped, !attempting, status != .ready, let factory else { return }
        attempting = true
        let hop = self.hop
        weak var weakSelf = self
        offload {
            let made = factory()
            hop {
                MainActor.assumeIsolated { weakSelf?.finishAttempt(made) }
            }
        }
    }

    private func finishAttempt(_ made: LinuxAudioBackend?) {
        attempting = false
        guard !stopped else {
            made?.shutdown()
            return
        }
        if let made, let swappable {
            retryTimer?.cancel()
            retryTimer = nil
            swappable.install(made)
            everConnected = true
            setStatus(.ready)
            return
        }
        if !everConnected { setStatus(.unavailable) }
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryTimer?.cancel()
        retryTimer = clock.schedule(after: Self.reconnectInterval) { [weak self] in
            self?.attempt()
        }
    }

    private func connectionChanged() {
        guard status == .ready, let swappable, swappable.hasBackend, !swappable.connected else { return }
        stage?.audioServerLost()
        let dead = swappable.detach()
        dead?.shutdown()
        setStatus(.reconnecting)
        scheduleRetry()
    }

    package func shutdown() async {
        guard !stopped else { return }
        stopped = true
        retryTimer?.cancel()
        retryTimer = nil
        if let routingObserver { routing?.removeObserver(routingObserver) }
        routingObserver = nil
        tune.shutdown()
        automation.shutdown()
        stage?.shutdown()
        backend?.shutdown()
        await app.shutdown()
    }
}
