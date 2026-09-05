import SwiftUI

/// What actually happens to audio between the source and the listener's
/// ears, laid out as a five-stage chain: Source → macOS mixer → this app →
/// the 5K's own EQ → Output.
///
/// The one rule that matters more than any layout detail: **we cannot know
/// the source file's sample rate.** The tap this app reads from (see
/// `StageEngine`) hands us audio already converted to the device's rate, so
/// there is no way to tell whether macOS resampled it first. Every row below
/// is written to say only what it can actually measure, and to say plainly
/// when it can't — never "bit-perfect", never a green tick standing in for
/// a guess. `SignalPathTests` holds this line by grepping every row string
/// this enum can produce.
enum SignalPath {
    /// One link in the chain. `indicator` is the glanceable "does this stage
    /// touch the audio" signal; `emphasis` borrows the Level pane's
    /// green/orange/yellow vocabulary but only where a row is actually
    /// making a quality claim (today, only the Source row) — everywhere
    /// else color would imply a verdict this view hasn't earned.
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let state: String
        let indicator: Indicator
        var emphasis: Emphasis = .neutral
    }

    enum Indicator: Equatable {
        /// This stage measurably changes the signal.
        case altering
        /// This stage is confirmed to leave the signal alone.
        case passthrough
        /// Whether this stage alters anything is not observable from here.
        case unknown
    }

    enum Emphasis: Equatable {
        case neutral, good, caution, warning
    }

    /// Plain-value snapshot of everything the five rows need, gathered from
    /// `QudelixController` and `StageState`. Pure input → pure output is what
    /// makes the honesty rules testable without standing up either
    /// `@MainActor` object or touching CoreAudio/HID.
    struct Inputs {
        /// Whether the 5K is the device this app is currently talking to —
        /// gates the two rows (EQ, Output) that describe the hardware
        /// itself. Source/mixer/this-app act on the Mac's default output,
        /// which may be a different device entirely, so they are NOT gated
        /// on this.
        var deviceConnected = true

        // Row 1: Source
        var detectQuality = true
        var engineRunning = false
        var callHold = false
        var qualityVerdict: QualityAnalyzer.Verdict?
        /// Few-word reason the engine isn't running, when it was asked to and
        /// couldn't. nil when nothing is wrong — an engine that is merely
        /// idle has no reason to give.
        var engineProblem: String?

        // Row 2: macOS mixer
        /// The DEFAULT OUTPUT's Core Audio nominal rate, read independently
        /// of whether the stage engine is running. It is the default output
        /// deliberately: this row sits between Source and This app, both of
        /// which describe that same chain. Handing it the 5K's rate while
        /// the Mac plays to something else made the row contradict its
        /// neighbours without changing a word of its text.
        var mixerRateHz: Double?
        /// The default output's name, so the row can say whose rate it is
        /// reporting — with the 5K attached but not selected, "48 kHz" alone
        /// reads as a claim about the 5K.
        var mixerDeviceName: String?

        // Row 3: This app (Soundstage)
        /// nil = the engine isn't running at all. Set only while running.
        var engineMode: StageEngine.Mode?
        var stage = StageSettings()

        // Row 4: Qudelix EQ (runs on the device, not the Mac)
        var eqEnabled = true
        var bandCount = 10
        /// How many of `bandCount` slots are individually muted right now —
        /// bypassed by this app rather than by the preset itself. A muted
        /// band contributes nothing to the curve, so "N-band" alone would
        /// overstate what's actually shaping the sound.
        var mutedBandCount = 0
        /// nil = no preset slot is active (the device's own "custom" state).
        var activePresetName: String?
        var preGain: Double = 0

        // Row 5: Output
        var link: QudelixController.Link = .none
        var codecLabel: String?
        /// The device's own protocol-reported rate label (distinct from
        /// `mixerRateHz`, which is what macOS's HAL reports for the same
        /// hardware — the two are independent observations and are allowed
        /// to disagree).
        var outputRateLabel: String?
        var outputHighGain: Bool?
        var currentLevelDb: Double?
    }

    static func rows(_ i: Inputs) -> [Row] {
        [sourceRow(i), mixerRow(i), appRow(i), eqRow(i), outputRow(i)]
    }

    // MARK: - Row 1: Source

    private static func sourceRow(_ i: Inputs) -> Row {
        let name = "Source"
        guard i.detectQuality else {
            return Row(id: "source", name: name, state: "quality detection is off",
                      indicator: .unknown)
        }
        guard i.engineRunning else {
            if i.callHold {
                return Row(id: "source", name: name,
                          state: "paused for a call — measuring resumes when it ends",
                          indicator: .unknown)
            }
            // A stopped engine has two very different causes, and "engine
            // off" alone left the commonest one — the recording permission
            // never granted — looking like a setting nobody switched on.
            if let problem = cap(i.engineProblem) {
                return Row(id: "source", name: name,
                          state: "can't measure — \(problem)", indicator: .unknown)
            }
            return Row(id: "source", name: name, state: "engine off — nothing to measure",
                      indicator: .unknown)
        }
        guard let verdict = i.qualityVerdict else {
            return Row(id: "source", name: name, state: "listening…", indicator: .unknown)
        }
        switch verdict {
        case .tooQuiet:
            return Row(id: "source", name: name, state: "nothing playing", indicator: .unknown)
        case .noTreble:
            return Row(id: "source", name: name, state: "no treble to judge — can't tell",
                      indicator: .unknown)
        case .lossy(let khz):
            return Row(id: "source", name: name,
                      state: String(format: "lossy, cuts at %.1f kHz", khz),
                      indicator: .altering, emphasis: .warning)
        case .lossyHigh(let khz):
            return Row(id: "source", name: name,
                      state: String(format: "lossy, high bitrate (%.1f kHz)", khz),
                      indicator: .altering, emphasis: .caution)
        case .losslessLike(let khz):
            return Row(id: "source", name: name,
                      state: String(format: "consistent with lossless (%.1f kHz)", khz),
                      indicator: .passthrough, emphasis: .good)
        case .hiRes(let khz):
            return Row(id: "source", name: name,
                      state: String(format: "hi-res content (%.1f kHz)", khz),
                      indicator: .passthrough, emphasis: .good)
        case .natural(let khz):
            return Row(id: "source", name: name,
                      state: String(format: "rolls off naturally (%.1f kHz) — can't judge this material", khz),
                      indicator: .unknown)
        }
    }

    // MARK: - Row 2: macOS mixer

    private static func mixerRow(_ i: Inputs) -> Row {
        let name = "macOS mixer"
        guard let rate = i.mixerRateHz, rate.isFinite, rate > 0 else {
            return Row(id: "mixer", name: name,
                      state: "no output device — can't read a rate",
                      indicator: .unknown)
        }
        // Named where we can: this row describes the Mac's default output,
        // which is often not the 5K the rows below it describe.
        let whose = cap(i.mixerDeviceName).map { "\($0) — " } ?? ""
        // Deliberately always .unknown: whatever the device's rate is, this
        // is exactly the point where the honesty rule bites — the tap hands
        // us audio already at this rate, so whether the source matched it
        // (or macOS resampled) is not something this app can observe.
        return Row(id: "mixer", name: name,
                  state: whose + String(format: "running at %g kHz — whether the source "
                                + "matched that rate isn't observable from here", rate / 1000),
                  indicator: .unknown)
    }

    // MARK: - Row 3: This app (Soundstage)

    private static func appRow(_ i: Inputs) -> Row {
        let name = "This app"
        guard let mode = i.engineMode else {
            // The engine isn't running at all: no tap, no callback, nothing
            // of this app's sits between source and output.
            return Row(id: "app", name: name,
                      state: "nothing in this app is altering the audio",
                      indicator: .passthrough)
        }
        switch mode {
        case .monitor:
            // Monitor mode reads the tap for metering only — the original
            // render keeps playing untouched. Said explicitly, because
            // "the engine is running" alone would read as "processing".
            return Row(id: "app", name: name,
                      state: "not in the path — metering only, audio untouched",
                      indicator: .passthrough)
        case .insert:
            return Row(id: "app", name: name, state: stageDescription(i.stage),
                      indicator: .altering)
        }
    }

    /// What the Stage is actually doing, named rather than just "on" — the
    /// four audible controls that are above their neutral value.
    private static func stageDescription(_ s: StageSettings) -> String {
        guard !s.isAudiblyNeutral else {
            return "Soundstage inserted — every control at neutral"
        }
        var parts: [String] = []
        if s.width != 100 { parts.append("width") }
        if s.crossfeed > 0 {
            let banded = s.crossLowTrimValue != 1 || s.crossMidTrimValue != 1
                || s.crossHighTrimValue != 1
            parts.append(banded ? "crossfeed (per band)" : "crossfeed")
        }
        if s.dialogue > 0 { parts.append("dialogue") }
        if s.room > 0 { parts.append("room") }
        if s.balanceDbValue != 0 || s.alignMsValue != 0 { parts.append("balance") }
        let detail = parts.isEmpty ? "processing the stereo mix"
                                   : parts.joined(separator: ", ") + " active"
        return "Soundstage inserted — " + detail
    }

    // MARK: - Row 4: Qudelix EQ

    private static func eqRow(_ i: Inputs) -> Row {
        let name = "Qudelix EQ"
        guard i.deviceConnected else {
            return Row(id: "eq", name: name, state: "no device connected", indicator: .unknown)
        }
        guard i.eqEnabled else {
            return Row(id: "eq", name: name, state: "off", indicator: .passthrough)
        }
        let preset = cap(i.activePresetName).map { "\u{201C}\($0)\u{201D}" } ?? "custom"
        // A muted band is bypassed on the device, same as an empty preset
        // slot — "N-band" alone would claim more shaping than is happening.
        let active = max(i.bandCount - i.mutedBandCount, 0)
        let bands = i.mutedBandCount > 0
            ? "\(active) of \(i.bandCount) bands (\(i.mutedBandCount) muted)"
            : "\(i.bandCount)-band"
        let state = "on — \(bands), \(preset), pre-gain "
            + String(format: "%+.1f dB", i.preGain)
        return Row(id: "eq", name: name, state: state, indicator: .altering)
    }

    // MARK: - Row 5: Output

    private static func outputRow(_ i: Inputs) -> Row {
        let name = "Output"
        guard i.deviceConnected else {
            return Row(id: "output", name: name, state: "no device connected", indicator: .unknown)
        }
        var parts: [String] = []
        switch i.link {
        case .usb:
            parts.append("USB")
        case .bluetooth:
            parts.append(cap(i.codecLabel).map { "Bluetooth (\($0))" } ?? "Bluetooth")
        case .none:
            parts.append("no link")
        }
        if let rate = cap(i.outputRateLabel) { parts.append(rate) }
        if let gain = i.outputHighGain { parts.append(gain ? "high gain" : "normal gain") }
        if !i.engineRunning {
            // "(metering off)" named a switch, which is wrong whenever the
            // engine was asked to run and couldn't; the Source row above
            // carries the reason.
            parts.append(i.callHold ? "level not measured (paused for a call)"
                                    : "level not measured (engine off)")
        } else if let db = i.currentLevelDb {
            parts.append(String(format: "%.0f dBFS", db))
        } else {
            parts.append("silent")
        }
        return Row(id: "output", name: name, state: parts.joined(separator: " · "),
                  indicator: .passthrough)
    }

    // MARK: - Shared

    private static let maxFieldLength = 40

    private static func cap(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s.count > maxFieldLength ? String(s.prefix(maxFieldLength - 1)) + "…" : s
    }
}

