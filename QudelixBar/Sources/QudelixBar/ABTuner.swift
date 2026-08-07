import Foundation
import SwiftUI

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
/// - Every candidate is loudness-matched, and pre-gain is fixed for the whole
///   session. Without that the listener simply prefers whichever is louder and
///   the result is meaningless.
/// - Which side carries the higher setting is randomised per trial, so the
///   listener cannot learn the pattern.
/// - Some trials present the same curve twice. Preferences expressed on those
///   measure noise, and the result says so rather than pretending otherwise.
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
    @Published private(set) var samePreferred = 0
    /// Macros the listener could not hear, zeroed rather than guessed at.
    @Published private(set) var inaudible: Set<String> = []

    /// What was loaded before the session, restored on cancel or discard.
    private var baseline: [QxEqBandValue] = []
    private var baselinePreGain: Double = 0
    private var sessionPreGain: Double = 0

    private var steps: [String: Double] = [:]
    /// How often the listener could not tell the two options apart, per macro.
    private var indifferent: [String: Int] = [:]
    private var queue: [String?] = []          // nil = consistency check
    private var curveA: [QxEqBandValue] = []
    private var curveB: [QxEqBandValue] = []
    private var highIsA = true

    // MARK: - Preconditions

    enum Blocker: Equatable {
        case notConnected
        case unsupported
        case voiceCall

        var message: String {
            switch self {
            case .notConnected: return "Connect the 5K first."
            case .unsupported: return "This device isn't supported, so nothing can be written."
            case .voiceCall:
                return "The link is in hands-free (voice) mode at 16 kHz. "
                    + "Audio quality is too low to judge — close whatever is using the microphone."
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
        return nil
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

    func start(_ c: QudelixController) {
        guard Self.blocker(c) == nil else { return }

        baseline = c.bands
        baselinePreGain = c.preGain
        values = Dictionary(uniqueKeysWithValues: Self.macros.map { ($0.name, 0.0) })
        steps = Dictionary(uniqueKeysWithValues: Self.macros.map { ($0.name, $0.range) })
        sameTrials = 0; samePreferred = 0; trialsDone = 0; round = 1
        inaudible = []
        indifferent = Dictionary(uniqueKeysWithValues: Self.macros.map { ($0.name, 0) })

        // One fixed pre-gain for the whole session, low enough that the loudest
        // tilt cannot clip. Fixed because a pre-gain that moved between options
        // would be a loudness cue, and loudness beats timbre every time.
        sessionPreGain = Self.safePreGain(for: baseline,
                                          notAbove: baselinePreGain,
                                          plusBoost: Self.tiltCap)

        queue = []
        for _ in 1...Self.rounds {
            for m in Self.macros {
                queue.append(m.name)
                if Int.random(in: 0..<6) == 0 { queue.append(nil) }
            }
        }
        trialsTotal = queue.count

        c.setPreGain(sessionPreGain)
        phase = .running
        nextTrial(c)
    }

    func cancel(_ c: QudelixController) {
        restoreBaseline(c)
        phase = .idle
    }

    /// Swap which of the two candidates is playing. The listener can do this as
    /// often as they like before committing.
    func toggleSide(_ c: QudelixController) {
        guard phase == .running else { return }
        showingA.toggle()
        apply(showingA ? curveA : curveB, to: c)
    }

    /// "They sound the same." Halves the step without moving the centre, so
    /// indifference narrows the search instead of nudging it somewhere arbitrary.
    ///
    /// Without this the listener has to guess, and a guess moves the centre — so
    /// someone with no preference in a band ends up with a tilt of up to half the
    /// search range purely from coin flips.
    func noDifference(_ c: QudelixController) {
        guard phase == .running else { return }
        if isConsistencyCheck {
            sameTrials += 1                      // correct answer on an identical pair
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
        guard phase == .running else { return }
        let preferredHigh = (preferA == highIsA)

        if isConsistencyCheck {
            sameTrials += 1
            if preferredHigh { samePreferred += 1 }
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
        round = min(Self.rounds, trialsDone / max(1, Self.macros.count) + 1)

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
            highIsA = Bool.random()
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
            highIsA = Bool.random()
        }

        showingA = true
        apply(curveA, to: c)
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
        apply(resultBands, to: c)
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

    var maxTilt: Double {
        // Judged on the curve actually applied, not on the degenerate parameters.
        resultBands.isEmpty ? 0 : (resultBands.map { abs($0.gain) }.max() ?? 0)
    }

    /// True when the listener answered identical pairs as if they differed, which
    /// means the differences were below what they could hear.
    var consistencyPoor: Bool {
        sameTrials >= 2 && (samePreferred == sameTrials || samePreferred == 0)
    }

    func keepResult(_ c: QudelixController) {
        // Leave the curve applied, but hand pre-gain back to the user's value if
        // the result does not actually need the extra headroom.
        c.setPreGain(Self.safePreGain(for: resultBands, notAbove: baselinePreGain))
        phase = .idle
    }

    func discardResult(_ c: QudelixController) {
        restoreBaseline(c)
        phase = .idle
    }

    private func restoreBaseline(_ c: QudelixController) {
        c.setPreGain(baselinePreGain)
        apply(baseline, to: c)
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
        var tilt = [Double](repeating: 0, count: count)
        for m in Self.macros {
            let amount = v[m.name] ?? 0
            guard amount != 0 else { continue }
            for i in 0..<count {
                tilt[i] += amount * Self.weight(m.shape, atHz: baseline[i].freq)
            }
        }
        // Remove the average so a tilt never changes overall loudness.
        let mean = tilt.reduce(0, +) / Double(count)
        var out: [QxEqBandValue] = []
        for i in 0..<count {
            var band = baseline[i]
            let shaped = min(max(tilt[i] - mean, -Self.tiltCap), Self.tiltCap)
            band.gain = min(max(band.gain + shaped, -12), 12)
            out.append(band)
        }
        return out
    }

    private func apply(_ bands: [QxEqBandValue], to c: QudelixController) {
        for (i, b) in bands.enumerated() where i < c.bandCount { c.updateBand(i, b) }
    }
}
