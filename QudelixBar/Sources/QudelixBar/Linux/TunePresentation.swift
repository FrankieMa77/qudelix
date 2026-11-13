import Foundation

package struct TuneRow: Equatable {
    package var title: String
    package var detail: String
    package var value: String
    package var fraction: Double
    package var muted: Bool
    package var hasBar: Bool
}

package struct TuneScreen: Equatable {
    package var method: TuneMethod
    package var phase: TunePhase
    package var headline = ""
    package var paragraphs: [String] = []
    package var footnotes: [String] = []
    package var cautions: [String] = []
    package var restoreLine: String?
    package var blocker: String?
    package var rowsTitle: String?
    package var rows: [TuneRow] = []
    package var rowsDimmed = false
    package var detail = ""
    package var progressText = ""
    package var progressFraction = 0.0
    package var playingLabel = ""
    package var catchSummary: String?
    package var keepLabel: String?
    package var discardLabel = ""
    package var startEnabled = false
    package var canListenAndChoose = false
    package var isTones: Bool { method == .tones }
}

@MainActor
package enum TunePresentation {
    package static let pickerLabel = "Tuning method"
    package static let switchLabel = "Switch"
    package static let switchAccessible = "Switch between A and B"
    package static let preferALabel = "Prefer A"
    package static let preferBLabel = "Prefer B"
    package static let sameLabel = "Sound the same"
    package static let stopLabel = "Stop"
    package static let startLabel = "Start"
    package static let heardLabel = "I hear it"
    package static let heardHelp = "Press the moment you hear anything, however faint. Silence is normal."
    package static let switchHelp = "Switch as often as you like, then choose. Space switches, Enter confirms the focused button, and Space presses Stop when Stop has focus."
    package static let toneSessionHelp = "Press Space or the button the moment you hear anything, however faint. Silence is normal."
    package static let sessionBadge = "Session running"
    package static let restoreText = "Your EQ was put back the way it was before the session."

    package static func title(_ method: TuneMethod) -> String {
        switch method {
        case .compare: return "Compare"
        case .shape: return "Shape"
        case .tones: return "Tones"
        case .check: return "Blind"
        case .trim: return "Trim"
        }
    }

    package static func accessibleName(_ method: TuneMethod) -> String {
        "\(title(method)) method"
    }

    package static func summary(_ method: TuneMethod) -> String {
        switch method {
        case .compare: return "Pick the EQ you prefer, 20 comparisons"
        case .shape: return "Bass, presence and tilt by ear, 12 comparisons"
        case .tones: return "Measure what you can hear with faint tones"
        case .check: return "Your EQ against flat, blind, 5 comparisons"
        case .trim: return "Your EQ against Auto-trim, blind, 5 comparisons"
        }
    }

    package static func trialText(done: Int, total: Int) -> String {
        "\(min(done + 1, total)) / \(total)"
    }

    package static func hertz(_ hz: Int) -> String {
        hz >= 1000 ? "\(hz / 1000) kHz" : "\(hz) Hz"
    }

    package static func shortHertz(_ hz: Int) -> String {
        hz >= 1000 ? "\(hz / 1000)k" : "\(hz)"
    }

    package static func sanityCheck(pairs: Int, guesses: Int) -> String {
        let repeated = pairs == 1
            ? "1 pair was the same setting twice"
            : "\(pairs) pairs were the same setting twice"
        return "Sanity check: " + repeated + "; you called a winner in \(guesses)."
    }

    package static func shapeConsistency(pairs: Int, guesses: Int, skipped: Int) -> String {
        let base = sanityCheck(pairs: pairs, guesses: guesses)
        guard skipped > 0 else { return base }
        let text = skipped == 1
            ? "1 step too small for the device to store"
            : "\(skipped) steps too small for the device to store"
        return base + " \u{00B7} " + text
    }

    package static func catchSummary(played: Int, falsePresses: Int) -> String {
        let checks = played == 1 ? "1 silent check" : "\(played) silent checks"
        let presses = falsePresses == 1 ? "1 press on silence" : "\(falsePresses) presses on silence"
        return "\(checks), \(presses)"
    }

    package static func trialsSummary(eq: Int, flat: Int, same: Int, eqName: String, flatName: String) -> String {
        "\(eq) for \(eqName) \u{00B7} \(flat) for \(flatName) \u{00B7} \(same) sounded the same"
    }

    package static func isRestoreNote(_ note: String) -> Bool {
        note.contains("stopped")
    }

    package static func screen(_ method: TuneMethod, _ state: TuneState) -> TuneScreen {
        var screen = TuneScreen(method: method, phase: phase(of: method, state))
        screen.blocker = state.blockers[method] ?? state.busy
        screen.startEnabled = screen.blocker == nil
        let note = note(of: method, state)
        if screen.phase == .idle, let note {
            screen.cautions.append(note)
            if isRestoreNote(note) { screen.restoreLine = restoreText }
        }
        switch (method, screen.phase) {
        case (.compare, .idle): compareIdle(&screen)
        case (.compare, .running): sideRunning(&screen, state.compare)
        case (.compare, .finished): compareFinished(&screen, state.compare)
        case (.shape, .idle): shapeIdle(&screen)
        case (.shape, .running): sideRunning(&screen, state.shape)
        case (.shape, .finished): shapeFinished(&screen, state.shape)
        case (.check, .idle): checkIdle(&screen)
        case (.check, .running): sideRunning(&screen, state.check)
        case (.check, .finished): bypassFinished(&screen, state.check, trim: false)
        case (.trim, .idle): trimIdle(&screen, state)
        case (.trim, .running): sideRunning(&screen, state.trim)
        case (.trim, .finished): bypassFinished(&screen, state.trim, trim: true)
        case (.tones, .idle): tonesIdle(&screen)
        case (.tones, .running): tonesRunning(&screen, state.tones)
        case (.tones, .finished): tonesFinished(&screen, state.tones)
        }
        if screen.phase == .idle, screen.blocker != nil { screen.footnotes = [] }
        return screen
    }

    private static func phase(of method: TuneMethod, _ state: TuneState) -> TunePhase {
        switch method {
        case .compare: return state.compare.phase
        case .shape: return state.shape.phase
        case .check: return state.check.phase
        case .trim: return state.trim.phase
        case .tones: return state.tones.phase
        }
    }

    private static func note(of method: TuneMethod, _ state: TuneState) -> String? {
        switch method {
        case .compare: return state.compare.note
        case .shape: return state.shape.note
        case .check: return state.check.note
        case .trim: return state.trim.note
        case .tones: return state.tones.note
        }
    }

    private static func compareIdle(_ screen: inout TuneScreen) {
        screen.headline = "Find the EQ you prefer"
        screen.paragraphs = [
            "Play music you know, then pick which of two settings sounds better. "
                + "Both are loudness-matched and unlabelled, so you can't simply prefer the louder one."
        ]
        screen.footnotes = ["Twenty comparisons. Your current EQ comes back if you stop."]
    }

    private static func shapeIdle(_ screen: inout TuneScreen) {
        screen.headline = "Settle three controls by ear"
        screen.paragraphs = [
            "Bass, then presence, then overall tilt \u{2014} one at a time, starting from a wide "
                + "difference and halving it each round. Blind pairs, loudness-matched, and much "
                + "shorter than Compare.",
            "The 5K's band centres are fixed, so each control is spread across them. What you hear "
                + "is already that spread-out version \u{2014} the curve a Keep would write, not an ideal shelf."
        ]
        screen.footnotes = [
            "Twelve comparisons, three of them repeats of one setting. Your current EQ comes back if you stop."
        ]
    }

    private static func checkIdle(_ screen: inout TuneScreen) {
        screen.headline = "Check your EQ blind"
        screen.paragraphs = [
            "Five times: your EQ, or a flat one. Which side is which is hidden and the two are "
                + "loudness-matched, so the only thing left to prefer is the curve itself."
        ]
        screen.footnotes = [
            "Nothing is written either way. Your bands and pre-gain come back exactly as they are now, "
                + "whichever way the answers fall."
        ]
    }

    private static func trimIdle(_ screen: inout TuneScreen, _ state: TuneState) {
        screen.headline = "Hear what Auto-trim does"
        screen.paragraphs = [
            "Five times: your EQ with Auto-trim's current trim on top, or your EQ as it is. Which side "
                + "is which is hidden and the two are loudness-matched, so the only thing left to prefer "
                + "is the trim itself."
        ]
        if screen.blocker == nil, let now = state.trimNow {
            screen.paragraphs.append("Trim now: " + now)
        }
        screen.footnotes = [
            "The trim is frozen when you start and Auto-trim waits. Your bands and pre-gain come back "
                + "exactly as they are now, whichever way the answers fall."
        ]
    }

    private static func tonesIdle(_ screen: inout TuneScreen) {
        screen.headline = "Measure what you can hear"
        screen.paragraphs = [
            "Faint tones at ten frequencies. Press the button whenever you hear one \u{2014} some are "
                + "silent on purpose. Needs a quiet room and about five minutes."
        ]
        screen.footnotes = [
            "Set a comfortable listening volume first \u{2014} the tones are quiet, but they are relative "
                + "to it. EQ is switched off while measuring, then restored."
        ]
        screen.cautions = [ToneTestModel.levelCaution]
    }

    private static func sideRunning(_ screen: inout TuneScreen, _ side: TuneSideState) {
        screen.headline = side.isConsistencyCheck ? "Checking" : side.title
        screen.detail = side.detail
        screen.progressText = trialText(done: side.trialsDone, total: side.trialsTotal)
        screen.progressFraction = Double(side.trialsDone) / Double(max(1, side.trialsTotal))
        screen.playingLabel = side.showingA ? "A" : "B"
        screen.footnotes = [switchHelp]
        screen.canListenAndChoose = true
        screen.discardLabel = stopLabel
    }

    private static func compareFinished(_ screen: inout TuneScreen, _ side: TuneSideState) {
        screen.headline = "The balance you preferred"
        screen.paragraphs = [sanityCheck(pairs: side.sameTrials, guesses: side.sameGuesses)]
        screen.rows = ABTuner.macros.map { macro in
            let inaudible = side.inaudible.contains(macro.name)
            let value = inaudible ? 0 : (side.values[macro.name] ?? 0)
            return TuneRow(title: macro.name,
                           detail: inaudible ? "You couldn't hear this one, so it's left alone" : macro.detail,
                           value: inaudible ? "\u{2014}" : DisplayFormat.signed(value),
                           fraction: max(-1, min(1, value / macro.range)),
                           muted: inaudible, hasBar: true)
        }
        if side.maxMovement < 1.0 {
            screen.footnotes.append(
                "Within a decibel of where you started \u{2014} a real answer, not a failure. Nothing here worth keeping.")
        }
        if side.verdict == .unreliable {
            screen.cautions.append(
                "Some of these answers are noise rather than preference, so treat the result as weak.")
        }
        screen.keepLabel = "Keep"
        screen.discardLabel = "Discard"
    }

    private static func shapeFinished(_ screen: inout TuneScreen, _ side: TuneSideState) {
        let consistency = shapeConsistency(pairs: side.sameTrials, guesses: side.sameGuesses,
                                           skipped: side.skippedTrials)
        screen.rows = ShapeRun.axisOrder.map { axis in
            let value = side.values[axis.rawValue] ?? 0
            let span = (value >= 0 ? axis.high : -axis.low) * max(side.rangeScale, 0.01)
            return TuneRow(title: axis.label, detail: axis.detail,
                           value: ShapeRun.text(value, axis: axis),
                           fraction: max(-1, min(1, value / max(span, 0.001))),
                           muted: false, hasBar: true)
        }
        switch side.verdict {
        case .unreliable:
            screen.headline = "Can't trust this run"
            screen.paragraphs = [
                consistency,
                "On most of the pairs that were one setting played twice, you named a winner. That is the "
                    + "check working: it means the choices in between were being made on something other "
                    + "than the sound, so there is nothing here to keep.",
                "Usually it is a session run too fast, or music that changed underneath the comparison. "
                    + "Switch back and forth a few times before answering, and use a passage you know."
            ]
            screen.rowsDimmed = true
            screen.discardLabel = "Close"
        case .nothingAudible, .usable:
            screen.headline = "The shape you preferred"
            screen.paragraphs = [consistency, side.summary]
            if side.verdict == .usable {
                screen.footnotes = [
                    "Keeping writes the curve you have been hearing, exactly as you heard it \u{2014} the "
                        + "three controls are already folded onto your bands."
                ]
                screen.keepLabel = "Keep"
                screen.discardLabel = "Discard"
            } else {
                screen.footnotes = [
                    "All three landed inside what anyone can reliably hear on music \u{2014} a real answer, "
                        + "not a failure. Nothing here worth keeping."
                ]
                screen.discardLabel = "Close"
            }
        }
    }

    private static func bypassFinished(_ screen: inout TuneScreen, _ side: TuneSideState, trim: Bool) {
        let total = BlindTuner.bypassTrials
        let eqName = trim ? "the trim" : "your EQ"
        let flatName = trim ? "your EQ" : "flat"
        let outcome = side.outcome ?? .noneSurvived(eq: side.preferredEQ, flat: side.preferredFlat,
                                                    same: side.noPreference)
        switch outcome {
        case .preferredEQ(let count):
            screen.headline = trim ? "You preferred the trim in \(count) of \(total)"
                : "You preferred your EQ in \(count) of \(total)"
        case .preferredFlat(let count):
            screen.headline = trim ? "You preferred your EQ as it is in \(count) of \(total)"
                : "You preferred flat in \(count) of \(total)"
        case .noneSurvived:
            screen.headline = "No clear preference in \(total)"
        }
        var eq = side.preferredEQ
        var flat = side.preferredFlat
        var same = side.noPreference
        if case .noneSurvived(let e, let f, let s) = outcome { eq = e; flat = f; same = s }
        screen.paragraphs = [trialsSummary(eq: eq, flat: flat, same: same, eqName: eqName, flatName: flatName)]
        screen.paragraphs.append(bypassReading(outcome, trim: trim))
        screen.footnotes = [
            trim
                ? "Your EQ is exactly as you left it \u{2014} this check never keeps anything. Auto-trim carries on as before."
                : "Your EQ is exactly as you left it \u{2014} this check never writes anything."
        ]
        screen.discardLabel = "Close"
    }

    private static func bypassReading(_ outcome: TuneCheckOutcome, trim: Bool) -> String {
        switch outcome {
        case .preferredEQ:
            return trim
                ? "The trim sounded better blind \u{2014} Auto-trim is doing what you'd want. Five trials say "
                    + "which way you leant, not by how much."
                : "Five trials can tell a strong preference from none, and nothing finer \u{2014} this says "
                    + "which way you leant, not by how much."
        case .preferredFlat:
            return trim
                ? "Your EQ as it is won. Consider the Clarity or Audiophile mode, a lower strength, or "
                    + "turning Auto-trim off."
                : "Five trials can tell a strong preference from none, and nothing finer \u{2014} this says "
                    + "which way you leant, not by how much."
        case .noneSurvived:
            return trim
                ? "The trim didn't survive blinding: on this music, at this volume, it is doing less than it "
                    + "seems to when you can see the switch. Five trials can only tell a strong preference from none."
                : "The difference didn't survive blinding. That is worth knowing rather than a failure: on this "
                    + "music, at this volume, the curve is doing less than it seems to when you can see the "
                    + "switch. Five trials can only tell a strong preference from none."
        }
    }

    private static func tonesRunning(_ screen: inout TuneScreen, _ tones: TuneToneState) {
        screen.headline = hertz(tones.currentHz)
        screen.progressText = "\(tones.bandsDone) / \(tones.bandsTotal) done"
        screen.progressFraction = Double(tones.bandsDone) / Double(max(1, tones.bandsTotal))
        screen.footnotes = [toneSessionHelp]
        screen.canListenAndChoose = true
        screen.discardLabel = stopLabel
    }

    private static func tonesFinished(_ screen: inout TuneScreen, _ tones: TuneToneState) {
        screen.rows = tones.suggestion.map { point in
            TuneRow(title: shortHertz(point.hz),
                    detail: point.measured ? DisplayFormat.decibels(point.deviation, decimals: 0) : "",
                    value: point.measured ? "EQ " + DisplayFormat.signed(point.gain) : "no reading",
                    fraction: 0, muted: !point.measured, hasBar: false)
        }
        screen.rowsTitle = "Compared with typical hearing"
        let total = tones.bandsTotal
        switch tones.verdict {
        case .tooFewReadings:
            screen.headline = "Couldn't measure your hearing"
            screen.paragraphs = [
                "\(tones.readingCount) of the \(total) frequencies gave a reading \u{2014} too few to compare "
                    + "against anything. This says nothing about your hearing either way; the test simply "
                    + "didn't get an answer.",
                "A quieter room and a slightly higher volume before starting are usually what's missing."
            ]
            screen.rows = []
        case .unreliable:
            screen.headline = "Can't trust this run"
            screen.paragraphs = [
                "Your presses landed on the silent checks often enough that the test can't tell them from "
                    + "real ones. The readings below were collected, but none of them can be believed, so "
                    + "there is nothing here to apply.",
                "That is almost always guessing \u{2014} background noise, or tiredness near the end of a "
                    + "long test. Press only when you're sure, and let the silences pass."
            ]
            screen.rowsDimmed = true
        case .tooScattered(let spread):
            screen.headline = "Readings too scattered"
            screen.paragraphs = [
                String(format: "The frequencies came out %.0f dB apart end to end \u{2014} further than hearing "
                       + "itself stretches. That is a measurement problem rather than a curve, so there is "
                       + "nothing here to apply.", spread),
                "Usually the fit changed partway through, or the room was quiet for some frequencies and not "
                    + "others. Reseat the headphones, keep the volume steady, and run it again."
            ]
            screen.rowsDimmed = true
        case .withinTestNoise:
            screen.headline = "Compared with typical hearing"
            screen.rowsTitle = nil
            let where_ = tones.readingCount < total ? "wherever it could be measured" : "across the range"
            screen.footnotes = [
                "Your hearing is within test noise of typical \(where_) \u{2014} there is no personal "
                    + "correction to make. A headphone correction will do far more."
            ]
        case .usable:
            screen.headline = "Compared with typical hearing"
            screen.rowsTitle = nil
        }
        if tones.falseAlarmsElevated {
            screen.cautions.append(
                "You pressed on the silent checks more often than the task needs, so read this as a rough "
                    + "shape rather than a measurement.")
        }
        screen.catchSummary = catchSummary(played: tones.catchPlayed, falsePresses: tones.catchFalsePositives)
        if tones.verdict == .usable {
            screen.keepLabel = "Apply suggestion"
            screen.discardLabel = "Discard"
        } else {
            screen.discardLabel = "Close"
        }
    }
}

