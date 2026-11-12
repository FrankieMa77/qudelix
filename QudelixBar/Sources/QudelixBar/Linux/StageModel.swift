import Foundation

package enum StageRunMode: Equatable {
    case insert
    case monitor
}

package struct StageImpulseInfo: Equatable {
    package var fileName: String
    package var displayName: String
    package var seconds: Double
    package var channels: Int
    package var sourceRate: Double

    init(_ info: ImpulseInfo) {
        fileName = info.fileName
        displayName = info.displayName
        seconds = info.seconds
        channels = info.channels
        sourceRate = info.sourceRate
    }
}

package enum StageImpulseState: Equatable {
    case off
    case ready(partitions: Int, taps: Int, hop: Int, rate: Double)
    case refused(String)

    init(_ status: StageProcessor.ImpulseStatus) {
        switch status {
        case .off:
            self = .off
        case .ready(_, let partitions, let taps, let hop, let rate):
            self = .ready(partitions: partitions, taps: taps, hop: hop, rate: rate)
        case .refused(let message):
            self = .refused(message)
        }
    }
}

package struct StageFailure: Equatable {
    package var message: String
    package var summary: String
}

package struct StageModelState: Equatable {
    package var settings = StageSettings()
    package var outputKey: String?
    package var outputDescription: String?
    package var running = false
    package var mode: StageRunMode?
    package var routed = false
    package var callActive = false
    package var callHold = false
    package var callSummary = "none"
    package var status = "Off."
    package var failure: StageFailure?
    package var sourceCorrelation: Double?
    package var limiterGainReductionDb = 0.0
    package var loudnessShelfDb = 0.0
    package var bassGuardBoostDb = 0.0
    package var bassGuardCeilingDb = 0.0
    package var bassGuardGainReductionDb = 0.0
    package var impulse: StageImpulseInfo?
    package var impulseState = StageImpulseState.off
    package var impulseBusy = false
    package var settingsNotice: String?
    package var runningRate: Double?
    package var audioNotice: String?
    package var impulseWaiting = false

    package init() {}

    package var bassGuardInert: Bool { bassGuardBoostDb <= StagePolicy.bassGuardInertDb }

    package var impulseInPath: Bool {
        guard case .ready = impulseState else { return false }
        return settings.hasImpulse && settings.impulseMixValue > 0 && !impulseWaiting
    }

    package var impulseProblem: String? {
        if case .refused(let message) = impulseState { return message }
        return nil
    }

    package var isCustomPreset: Bool {
        settings.enabled && !settings.audiblyEquals(.music)
            && !settings.audiblyEquals(.movie) && !settings.audiblyEquals(.theater)
    }
}

struct ImpulseStore {
    var directory: () -> URL = { IRLibrary.directory }

    func install(_ url: URL) throws -> ImpulseResponse {
        try IRLibrary.install(source: url, into: directory())
    }

    func load(_ name: String) throws -> ImpulseResponse {
        try IRLibrary.load(name: name, from: directory())
    }

    func remove(_ name: String) {
        IRLibrary.remove(name: name, from: directory())
    }

    func sweep(keeping referenced: Set<String>) {
        IRLibrary.sweep(keeping: referenced, in: directory())
    }
}

struct StageCallbackSizes: Equatable {
    var last = 0
    var smallest = 0
    var largest = 0
}

private final class StageRenderBridge {
    let processor: StageProcessor
    private let input = UnsafeMutablePointer<StageBuffer>.allocate(capacity: 1)
    private let output = UnsafeMutablePointer<StageBuffer>.allocate(capacity: 1)
    private let sizeLock = RTLock()
    private var sizes = StageCallbackSizes()

    init(processor: StageProcessor) {
        self.processor = processor
        input.initialize(to: StageBuffer(channels: 0, byteSize: 0, data: nil))
        output.initialize(to: StageBuffer(channels: 0, byteSize: 0, data: nil))
    }

    deinit {
        input.deallocate()
        output.deallocate()
        sizeLock.destroy()
    }

    func drainSizes() -> StageCallbackSizes {
        sizeLock.lock()
        let seen = sizes
        sizes.smallest = 0
        sizes.largest = 0
        sizeLock.unlock()
        return seen
    }

    func insert(_ samples: UnsafePointer<Float>, _ out: UnsafeMutablePointer<Float>,
                _ frames: Int, _ channels: Int) {
        guard frames > 0, channels > 0 else { return }
        sizeLock.lock()
        sizes.last = frames
        if sizes.smallest == 0 || frames < sizes.smallest { sizes.smallest = frames }
        if frames > sizes.largest { sizes.largest = frames }
        sizeLock.unlock()
        let bytes = UInt32(clamping: frames * channels * MemoryLayout<Float>.size)
        input.pointee = StageBuffer(channels: UInt32(channels), byteSize: bytes,
                                    data: UnsafeMutableRawPointer(mutating: samples))
        output.pointee = StageBuffer(channels: UInt32(channels), byteSize: bytes, data: out)
        processor.render(input: StageBufferList(base: input, count: 1),
                         output: StageBufferList(base: output, count: 1))
    }

