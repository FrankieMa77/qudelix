import SwiftUI

/// The Soundstage pane: stereo-derived spaciousness, applied on the Mac to
/// whatever the system is playing, per output device.
///
/// Everything here reshapes the stereo mix — mid/side width, interaural
/// crossfeed, a mid-only dialogue lift, and sparse early reflections. It is
/// deliberately *not* called "spatial audio": there is no surround unfolding
/// and no head tracking, and the footnote says so rather than letting the
/// name overpromise.
struct StageView: View {
    @EnvironmentObject var stageState: StageState

    var body: some View {
        // Captured at render time: every control created below edits the
        // device the user was LOOKING at, and StageState drops the write if
        // the default output changed under an in-flight gesture.
        let uid = stageState.outputUID
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(isOn: Binding(
                    get: { stageState.stage.enabled },
                    set: { on in
                        var s = stageState.stage
                        s.enabled = on
                        // Flipping on with everything at neutral would be a
                        // no-op that reads as "broken"; start somewhere.
                        if on, !s.doesAnything { s = .music }
                        stageState.setStage(s, editedFor: uid)
                    })) {
                    Text("Soundstage")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer()
                Text(verbatim: deviceLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if stageState.stage.enabled, !stageState.engine.isRunning {
                // Start errors land in the status line — most likely the
                // System Audio Recording permission on first use.
                Text(verbatim: stageState.engine.status)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                presetButton("Music", .music, uid: uid)
                presetButton("Movie", .movie, uid: uid)
                presetButton("Theater", .theater, uid: uid)
                if isCustom {
                    Text("Custom")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(spacing: 8) {
                slider("Width", value: Binding(
                    get: { stageState.stage.width },
                    set: { v in mutate(uid) { $0.width = v.rounded() } }),
                    in: 0...200, display: String(format: "%.0f %%", stageState.stage.width),
                    help: "Side-channel level. Dialogue and bass stay centred; "
                        + "ambience and score grow around them.")
                slider("Crossfeed", value: Binding(
                    get: { stageState.stage.crossfeed * 100 },
                    set: { v in mutate(uid) { $0.crossfeed = v.rounded() / 100 } }),
                    in: 0...100, display: String(format: "%.0f %%", stageState.stage.crossfeed * 100),
                    help: "Each ear hears a delayed, darkened copy of the other "
                        + "channel — sound moves out of the middle of your head.")
                slider("Dialogue", value: Binding(
                    get: { stageState.stage.dialogue },
                    set: { v in mutate(uid) { $0.dialogue = (v * 2).rounded() / 2 } }),
                    in: 0...6, display: String(format: "+%.1f dB", stageState.stage.dialogue),
                    help: "Presence lift on the centre channel only, so speech "
                        + "cuts through without sharpening the whole mix.")
                slider("Room", value: Binding(
                    get: { stageState.stage.room * 100 },
                    set: { v in mutate(uid) { $0.room = v.rounded() / 100 } }),
                    in: 0...100, display: String(format: "%.0f %%", stageState.stage.room * 100),
                    help: "Sparse early reflections that suggest a room. "
                        + "Subtle on purpose — more is not better.")
                slider("Night", value: Binding(
                    get: { stageState.stage.nightValue * 100 },
                    set: { v in mutate(uid) { $0.night = v.rounded() / 100 } }),
                    in: 0...100, display: String(format: "%.0f %%",
                                                 stageState.stage.nightValue * 100),
                    help: "Evens out movie dynamics: quiet dialogue comes up, "
                        + "explosions come down. Dialogue stays put.")
            }
            // Deliberately NOT .disabled: a slider someone reaches for should
            // work — touching one switches the stage on. Controls that do
            // something when touched beat controls that politely do nothing.
            .opacity(stageState.stage.enabled ? 1 : 0.55)

            if stageState.stage.crossfeed > 0 {
                crossBandGroup(uid)
                    .opacity(stageState.stage.enabled ? 1 : 0.55)
            }

            DisclosureGroup {
                VStack(spacing: 8) {
                    slider("Distance", value: Binding(
                        get: { stageState.stage.distanceValue * 100 },
                        set: { v in mutate(uid) { $0.distance = v.rounded() / 100 } }),
                        in: 0...100, display: String(format: "%.0f %%",
                                                     stageState.stage.distanceValue * 100),
                        help: "Pushes the sources away from your head: the room's "
                            + "first reflection arrives later, the direct sound "
                            + "eases slightly.")
                    slider("Span", value: Binding(
                        get: { stageState.stage.spanValue * 100 },
                        set: { v in mutate(uid) { $0.span = v.rounded() / 100 } }),
                        in: 0...100, display: String(format: "%.0f %%",
                                                     stageState.stage.spanValue * 100),
                        help: "The virtual speaker angle the crossfeed simulates — "
                            + "wider span, sources spread further apart.")
                    slider("Center", value: Binding(
                        get: { stageState.stage.centerValue },
                        set: { v in mutate(uid) { $0.center = (v * 2).rounded() / 2 } }),
                        in: -6...3, display: String(format: "%+.1f dB",
                                                    stageState.stage.centerValue),
                        help: "Level of the centre image. Cramped stages are "
                            + "usually centre-heavy — pull it back a little and "
                            + "the sides get room to breathe.")
                    slider("Size", value: Binding(
                        get: { stageState.stage.sizeValue * 100 },
                        set: { v in mutate(uid) { $0.size = v.rounded() / 100 } }),
                        in: 0...100, display: String(format: "%.0f %%",
                                                     stageState.stage.sizeValue * 100),
                        help: "Scales the whole room — reflection distances and "
                            + "the tail's decay paths.")
                }
                .padding(.top, 6)
            } label: {
                Text("Stage geometry")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .opacity(stageState.stage.enabled ? 1 : 0.55)

            balanceSection(uid)
                .opacity(stageState.stage.enabled ? 1 : 0.55)

            limiterSection(uid)

            loudnessSection(uid)

            if stageState.stage.enabled, let corr = stageState.sourceCorrelation,
               corr > 0.985 {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("What's playing right now is mono — identical left and "
                         + "right. Width and Crossfeed have nothing to work "
                         + "with; only Dialogue, Room and Balance can act. Try "
                         + "a stereo source (music, a film trailer) to hear the "
                         + "stage.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Applied on the Mac to whatever is playing, before it reaches "
                 + "the output — the 5K's own EQ stays untouched on the device. "
                 + "Works on the stereo mix: surround content stays downmixed, "
                 + "and sound doesn't track your head. Settings follow the "
                 + "current output device.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var deviceLabel: String {
        // The device name comes from the hardware (a Bluetooth radio can
        // carry anything); cap it and render verbatim.
        guard let name = stageState.outputName else { return "" }
        return "for " + (name.count > 22 ? name.prefix(21) + "…" : name)
    }

    private var isCustom: Bool {
        stageState.stage.enabled && !stageState.stage.audiblyEquals(.music)
            && !stageState.stage.audiblyEquals(.movie)
            && !stageState.stage.audiblyEquals(.theater)
    }

    private func mutate(_ uid: String?, _ change: (inout StageSettings) -> Void) {
        var s = stageState.stage
        change(&s)
        s.enabled = true   // reaching for a slider IS the intent to hear it
        stageState.setStage(s, editedFor: uid)
    }

    private func presetButton(_ label: String, _ preset: StageSettings,
                              uid: String?) -> some View {
        Button(label) {
            stageState.setStage(preset, editedFor: uid)
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .tint(stageState.stage.audiblyEquals(preset) ? Color.accentColor : nil)
    }

    private func crossBandGroup(_ uid: String?) -> some View {
        DisclosureGroup {
            VStack(spacing: 8) {
                slider("Low", value: Binding(
                    get: { stageState.stage.crossLowTrimValue * 100 },
                    set: { v in mutate(uid) { $0.crossLowTrim = v.rounded() / 100 } }),
                    in: 0...100, display: String(format: "%.0f %%",
                                                 stageState.stage.crossLowTrimValue * 100),
                    help: "Below 800 Hz.")
                slider("Mid", value: Binding(
                    get: { stageState.stage.crossMidTrimValue * 100 },
                    set: { v in mutate(uid) { $0.crossMidTrim = v.rounded() / 100 } }),
                    in: 0...100, display: String(format: "%.0f %%",
                                                 stageState.stage.crossMidTrimValue * 100),
                    help: "800 Hz to 4 kHz.")
                slider("High", value: Binding(
                    get: { stageState.stage.crossHighTrimValue * 100 },
                    set: { v in mutate(uid) { $0.crossHighTrim = v.rounded() / 100 } }),
                    in: 0...100, display: String(format: "%.0f %%",
                                                 stageState.stage.crossHighTrimValue * 100),
                    help: "Above 4 kHz.")
                Text("Each of these scales the Crossfeed amount inside one "
                     + "range. 100 % everywhere is the plain Crossfeed above.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 5) {
                Text("Crossfeed by band")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if bandTrimsActive {
                    Text(String(format: "%.0f / %.0f / %.0f %%",
                                stageState.stage.crossLowTrimValue * 100,
                                stageState.stage.crossMidTrimValue * 100,
                                stageState.stage.crossHighTrimValue * 100))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .help("Scales Crossfeed separately below 800 Hz, between 800 Hz "
                  + "and 4 kHz, and above 4 kHz.")
        }
    }

    private var bandTrimsActive: Bool {
        stageState.stage.crossLowTrimValue != 1
            || stageState.stage.crossMidTrimValue != 1
            || stageState.stage.crossHighTrimValue != 1
    }

    private func balanceSection(_ uid: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Balance")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            slider("Level", value: Binding(
                get: { stageState.stage.balanceDbValue },
                set: { v in mutate(uid) { $0.balanceDb = (v * 10).rounded() / 10 } }),
                in: -3...3, display: levelDisplay,
                help: "Level difference between the two sides. Half of it goes "
                    + "to each side, so the balance changes and the volume "
                    + "does not.",
                valueWidth: 74,
                reset: { mutate(uid) { $0.balanceDb = 0 } })
            slider("Time", value: Binding(
                get: { stageState.stage.alignMsValue },
                set: { v in mutate(uid) { $0.alignMs = (v * 100).rounded() / 100 } }),
                in: -0.5...0.5, display: timeDisplay,
                help: "Arrival-time difference between the two sides — the side "
                    + "shown is the one held back.",
                valueWidth: 74,
                reset: { mutate(uid) { $0.alignMs = 0 } })
            Text("For a real mismatch between the two sides: a pair that has "
                 + "drifted apart, or one ear that hears less than the other. "
                 + "It acts on mono content too.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func limiterSection(_ uid: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { stageState.stage.limiterValue },
                set: { on in
                    var s = stageState.stage
                    s.limiter = on
                    stageState.setStage(s, editedFor: uid)
                })) {
                Text("True-peak limiter")
                    .font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!stageState.stage.enabled)
            Text(limiterNote)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(stageState.stage.enabled ? 1 : 0.55)
    }

    private func loudnessSection(_ uid: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding(
                    get: { stageState.stage.loudnessValue },
                    set: { on in
                        var s = stageState.stage
                        s.loudness = on
                        stageState.setStage(s, editedFor: uid)
                    })) {
                    Text("Loudness")
                        .font(.system(size: 11, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!stageState.stage.enabled)
                Spacer()
                if stageState.stage.enabled, stageState.stage.loudnessValue {
                    Text(loudnessAmount)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(stageState.loudnessShelfDb > 0.05
                                         ? AnyShapeStyle(.secondary)
                                         : AnyShapeStyle(.tertiary))
                }
            }
            if stageState.stage.loudnessValue {
                slider("Strength", value: Binding(
                    get: { stageState.stage.loudnessStrengthValue * 100 },
                    set: { v in mutate(uid) { $0.loudnessStrength = v.rounded() / 100 } }),
                    in: 0...100, display: String(format: "%.0f %%",
                                                 stageState.stage.loudnessStrengthValue * 100),
                    help: "Scales the whole contour. 100 % is the full "
                        + "correction the estimated level asks for.")
            }
            Text(loudnessNote)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(stageState.stage.enabled ? 1 : 0.55)
    }

    private var loudnessAmount: String {
        let db = stageState.loudnessShelfDb
        return db > 0.05 ? String(format: "+%.1f dB bass", db) : "flat"
    }

    private var loudnessNote: String {
        guard stageState.stage.enabled else {
            return "Unavailable while Soundstage is off — with the stage off "
                + "this app is not in the audio path at all, so it has "
                + "nothing to shape."
        }
        let what = String(format: "Quiet listening loses bass first, and a "
                          + "little treble with it. This raises both back "
                          + "while the estimated level at your ear sits "
                          + "below the %.0f dB reference, and eases off as "
                          + "you turn up.", EarLevel.referenceDb)
        guard stageState.engine.isRunning else { return what }
        if stageState.earAnchor == nil {
            return what + " Holding flat for now: it rests on the estimate "
                + "in the Level pane, and this output offers no volume "
                + "reading to anchor one."
        }
        if stageState.earLevelAverageDb == nil {
            return what + " Holding flat until the estimate in the Level "
                + "pane settles — it averages about half a minute of "
                + "playback, so the shelf follows the listening level "
                + "rather than the chorus."
        }
        return what + " It rests on the estimate in the Level pane, which is "
            + "measured before this shelf so the two can never chase each "
            + "other."
    }

    private var limiterNote: String {
        guard stageState.stage.enabled else {
            return "Unavailable while Soundstage is off — with the stage off "
                + "this app is not in the audio path at all, so it has no "
                + "output of its own to protect."
        }
        return String(format: "Protects the Soundstage's own output at −1 dBTP, "
                      + "counting the peaks that land between samples — the "
                      + "ones a lossy encoder clips on. Adds %d samples of "
                      + "latency: %.1f ms at %g kHz. It does nothing while "
                      + "Soundstage is off.",
                      StageProcessor.limLookahead, limiterLatencyMs,
                      limiterRateHz / 1000)
    }

    private var limiterRateHz: Double {
        let rate = stageState.engine.runningSampleRate
            ?? stageState.watcher.defaultOutput?.sampleRate ?? 48000
        return AudioOutputs.plausibleRate(rate)
    }

    private var limiterLatencyMs: Double {
        Double(StageProcessor.limLookahead) / limiterRateHz * 1000
    }

    private var levelDisplay: String {
        let v = stageState.stage.balanceDbValue
        if v == 0 { return "centred" }
        return String(format: "%@ +%.1f dB", v > 0 ? "R" : "L", abs(v))
    }

    private var timeDisplay: String {
        let v = stageState.stage.alignMsValue
        if v == 0 { return "aligned" }
        return String(format: "%@ +%.2f ms", v > 0 ? "R" : "L", abs(v))
    }

    private func slider(_ label: String, value: Binding<Double>,
                        in range: ClosedRange<Double>, display: String,
                        help: String, valueWidth: CGFloat = 56,
                        reset: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
            Text(display)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: valueWidth, alignment: .trailing)
            if let reset {
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("Reset \(label)")
                .help("Reset \(label)")
            }
        }
        .help(help)
    }
}