package enum TuneKeyFocus: Equatable {
    case sessionControl
    case other
}

package struct TuneRoundMark: Equatable {
    package let method: TuneMethod
    package let phase: TunePhase
    package let progress: String
}

package enum TuneFocusTarget: Equatable {
    case sessionMain
    case keep
    case discard
}

package enum TuneKeyAction: Equatable {
    case toggleSide
    case heard
}

extension TunePresentation {
    package static let spaceKey: UInt32 = 0x20

    package static func keyAction(keyval: UInt32, modified: Bool, focus: TuneKeyFocus = .sessionControl, state: TuneState) -> TuneKeyAction? {
        guard keyval == spaceKey, !modified, focus == .sessionControl, let method = state.active else { return nil }
        switch method {
        case .compare: return state.compare.phase == .running ? .toggleSide : nil
        case .shape: return state.shape.phase == .running ? .toggleSide : nil
        case .check: return state.check.phase == .running ? .toggleSide : nil
        case .trim: return state.trim.phase == .running ? .toggleSide : nil
        case .tones: return state.tones.phase == .running ? .heard : nil
        }
    }

    package static func roundMark(_ screen: TuneScreen) -> TuneRoundMark {
        TuneRoundMark(method: screen.method, phase: screen.phase, progress: screen.progressText)
    }

    package static func focusTarget(from previous: TuneRoundMark?, to mark: TuneRoundMark,
                                    screen: TuneScreen, focus: TuneKeyFocus) -> TuneFocusTarget? {
        guard previous != mark else { return nil }
        let fresh = previous?.phase != mark.phase || previous?.method != mark.method
        switch mark.phase {
        case .running: return fresh || focus == .sessionControl ? .sessionMain : nil
        case .finished: return fresh ? (screen.keepLabel == nil ? .discard : .keep) : nil
        default: return nil
        }
    }

    package static func accessibleRow(_ row: TuneRow) -> String {
        row.detail.isEmpty ? "\(row.title), \(row.value)" : "\(row.title), \(row.detail), \(row.value)"
    }

    package static let sidebarBadgeLabel = "Tune, a session is running"
}
