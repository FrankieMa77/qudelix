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
            exposureDays = saved.exposure.map { day in
                // The file is user-writable: clamp what comes off it so a
                // hand-edited value can't trap Int() in the Level pane.
                DayExposure(day: String(day.day.prefix(10)),
                            audibleSeconds: min(max(day.audibleSeconds, 0), 172_800),
                            loudSeconds: min(max(day.loudSeconds, 0), 172_800),
                            energySum: min(max(day.energySum, 0), 1e12))
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        watcher.onChange = { [weak self] in self?.outputsChanged() }
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

    /// The default output changed, or the device list did. The stage follows
    /// the default output, so per-device settings swap with it.
    private func outputsChanged() {
        let uid = outputUID
        if let uid {
            let deviceStage = stageByDevice[uid] ?? StageSettings()
            if !deviceStage.audiblyEquals(stage) || deviceStage.enabled != stage.enabled {
                stage = deviceStage
                engine.processor.applyStage(stage)
            }
        }

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
            let content = "running=\(engine.isRunning) status=\"\(engine.status)\" "
                + "render: channels=\(d.channels) stage=\(d.stageRan ? "on" : "off") "
                + "(settings enabled=\(stage.enabled) width=\(Int(stage.width)) room=\(stage.room))"
            if engine.isRunning || content != lastDiagContent {
                lastDiagContent = content
                let line = Self.diagFormatter.string(from: Date()) + " " + content + "\n"
                let url = StageStateFile.directory.appendingPathComponent("diag.txt")
                // Append, keep the tail: the history between two snapshots is
                // exactly what a "worked then, broken now" hunt needs.
                DispatchQueue.global(qos: .utility).async {
                    let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    let kept = existing.split(separator: "\n").suffix(200)
                        .joined(separator: "\n")
                    try? (kept + (kept.isEmpty ? "" : "\n") + line)
                        .write(to: url, atomically: true, encoding: .utf8)
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

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }
}
