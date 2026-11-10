import Foundation

package enum TuneMethod: String, CaseIterable, Equatable {
    case compare, shape, tones, check, trim
}

package enum TunePhase: Equatable {
    case idle, running, finished
}

package enum TuneVerdict: Equatable {
    case unreliable, nothingAudible, usable
}

package enum TuneCheckOutcome: Equatable {
    case preferredEQ(Int)
    case preferredFlat(Int)
    case noneSurvived(eq: Int, flat: Int, same: Int)
}

package struct TuneSideState: Equatable {
    package var phase = TunePhase.idle
    package var showingA = true
    package var trialsDone = 0
    package var trialsTotal = 0
    package var isConsistencyCheck = false
    package var title = ""
    package var detail = ""
    package var note: String?
    package var summary = ""
    package var values: [String: Double] = [:]
    package var resultBands: [EqBand] = []
    package var maxMovement = 0.0
    package var sameTrials = 0
    package var sameGuesses = 0
    package var inaudible: [String] = []
    package var rangeScale = 1.0
    package var verdict = TuneVerdict.usable
    package var outcome: TuneCheckOutcome?
    package var preferredEQ = 0
    package var preferredFlat = 0
    package var noPreference = 0
    package var round = 1

    package init() {}
}

package struct TuneToneState: Equatable {
    package var phase = TunePhase.idle
    package var currentHz = 0
    package var bandsDone = 0
    package var bandsTotal = ToneTestMath.order.count
    package var listening = false
    package var catchPlayed = 0
    package var catchFalsePositives = 0
    package var readingCount = 0
    package var suggestion: [TonePoint] = []
    package var verdict = ToneTestVerdict.tooFewReadings
    package var falseAlarmsElevated = false
    package var note: String?

    package init() {}
}

package struct TuneState: Equatable {
    package var active: TuneMethod?
    package var sessionActive = false
    package var compare = TuneSideState()
    package var shape = TuneSideState()
    package var check = TuneSideState()
    package var trim = TuneSideState()
    package var tones = TuneToneState()
    package var blockers: [TuneMethod: String] = [:]
    package var busy: String?
    package var note: String?

    package init() {}
}