    func monitor(_ samples: UnsafePointer<Float>, _ frames: Int, _ channels: Int) {
        guard frames > 0, channels > 0 else { return }
        let bytes = UInt32(clamping: frames * channels * MemoryLayout<Float>.size)
        input.pointee = StageBuffer(channels: UInt32(channels), byteSize: bytes,
                                    data: UnsafeMutableRawPointer(mutating: samples))
        processor.render(input: StageBufferList(base: input, count: 1),
                         output: StageBufferList(base: nil, count: 0))
    }
}

@MainActor
package final class StageModel {
    package static let phaseDeadline: TimeInterval = 5
    package static let phasePoll: TimeInterval = 0.1
    package static let saveDelay: TimeInterval = 0.5
    package static let defaultGraphRate = 48000.0
    package static let silenceLimit: TimeInterval = 3
    package static let underrunTicksLimit = 3
    package static let bluetoothUnderrunTicksLimit = 10
    package static let bluetoothRetryDelay: TimeInterval = 15
    package static let bluetoothRetries = 3
    package static let bluetoothHealthyRun: TimeInterval = 120
    package static let bluetoothStallMessage =
        "Stage paused because the Bluetooth link to the 5K kept stalling. It turns itself back on; "
        + "if this keeps happening, move closer to the computer or use USB."
    package static let headsetHoldStatus =
        "Paused while the 5K is in its headset profile \u{2014} resumes when it switches back."
    package static let silentRetryBackoff: TimeInterval = 300
    package static let volumeGrace: TimeInterval = 1
    package static let reconnectingStatus = "The audio server restarted \u{2014} reconnecting\u{2026}"

    private enum Phase: Equatable {
        case idle
        case starting(deadline: Date)
        case routing(deadline: Date)
        case active
    }

    package private(set) var state = StageModelState()
    private var preview: StageModelState?
    package let level: LevelModel
    package var onStatusChange: (() -> Void)?

    package weak var reporter: AudioDeviceReporting? {
        didSet { level.reporter = reporter }
    }

    let processor = StageProcessor()

    private let backend: LinuxAudioBackend
    private let routing: OutputRouting
    private let clock: AppClock
    private let settingsURL: URL
    private let impulses: ImpulseStore
    private var stageByDevice = StageDeviceStore()
    private var settingsUnreadable = false
    private var preservedA2dpGuard: String?
    private var preservedPerAppEQ: Bool?
    private var observers: [Int: (StageModelState) -> Void] = [:]
    private var nextObserverID = 0
    private var notified: StageModelState?
    private var started = false
    private var routingObserver: Int?
    private var tickTimer: AppTimer?
    private var phaseTimer: AppTimer?
    private var saveTimer: AppTimer?
    private var callTicks = 0
    private var busy = false
    private var pendingOutputs = false
    private var pendingReconcile = false
    private var retryNotBefore: Date?
    package static let retryBackoff: TimeInterval = 30
    private var callReleasedByHand = false
    private var correlationSmoothed: Double?
    private var lastOutputKey: String?
    private var wasConnected = false
    private var silenceSince: Date?
    private var lastUnderruns: UInt64 = 0
    private var underrunRises = 0
    private var runningBluetooth = false
    private var bluetoothStalls = 0
    private var bluetoothRetryDue = false
    private var healthySince: Date?
    private var knownSinkNames: Set<String> = []
    private var headsetHold = false

    private enum StartError: Error {
        case recordUnwritable
    }

    private var handle: AudioStreamHandle?
    private var bridge: StageRenderBridge?
    private var phase = Phase.idle
    private var engineMode: StageRunMode?
    private var runningSinkName: String?
    private var runningRate: Double?
    private var lastKnownRate: Double?
    private var callHold = false
    private var callActive = false
    private var failure: StageFailure?
    private var status = "Off."

    private var loadedImpulseName: String?
    private var loadedImpulse: ImpulseResponse?
    private var primeGate = ImpulsePrimeGate()
    private var impulseBusy = false
    private var impulseInfo: StageImpulseInfo?
    private var impulseState = StageImpulseState.off

    private var loudnessTargetDb = 0.0
    private var scannedBands: [QxEqBandValue]?
    private var scannedShelfDb = 0.0
    private var scannedBoostDb = 0.0
    var deviceEqCurve: (() -> [QxEqBandValue]?)?

    package convenience init(backend: LinuxAudioBackend,
                             routing: OutputRouting,
                             clock: AppClock = SystemClock(),
                             settingsURL: URL = StageStateFile.url,
                             impulseDirectory: (() -> URL)? = nil,
                             forceMarkerURL: URL? = nil,
                             availableRates: [Double] = LevelModel.defaultAvailableRates) {
        self.init(backend: backend, routing: routing, clock: clock, settingsURL: settingsURL,
                  impulseDirectory: impulseDirectory, forceMarkerURL: forceMarkerURL,
                  kernel: nil, availableRates: availableRates)
    }

    init(backend: LinuxAudioBackend,
         routing: OutputRouting,
         clock: AppClock,
         settingsURL: URL,
         impulseDirectory: (() -> URL)?,
         forceMarkerURL: URL? = nil,
         kernel: SpectrumKernel?,
         availableRates: [Double]) {
        self.backend = backend
        self.routing = routing
        self.clock = clock
        self.settingsURL = settingsURL
        var store = ImpulseStore()
        if let impulseDirectory { store.directory = impulseDirectory }
        impulses = store
        var seed = LevelSeed()
        var loadedStages = StageDeviceStore()
        var notice: String?
        var a2dpGuard: String?
        var perAppEQ: Bool?
        let outcome = StageStateFile.loadOutcome(settingsURL)
        if let text = StageStateFile.notice(for: outcome, fileName: settingsURL.lastPathComponent) {
            notice = text
            DebugLog.shared.log("stage settings file could not be loaded; left alone")
        }
        if case .loaded(let saved) = outcome {
            loadedStages = StageDeviceStore(saved.stageByDevice.mapValues { $0.clamped() })
            seed.levelTracking = saved.levelTracking
            seed.detectQuality = saved.detectQuality ?? true
            seed.autoRate = saved.autoRate ?? true
            seed.manualRateHz = saved.manualRateHz
            seed.earCalibrationByDevice = saved.earCalibrationByDevice ?? [:]
            seed.exposure = saved.exposure
            a2dpGuard = saved.a2dpGuard
            perAppEQ = saved.perAppEQ
        }
        level = LevelModel(backend: backend, routing: routing, clock: clock, seed: seed,
                           kernel: kernel, availableRates: availableRates, markerURL: forceMarkerURL)
        settingsUnreadable = !outcome.permitsSaving
        stageByDevice = loadedStages
        preservedA2dpGuard = a2dpGuard
        preservedPerAppEQ = perAppEQ
        state.settingsNotice = notice
    }

    package var outputKey: String? { routing.realOutput?.name }

    package var isRunning: Bool { handle != nil }

    package private(set) var toneHold = false

    package func setToneHold(_ on: Bool) {
        guard on != toneHold else { return }
        toneHold = on
        processor.setMuted(on)
    }

    package var engineFailure: StageFailure? {
        guard handle == nil, desiredMode != nil else { return nil }
        return failure
    }

    package var impulseInPath: Bool { state.impulseInPath }

    package var settings: StageSettings { state.settings }

    @discardableResult
    package func addObserver(_ observer: @escaping (StageModelState) -> Void) -> Int {
        nextObserverID += 1
        observers[nextObserverID] = observer
        observer(preview ?? state)
        return nextObserverID
    }

    package func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    package func showPreview(_ stage: StageModelState, level levelState: LevelModelState) {
        preview = stage
        level.showPreview(levelState)
        for observer in observers.values { observer(stage) }
    }

    private func publish() {
        guard preview == nil else { return }
        state.outputKey = routing.realOutput?.name
        state.outputDescription = routing.realOutput?.description
        state.running = handle != nil
        state.mode = handle == nil ? nil : engineMode
        state.routed = phase == .active
        state.callActive = callActive
        state.callHold = callHold
        state.status = status
        state.failure = engineFailure
        state.impulse = impulseInfo
        state.impulseState = impulseState
        state.impulseBusy = impulseBusy
        state.runningRate = runningRate
        state.audioNotice = routing.notice
        level.publish()
        guard state != notified else { return }
        notified = state
        for observer in observers.values { observer(state) }
    }

    package func start() {
        guard !started else { return }
        started = true
        level.onModeInputsChanged = { [weak self] in
            self?.retryNotBefore = nil
            self?.reconcile()
        }
        level.onSaveNeeded = { [weak self] in self?.scheduleSave() }
        level.onSaveNow = { [weak self] in self?.saveNowCancelingPending() }
        level.onStatusChange = { [weak self] in self?.onStatusChange?() }
        routingObserver = routing.addObserver { [weak self] in self?.outputsChanged() }
        routing.start()
        outputsChanged()
        sweepImpulses()
        scheduleTick()
    }

    package func shutdown() {
        guard started else { return }
        started = false
        tickTimer?.cancel()
        phaseTimer?.cancel()
        saveTimer?.cancel()
        if let routingObserver { routing.removeObserver(routingObserver) }
        routingObserver = nil
        saveNow()
        stopEngine()
        level.shutdown()
        routing.shutdown()
        publish()
    }

    private func scheduleTick() {
        tickTimer?.cancel()
        tickTimer = clock.schedule(after: 1) { [weak self] in
            guard let self, self.started else { return }
            self.scheduleTick()
            self.routing.refresh()
            self.meterTick()
        }
    }

    package func setStage(_ settings: StageSettings) {
        retryNotBefore = nil
        let wasEnabled = state.settings.enabled
        state.settings = settings.clamped()
        if state.settings.enabled != wasEnabled { onStatusChange?() }
        if let key = outputKey { stageByDevice.set(state.settings, for: key) }
        processor.applyStage(state.settings)
        syncImpulse()
        updateBassGuard()
        reconcile()
        scheduleSave()
        publish()
    }

    package func setStage(_ settings: StageSettings, editedFor key: String?) {
        guard key == outputKey else {
            DebugLog.shared.log("stage edit dropped: output device changed mid-edit")
            return
        }
        setStage(settings)
    }

    package func mutate(editedFor key: String?, _ change: (inout StageSettings) -> Void) {
        var next = state.settings
        change(&next)
        next.enabled = true
        setStage(next, editedFor: key)
    }

    package func setEnabled(_ on: Bool, editedFor key: String?) {
        var next = state.settings
        next.enabled = on
        setStage(next, editedFor: key)
    }

    package func applyPreset(_ preset: StageSettings, editedFor key: String?) {
        setStage(preset, editedFor: key)
    }

    package func setEarCalibration(_ db: Double, editedFor key: String?) {
        level.setEarCalibration(db, editedFor: key)
    }

    package func setLevelTracking(_ on: Bool) { level.setLevelTracking(on) }

    package func setDetectQuality(_ on: Bool) { level.setDetectQuality(on) }

    package func setAutoRate(_ on: Bool) { level.setAutoRate(on) }

    private var wantedMode: StageRunMode? {
        let mode = StagePolicy.wantedMode(stageEnabled: state.settings.enabled, perAppEQ: false,
                                          levelTracking: level.state.levelTracking,
                                          detectQuality: level.state.detectQuality)
        switch mode {
        case .insert?: return .insert
        case .monitor?: return .monitor
        case nil: return nil
        }
    }

    private var desiredMode: StageRunMode? {
        guard !callActive else { return nil }
        return wantedMode
    }

    private func reconcile() {
        run(outputs: false)
    }

    private func outputsChanged() {
        run(outputs: true)
    }

    private func run(outputs: Bool) {
        guard started else { return }
        if busy {
            if outputs { pendingOutputs = true } else { pendingReconcile = true }
            return
        }
        busy = true
        var wantOutputs = outputs
        var rounds = 0
        repeat {
            pendingOutputs = false
            pendingReconcile = false
            if wantOutputs { outputsChangedOnce() } else { reconcileOnce() }
            wantOutputs = pendingOutputs
            rounds += 1
        } while (pendingOutputs || pendingReconcile) && rounds < 5
        pendingOutputs = false
        pendingReconcile = false
        busy = false
        publish()
    }

    private func reconcileOnce() {
        guard routing.connected else { return }
        let device = routing.realOutput
        headsetHold = device?.isBluetoothHeadsetProfile == true
        let hold = (callActive || headsetHold) && wantedMode != nil && device != nil
        let desired = desiredMode

        if handle != nil, !hold {
            let deviceChanged = runningSinkName != device?.name
            if desired == nil || deviceChanged || engineMode != desired {
                stopEngine()
            }
        }
        if callHold, !hold { stopEngine() }

        if hold {
            if !callHold {
                level.clearVerdict()
                DebugLog.shared.log(headsetHold ? "headset profile — stage engine holding"
                                                : "call in progress — stage engine holding")
                beginHold()
            }
        } else if handle == nil, let desired, let device {
            if let notBefore = retryNotBefore, clock.now() < notBefore { return }
            processor.applyStage(state.settings)
            syncImpulse()
            if awaitImpulsePriming() { return }
            startEngine(on: device, mode: desired)
        }
    }

    private func beginHold() {
        if handle != nil { stopEngine() }
        callHold = true
        failure = nil
        status = callActive ? "Paused for a call — resumes when the call ends." : Self.headsetHoldStatus
    }

    private func startEngine(on device: AudioSink, mode: StageRunMode) {
        if callHold {
            callHold = false
        }
        let rate = runningRate ?? lastKnownRate ?? Self.defaultGraphRate
        processor.prepare(sampleRate: rate)
        processor.setMonitorOnly(mode == .monitor)
        processor.setMuted(toneHold)
        let bridge = StageRenderBridge(processor: processor)
        do {
            switch mode {
            case .insert:
                guard routing.prepareInsert(target: device.name) else { throw StartError.recordUnwritable }
                handle = try backend.startInsert(target: device.name,
                                                 bluetooth: device.transport == .bluetooth) { input, output, frames, channels, _ in
                    bridge.insert(input, output, frames, channels)
                }
            case .monitor:
                handle = try backend.startMonitor(sink: device.name) { samples, frames, channels, _ in
                    bridge.monitor(samples, frames, channels)
                }
            }
            self.bridge = bridge
            engineMode = mode
            runningSinkName = device.name
            runningBluetooth = device.transport == .bluetooth
            runningRate = rate
            failure = nil
            if mode == .insert {
                phase = .starting(deadline: clock.now().addingTimeInterval(Self.phaseDeadline))
                status = "Starting Stage on \(device.description)…"
                schedulePhasePoll()
                advanceInsert()
            } else {
                phase = .active
                status = statusLine()
            }
            syncRate()
        } catch {
            handle = nil
            stopEngine()
            let message = Self.failureMessage(error)
            failure = StageFailure(message: message, summary: "the audio stream couldn't start")
            status = message
            retryNotBefore = clock.now().addingTimeInterval(Self.retryBackoff)
            DebugLog.shared.log("stage engine start failed: \(message)")
        }
    }

    private static func failureMessage(_ error: Error) -> String {
        if let startError = error as? StartError, startError == .recordUnwritable {
            return OutputRouting.recordFailedNotice
        }
        if let backendError = error as? AudioBackendError {
            switch backendError {
            case .unavailable:
                return "The audio server isn't reachable, so Stage and Level can't run."
            case .streamFailed:
                return "The audio server refused the stream. Try again in a moment."
            }
        }
        return error.localizedDescription
    }

    private func statusLine() -> String {
        let name = routing.realOutput?.description ?? runningSinkName ?? "the output"
        let kilohertz = (runningRate ?? Self.defaultGraphRate) / 1000
        let verb = engineMode == .insert ? "Stage active" : "Metering"
        return String(format: "%@ → %@ @ %g kHz", verb, name, kilohertz)
    }

    private func stopEngine() {
        phaseTimer?.cancel()
        phaseTimer = nil
        let wasActive = handle != nil || callHold
        let old = handle
        let oldBridge = bridge
        handle = nil
        bridge = nil
        processor.setMuted(false)
        phase = .idle
        engineMode = nil
        runningSinkName = nil
        runningRate = nil
        callHold = false
        failure = nil
        silenceSince = nil
        underrunRises = 0
        lastUnderruns = 0
        healthySince = nil
        runningBluetooth = false
        if wasActive { status = "Off." }
        let outer = busy
        busy = true
        routing.endInsert()
        busy = outer
        old?.stop()
        withExtendedLifetime(oldBridge) {}
    }

    private func failEngine(_ message: String, summary: String, backoff: TimeInterval = StageModel.retryBackoff) {
        stopEngine()
        failure = StageFailure(message: message, summary: summary)
        status = message
        retryNotBefore = clock.now().addingTimeInterval(backoff)
        DebugLog.shared.log("stage engine failed: \(message)")
        publish()
    }

    private func failBluetoothStall() {
        let retry = bluetoothStalls < Self.bluetoothRetries
        bluetoothStalls = retry ? bluetoothStalls + 1 : 0
        bluetoothRetryDue = retry
        failEngine(Self.bluetoothStallMessage, summary: "the Bluetooth link kept stalling",
                   backoff: retry ? Self.bluetoothRetryDelay : Self.silentRetryBackoff)
    }

    private func schedulePhasePoll() {
        phaseTimer?.cancel()
        phaseTimer = clock.schedule(after: Self.phasePoll) { [weak self] in
            guard let self, self.started else { return }
            self.routing.refresh()
            self.advanceInsert()
            self.publish()
        }
    }

    private func advanceInsert() {
        guard let handle, engineMode == .insert else { return }
        if handle.hasFailed {
            failEngine("The audio stream stopped unexpectedly.", summary: "the stream stopped")
            return
        }
        syncRate()
        if ratesDiffer() {
            failEngine(Self.rateMismatchMessage(routing.realOutput), summary: "different rates")
            return
        }
        let now = clock.now()
        switch phase {
        case .idle, .active:
            return
        case .starting(let deadline):
            let volumeReady = routing.stageVolumeKnown
                || now > deadline.addingTimeInterval(Self.volumeGrace - Self.phaseDeadline)
            if handle.isReady, routing.stageSinkPresent, volumeReady {
                if routing.activateStage() {
                    phase = .routing(deadline: now.addingTimeInterval(Self.phaseDeadline))
                } else {
                    failEngine("Couldn't make Qudelix Stage the default output.", summary: "default output unchanged")
                    return
                }
            } else if now > deadline {
                failEngine("The Stage output didn't come up in time.", summary: "the Stage output didn't appear")
                return
            }
        case .routing:
            break
        }
        if case .routing(let deadline) = phase {
            if routing.isStageDefault {
                phase = .active
                status = statusLine()
                phaseTimer?.cancel()
                phaseTimer = nil
                return
            }
            if now > deadline {
                failEngine("The audio server didn't switch the default output to Stage in time.",
                           summary: "the default output didn't switch")
                return
            }
        }
        schedulePhasePoll()
    }

    private func ratesDiffer() -> Bool {
        guard let handle, let sink = handle.sinkLegFormat?.rate, let playback = handle.format?.rate,
              sink > 0, playback > 0 else { return false }
        return sink != playback
    }

    private static func rateMismatchMessage(_ output: AudioSink?) -> String {
        let name = output?.isQudelix5K == true ? "the 5K" : "your output"
        return "The audio graph runs the Stage output and \(name) at different rates; Stage needs one rate."
    }

    private func watchInsertHealth() {
        guard let handle, engineMode == .insert, phase == .active else {
            silenceSince = nil
            underrunRises = 0
            return
        }
        if ratesDiffer() {
            failEngine(Self.rateMismatchMessage(routing.realOutput), summary: "different rates")
            return
        }
        let now = clock.now()
        if handle.sinkLegState == .streaming, handle.playbackLegState != .streaming {
            let since = silenceSince ?? now
            silenceSince = since
            if now.timeIntervalSince(since) >= Self.silenceLimit {
                failEngine("Stage went silent: the audio server isn\u{2019}t carrying its output to "
                           + (routing.realOutput?.description ?? "your output")
                           + ". Stage is off and your output is back.",
                           summary: "the Stage output went silent", backoff: Self.silentRetryBackoff)
                return
            }
        } else {
            silenceSince = nil
        }
        let underruns = handle.underruns
        underrunRises = underruns > lastUnderruns ? underrunRises + 1 : 0
        lastUnderruns = underruns
        if runningBluetooth {
            let since = healthySince ?? now
            healthySince = since
            if now.timeIntervalSince(since) >= Self.bluetoothHealthyRun { bluetoothStalls = 0 }
            if underrunRises >= Self.bluetoothUnderrunTicksLimit {
                healthySince = nil
                failBluetoothStall()
            }
            return
        }
        if underrunRises >= Self.underrunTicksLimit {
            failEngine("Stage can\u{2019}t keep up with the audio server, so it is off and your output is back.",
                       summary: "the Stage output kept underrunning", backoff: Self.silentRetryBackoff)
        }
    }

    private func syncRate() {
        guard handle != nil, let format = handle?.format, format.rate > 0 else { return }
        let rate = Double(format.rate)
        guard rate != runningRate || rate != lastKnownRate else { return }
        lastKnownRate = rate
        if rate != runningRate {
            runningRate = rate
            processor.prepare(sampleRate: rate)
            if status.contains("@") { status = statusLine() }
        }
        primeGate.engineStarted(at: rate)
    }

    private func awaitImpulsePriming() -> Bool {
        let rate = lastKnownRate ?? (backend.forceRate > 0 ? Double(backend.forceRate) : Self.defaultGraphRate)
        switch primeGate.verdict(sourceRate: loadedImpulse?.sourceRate, targetRate: rate) {
        case .proceed:
            return false
        case .wait:
            return true
        case .prime(let target):
            guard let response = loadedImpulse else { return false }
            let generation = primeGate.generation
            Task.detached(priority: .userInitiated) { [weak self] in
                response.prime(at: target)
                await self?.finishPriming(generation: generation, rate: target)
            }
            return true
        }
    }

    private func finishPriming(generation: Int, rate: Double) {
        primeGate.finished(generation: generation, rate: rate)
        reconcile()
    }

    private func impulsePrimeRate() -> Double {
        AudioOutputs.plausibleRate(runningRate ?? lastKnownRate ?? Self.defaultGraphRate)
    }

    private func refreshCallState() {
        var witnesses = CallWitnesses()
        witnesses.deviceActiveCall = reporter?.reportedActiveCall
        witnesses.deviceInputSource = reporter?.reportedInputSource
        let verdict = StagePolicy.callVerdict(witnesses, releasedByHand: callReleasedByHand)
        callReleasedByHand = verdict.stillReleased
        state.callSummary = witnesses.summary
        if verdict.active != callActive {
            callActive = verdict.active
            onStatusChange?()
            DebugLog.shared.log("call state → \(verdict.active ? "on a call" : "clear") (\(witnesses.summary))")
        }
    }

    package func callActiveFresh() -> Bool {
        guard started else { return false }
        refreshCallState()
        return callActive
    }

    package func checkCallNow() {
        guard started else { return }
        refreshCallState()
        reconcile()
    }

    package func releaseCall() {
        guard started else { return }
        callReleasedByHand = true
        DebugLog.shared.log("call mode released by hand (\(state.callSummary))")
        reporter?.requestDeviceStatus()
        refreshCallState()
        reconcile()
        _ = clock.schedule(after: 1.5) { [weak self] in
            self?.checkCallNow()
        }
    }

    package func audioServerLost() {
        if handle != nil || callHold { stopEngine() }
        level.backendLost()
        status = Self.reconnectingStatus
        publish()
    }

    private func trackConnection() {
        let connected = routing.connected
        defer { wasConnected = connected }
        guard connected != wasConnected else { return }
        if connected {
            level.recoverForce()
            retryNotBefore = nil
            bluetoothStalls = 0
            if handle == nil, !callHold { status = "Off." }
        } else {
            if handle != nil || callHold { stopEngine() }
            level.backendLost()
            if wasConnected { status = Self.reconnectingStatus }
        }
    }

    private func outputsChangedOnce() {
        trackConnection()
        guard routing.connected else { return }
        let key = routing.realOutput?.name
        if let key {
            if lastOutputKey == nil, stageByDevice[key] == nil,
               state.settings.enabled || state.settings.doesAnything {
                stageByDevice.set(state.settings, for: key)
                scheduleSave()
            } else {
                stageByDevice.touch(key)
                let deviceStage = stageByDevice[key] ?? StageSettings()
                if !deviceStage.audiblyEquals(state.settings) || deviceStage.enabled != state.settings.enabled {
                    state.settings = deviceStage
                    processor.applyStage(state.settings)
                    syncImpulse()
                    onStatusChange?()
                }
            }
        }
        if key != lastOutputKey {
            level.adoptEarCalibration(for: key)
            retryNotBefore = nil
            bluetoothStalls = 0
        }
        lastOutputKey = key
        let names = Set(routing.sinks.map(\.name))
        if let key, names.contains(key), !knownSinkNames.contains(key) {
            retryNotBefore = nil
            bluetoothStalls = 0
        }
        knownSinkNames = names

        if handle != nil, let running = runningSinkName,
           !routing.sinks.contains(where: { $0.name == running }) {
            stopEngine()
        }
        refreshCallState()
        reconcileOnce()
    }

    package func installImpulse(_ url: URL, editedFor key: String?) {
        guard key == outputKey else {
            DebugLog.shared.log("impulse install dropped: output device changed")
            return
        }
        guard !impulseBusy else { return }
        impulseBusy = true
        publish()
        let rate = impulsePrimeRate()
        let store = impulses
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<ImpulseResponse, Error>
            do {
                let response = try store.install(url)
                response.prime(at: AudioOutputs.plausibleRate(rate))
                outcome = .success(response)
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { self?.finishInstall(outcome, editedFor: key) }
        }
    }

    private func finishInstall(_ outcome: Result<ImpulseResponse, Error>, editedFor key: String?) {
        impulseBusy = false
        switch outcome {
        case .success(let response):
            guard key == outputKey else {
                impulses.remove(response.fileName)
                publish()
                return
            }
            adopt(response)
            var next = state.settings
            next.impulseFile = response.fileName
            next.enabled = true
            setStage(next, editedFor: key)
            sweepImpulses()
        case .failure(let error):
            let message = (error as? ImpulseError)?.message ?? error.localizedDescription
            impulseState = .refused(SafeText.scrubbed(message, limit: 300))
            DebugLog.shared.log("impulse install refused: \(message)")
            publish()
        }
    }

    package func removeImpulse(editedFor key: String?) {
        let name = state.settings.impulseFile
        var next = state.settings
        next.impulseFile = nil
        next.impulseMix = nil
        setStage(next, editedFor: key)
        if let name, !stageByDevice.values.contains(where: { $0.impulseFile == name }) {
            impulses.remove(name)
        }
        sweepImpulses()
    }

    package func setImpulseMix(_ mix: Double, editedFor key: String?) {
        guard state.settings.hasImpulse else { return }
        var next = state.settings
        next.impulseMix = mix
        setStage(next, editedFor: key)
    }

    private func adopt(_ response: ImpulseResponse?) {
        processor.setImpulse(response)
        loadedImpulse = response
        primeGate.adopted()
        impulseInfo = response.map { StageImpulseInfo(ImpulseInfo($0)) }
        loadedImpulseName = response?.fileName
        impulseState = StageImpulseState(processor.impulseStatus)
    }

    private func syncImpulse() {
        let wanted = state.settings.impulseFile
        guard wanted != loadedImpulseName else { return }
        loadedImpulseName = wanted
        guard let wanted else {
            adopt(nil)
            return
        }
        let rate = impulsePrimeRate()
        let store = impulses
        impulseBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<ImpulseResponse, Error>
            do {
                let response = try store.load(wanted)
                response.prime(at: AudioOutputs.plausibleRate(rate))
                outcome = .success(response)
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { self?.finishLoad(outcome, named: wanted) }
        }
    }

    private func finishLoad(_ outcome: Result<ImpulseResponse, Error>, named: String) {
        impulseBusy = false
        guard loadedImpulseName == named else {
            publish()
            return
        }
        switch outcome {
        case .success(let response):
            adopt(response)
        case .failure(let error):
            let message = (error as? ImpulseError)?.message ?? error.localizedDescription
            processor.setImpulse(nil)
            loadedImpulse = nil
            primeGate.adopted()
            impulseInfo = nil
            impulseState = .refused(SafeText.scrubbed(message, limit: 300))
        }
        publish()
    }

    private func sweepImpulses() {
        guard !settingsUnreadable else { return }
        var referenced = Set(stageByDevice.values.compactMap(\.impulseFile))
        if let current = state.settings.impulseFile { referenced.insert(current) }
        impulses.sweep(keeping: referenced)
    }

    package func scheduleSave() {
        saveTimer?.cancel()
        saveTimer = clock.schedule(after: Self.saveDelay) { [weak self] in
            self?.saveNow()
        }
    }

    private func saveNowCancelingPending() {
        saveTimer?.cancel()
        saveNow()
    }

    package func saveNow() {
        guard !settingsUnreadable else { return }
        let part = level.persisted
        StageStateFile.save(PersistedStageState(
            stageByDevice: stageByDevice.settings,
            exposure: part.exposure,
            levelTracking: part.levelTracking,
            detectQuality: part.detectQuality,
            autoRate: part.autoRate,
            manualRateHz: part.manualRateHz,
            a2dpGuard: preservedA2dpGuard,
            earCalibrationByDevice: part.earCalibrationByDevice,
            perAppEQ: preservedPerAppEQ), to: settingsURL)
    }

    private var levelContext: LevelTick {
        LevelTick(running: handle != nil, rate: runningRate, sinkName: runningSinkName,
                  muted: processor.isMutedNow, stageEnabled: state.settings.enabled,
                  callActive: callActive, callHold: callHold)
    }

    package func meterTick() {
        callTicks += 1
        if callTicks >= (callActive ? 5 : 60) {
            callTicks = 0
            if callActive { reporter?.requestDeviceStatus() }
            refreshCallState()
            reconcile()
        }

        if handle == nil, bluetoothRetryDue, let notBefore = retryNotBefore, clock.now() >= notBefore {
            bluetoothRetryDue = false
            reconcile()
        }
        syncRate()
        if handle?.hasFailed == true {
            failEngine("The audio stream stopped unexpectedly.", summary: "the stream stopped")
        }
        watchInsertHealth()
        level.housekeeping(levelContext)

        guard handle != nil else {
            state.sourceCorrelation = nil
            state.impulseWaiting = false
            state.limiterGainReductionDb = 0
            if loudnessTargetDb != 0 { loudnessTargetDb = 0 }
            state.loudnessShelfDb = 0
            processor.applyLoudness(shelfDb: 0)
            state.bassGuardBoostDb = 0
            state.bassGuardCeilingDb = 0
            state.bassGuardGainReductionDb = 0
            processor.applyBassGuard(ceilingDb: 0, predictedBoostDb: 0)
            correlationSmoothed = nil
            level.idleTick(levelContext)
            publish()
            return
        }

        if let corr = processor.drainSourceCorrelation() {
            let smoothed = 0.7 * (correlationSmoothed ?? corr) + 0.3 * corr
            correlationSmoothed = smoothed
            if state.sourceCorrelation == nil || abs(smoothed - (state.sourceCorrelation ?? 0)) > 0.001 {
                state.sourceCorrelation = smoothed
            }
        }

        updateLimiterTelemetry()
        refreshImpulseStatus()
        refreshImpulseWaiting()
        updateBassGuardTelemetry()
        level.qualityTick(processor: processor, context: levelContext)
        level.automationStep(levelContext)
        level.updateEarLevel(processor: processor)
        updateLoudness()
        updateBassGuard()
        level.consumeMeter(processor: processor)
        publish()
    }

    private func refreshImpulseWaiting() {
        guard engineMode == .insert, let sizes = bridge?.drainSizes(), sizes.last > 0 else { return }
        guard state.settings.hasImpulse, state.settings.impulseMixValue > 0,
              case .ready(_, _, let hop, _) = impulseState else {
            state.impulseWaiting = false
            return
        }
        let constant = sizes.smallest == sizes.largest
        state.impulseWaiting = !(constant && hop > 0 && sizes.last % hop == 0)
    }

    private func refreshImpulseStatus() {
        processor.refreshImpulseLayout()
        let next = processor.impulseStatus
        if next == .off {
            if !state.settings.hasImpulse { impulseState = .off }
            return
        }
        impulseState = StageImpulseState(next)
    }

    private func updateLimiterTelemetry() {
        let floor = processor.drainLimiterFloor()
        state.limiterGainReductionDb = floor.isFinite && floor > 0 && floor < 0.999
            ? -20 * log10(Double(floor)) : 0
    }

    private func updateBassGuard() {
        let measuring = state.settings.enabled && state.settings.bassGuardValue
        var boost = 0.0
        if measuring {
            let bands = deviceEqCurve?() ?? []
            if bands != scannedBands || abs(state.loudnessShelfDb - scannedShelfDb) >= 0.1 {
                scannedBands = bands
                scannedShelfDb = state.loudnessShelfDb
                scannedBoostDb = StagePolicy.bassGuardBoostDb(bands: bands, loudnessShelfDb: state.loudnessShelfDb)
            }
            boost = scannedBoostDb
        } else if scannedBands != nil {
            scannedBands = nil
            scannedShelfDb = 0
            scannedBoostDb = 0
        }
        let ceiling = measuring
            ? StagePolicy.bassGuardCeilingDb(worstBoostDb: boost,
                                             strength: state.settings.bassGuardStrengthValue)
            : 0
        let moved = abs(boost - state.bassGuardBoostDb) >= 0.1
            || abs(ceiling - state.bassGuardCeilingDb) >= 0.1
            || (boost == 0 && state.bassGuardBoostDb != 0)
            || (ceiling == 0 && state.bassGuardCeilingDb != 0)
        if moved {
            state.bassGuardBoostDb = boost
            state.bassGuardCeilingDb = ceiling
        }
        processor.applyBassGuard(ceilingDb: state.bassGuardCeilingDb,
                                 predictedBoostDb: state.bassGuardBoostDb)
    }

    private func updateBassGuardTelemetry() {
        let deepest = processor.drainBassGuardReduction()
        state.bassGuardGainReductionDb = deepest.isFinite && deepest > 0.05 ? Double(deepest) : 0
    }

    private func updateLoudness() {
        let target = state.settings.loudnessValue
            ? EarLevel.shelfDb(earLevelDb: level.state.earLevelAverageDb,
                               strength: state.settings.loudnessStrengthValue)
            : 0
        loudnessTargetDb = target
        processor.applyLoudness(shelfDb: target)
        state.loudnessShelfDb = processor.appliedLoudnessShelfDb
    }
}
