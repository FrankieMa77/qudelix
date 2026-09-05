import Foundation
import SwiftUI

enum LevelMatch {
    static let lowHz: Double = 100
    static let highHz: Double = 8000
    static let points = 129
    static let toleranceDb: Double = 0.1

    nonisolated static let grid: [Double] = {
        let l0 = log10(lowHz), l1 = log10(highHz)
        return (0..<points).map { i in
            pow(10, l0 + (l1 - l0) * (Double(i) + 0.5) / Double(points))
        }
    }()

    nonisolated static func meanLevelDb(bands: [QxEqBandValue], preGain: Double = 0) -> Double {
        let response = EQCurve.response(bands: bands, preGain: preGain, at: grid)
        guard !response.isEmpty else { return preGain }
        return response.reduce(0, +) / Double(response.count)
    }

    nonisolated static func matchedPreGains(_ a: [QxEqBandValue], _ b: [QxEqBandValue],
                                            base: Double) -> (a: Double, b: Double) {
        let levelA = meanLevelDb(bands: a), levelB = meanLevelDb(bands: b)
        let quieter = min(levelA, levelB)
        return (trimmed(base, by: levelA - quieter), trimmed(base, by: levelB - quieter))
    }

    nonisolated static func trimmed(_ base: Double, by trim: Double) -> Double {
        guard base.isFinite else { return 0 }
        guard trim.isFinite else { return EQHeadroom.clamp(base) }
        return EQHeadroom.clamp(base - max(0, trim))
    }
}

struct Chance {
    var coin: () -> Bool
    var index: (Int) -> Int

    static var real: Chance {
        Chance(coin: { Bool.random() }, index: { Int.random(in: 0...$0) })
    }

    static func seeded(_ seed: UInt64) -> Chance {
        var state = seed
        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        return Chance(coin: { next() & 1 == 0 },
                      index: { n in Int(next() % UInt64(max(1, n + 1))) })
    }
}

enum ShapeAxis: String, CaseIterable, Identifiable {
    case bass, presence, tilt

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bass: return "Bass"
        case .presence: return "Presence"
        case .tilt: return "Tilt"
        }
    }

    var detail: String {
        switch self {
        case .bass: return "105 Hz shelf"
        case .presence: return "2.8 kHz"
        case .tilt: return "overall slope"
        }
    }

    var unit: String { self == .tilt ? "dB/oct" : "dB" }

    var low: Double {
        switch self {
        case .bass: return -6
        case .presence: return -4
        case .tilt: return -2
        }
    }

    var high: Double {
        switch self {
        case .bass: return 8
        case .presence: return 4
        case .tilt: return 2
        }
    }

    var firstStep: Double {
        switch self {
        case .bass: return 4
        case .presence: return 3
        case .tilt: return 1
        }
    }

    var audibleFloor: Double { self == .tilt ? 0.25 : 1.0 }

    static let referenceGain: Double = 1
    static let tiltPivotHz: Double = 1000
    static let tiltLowHz: Double = 250
    static let tiltHighHz: Double = 4000

    var idealFilter: QxEqBandValue? {
        switch self {
        case .bass:
            return QxEqBandValue(filter: .lowShelf, freq: 105,
                                 gain: Self.referenceGain, q: 0.71)
        case .presence:
            return QxEqBandValue(filter: .peak, freq: 2800,
                                 gain: Self.referenceGain, q: 1.0)
        case .tilt:
            return nil
        }
    }

    nonisolated func weights(atCentres freqs: [Int]) -> [Double] {
        guard let ideal = idealFilter else {
            return freqs.map { hz in
                let f = min(max(Double(hz), Self.tiltLowHz), Self.tiltHighHz)
                return log2(f / Self.tiltPivotHz)
            }
        }
        return EQCurve.response(bands: [ideal], preGain: 0, at: freqs.map(Double.init))
            .map { $0 / Self.referenceGain }
    }
}

