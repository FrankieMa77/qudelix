import Combine
import Foundation
import SwiftUI

/// The model behind the Stage and Level panes: per-device Soundstage
/// settings, the listening-exposure history, and the engine's lifecycle.
///
/// Unlike everything else in this app, these features live on the Mac, not
/// on the 5K — the 5K keeps doing its own EQ on-device; the stage is applied
/// to what the Mac plays *before* it reaches any output device. The engine
/// follows the system default output, and each device keeps its own stage
/// settings by UID.
///
/// The engine runs only while a feature needs it: the Stage enabled for the
/// current output (insert mode), or Level tracking switched on (monitor
/// mode, which never touches the audio path). Everything else in the app
/// works exactly as before while the engine is off.
@MainActor
final class StageState: ObservableObject {
    let engine = StageEngine()
    let watcher = OutputWatcher()

    /// The current output device's stage, backed by the per-device map.
    @Published private(set) var stage = StageSettings()
    @Published private(set) var levelTracking = false
    @Published private(set) var perAppEQ = true

    var activeAssignments: (() -> [ResolvedAssignment])?
    var onProcessListRefresh: (() -> Void)?

    @Published private(set) var impulseInfo: ImpulseInfo?
    @Published private(set) var impulseStatus: StageProcessor.ImpulseStatus = .off
    private(set) var impulseStatusLive: StageProcessor.ImpulseStatus = .off
    @Published private(set) var impulseBusy = false
    private var loadedImpulseName: String?

    var impulseInPath: Bool {
        guard case .ready = impulseStatus else { return false }
        return stage.hasImpulse && stage.impulseMixValue > 0
    }

    var impulseProblem: String? {
        if case .refused(let message) = impulseStatus { return message }
        return nil
    }

    @Published private(set) var callActive = false
    private(set) var callActiveLive = false

    var deviceCallState: (() -> (activeCall: Bool?, inputSource: String?)?)?

    var onStatusChange: (() -> Void)?

    private var a2dpGuardModeRaw = A2dpGuard.Mode.ask.rawValue
    var savedA2dpGuardMode: A2dpGuard.Mode {
        A2dpGuard.Mode(rawValue: a2dpGuardModeRaw) ?? .ask
    }
    func setA2dpGuardMode(_ mode: A2dpGuard.Mode) {
        guard mode.rawValue != a2dpGuardModeRaw else { return }
        a2dpGuardModeRaw = mode.rawValue
        scheduleSave()
    }
    var guardDiagnostics: (() -> String)?
    var aiDiagnostics: (() -> String)?

    var suggestionDiagnostics: (() -> String)?

    // Stream-quality detection: spectral analysis of what the tap hears.
    @Published private(set) var detectQuality = true
    @Published private(set) var autoRate = true
    /// Verdict after hysteresis — what the UI shows. nil while unknown.
    @Published private(set) var qualityVerdict: QualityAnalyzer.Verdict?
    private(set) var qualityVerdictLive: QualityAnalyzer.Verdict?
    private let analyzer = QualityAnalyzer()
    private var rawVerdict: QualityAnalyzer.Verdict?
    private var rawVerdictStreak = 0
    /// Which device the published verdict was measured on. A verdict is only
    /// ever evidence about the stream the engine was listening to, and the
    /// engine listens to the default output — which need not be the 5K.
    private var verdictDeviceUID: String?
    /// When the current lossless-class vote became stable, for the
    /// switch-after-10s rule.
    private var verdictStableSince: Date?
    private var lastAutoSwitch = Date.distantPast
    /// The rate the user last picked by hand; lossy content returns here.
    private var manualRateHz: Double?
    var manualRate: Double? { manualRateHz }
    /// The rate the automation last set, nil once the user overrides it —
    /// the UI marks the rate as auto-chosen while this matches reality.
    @Published private(set) var autoSetRate: Double?

    // Listening exposure (digital level, dBFS — not calibrated SPL).
    @Published private(set) var currentLevelDb: Double?
    private(set) var currentLevelDbLive: Double?
    @Published private(set) var exposureDays: [DayExposure] = []
    private(set) var exposureDaysLive: [DayExposure] = []
    /// Smoothed L/R correlation of what's playing: ~1 means mono content,
    /// which width and crossfeed cannot widen — the UI says so.
    @Published private(set) var sourceCorrelation: Double?
    @Published private(set) var limiterGainReductionDb: Double = 0
    private(set) var limiterGainReductionDbLive: Double = 0
    @Published private(set) var loudnessShelfDb: Double = 0
    private(set) var loudnessShelfDbLive: Double = 0
    private var loudnessTargetDb: Double = 0
    @Published private(set) var bassGuardBoostDb: Double = 0
    private(set) var bassGuardBoostDbLive: Double = 0
    @Published private(set) var bassGuardCeilingDb: Double = 0
    private(set) var bassGuardCeilingDbLive: Double = 0
    @Published private(set) var bassGuardGainReductionDb: Double = 0
    private(set) var bassGuardGainReductionDbLive: Double = 0
    var bassGuardInert: Bool { bassGuardBoostDb <= Self.bassGuardInertDb }
    var deviceEqCurve: (() -> [QxEqBandValue]?)?

    @Published private(set) var earLevel: EarLevelEstimate = .unavailable
    private(set) var earLevelLive: EarLevelEstimate = .unavailable
    @Published private(set) var earLevelAverageDb: Double?
    private(set) var earLevelAverageDbLive: Double?
    @Published private(set) var earCalibrationDb = EarLevel.defaultCalibrationDb
    @Published private(set) var earAnchor: EarVolumeAnchor?
    private(set) var earAnchorLive: EarVolumeAnchor?
    var earLevelDb: Double? {
        if case .estimated(let db) = earLevel { return db }
        return nil
    }
    var qudelixVolumeDb: (() -> Double?)?
    private var shortTerm = ShortTermLoudness()
    private var earAverage = AveragedLoudness()
    private var earCalibrationByDevice: [String: Double] = [:]

    private(set) var sourceCorrelationLive: Double?

    private var uiVisible = false

    func setUIVisible(_ visible: Bool) {
        uiVisible = visible
        if visible {
            flushMirrors()
            onProcessListRefresh?()
        }
    }

