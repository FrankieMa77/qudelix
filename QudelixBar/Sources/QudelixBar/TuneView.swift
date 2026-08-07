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
    @StateObject private var tuner = ABTuner()
    @StateObject private var tones = ToneTester()

    /// Two quite different methods live here. Comparing settings measures what you
    /// prefer; the tone test measures what you can hear. They answer different
    /// questions, so the pane asks which one rather than blending them.
    enum Method: String, CaseIterable, Identifiable {
        case compare = "Compare"
        case tones = "Tones"
        var id: String { rawValue }
    }
    @State private var method: Method = .compare

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Hidden mid-session: switching method with a session running would
            // abandon it with the EQ left mid-test.
            if tuner.phase == .idle && tones.phase == .idle {
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
            case .tones:
                switch tones.phase {
                case .idle:     toneIntro
                case .running:  toneSession
                case .finished: toneResult
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
        .onDisappear {
            stageState.engine.processor.setMuted(false)
            // The sessions are view-owned and die with the popover — but
            // their DEVICE state must not: an abandoned tone test leaves
            // the EQ switched off, an abandoned comparison leaves a trial
            // curve and its session pre-gain applied.
            if tones.phase == .running { tones.stop(controller) }
            // `.finished` matters as much as `.running`: that is the results
            // screen, before Keep or Discard, and the trial curve and session
            // pre-gain are still on the device. Closing the popover there used
            // to destroy the baseline along with the view, stranding both with
            // no way back.
            if tuner.phase == .running || tuner.phase == .finished {
                tuner.cancel(controller)
            }
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

    private var toneResult: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compared with typical hearing")
                .font(.system(size: 12, weight: .medium))

            VStack(spacing: 4) {
                ForEach(tones.suggestion, id: \.hz) { s in
                    HStack(spacing: 8) {
                        Text(s.hz >= 1000 ? "\(s.hz / 1000)k" : "\(s.hz)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                        Text(String(format: "%+.0f dB", s.deviation))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 52, alignment: .trailing)
                        Text(String(format: "EQ %+.1f", s.gain))
                            .font(.system(size: 11).monospacedDigit())
                            .frame(width: 66, alignment: .trailing)
                        Spacer()
                    }
                }
            }

            if tones.deviationSpread < 8 {
                Text("Your hearing is within test noise of typical across the range — "
                     + "there is no personal correction to make. A headphone "
                     + "correction will do far more.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tones.falsePositiveRate > 0.3 {
                Text(String(format: "You responded on %.0f%% of the silent trials, so "
                            + "these numbers are unreliable. Worth repeating.",
                            tones.falsePositiveRate * 100))
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Apply") { tones.applySuggestion(controller) }
                    .controlSize(.small)
                    .disabled(tones.deviationSpread < 8)
                Spacer()
                Button("Discard") { tones.stop(controller) }
                    .controlSize(.small)
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
                Text("About 20 comparisons. Your current EQ comes back if you stop.")
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

            VStack(spacing: 5) {
                ForEach(ABTuner.macros, id: \.name) { m in
                    resultRow(m)
                }
            }

            if tuner.maxTilt < 1.0 {
                Text("Within a decibel of where you started — a real answer, "
                     + "not a failure. Nothing here worth keeping.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tuner.consistencyPoor {
                Text("You answered the identical pairs one-sidedly, so treat this as weak.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Keep") { tuner.keepResult(controller) }
                    .controlSize(.small)
                Menu("Save to…") {
                    ForEach(0..<QudelixController.presetCount, id: \.self) { i in
                        Button(controller.presetLabel(i)) {
                            tuner.keepResult(controller)
                            controller.savePreset(i)
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
}
