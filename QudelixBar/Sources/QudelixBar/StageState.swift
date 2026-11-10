import Combine
import Foundation
import SwiftUI

@MainActor
final class StageState: ObservableObject {
    let engine = StageEngine()
    let watcher = OutputWatcher()

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
    private var loadedImpulse: ImpulseResponse?
    private var primeGate = ImpulsePrimeGate()

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
    @Published private(set) var callWitnesses = CallWitnesses()
    private(set) var callWitnessesLive = CallWitnesses()
    private var callReleasedByHand = false

    var deviceCallState: (() -> (activeCall: Bool?, inputSource: String?)?)?
    var requestDeviceStatus: (() -> Void)?
    var releaseHeadsetMicrophone: (() -> Bool)?

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

    @Published private(set) var detectQuality = true
    @Published private(set) var autoRate = true
    @Published private(set) var qualityVerdict: QualityAnalyzer.Verdict?
    private(set) var qualityVerdictLive: QualityAnalyzer.Verdict?
    private let analyzer = QualityAnalyzer()
    var automationTick: ((EqAutomation.Context) -> Void)?
    var automationDiagnostics: (() -> String)?
    @Published private(set) var balance: BalanceFeatures?
    private var balanceLive: BalanceFeatures?
    private var balanceAnchor: BalanceFeatures?
    private var freshBalanceReading: BalanceFeatures?
    private static let balanceAnchorCoefficient = 1 - exp(-3.0 / 30)
    private var rawVerdict: QualityAnalyzer.Verdict?
    private var rawVerdictStreak = 0
    private var verdictDeviceUID: String?
    private var verdictStableSince: Date?
    private var lastAutoSwitch = Date.distantPast
    private var manualRateHz: Double?
    var manualRate: Double? { manualRateHz }
    @Published private(set) var autoSetRate: Double?

    @Published private(set) var currentLevelDb: Double?
    private(set) var currentLevelDbLive: Double?
    @Published private(set) var exposureDays: [DayExposure] = []
    private(set) var exposureDaysLive: [DayExposure] = []
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
    var bassGuardInert: Bool { bassGuardBoostDb <= StagePolicy.bassGuardInertDb }
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
        mirror(balanceLive, into: \.balance)
        mirror(callActiveLive, into: \.callActive)
        mirror(callWitnessesLive, into: \.callWitnesses)
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

    private var stageByDevice = StageDeviceStore()
    private var settingsUnreadable = false
    private let settingsURL: URL
    @Published private(set) var settingsNotice: String?
    static let maxCalibratedDevices = 64
    private var meterTimer: Timer?
    private var meterTicksSinceSave = 0
    private var saveWork: DispatchWorkItem?
    private var started = false
    private var forwarders: Set<AnyCancellable> = []

    var outputName: String? { watcher.defaultOutput?.name }
    var outputUID: String? { watcher.defaultOutput?.uid }

    var qudelixOutput: AudioOutput? {
        Self.qudelixOutput(in: watcher.devices)
    }

    nonisolated static func qudelixOutput(in devices: [AudioOutput]) -> AudioOutput? {
        devices.first {
            !StageEngine.isEngineDevice(uid: $0.uid)
                && $0.name.localizedCaseInsensitiveContains("qudelix")
        }
    }

    var qudelixUsbOutput: AudioOutput? {
        Self.qudelixUsbOutput(in: watcher.devices)
    }

    nonisolated static func qudelixUsbOutput(in devices: [AudioOutput]) -> AudioOutput? {
        qudelixOutput(in: devices).flatMap { $0.isBluetooth ? nil : $0 }
    }

    @discardableResult
    func setNominalRate(_ rate: Double, for device: AudioOutput, manual: Bool = false) -> Bool {
        if manual, let baseline = StagePolicy.acceptableManualRate(rate) {
            manualRateHz = baseline
            autoSetRate = nil
            scheduleSave()
        }
        let accepted = AudioOutputs.setNominalRate(device.id, rate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.watcher.refreshNow()
        }
        return accepted
    }

