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

/// Blind A/B EQ preference tuning.
///
/// Why preference rather than a hearing test: a threshold test through an
/// uncalibrated headphone measures the listener's ears, the headphone's own
/// response and the volume setting all mixed together — and the dominant term is
/// the normal shape of human hearing, which must not be equalised away. Asking
/// "which of these two do you prefer, on your own music" measures the thing we
/// actually want to set, and needs no calibration at all.
///
/// Method, and the reasons that matter more than the search itself:
///
/// - Four broad tilts rather than ten independent bands. Preference tracks a few
///   macro shapes; a ten-dimensional search would never converge in a sitting.
/// - Binary search per tilt: present two curves either side of the current
///   centre, move toward the winner, halve the step. Four rounds takes ±6 dB
///   down to ±0.75 dB.
/// - Which side carries the higher setting is randomised per trial, so the
///   listener cannot learn the pattern.
/// - One trial per round presents the same curve twice. Naming a winner there is
///   a preference for nothing, and the result says so rather than pretending
///   otherwise.
///
/// The tilts are applied on top of whatever curve is already loaded, so this
/// refines the user's own setup instead of replacing it. The original is restored
/// if the session is cancelled or the result discarded.
@MainActor
final class ABTuner: ObservableObject {
    struct Macro {
        let name: String
        let detail: String
        let shape: [Double]     // weight per band, 31 Hz … 16 kHz
        let range: Double       // ± dB explored
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
    /// Per-band ceiling for the tilt itself, on top of the existing curve.
    static let tiltCap = 6.0
    /// Each round is the four macros plus one identical pair.
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
    /// Identical pairs presented, and how many of them the listener named a
    /// winner on instead of answering "sound the same".
    @Published private(set) var sameTrials = 0
    @Published private(set) var sameGuesses = 0
    /// Macros the listener could not hear, zeroed rather than guessed at.
    @Published private(set) var inaudible: Set<String> = []
    @Published private(set) var note: String?

    /// What was loaded before the session, restored on cancel or discard.
    private var baseline: [QxEqBandValue] = []
    private var baselinePreGain: Double = 0
    private var sessionPreGain: Double = 0
    private var sessionGroup: QxEqGroup = .user

    private var steps: [String: Double] = [:]
    /// How often the listener could not tell the two options apart, per macro.
    private var indifferent: [String: Int] = [:]
    private var queue: [String?] = []          // nil = consistency check
    private var curveA: [QxEqBandValue] = []
    private var curveB: [QxEqBandValue] = []
    private var preGainA: Double = 0
    private var preGainB: Double = 0
    private var devicePreGain: Double = 0
    private var highIsA = true
    private var chance: Chance = .real

    // MARK: - Preconditions

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

    /// Refusing to run in HFP matters: at 16 kHz narrowband the listener would be
    /// comparing EQ curves through a voice codec, which invalidates the session.
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

    // MARK: - Session

    /// A pre-gain low enough that `bands` cannot clip, never louder than the
    /// user already had it.
    ///
    /// It is the peak of the *summed* response that matters, not the largest
    /// single band gain: overlapping bands add, a shelf overshoots its nominal
    /// corner, and a resonant low-pass has gain of its own. Reading one band
    /// under-reports on exactly the curves with the least headroom left, which
    /// is where the whole point of a fixed session pre-gain fails.
    ///
    /// `plusBoost` is what the trials themselves may add on top of the curve
    /// being measured; a result that is simply being kept adds nothing.
    ///
    /// Lives here as a pure function so it can be tested without a device — it
    /// was previously inline in `start`, which is why it went wrong unnoticed.
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
        // One step for the whole session, taken before anything moves.
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

        // Exactly one identical pair per round, dropped at an unpredictable
        // position inside it. Sprinkling them at a fixed probability, as this
        // used to, left the count to chance: nearly half of sessions drew fewer
        // than the three the check needs to tell one impatient answer from a
        // habit, and the occasional session drew a dozen for no extra insight.
        // Fixing the count also makes the session exactly twenty trials, which
        // is what the intro promises.
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

    /// Swap which of the two candidates is playing. The listener can do this as
    /// often as they like before committing.
    func toggleSide(_ c: QudelixController) {
        guard phase == .running, stillValid(c) else { return }
        showingA.toggle()
        pushSide(c)
    }

