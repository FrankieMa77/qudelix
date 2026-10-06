import Foundation
import SwiftUI

enum SessionInterruption: Equatable {
    case disconnected
    case unsupported
    case voiceCall
    case eqModeChanged
    case playerStopped
    case outputChanged

    var reason: String {
        switch self {
        case .disconnected: return "the 5K disconnected"
        case .unsupported: return "the device stopped accepting EQ writes"
        case .voiceCall: return "the link dropped to hands-free (voice) mode"
        case .eqModeChanged: return "the device changed EQ mode"
        case .playerStopped: return "the tone player stopped"
        case .outputChanged: return "sound moved to another output device"
        }
    }
}

@MainActor
final class ABTuner: ObservableObject {
    struct Macro {
        let name: String
        let detail: String
        let shape: [Double]
        let range: Double
    }

    static let macros: [Macro] = [
        Macro(name: "Bass", detail: "31–250 Hz",
              shape: [1.0, 1.0, 0.8, 0.4, 0, 0, 0, 0, 0, 0], range: 6),
        Macro(name: "Warmth", detail: "125–1k Hz",
              shape: [0, 0, 0.3, 1.0, 0.7, 0.2, 0, 0, 0, 0], range: 4),
        Macro(name: "Presence", detail: "500–4k Hz",
              shape: [0, 0, 0, 0, 0.2, 0.6, 1.0, 0.6, 0.1, 0], range: 4),
        Macro(name: "Treble", detail: "2k–16k Hz",
              shape: [0, 0, 0, 0, 0, 0, 0.3, 0.7, 1.0, 1.0], range: 6),
    ]

    static let rounds = 4
    static let tiltCap = 6.0
    static var trialsPerRound: Int { macros.count + 1 }

    enum Phase: Equatable { case idle, running, finished }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var showingA = true
    @Published private(set) var round = 1
    @Published private(set) var currentMacro = ""
    @Published private(set) var currentDetail = ""
    @Published private(set) var isConsistencyCheck = false
    @Published private(set) var trialsDone = 0
    @Published private(set) var trialsTotal = 0
    @Published private(set) var values: [String: Double] = [:]
    @Published private(set) var resultBands: [QxEqBandValue] = []
    @Published private(set) var sameTrials = 0
    @Published private(set) var sameGuesses = 0
    @Published private(set) var inaudible: Set<String> = []
    @Published private(set) var note: String?

    private var baseline: [QxEqBandValue] = []
    private var baselinePreGain: Double = 0
    private var sessionPreGain: Double = 0
    private var sessionGroup: QxEqGroup = .user

    private var steps: [String: Double] = [:]
    private var indifferent: [String: Int] = [:]
    private var queue: [String?] = []
    private var curveA: [QxEqBandValue] = []
    private var curveB: [QxEqBandValue] = []
    private var preGainA: Double = 0
    private var preGainB: Double = 0
    private var devicePreGain: Double = 0
    private var highIsA = true
    private var chance: Chance = .real

    enum Blocker: Equatable {
        case notConnected
        case unsupported
        case voiceCall
        case noGainBand

        var message: String {
            switch self {
            case .notConnected: return "Connect the 5K first."
            case .unsupported: return "This device isn't supported, so nothing can be written."
            case .voiceCall:
                return "The link is in hands-free (voice) mode at 16 kHz. "
                    + "Audio quality is too low to judge — close whatever is using the microphone."
            case .noGainBand:
                return "Every band is switched off or a pass filter, so both options "
                    + "would be the same sound. Add a peak or shelf band first."
            }
        }
    }

    static func blocker(_ c: QudelixController) -> Blocker? {
        if case .connected = c.connection {} else { return .notConnected }
        guard c.compatibility == .ok else { return .unsupported }
        if let src = c.inputSource, src.hasPrefix("HFP") { return .voiceCall }
        if c.sampleRate == "16 kHz" { return .voiceCall }
        guard c.bands.prefix(c.bandCount).contains(where: { $0.filter.rendersGain }) else {
            return .noGainBand
        }
        return nil
    }

    nonisolated static func interruption(connected: Bool, compatible: Bool,
                                         voiceCall: Bool,
                                         eqModeChanged: Bool) -> SessionInterruption? {
        if !connected { return .disconnected }
        if !compatible { return .unsupported }
        if voiceCall { return .voiceCall }
        if eqModeChanged { return .eqModeChanged }
        return nil
    }

    private func interruption(_ c: QudelixController) -> SessionInterruption? {
        var connected = false
        if case .connected = c.connection { connected = true }
        let voice = (c.inputSource?.hasPrefix("HFP") ?? false) || c.sampleRate == "16 kHz"
        return Self.interruption(connected: connected,
                                 compatible: c.compatibility == .ok,
                                 voiceCall: voice,
                                 eqModeChanged: c.eqGroup != sessionGroup)
    }