@MainActor
package final class TuneModel {
    package static let busyText = "The 5K is busy \u{2014} try again in a moment."
    package static let sessionOpenText = "Another tuning session is already running."

    private let app: AppModel
    private let host: LinuxEqHost
    private let automation: AutomationModel?
    private let ab = ABTuner()
    private let blind = BlindTuner()
    let tones: ToneTestModel
    private var observers: [Int: (TuneState) -> Void] = [:]
    private var nextObserverID = 0
    private var appObserver: Int?
    private var eqObserver: Int?
    private var sessionObserver: Int?
    private var sessionGroup: QxEqGroup = .user
    private var interruptionNote: String?
    private var shutDown = false
    package private(set) var state = TuneState()

    package init(app: AppModel, routing: OutputRouting? = nil, backend: LinuxAudioBackend? = nil,
                 stage: StageModel? = nil, automation: AutomationModel? = nil) {
        self.app = app
        host = app.eqHost
        self.automation = automation
        tones = ToneTestModel(host: app.eqHost, routing: routing, backend: backend, stage: stage)
        tones.onChange = { [weak self] in self?.refresh() }
        appObserver = app.addObserver { [weak self] _ in self?.environmentChanged() }
        eqObserver = app.eq.addObserver { [weak self] _ in self?.environmentChanged() }
        sessionObserver = host.addSessionObserver { [weak self] active in
            if !active { self?.sessionEnded() }
        }
        host.onTuneShutdown = { [weak self] in self?.shutdown() }
        state = computeState()
    }

    @discardableResult
    package func addObserver(_ observer: @escaping (TuneState) -> Void) -> Int {
        nextObserverID += 1
        observers[nextObserverID] = observer
        observer(state)
        return nextObserverID
    }

    package func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    private var activeMethod: TuneMethod? {
        if ab.phase != .idle { return .compare }
        if blind.phase != .idle {
            switch blind.mode {
            case .shape: return .shape
            case .bypass: return .check
            case .trim: return .trim
            }
        }
        if tones.phase != .idle { return .tones }
        return nil
    }

    private func blockerText(_ method: TuneMethod) -> String? {
        switch method {
        case .compare: return ABTuner.blocker(host)?.message
        case .shape: return BlindTuner.blocker(host, mode: .shape)?.message
        case .check: return BlindTuner.blocker(host, mode: .bypass)?.message
        case .trim:
            guard let automation else { return BlindTuner.Blocker.trimOff.message }
            return BlindTuner.trimBlocker(host, automation: automation.engine)?.message
        case .tones: return tones.blocker?.message
        }
    }

    private func phase(_ value: ABTuner.Phase) -> TunePhase {
        switch value {
        case .idle: return .idle
        case .running: return .running
        case .finished: return .finished
        }
    }

    private func phase(_ value: BlindTuner.Phase) -> TunePhase {
        switch value {
        case .idle: return .idle
        case .running: return .running
        case .finished: return .finished
        }
    }

    private func compareState() -> TuneSideState {
        var side = TuneSideState()
        side.phase = phase(ab.phase)
        side.showingA = ab.showingA
        side.trialsDone = ab.trialsDone
        side.trialsTotal = ab.trialsTotal
        side.isConsistencyCheck = ab.isConsistencyCheck
        side.title = ab.currentMacro
        side.detail = ab.currentDetail
        side.note = interruptionNote(for: .compare) ?? ab.note
        side.values = ab.displayValues
        side.resultBands = ab.resultBands.map(EqBand.init)
        side.maxMovement = ab.maxMovement
        side.sameTrials = ab.sameTrials
        side.sameGuesses = ab.sameGuesses
        side.inaudible = ab.inaudible.sorted()
        side.round = ab.round
        side.verdict = ab.consistencyPoor ? .unreliable : .usable
        return side
    }

    private func blindSide(_ mode: BlindTuner.Mode) -> TuneSideState {
        var side = TuneSideState()
        guard blind.mode == mode else { return side }
        side.phase = phase(blind.phase)
        side.showingA = blind.showingA
        side.trialsDone = blind.trialsDone
        side.trialsTotal = blind.trialsTotal
        side.isConsistencyCheck = blind.isConsistencyCheck
        side.title = blind.currentTitle
        side.detail = blind.currentDetail
        side.note = interruptionNote(for: mode == .shape ? .shape : (mode == .bypass ? .check : .trim))
            ?? blind.note
        side.summary = blind.summary
        side.values = Dictionary(uniqueKeysWithValues: blind.values.map { ($0.key.rawValue, $0.value) })
        side.resultBands = blind.resultBands.map(EqBand.init)
        side.maxMovement = blind.maxMovement
        side.sameTrials = blind.sameTrials
        side.sameGuesses = blind.sameGuesses
        side.rangeScale = blind.rangeScale
        side.preferredEQ = blind.preferredEQ
        side.preferredFlat = blind.preferredFlat
        side.noPreference = blind.noPreference
        switch blind.verdict {
        case .unreliable: side.verdict = .unreliable
        case .nothingAudible: side.verdict = .nothingAudible
        case .usable: side.verdict = .usable
        }
        switch blind.bypassOutcome {
        case .preferredEQ(let count): side.outcome = .preferredEQ(count)
        case .preferredFlat(let count): side.outcome = .preferredFlat(count)
        case .noneSurvived(let eq, let flat, let same):
            side.outcome = .noneSurvived(eq: eq, flat: flat, same: same)
        }
        return side
    }

    private func interruptionNote(for method: TuneMethod) -> String? {
        activeOrLast == method ? interruptionNote : nil
    }

    private var lastMethod: TuneMethod?

    private var activeOrLast: TuneMethod? { activeMethod ?? lastMethod }

    private func toneVerdict() -> ToneTestVerdict {
        switch tones.verdict {
        case .tooFewReadings: return .tooFewReadings
        case .unreliable: return .unreliable
        case .tooScattered(let spread): return .tooScattered(spread)
        case .withinTestNoise: return .withinTestNoise
        case .usable: return .usable
        }
    }

    private func toneState() -> TuneToneState {
        var tone = TuneToneState()
        tone.phase = {
            switch tones.phase {
            case .idle: return .idle
            case .running: return .running
            case .finished: return .finished
            }
        }()
        tone.currentHz = tones.currentHz
        tone.bandsDone = tones.bandsDone
        tone.listening = tones.listening
        tone.catchPlayed = tones.catchPlayed
        tone.catchFalsePositives = tones.catchFalsePositives
        tone.readingCount = tones.readingCount
        tone.suggestion = tones.suggestion.map {
            TonePoint(hz: $0.hz, gain: $0.gain, deviation: $0.deviation, measured: $0.measured)
        }
        tone.verdict = toneVerdict()
        tone.falseAlarmsElevated = tones.falseAlarmsElevated
        tone.note = tones.note ?? interruptionNote(for: .tones)
        return tone
    }

    private func computeState() -> TuneState {
        var next = TuneState()
        next.active = activeMethod
        next.sessionActive = host.byEarSessionActive
        next.compare = compareState()
        next.shape = blindSide(.shape)
        next.check = blindSide(.bypass)
        next.trim = blindSide(.trim)
        next.tones = toneState()
        for method in TuneMethod.allCases {
            if let text = blockerText(method) { next.blockers[method] = text }
        }
        next.busy = busyReason()
        next.note = interruptionNote
        return next
    }

    private func busyReason() -> String? {
        if host.byEarSessionActive, activeMethod == nil { return Self.sessionOpenText }
        if host.eqSettling || app.eq.isBusy { return Self.busyText }
        return nil
    }

    private func refresh() {
        let next = computeState()
        guard next != state else { return }
        state = next
        for observer in observers.values { observer(next) }
    }

    private func startRefusal(_ method: TuneMethod) -> String? {
        if let text = blockerText(method) { return text }
        if let busy = busyReason() { return busy }
        return nil
    }

    package func blocker(for method: TuneMethod) -> String? {
        startRefusal(method)
    }

    private func chance(_ seed: UInt64?) -> Chance {
        seed.map { Chance.seeded($0) } ?? .real
    }

    package func start(_ method: TuneMethod, seed: UInt64? = nil) {
        guard activeMethod == nil, startRefusal(method) == nil else { return refresh() }
        interruptionNote = nil
        lastMethod = nil
        sessionGroup = host.eqGroup
        switch method {
        case .compare:
            ab.start(host, chance: chance(seed))
        case .shape:
            blind.start(host, mode: .shape, chance: chance(seed))
        case .check:
            blind.start(host, mode: .bypass, chance: chance(seed))
        case .trim:
            if let automation {
                blind.startTrim(host, trim: automation.engine.trim, chance: chance(seed))
            }
        case .tones:
            tones.start()
        }
        refresh()
    }

    package func toggleSide() {
        switch activeMethod {
        case .compare: ab.toggleSide(host)
        case .shape, .check, .trim: blind.toggleSide(host)
        default: break
        }
        refresh()
    }

    package func choose(preferA: Bool) {
        switch activeMethod {
        case .compare: ab.choose(preferA: preferA, host)
        case .shape, .check, .trim: blind.choose(preferA: preferA, host)
        default: break
        }
        refresh()
    }

    package func noDifference() {
        switch activeMethod {
        case .compare: ab.noDifference(host)
        case .shape, .check, .trim: blind.noDifference(host)
        default: break
        }
        refresh()
    }

    package func cancel() {
        guard let method = activeMethod else { return }
        switch method {
        case .compare: ab.cancel(host)
        case .shape, .check, .trim: blind.cancel(host)
        case .tones: tones.stop()
        }
        lastMethod = nil
        refresh()
    }

    @discardableResult
    package func keep() -> Bool {
        var kept = false
        switch activeMethod {
        case .compare:
            ab.keepResult(host)
            kept = ab.phase == .idle
        case .shape:
            blind.keepResult(host)
            kept = blind.phase == .idle
        case .tones:
            kept = tones.applySuggestion()
        default: break
        }
        refresh()
        return kept
    }

    package func discard() {
        switch activeMethod {
        case .compare: ab.discardResult(host)
        case .shape, .check, .trim: blind.discardResult(host)
        case .tones: tones.stop()
        default: break
        }
        refresh()
    }

    package func reportHeard() {
        tones.reportHeard()
    }

    private func sessionEnded() {
        Task { @MainActor [weak self] in
            guard let self, !self.shutDown else { return }
            self.abandonRunning()
        }
    }

    private func abandonRunning() {
        if ab.phase == .running, !host.byEarSessionActive {
            ab.abandon(host)
            lastMethod = .compare
        }
        if blind.phase == .running, !host.byEarSessionActive {
            let method = activeMethod
            blind.abandon(host)
            lastMethod = method
        }
        if tones.phase == .running, !host.byEarSessionActive {
            tones.abandon()
            lastMethod = .tones
        }
        refresh()
    }

    private func environmentChanged() {
        guard !shutDown else { return }
        checkInterruptions()
        refresh()
    }

    private func checkInterruptions() {
        guard host.byEarSessionActive, let method = activeMethod else { return }
        if method == .tones {
            tones.checkInterruption()
            return
        }
        let reason = ABTuner.interruption(connected: host.isConnectedNow,
                                          compatible: host.isCompatible,
                                          voiceCall: host.isOnVoiceLink || host.activeCall == true,
                                          eqModeChanged: host.eqGroup != sessionGroup)
        guard let reason else { return }
        if method == .compare {
            guard ab.phase == .running else { return }
            ab.cancel(host)
        } else {
            guard blind.phase == .running else { return }
            blind.cancel(host)
        }
        interruptionNote = "Session stopped \u{2014} \(reason.reason)."
        lastMethod = method
    }

    package func shutdown() {
        guard !shutDown else { return }
        if activeMethod != nil { cancel() }
        shutDown = true
        if let appObserver { app.removeObserver(appObserver) }
        if let eqObserver { app.eq.removeObserver(eqObserver) }
        if let sessionObserver { host.removeSessionObserver(sessionObserver) }
        appObserver = nil
        eqObserver = nil
        sessionObserver = nil
    }
}