    /// "They sound the same." Halves the step without moving the centre, so
    /// indifference narrows the search instead of nudging it somewhere arbitrary.
    ///
    /// Without this the listener has to guess, and a guess moves the centre — so
    /// someone with no preference in a band ends up with a tilt of up to half the
    /// search range purely from coin flips.
    func noDifference(_ c: QudelixController) {
        guard phase == .running, stillValid(c) else { return }
        if isConsistencyCheck {
            // The right answer on an identical pair: counted, but not held
            // against the listener.
            sameTrials += 1
        } else if let name = currentMacroName,
                  let m = Self.macros.first(where: { $0.name == name }) {
            let step = steps[name] ?? m.range
            // Only a WIDE step tells us anything. Failing to hear a 0.4 dB
            // difference is expected and says nothing about whether the parameter
            // matters — counting it was zeroing macros the listener did care
            // about, and got worse the more rounds were run.
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
            // Both curves are the same one, so which side was picked carries no
            // information — that a side was picked at all is the whole finding.
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
            // Identical pair: whatever the listener says here is noise.
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
        // A macro the listener repeatedly could not hear is not a preference.
        // Applying whatever the search happened to land on would be inventing one.
        // Two wide-step trials are all there are, so this means "could not hear
        // it at either of the coarse settings".
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

    // MARK: - Result handling

    /// The four values for display, with their common average removed.
    ///
    /// Raising all four tilts together changes the audible curve by under a third
    /// of a decibel, so the raw values are not uniquely determined — a listener
    /// who only wanted less presence can legitimately come out as "everything
    /// else up". Showing that verbatim reads as nonsense. This is presentation
    /// only: `resultBands`, which is what actually gets written, is untouched.
    var displayValues: [String: Double] {
        let vs = Self.macros.map { values[$0.name] ?? 0 }
        let mean = vs.reduce(0, +) / Double(max(1, vs.count))
        return Dictionary(uniqueKeysWithValues: Self.macros.map {
            ($0.name, (values[$0.name] ?? 0) - mean)
        })
    }

    /// How far the session moved the curve, in dB.
    ///
    /// The distance between the finished curve and the baseline, not the height
    /// of the finished curve. Tilts are applied on top of whatever was already
    /// loaded, so a session run over an imported correction — the normal case —
    /// inherits several decibels that it did not put there. Reading those meant
    /// "this session found nothing" could never be said out loud, which is
    /// exactly the case where the listener most needs to hear it.
    ///
    /// Judged on the applied curve rather than the four parameters, because the
    /// parameters are not uniquely determined and the clamps in `curve` can
    /// swallow part of a tilt that had nowhere left to go.
    var maxMovement: Double { Self.movement(from: baseline, to: resultBands) }

    nonisolated static func movement(from baseline: [QxEqBandValue],
                                     to result: [QxEqBandValue]) -> Double {
        zip(baseline, result).map { abs($1.gain - $0.gain) }.max() ?? 0
    }

    /// Fewest identical pairs that can support a judgement.
    ///
    /// Naming a winner on an identical pair is a direct observation, not a coin
    /// flip, so it does not need many samples to mean something — but anyone can
    /// press the wrong button once in twenty trials, and one observation cannot
    /// separate that slip from a habit. Three can. The session schedules four.
    nonisolated static let minChecksToJudge = 3

    /// True when the listener repeatedly named a winner between two identical
    /// curves.
    ///
    /// What the check is for is over-claiming: the pairs are the same curve
    /// twice, so a preference expressed on one is a preference for nothing, and
    /// the same readiness to answer will have shaped the real trials. "Sound the
    /// same" is the correct answer, and a listener who gives it every time
    /// scores zero here — this once read the count the other way round and told
    /// precisely those listeners that their session was unreliable.
    ///
    /// A majority rather than a single instance, for the reason above; and
    /// silence rather than a verdict when there are too few pairs to tell the
    /// difference.
    var consistencyPoor: Bool {
        Self.consistencyPoor(guesses: sameGuesses, of: sameTrials)
    }

    nonisolated static func consistencyPoor(guesses: Int, of trials: Int) -> Bool {
        trials >= minChecksToJudge && guesses * 2 > trials
    }

    func keepResult(_ c: QudelixController) {
        guard phase == .finished, !resultBands.isEmpty, stillValid(c) else { return }
        // Leave the curve applied, but hand pre-gain back to the user's value if
        // the result does not actually need the extra headroom.
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

    // MARK: - Curve building

    /// A macro's weight at an arbitrary frequency.
    ///
    /// The `shape` arrays are authored against the ten-band layout, one weight
    /// per band. Applying them by *index* only works if the bands are that
    /// layout — in 20-band mode index 6-9 are 250-710 Hz, so the "Treble"
    /// macro was tilting the lower midrange and the top ten bands were never
    /// touched at all. Interpolating on log frequency makes a macro mean the
    /// same thing in either mode, which is what its name promises.
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

    /// The listener's own curve plus the macro tilt, loudness-matched.
    ///
    /// Sized from the baseline, so it covers whichever group is live rather
    /// than always the first ten bands.
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

    /// Write a trial curve.
    ///
    /// Neither persisted to the device's flash nor recorded as undo steps. A
    /// trial is a question, not a decision: committing twenty of them burns
    /// flash and leaves the last one surviving a power cycle, and recording
    /// each band of each trial buried the pre-session curve under two hundred
    /// entries in a forty-deep history. The session takes one step, opened by
    /// `start`, and Keep or Discard is what the user actually undoes.
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
