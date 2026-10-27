import Foundation

struct PersistedAutofit: Codable, Equatable {
    var autoTrimOn: Bool?
    var autoTrimMode: TrimMode?
    var autoTrimStrength: Double?
    var balanceBaseline: BalanceBaseline?
    var showReference: Bool?
    var referenceSource: ReferenceSource?
    var autoFit: Bool?
    var referenceByGroup: [String: ReferenceCurve]?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case autoTrimOn, autoTrimMode, autoTrimStrength, balanceBaseline, showReference,
             referenceSource, autoFit, referenceByGroup
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoTrimOn = try? c.decodeIfPresent(Bool.self, forKey: .autoTrimOn)
        autoTrimMode = try? c.decodeIfPresent(TrimMode.self, forKey: .autoTrimMode)
        autoTrimStrength = try? c.decodeIfPresent(Double.self, forKey: .autoTrimStrength)
        balanceBaseline = try? c.decodeIfPresent(BalanceBaseline.self, forKey: .balanceBaseline)
        showReference = try? c.decodeIfPresent(Bool.self, forKey: .showReference)
        referenceSource = try? c.decodeIfPresent(ReferenceSource.self, forKey: .referenceSource)
        autoFit = try? c.decodeIfPresent(Bool.self, forKey: .autoFit)
        let lossy = try? c.decodeIfPresent([String: ReferenceCurve.Lossy].self,
                                           forKey: .referenceByGroup)
        referenceByGroup = lossy?.compactMapValues(\.value)
    }
}

enum AutofitFile {
    static var url: URL {
        StageStateFile.directory.appendingPathComponent("autofit.json")
    }

    static let maxBytes = 500_000

    static func load(from url: URL = url) -> PersistedAutofit? {
        guard let data = SafeFile.read(url, cap: maxBytes) else { return nil }
        if let state = try? JSONDecoder().decode(PersistedAutofit.self, from: data) {
            return state
        }
        let parked = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".recovered")
        SafeFile.writeAtomic(data, to: parked)
        DebugLog.shared.log("autofit settings could not be read; a copy was parked")
        return nil
    }

    @discardableResult
    static func save(_ state: PersistedAutofit, to url: URL = url) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return false }
        return SafeFile.writeAtomic(data, to: url)
    }
}

@MainActor
final class EqAutomation: ObservableObject {
    struct Context {
        var reading: BalanceFeatures?
        var verdict: QualityAnalyzer.Verdict?
        var detecting = true
        var muted = false
        var onCall = false
        var deviceUID: String? = "device"
        var onQudelixOutput = true
        var dt = 1.0
    }

    private struct TargetKey: Equatable {
        var reference: [QxEqBandValue]
        var referencePreGain: Double
        var trim: TrimGains
    }

    private struct Written {
        var bands: [QxEqBandValue]
        var preGain: Double
        var at: Date
    }

    static let echoToleranceDb = 0.5
    static let echoWindow: TimeInterval = 3
    static let recentLimit = 6
    static let baselineSaveTicks = 60

    @Published private(set) var autoTrimOn = false
    @Published private(set) var autoTrimMode: TrimMode = .clarity
    @Published private(set) var autoTrimStrength = 0.5
    @Published private(set) var baseline = BalanceBaseline()
    @Published private(set) var showReference = true
    @Published private(set) var referenceSource: ReferenceSource = .auto
    @Published private(set) var autoFit = false
    @Published private(set) var references: [UInt8: ReferenceCurve] = [:]
    @Published private(set) var trim = TrimGains.zero
    @Published private(set) var advisory = TrimGains.zero
    @Published private(set) var following = false
    @Published private(set) var paused = false
    @Published private(set) var suspended = false
    @Published private(set) var waitingReason: String?
    @Published private(set) var deviationDb: Double?
    @Published private(set) var followedBands: [QxEqBandValue] = []
    @Published private(set) var followedPreGain = 0.0
    @Published private(set) var baseBands: [QxEqBandValue] = []
    @Published private(set) var basePreGain = 0.0

    var enableDetection: (() -> Void)?

    private let controller: QudelixController
    private let url: URL
    private var trimController = TrimController()
    private var base: [QxEqBandValue]?
    private var baseGain = 0.0
    private var lastWritten: Written?
    private var recent: [Written] = []
    private var hasWritten = false
    private var engagePending = true
    private var awaitingReadback = false
    private var health = ReferenceFollower.FollowHealth()
    private var previousGains: [Double]?
    private var lastKey: TargetKey?
    private var lastResult: ReferenceFollower.Result?
    private var settled = false
    private var lastDeviceUID: String?
    private var lastContext = Context()
    private var bandWrites = 0
    private var ticksSinceSave = 0
    private var baselineDirty = false
    private var saveWork: DispatchWorkItem?

