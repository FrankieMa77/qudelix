import SwiftUI

/// The A/B preference pane.
///
/// Kept deliberately sparse while a session runs: the listener should be
/// attending to the music, not the screen, and any hint of which option is which
/// would break the blinding. Sizes follow the rest of the popover — 11 for body
/// text, 12 for headings — and the copy is short, because a 400 pt window has no
/// room for paragraphs and an over-tall pane pushes its own buttons out of view.
struct TuneView: View {
    @EnvironmentObject var controller: QudelixController
    @EnvironmentObject var stageState: StageState
    @EnvironmentObject var tuner: ABTuner
    @EnvironmentObject var tones: ToneTester
    @EnvironmentObject var blind: BlindTuner

    enum Method: String, CaseIterable, Identifiable {
        case compare = "Compare"
        case shape = "Shape"
        case tones = "Tones"
        case check = "Blind check"
        var id: String { rawValue }
    }
    @State private var method: Method = .compare

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Hidden mid-session: switching method with a session running would
            // abandon it with the EQ left mid-test.
            if tuner.phase == .idle && tones.phase == .idle && blind.phase == .idle {
                Picker("", selection: $method) {
                    ForEach(Method.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            switch method {
            case .compare:
                switch tuner.phase {
                case .idle:     intro
                case .running:  session
                case .finished: result
                }
            case .shape:
                switch blind.phase {
                case .idle:     shapeIntro
                case .running:  blindSession
                case .finished: shapeResult
                }
            case .tones:
                switch tones.phase {
                case .idle:     toneIntro
                case .running:  toneSession
                case .finished: toneResult
                }
            case .check:
                switch blind.phase {
                case .idle:     checkIntro
                case .running:  blindSession
                case .finished: checkResult
                }
            }
        }
        // The tone test needs a quiet channel: while the Stage engine is
        // inserted in the audio path, the system mix would keep playing
        // through it and mask every near-threshold presentation. Mute the
        // mix for the session — the tones themselves are played by this
        // process, which the engine's tap excludes, so they stay audible.
        // View-scoped on purpose: the session dies with the popover, and so
        // must the mute (a stopped engine clears it as well).
        .onChange(of: tones.phase) { _, phase in
            stageState.engine.processor.setMuted(phase == .running)
        }
        .onAppear {
            if tones.phase != .idle {
                method = .tones
            } else if tuner.phase != .idle {
                method = .compare
            } else if blind.phase != .idle {
                method = blind.mode == .bypass ? .check : .shape
            }
        }
        .onDisappear {
            stageState.engine.processor.setMuted(false)
            if tones.phase == .running { tones.stop(controller) }
        }
    }

    // MARK: - Tone test

    private var toneIntro: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Measure what you can hear")
                .font(.system(size: 12, weight: .medium))

            Text("Faint tones at ten frequencies. Press the button whenever you hear "
                 + "one — some are silent on purpose. Needs a quiet room and about "
                 + "five minutes.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let note = tones.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let blocker = ToneTester.blocker(controller) {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(blocker.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Set a comfortable listening volume first — the tones are quiet, "
                     + "but they are relative to it. EQ is switched off while "
                     + "measuring, then restored.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Start") { tones.start(controller) }
                .controlSize(.small)
                .disabled(ToneTester.blocker(controller) != nil)
        }
    }

    private var toneSession: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(tones.currentHz >= 1000
                     ? "\(tones.currentHz / 1000) kHz" : "\(tones.currentHz) Hz")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                Spacer()
                Text("\(tones.bandsDone) / \(ToneTester.order.count) done")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Double(tones.bandsDone),
                         total: Double(ToneTester.order.count))
                .controlSize(.small)

            Button {
                tones.reportHeard()
            } label: {
                Text("I hear it")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])

            Text("Press the moment you hear anything, however faint. Silence is normal.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Stop") { tones.stop(controller) }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var toneResult: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch tones.verdict {
            case .tooFewReadings:           toneFailure
            case .unreliable:               toneUnreliable
            case .tooScattered(let spread): toneScattered(spread)
            case .withinTestNoise, .usable: toneReadings
            }

            if tones.falseAlarmsElevated {
                Text("You pressed on the silent checks more often than the task "
                     + "needs, so read this as a rough shape rather than a "
                     + "measurement.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(catchSummary)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if tones.verdict == .usable {
                    Button("Apply") { tones.applySuggestion(controller) }
                        .controlSize(.small)
                }
                Spacer()
                Button(tones.verdict == .usable ? "Discard" : "Close") {
                    tones.stop(controller)
                }
                .controlSize(.small)
            }
        }
    }

    private var catchSummary: String {
        let checks = tones.catchPlayed == 1
            ? "1 silent check" : "\(tones.catchPlayed) silent checks"
        let alarms = tones.catchFalsePositives == 1
            ? "1 press on silence" : "\(tones.catchFalsePositives) presses on silence"
        return "\(checks), \(alarms)"
    }

    private var toneFailure: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Couldn't measure your hearing")
                .font(.system(size: 12, weight: .medium))

            Text("\(tones.readingCount) of the \(ToneTester.order.count) frequencies "
                 + "gave a reading — too few to compare against anything. This says "
                 + "nothing about your hearing either way; the test simply didn't "
                 + "get an answer.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("A quieter room and a slightly higher volume before starting are "
                 + "usually what's missing.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var toneUnreliable: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Can't trust this run")
                .font(.system(size: 12, weight: .medium))

            Text("Your presses landed on the silent checks often enough that the "
                 + "test can't tell them from real ones. The readings below were "
                 + "collected, but none of them can be believed, so there is "
                 + "nothing here to apply.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("That is almost always guessing — background noise, or tiredness "
                 + "near the end of a long test. Press only when you're sure, and "
                 + "let the silences pass.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            readingsTable
                .opacity(0.5)
        }
    }

    private func toneScattered(_ spread: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Readings too scattered")
                .font(.system(size: 12, weight: .medium))

            Text(String(format: "The frequencies came out %.0f dB apart end to end "
                        + "— further than hearing itself stretches. That is a "
                        + "measurement problem rather than a curve, so there is "
                        + "nothing here to apply.", spread))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Usually the fit changed partway through, or the room was quiet "
                 + "for some frequencies and not others. Reseat the headphones, "
                 + "keep the volume steady, and run it again.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            readingsTable
                .opacity(0.5)
        }
    }

    private var toneReadings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compared with typical hearing")
                .font(.system(size: 12, weight: .medium))

            readingsTable

            if tones.verdict == .withinTestNoise {
                Text("Your hearing is within test noise of typical "
                     + (tones.readingCount < ToneTester.order.count
                        ? "wherever it could be measured" : "across the range")
                     + " — there is no personal correction to make. A headphone "
                     + "correction will do far more.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var readingsTable: some View {
        VStack(spacing: 4) {
            ForEach(tones.suggestion, id: \.hz) { s in
                HStack(spacing: 8) {
                    Text(s.hz >= 1000 ? "\(s.hz / 1000)k" : "\(s.hz)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                    if s.measured {
                        Text(String(format: "%+.0f dB", s.deviation))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 52, alignment: .trailing)
                        Text(String(format: "EQ %+.1f", s.gain))
                            .font(.system(size: 11).monospacedDigit())
                            .frame(width: 66, alignment: .trailing)
                    } else {
                        // Not zero. A frequency that gave no reading is a gap
                        // in the measurement, and "+0 dB, EQ +0.0" would read
                        // as having measured perfectly ordinary hearing there.
                        Text("no reading")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .frame(width: 126, alignment: .trailing)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Idle

    private var intro: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Find the EQ you prefer")
                .font(.system(size: 12, weight: .medium))

            Text("Play music you know, then pick which of two settings sounds better. "
                 + "Both are loudness-matched and unlabelled, so you can't simply "
                 + "prefer the louder one.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let note = tuner.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let blocker = ABTuner.blocker(controller) {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(blocker.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Twenty comparisons. Your current EQ comes back if you stop.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Start") { tuner.start(controller) }
                .controlSize(.small)
                .disabled(ABTuner.blocker(controller) != nil)
        }
    }

    // MARK: - Running

    private var session: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(tuner.isConsistencyCheck ? "Checking" : tuner.currentMacro)
                    .font(.system(size: 12, weight: .medium))
                Text(tuner.currentDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(min(tuner.trialsDone + 1, tuner.trialsTotal)) / \(tuner.trialsTotal)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Double(tuner.trialsDone),
                         total: Double(max(1, tuner.trialsTotal)))
                .controlSize(.small)

            // Named, never characterised: no gain readout, no "brighter".
            HStack(spacing: 10) {
                Text("Playing")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(tuner.showingA ? "A" : "B")
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .frame(width: 18)
                Button { tuner.toggleSide(controller) } label: {
                    Label("Switch", systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                Spacer()
            }

            Text("Switch as often as you like, then choose.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            // Two rows: four controls on one line overflow a 400 pt popover.
            HStack(spacing: 8) {
                Button("Prefer A") { tuner.choose(preferA: true, controller) }
                    .controlSize(.small)
                Button("Prefer B") { tuner.choose(preferA: false, controller) }
                    .controlSize(.small)
                Spacer()
            }
            HStack(spacing: 8) {
                // The honest third answer: without it a listener who cannot hear a
                // difference has to guess, and guesses become a real tilt.
                Button("Sound the same") { tuner.noDifference(controller) }
                    .controlSize(.small)
                Spacer()
                Button("Stop") { tuner.cancel(controller) }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Result

    private var result: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The balance you preferred")
                .font(.system(size: 12, weight: .medium))

            Text(consistencySummary)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 5) {
                ForEach(ABTuner.macros, id: \.name) { m in
                    resultRow(m)
                }
            }

            if tuner.maxMovement < 1.0 {
                Text("Within a decibel of where you started — a real answer, "
                     + "not a failure. Nothing here worth keeping.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tuner.consistencyPoor {
                Text("Some of these answers are noise rather than preference, so "
                     + "treat the result as weak.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Keep") { tuner.keepResult(controller) }
                    .controlSize(.small)
                Menu("Save to slot…") {
                    ForEach(0..<QudelixController.presetCount, id: \.self) { i in
                        Button {
                            tuner.keepResult(controller)
                            controller.savePreset(i)
                        } label: {
                            Text(verbatim: controller.presetLabel(i))
                        }
                    }
                }
                .controlSize(.small)
                .fixedSize()
                Spacer()
                Button("Discard") { tuner.discardResult(controller) }
                    .controlSize(.small)
            }
        }
    }

    private var consistencySummary: String {
        TuneView.sanityCheck(pairs: tuner.sameTrials, guesses: tuner.sameGuesses)
    }

    static func sanityCheck(pairs: Int, guesses: Int) -> String {
        let repeated = pairs == 1
            ? "1 pair was the same setting twice"
            : "\(pairs) pairs were the same setting twice"
        return "Sanity check: " + repeated + "; you called a winner in \(guesses)."
    }

    /// One tilt: name, a bar either side of centre, and the value.
    ///
    /// Fixed widths rather than a GeometryReader — inside a row that is itself
    /// being sized by its content, a GeometryReader collapses and the bar vanishes.
    private func resultRow(_ m: ABTuner.Macro) -> some View {
        let inaudible = tuner.inaudible.contains(m.name)
        let v = inaudible ? 0 : (tuner.displayValues[m.name] ?? 0)
        let barWidth: CGFloat = 150
        let half = barWidth / 2
        let frac = min(abs(v) / m.range, 1)

        return HStack(spacing: 8) {
            Text(m.name)
                .font(.system(size: 11))
                .frame(width: 66, alignment: .leading)

            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                    .frame(width: barWidth, height: 4)
                Rectangle().fill(.tertiary)
                    .frame(width: 1, height: 8)
                    .offset(x: half)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(1, half * frac), height: 4)
                    .offset(x: v >= 0 ? half : half - half * frac)
            }
            .frame(width: barWidth, height: 8)

            Text(inaudible ? "—" : String(format: "%+.1f", v))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(inaudible ? .tertiary : .secondary)
                .frame(width: 40, alignment: .trailing)
                .help(inaudible ? "You couldn't hear this one, so it's left alone" : "")
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var blindNote: some View {
        if let note = blind.note {
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shapeIntro: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Settle three controls by ear")
                .font(.system(size: 12, weight: .medium))

            Text("Bass, then presence, then overall tilt — one at a time, starting "
                 + "from a wide difference and halving it each round. Blind pairs, "
                 + "loudness-matched, and much shorter than Compare.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("The 5K's band centres are fixed, so each control is spread across "
                 + "them. What you hear is already that spread-out version — the "
                 + "curve a Keep would write, not an ideal shelf.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            blindNote

            if let blocker = BlindTuner.blocker(controller, mode: .shape) {
                warning(blocker.message)
            } else {
                Text("Twelve comparisons, three of them repeats of one setting. Your "
                     + "current EQ comes back if you stop.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Start") { blind.start(controller, mode: .shape) }
                .controlSize(.small)
                .disabled(BlindTuner.blocker(controller, mode: .shape) != nil)
        }
    }

    private var blindSession: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(blind.currentTitle)
                    .font(.system(size: 12, weight: .medium))
                Text(blind.currentDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(min(blind.trialsDone + 1, blind.trialsTotal)) / \(blind.trialsTotal)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Double(blind.trialsDone),
                         total: Double(max(1, blind.trialsTotal)))
                .controlSize(.small)

            HStack(spacing: 10) {
                Text("Playing")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(blind.showingA ? "A" : "B")
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .frame(width: 18)
                Button { blind.toggleSide(controller) } label: {
                    Label("Switch", systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                Spacer()
            }

            Text("Switch as often as you like, then choose.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                Button("Prefer A") { blind.choose(preferA: true, controller) }
                    .controlSize(.small)
                Button("Prefer B") { blind.choose(preferA: false, controller) }
                    .controlSize(.small)
                Spacer()
            }
            HStack(spacing: 8) {
                Button("Sound the same") { blind.noDifference(controller) }
                    .controlSize(.small)
                Spacer()
                Button("Stop") { blind.cancel(controller) }
                    .controlSize(.small)
            }
        }
    }

    private var shapeResult: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch blind.verdict {
            case .unreliable:               shapeUnreliable
            case .nothingAudible, .usable:  shapeReading
            }
        }
    }

    private var shapeConsistencyLine: some View {
        Text(shapeConsistencySummary)
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var shapeConsistencySummary: String {
        let base = TuneView.sanityCheck(pairs: blind.sameTrials,
                                        guesses: blind.sameGuesses)
        guard blind.skippedTrials > 0 else { return base }
        let skipped = blind.skippedTrials == 1
            ? "1 step too small for the device to store"
            : "\(blind.skippedTrials) steps too small for the device to store"
        return base + " · " + skipped
    }

    private var shapeUnreliable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Can't trust this run")
                .font(.system(size: 12, weight: .medium))

            shapeConsistencyLine

            Text("On most of the pairs that were one setting played twice, you named "
                 + "a winner. That is the check working: it means the choices in "
                 + "between were being made on something other than the sound, so "
                 + "there is nothing here to keep.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Usually it is a session run too fast, or music that changed "
                 + "underneath the comparison. Switch back and forth a few times "
                 + "before answering, and use a passage you know.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            shapeRows
                .opacity(0.5)

            HStack {
                Spacer()
                Button("Close") { blind.discardResult(controller) }
                    .controlSize(.small)
            }
        }
    }

    private var shapeReading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The shape you preferred")
                .font(.system(size: 12, weight: .medium))

            shapeConsistencyLine

            Text(blind.summary)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            shapeRows

            if blind.verdict == .usable {
                Text("Keeping writes the curve you have been hearing, exactly as you "
                     + "heard it — the three controls are already folded onto your "
                     + "bands.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("All three landed inside what anyone can reliably hear on music "
                     + "— a real answer, not a failure. Nothing here worth keeping.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if blind.verdict == .usable {
                    Button("Keep") { blind.keepResult(controller) }
                        .controlSize(.small)
                    Menu("Save to slot…") {
                        ForEach(0..<QudelixController.presetCount, id: \.self) { i in
                            Button {
                                blind.keepResult(controller)
                                controller.savePreset(i)
                            } label: {
                                Text(verbatim: controller.presetLabel(i))
                            }
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
                Spacer()
                Button(blind.verdict == .usable ? "Discard" : "Close") {
                    blind.discardResult(controller)
                }
                .controlSize(.small)
            }
        }
    }

    private var shapeRows: some View {
        VStack(spacing: 5) {
            ForEach(ShapeRun.axisOrder) { axis in
                shapeRow(axis)
            }
        }
    }

    private func shapeRow(_ axis: ShapeAxis) -> some View {
        let v = blind.values[axis] ?? 0
        let barWidth: CGFloat = 140
        let half = barWidth / 2
        let span = (v >= 0 ? axis.high : -axis.low) * max(blind.rangeScale, 0.01)
        let frac = min(abs(v) / max(span, 0.001), 1)

        return HStack(spacing: 8) {
            Text(axis.label)
                .font(.system(size: 11))
                .frame(width: 62, alignment: .leading)

            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                    .frame(width: barWidth, height: 4)
                Rectangle().fill(.tertiary)
                    .frame(width: 1, height: 8)
                    .offset(x: half)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(1, half * frac), height: 4)
                    .offset(x: v >= 0 ? half : half - half * frac)
            }
            .frame(width: barWidth, height: 8)

            Text(ShapeRun.text(v, axis: axis))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
    }

    private var checkIntro: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Check your EQ blind")
                .font(.system(size: 12, weight: .medium))

            Text("Five times: your EQ, or a flat one. Which side is which is hidden "
                 + "and the two are loudness-matched, so the only thing left to "
                 + "prefer is the curve itself.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            blindNote

            if let blocker = BlindTuner.blocker(controller, mode: .bypass) {
                warning(blocker.message)
            } else {
                Text("Nothing is written either way. Your bands and pre-gain come back "
                     + "exactly as they are now, whichever way the answers fall.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Start") { blind.start(controller, mode: .bypass) }
                .controlSize(.small)
                .disabled(BlindTuner.blocker(controller, mode: .bypass) != nil)
        }
    }

    private var checkResult: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(checkHeadline)
                .font(.system(size: 12, weight: .medium))

            Text(checkCounts)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(checkReading)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Your EQ is exactly as you left it — this check never writes "
                 + "anything.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Close") { blind.discardResult(controller) }
                    .controlSize(.small)
            }
        }
    }

    private var checkHeadline: String {
        switch blind.bypassOutcome {
        case .preferredEQ(let k):
            return "You preferred your EQ in \(k) of \(BlindTuner.bypassTrials)"
        case .preferredFlat(let k):
            return "You preferred flat in \(k) of \(BlindTuner.bypassTrials)"
        case .noneSurvived:
            return "No clear preference in \(BlindTuner.bypassTrials)"
        }
    }

    private var checkCounts: String {
        switch blind.bypassOutcome {
        case .preferredEQ, .preferredFlat:
            return "\(blind.preferredEQ) for your EQ · \(blind.preferredFlat) for flat "
                + "· \(blind.noPreference) sounded the same"
        case .noneSurvived(let eq, let flat, let same):
            return "\(eq) for your EQ · \(flat) for flat · \(same) sounded the same"
        }
    }

    private var checkReading: String {
        switch blind.bypassOutcome {
        case .preferredEQ, .preferredFlat:
            return "Five trials can tell a strong preference from none, and nothing "
                + "finer — this says which way you leant, not by how much."
        case .noneSurvived:
            return "The difference didn't survive blinding. That is worth knowing "
                + "rather than a failure: on this music, at this volume, the curve "
                + "is doing less than it seems to when you can see the switch. Five "
                + "trials can only tell a strong preference from none."
        }
    }
}