    private func stillValid(_ c: QudelixController) -> Bool {
        guard let interruption = interruption(c) else { return true }
        if interruption != .eqModeChanged { restoreBaseline(c) }
        endSession(c)
        note = "Comparison stopped — \(interruption.reason)."
        return false
    }

    nonisolated static func safePreGain(for bands: [QxEqBandValue],
                                        notAbove userPreGain: Double,
                                        plusBoost: Double = 0) -> Double {
        let peak = EQHeadroom.peakBoost(of: bands) + plusBoost
        return EQHeadroom.clamp(min(userPreGain, -max(0, peak)))
    }

    func start(_ c: QudelixController, chance: Chance = .real) {
        guard Self.blocker(c) == nil, phase == .idle else { return }

        note = nil
        self.chance = chance
        c.beginUndoStep("by-ear tuning")
        baseline = c.bands
        baselinePreGain = c.preGain
        sessionGroup = c.eqGroup
        values = Dictionary(uniqueKeysWithValues: Self.macros.map { ($0.name, 0.0) })
        steps = Dictionary(uniqueKeysWithValues: Self.macros.map { ($0.name, $0.range) })
        sameTrials = 0; sameGuesses = 0; trialsDone = 0; round = 1
        inaudible = []
        indifferent = Dictionary(uniqueKeysWithValues: Self.macros.map { ($0.name, 0) })

        sessionPreGain = Self.safePreGain(for: baseline,
                                          notAbove: baselinePreGain,
                                          plusBoost: Self.tiltCap)

        queue = []
        for _ in 1...Self.rounds {
            var block: [String?] = Self.macros.map { $0.name }
            block.insert(nil, at: chance.index(block.count))
            queue.append(contentsOf: block)
        }
        trialsTotal = queue.count

        devicePreGain = baselinePreGain
        c.setByEarSessionActive(true)
        phase = .running
        nextTrial(c)
    }

    func cancel(_ c: QudelixController) {
        restoreBaseline(c)
        endSession(c)
    }

    private func endSession(_ c: QudelixController) {
        c.setByEarSessionActive(false)
        phase = .idle
    }

    func toggleSide(_ c: QudelixController) {
        guard phase == .running, stillValid(c) else { return }
        showingA.toggle()
        pushSide(c)
    }

    func noDifference(_ c: QudelixController) {
        guard phase == .running, stillValid(c) else { return }
        if isConsistencyCheck {
            sameTrials += 1
        } else if let name = currentMacroName,
                  let m = Self.macros.first(where: { $0.name == name }) {
            let step = steps[name] ?? m.range
            if step >= m.range / 2 { indifferent[name, default: 0] += 1 }
            steps[name] = step / 2
        }
        trialsDone += 1
        nextTrial(c)
    }

    func choose(preferA: Bool, _ c: QudelixController) {
        guard phase == .running, stillValid(c) else { return }
        let preferredHigh = (preferA == highIsA)

        if isConsistencyCheck {
            sameTrials += 1
            sameGuesses += 1
        } else if let name = currentMacroName, let m = Self.macros.first(where: { $0.name == name }) {
            let step = steps[name] ?? m.range
            let centre = values[name] ?? 0
            let low = max(centre - step / 2, -m.range)
            let high = min(centre + step / 2, m.range)
            values[name] = preferredHigh ? high : low
            steps[name] = step / 2
        }

        trialsDone += 1
        nextTrial(c)
    }

    private var currentMacroName: String?

    private func nextTrial(_ c: QudelixController) {
        guard !queue.isEmpty else { finish(c); return }
        let entry = queue.removeFirst()
        round = min(Self.rounds, trialsDone / max(1, Self.trialsPerRound) + 1)

        if let name = entry, let m = Self.macros.first(where: { $0.name == name }) {
            isConsistencyCheck = false
            currentMacroName = name
            currentMacro = m.name
            currentDetail = m.detail
            let step = steps[name] ?? m.range
            let centre = values[name] ?? 0
            var lowV = values, highV = values
            lowV[name] = max(centre - step / 2, -m.range)
            highV[name] = min(centre + step / 2, m.range)
            let lowCurve = curve(lowV)
            let highCurve = curve(highV)
            highIsA = chance.coin()
            curveA = highIsA ? highCurve : lowCurve
            curveB = highIsA ? lowCurve : highCurve
        } else {
            isConsistencyCheck = true
            currentMacroName = nil
            currentMacro = "Consistency check"
            currentDetail = "these two may be identical"
            let same = curve(values)
            curveA = same; curveB = same
            highIsA = chance.coin()
        }

        let matched = LevelMatch.matchedPreGains(curveA, curveB, base: sessionPreGain)
        preGainA = matched.a
        preGainB = matched.b
        showingA = true
        pushSide(c)
    }