    init(controller: QudelixController, url: URL = AutofitFile.url) {
        self.controller = controller
        self.url = url
        if let saved = AutofitFile.load(from: url) { adopt(saved) }
        wire()
    }

    private func wire() {
        controller.baseProvider = { [weak self] in self?.currentBase }
        controller.onReadback = { [weak self] bands, preGain in
            self?.handleReadback(bands, preGain)
        }
        controller.onBaseEvent = { [weak self] event in self?.handle(event) }
        controller.onFlashCommitted = { [weak self] in self?.flashCommitted() }
        controller.onSessionBegin = { [weak self] in self?.suspendForSession() }
        controller.onSessionEnd = { [weak self] in self?.resumeAfterSession() }
        controller.onReferenceLanded = { [weak self] curve, group in
            self?.recordReference(curve, for: group)
        }
    }

    private func adopt(_ saved: PersistedAutofit) {
        autoTrimOn = saved.autoTrimOn ?? false
        autoTrimMode = saved.autoTrimMode ?? .clarity
        autoTrimStrength = Self.clampedStrength(saved.autoTrimStrength ?? 0.5)
        showReference = saved.showReference ?? true
        referenceSource = saved.referenceSource ?? .auto
        autoFit = saved.autoFit ?? false
        let loaded = (saved.balanceBaseline ?? BalanceBaseline()).sanitized()
        baseline = loaded
        trimController.baseline = loaded
        var map: [UInt8: ReferenceCurve] = [:]
        for (key, curve) in saved.referenceByGroup ?? [:] {
            guard let raw = UInt8(key), QxEqGroup(rawValue: raw) != nil,
                  curve.bands.contains(where: { $0.filter != .bypass }) else { continue }
            map[raw] = curve.sanitized()
        }
        references = map
        syncTrimController()
    }

    nonisolated static func clampedStrength(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0.5
    }

    private func syncTrimController() {
        trimController.mode = autoTrimMode
        trimController.strength = autoTrimStrength
        trimController.enabled = autoTrimOn
    }

    var currentReference: ReferenceCurve? { references[controller.eqGroup.rawValue] }

    var effectiveSource: ReferenceSource {
        switch referenceSource {
        case .auto: return currentReference != nil ? .catalog : .listening
        case .catalog, .listening: return referenceSource
        }
    }

    var referenceActive: Bool {
        autoFit && effectiveSource == .catalog && currentReference != nil
    }

    var wantsFollow: Bool {
        (autoFit && currentReference != nil) || autoTrimOn
    }

    var sessionsActive: Bool { controller.byEarSessionActive }

    private var currentBase: (bands: [QxEqBandValue], preGain: Double)? {
        guard hasWritten, let base else { return nil }
        return (base, baseGain)
    }

    func setAutoTrim(on: Bool? = nil, mode: TrimMode? = nil, strength: Double? = nil) {
        var turnedOn = false
        if let on, on != autoTrimOn {
            autoTrimOn = on
            turnedOn = on
        }
        if let mode, mode != autoTrimMode { autoTrimMode = mode }
        if let strength {
            let clamped = Self.clampedStrength(strength)
            if clamped != autoTrimStrength { autoTrimStrength = clamped }
        }
        syncTrimController()
        if turnedOn {
            enableDetection?()
            reenable()
        }
        settleWants()
        schedulePersist()
    }

    func setAutoFit(_ on: Bool) {
        guard on != autoFit else { return }
        autoFit = on
        if on {
            enableTrimForListeningFollow()
            reenable()
        }
        settleWants()
        schedulePersist()
    }

    func setReferenceSource(_ source: ReferenceSource) {
        guard source != referenceSource else { return }
        referenceSource = source
        if autoFit {
            enableTrimForListeningFollow()
            reenable()
        }
        retarget()
        settleWants()
        schedulePersist()
    }

    func setShowReference(_ on: Bool) {
        guard on != showReference else { return }
        showReference = on
        schedulePersist()
    }

    func recordReference(_ curve: ReferenceCurve, for group: QxEqGroup) {
        let clean = curve.sanitized()
        guard clean.bands.contains(where: { $0.filter != .bypass }) else { return }
        references[group.rawValue] = clean
        if !showReference { showReference = true }
        if group == controller.eqGroup { retarget() }
        schedulePersist()
    }