struct ShapeRun {
    static let axisOrder: [ShapeAxis] = [.bass, .presence, .tilt]
    static let rounds = 3

    enum Answer: Equatable { case preferA, preferB, same }

    struct Trial {
        let axis: ShapeAxis?
        let round: Int
        let low: [QxEqBandValue]
        let high: [QxEqBandValue]
        let highIsA: Bool

        var a: [QxEqBandValue] { highIsA ? high : low }
        var b: [QxEqBandValue] { highIsA ? low : high }
    }

    let baseline: [QxEqBandValue]
    let weights: [ShapeAxis: [Double]]
    let scale: Double
    let trialsTotal: Int

    private(set) var values: [ShapeAxis: Double]
    private(set) var steps: [ShapeAxis: Double]
    private(set) var trial: Trial?
    private(set) var trialsDone = 0
    private(set) var sameTrials = 0
    private(set) var sameGuesses = 0
    private(set) var skipped = 0
    private(set) var converged: Set<ShapeAxis> = []

    private var queue: [ShapeAxis?]
    private var chance: Chance

    init(baseline: [QxEqBandValue], weights: [ShapeAxis: [Double]],
         scale: Double = 1, chance: Chance = .real) {
        let fitted = max(0.01, min(1, scale))
        self.baseline = baseline
        self.weights = weights
        self.scale = fitted
        self.chance = chance
        values = Dictionary(uniqueKeysWithValues: ShapeAxis.allCases.map { ($0, 0.0) })
        steps = Dictionary(uniqueKeysWithValues:
            ShapeAxis.allCases.map { ($0, $0.firstStep * fitted) })
        var built: [ShapeAxis?] = []
        for axis in Self.axisOrder {
            var block: [ShapeAxis?] = Array(repeating: axis, count: Self.rounds)
            block.insert(nil, at: chance.index(block.count))
            built += block
        }
        queue = built
        trialsTotal = built.count
        advance()
    }

    var finished: Bool { trial == nil }

    func low(_ axis: ShapeAxis) -> Double { axis.low * scale }
    func high(_ axis: ShapeAxis) -> Double { axis.high * scale }

    mutating func answer(_ answer: Answer) {
        guard let trial else { return }
        if let axis = trial.axis {
            let step = steps[axis] ?? axis.firstStep * scale
            let centre = values[axis] ?? 0
            let lowValue = max(centre - step, low(axis))
            let highValue = min(centre + step, high(axis))
            if answer != .same {
                let preferredHigh = ((answer == .preferA) == trial.highIsA)
                values[axis] = preferredHigh ? highValue : lowValue
            }
            steps[axis] = step / 2
        } else {
            sameTrials += 1
            if answer != .same { sameGuesses += 1 }
        }
        trialsDone += 1
        advance()
    }

    private mutating func advance() {
        while !queue.isEmpty {
            let entry = queue.removeFirst()
            guard let axis = entry else {
                let same = Self.curve(baseline: baseline, weights: weights, values: values)
                trial = Trial(axis: nil, round: 0, low: same, high: same,
                              highIsA: chance.coin())
                return
            }
            let round = Self.rounds - queue.filter { $0 == axis }.count
            let step = steps[axis] ?? axis.firstStep * scale
            guard !converged.contains(axis) else {
                steps[axis] = step / 2
                skipped += 1
                trialsDone += 1
                continue
            }
            let centre = values[axis] ?? 0
            var lowValues = values, highValues = values
            lowValues[axis] = max(centre - step, low(axis))
            highValues[axis] = min(centre + step, high(axis))
            let lowCurve = Self.curve(baseline: baseline, weights: weights, values: lowValues)
            let highCurve = Self.curve(baseline: baseline, weights: weights, values: highValues)
            if lowCurve == highCurve {
                converged.insert(axis)
                steps[axis] = step / 2
                skipped += 1
                trialsDone += 1
                continue
            }
            trial = Trial(axis: axis, round: round, low: lowCurve, high: highCurve,
                          highIsA: chance.coin())
            return
        }
        trial = nil
    }

