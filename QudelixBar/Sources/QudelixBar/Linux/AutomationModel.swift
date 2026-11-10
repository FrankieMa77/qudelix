import Foundation

package enum AutomationTrimMode: String, CaseIterable, Equatable {
    case audiophile, clarity, resolution, presentation

    package var label: String { (TrimMode(rawValue: rawValue) ?? .clarity).label }

    var shared: TrimMode { TrimMode(rawValue: rawValue) ?? .clarity }
}

package enum AutomationSource: String, CaseIterable, Equatable {
    case auto, catalog, listening

    package var label: String { shared.label }

    package var title: String {
        switch self {
        case .auto: return "Auto \u{2014} the AutoEq fit when there is one, else listening"
        case .catalog: return "AutoEq \u{2014} the measurement-based correction"
        case .listening: return "Listening \u{2014} your EQ plus what Auto-trim measures"
        }
    }

    var shared: ReferenceSource { ReferenceSource(rawValue: rawValue) ?? .auto }
}

package struct AutomationTrim: Equatable {
    package var bassDb = 0.0
    package var tiltDbPerOctave = 0.0
    package var presenceDb = 0.0
    package var airDb = 0.0

    package init() {}

    init(_ gains: TrimGains) {
        bassDb = gains.bassDb
        tiltDbPerOctave = gains.tiltDbPerOctave
        presenceDb = gains.presenceDb
        airDb = gains.airDb
    }

    package var isZero: Bool {
        bassDb == 0 && tiltDbPerOctave == 0 && presenceDb == 0 && airDb == 0
    }
}

package struct AutomationLine: Equatable {
    package var bands: [EqBand]
    package var offsetDb: Double

    package func response(count: Int = 220) -> [Double] {
        EqCurveGeometry.response(bands: bands, count: count).map { $0 + offsetDb }
    }

    package init(bands: [EqBand], offsetDb: Double) {
        self.bands = bands
        self.offsetDb = offsetDb
    }

    init(_ line: EQLine) {
        bands = line.bands.map(EqBand.init)
        offsetDb = line.offsetDb
    }
}

package struct AutomationState: Equatable {
    package var autoTrimOn = false
    package var trimMode = AutomationTrimMode.clarity
    package var trimStrength = 0.5
    package var autoFit = false
    package var showReference = true
    package var source = AutomationSource.auto
    package var effectiveSource = AutomationSource.listening
    package var hasReference = false
    package var referenceActive = false
    package var referenceTexts: [String] = []
    package var trimTexts: [String] = []
    package var followNote: String?
    package var referenceLine: AutomationLine?
    package var trimLine: AutomationLine?
    package var following = false
    package var paused = false
    package var suspended = false
    package var waitingReason: String?
    package var deviationDb: Double?
    package var trim = AutomationTrim()
    package var advisory = AutomationTrim()
    package var baselineText = ""
    package var baselineLearned = false
    package var balanceText = ""
    package var detecting = true
    package var fitRequest: String?

    package init() {}

    package var canKeep: Bool { following && !paused }

    package var readOnly: Bool { following }

    package static let readOnlyHelp = AutomationReadout.readOnlyHelp

    package static let keepHelp = "Write the followed gains and pre-gain into your EQ and stop "
        + "following. It also turns Auto-trim off if it is on, since the bands now "
        + "carry the trim."

    package static let resumeHelp = "Try following again from your own EQ."

    package static let showHelp = "Draw the reference line on the graph."

    package static let referenceHelp = "Where the reference line comes from"

    package static let autoFitHelp = "The 5K's gains follow the reference line: only gains move, your band "
        + "layout and saved presets stay as they are. With the listening "
        + "reference this turns Auto-trim on. Untick to edit again; Keep "
        + "writes what it found into your EQ."

    package static let autoTrimHelp = "Slowly trims what's playing toward the balance you usually listen to, "
        + "at most a few dB, level-matched. It moves the 5K's bands a little at "
        + "a time and your saved presets stay untouched until you Keep. Turning "
        + "it on enables quality detection."

    package var isForced: Bool { autoFit || autoTrimOn || following || hasReference }

    package var summary: String {
        var parts: [String] = []
        if autoFit { parts.append("Auto-fit on") }
        if autoTrimOn { parts.append("Auto-trim " + trimMode.label.lowercased()) }
        if paused {
            parts.append("paused")
        } else if following {
            parts.append("following")
        }
        return parts.isEmpty ? "Off" : parts.joined(separator: " \u{00B7} ")
    }

    package var strengthEnabled: Bool { autoTrimOn && trimMode != .audiophile }
}

