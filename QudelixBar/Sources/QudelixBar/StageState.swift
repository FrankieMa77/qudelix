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

    // Stream-quality detection: spectral analysis of what the tap hears.
    @Published private(set) var detectQuality = true
    @Published private(set) var autoRate = true
    /// Verdict after hysteresis — what the UI shows. nil while unknown.
    @Published private(set) var qualityVerdict: QualityAnalyzer.Verdict?
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
    @Published private(set) var exposureDays: [DayExposure] = []
    /// Smoothed L/R correlation of what's playing: ~1 means mono content,
    /// which width and crossfeed cannot widen — the UI says so.
    @Published private(set) var sourceCorrelation: Double?

    static let silenceFloorDb: Double = -55
    static let loudThresholdDb: Double = -12

    private var stageByDevice: [String: StageSettings] = [:]
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
        if let saved = StageStateFile.load() {
            stageByDevice = saved.stageByDevice.mapValues { $0.clamped() }
            levelTracking = saved.levelTracking
            detectQuality = saved.detectQuality ?? true
            autoRate = saved.autoRate ?? true
            if let rate = saved.manualRateHz, AudioOutputs.isPlausibleRate(rate) {
                manualRateHz = rate
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
        }
    }

    func start() {
        guard !started else { return }
        started = true
        watcher.onChange = { [weak self] in self?.outputsChanged() }
        // The output's sample rate changed under a running engine: every
        // coefficient is designed for the old rate, so restart on fresh
        // device info. The refresh re-enumerates and lands in
        // outputsChanged → reconcile, which brings the engine back up.
        engine.onDeviceConfigurationChange = { [weak self] in
            guard let self, self.engine.isRunning else { return }
            self.engine.stop()
            self.watcher.refreshNow()
        }
        watcher.start()
        outputsChanged()
        startMetering()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.watcher.refreshNow()
        }
    }

    // MARK: - Edits

    func setStage(_ settings: StageSettings) {
        stage = settings.clamped()
        if let uid = outputUID { stageByDevice[uid] = stage }
        engine.processor.applyStage(stage)
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
        if qualityVerdict != nil { qualityVerdict = nil }
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

    private var desiredMode: StageEngine.Mode? {
        if stage.enabled { return .insert }
        if levelTracking || detectQuality { return .monitor }
        return nil
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
    private func reconcile() {
        let device = watcher.defaultOutput
        let desired = desiredMode

        if engine.isRunning {
            // Restart on any drift: mode changes need a different tap, and a
            // device swap needs a new aggregate. Stopping first is also the
            // recovery path when the output vanished under us.
            let deviceChanged = engine.runningDeviceUID != device?.uid
            if desired == nil || deviceChanged || engine.mode != desired {
                engine.stop()
            }
        }

        if !engine.isRunning, let desired, let device {
            engine.processor.applyStage(stage)
            engine.start(output: device, mode: desired)
        }
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
                stageByDevice[uid] = stage
                scheduleSave()
            } else {
                let deviceStage = stageByDevice[uid] ?? StageSettings()
                if !deviceStage.audiblyEquals(stage) || deviceStage.enabled != stage.enabled {
                    stage = deviceStage
                    engine.processor.applyStage(stage)
                }
            }
        }
        lastOutputUID = uid

        // A disconnect-reconnect can settle on the same default output while
        // still having killed our aggregate's sub-device; the running check
        // in reconcile() only catches UID drift. Restart whenever the device
        // identity behind our UID changed.
        if engine.isRunning, let running = engine.runningDeviceUID,
           !watcher.devices.contains(where: { $0.uid == running }) {
            engine.stop()
        }
        reconcile()
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
                    verdict: QualityAnalyzer.Verdict? = nil) {
        persistenceDisabled = true
        self.stage = stage
        exposureDays = exposure
        currentLevelDb = currentDb
        sourceCorrelation = correlation
        self.levelTracking = levelTracking
        qualityVerdict = verdict
    }
    #else
    private let persistenceDisabled = false
    #endif

    func saveNow() {
        guard !persistenceDisabled else { return }
        StageStateFile.save(PersistedStageState(
            stageByDevice: stageByDevice,
            exposure: exposureDays,
            levelTracking: levelTracking,
            detectQuality: detectQuality,
            autoRate: autoRate,
            manualRateHz: manualRateHz))
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

    private func meterTick() {
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
                "running=\(engine.isRunning) status=\"\(engine.status)\" "
                + "render: channels=\(d.channels) stage=\(d.stageRan ? "on" : "off") "
                + "(settings enabled=\(stage.enabled) width=\(Int(stage.width)) room=\(stage.room)) "
                + "quality=\(qualityVerdict.map(String.init(describing:)) ?? "nil") \(analyzer.lastDebug)")
            if engine.isRunning || content != lastDiagContent {
                let repeats = diagSuppressed
                diagSuppressed = 0
                lastDiagContent = content
                let suffix = repeats > 0
                    ? " (+\(repeats) identical ticks suppressed)" : ""
                let line = Self.diagFormatter.string(from: Date()) + " "
                    + content + suffix + "\n"
                let url = StageStateFile.directory.appendingPathComponent("diag.txt")
                // Append, keep the tail: the history between two snapshots is
                // exactly what a "worked then, broken now" hunt needs.
                // Serial queue: two overlapping read-modify-writes on the
                // global pool would interleave and drop lines.
                Self.diagQueue.async {
                    let existing = Self.readDiagTail(url)
                    let kept = existing.split(separator: "\n").suffix(200)
                        .joined(separator: "\n")
                    try? (kept + (kept.isEmpty ? "" : "\n") + line)
                        .write(to: url, atomically: true, encoding: .utf8)
                    // Device names are personal data; same posture as the
                    // packet log.
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
            } else {
                diagSuppressed += 1
            }
        }

        guard engine.isRunning else {
            if currentLevelDb != nil { currentLevelDb = nil }
            if sourceCorrelation != nil { sourceCorrelation = nil }
            correlationSmoothed = nil
            clearVerdict()
            qualityRate = nil
            return
        }
        if let corr = engine.processor.drainSourceCorrelation() {
            // Light smoothing so a quiet moment doesn't flicker the notice.
            let smoothed = 0.7 * (correlationSmoothed ?? corr) + 0.3 * corr
            correlationSmoothed = smoothed
            if sourceCorrelation == nil || abs(smoothed - (sourceCorrelation ?? 0)) > 0.001 {
                sourceCorrelation = smoothed
            }
        }

        qualityTick()

        let (sumSquares, frames) = engine.processor.drainMeter()
        guard frames > 0 else {
            if currentLevelDb != nil { currentLevelDb = nil }
            return
        }
        let power = sumSquares / Double(frames)
        guard power.isFinite else { return }
        let db = power > 0 ? 10 * log10(power) : -120
        let level = max(db, -80)
        if currentLevelDb != level { currentLevelDb = level }

        let updated = Self.exposureAfterTick(exposureDays, db: db, power: power,
                                             tracking: levelTracking, today: Self.dayKey())
        guard updated != exposureDays else { return }
        exposureDays = updated

        // Once a second is too often for disk; every 30 audible seconds is
        // plenty, and the regular edit/quit paths save the rest.
        meterTicksSinceSave += 1
        if meterTicksSinceSave >= 30 {
            meterTicksSinceSave = 0
            scheduleSave()
        }
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
        guard !exposureDays.isEmpty else { return }
        exposureDays = []
        meterTicksSinceSave = 0
        saveWork?.cancel()
        saveNow()
    }

    private static let diagQueue = DispatchQueue(label: "stage.diag", qos: .utility)

    /// The diag file is ours, but a symlink could be planted at its path and
    /// `String(contentsOf:)` would follow it into an arbitrarily large file.
    /// Refuse symlinks and cap the read; oversized or unreadable starts fresh.
    private nonisolated static func readDiagTail(_ url: URL) -> String {
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
        if let cur = qualityVerdict, case .losslessLike = cur,
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

        let kindChanged = qualityVerdict?.kind != effective.kind
        if kindChanged {
            DebugLog.shared.log("stream quality verdict → \(effective) [\(analyzer.lastDebug)]")
        }
        let previousClass = qualityVerdict?.isLosslessClass
        qualityVerdict = effective
        verdictDeviceUID = engine.runningDeviceUID
        if effective.isLosslessClass != previousClass {
            verdictStableSince = effective.isLosslessClass != nil ? Date() : nil
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
            verdict: qualityVerdict,
            measuredOn: verdictDeviceUID,
            device: device,
            availableRates: AudioOutputs.availableNominalRates(device.id),
            manualRateHz: manualRateHz,
            autoRate: autoRate,
            stageEnabled: stage.enabled,
            secondsStable: verdictStableSince.map { now.timeIntervalSince($0) },
            secondsSinceLastSwitch: now.timeIntervalSince(lastAutoSwitch))
        else { return }

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
            qualityVerdict?.isLosslessClass == true ? "lossless-class" : "lossy",
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
                               secondsStable: Double?,
                               secondsSinceLastSwitch: Double) -> Double? {
        guard autoRate, !stageEnabled,
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