    nonisolated static func quantised(_ gain: Double) -> Double {
        guard gain.isFinite else { return 0 }
        return (gain * QxScale.gain).rounded() / QxScale.gain
    }

    nonisolated static func curve(baseline: [QxEqBandValue],
                                  weights: [ShapeAxis: [Double]],
                                  values: [ShapeAxis: Double]) -> [QxEqBandValue] {
        var out = baseline
        for i in out.indices where out[i].filter.rendersGain {
            var gain = baseline[i].gain
            for axis in ShapeAxis.allCases {
                let value = values[axis] ?? 0
                guard value != 0, let weight = weights[axis], i < weight.count else { continue }
                gain += value * weight[i]
            }
            out[i].gain = quantised(min(max(gain, -12), 12))
        }
        return out
    }

    nonisolated static func flattened(_ bands: [QxEqBandValue]) -> [QxEqBandValue] {
        bands.map { band in
            var out = band
            out.gain = 0
            if out.filter == .lpf || out.filter == .hpf { out.filter = .peak }
            return out
        }
    }

    var nothingAudible: Bool {
        ShapeAxis.allCases.allSatisfy { abs(values[$0] ?? 0) < $0.audibleFloor }
    }

    var consistencyPoor: Bool {
        ABTuner.consistencyPoor(guesses: sameGuesses, of: sameTrials)
    }

    nonisolated static func text(_ value: Double, axis: ShapeAxis) -> String {
        var s = String(format: "%+.2f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + " " + axis.unit
    }

    var summary: String {
        Self.axisOrder
            .map { "\($0.label) \(Self.text(values[$0] ?? 0, axis: $0))" }
            .joined(separator: " · ")
    }
}

@MainActor
final class BlindTuner: ObservableObject {
    enum Mode: String, Equatable { case shape, bypass }
    enum Phase: Equatable { case idle, running, finished }

    static let bypassTrials = 5
    static let bypassClearMajority = 4
    nonisolated static let smallestRange = 0.25

    @Published private(set) var mode: Mode = .shape
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var showingA = true
    @Published private(set) var trialsDone = 0
    @Published private(set) var trialsTotal = 0
    @Published private(set) var isConsistencyCheck = false
    @Published private(set) var currentTitle = ""
    @Published private(set) var currentDetail = ""
    @Published private(set) var note: String?

    @Published private(set) var values: [ShapeAxis: Double] = [:]
    @Published private(set) var summary = ""
    @Published private(set) var sameTrials = 0
    @Published private(set) var sameGuesses = 0
    @Published private(set) var skippedTrials = 0
    @Published private(set) var rangeScale: Double = 1
    @Published private(set) var resultBands: [QxEqBandValue] = []

    @Published private(set) var preferredEQ = 0
    @Published private(set) var preferredFlat = 0
    @Published private(set) var noPreference = 0

    private var run: ShapeRun?
    private var chance: Chance = .real
    private var weights: [ShapeAxis: [Double]] = [:]

    private var baseline: [QxEqBandValue] = []
    private var baselinePreGain: Double = 0
    private var sessionPreGain: Double = 0
    private var sessionGroup: QxEqGroup = .user

    private var onDevice: [QxEqBandValue] = []
    private var devicePreGain: Double = 0
    private var curveA: [QxEqBandValue] = []
    private var curveB: [QxEqBandValue] = []
    private var preGainA: Double = 0
    private var preGainB: Double = 0
    private var eqIsA = true

    enum Blocker: Equatable {
        case notConnected
        case unsupported
        case voiceCall
        case noGainBand
        case eqOff
        case alreadyFlat

