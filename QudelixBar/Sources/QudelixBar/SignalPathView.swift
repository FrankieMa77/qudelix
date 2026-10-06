import AppKit
import SwiftUI

enum SignalPath {
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let state: String
        let indicator: Indicator
        var emphasis: Emphasis = .neutral
    }

    enum Indicator: Equatable {
        case altering
        case passthrough
        case unknown
    }

    enum Emphasis: Equatable {
        case neutral, good, caution, warning
    }

    struct Inputs {
        var deviceConnected = true

        var detectQuality = true
        var engineRunning = false
        var callHold = false
        var qualityVerdict: QualityAnalyzer.Verdict?
        var engineProblem: String?

        var mixerRateHz: Double?
        var mixerDeviceName: String?

        var engineMode: StageEngine.Mode?
        var stage = StageSettings()
        var impulseActive = false
        var perAppCount = 0

        var bassGuardActive = false

        var eqEnabled = true
        var bandCount = 10
        var mutedBandCount = 0
        var activePresetName: String?
        var preGain: Double = 0

        var link: QudelixController.Link = .none
        var codecLabel: String?
        var outputRateLabel: String?
        var outputHighGain: Bool?
        var currentLevelDb: Double?
    }

    static func rows(_ i: Inputs) -> [Row] {
        [sourceRow(i), mixerRow(i), appRow(i), eqRow(i), outputRow(i)]
    }

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

    private static func mixerRow(_ i: Inputs) -> Row {
        let name = "macOS mixer"
        guard let rate = i.mixerRateHz, rate.isFinite, rate > 0 else {
            return Row(id: "mixer", name: name,
                      state: "no output device — can't read a rate",
                      indicator: .unknown)
        }
        let whose = cap(i.mixerDeviceName).map { "\($0) — " } ?? ""
        return Row(id: "mixer", name: name,
                  state: whose + String(format: "running at %g kHz — whether the source "
                                + "matched that rate isn't observable from here", rate / 1000),
                  indicator: .unknown)
    }

    private static func appRow(_ i: Inputs) -> Row {
        let name = "This app"
        guard let mode = i.engineMode else {
            return Row(id: "app", name: name,
                      state: "nothing in this app is altering the audio",
                      indicator: .passthrough)
        }
        switch mode {
        case .monitor:
            return Row(id: "app", name: name,
                      state: "not in the path — metering only, audio untouched",
                      indicator: .passthrough)
        case .insert:
            return Row(id: "app", name: name, state: insertDescription(i),
                      indicator: .altering)
        }
    }

    static func perAppLabel(_ count: Int) -> String {
        "per-app EQ (\(count) app\(count == 1 ? "" : "s"))"
    }

    private static func insertDescription(_ i: Inputs) -> String {
        let apps = i.perAppCount > 0 ? perAppLabel(i.perAppCount) : nil
        let stage = stageDescription(i.stage, impulse: i.impulseActive,
                                     guarding: i.bassGuardActive)
        guard i.stage.enabled || i.impulseActive else { return apps ?? stage }
        guard let apps else { return stage }
        return stage + " · " + apps
    }

    private static func stageDescription(_ s: StageSettings,
                                         impulse: Bool,
                                         guarding: Bool) -> String {
        guard !s.isAudiblyNeutral || impulse else {
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
        if impulse { parts.append("impulse response") }
        if s.loudnessValue { parts.append("loudness compensation") }
        if s.limiterValue { parts.append("true-peak limiter") }
        if s.bassGuardValue, guarding { parts.append("dynamic bass") }
        let detail = parts.isEmpty ? "processing the stereo mix"
                                   : parts.joined(separator: ", ") + " active"
        return "Soundstage inserted — " + detail
    }

    private static func eqRow(_ i: Inputs) -> Row {
        let name = "Qudelix EQ"
        guard i.deviceConnected else {
            return Row(id: "eq", name: name, state: "no device connected", indicator: .unknown)
        }
        guard i.eqEnabled else {
            return Row(id: "eq", name: name, state: "off", indicator: .passthrough)
        }
        let preset = cap(i.activePresetName).map { "\u{201C}\($0)\u{201D}" } ?? "custom"
        let active = max(i.bandCount - i.mutedBandCount, 0)
        let bands = i.mutedBandCount > 0
            ? "\(active) of \(i.bandCount) bands (\(i.mutedBandCount) muted)"
            : "\(i.bandCount)-band"
        let state = "on — \(bands), \(preset), pre-gain "
            + String(format: "%+.1f dB", i.preGain)
        return Row(id: "eq", name: name, state: state, indicator: .altering)
    }

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

    private static let maxFieldLength = 40

    private static func cap(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s.count > maxFieldLength ? String(s.prefix(maxFieldLength - 1)) + "…" : s
    }
}

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
            impulseActive: stageState.impulseInPath,
            perAppCount: stageState.perAppActiveCount,
            bassGuardActive: stageState.stage.bassGuardValue
                && !stageState.bassGuardInert,
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
                Text(verbatim: row.state)
                    .font(.system(size: 9))
                    .foregroundStyle(color(row))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

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
        case .caution: return AnyShapeStyle(Color.cautionText)
        case .warning: return AnyShapeStyle(.orange)
        case .neutral:
            return AnyShapeStyle(row.indicator == .unknown ? .tertiary : .secondary)
        }
    }
}

enum CautionTint {
    static let lightRed = 112.0 / 255
    static let lightGreen = 74.0 / 255
    static let lightBlue = 0.0

    static func resolved(for appearance: NSAppearance) -> NSColor {
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return .systemYellow
        }
        return NSColor(srgbRed: lightRed, green: lightGreen, blue: lightBlue, alpha: 1)
    }
}

extension Color {
    static let cautionText = Color(nsColor: NSColor(name: nil) { CautionTint.resolved(for: $0) })
}