@MainActor
package final class AutomationModel {
    private let app: AppModel
    private let stage: StageModel?
    private let automation: EqAutomation
    private var observers: [Int: (AutomationState) -> Void] = [:]
    private var nextObserverID = 0
    private var cancellables = Set<AnyCancellable>()
    private var appObserver: Int?
    private var eqObserver: Int?
    private var levelObserver: Int?
    private var stopped = false
    package private(set) var state = AutomationState()

    package convenience init(app: AppModel, stage: StageModel?) {
        self.init(app: app, stage: stage, url: AutofitFile.url)
    }

    package init(app: AppModel, stage: StageModel?, url: URL) {
        self.app = app
        self.stage = stage
        automation = EqAutomation(controller: app.eqHost, url: url)
        automation.enableDetection = { [weak stage] in
            guard let stage, !stage.level.state.detectQuality else { return }
            stage.setDetectQuality(true)
        }
        if let stage {
            stage.level.automationTick = { [weak self] context in self?.tick(context) }
            stage.deviceEqCurve = { [weak app] in
                guard let app, app.eq.liveEnabled, app.state.connection.isConnected else { return nil }
                return app.eq.liveBands
            }
            levelObserver = stage.addObserver { [weak self] _ in self?.refresh() }
        }
        app.eqHost.onQuit = { [weak self] in self?.quit() }
        appObserver = app.addObserver { [weak self] _ in self?.refresh() }
        eqObserver = app.eq.addObserver { [weak self] _ in self?.refresh() }
        subscribe()
        state = computeState()
    }

    private func subscribe() {
        let refresh: () -> Void = { [weak self] in self?.refresh() }
        automation.$autoTrimOn.sink { _ in refresh() }.store(in: &cancellables)
        automation.$autoTrimMode.sink { _ in refresh() }.store(in: &cancellables)
        automation.$autoTrimStrength.sink { _ in refresh() }.store(in: &cancellables)
        automation.$baseline.sink { _ in refresh() }.store(in: &cancellables)
        automation.$showReference.sink { _ in refresh() }.store(in: &cancellables)
        automation.$referenceSource.sink { _ in refresh() }.store(in: &cancellables)
        automation.$autoFit.sink { _ in refresh() }.store(in: &cancellables)
        automation.$references.sink { _ in refresh() }.store(in: &cancellables)
        automation.$trim.sink { _ in refresh() }.store(in: &cancellables)
        automation.$advisory.sink { _ in refresh() }.store(in: &cancellables)
        automation.$paused.sink { _ in refresh() }.store(in: &cancellables)
        automation.$suspended.sink { _ in refresh() }.store(in: &cancellables)
        automation.$waitingReason.sink { _ in refresh() }.store(in: &cancellables)
        automation.$deviationDb.sink { _ in refresh() }.store(in: &cancellables)
        automation.$following.sink { [weak self] following in
            self?.app.eq.setFollowing(following)
            refresh()
        }.store(in: &cancellables)
    }

    @discardableResult
    package func addObserver(_ observer: @escaping (AutomationState) -> Void) -> Int {
        nextObserverID += 1
        observers[nextObserverID] = observer
        observer(state)
        return nextObserverID
    }

    package func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    private var fitRequest: String?

    var engine: EqAutomation { automation }

    private var preview: AutomationState?

    package func showPreview(_ preview: AutomationState) {
        self.preview = preview
        app.eq.setFollowing(preview.following)
        refresh()
    }

    private func computeState() -> AutomationState {
        if let preview { return preview }
        var next = AutomationState()
        next.autoTrimOn = automation.autoTrimOn
        next.trimMode = AutomationTrimMode(rawValue: automation.autoTrimMode.rawValue) ?? .clarity
        next.trimStrength = automation.autoTrimStrength
        next.autoFit = automation.autoFit
        next.showReference = automation.showReference
        next.source = AutomationSource(rawValue: automation.referenceSource.rawValue) ?? .auto
        next.effectiveSource = AutomationSource(rawValue: automation.effectiveSource.rawValue) ?? .listening
        next.hasReference = automation.currentReference != nil
        next.referenceActive = automation.referenceActive
        let detecting = stage?.level.state.detectQuality ?? true
        next.detecting = detecting
        next.referenceTexts = AutomationReadout.referenceTexts(
            source: automation.effectiveSource, reference: automation.currentReference,
            trim: automation.trim, autoTrimOn: automation.autoTrimOn,
            mode: automation.autoTrimMode)
        next.trimTexts = AutomationReadout.trimLines(
            on: automation.autoTrimOn, detecting: detecting, mode: automation.autoTrimMode,
            trim: automation.trim, baseline: automation.baseline, advisory: automation.advisory)
        next.waitingReason = displayedReason()
        next.following = automation.following
        next.paused = automation.paused
        next.suspended = automation.suspended
        next.deviationDb = automation.deviationDb
        next.followNote = AutomationReadout.followNote(
            following: automation.following, paused: automation.paused,
            waitingReason: automation.wantsFollow ? next.waitingReason : nil,
            deviationDb: automation.deviationDb, referenceActive: automation.referenceActive)
        let lines = AutomationReadout.lines(AutomationReadout.inputs(automation, app.eqHost))
        next.referenceLine = lines.reference.map(AutomationLine.init)
        next.trimLine = lines.trim.map(AutomationLine.init)
        next.trim = AutomationTrim(automation.trim)
        next.advisory = AutomationTrim(automation.advisory)
        next.baselineLearned = automation.baseline.isLearned
        next.baselineText = AutomationReadout.baselineText(automation.baseline)
        next.balanceText = AutomationReadout.balanceText(stage?.level.state.balance)
        next.fitRequest = fitRequest
        return next
    }

    private func displayedReason() -> String? {
        guard let reason = automation.waitingReason else { return nil }
        if reason == "Waiting for the 5K's EQ mode", !app.eq.isModeChanging {
            return "Waiting for the 5K to finish what it is doing"
        }
        return reason
    }

    private func refresh() {
        guard !stopped else { return }
        let next = computeState()
        guard next != state else { return }
        state = next
        for observer in observers.values { observer(next) }
    }

    func tick(_ context: EqAutomation.Context) {
        guard !stopped else { return }
        automation.tick(context)
        refresh()
    }

    package func setAutoTrim(on: Bool? = nil, mode: AutomationTrimMode? = nil, strength: Double? = nil) {
        automation.setAutoTrim(on: on, mode: mode?.shared, strength: strength)
    }

    package func setAutoFit(_ on: Bool) {
        automation.setAutoFit(on)
    }

    package func setReferenceSource(_ source: AutomationSource) {
        automation.setReferenceSource(source.shared)
    }

    package func setShowReference(_ on: Bool) {
        automation.setShowReference(on)
    }

    package func keep() {
        automation.keep()
        refresh()
    }

    package func resume() {
        automation.reenable()
        refresh()
    }

    package func clearReference() {
        automation.clearReference(for: app.eq.currentGroup)
    }

    package func requestFit(headphone: String) {
        fitRequest = headphone
        refresh()
    }

    package func clearFitRequest() {
        fitRequest = nil
        refresh()
    }

    func landReference(_ curve: ReferenceCurve) {
        app.eqHost.onReferenceLanded?(curve, app.eq.currentGroup)
    }

    package func diagnostics() -> String {
        automation.diagnostics()
    }

    package func persist() {
        automation.persistNow()
    }

    private func quit() {
        guard !stopped else { return }
        stopped = true
        automation.restoreBaseForQuit()
        automation.persistNow()
    }

    package func shutdown() {
        quit()
        if let appObserver { app.removeObserver(appObserver) }
        if let eqObserver { app.eq.removeObserver(eqObserver) }
        if let levelObserver, let stage { stage.removeObserver(levelObserver) }
        appObserver = nil
        eqObserver = nil
        levelObserver = nil
        stage?.level.automationTick = nil
    }
}
