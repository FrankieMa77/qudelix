import Foundation

package enum StageControlGroup: CaseIterable {
    case shape
    case crossBands
    case geometry
    case balance
}

package enum StageControl: CaseIterable {
    case width
    case crossfeed
    case dialogue
    case room
    case night
    case crossLow
    case crossMid
    case crossHigh
    case distance
    case span
    case center
    case size
    case balanceLevel
    case balanceTime
    case loudnessStrength
    case bassGuardStrength
    case impulseMix

    package static func controls(in group: StageControlGroup) -> [StageControl] {
        switch group {
        case .shape: return [.width, .crossfeed, .dialogue, .room, .night]
        case .crossBands: return [.crossLow, .crossMid, .crossHigh]
        case .geometry: return [.distance, .span, .center, .size]
        case .balance: return [.balanceLevel, .balanceTime]
        }
    }

    package var label: String {
        switch self {
        case .width: return "Width"
        case .crossfeed: return "Crossfeed"
        case .dialogue: return "Dialogue"
        case .room: return "Room"
        case .night: return "Night"
        case .crossLow: return "Low"
        case .crossMid: return "Mid"
        case .crossHigh: return "High"
        case .distance: return "Distance"
        case .span: return "Span"
        case .center: return "Center"
        case .size: return "Size"
        case .balanceLevel: return "Level"
        case .balanceTime: return "Time"
        case .loudnessStrength, .bassGuardStrength: return "Strength"
        case .impulseMix: return "Mix"
        }
    }

    package var help: String {
        switch self {
        case .width:
            return "Side-channel level. Dialogue and bass stay centered; ambience and score grow around them."
        case .crossfeed:
            return "Each ear hears a delayed, darkened copy of the other channel, so sound moves out of the middle of your head."
        case .dialogue:
            return "Presence lift on the center channel only, so speech cuts through without sharpening the whole mix."
        case .room:
            return "Sparse early reflections that suggest a room. Subtle on purpose; more is not better."
        case .night:
            return "Evens out movie dynamics: quiet dialogue comes up, explosions come down. Dialogue stays put."
        case .crossLow:
            return "Crossfeed amount below 800 Hz."
        case .crossMid:
            return "Crossfeed amount from 800 Hz to 4 kHz."
        case .crossHigh:
            return "Crossfeed amount above 4 kHz."
        case .distance:
            return "Pushes the sources away from your head: the room's first reflection arrives later and the direct sound eases slightly."
        case .span:
            return "The virtual speaker angle the crossfeed simulates. A wider span spreads the sources further apart."
        case .center:
            return "Level of the center image. Cramped stages are usually center-heavy: pull it back a little and the sides get room to breathe."
        case .size:
            return "Scales the whole room: reflection distances and the tail's decay paths."
        case .balanceLevel:
            return "Level difference between the two sides. Half of it goes to each side, so the balance changes and the volume does not."
        case .balanceTime:
            return "Arrival-time difference between the two sides. The side shown is the one held back."
        case .loudnessStrength:
            return "Scales the whole contour. 100 % is the full correction the estimated level asks for."
        case .bassGuardStrength:
            return "Scales the ceiling: at 100 % the loudest passages can lose the whole boost the 5K is adding, at 50 % half of it."
        case .impulseMix:
            return "How much of the convolved signal is blended with the dry one. 100 % is the response alone."
        }
    }

    package var range: ClosedRange<Double> {
        switch self {
        case .width: return 0...200
        case .dialogue: return 0...6
        case .center: return -6...3
        case .balanceLevel: return -3...3
        case .balanceTime: return -0.5...0.5
        default: return 0...100
        }
    }

    package var step: Double {
        switch self {
        case .dialogue, .center: return 0.5
        case .balanceLevel: return 0.1
        case .balanceTime: return 0.01
        default: return 1
        }
    }

    package var hasReset: Bool {
        self == .balanceLevel || self == .balanceTime
    }

    package var neutral: Double {
        switch self {
        case .balanceLevel, .balanceTime: return 0
        default: return range.lowerBound
        }
    }

    package func value(_ s: StageSettings) -> Double {
        switch self {
        case .width: return s.width
        case .crossfeed: return s.crossfeed * 100
        case .dialogue: return s.dialogue
        case .room: return s.room * 100
        case .night: return s.nightValue * 100
        case .crossLow: return s.crossLowTrimValue * 100
        case .crossMid: return s.crossMidTrimValue * 100
        case .crossHigh: return s.crossHighTrimValue * 100
        case .distance: return s.distanceValue * 100
        case .span: return s.spanValue * 100
        case .center: return s.centerValue
        case .size: return s.sizeValue * 100
        case .balanceLevel: return s.balanceDbValue
        case .balanceTime: return s.alignMsValue
        case .loudnessStrength: return s.loudnessStrengthValue * 100
        case .bassGuardStrength: return s.bassGuardStrengthValue * 100
        case .impulseMix: return s.impulseMixValue * 100
        }
    }

    package func quantized(_ raw: Double) -> Double {
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        let snapped = (clamped / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    package func apply(_ raw: Double, to s: inout StageSettings) {
        let v = quantized(raw)
        switch self {
        case .width: s.width = v
        case .crossfeed: s.crossfeed = v / 100
        case .dialogue: s.dialogue = v
        case .room: s.room = v / 100
        case .night: s.night = v / 100
        case .crossLow: s.crossLowTrim = v / 100
        case .crossMid: s.crossMidTrim = v / 100
        case .crossHigh: s.crossHighTrim = v / 100
        case .distance: s.distance = v / 100
        case .span: s.span = v / 100
        case .center: s.center = v
        case .size: s.size = v / 100
        case .balanceLevel: s.balanceDb = v
        case .balanceTime: s.alignMs = v
        case .loudnessStrength: s.loudnessStrength = v / 100
        case .bassGuardStrength: s.bassGuardStrength = v / 100
        case .impulseMix: s.impulseMix = v / 100
        }
    }

    package func display(_ s: StageSettings) -> String {
        let v = value(s)
        switch self {
        case .dialogue: return String(format: "+%.1f dB", v)
        case .center: return DisplayFormat.decibels(v)
        case .balanceLevel:
            if v == 0 { return "centered" }
            return String(format: "%@ +%.1f dB", v > 0 ? "R" : "L", abs(v))
        case .balanceTime:
            if v == 0 { return "aligned" }
            return String(format: "%@ +%.2f ms", v > 0 ? "R" : "L", abs(v))
        default: return String(format: "%.0f %%", v)
        }
    }
}

package enum StagePresetChoice: CaseIterable {
    case music
    case movie
    case theater

    package var title: String {
        switch self {
        case .music: return "Music"
        case .movie: return "Movie"
        case .theater: return "Theater"
        }
    }

    package var settings: StageSettings {
        switch self {
        case .music: return .music
        case .movie: return .movie
        case .theater: return .theater
        }
    }

    package func isSelected(_ s: StageSettings) -> Bool {
        s.enabled && s.audiblyEquals(settings)
    }
}

package struct StageNotice: Equatable {
    package var text: String
    package var caution: Bool

    package init(text: String, caution: Bool) {
        self.text = text
        self.caution = caution
    }
}

@MainActor
package enum StagePresentation {
    package static let stageOutputName = LinuxAudioNames.stageSinkDescription
    package static let mono = "What is playing right now is mono: identical left and right. Width and Crossfeed "
        + "have nothing to work with; only Dialogue, Room and Balance can act. Try a stereo source to hear the stage."
    package static let crossBandsFootnote = "Each of these scales the Crossfeed amount inside one range. "
        + "100 % everywhere is the plain Crossfeed above."
    package static let balanceFootnote = "For a real mismatch between the two sides: a pair that has drifted apart, "
        + "or one ear that hears less than the other. It acts on mono content too."
    package static let offHint = "Stage is off. Moving a control turns it on. "
    package static let noOutput = "No output device found"

    package static func outputLabel(_ state: StageModelState) -> String {
        guard let name = state.outputDescription else { return noOutput }
        return "Settings for " + name
    }

    package static func perOutputNote(_ state: StageModelState) -> String {
        guard let name = state.outputDescription else {
            return "Stage settings are remembered per output device. Connect or select an output to edit its settings."
        }
        return "These settings belong to \(name) only. Every other output keeps its own, so switching outputs "
            + "switches the settings with it."
    }

    package static func routingExplanation(_ state: StageModelState) -> String {
        let target = state.outputDescription ?? "the real output"
        let how = "While Stage is on, a \u{201C}\(stageOutputName)\u{201D} output becomes the system default and "
            + "all sound goes through it to \(target). The previous default is restored when Stage turns off, "
            + "when the real output disappears and when the app quits."
        let limits = " It works on the stereo mix: surround content stays downmixed and the sound does not track "
            + "your head. The 5K's own EQ stays untouched on the device."
        if state.mode == .insert, state.routed {
            return "Stage is active. " + how + limits
        }
        return how + limits
    }

    package static func statusNotice(_ state: StageModelState) -> StageNotice? {
        if let failure = state.failure { return StageNotice(text: failure.message, caution: true) }
        if state.callHold { return StageNotice(text: state.status, caution: false) }
        guard state.settings.enabled else { return nil }
        if state.outputKey == nil { return StageNotice(text: "No output device is available for Stage to run on.", caution: true) }
        guard state.status != "Off." else { return nil }
        return StageNotice(text: state.status, caution: false)
    }

    package static let impulseWaitingText =
        "The impulse response is waiting for a compatible audio buffer size, so it isn\u{2019}t in the sound yet."

    package static func notices(_ state: StageModelState) -> [StageNotice] {
        var result: [StageNotice] = []
        if let notice = state.settingsNotice { result.append(StageNotice(text: notice, caution: true)) }
        if let status = statusNotice(state) { result.append(status) }
        if let problem = state.impulseProblem { result.append(StageNotice(text: problem, caution: true)) }
        if let notice = state.audioNotice { result.append(StageNotice(text: notice, caution: true)) }
        if state.settings.enabled, state.settings.hasImpulse, state.impulseWaiting {
            result.append(StageNotice(text: impulseWaitingText, caution: false))
        }
        if state.settings.enabled, let corr = state.sourceCorrelation, corr > 0.985 {
            result.append(StageNotice(text: mono, caution: true))
        }
        return result
    }

    package static func bandTrimSummary(_ s: StageSettings) -> String? {
        guard s.crossLowTrimValue != 1 || s.crossMidTrimValue != 1 || s.crossHighTrimValue != 1 else { return nil }
        return String(format: "%.0f / %.0f / %.0f %%", s.crossLowTrimValue * 100,
                      s.crossMidTrimValue * 100, s.crossHighTrimValue * 100)
    }

    package static func limiterNote(_ state: StageModelState) -> String {
        guard state.settings.enabled else {
            return offHint + "With the stage off this app is not in the audio path at all, so it has no output of its own to protect."
        }
        let rate = AudioOutputs.plausibleRate(state.runningRate ?? StageModel.defaultGraphRate)
        let latency = Double(StageProcessor.limLookahead) / rate * 1000
        return String(format: "Protects the Stage's own output at \u{2212}1 dBTP, counting the peaks that land between "
                      + "samples, the ones a lossy encoder clips on. Adds %d samples of latency: %.1f ms at %g kHz.",
                      StageProcessor.limLookahead, latency, rate / 1000)
    }

    package static func loudnessAmount(_ state: StageModelState) -> String {
        state.loudnessShelfDb > 0.05 ? String(format: "+%.1f dB bass", state.loudnessShelfDb) : "flat"
    }

    package static func loudnessNote(_ state: StageModelState, level: LevelModelState) -> String {
        guard state.settings.enabled else {
            return offHint + "With the stage off this app is not in the audio path at all, so it has nothing to shape."
        }
        let what = String(format: "Quiet listening loses bass first, and a little treble with it. This raises both "
                          + "back while the estimated level at your ear sits below the %.0f dB reference, and eases "
                          + "off as you turn up.", EarLevel.referenceDb)
        guard state.running else { return what }
        if level.earAnchor == nil {
            return what + " Holding flat for now: it rests on the estimate on the Level page, and this output "
                + "offers no volume reading to anchor one."
        }
        if level.earLevelAverageDb == nil {
            return what + " Holding flat until the estimate on the Level page settles. It averages about half a "
                + "minute of playback, so the shelf follows the listening level rather than the chorus."
        }
        return what + " It rests on the estimate on the Level page, which is measured before this shelf so the two "
            + "can never chase each other."
    }

    package static func bassGuardAmount(_ state: StageModelState) -> String {
        let reduction = state.bassGuardGainReductionDb
        if reduction > 0.1 { return String(format: "\u{2212}%.1f dB", reduction) }
        return String(format: "up to \u{2212}%.1f dB", state.bassGuardCeilingDb)
    }

    package static func bassGuardCeilingHelp(_ state: StageModelState) -> String {
        String(format: "The deepest cut the guard may make, measured off the 5K's own curve: it peaks at +%.1f dB "
               + "below 200 Hz, and the Strength slider scales what that buys.", state.bassGuardBoostDb)
    }

    package static func bassGuardNote(_ state: StageModelState) -> String {
        guard state.settings.enabled else {
            return offHint + "With the stage off this app is not in the audio path at all, so it has nothing to ease."
        }
        let what = "Eases the low band on loud passages only, here and ahead of the bass the 5K's EQ adds after "
            + "this app, so quiet passages keep the whole boost and the loudest ones stop asking the driver for "
            + "all of it at once."
        guard state.settings.bassGuardValue else { return what }
        if state.bassGuardInert {
            return "Nothing to guard: the 5K's curve boosts no bass, so this stands down rather than shaving a band "
                + "nobody lifted."
        }
        return what
    }

    package static func impulseDetail(_ state: StageModelState) -> String? {
        guard state.settings.hasImpulse, let info = state.impulse else { return nil }
        var parts = [String(format: "%.2f s", info.seconds),
                     info.channels == 1 ? "mono, both ears" : "stereo, one per side",
                     String(format: "%g kHz file", info.sourceRate / 1000)]
        if case .ready(let partitions, _, let hop, let rate) = state.impulseState {
            parts.append(String(format: "%d \u{00D7} %d at %g kHz", partitions, hop, rate / 1000))
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    package static func impulseNote(_ state: StageModelState) -> String {
        guard state.settings.enabled else {
            return offHint + "With the stage off this app is not in the audio path at all, so it has nothing to convolve."
        }
        return "Convolves what is playing with a response of your own: a headphone correction, a room measurement, "
            + "a reverb. A stereo file applies one response per side; a mono one applies the same response to "
            + "both. The response is partitioned uniformly at the size the audio graph hands this app, so however "
            + "long it is it adds no latency at all. WAV files only (PCM 16, 24 or 32 bit, or 32-bit float), up to "
            + String(format: "%.0f seconds.", ImpulseLimits.maxSeconds)
    }

    package static func impulseTitle(_ state: StageModelState) -> String {
        guard state.settings.hasImpulse, let info = state.impulse else { return "None" }
        return info.displayName
    }

    package static let impulseDialogTitle = "Choose an impulse response"
}