    init(settingsURL: URL = StageStateFile.url) {
        self.settingsURL = settingsURL
        watcher.watchesVolume = true
        engine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwarders)
        watcher.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwarders)
        let outcome = StageStateFile.loadOutcome(settingsURL)
        settingsUnreadable = !outcome.permitsSaving
        if let notice = StageStateFile.notice(for: outcome,
                                              fileName: settingsURL.lastPathComponent) {
            settingsNotice = notice
            DebugLog.shared.log("stage settings file could not be loaded; left alone")
        }
        if case .loaded(let saved) = outcome {
            stageByDevice = StageDeviceStore(saved.stageByDevice.mapValues { $0.clamped() })
            levelTracking = saved.levelTracking
            detectQuality = saved.detectQuality ?? true
            autoRate = saved.autoRate ?? true
            manualRateHz = StagePolicy.acceptableManualRate(saved.manualRateHz)
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
               AudioOutputs.currentNominalRate(device.id) != self.engine.outputRateAtStart {
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
        let reachable = StageEngine.reachablePlan(plan, failed: engine.failedTapBundleIDs)
        let sameTaps = StageEngine.sameTaps(engine.activeAppPlan, reachable)
        engine.appTapPlan = plan
        engine.followProcessList = wantsPerAppEQ
        if engine.isRunning, engine.mode == .insert, sameTaps {
            engine.processor.applyAppChains(reachable.map(\.chain))
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
        clearBalance()
    }

    private func updateBalance(_ reading: BalanceFeatures?) {
        guard let reading, reading.bassDb.isFinite, reading.tiltDbPerOctave.isFinite,
              reading.presenceDb.isFinite else { return }
        let k = Self.balanceAnchorCoefficient
        let anchor = balanceAnchor.map { a in
            BalanceFeatures(
                bassDb: a.bassDb + k * (reading.bassDb - a.bassDb),
                tiltDbPerOctave: a.tiltDbPerOctave + k * (reading.tiltDbPerOctave - a.tiltDbPerOctave),
                presenceDb: a.presenceDb + k * (reading.presenceDb - a.presenceDb))
        } ?? reading
        balanceAnchor = anchor
        freshBalanceReading = reading
        func tenth(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        balanceLive = BalanceFeatures(bassDb: tenth(anchor.bassDb),
                                      tiltDbPerOctave: tenth(anchor.tiltDbPerOctave),
                                      presenceDb: tenth(anchor.presenceDb))
        mirror(balanceLive, into: \.balance)
    }

    private func clearBalance() {
        balanceAnchor = nil
        balanceLive = nil
        freshBalanceReading = nil
        mirror(balanceLive, into: \.balance)
        analyzer.reset()
        qualityWindowsFed = 0
    }

    private func automationStep() {
        let reading = freshBalanceReading
        freshBalanceReading = nil
        let running = engine.isRunning
        let uid = running ? engine.runningDeviceUID : nil
        let onQudelix = uid != nil && uid == qudelixOutput?.uid
        automationTick?(EqAutomation.Context(
            reading: reading, verdict: qualityVerdictLive,
            detecting: detectQuality && running,
            muted: engine.processor.isMutedNow,
            onCall: callActiveLive || engine.callHold,
            deviceUID: uid, onQudelixOutput: onQudelix, dt: 1))
    }

    func setAutoRate(_ on: Bool) {
        autoRate = on
        scheduleSave()
    }

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

    private var wantedMode: StageEngine.Mode? {
        StagePolicy.wantedMode(stageEnabled: stage.enabled, perAppEQ: wantsPerAppEQ,
                        levelTracking: levelTracking, detectQuality: detectQuality)
    }

    private var desiredMode: StageEngine.Mode? {
        guard !callActiveLive else { return nil }
        return wantedMode
    }

    var engineFailure: StageEngine.Failure? {
        guard !engine.isRunning, desiredMode != nil else { return nil }
        return engine.failure
    }

    private func reconcile(plan: [StageEngine.AppTapEntry]? = nil) {
        engine.followProcessList = wantsPerAppEQ
        if !engine.isRunning { engine.appTapPlan = plan ?? desiredTapPlan() }
        let device = watcher.defaultOutput
        let hold = callActiveLive && wantedMode != nil && device != nil
        let desired = desiredMode

        if engine.isRunning, !hold {
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
            if awaitImpulsePriming(for: device) { return }
            engine.start(output: device, mode: desired)
            if engine.isRunning, let rate = engine.runningSampleRate {
                primeGate.engineStarted(at: rate)
            }
        }
    }

    private func awaitImpulsePriming(for device: AudioOutput) -> Bool {
        let rate = AudioOutputs.currentNominalRate(device.id)
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
        if let running = engine.runningSampleRate { return running }
        if let device = watcher.defaultOutput {
            return AudioOutputs.currentNominalRate(device.id)
        }
        return 48000
    }

    private func refreshCallState() {
        var witnesses = CallWitnesses()
        if let device = watcher.defaultOutput, device.isBluetooth {
            witnesses.outputAtCallRate = AudioOutputs.outputAtCallRate(device.id)
            witnesses.headsetMicRunning = AudioOutputs.headsetMicRunning(outputID: device.id)
        }
        if let reported = deviceCallState?() {
            witnesses.deviceActiveCall = reported.activeCall
            witnesses.deviceInputSource = reported.inputSource
        }
        let verdict = StagePolicy.callVerdict(witnesses, releasedByHand: callReleasedByHand)
        callReleasedByHand = verdict.stillReleased
        if witnesses != callWitnessesLive {
            callWitnessesLive = witnesses
            mirror(witnesses, into: \.callWitnesses)
        }
        if verdict.active != callActiveLive {
            callActiveLive = verdict.active
            mirror(verdict.active, into: \.callActive)
            onStatusChange?()
            DebugLog.shared.log("call state → \(verdict.active ? "on a call" : "clear")"
                                + " (\(witnesses.summary))")
        }
    }

    func callActiveFresh() -> Bool {
        guard started else { return false }
        refreshCallState()
        return callActiveLive
    }

    func checkCallNow() {
        guard started else { return }
        refreshCallState()
        reconcile()
    }

    func releaseCall() {
        guard started else { return }
        var actions: [String] = []
        if let device = watcher.defaultOutput, device.isBluetooth {
            if AudioOutputs.headsetMicRunning(outputID: device.id) {
                if releaseHeadsetMicrophone?() == true {
                    actions.append("input moved to the built-in microphone")
                }
            } else if AudioOutputs.outputAtCallRate(device.id),
                      let rate = StagePolicy.rateAfterCall(
                          manual: manualRateHz,
                          available: AudioOutputs.availableNominalRates(device.id)),
                      AudioOutputs.setNominalRate(device.id, rate) {
                actions.append(String(format: "output rate set to %g kHz", rate / 1000))
            }
        }
        callReleasedByHand = true
        DebugLog.shared.log("call mode released by hand (\(callWitnessesLive.summary))"
                            + (actions.isEmpty ? "" : ": " + actions.joined(separator: ", ")))
        requestDeviceStatus?()
        refreshCallState()
        reconcile()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.watcher.refreshNow()
            self?.checkCallNow()
        }
    }

    private var lastOutputUID: String?

    private func outputsChanged() {
        let uid = outputUID
        if let uid {
            if lastOutputUID == nil, stageByDevice[uid] == nil,
               stage.enabled || stage.doesAnything {
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
        let rate = impulsePrimeRate()
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
        loadedImpulse = response
        primeGate.adopted()
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
        let rate = impulsePrimeRate()
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
            loadedImpulse = nil
            primeGate.adopted()
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

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    #if DEBUG
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

    func previewSetBalance(_ reading: BalanceFeatures?) {
        balance = reading
        balanceLive = reading
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
        guard !persistenceDisabled, !settingsUnreadable else { return }
        StageStateFile.save(PersistedStageState(
            stageByDevice: stageByDevice.settings,
            exposure: exposureDaysLive,
            levelTracking: levelTracking,
            detectQuality: detectQuality,
            autoRate: autoRate,
            manualRateHz: manualRateHz,
            a2dpGuard: a2dpGuardModeRaw,
            earCalibrationByDevice: earCalibrationByDevice,
            perAppEQ: perAppEQ), to: settingsURL)
    }

    private func startMetering() {
        guard meterTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.meterTick() }
        }
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

    private var balanceDiag: String {
        balanceLive.map {
            String(format: "bal=%+.1f,%+.1f,%+.1f", $0.bassDb, $0.tiltDbPerOctave, $0.presenceDb)
        } ?? "bal=-"
    }

    private func meterTick() {
        callTicks += 1
        if callTicks >= (callActiveLive ? 5 : 60) {
            callTicks = 0
            if callActiveLive { requestDeviceStatus?() }
            refreshCallState()
            if wantsPerAppEQ {
                onProcessListRefresh?()
                applyAssignmentChange()
            } else {
                reconcile()
            }
        }

        diagTicks += 1
        if diagTicks % 15 == 0, !persistenceDisabled {
            let d = engine.processor.renderDiagnostics()
            let content = DebugLog.sanitized(
                "running=\(engine.isRunning) call=\(callActiveLive)[\(callWitnessesLive.summary)] "
                + "hold=\(engine.callHold) drives=\(engine.drivesOutputDevice) "
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
                + balanceDiag + " "
                + (automationDiagnostics.map { $0() + " " } ?? "")
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
            automationStep()
            return
        }
        if let corr = engine.processor.drainSourceCorrelation() {
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
        automationStep()
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

        let updated = StagePolicy.exposureAfterTick(exposureDaysLive, db: db, power: power,
                                             tracking: levelTracking, today: Self.dayKey())
        guard updated != exposureDaysLive else { return }
        exposureDaysLive = updated
        mirror(updated, into: \.exposureDays)

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
                scannedBoostDb = StagePolicy.bassGuardBoostDb(
                    bands: bands, loudnessShelfDb: loudnessShelfDbLive)
            }
            boost = scannedBoostDb
        } else if scannedBands != nil {
            scannedBands = nil
            scannedShelfDb = 0
            scannedBoostDb = 0
        }
        let ceiling = measuring
            ? StagePolicy.bassGuardCeilingDb(worstBoostDb: boost,
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
        return StagePolicy.volumeAnchor(
            playingToQudelix: onQudelix,
            qudelixVolumeDb: onQudelix ? qudelixVolumeDb?() : nil,
            systemVolumeDb: watcher.defaultOutput
                .flatMap { watcher.systemVolumeDb(of: $0) }
                .map(Double.init))
    }

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

    nonisolated static let diagReadCap = 256 << 10

    nonisolated static func readDiagTail(_ url: URL) -> String {
        guard let data = SafeFile.read(url, cap: diagReadCap) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

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

        if let rate { updateBalance(analyzer.balance(sampleRate: rate)) }
        guard let rate, let raw = analyzer.classify(sampleRate: rate) else { return }

        var effective = raw
        if let cur = qualityVerdictLive, case .losslessLike = cur,
           case .lossyHigh(let k) = raw, k >= 19.7 {
            effective = .losslessLike(cutoffKHz: k)
        }

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

    private func autoSwitchIfDue() {
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

        if manualRateHz == nil, let baseline = StagePolicy.acceptableManualRate(device.sampleRate) {
            manualRateHz = baseline
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
        StagePolicy.autoRateTarget(
            verdict: verdict,
            measuredOn: verdictDeviceUID,
            device: device.map {
                AutoRateDevice(uid: $0.uid, isBluetooth: $0.isBluetooth, rate: $0.sampleRate)
            },
            availableRates: availableRates,
            manualRateHz: manualRateHz,
            autoRate: autoRate,
            stageEnabled: stageEnabled,
            callActive: callActive,
            secondsStable: secondsStable,
            secondsSinceLastSwitch: secondsSinceLastSwitch)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
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