    func clearReference(for group: QxEqGroup) {
        guard references[group.rawValue] != nil else { return }
        references[group.rawValue] = nil
        if group == controller.eqGroup { retarget() }
        settleWants()
        schedulePersist()
    }

    private func enableTrimForListeningFollow() {
        if effectiveSource == .listening, !autoTrimOn {
            autoTrimOn = true
            syncTrimController()
            enableDetection?()
        }
    }

    func reenable() {
        guard paused else { return }
        paused = false
        health = ReferenceFollower.FollowHealth()
        if controller.canWriteNow, base != nil {
            rebase(controller.bands, controller.preGain)
        }
        publishState()
    }

    private func retarget() {
        engagePending = true
        settled = false
        health = ReferenceFollower.FollowHealth()
    }

    private func settleWants() {
        if !wantsFollow {
            if base != nil { disengage() }
            paused = false
        }
        publishState()
    }

    func keep() {
        guard following, !paused, let base else { return }
        let followed = (bands: controller.bands, preGain: controller.preGain)
        let original = (bands: base, preGain: baseGain)
        let trimWasOn = autoTrimOn
        hasWritten = false
        lastWritten = nil
        autoFit = false
        if trimWasOn {
            trimController.gains = .zero
            autoTrimOn = false
            syncTrimController()
            trim = .zero
        }
        controller.keepFollowed(base: original, followed: followed, undoLabel: "Keep auto-fit")
        clearFollowState()
        publishState()
        schedulePersist()
    }

    func suspendForSession() {
        guard !suspended else { return }
        suspended = true
        if base != nil { writeBaseBack() }
        publishState()
    }

    func resumeAfterSession() {
        guard suspended else { return }
        suspended = false
        if base != nil, controller.canWriteNow {
            rebase(controller.bands, controller.preGain)
        }
        publishState()
    }

    private func writeBaseBack() {
        guard let base else { return }
        if hasWritten, controller.canWriteNow, !controller.eqSettling {
            controller.writeFollowed(bands: base, preGain: baseGain)
            controller.flushPendingEqSends()
        }
        hasWritten = false
        lastWritten = nil
        recent.removeAll()
    }

    private func disengage() {
        writeBaseBack()
        clearFollowState()
    }

    private func clearFollowState() {
        base = nil
        baseGain = 0
        lastWritten = nil
        recent.removeAll()
        hasWritten = false
        previousGains = nil
        lastKey = nil
        lastResult = nil
        settled = false
        engagePending = true
        awaitingReadback = false
        health = ReferenceFollower.FollowHealth()
        deviationDb = nil
        followedBands = []
        baseBands = []
    }

    private func rebase(_ bands: [QxEqBandValue], _ preGain: Double) {
        base = bands
        baseGain = preGain
        lastWritten = nil
        recent.removeAll()
        hasWritten = false
        previousGains = nil
        lastKey = nil
        lastResult = nil
        settled = false
        engagePending = true
        awaitingReadback = false
        health = ReferenceFollower.FollowHealth()
        if baseBands != bands { baseBands = bands }
        if basePreGain != preGain { basePreGain = preGain }
    }

    private func handle(_ event: QudelixController.EqBaseEvent) {
        switch event {
        case .reset, .group:
            clearFollowState()
            publishState()
        case .slotLoad:
            guard base != nil else { return }
            hasWritten = false
            lastWritten = nil
            recent.removeAll()
            awaitingReadback = true
        case .fit, .restore, .undoRedo:
            guard base != nil, !suspended else { return }
            rebase(controller.bands, controller.preGain)
            publishState()
        }
    }

    private func flashCommitted() {
        lastWritten = nil
        recent.removeAll()
        hasWritten = false
        engagePending = true
        settled = false
    }

    private func isEcho(_ bands: [QxEqBandValue], _ preGain: Double) -> Bool {
        let now = Date()
        var candidates: [Written] = []
        if let lastWritten { candidates.append(lastWritten) }
        candidates += recent.filter { now.timeIntervalSince($0.at) <= Self.echoWindow }
        return candidates.contains { written in
            ReferenceFollower.sameLayout(bands, written.bands)
                && zip(bands, written.bands).allSatisfy {
                    abs($0.gain - $1.gain) <= Self.echoToleranceDb
                }
                && abs(preGain - written.preGain) <= Self.echoToleranceDb
        }
    }

    private func handleReadback(_ bands: [QxEqBandValue], _ preGain: Double) {
        guard base != nil, !suspended else { return }
        if awaitingReadback || !hasWritten || lastWritten == nil {
            rebase(bands, preGain)
            publishState()
            return
        }
        if isEcho(bands, preGain) {
            reassert()
        } else {
            rebase(bands, preGain)
            publishState()
        }
    }