/// Compact chain view: what happens to audio between the source and the
/// listener's ears, five stages top to bottom. Every row says only what it
/// can measure — see `SignalPath` for the derivation and the honesty rules
/// it enforces.
struct SignalPathView: View {
    @EnvironmentObject var controller: QudelixController
    @EnvironmentObject var stageState: StageState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signal path")
                .font(.system(size: 12, weight: .medium))

            VStack(alignment: .leading, spacing: 7) {
                ForEach(SignalPath.rows(inputs)) { row in
                    rowView(row)
                }
            }

            Text("Each row reports only what it can measure from here — a "
                 + "stage this app can't verify says so, rather than guessing.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inputs: SignalPath.Inputs {
        var connected = false
        if case .connected = controller.connection { connected = true }
        return SignalPath.Inputs(
            deviceConnected: connected,
            detectQuality: stageState.detectQuality,
            engineRunning: stageState.engine.isRunning,
            callHold: stageState.engine.callHold,
            qualityVerdict: stageState.qualityVerdict,
            engineProblem: stageState.engineFailure?.summary,
            mixerRateHz: stageState.watcher.defaultOutput?.sampleRate,
            mixerDeviceName: stageState.outputName,
            engineMode: stageState.engine.isRunning ? stageState.engine.mode : nil,
            stage: stageState.stage,
            eqEnabled: controller.eqEnabled,
            bandCount: controller.bandCount,
            mutedBandCount: controller.mutedBands.count,
            activePresetName: controller.activePreset.map(controller.presetLabel),
            preGain: controller.preGain,
            link: controller.link,
            codecLabel: controller.codecLabel,
            outputRateLabel: controller.sampleRate,
            outputHighGain: controller.outputHighGain,
            currentLevelDb: stageState.currentLevelDb)
    }