    private func mirror<T: Equatable>(_ value: T,
                                      into keyPath: ReferenceWritableKeyPath<StageState, T>) {
        guard uiVisible, self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    private func publish<T: Equatable>(_ value: T,
                                       live: ReferenceWritableKeyPath<StageState, T>,
                                       into published: ReferenceWritableKeyPath<StageState, T>) {
        self[keyPath: live] = value
        mirror(value, into: published)
    }

    private func flushMirrors() {
        mirror(currentLevelDbLive, into: \.currentLevelDb)
        mirror(sourceCorrelationLive, into: \.sourceCorrelation)
        mirror(exposureDaysLive, into: \.exposureDays)
        mirror(qualityVerdictLive, into: \.qualityVerdict)
        mirror(callActiveLive, into: \.callActive)
        mirror(limiterGainReductionDbLive, into: \.limiterGainReductionDb)
        mirror(impulseStatusLive, into: \.impulseStatus)
        mirror(loudnessShelfDbLive, into: \.loudnessShelfDb)
        mirror(bassGuardBoostDbLive, into: \.bassGuardBoostDb)
        mirror(bassGuardCeilingDbLive, into: \.bassGuardCeilingDb)
        mirror(bassGuardGainReductionDbLive, into: \.bassGuardGainReductionDb)
        mirror(earAnchorLive, into: \.earAnchor)
        mirror(earLevelLive, into: \.earLevel)
        mirror(earLevelAverageDbLive, into: \.earLevelAverageDb)
    }

    static let silenceFloorDb: Double = -55
    static let loudThresholdDb: Double = -12

    private var stageByDevice = StageDeviceStore()
    private var settingsUnreadable = false
    static let maxCalibratedDevices = 64
    private var meterTimer: Timer?
    private var meterTicksSinceSave = 0
    private var saveWork: DispatchWorkItem?
    private var started = false
    private var forwarders: Set<AnyCancellable> = []

    var outputName: String? { watcher.defaultOutput?.name }
    var outputUID: String? { watcher.defaultOutput?.uid }

    /// The 5K as a Core Audio OUTPUT device (its USB audio side), whichever
    /// output is currently the default. nil when audio isn't on USB.
    var qudelixOutput: AudioOutput? {
        watcher.devices.first { $0.name.localizedCaseInsensitiveContains("qudelix") }
    }

    /// Set the rate macOS runs a device at — what Audio MIDI Setup does.
    /// If the stage engine is on that device, its rate listener restarts it
    /// at the new rate; the delayed refresh picks up the HAL's async apply.
    /// `manual: true` records the choice as the user's baseline — the rate
    /// lossy content returns to when auto-switching is on.
    @discardableResult
    func setNominalRate(_ rate: Double, for device: AudioOutput, manual: Bool = false) -> Bool {
        if manual {
            manualRateHz = rate
            autoSetRate = nil       // the user's hand overrides the automation
            scheduleSave()
        }
        let accepted = AudioOutputs.setNominalRate(device.id, rate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.watcher.refreshNow()
        }
        return accepted
    }

    init() {
        // Views observe this object alone; the engine's status line and the
        // watcher's device names publish through it.
        engine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwarders)
        watcher.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwarders)
        let outcome = StageStateFile.loadOutcome()
        if case .unreadable = outcome { settingsUnreadable = true }
        if case .loaded(let saved) = outcome {
            stageByDevice = StageDeviceStore(saved.stageByDevice.mapValues { $0.clamped() })
            levelTracking = saved.levelTracking
            detectQuality = saved.detectQuality ?? true
            autoRate = saved.autoRate ?? true
            if let rate = saved.manualRateHz, AudioOutputs.isPlausibleRate(rate) {
                manualRateHz = rate
            }
            if let raw = saved.a2dpGuard, A2dpGuard.Mode(rawValue: raw) != nil {
                a2dpGuardModeRaw = raw
            }
            perAppEQ = saved.perAppEQ ?? true
            if let calibrations = saved.earCalibrationByDevice {
                earCalibrationByDevice = Dictionary(uniqueKeysWithValues:
                    calibrations.sorted { $0.key < $1.key }
                        .prefix(Self.maxCalibratedDevices)
                        .map { ($0.key, EarLevel.clampedCalibration($0.value)) })
            }
            // The file is user-writable: clamp what comes off it so a
            // hand-edited value can't trap Int() in the Level pane, drop
            // duplicate day keys (ForEach identity), and apply the 14-day
            // cap here too — the append path's trim never sees a file that
            // arrived oversized.
            var seenDays = Set<String>()
            exposureDays = Array(saved.exposure.map { day in
                DayExposure(day: String(day.day.prefix(10)),
                            audibleSeconds: min(max(day.audibleSeconds, 0), 172_800),
                            loudSeconds: min(max(day.loudSeconds, 0), 172_800),
                            energySum: min(max(day.energySum, 0), 1e12))
            }
            .filter { seenDays.insert($0.day).inserted }
            .suffix(14))
            exposureDaysLive = exposureDays
        }
    }

    func start() {
        guard !started else { return }
        started = true
        watcher.onChange = { [weak self] in self?.outputsChanged() }
        engine.onProcessListChange = { [weak self] in
            AudioOutputs.invalidateProcessCache()
            self?.onProcessListRefresh?()
            self?.applyAssignmentChange()
        }
        engine.onDeviceConfigurationChange = { [weak self] in
            guard let self else { return }
            self.refreshCallState()
            if self.engine.isRunning, !self.callActiveLive,
               let device = self.watcher.defaultOutput,
               AudioOutputs.currentNominalRate(device.id) != self.engine.runningSampleRate {
                self.engine.stop()
                self.watcher.refreshNow()
                return
            }
            self.reconcile()
        }
        watcher.start()
        outputsChanged()
        sweepImpulses()
        startMetering()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.watcher.refreshNow()
        }
    }

    // MARK: - Edits

    func setStage(_ settings: StageSettings) {
        let wasEnabled = stage.enabled
        stage = settings.clamped()
        if stage.enabled != wasEnabled { onStatusChange?() }
        if let uid = outputUID { stageByDevice.set(stage, for: uid) }
        engine.processor.applyStage(stage)
        syncImpulse()
        updateBassGuard()
        reconcile()
        scheduleSave()
    }

    /// For view-originated edits: `uid` is the device the view was SHOWING
    /// when the control was touched (captured at render time). A slider
    /// drag can straddle a default-output swap; without the check, the tail
    /// of the drag mutates the OLD device's saved profile and force-enables
    /// the stage on the new one.
    func setStage(_ settings: StageSettings, editedFor uid: String?) {
        guard uid == outputUID else {
            DebugLog.shared.log("stage edit dropped: output device changed mid-edit")
            return
        }
        setStage(settings)
    }

    func setEarCalibration(_ db: Double) {
        let clamped = EarLevel.clampedCalibration(db)
        guard clamped != earCalibrationDb else { return }
        earCalibrationDb = clamped
        if let uid = outputUID {
            if earCalibrationByDevice[uid] == nil,
               earCalibrationByDevice.count >= Self.maxCalibratedDevices {
                earCalibrationByDevice.removeValue(forKey:
                    earCalibrationByDevice.keys.sorted()[0])
            }
            earCalibrationByDevice[uid] = clamped
        }
        scheduleSave()
    }

    func setEarCalibration(_ db: Double, editedFor uid: String?) {
        guard uid == outputUID else {
            DebugLog.shared.log("ear calibration edit dropped: output device changed mid-edit")
            return
        }
        setEarCalibration(db)
    }

    private func adoptEarCalibration(for uid: String?) {
        let next = EarLevel.clampedCalibration(
            uid.flatMap { earCalibrationByDevice[$0] } ?? EarLevel.defaultCalibrationDb)
        if earCalibrationDb != next { earCalibrationDb = next }
        clearEarLevel()
    }

    private func clearEarLevel() {
        shortTerm.reset()
        earAverage.reset()
        publish(EarLevelEstimate.unavailable, live: \.earLevelLive, into: \.earLevel)
        publish(Double?.none, live: \.earLevelAverageDbLive, into: \.earLevelAverageDb)
        publish(EarVolumeAnchor?.none, live: \.earAnchorLive, into: \.earAnchor)
    }

    func setPerAppEQ(_ on: Bool) {
        guard on != perAppEQ else { return }
        perAppEQ = on
        appAssignmentsChanged()
        scheduleSave()
    }

    var perAppActiveCount: Int {
        engine.isRunning ? engine.activeAppTaps.count : 0
    }

    var assignedAppCount: Int { activeAssignments?().count ?? 0 }

    private var wantsPerAppEQ: Bool {
        perAppEQ && !(activeAssignments?().isEmpty ?? true)
    }

    private func desiredTapPlan() -> [StageEngine.AppTapEntry] {
        guard wantsPerAppEQ, let resolved = activeAssignments?() else { return [] }
        return StageEngine.tapPlan(assignments: resolved,
                                   runningProcesses: AudioOutputs.audioProcesses(),
                                   selfPID: getpid())
    }

    static let assignmentRebuildQuiet: TimeInterval = 0.4
    private var pendingAssignmentRebuild: DispatchWorkItem?

    func appAssignmentsChanged() {
        guard started else { return }
        pendingAssignmentRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingAssignmentRebuild = nil
            self?.applyAssignmentChange()
        }
        pendingAssignmentRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.assignmentRebuildQuiet,
                                      execute: work)
        onStatusChange?()
    }

    private func applyAssignmentChange() {
        guard started else { return }
        let plan = desiredTapPlan()
        let sameTaps = StageEngine.sameTaps(engine.activeAppPlan, plan)
        engine.appTapPlan = plan
        engine.followProcessList = wantsPerAppEQ
        if engine.isRunning, engine.mode == .insert, sameTaps {
            engine.processor.applyAppChains(plan.map(\.chain))
            return
        }
        if engine.isRunning, !sameTaps { engine.stop() }
        reconcile(plan: plan)
    }

    nonisolated static func perAppDiag(taps: Int, assigned: Int) -> String {
        "apps=\(max(taps, 0))/\(max(assigned, 0))"
    }

    func setLevelTracking(_ on: Bool) {
        levelTracking = on
        reconcile()
        scheduleSave()
    }

    func setDetectQuality(_ on: Bool) {
        detectQuality = on
        if !on {
            clearVerdict()
            qualityRate = nil
        }
        reconcile()
        scheduleSave()
    }

    private func clearVerdict() {
        let had = qualityVerdictLive?.isLosslessClass
        qualityVerdictLive = nil
        mirror(qualityVerdictLive, into: \.qualityVerdict)
        if had != nil { onStatusChange?() }
        verdictDeviceUID = nil
        rawVerdict = nil
        rawVerdictStreak = 0
        verdictStableSince = nil
    }

    func setAutoRate(_ on: Bool) {
        autoRate = on
        scheduleSave()
    }

    /// The one switch a user needs: on = detect and act, off = do neither.
    /// The Level pane keeps the granular pair for those who want detection
    /// without automation.
    var qualityMasterOn: Bool { detectQuality && autoRate }

    func setQualityMaster(_ on: Bool) {
        if on {
            setDetectQuality(true)
            setAutoRate(true)
        } else {
            setAutoRate(false)
            setDetectQuality(false)
            autoSetRate = nil
        }
    }

    // MARK: - Engine lifecycle

    nonisolated static func wantedMode(stageEnabled: Bool, perAppEQ: Bool,
                                       levelTracking: Bool,
                                       detectQuality: Bool) -> StageEngine.Mode? {
        if stageEnabled { return .insert }
        if perAppEQ { return .insert }
        if levelTracking || detectQuality { return .monitor }
        return nil
    }

    private var wantedMode: StageEngine.Mode? {
        Self.wantedMode(stageEnabled: stage.enabled, perAppEQ: wantsPerAppEQ,
                        levelTracking: levelTracking, detectQuality: detectQuality)
    }

    private var desiredMode: StageEngine.Mode? {
        guard !callActiveLive else { return nil }
        return wantedMode
    }

    /// Why the engine isn't running, when something asked it to run and it
    /// couldn't — nil whenever there is nothing to report, so a surface can
    /// render it unconditionally and stay quiet while all is well.
    ///
    /// The failure that matters most is the one nobody asked for: quality
    /// detection is on out of the box, so the very first launch starts the
    /// engine before System Audio Recording has been granted. That refusal
    /// belongs on screen even though the Stage and Level switches are both
    /// off — gating it on either of them is how it stayed invisible.
    var engineFailure: StageEngine.Failure? {
        guard !engine.isRunning, desiredMode != nil else { return nil }
        return engine.failure
    }

    /// The one place that decides whether the engine should run, and on what.
    /// Called after every edit and every device event; safe to call twice.
    private func reconcile(plan: [StageEngine.AppTapEntry]? = nil) {
        engine.followProcessList = wantsPerAppEQ
        if !engine.isRunning { engine.appTapPlan = plan ?? desiredTapPlan() }
        let device = watcher.defaultOutput
        let hold = callActiveLive && wantedMode != nil && device != nil
        let desired = desiredMode

        if engine.isRunning, !hold {
            // Restart on any drift: mode changes need a different tap, and a
            // device swap needs a new aggregate. Stopping first is also the
            // recovery path when the output vanished under us.
            let deviceChanged = engine.runningDeviceUID != device?.uid
            if desired == nil || deviceChanged || engine.mode != desired {
                engine.stop()
            }
        }
        if engine.callHold, !hold { engine.stop() }

        if hold, let device {
            if !engine.callHold {
                clearVerdict()
                DebugLog.shared.log("call in progress — stage engine holding")
            }
            engine.holdForCall(output: device)
        } else if !engine.isRunning, let desired, let device {
            engine.processor.applyStage(stage)
            syncImpulse()
            engine.start(output: device, mode: desired)
        }
    }

    private func refreshCallState() {
        let device = watcher.defaultOutput
        let outputOnCall = device.map {
            $0.isBluetooth && AudioOutputs.callModeActive(outputID: $0.id)
        } ?? false
        let reported = deviceCallState?()
        let active = Self.callIsActive(outputOnCall: outputOnCall,
                                       deviceActiveCall: reported?.activeCall,
                                       deviceInputSource: reported?.inputSource)
        if active != callActiveLive {
            callActiveLive = active
            mirror(active, into: \.callActive)
            onStatusChange?()
            DebugLog.shared.log("call state → \(active ? "on a call" : "clear")")
        }
    }

    nonisolated static func callIsActive(outputOnCall: Bool,
                                         deviceActiveCall: Bool?,
                                         deviceInputSource: String?) -> Bool {
        if outputOnCall { return true }
        if deviceActiveCall == true { return true }
        return deviceInputSource?.hasPrefix("HFP") ?? false
    }

    func checkCallNow() {
        guard started else { return }
        refreshCallState()
        reconcile()
    }

    /// The last default output seen, to tell a device *change* from a device
    /// *appearing* after a spell with none.
    private var lastOutputUID: String?

    /// The default output changed, or the device list did. The stage follows
    /// the default output, so per-device settings swap with it.
    private func outputsChanged() {
        let uid = outputUID
        if let uid {
            if lastOutputUID == nil, stageByDevice[uid] == nil,
               stage.enabled || stage.doesAnything {
                // Edits made while NO output existed have no device key.
                // A device appearing must adopt them, not silently discard
                // them — but only onto a device with no saved profile of
                // its own.
                stageByDevice.set(stage, for: uid)
                scheduleSave()
            } else {
                stageByDevice.touch(uid)
                let deviceStage = stageByDevice[uid] ?? StageSettings()
                if !deviceStage.audiblyEquals(stage) || deviceStage.enabled != stage.enabled {
                    stage = deviceStage
                    engine.processor.applyStage(stage)
                    syncImpulse()
                    onStatusChange?()
                }
            }
        }
        if uid != lastOutputUID { adoptEarCalibration(for: uid) }
        lastOutputUID = uid

        // A disconnect-reconnect can settle on the same default output while
        // still having killed our aggregate's sub-device; the running check
        // in reconcile() only catches UID drift. Restart whenever the device
        // identity behind our UID changed.
        if engine.isRunning, let running = engine.runningDeviceUID,
           !watcher.devices.contains(where: { $0.uid == running }) {
            engine.stop()
        }
        refreshCallState()
        reconcile()
    }

    func installImpulse(_ url: URL, editedFor uid: String?) {
        guard uid == outputUID else {
            DebugLog.shared.log("impulse install dropped: output device changed")
            return
        }
        guard !impulseBusy else { return }
        impulseBusy = true
        let rate = engine.runningSampleRate
            ?? watcher.defaultOutput?.sampleRate ?? 48000
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<ImpulseResponse, Error>
            do {
                let response = try IRLibrary.install(source: url)
                response.prime(at: AudioOutputs.plausibleRate(rate))
                outcome = .success(response)
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { self?.finishInstall(outcome, editedFor: uid) }
        }
    }

    private func finishInstall(_ outcome: Result<ImpulseResponse, Error>,
                               editedFor uid: String?) {
        impulseBusy = false
        switch outcome {
        case .success(let response):
            guard uid == outputUID else {
                IRLibrary.remove(name: response.fileName)
                return
            }
            adopt(response)
            var next = stage
            next.impulseFile = response.fileName
            next.enabled = true
            setStage(next, editedFor: uid)
            sweepImpulses()
        case .failure(let error):
            let message = (error as? ImpulseError)?.message
                ?? error.localizedDescription
            publish(StageProcessor.ImpulseStatus.refused(
                        SafeText.scrubbed(message, limit: 300)),
                    live: \.impulseStatusLive, into: \.impulseStatus)
            DebugLog.shared.log("impulse install refused: \(message)")
        }
    }

    func removeImpulse(editedFor uid: String?) {
        let name = stage.impulseFile
        var next = stage
        next.impulseFile = nil
        next.impulseMix = nil
        setStage(next, editedFor: uid)
        if let name, !stageByDevice.values.contains(where: { $0.impulseFile == name }) {
            IRLibrary.remove(name: name)
        }
        sweepImpulses()
    }

    func setImpulseMix(_ mix: Double, editedFor uid: String?) {
        guard stage.hasImpulse else { return }
        var next = stage
        next.impulseMix = mix
        setStage(next, editedFor: uid)
    }

    private func adopt(_ response: ImpulseResponse?) {
        engine.processor.setImpulse(response)
        impulseInfo = response.map(ImpulseInfo.init)
        loadedImpulseName = response?.fileName
        publish(engine.processor.impulseStatus,
                live: \.impulseStatusLive, into: \.impulseStatus)
    }

    private func syncImpulse() {
        let wanted = stage.impulseFile
        guard wanted != loadedImpulseName else { return }
        loadedImpulseName = wanted
        guard let wanted else {
            adopt(nil)
            return
        }
        let rate = engine.runningSampleRate
            ?? watcher.defaultOutput?.sampleRate ?? 48000
        impulseBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<ImpulseResponse, Error>
            do {
                let response = try IRLibrary.load(name: wanted)
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
        guard loadedImpulseName == named else { return }
        switch outcome {
        case .success(let response):
            adopt(response)
        case .failure(let error):
            let message = (error as? ImpulseError)?.message
                ?? error.localizedDescription
            engine.processor.setImpulse(nil)
            impulseInfo = nil
            publish(StageProcessor.ImpulseStatus.refused(
                        SafeText.scrubbed(message, limit: 300)),
                    live: \.impulseStatusLive, into: \.impulseStatus)
        }
    }

    private func sweepImpulses() {
        guard !persistenceDisabled, !settingsUnreadable else { return }
        var referenced = Set(stageByDevice.values.compactMap(\.impulseFile))
        if let current = stage.impulseFile { referenced.insert(current) }
        IRLibrary.sweep(keeping: referenced)
    }

    // MARK: - Persistence

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    #if DEBUG
    /// UI previews mutate freely; nothing may reach the user's stage.json.
    private var persistenceDisabled = false
    func previewDisablePersistence() { persistenceDisabled = true }

    func previewSet(stage: StageSettings, exposure: [DayExposure],
                    currentDb: Double?, correlation: Double? = nil,
                    levelTracking: Bool = false,
                    verdict: QualityAnalyzer.Verdict? = nil,
                    limiterGainReductionDb: Double = 0,
                    loudnessShelfDb: Double = 0,
                    bassGuardBoostDb: Double = 0,
                    bassGuardCeilingDb: Double = 0,
                    bassGuardGainReductionDb: Double = 0,
                    earLevel: EarLevelEstimate = .unavailable,
                    earAnchor: EarVolumeAnchor? = nil,
                    earCalibrationDb: Double = EarLevel.defaultCalibrationDb) {
        persistenceDisabled = true
        self.earLevel = earLevel
        earLevelLive = earLevel
        self.earAnchor = earAnchor
        earAnchorLive = earAnchor
        self.earCalibrationDb = EarLevel.clampedCalibration(earCalibrationDb)
        self.stage = stage
        exposureDays = exposure
        exposureDaysLive = exposure
        currentLevelDb = currentDb
        currentLevelDbLive = currentDb
        sourceCorrelation = correlation
        sourceCorrelationLive = correlation
        self.levelTracking = levelTracking
        self.limiterGainReductionDb = limiterGainReductionDb
        limiterGainReductionDbLive = limiterGainReductionDb
        self.loudnessShelfDb = loudnessShelfDb
        loudnessShelfDbLive = loudnessShelfDb
        self.bassGuardBoostDb = bassGuardBoostDb
        bassGuardBoostDbLive = bassGuardBoostDb
        self.bassGuardCeilingDb = bassGuardCeilingDb
        bassGuardCeilingDbLive = bassGuardCeilingDb
        self.bassGuardGainReductionDb = bassGuardGainReductionDb
        bassGuardGainReductionDbLive = bassGuardGainReductionDb
        qualityVerdict = verdict
        qualityVerdictLive = verdict
    }

    func previewSetImpulse(_ response: ImpulseResponse?,
                           status: StageProcessor.ImpulseStatus) {
        impulseInfo = response.map(ImpulseInfo.init)
        impulseStatus = status
        impulseStatusLive = status
        loadedImpulseName = response?.fileName
    }

    func previewPublishLevel(_ db: Double?) {
        currentLevelDbLive = db
        mirror(db, into: \.currentLevelDb)
    }

    func previewPublishLimiter(_ db: Double) {
        publish(db, live: \.limiterGainReductionDbLive,
                into: \.limiterGainReductionDb)
    }

    func previewPublishVerdict(_ verdict: QualityAnalyzer.Verdict?) {
        qualityVerdictLive = verdict
        mirror(verdict, into: \.qualityVerdict)
    }
    #else
    private let persistenceDisabled = false
    #endif

    func saveNow() {
        guard !persistenceDisabled else { return }
        StageStateFile.save(PersistedStageState(
            stageByDevice: stageByDevice.settings,
            exposure: exposureDaysLive,
            levelTracking: levelTracking,
            detectQuality: detectQuality,
            autoRate: autoRate,
            manualRateHz: manualRateHz,
            a2dpGuard: a2dpGuardModeRaw,
            earCalibrationByDevice: earCalibrationByDevice,
            perAppEQ: perAppEQ))
    }

    // MARK: - Metering

    /// One tick a second while the app runs; near-free when the engine is
    /// idle (the deduplicated heartbeat writes at most once per state change).
    private func startMetering() {
        guard meterTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.meterTick() }
        }
        // Half a second of slack lets the OS coalesce this wake with
        // others — metering doesn't care exactly when within the second.
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private var diagTicks = 0
    private var lastDiagContent = ""
    private var diagSuppressed = 0
    private static let diagFormatter = ISO8601DateFormatter()
    private var correlationSmoothed: Double?

    private var callTicks = 0

    private var limiterDiag: String {
        guard stage.limiterValue else { return "lim=off" }
        return String(format: "lim=-%.1fdB", limiterGainReductionDbLive)
    }

    private var loudDiag: String {
        guard stage.loudnessValue else { return "loud=off" }
        return String(format: "loud=%.1f/%.1f", loudnessTargetDb, loudnessShelfDbLive)
    }

    private var impulseDiag: String {
        Self.impulseDiag(impulseStatusLive, mix: stage.impulseMixValue)
    }

    nonisolated static func impulseDiag(_ status: StageProcessor.ImpulseStatus,
                                        mix: Double) -> String {
        switch status {
        case .off:
            return "ir=off"
        case .refused:
            return "ir=refused"
        case .ready(_, let partitions, let taps, let hop, _):
            return String(format: "ir=on/%dx%d/%dtaps/mix%.2f",
                          partitions, hop, taps, mix)
        }
    }

    private var bassDiag: String {
        guard stage.bassGuardValue else { return "bass=off" }
        return String(format: "bass=%.1f/-%.1fdB", bassGuardCeilingDbLive,
                      bassGuardGainReductionDbLive)
    }

    private var earDiag: String {
        let lufs = shortTerm.lufs.map { String(format: "%.1f", $0) } ?? "nil"
        let anchor: String
        switch earAnchorLive {
        case .qudelix(let db): anchor = String(format: "5k/%.1f", db)
        case .system(let db): anchor = String(format: "system/%.1f", db)
        case nil: anchor = "none"
        }
        let estimate: String
        switch earLevelLive {
        case .unavailable: estimate = "nil"
        case .tooQuiet: estimate = "quiet"
        case .estimated(let db): estimate = String(format: "%.0f", db)
        }
        let average = earLevelAverageDbLive.map { String(format: "%.0f", $0) } ?? "nil"
        return "ear: lufs=\(lufs) anchor=\(anchor) "
            + String(format: "cal=%.0f ", earCalibrationDb)
            + "est=\(estimate) avg=\(average)"
    }

    private func meterTick() {
        callTicks += 1
        if callTicks >= 60 {
            callTicks = 0
            refreshCallState()
            if wantsPerAppEQ {
                onProcessListRefresh?()
                applyAssignmentChange()
            } else {
                reconcile()
            }
        }

        // Heartbeat for field debugging, running or not: engine state, the
        // status line (start errors land there), and what render last saw.
        // Idle lines are deduplicated (a stopped engine writes one line, not
        // one every 15 s forever) and the I/O runs off the main thread.
        diagTicks += 1
        if diagTicks % 15 == 0, !persistenceDisabled {
            let d = engine.processor.renderDiagnostics()
            // Sanitized like every other log path: the status line carries
            // the output device's name, which for Bluetooth is a
            // radio-supplied string — a newline in it forges heartbeat lines.
            let content = DebugLog.sanitized(
                "running=\(engine.isRunning) call=\(callActiveLive) "
                + "hold=\(engine.callHold) "
                + (guardDiagnostics.map { $0() + " " } ?? "")
                + (suggestionDiagnostics.map { $0() + " " } ?? "")
                + (aiDiagnostics.map { $0() + " " } ?? "")
                + "status=\"\(engine.status)\" "
                + "render: channels=\(d.channels) buffers=\(d.inputBuffers) stage=\(d.stageRan ? "on" : "off") "
                + "(settings enabled=\(stage.enabled) width=\(Int(stage.width)) room=\(stage.room) "
                + String(format: "cross=%.2f/%.2f/%.2f bal=%.1fdB/%.2fms) ",
                         stage.crossLowTrimValue, stage.crossMidTrimValue,
                         stage.crossHighTrimValue, stage.balanceDbValue,
                         stage.alignMsValue)
                + Self.perAppDiag(taps: engine.activeAppTaps.count,
                                  assigned: assignedAppCount) + " "
                + limiterDiag + " " + loudDiag + " " + bassDiag + " "
                + impulseDiag + " "
                + "quality=\(qualityVerdictLive.map(String.init(describing:)) ?? "nil") \(analyzer.lastDebug) "
                + earDiag)
            if engine.isRunning || content != lastDiagContent {
                let repeats = diagSuppressed
                diagSuppressed = 0
                lastDiagContent = content
                let suffix = repeats > 0
                    ? " (+\(repeats) identical ticks suppressed)" : ""
                let line = Self.diagFormatter.string(from: Date()) + " "
                    + content + suffix
                diagLog.append(line)
            } else {
                diagSuppressed += 1
            }
        }

        guard engine.isRunning else {
            currentLevelDbLive = nil
            mirror(currentLevelDbLive, into: \.currentLevelDb)
            sourceCorrelationLive = nil
            mirror(sourceCorrelationLive, into: \.sourceCorrelation)
            publish(0.0, live: \.limiterGainReductionDbLive,
                    into: \.limiterGainReductionDb)
            if loudnessTargetDb != 0 { loudnessTargetDb = 0 }
            publish(0.0, live: \.loudnessShelfDbLive, into: \.loudnessShelfDb)
            engine.processor.applyLoudness(shelfDb: 0)
            publish(0.0, live: \.bassGuardBoostDbLive, into: \.bassGuardBoostDb)
            publish(0.0, live: \.bassGuardCeilingDbLive, into: \.bassGuardCeilingDb)
            publish(0.0, live: \.bassGuardGainReductionDbLive,
                    into: \.bassGuardGainReductionDb)
            engine.processor.applyBassGuard(ceilingDb: 0, predictedBoostDb: 0)
            correlationSmoothed = nil
            clearEarLevel()
            clearVerdict()
            qualityRate = nil
            return
        }
        if let corr = engine.processor.drainSourceCorrelation() {
            // Light smoothing so a quiet moment doesn't flicker the notice.
            let smoothed = 0.7 * (correlationSmoothed ?? corr) + 0.3 * corr
            correlationSmoothed = smoothed
            if sourceCorrelationLive == nil
                || abs(smoothed - (sourceCorrelationLive ?? 0)) > 0.001 {
                sourceCorrelationLive = smoothed
                mirror(smoothed, into: \.sourceCorrelation)
            }
        }

        updateLimiterTelemetry()
        refreshImpulseStatus()
        updateBassGuardTelemetry()
        qualityTick()
        updateEarLevel()
        updateLoudness()
        updateBassGuard()

        let (sumSquares, frames) = engine.processor.drainMeter()
        guard frames > 0 else {
            currentLevelDbLive = nil
            mirror(currentLevelDbLive, into: \.currentLevelDb)
            return
        }
        let power = sumSquares / Double(frames)
        guard power.isFinite else { return }
        let db = power > 0 ? 10 * log10(power) : -120
        let level = max(db, -80)
        if currentLevelDbLive != level {
            currentLevelDbLive = level
            mirror(level, into: \.currentLevelDb)
        }

        let updated = Self.exposureAfterTick(exposureDaysLive, db: db, power: power,
                                             tracking: levelTracking, today: Self.dayKey())
        guard updated != exposureDaysLive else { return }
        exposureDaysLive = updated
        mirror(updated, into: \.exposureDays)

        // Once a second is too often for disk; every 30 audible seconds is
        // plenty, and the regular edit/quit paths save the rest.
        meterTicksSinceSave += 1
        if meterTicksSinceSave >= 30 {
            meterTicksSinceSave = 0
            scheduleSave()
        }
    }

    private func refreshImpulseStatus() {
        engine.processor.refreshImpulseLayout()
        let next = engine.processor.impulseStatus
        if next == .off {
            if !stage.hasImpulse {
                publish(next, live: \.impulseStatusLive, into: \.impulseStatus)
            }
            return
        }
        publish(next, live: \.impulseStatusLive, into: \.impulseStatus)
    }

    private func updateLimiterTelemetry() {
        let floor = engine.processor.drainLimiterFloor()
        let reduction = floor.isFinite && floor > 0 && floor < 0.999
            ? -20 * log10(Double(floor)) : 0
        publish(reduction, live: \.limiterGainReductionDbLive,
                into: \.limiterGainReductionDb)
    }

    private func updateEarLevel() {
        let (sumSquares, frames) = engine.processor.drainLoudnessMeter()
        shortTerm.add(sumSquares: sumSquares, frames: frames)

        let anchor = volumeAnchor()
        publish(anchor, live: \.earAnchorLive, into: \.earAnchor)

        let next = EarLevel.estimate(shortTermLUFS: shortTerm.lufs,
                                     volumeDb: anchor?.db,
                                     calibrationDb: earCalibrationDb)
        publish(next, live: \.earLevelLive, into: \.earLevel)

        if case .estimated = next, let lufs = shortTerm.lufs { earAverage.add(lufs) }
        let average: Double? = earAverage.lufs.flatMap {
            if case .estimated(let db) = EarLevel.estimate(
                shortTermLUFS: $0, volumeDb: anchor?.db,
                calibrationDb: earCalibrationDb) { return db }
            return nil
        }
        publish(average, live: \.earLevelAverageDbLive, into: \.earLevelAverageDb)
    }

    nonisolated static let bassGuardScanLowHz: Double = 20
    nonisolated static let bassGuardScanHighHz: Double = 200
    nonisolated static let bassGuardScanPoints = 201
    nonisolated static let bassGuardInertDb: Double = 0.5

    nonisolated static func bassGuardBoostDb(bands: [QxEqBandValue],
                                             loudnessShelfDb: Double) -> Double {
        let freqs = EQCurve.logSweep(count: bassGuardScanPoints,
                                     from: bassGuardScanLowHz,
                                     to: bassGuardScanHighHz)
        let curve = EQCurve.response(bands: bands, preGain: 0, at: freqs)
        let shelfDb = loudnessShelfDb.isFinite
            ? min(max(loudnessShelfDb, 0), EarLevel.maxShelfDb) : 0
        let shelf = shelfDb > 0.05
            ? BiquadSection.lowShelf(freq: StageProcessor.loudnessLowHz,
                                     gainDb: shelfDb,
                                     q: StageProcessor.loudnessShelfQ,
                                     sampleRate: EQCurve.sampleRate)
            : nil
        var worst = 0.0
        for (i, f) in freqs.enumerated() {
            var db = curve[i]
            if let shelf {
                db += shelf.magnitudeDb(at: f, sampleRate: EQCurve.sampleRate)
            }
            if db.isFinite, db > worst { worst = db }
        }
        return worst
    }

    nonisolated static func bassGuardCeilingDb(worstBoostDb: Double,
                                               strength: Double) -> Double {
        guard worstBoostDb.isFinite, worstBoostDb > bassGuardInertDb else { return 0 }
        let scale = strength.isFinite ? min(max(strength, 0), 1) : 0
        return min(worstBoostDb, StageProcessor.bassGuardMaxCeilingDb) * scale
    }

    private var scannedBands: [QxEqBandValue]?
    private var scannedShelfDb: Double = 0
    private var scannedBoostDb: Double = 0

    private func updateBassGuard() {
        let measuring = stage.enabled && stage.bassGuardValue
        var boost = 0.0
        if measuring {
            let bands = deviceEqCurve?() ?? []
            if bands != scannedBands
                || abs(loudnessShelfDbLive - scannedShelfDb) >= 0.1 {
                scannedBands = bands
                scannedShelfDb = loudnessShelfDbLive
                scannedBoostDb = Self.bassGuardBoostDb(
                    bands: bands, loudnessShelfDb: loudnessShelfDbLive)
            }
            boost = scannedBoostDb
        } else if scannedBands != nil {
            scannedBands = nil
            scannedShelfDb = 0
            scannedBoostDb = 0
        }
        let ceiling = measuring
            ? Self.bassGuardCeilingDb(worstBoostDb: boost,
                                      strength: stage.bassGuardStrengthValue)
            : 0
        let moved = abs(boost - bassGuardBoostDbLive) >= 0.1
            || abs(ceiling - bassGuardCeilingDbLive) >= 0.1
            || (boost == 0 && bassGuardBoostDbLive != 0)
            || (ceiling == 0 && bassGuardCeilingDbLive != 0)
        if moved {
            publish(boost, live: \.bassGuardBoostDbLive, into: \.bassGuardBoostDb)
            publish(ceiling, live: \.bassGuardCeilingDbLive, into: \.bassGuardCeilingDb)
        }
        engine.processor.applyBassGuard(ceilingDb: bassGuardCeilingDbLive,
                                        predictedBoostDb: bassGuardBoostDbLive)
    }

    private func updateBassGuardTelemetry() {
        let deepest = engine.processor.drainBassGuardReduction()
        let reduction = deepest.isFinite && deepest > 0.05 ? Double(deepest) : 0
        publish(reduction, live: \.bassGuardGainReductionDbLive,
                into: \.bassGuardGainReductionDb)
    }

    private func updateLoudness() {
        let target = stage.loudnessValue
            ? EarLevel.shelfDb(earLevelDb: earLevelAverageDbLive,
                               strength: stage.loudnessStrengthValue)
            : 0
        loudnessTargetDb = target
        engine.processor.applyLoudness(shelfDb: target)
        publish(engine.processor.appliedLoudnessShelfDb,
                live: \.loudnessShelfDbLive, into: \.loudnessShelfDb)
    }

    func volumeAnchor() -> EarVolumeAnchor? {
        let onQudelix = outputUID != nil && outputUID == qudelixOutput?.uid
        return Self.volumeAnchor(
            playingToQudelix: onQudelix,
            qudelixVolumeDb: onQudelix ? qudelixVolumeDb?() : nil,
            systemVolumeDb: watcher.defaultOutput
                .flatMap { AudioOutputs.outputVolumeDb($0.id) }
                .map(Double.init))
    }

    static func volumeAnchor(playingToQudelix: Bool, qudelixVolumeDb: Double?,
                             systemVolumeDb: @autoclosure () -> Double?
    ) -> EarVolumeAnchor? {
        if playingToQudelix, let db = qudelixVolumeDb,
           EarLevel.plausibleVolumeDb.contains(db) {
            return .qudelix(db)
        }
        guard let db = systemVolumeDb(), EarLevel.plausibleVolumeDb.contains(db) else {
            return nil
        }
        return .system(db)
    }

    /// The pure half of one metering second: the history that should exist
    /// after hearing `db` (linear `power`), given the history so far. Returns
    /// the input untouched when the second doesn't count.
    ///
    /// The tracking switch is checked HERE and nowhere else, because the
    /// engine's own state cannot stand in for it: quality detection runs the
    /// same tap in monitor mode, so "the engine is up" says nothing about
    /// whether the user asked for a record of their listening. Reading the
    /// engine instead is what let the Level pane show a day's totals directly
    /// under a switch that was off and a line promising nothing was recorded.
    static func exposureAfterTick(_ days: [DayExposure], db: Double, power: Double,
                                  tracking: Bool, today key: String) -> [DayExposure] {
        // Silence isn't listening; don't count it.
        guard tracking, db > silenceFloorDb else { return days }
        var days = days
        // Find, don't assume last: a timezone hop or clock rollback can make
        // "today" a key that already exists earlier in the array, and a
        // duplicate would split the day and break ForEach identity.
        var idx = days.firstIndex { $0.day == key }
        if idx == nil {
            days.append(DayExposure(day: key, audibleSeconds: 0,
                                    loudSeconds: 0, energySum: 0))
            if days.count > 14 {
                days.removeFirst(days.count - 14)
            }
            idx = days.count - 1
        }
        guard let i = idx else { return days }
        days[i].audibleSeconds += 1
        days[i].energySum += power
        if db > loudThresholdDb { days[i].loudSeconds += 1 }
        return days
    }

    /// Throw the recorded history away, now rather than on the save timer.
    ///
    /// Its own control rather than a side effect of switching tracking off:
    /// pausing and deleting are different intentions, and history recorded
    /// while the switch was on is the user's to keep. That cuts both ways for
    /// anything an earlier build recorded while the switch was off — it is
    /// still their data, and quietly deleting it on launch would be its own
    /// kind of surprise, so the pane says plainly that nothing new is being
    /// added and puts the delete one click away.
    func clearExposureHistory() {
        guard !exposureDaysLive.isEmpty else { return }
        exposureDaysLive = []
        mirror(exposureDaysLive, into: \.exposureDays)
        meterTicksSinceSave = 0
        saveWork?.cancel()
        saveNow()
    }

    private lazy var diagLog = DiagLog(
        url: StageStateFile.directory.appendingPathComponent("diag.txt"))

    /// The diag file is ours, but a symlink could be planted at its path and
    /// `String(contentsOf:)` would follow it into an arbitrarily large file.
    /// Refuse symlinks and cap the read; oversized or unreadable starts fresh.
    nonisolated static func readDiagTail(_ url: URL) -> String {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_NOFOLLOW)
        }
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        var data = Data(count: 256 * 1024)
        let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard n > 0 else { return "" }
        return String(data: data.prefix(n), encoding: .utf8) ?? ""
    }

    // MARK: - Stream quality

    /// Once a second while the engine runs: pull the freshest samples, FFT
    /// them, and every few windows take a classification. The published
    /// verdict changes only after three consecutive agreeing raw results —
    /// track transitions and quiet passages flicker, listeners don't.
    private var qualityWindowsFed = 0
    private var qualityRate: Double?
    private var qualityDeviceUID: String?

    private func qualityTick() {
        guard detectQuality, engine.isRunning,
              !engine.processor.isMutedNow else { return }

        let rate = engine.runningSampleRate

        if rate != qualityRate {
            if qualityRate != nil, rate != autoSetRate { clearVerdict() }
            qualityRate = rate
            analyzer.reset()
            qualityWindowsFed = 0
            rawVerdict = nil
            rawVerdictStreak = 0
        }
        // The engine moved to another device, which is a different kind of
        // break: the standing verdict describes a stream we have stopped
        if engine.runningDeviceUID != qualityDeviceUID {
            qualityDeviceUID = engine.runningDeviceUID
            analyzer.reset()
            qualityWindowsFed = 0
            clearVerdict()
        }
        let samples = engine.processor.drainSpectrumSamples(QualityAnalyzer.fftSize)
        guard samples.count >= QualityAnalyzer.fftSize else { return }
        analyzer.feed(samples)
        qualityWindowsFed += 1
        guard qualityWindowsFed >= 3 else { return }
        qualityWindowsFed = 0

        guard let rate, let raw = analyzer.classify(sampleRate: rate) else { return }

        // Boundary jitter guard: the same physical cliff measures a few
        // hundred Hz differently between rounds, and near the 20.25 kHz
        // class boundary that flips the DISPLAYED verdict back and forth.
        // A standing lossless verdict holds through ambiguous-zone readings.
        var effective = raw
        if let cur = qualityVerdictLive, case .losslessLike = cur,
           case .lossyHigh(let k) = raw, k >= 19.7 {
            effective = .losslessLike(cutoffKHz: k)
        }

        // Stability is judged on the verdict's KIND — the measured cutoff
        // rides along and refreshes on every publish.
        if let previous = rawVerdict, previous.kind == effective.kind {
            rawVerdictStreak += 1
        } else {
            rawVerdictStreak = 1
        }
        rawVerdict = effective
        guard rawVerdictStreak >= 3 else { return }

        let kindChanged = qualityVerdictLive?.kind != effective.kind
        if kindChanged {
            DebugLog.shared.log("stream quality verdict → \(effective) [\(analyzer.lastDebug)]")
        }
        let previousClass = qualityVerdictLive?.isLosslessClass
        qualityVerdictLive = effective
        mirror(effective, into: \.qualityVerdict)
        verdictDeviceUID = engine.runningDeviceUID
        if effective.isLosslessClass != previousClass {
            verdictStableSince = effective.isLosslessClass != nil ? Date() : nil
            onStatusChange?()
        }
        autoSwitchIfDue()
    }

    /// The lossy↔lossless rate automation: decide, then act.
    private func autoSwitchIfDue() {
        // The cheap refusals before the rate query, which is a round trip
        // into coreaudiod; the decision below re-checks them anyway.
        guard autoRate, !stage.enabled, let device = qudelixOutput else { return }

        let now = Date()
        guard let target = Self.autoRateTarget(
            verdict: qualityVerdictLive,
            measuredOn: verdictDeviceUID,
            device: device,
            availableRates: AudioOutputs.availableNominalRates(device.id),
            manualRateHz: manualRateHz,
            autoRate: autoRate,
            stageEnabled: stage.enabled,
            callActive: callActiveLive,
            secondsStable: verdictStableSince.map { now.timeIntervalSince($0) },
            secondsSinceLastSwitch: now.timeIntervalSince(lastAutoSwitch))
        else { return }

        guard !AudioOutputs.callModeActive(outputID: device.id) else { return }

        // First automatic act with no manual baseline yet: the rate we're
        // ABOUT to leave becomes the baseline, or lossy content could never
        // return anywhere — switch down once, ratchet forever.
        if manualRateHz == nil {
            manualRateHz = device.sampleRate
            scheduleSave()
        }

        lastAutoSwitch = now
        DebugLog.shared.log(String(format:
            "stream quality %@ — switching USB rate to %g kHz",
            qualityVerdictLive?.isLosslessClass == true ? "lossless-class" : "lossy",
            target / 1000))
        if setNominalRate(target, for: device) {
            autoSetRate = target
        }
    }

    /// The rate the 5K should be moved to, or nil for "leave it alone" — the
    /// whole of the automation's judgement, with no clock and no CoreAudio in
    /// it so every refusal can be tested.
    ///
    /// Deliberately conservative: the verdict must have held for 10 s,
    /// switches are at least 45 s apart, and nothing moves while the Stage is
    /// inserted (it resamples anyway, so a switch would only add an audio
    /// blip). The strictest condition is `measuredOn`: a verdict is evidence
    /// about the device the engine listened to, which is the Mac's default
    /// output. Plug the 5K in while the Mac still plays to its speakers and
    /// the audio that produced the verdict never went near the 5K — acting on
    /// it would renegotiate one device's rate from another device's sound.
    static func autoRateTarget(verdict: QualityAnalyzer.Verdict?,
                               measuredOn verdictDeviceUID: String?,
                               device: AudioOutput?,
                               availableRates: [Double],
                               manualRateHz: Double?,
                               autoRate: Bool,
                               stageEnabled: Bool,
                               callActive: Bool,
                               secondsStable: Double?,
                               secondsSinceLastSwitch: Double) -> Double? {
        guard autoRate, !stageEnabled, !callActive,
              let device,
              let verdictDeviceUID, device.uid == verdictDeviceUID,
              let verdict,
              let stable = secondsStable, stable >= 10,
              secondsSinceLastSwitch >= 45,
              let target = rateForVerdict(verdict, availableRates: availableRates,
                                          manualRateHz: manualRateHz,
                                          deviceRate: device.sampleRate)
        else { return nil }
        guard availableRates.contains(target), device.sampleRate != target else { return nil }
        return target
    }

    static func rateForVerdict(_ verdict: QualityAnalyzer.Verdict,
                               availableRates: [Double],
                               manualRateHz: Double?,
                               deviceRate: Double) -> Double? {
        guard let lossless = verdict.isLosslessClass else { return nil }
        if case .hiRes = verdict {
            return availableRates.filter { $0 >= 88200 }.max()
        }
        if lossless { return 44100 }
        return manualRateHz ?? deviceRate
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        // POSIX-pinned: a non-Gregorian system calendar would otherwise
        // change the keys and split every day's history in two.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }
}