    private func reassert() {
        guard let last = lastWritten, blockReason() == nil else { return }
        bandWrites += controller.writeFollowed(bands: last.bands, preGain: last.preGain)
    }

    private func blockReason() -> String? {
        guard controller.canWriteNow else { return "Connect the 5K" }
        if controller.eqGroup == .speaker { return "Not available for the speaker EQ" }
        if controller.eqSettling { return "Waiting for the 5K's EQ mode" }
        if !controller.eqEnabled { return "Turn the EQ on to use it" }
        let hfp = controller.inputSource?.hasPrefix("HFP") ?? false
        if lastContext.onCall || controller.activeCall == true || hfp { return "Paused for the call" }
        if suspended || sessionsActive { return "Paused while a tuning session runs" }
        if !controller.eqReadBack || !controller.eqRestoreDecided { return "Reading the 5K's EQ" }
        return nil
    }

    func tick(_ ctx: Context) {
        lastContext = ctx
        stepTrim(ctx)
        followTick()
        ticksSinceSave += 1
        if baselineDirty, ticksSinceSave >= Self.baselineSaveTicks {
            persistNow()
        }
        publishState()
    }

    private func stepTrim(_ ctx: Context) {
        let changedDevice = ctx.deviceUID != lastDeviceUID
        lastDeviceUID = ctx.deviceUID
        let live = ctx.detecting && ctx.onQudelixOutput && !changedDevice
        if !live { trimController.reset() }
        let hfp = controller.inputSource?.hasPrefix("HFP") ?? false
        let call = ctx.onCall || controller.activeCall == true || hfp
        let frozen = ctx.muted || call || sessionsActive || suspended
        let before = trimController.baseline.readings
        let gains = trimController.step(reading: live ? ctx.reading : nil,
                                        air: AirClass(verdict: ctx.verdict),
                                        frozen: frozen, dt: ctx.dt)
        let rounded = gains.rounded()
        if rounded != trim { trim = rounded }
        let advised = trimController.advisory.rounded()
        if advised != advisory { advisory = advised }
        let current = trimController.baseline
        if current.readings != before { baselineDirty = true }
        if current.isLearned != baseline.isLearned || current.readings / 10 != baseline.readings / 10 {
            baseline = current
        }
    }

    private func followTick() {
        guard wantsFollow else {
            waitingReason = nil
            if base != nil { disengage() }
            paused = false
            return
        }
        if paused {
            waitingReason = nil
            return
        }
        if let reason = blockReason() {
            waitingReason = reason
            return
        }
        waitingReason = nil
        guard !awaitingReadback else { return }
        if base == nil { rebase(controller.bands, controller.preGain) }
        observeController()
        guard base != nil, !awaitingReadback else { return }
        followStep()
    }

    private func observeController() {
        guard hasWritten, let last = lastWritten else { return }
        let bands = controller.bands
        let pre = controller.preGain
        if ReferenceFollower.sameLayout(bands, last.bands),
           zip(bands, last.bands).allSatisfy({ abs($0.gain - $1.gain) <= Self.echoToleranceDb }),
           abs(pre - last.preGain) <= Self.echoToleranceDb {
            if !QudelixController.sameQuantized(bands, last.bands)
                || ReferenceFollower.quantized(pre) != ReferenceFollower.quantized(last.preGain) {
                reassert()
            }
        } else {
            rebase(bands, pre)
        }
    }

    private struct Goal {
        var bands: [QxEqBandValue]
        var preGain: Double
    }

    private func goal(base: [QxEqBandValue]) -> Goal {
        if referenceActive, let reference = currentReference {
            return Goal(bands: reference.bands, preGain: reference.preGain)
        }
        return Goal(bands: base, preGain: baseGain)
    }

    private func followStep() {
        guard let base else { return }
        let goal = goal(base: base)
        let trimArg: TrimGains? = autoTrimOn ? trim : nil
        let key = TargetKey(reference: goal.bands, referencePreGain: goal.preGain,
                            trim: trimArg ?? .zero)
        let targetChanged = key != lastKey
        let pinned = ReferenceFollower.pinnedSet(base: base)
        let target = ReferenceFollower.target(reference: goal.bands, trim: trimArg)

        if settled, !targetChanged, let previous = lastResult {
            if health.failing(deviationDb: previous.deviationDb, display: previous.bands,
                              target: target, pinned: pinned, targetChanged: false) {
                pause(deviation: previous.deviationDb)
            }
            return
        }

        let iterations = engagePending
            ? ReferenceFollower.startIterations : ReferenceFollower.iterationsPerTick
        let result = ReferenceFollower.solve(
            base: base, basePreGain: baseGain, reference: goal.bands,
            referencePreGain: goal.preGain, trim: trimArg, iterations: iterations,
            previousGains: previousGains)
        if health.failing(deviationDb: result.deviationDb, display: result.bands,
                          target: target, pinned: pinned, targetChanged: targetChanged) {
            pause(deviation: result.deviationDb)
            return
        }
        settled = result.gains == previousGains && !targetChanged
        previousGains = result.gains
        lastKey = key
        lastResult = result
        engagePending = false
        deviationDb = result.deviationDb
        write(result)
    }