    private func rowView(_ row: SignalPath.Row) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // The glyph encodes altering / passing through / unknown, which
            // the row's own text does not repeat — so it is named rather
            // than hidden.
            Image(systemName: icon(row.indicator))
                .accessibilityLabel(indicatorDescription(row.indicator))
                .font(.system(size: 9))
                .foregroundStyle(color(row))
                .frame(width: 12)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                // Every field that can carry a device- or radio-supplied
                // string (preset name, codec, rate label) flows into here —
                // verbatim, so it can never be read as Markdown.
                Text(verbatim: row.state)
                    .font(.system(size: 9))
                    .foregroundStyle(color(row))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// Spoken form of the indicator glyph. It carries meaning the row text
    /// does not restate, so hiding it would lose information.
    private func indicatorDescription(_ i: SignalPath.Indicator) -> String {
        switch i {
        case .altering: return "altering the audio"
        case .passthrough: return "passing through unchanged"
        case .unknown: return "not observable"
        }
    }

    private func icon(_ indicator: SignalPath.Indicator) -> String {
        switch indicator {
        case .altering: return "waveform"
        case .passthrough: return "arrow.down"
        case .unknown: return "questionmark"
        }
    }

    private func color(_ row: SignalPath.Row) -> AnyShapeStyle {
        switch row.emphasis {
        case .good: return AnyShapeStyle(.green)
        case .caution: return AnyShapeStyle(.yellow)
        case .warning: return AnyShapeStyle(.orange)
        case .neutral:
            return AnyShapeStyle(row.indicator == .unknown ? .tertiary : .secondary)
        }
    }
}
