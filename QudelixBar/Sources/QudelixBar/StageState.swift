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
    func setNominalRate(_ rate: Double, for device: AudioOutput) {
        AudioOutputs.setNominalRate(device.id, rate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.watcher.refreshNow()
        }
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

    // MARK: - Engine lifecycle

    private var desiredMode: StageEngine.Mode? {
        if stage.enabled { return .insert }
        if levelTracking { return .monitor }
        return nil
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
                    levelTracking: Bool = false) {
        persistenceDisabled = true
        self.stage = stage
        exposureDays = exposure
        currentLevelDb = currentDb
        sourceCorrelation = correlation
        self.levelTracking = levelTracking
    }
    #else
    private let persistenceDisabled = false
    #endif

    func saveNow() {
        guard !persistenceDisabled else { return }
        StageStateFile.save(PersistedStageState(
            stageByDevice: stageByDevice,
            exposure: exposureDays,
            levelTracking: levelTracking))
    }

    // MARK: - Metering

    /// One tick a second while the app runs; near-free when the engine is
    /// idle (the deduplicated heartbeat writes at most once per state change).
    private func startMetering() {
        guard meterTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.meterTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private var diagTicks = 0
    private var lastDiagContent = ""
    private static let diagFormatter = ISO8601DateFormatter()

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
                + "(settings enabled=\(stage.enabled) width=\(Int(stage.width)) room=\(stage.room))")
            if engine.isRunning || content != lastDiagContent {
                lastDiagContent = content
                let line = Self.diagFormatter.string(from: Date()) + " " + content + "\n"
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
            }
        }

        guard engine.isRunning else {
            if currentLevelDb != nil { currentLevelDb = nil }
            if sourceCorrelation != nil { sourceCorrelation = nil }
            return
        }
        if let corr = engine.processor.drainSourceCorrelation() {
            // Light smoothing so a quiet moment doesn't flicker the notice.
            sourceCorrelation = 0.7 * (sourceCorrelation ?? corr) + 0.3 * corr
        }

        let (sumSquares, frames) = engine.processor.drainMeter()
        guard frames > 0 else {
            currentLevelDb = nil
            return
        }
        let power = sumSquares / Double(frames)
        let db = power > 0 ? 10 * log10(power) : -120
        currentLevelDb = max(db, -80)

        // Silence isn't listening; don't count it.
        guard db > Self.silenceFloorDb else { return }
        let key = Self.dayKey()
        // Find, don't assume last: a timezone hop or clock rollback can make
        // "today" a key that already exists earlier in the array, and a
        // duplicate would split the day and break ForEach identity.
        var idx = exposureDays.firstIndex { $0.day == key }
        if idx == nil {
            exposureDays.append(DayExposure(day: key, audibleSeconds: 0,
                                            loudSeconds: 0, energySum: 0))
            if exposureDays.count > 14 {
                exposureDays.removeFirst(exposureDays.count - 14)
            }
            idx = exposureDays.count - 1
        }
        guard let i = idx else { return }
        exposureDays[i].audibleSeconds += 1
        exposureDays[i].energySum += power
        if db > Self.loudThresholdDb { exposureDays[i].loudSeconds += 1 }

        // Once a second is too often for disk; every 30 audible seconds is
        // plenty, and the regular edit/quit paths save the rest.
        meterTicksSinceSave += 1
        if meterTicksSinceSave >= 30 {
            meterTicksSinceSave = 0
            scheduleSave()
        }
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