    private func write(_ result: ReferenceFollower.Result) {
        let wrote = controller.writeFollowed(bands: result.bands, preGain: result.preGain)
        bandWrites += wrote
        hasWritten = true
        let held = Written(bands: controller.bands, preGain: controller.preGain, at: Date())
        if let previous = lastWritten {
            recent.append(previous)
            if recent.count > Self.recentLimit { recent.removeFirst() }
        }
        lastWritten = held
        if followedBands != held.bands { followedBands = held.bands }
        if followedPreGain != held.preGain { followedPreGain = held.preGain }
    }

    private func pause(deviation: Double) {
        paused = true
        writeBaseBack()
        deviationDb = nil
        followedBands = []
        previousGains = nil
        lastKey = nil
        lastResult = nil
        settled = false
        DebugLog.shared.log(String(format: "auto-fit paused: dev=%.1f", deviation))
    }

    private func publishState() {
        let active = base != nil && wantsFollow && !paused && !suspended
        if following != active { following = active }
        if !active, !followedBands.isEmpty { followedBands = [] }
        if base == nil, !baseBands.isEmpty { baseBands = [] }
    }

    func diagnostics() -> String {
        let g = trimController.gains
        let b = trimController.baseline
        let follow = paused ? "p" : (following && hasWritten ? "1" : "0")
        let src = (following || paused) ? (referenceActive ? "c" : "l") : "-"
        let dev = health.lastDeviationDb.map { String(format: "%.1f", $0) } ?? "-"
        let line = String(format: "trim=%+.1f,%+.1f,%+.1f,%+.1f base=%+.1f,%+.1f,%+.1f/%ld ",
                          g.bassDb, g.tiltDbPerOctave, g.presenceDb, g.airDb,
                          b.bassDb, b.tiltDbPerOctave, b.presenceDb, b.readings)
            + "sess=\(sessionsActive ? 1 : 0) follow=\(follow) src=\(src) dev=\(dev) w=\(bandWrites)"
        bandWrites = 0
        return line
    }

    private func snapshot() -> PersistedAutofit {
        var state = PersistedAutofit()
        state.autoTrimOn = autoTrimOn
        state.autoTrimMode = autoTrimMode
        state.autoTrimStrength = autoTrimStrength
        state.balanceBaseline = trimController.baseline
        state.showReference = showReference
        state.referenceSource = referenceSource
        state.autoFit = autoFit
        state.referenceByGroup = Dictionary(uniqueKeysWithValues: references.map {
            (String($0.key), $0.value)
        })
        return state
    }

    private func schedulePersist() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.persistNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func persistNow() {
        saveWork?.cancel()
        saveWork = nil
        ticksSinceSave = 0
        baselineDirty = false
        baseline = trimController.baseline
        AutofitFile.save(snapshot(), to: url)
    }

    #if DEBUG
    func previewSet(autoFit: Bool = false, autoTrimOn: Bool = false,
                    mode: TrimMode = .clarity, source: ReferenceSource = .auto,
                    references: [UInt8: ReferenceCurve] = [:], trim: TrimGains = .zero, advisory: TrimGains = .zero,
                    baseline: BalanceBaseline = BalanceBaseline(),
                    following: Bool = false, paused: Bool = false,
                    waitingReason: String? = nil, deviationDb: Double? = nil,
                    base: (bands: [QxEqBandValue], preGain: Double)? = nil) {
        self.autoFit = autoFit
        self.autoTrimOn = autoTrimOn
        autoTrimMode = mode
        referenceSource = source
        self.references = references
        self.trim = trim
        self.advisory = advisory
        self.baseline = baseline
        trimController.baseline = baseline
        self.following = following
        self.paused = paused
        self.waitingReason = waitingReason
        self.deviationDb = deviationDb
        syncTrimController()
        if let base {
            baseBands = base.bands
            basePreGain = base.preGain
            controller.baseProvider = { base }
        }
    }
    #endif
}