        var message: String {
            switch self {
            case .notConnected: return "Connect the 5K first."
            case .unsupported: return "This device isn't supported, so nothing can be written."
            case .voiceCall:
                return "The link is in hands-free (voice) mode at 16 kHz. "
                    + "Audio quality is too low to judge — close whatever is using the microphone."
            case .noGainBand:
                return "Every band is switched off or a pass filter, so there is nowhere "
                    + "to put a shape. Add a peak or shelf band first."
            case .eqOff:
                return "The EQ is switched off, so both sides would be the same sound. "
                    + "Switch it on first."
            case .alreadyFlat:
                return "Your EQ is flat, so both sides would be the same sound."
            }
        }
    }

    static func blocker(_ c: QudelixController, mode: Mode) -> Blocker? {
        if case .connected = c.connection {} else { return .notConnected }
        guard c.compatibility == .ok else { return .unsupported }
        if let src = c.inputSource, src.hasPrefix("HFP") { return .voiceCall }
        if c.sampleRate == "16 kHz" { return .voiceCall }
        let live = Array(c.bands.prefix(c.bandCount))
        switch mode {
        case .shape:
            guard live.contains(where: { $0.filter.rendersGain }) else { return .noGainBand }
        case .bypass:
            guard c.eqEnabled else { return .eqOff }
            guard live.contains(where: { $0.filter != .bypass
                    && (!$0.filter.rendersGain || $0.gain != 0) }) else { return .alreadyFlat }
        }
        return nil
    }

    nonisolated static func weights(for baseline: [QxEqBandValue]) -> [ShapeAxis: [Double]] {
        let centres = baseline.map(\.freq)
        return Dictionary(uniqueKeysWithValues:
            ShapeAxis.allCases.map { ($0, $0.weights(atCentres: centres)) })
    }

    nonisolated static func cornerCurves(baseline: [QxEqBandValue],
                                         weights: [ShapeAxis: [Double]],
                                         scale: Double) -> [[QxEqBandValue]] {
        var out = [baseline]
        for bass in [ShapeAxis.bass.low, ShapeAxis.bass.high] {
            for presence in [ShapeAxis.presence.low, ShapeAxis.presence.high] {
                for tilt in [ShapeAxis.tilt.low, ShapeAxis.tilt.high] {
                    out.append(ShapeRun.curve(baseline: baseline, weights: weights,
                                              values: [.bass: bass * scale,
                                                       .presence: presence * scale,
                                                       .tilt: tilt * scale]))
                }
            }
        }
        return out
    }

    nonisolated static func pairSpans(_ axis: ShapeAxis,
                                      scale: Double) -> [(Double, Double)] {
        let low = axis.low * scale, high = axis.high * scale
        let step = axis.firstStep * scale
        let span = min(2 * step, high - low)
        return [(low, low + span),
                (high - span, high),
                (max(low, -step), min(high, step))]
    }

    nonisolated static func worstTrim(baseline: [QxEqBandValue],
                                      weights: [ShapeAxis: [Double]],
                                      scale: Double) -> Double {
        let backgrounds: [[ShapeAxis: Double]] = [
            [:],
            Dictionary(uniqueKeysWithValues: ShapeAxis.allCases.map { ($0, $0.low * scale) }),
            Dictionary(uniqueKeysWithValues: ShapeAxis.allCases.map { ($0, $0.high * scale) }),
        ]
        var worst = 0.0
        for axis in ShapeAxis.allCases {
            for (lowValue, highValue) in pairSpans(axis, scale: scale) {
                for background in backgrounds {
                    var low = background, high = background
                    low[axis] = lowValue
                    high[axis] = highValue
                    let levelLow = LevelMatch.meanLevelDb(
                        bands: ShapeRun.curve(baseline: baseline, weights: weights,
                                              values: low))
                    let levelHigh = LevelMatch.meanLevelDb(
                        bands: ShapeRun.curve(baseline: baseline, weights: weights,
                                              values: high))
                    worst = max(worst, abs(levelHigh - levelLow))
                }
            }
        }
        return worst
    }