    private func finish(_ c: QudelixController) {
        for m in Self.macros where (indifferent[m.name] ?? 0) >= 2 {
            values[m.name] = 0
            inaudible.insert(m.name)
        }
        resultBands = curve(values)
        curveA = resultBands
        curveB = resultBands
        let matched = LevelMatch.matchedPreGains(resultBands, baseline, base: sessionPreGain)
        preGainA = matched.a
        preGainB = matched.a
        showingA = true
        pushSide(c)
        phase = .finished
    }

    var displayValues: [String: Double] {
        let vs = Self.macros.map { values[$0.name] ?? 0 }
        let mean = vs.reduce(0, +) / Double(max(1, vs.count))
        return Dictionary(uniqueKeysWithValues: Self.macros.map {
            ($0.name, (values[$0.name] ?? 0) - mean)
        })
    }

    var maxMovement: Double { Self.movement(from: baseline, to: resultBands) }

    nonisolated static func movement(from baseline: [QxEqBandValue],
                                     to result: [QxEqBandValue]) -> Double {
        zip(baseline, result).map { abs($1.gain - $0.gain) }.max() ?? 0
    }

    nonisolated static let minChecksToJudge = 3

    var consistencyPoor: Bool {
        Self.consistencyPoor(guesses: sameGuesses, of: sameTrials)
    }

    nonisolated static func consistencyPoor(guesses: Int, of trials: Int) -> Bool {
        trials >= minChecksToJudge && guesses * 2 > trials
    }

    func keepResult(_ c: QudelixController) {
        guard phase == .finished, !resultBands.isEmpty, stillValid(c) else { return }
        c.setPreGain(Self.safePreGain(for: resultBands, notAbove: baselinePreGain),
                     recordUndo: false)
        endSession(c)
    }

    func discardResult(_ c: QudelixController) {
        guard phase == .finished else { return }
        restoreBaseline(c)
        endSession(c)
    }

    private func restoreBaseline(_ c: QudelixController) {
        guard c.eqGroup == sessionGroup else { return }
        push(baseline, preGain: baselinePreGain, to: c)
    }

    nonisolated static func weight(_ shape: [Double], atHz hz: Int) -> Double {
        let table = QxEq.defaultFreqs
        guard let lowest = table.first, let highest = table.last,
              shape.count == table.count else { return 0 }
        if hz <= lowest { return shape[0] }
        if hz >= highest { return shape[shape.count - 1] }
        for i in 1..<table.count where hz <= table[i] {
            let lo = Double(table[i - 1]), hi = Double(table[i])
            let t = (log10(Double(hz)) - log10(lo)) / (log10(hi) - log10(lo))
            return shape[i - 1] + t * (shape[i] - shape[i - 1])
        }
        return shape[shape.count - 1]
    }

    private func curve(_ v: [String: Double]) -> [QxEqBandValue] {
        let count = baseline.count
        guard count > 0 else { return [] }
        let eligible = (0..<count).filter { baseline[$0].filter.rendersGain }
        guard !eligible.isEmpty else { return baseline }
        var tilt = [Double](repeating: 0, count: count)
        for m in Self.macros {
            let amount = v[m.name] ?? 0
            guard amount != 0 else { continue }
            for i in eligible {
                tilt[i] += amount * Self.weight(m.shape, atHz: baseline[i].freq)
            }
        }
        let mean = eligible.map { tilt[$0] }.reduce(0, +) / Double(eligible.count)
        var out = baseline
        for i in eligible {
            let shaped = min(max(tilt[i] - mean, -Self.tiltCap), Self.tiltCap)
            out[i].gain = min(max(baseline[i].gain + shaped, -12), 12)
        }
        return out
    }

    private func apply(_ bands: [QxEqBandValue], to c: QudelixController) {
        for (i, b) in bands.enumerated() where i < c.bandCount {
            c.updateBand(i, b, persistToFlash: false, recordUndo: false)
        }
    }

    private func pushSide(_ c: QudelixController) {
        push(showingA ? curveA : curveB,
             preGain: showingA ? preGainA : preGainB, to: c)
    }

    private func push(_ bands: [QxEqBandValue], preGain: Double,
                      to c: QudelixController) {
        if preGain < devicePreGain {
            writePreGain(preGain, to: c)
            apply(bands, to: c)
        } else {
            apply(bands, to: c)
            writePreGain(preGain, to: c)
        }
    }

    private func writePreGain(_ db: Double, to c: QudelixController) {
        guard abs(db - devicePreGain) >= 0.05 else { return }
        c.setPreGain(db, persistToFlash: false, recordUndo: false)
        devicePreGain = db
    }
}
