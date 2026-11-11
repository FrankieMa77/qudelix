import Foundation

package enum StreamQualityKind: Equatable {
    case tooQuiet
    case noTreble
    case lossy
    case lossyHigh
    case losslessLike
    case hiRes
    case natural
}

package struct StreamQuality: Equatable {
    package var kind: StreamQualityKind
    package var cutoffKHz: Double?
    package var isLosslessClass: Bool?

    init(_ verdict: QualityAnalyzer.Verdict) {
        isLosslessClass = verdict.isLosslessClass
        switch verdict {
        case .tooQuiet:
            kind = .tooQuiet
            cutoffKHz = nil
        case .noTreble:
            kind = .noTreble
            cutoffKHz = nil
        case .lossy(let k):
            kind = .lossy
            cutoffKHz = k
        case .lossyHigh(let k):
            kind = .lossyHigh
            cutoffKHz = k
        case .losslessLike(let k):
            kind = .losslessLike
            cutoffKHz = k
        case .hiRes(let k):
            kind = .hiRes
            cutoffKHz = k
        case .natural(let k):
            kind = .natural
            cutoffKHz = k
        }
    }
}

package struct LevelModelState: Equatable {
    package var levelTracking = false
    package var detectQuality = true
    package var autoRate = true
    package var currentLevelDb: Double?
    package var exposureDays: [DayExposure] = []
    package var earLevel: EarLevelEstimate = .unavailable
    package var earLevelAverageDb: Double?
    package var earCalibrationDb = EarLevel.defaultCalibrationDb
    package var earAnchor: EarVolumeAnchor?
    package var quality: StreamQuality?
    package var balance: BalanceFeatures?
    package var autoSetRate: Double?
    package var manualRate: Double?
    package var foreignForceRate: Int?

    package init() {}

    package var qualityMasterOn: Bool { detectQuality && autoRate }

    package var earLevelDb: Double? {
        if case .estimated(let db) = earLevel { return db }
        return nil
    }
}

struct LevelSeed {
    var levelTracking = false
    var detectQuality = true
    var autoRate = true
    var manualRateHz: Double?
    var earCalibrationByDevice: [String: Double] = [:]
    var exposure: [DayExposure] = []
}

struct LevelTick {
    var running: Bool
    var rate: Double?
    var sinkName: String?
    var muted: Bool
    var stageEnabled: Bool
    var callActive: Bool
    var callHold: Bool
}

struct ForceRateMarker {
    static let cap = 256

    let url: URL?

    func load() -> Int? {
        guard let url, let data = SafeFile.read(url, cap: Self.cap),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.rate > 0 else { return nil }
        return saved.rate
    }

    @discardableResult
    func save(_ rate: Int) -> Bool {
        guard let url else { return true }
        guard let data = try? JSONEncoder().encode(Saved(rate: rate)) else { return false }
        return SafeFile.writeAtomic(data, to: url)
    }

    func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private struct Saved: Codable {
        var rate: Int
    }
}