    nonisolated static func fitted(baseline: [QxEqBandValue],
                                   weights: [ShapeAxis: [Double]],
                                   userPreGain: Double) -> (scale: Double, base: Double) {
        let rungs = 20
        let lowest = Int((smallestRange * Double(rungs)).rounded())

        func rung(_ i: Int) -> (scale: Double, base: Double, fits: Bool) {
            let scale = Double(i) / Double(rungs)
            let base = cornerCurves(baseline: baseline, weights: weights, scale: scale)
                .map { ABTuner.safePreGain(for: $0, notAbove: userPreGain) }
                .min() ?? EQHeadroom.clamp(userPreGain)
            let trim = worstTrim(baseline: baseline, weights: weights, scale: scale)
            return (scale, base, base - trim >= EQHeadroom.range.lowerBound)
        }

        var low = lowest, high = rungs
        var best: (scale: Double, base: Double)?
        while low <= high {
            let middle = (low + high) / 2
            let step = rung(middle)
            if step.fits {
                best = (step.scale, step.base)
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        if let best { return best }
        let floor = rung(lowest)
        return (floor.scale, floor.base)
    }

    func start(_ c: QudelixController, mode: Mode, chance: Chance = .real) {
        guard phase == .idle, Self.blocker(c, mode: mode) == nil else { return }
        note = nil
        self.mode = mode
        self.chance = chance
        c.beginUndoStep(mode == .bypass ? "blind check" : "by-ear shaping")
        baseline = c.bands
        baselinePreGain = c.preGain
        sessionGroup = c.eqGroup
        onDevice = baseline
        devicePreGain = baselinePreGain
        values = [:]; summary = ""; resultBands = []
        sameTrials = 0; sameGuesses = 0; skippedTrials = 0; trialsDone = 0
        preferredEQ = 0; preferredFlat = 0; noPreference = 0
        rangeScale = 1

        switch mode {
        case .shape:
            let w = Self.weights(for: baseline)
            weights = w
            let fit = Self.fitted(baseline: baseline, weights: w,
                                  userPreGain: baselinePreGain)
            rangeScale = fit.scale
            sessionPreGain = fit.base
            if fit.scale < 1 {
                note = "The 5K has 12 dB of pre-gain to spend, and matching levels "
                    + "across the full range needs more, so this session explores "
                    + "\(Int((fit.scale * 100).rounded()))% of it."
            }
            let r = ShapeRun(baseline: baseline, weights: w, scale: fit.scale, chance: chance)
            run = r
            trialsTotal = r.trialsTotal
            phase = .running
            c.setByEarSessionActive(true)
            publish(r)
            presentTrial(c)
        case .bypass:
            let flat = ShapeRun.flattened(baseline)
            sessionPreGain = min(ABTuner.safePreGain(for: baseline, notAbove: baselinePreGain),
                                 ABTuner.safePreGain(for: flat, notAbove: baselinePreGain))
            run = nil
            weights = [:]
            trialsTotal = Self.bypassTrials
            phase = .running
            c.setByEarSessionActive(true)
            presentBypassTrial(c)
        }
    }

    func cancel(_ c: QudelixController) {
        guard phase != .idle else { return }
        restoreBaseline(c)
        endSession(c)
    }

    private func endSession(_ c: QudelixController) {
        c.setByEarSessionActive(false)
        phase = .idle
    }

    private func interruption(_ c: QudelixController) -> SessionInterruption? {
        var connected = false
        if case .connected = c.connection { connected = true }
        let voice = (c.inputSource?.hasPrefix("HFP") ?? false) || c.sampleRate == "16 kHz"
        return ABTuner.interruption(connected: connected,
                                    compatible: c.compatibility == .ok,
                                    voiceCall: voice,
                                    eqModeChanged: c.eqGroup != sessionGroup)
    }

    private func stillValid(_ c: QudelixController) -> Bool {
        guard let interruption = interruption(c) else { return true }
        if interruption != .eqModeChanged { restoreBaseline(c) }
        endSession(c)
        note = (mode == .bypass ? "Blind check" : "Shaping")
            + " stopped — \(interruption.reason)."
        return false
    }

    func toggleSide(_ c: QudelixController) {
        guard phase == .running, stillValid(c) else { return }
        showingA.toggle()
        pushSide(c)
    }

    func choose(preferA: Bool, _ c: QudelixController) {
        answer(preferA ? .preferA : .preferB, c)
    }

    func noDifference(_ c: QudelixController) { answer(.same, c) }

    private func answer(_ answer: ShapeRun.Answer, _ c: QudelixController) {
        guard phase == .running, stillValid(c) else { return }
        switch mode {
        case .shape:
            guard var r = run else { return }
            r.answer(answer)
            run = r
            publish(r)
            if r.finished { finishShape(c) } else { presentTrial(c) }
        case .bypass:
            switch answer {
            case .same: noPreference += 1
            case .preferA: if eqIsA { preferredEQ += 1 } else { preferredFlat += 1 }
            case .preferB: if eqIsA { preferredFlat += 1 } else { preferredEQ += 1 }
            }
            trialsDone += 1
            if trialsDone >= Self.bypassTrials { finishBypass(c) }
            else { presentBypassTrial(c) }
        }
    }

    private func publish(_ r: ShapeRun) {
        values = r.values
        summary = r.summary
        trialsDone = r.trialsDone
        sameTrials = r.sameTrials
        sameGuesses = r.sameGuesses
        skippedTrials = r.skipped
    }

    private func presentTrial(_ c: QudelixController) {
        guard let r = run, let trial = r.trial else { return }
        if let axis = trial.axis {
            isConsistencyCheck = false
            currentTitle = axis.label
            currentDetail = "\(axis.detail) · round \(trial.round) of \(ShapeRun.rounds)"
        } else {
            isConsistencyCheck = true
            currentTitle = "Consistency check"
            currentDetail = "these two may be identical"
        }
        present(trial.a, trial.b, c)
    }

    private func presentBypassTrial(_ c: QudelixController) {
        isConsistencyCheck = false
        currentTitle = "Your EQ, or none"
        currentDetail = "trial \(trialsDone + 1) of \(Self.bypassTrials)"
        eqIsA = chance.coin()
        let flat = ShapeRun.flattened(baseline)
        present(eqIsA ? baseline : flat, eqIsA ? flat : baseline, c)
    }

    private func present(_ a: [QxEqBandValue], _ b: [QxEqBandValue], _ c: QudelixController) {
        curveA = a
        curveB = b
        let matched = LevelMatch.matchedPreGains(a, b, base: sessionPreGain)
        preGainA = matched.a
        preGainB = matched.b
        showingA = true
        pushSide(c)
    }

    private func pushSide(_ c: QudelixController) {
        push(showingA ? curveA : curveB, preGain: showingA ? preGainA : preGainB, c)
    }

    private func push(_ bands: [QxEqBandValue], preGain: Double, _ c: QudelixController) {
        if preGain < devicePreGain {
            writePreGain(preGain, c)
            write(bands, c)
        } else {
            write(bands, c)
            writePreGain(preGain, c)
        }
    }

    private func writePreGain(_ db: Double, _ c: QudelixController) {
        guard abs(db - devicePreGain) >= 0.05 else { return }
        c.setPreGain(db, persistToFlash: false, recordUndo: false)
        devicePreGain = db
    }

    nonisolated static func changedIndices(from before: [QxEqBandValue],
                                           to after: [QxEqBandValue],
                                           limit: Int) -> [Int] {
        (0..<min(limit, after.count)).filter { i in
            i >= before.count || before[i] != after[i]
        }
    }

    private func write(_ bands: [QxEqBandValue], _ c: QudelixController) {
        for i in Self.changedIndices(from: onDevice, to: bands, limit: c.bandCount) {
            c.updateBand(i, bands[i], persistToFlash: false, recordUndo: false)
        }
        onDevice = bands
    }

    private func restoreBaseline(_ c: QudelixController) {
        push(baseline, preGain: baselinePreGain, c)
    }

    private func finishShape(_ c: QudelixController) {
        guard let r = run else { return }
        resultBands = ShapeRun.curve(baseline: baseline, weights: weights, values: r.values)
        curveA = resultBands
        curveB = resultBands
        let matched = LevelMatch.matchedPreGains(resultBands, baseline, base: sessionPreGain)
        preGainA = matched.a
        preGainB = matched.a
        showingA = true
        pushSide(c)
        phase = .finished
    }

    private func finishBypass(_ c: QudelixController) {
        restoreBaseline(c)
        phase = .finished
    }

    enum Verdict: Equatable {
        case unreliable
        case nothingAudible
        case usable
    }

    var verdict: Verdict {
        guard let r = run else { return .nothingAudible }
        if r.consistencyPoor { return .unreliable }
        if r.nothingAudible { return .nothingAudible }
        return .usable
    }

    enum BypassOutcome: Equatable {
        case preferredEQ(Int)
        case preferredFlat(Int)
        case noneSurvived(eq: Int, flat: Int, same: Int)
    }

    var bypassOutcome: BypassOutcome {
        if preferredEQ >= Self.bypassClearMajority { return .preferredEQ(preferredEQ) }
        if preferredFlat >= Self.bypassClearMajority { return .preferredFlat(preferredFlat) }
        return .noneSurvived(eq: preferredEQ, flat: preferredFlat, same: noPreference)
    }

    var maxMovement: Double { ABTuner.movement(from: baseline, to: resultBands) }

    func keepResult(_ c: QudelixController) {
        guard mode == .shape, phase == .finished, verdict == .usable,
              !resultBands.isEmpty else { return }
        write(resultBands, c)
        c.setPreGain(ABTuner.safePreGain(for: resultBands, notAbove: baselinePreGain),
                     recordUndo: false)
        endSession(c)
    }

    func discardResult(_ c: QudelixController) {
        guard phase == .finished else { return }
        restoreBaseline(c)
        endSession(c)
    }

    #if DEBUG
    static func previewBaseline() -> [QxEqBandValue] {
        let gains: [Double] = [4.5, 2.0, -1.5, -0.5, 1.0, -2.0, 2.5, -1.0, 3.0, -2.5]
        return zip(QxEq.defaultFreqs, gains).map {
            QxEqBandValue(filter: .peak, freq: $0, gain: $1, q: 1.0)
        }
    }

    static func previewShape(_ answering: (ShapeRun.Trial) -> ShapeRun.Answer) -> BlindTuner {
        let tuner = BlindTuner()
        let baseline = previewBaseline()
        let weights = weights(for: baseline)
        var r = ShapeRun(baseline: baseline, weights: weights, chance: .seeded(0x5EED))
        while let trial = r.trial { r.answer(answering(trial)) }
        tuner.mode = .shape
        tuner.baseline = baseline
        tuner.weights = weights
        tuner.run = r
        tuner.trialsTotal = r.trialsTotal
        tuner.publish(r)
        tuner.resultBands = ShapeRun.curve(baseline: baseline, weights: weights,
                                           values: r.values)
        tuner.phase = .finished
        return tuner
    }

    static func previewBypass(eq: Int, flat: Int, same: Int) -> BlindTuner {
        let tuner = BlindTuner()
        tuner.mode = .bypass
        tuner.baseline = previewBaseline()
        tuner.trialsTotal = bypassTrials
        tuner.trialsDone = bypassTrials
        tuner.preferredEQ = eq
        tuner.preferredFlat = flat
        tuner.noPreference = same
        tuner.phase = .finished
        return tuner
    }
    #endif
}