final class DiagLog {
    static let defaultMaxLines = 200
    static let defaultMaxBytes = 192 << 10

    private let url: URL
    private let queue: DispatchQueue
    private let maxLines: Int
    private let maxBytes: Int

    private var tail: [String] = []
    private var bytes = 0
    private var loaded = false

    init(url: URL, maxLines: Int = defaultMaxLines,
         maxBytes: Int = defaultMaxBytes,
         queue: DispatchQueue = DispatchQueue(label: "stage.diag", qos: .utility)) {
        self.url = url
        self.maxLines = max(maxLines, 1)
        self.maxBytes = max(maxBytes, 1)
        self.queue = queue
    }

    func append(_ line: String) {
        queue.async { self.write(line) }
    }

    func flush() {
        queue.sync {}
    }

    private func write(_ line: String) {
        if !loaded { adoptExistingFile() }
        tail.append(line)
        if tail.count > maxLines { tail.removeFirst(tail.count - maxLines) }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        guard bytes + data.count <= maxBytes, appendToFile(data) else {
            rewrite()
            return
        }
        bytes += data.count
    }

    private func adoptExistingFile() {
        loaded = true
        tail = StageState.readDiagTail(url).split(separator: "\n")
            .suffix(maxLines).map(String.init)
        rewrite()
    }

    private func rewrite() {
        while tail.count > 1, Self.encodedSize(tail) > maxBytes / 2 {
            tail.removeFirst()
        }
        let text = tail.isEmpty ? "" : tail.joined(separator: "\n") + "\n"
        let data = Data(text.utf8)
        bytes = SafeFile.writeAtomic(data, to: url) ? data.count : 0
    }

    private static func encodedSize(_ lines: [String]) -> Int {
        lines.reduce(0) { $0 + $1.utf8.count + 1 }
    }

    private func appendToFile(_ data: Data) -> Bool {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var written = 0
        return data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            while written < buffer.count {
                let n = Darwin.write(fd, base + written, buffer.count - written)
                if n <= 0 {
                    if n < 0, errno == EINTR { continue }
                    return false
                }
                written += n
            }
            return true
        }
    }
}