@MainActor
package final class LevelModel {
    package static let maxCalibratedDevices = 64
    package static let autoRateExplanation = "Auto-match changes the sample rate of the whole audio "
        + "graph, so every app is affected while it is active. It only applies to the 5K over USB while "
        + "Stage is off and no call is in progress, and it is released as soon as any of that stops, "
        + "when you turn it off and when the app quits."
    package static let defaultAvailableRates: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]
    package static let forceDeadline: TimeInterval = 5
    package static func foreignRateNotice(_ rate: Int) -> String {
        String(format: "Another program has fixed the audio graph at %g kHz; Auto-match waits.",
               Double(rate) / 1000)
    }
    private static let balanceAnchorCoefficient = 1 - exp(-3.0 / 30)

    package private(set) var state = LevelModelState()
    private var preview: LevelModelState?
    package weak var reporter: AudioDeviceReporting?

    var automationTick: ((EqAutomation.Context) -> Void)?
    var onModeInputsChanged: (() -> Void)?
    var onSaveNeeded: (() -> Void)?
    var onSaveNow: (() -> Void)?
    var onStatusChange: (() -> Void)?

    private let backend: LinuxAudioBackend
    private let routing: OutputRouting
    private let clock: AppClock
    private let analyzer: QualityAnalyzer
    private let availableRates: [Double]
    private let marker: ForceRateMarker
    private var observers: [Int: (LevelModelState) -> Void] = [:]
    private var nextObserverID = 0
    private var notified: LevelModelState?

    private var shortTerm = ShortTermLoudness()
    private var earAverage = AveragedLoudness()
    private var earCalibrationByDevice: [String: Double]
    private var exposureLive: [DayExposure]
    private var qualityVerdictLive: QualityAnalyzer.Verdict?
    private var balanceAnchor: BalanceFeatures?
    private var balanceLive: BalanceFeatures?
    private var freshBalanceReading: BalanceFeatures?
    private var rawVerdict: QualityAnalyzer.Verdict?
    private var rawVerdictStreak = 0
    private var verdictKey: String?
    private var verdictStableSince: Date?
    private var lastAutoSwitch = Date.distantPast
    private var qualityWindowsFed = 0
    private var qualityRate: Double?
    private var qualityKey: String?
    private var meterTicksSinceSave = 0
    private var forcedTarget: Int?
    private var forceRequestedAt: Date?
    private var forceConfirmed = false

    init(backend: LinuxAudioBackend,
         routing: OutputRouting,
         clock: AppClock,
         seed: LevelSeed = LevelSeed(),
         kernel: SpectrumKernel? = nil,
         availableRates: [Double] = LevelModel.defaultAvailableRates,
         markerURL: URL? = nil) {
        self.marker = ForceRateMarker(url: markerURL)
        self.backend = backend
        self.routing = routing
        self.clock = clock
        self.analyzer = kernel.map { QualityAnalyzer(kernel: $0) } ?? QualityAnalyzer()
        self.availableRates = availableRates
        earCalibrationByDevice = Dictionary(uniqueKeysWithValues:
            seed.earCalibrationByDevice.sorted { $0.key < $1.key }
                .prefix(Self.maxCalibratedDevices)
                .map { ($0.key, EarLevel.clampedCalibration($0.value)) })
        var seenDays = Set<String>()
        exposureLive = Array(seed.exposure.map { day in
            DayExposure(day: String(day.day.prefix(10)),
                        audibleSeconds: min(max(day.audibleSeconds, 0), 172_800),
                        loudSeconds: min(max(day.loudSeconds, 0), 172_800),
                        energySum: min(max(day.energySum, 0), 1e12))
        }
        .filter { seenDays.insert($0.day).inserted }
        .suffix(14))
        state.levelTracking = seed.levelTracking
        state.detectQuality = seed.detectQuality
        state.autoRate = seed.autoRate
        state.manualRate = StagePolicy.acceptableManualRate(seed.manualRateHz)
        state.exposureDays = exposureLive
    }

    @discardableResult
    package func addObserver(_ observer: @escaping (LevelModelState) -> Void) -> Int {
        nextObserverID += 1
        observers[nextObserverID] = observer
        observer(preview ?? state)
        return nextObserverID
    }

    package func showPreview(_ next: LevelModelState) {
        preview = next
        for observer in observers.values { observer(next) }
    }

    package func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    package func publish() {
        guard preview == nil, state != notified else { return }
        notified = state
        for observer in observers.values { observer(state) }
    }

    package var forcedRate: Int? { forcedTarget }

    package var calibrationCount: Int { earCalibrationByDevice.count }

    var persisted: LevelSeed {
        LevelSeed(levelTracking: state.levelTracking,
                  detectQuality: state.detectQuality,
                  autoRate: state.autoRate,
                  manualRateHz: state.manualRate,
                  earCalibrationByDevice: earCalibrationByDevice,
                  exposure: exposureLive)
    }

    package func setLevelTracking(_ on: Bool) {
        state.levelTracking = on
        onModeInputsChanged?()
        onSaveNeeded?()
        publish()
    }

    package func setDetectQuality(_ on: Bool) {
        state.detectQuality = on
        if !on {
            clearVerdict()
            qualityRate = nil
            releaseForce()
        }
        onModeInputsChanged?()
        onSaveNeeded?()
        publish()
    }

    package func setAutoRate(_ on: Bool) {
        state.autoRate = on
        if !on { releaseForce() }
        onSaveNeeded?()
        publish()
    }

    package func setQualityMaster(_ on: Bool) {
        if on {
            setDetectQuality(true)
            setAutoRate(true)
        } else {
            setAutoRate(false)
            setDetectQuality(false)
            state.autoSetRate = nil
            publish()
        }
    }

    package func setEarCalibration(_ db: Double, editedFor key: String?) {
        guard key == routing.realOutput?.name else {
            DebugLog.shared.log("ear calibration edit dropped: output device changed mid-edit")
            return
        }
        let clamped = EarLevel.clampedCalibration(db)
        guard clamped != state.earCalibrationDb else { return }
        state.earCalibrationDb = clamped
        if let key {
            if earCalibrationByDevice[key] == nil,
               earCalibrationByDevice.count >= Self.maxCalibratedDevices {
                earCalibrationByDevice.removeValue(forKey: earCalibrationByDevice.keys.sorted()[0])
            }
            earCalibrationByDevice[key] = clamped
        }
        onSaveNeeded?()
        publish()
    }

    func adoptEarCalibration(for key: String?) {
        let next = EarLevel.clampedCalibration(
            key.flatMap { earCalibrationByDevice[$0] } ?? EarLevel.defaultCalibrationDb)
        if state.earCalibrationDb != next { state.earCalibrationDb = next }
        clearEarLevel()
    }

    private func clearEarLevel() {
        shortTerm.reset()
        earAverage.reset()
        state.earLevel = .unavailable
        state.earLevelAverageDb = nil
        state.earAnchor = nil
    }

    package func clearExposureHistory() {
        guard !exposureLive.isEmpty else { return }
        exposureLive = []
        state.exposureDays = []
        meterTicksSinceSave = 0
        onSaveNow?()
        publish()
    }

    func clearVerdict() {
        let had = qualityVerdictLive?.isLosslessClass
        qualityVerdictLive = nil
        state.quality = nil
        if had != nil { onStatusChange?() }
        verdictKey = nil
        rawVerdict = nil
        rawVerdictStreak = 0
        verdictStableSince = nil
        clearBalance()
    }

    private func clearBalance() {
        balanceAnchor = nil
        balanceLive = nil
        freshBalanceReading = nil
        state.balance = nil
        analyzer.reset()
        qualityWindowsFed = 0
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
        state.balance = balanceLive
    }

    func automationStep(_ context: LevelTick) {
        let reading = freshBalanceReading
        freshBalanceReading = nil
        let key = context.running ? context.sinkName : nil
        let output = routing.realOutput
        let onQudelix = key != nil && key == output?.name && output?.isQudelix5K == true
        automationTick?(EqAutomation.Context(
            reading: reading, verdict: qualityVerdictLive,
            detecting: state.detectQuality && context.running,
            muted: context.muted,
            onCall: context.callActive || context.callHold,
            deviceUID: key, onQudelixOutput: onQudelix, dt: 1))
    }

    func idleTick(_ context: LevelTick) {
        state.currentLevelDb = nil
        clearEarLevel()
        clearVerdict()
        qualityRate = nil
        automationStep(context)
    }

    func qualityTick(processor: StageProcessor, context: LevelTick) {
        guard state.detectQuality, context.running, !processor.isMutedNow else { return }
        let rate = context.rate
        if rate != qualityRate {
            if qualityRate != nil, rate != state.autoSetRate { clearVerdict() }
            qualityRate = rate
            analyzer.reset()
            qualityWindowsFed = 0
            rawVerdict = nil
            rawVerdictStreak = 0
        }
        if context.sinkName != qualityKey {
            qualityKey = context.sinkName
            analyzer.reset()
            qualityWindowsFed = 0
            clearVerdict()
        }
        let samples = processor.drainSpectrumSamples(QualityAnalyzer.fftSize)
        guard samples.count >= QualityAnalyzer.fftSize else { return }
        analyzer.feed(samples)
        qualityWindowsFed += 1
        guard qualityWindowsFed >= 3 else { return }
        qualityWindowsFed = 0

        if let rate { updateBalance(analyzer.balance(sampleRate: rate)) }
        guard let rate, let raw = analyzer.classify(sampleRate: rate) else { return }

        var effective = raw
        if let current = qualityVerdictLive, case .losslessLike = current,
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
        state.quality = StreamQuality(effective)
        verdictKey = context.sinkName
        if effective.isLosslessClass != previousClass {
            verdictStableSince = effective.isLosslessClass != nil ? clock.now() : nil
            onStatusChange?()
        }
        autoSwitchIfDue(context)
    }

    private func autoSwitchIfDue(_ context: LevelTick) {
        guard state.autoRate, !context.stageEnabled, !context.callActive,
              let device = routing.realOutput, routing.outputIsQudelixUsb else { return }
        guard forcedTarget != nil || backend.forceRate == 0 else { return }

        let now = clock.now()
        let currentRate = backend.forceRate != 0 ? Double(backend.forceRate) : (context.rate ?? 48000)
        guard let target = StagePolicy.autoRateTarget(
            verdict: qualityVerdictLive,
            measuredOn: verdictKey,
            device: AutoRateDevice(uid: device.name, isBluetooth: false, rate: currentRate),
            availableRates: availableRates,
            manualRateHz: state.manualRate,
            autoRate: state.autoRate,
            stageEnabled: context.stageEnabled,
            callActive: context.callActive,
            secondsStable: verdictStableSince.map { now.timeIntervalSince($0) },
            secondsSinceLastSwitch: now.timeIntervalSince(lastAutoSwitch))
        else { return }

        if state.manualRate == nil, let baseline = StagePolicy.acceptableManualRate(currentRate) {
            state.manualRate = baseline
            onSaveNeeded?()
        }

        lastAutoSwitch = now
        DebugLog.shared.log(String(format:
            "stream quality %@ — forcing the graph rate to %g kHz",
            qualityVerdictLive?.isLosslessClass == true ? "lossless-class" : "lossy",
            target / 1000))
        guard marker.save(Int(target)) else {
            DebugLog.shared.log("could not record the graph rate change; not applying it")
            return
        }
        if backend.setForceRate(Int(target)) {
            forcedTarget = Int(target)
            forceRequestedAt = now
            forceConfirmed = false
            state.autoSetRate = target
        }
    }

    func recoverForce() {
        guard let recorded = marker.load() else { return }
        if backend.forceRate == recorded {
            guard backend.setForceRate(0) else { return }
            DebugLog.shared.log("cleared a graph rate left over from an earlier run")
        }
        marker.clear()
    }

    func backendLost() {
        guard forcedTarget != nil else { return }
        forgetForce()
    }

    private func updateForeignRate() {
        let rate = backend.forceRate
        let foreign = rate != 0 && forcedTarget == nil ? rate : nil
        if state.foreignForceRate != foreign { state.foreignForceRate = foreign }
    }

    func housekeeping(_ context: LevelTick) {
        updateForeignRate()
        guard let target = forcedTarget else { return }
        let now = clock.now()
        if !forceConfirmed {
            if backend.forceRate == target {
                forceConfirmed = true
            } else if let requested = forceRequestedAt,
                      now.timeIntervalSince(requested) > Self.forceDeadline {
                DebugLog.shared.log("graph rate change was not applied in time; dropped")
                forgetForce()
                return
            }
        } else if backend.forceRate != target {
            DebugLog.shared.log("graph rate was changed by someone else; left alone")
            marker.clear()
            forgetForce()
            return
        }
        let allowed = state.autoRate && state.detectQuality && !context.stageEnabled
            && !context.callActive && routing.outputIsQudelixUsb
        if !allowed { releaseForce() }
    }

    private func forgetForce() {
        forcedTarget = nil
        forceRequestedAt = nil
        forceConfirmed = false
        state.autoSetRate = nil
    }

    package func releaseForce() {
        guard forcedTarget != nil else {
            state.autoSetRate = nil
            return
        }
        if !forceConfirmed || backend.forceRate == forcedTarget {
            if backend.setForceRate(0) { marker.clear() }
        } else {
            marker.clear()
        }
        forgetForce()
    }

    package func shutdown() {
        releaseForce()
        publish()
    }

    func volumeAnchor() -> EarVolumeAnchor? {
        let output = routing.realOutput
        let onQudelix = output?.isQudelix5K == true
        guard let anchor = StagePolicy.volumeAnchor(
            playingToQudelix: onQudelix,
            qudelixVolumeDb: onQudelix ? reporter?.reportedVolumeDb : nil,
            systemVolumeDb: output.flatMap { routing.sinkVolumeDb(named: $0.name) })
        else { return nil }
        guard routing.isStageDefault else { return anchor }
        guard let stageDb = routing.stageVolumeDb() else { return nil }
        let db = anchor.db + stageDb
        guard EarLevel.plausibleVolumeDb.contains(db) else { return nil }
        switch anchor {
        case .qudelix: return .qudelix(db)
        case .system: return .system(db)
        }
    }

    func updateEarLevel(processor: StageProcessor) {
        let (sumSquares, frames) = processor.drainLoudnessMeter()
        shortTerm.add(sumSquares: sumSquares, frames: frames)

        let anchor = volumeAnchor()
        state.earAnchor = anchor

        let calibration = state.earCalibrationDb
        let next = EarLevel.estimate(shortTermLUFS: shortTerm.lufs,
                                     volumeDb: anchor?.db,
                                     calibrationDb: calibration)
        state.earLevel = next

        if case .estimated = next, let lufs = shortTerm.lufs { earAverage.add(lufs) }
        state.earLevelAverageDb = earAverage.lufs.flatMap {
            if case .estimated(let db) = EarLevel.estimate(
                shortTermLUFS: $0, volumeDb: anchor?.db,
                calibrationDb: calibration) { return db }
            return nil
        }
    }

    func consumeMeter(processor: StageProcessor) {
        let (sumSquares, frames) = processor.drainMeter()
        guard frames > 0 else {
            state.currentLevelDb = nil
            return
        }
        let power = sumSquares / Double(frames)
        guard power.isFinite else { return }
        let db = power > 0 ? 10 * log10(power) : -120
        let level = max(db, -80)
        if state.currentLevelDb != level { state.currentLevelDb = level }

        let updated = StagePolicy.exposureAfterTick(exposureLive, db: db, power: power,
                                                    tracking: state.levelTracking,
                                                    today: Self.dayKey(clock.now()))
        guard updated != exposureLive else { return }
        exposureLive = updated
        state.exposureDays = updated

        meterTicksSinceSave += 1
        if meterTicksSinceSave >= 30 {
            meterTicksSinceSave = 0
            onSaveNeeded?()
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    package static func dayKey(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }
}
