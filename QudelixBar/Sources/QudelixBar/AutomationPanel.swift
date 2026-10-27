import SwiftUI

struct AutomationPanel: View {
    @EnvironmentObject var controller: QudelixController
    @EnvironmentObject var automation: EqAutomation
    @EnvironmentObject var stageState: StageState
    @EnvironmentObject var presetLibrary: PresetLibrary
    @EnvironmentObject var suggestions: HeadphoneSuggestions
    @State private var hiddenFitNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            referenceRow
            referenceText
            followNote
            trimRow
            trimText
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: automation.currentReference) { _, _ in hiddenFitNote = suggestions.fitNote }
        .onChange(of: automation.referenceSource) { _, _ in hiddenFitNote = suggestions.fitNote }
        .onChange(of: suggestions.fitNote) { _, note in
            if note == nil { hiddenFitNote = nil }
        }
    }

    private var visibleFitNote: String? {
        guard let note = suggestions.fitNote, note != hiddenFitNote else { return nil }
        return note
    }

    private var referenceRow: some View {
        HStack(spacing: 6) {
            sourceMenu
            Toggle(isOn: Binding(get: { automation.showReference },
                                 set: { automation.setShowReference($0) })) {
                Text("Show").foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .fixedSize()
            .help("Draw the reference line on the graph.")
            Spacer(minLength: 0)
            fitControl
            if automation.following {
                Button("Keep") { automation.keep() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .fixedSize()
                    .help(Self.keepHelp)
            } else if automation.paused {
                Button("Resume") { automation.reenable() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .fixedSize()
                    .help("Try following again from your own EQ.")
            }
            Toggle(isOn: Binding(get: { automation.autoFit },
                                 set: { automation.setAutoFit($0) })) {
                Text("Auto-fit").foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .fixedSize()
            .help("The 5K's gains follow the reference line: only gains move, your band "
                  + "layout and saved presets stay as they are. With the listening "
                  + "reference this turns Auto-trim on. Untick to edit again; Keep "
                  + "writes what it found into your EQ.")
        }
        .font(.system(size: 9))
    }

    static let keepHelp = "Write the followed gains and pre-gain into your EQ and stop "
        + "following. It also turns Auto-trim off if it is on, since the bands now "
        + "carry the trim."

    private var sourceMenu: some View {
        Menu {
            ForEach(ReferenceSource.allCases) { source in
                Button {
                    automation.setReferenceSource(source)
                } label: {
                    if automation.referenceSource == source {
                        Label(Self.title(source), systemImage: "checkmark")
                    } else {
                        Text(Self.title(source))
                    }
                }
            }
        } label: {
            Text("Ref: " + automation.referenceSource.label)
                .font(.system(size: 9))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.mini)
        .fixedSize()
        .help("Where the reference line comes from")
    }

    static func title(_ source: ReferenceSource) -> String {
        switch source {
        case .auto: return "Auto \u{2014} the AutoEq fit when there is one, else listening"
        case .catalog: return "AutoEq \u{2014} the measurement-based correction"
        case .listening: return "Listening \u{2014} your EQ plus what Auto-trim measures"
        }
    }

    @ViewBuilder
    private var fitControl: some View {
        if suggestions.fitting {
            Text("fitting\u{2026}")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize()
        } else {
            Button(automation.currentReference == nil ? "Fit" : "Re-fit") { fit() }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .fixedSize()
                .disabled(!controller.canWriteNow)
                .help(automation.currentReference == nil
                      ? "Fit a correction for these headphones from their measurement "
                        + "\u{2014} one click, with the recommended target. Opens Import "
                        + "if the headphones need choosing."
                      : "Fit this headphone's correction again with the recommended "
                        + "target, for the current band layout.")
        }
    }

    private func fit() {
        suggestions.quickFit(name: presetLibrary.headphoneName, controller: controller) { query, note in
            AutoEqIndex.shared.query = query
            controller.lastImportSummary = note
            controller.requestPane(.importing)
        }
    }

    private var referenceText: some View {
        let lines = AutomationReadout.referenceTexts(
            source: automation.effectiveSource, reference: automation.currentReference,
            trim: automation.trim, autoTrimOn: automation.autoTrimOn,
            mode: automation.autoTrimMode)
        return ViewThatFits(in: .horizontal) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line).lineLimit(1)
            }
            Text(verbatim: lines.last ?? "").lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .padding(.leading, 2)
    }

    @ViewBuilder
    private var followNote: some View {
        if let fitNote = visibleFitNote {
            Text(verbatim: fitNote)
                .font(.system(size: 9))
                .foregroundStyle(Color.cautionText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
        }
        let note = AutomationReadout.followNote(
            following: automation.following, paused: automation.paused,
            waitingReason: automation.wantsFollow ? automation.waitingReason : nil,
            deviationDb: automation.deviationDb,
            referenceActive: automation.referenceActive)
        if let note {
            Text(verbatim: note)
                .font(.system(size: 9))
                .foregroundStyle(automation.paused ? AnyShapeStyle(Color.cautionText) : AnyShapeStyle(.secondary))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
        }
    }

    private var trimRow: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { automation.autoTrimOn },
                                 set: { automation.setAutoTrim(on: $0) })) {
                Text("Auto-trim").foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .fixedSize()
            .help("Slowly trims what's playing toward the balance you usually listen to, "
                  + "at most a few dB, level-matched. It moves the 5K's bands a little at "
                  + "a time and your saved presets stay untouched until you Keep. Turning "
                  + "it on enables quality detection (Level pane).")

            Picker("", selection: Binding(get: { automation.autoTrimMode },
                                          set: { automation.setAutoTrim(mode: $0) })) {
                ForEach(TrimMode.allCases) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.mini)
            .fixedSize()
            .disabled(!automation.autoTrimOn)
            .accessibilityLabel("Auto-trim mode")

            Slider(value: Binding(get: { automation.autoTrimStrength },
                                  set: { automation.setAutoTrim(strength: ($0 * 100).rounded() / 100) }),
                   in: 0...1)
                .controlSize(.mini)
                .frame(maxWidth: 90)
                .disabled(!automation.autoTrimOn || automation.autoTrimMode == .audiophile)
                .accessibilityLabel("Auto-trim strength")
                .accessibilityValue("\(Int((automation.autoTrimStrength * 100).rounded())) percent")
            Spacer(minLength: 0)
        }
        .font(.system(size: 9))
    }

    private var trimText: some View {
        let lines = AutomationReadout.trimLines(
            on: automation.autoTrimOn, detecting: stageState.detectQuality,
            mode: automation.autoTrimMode, trim: automation.trim,
            baseline: automation.baseline, advisory: automation.advisory)
        return ViewThatFits(in: .horizontal) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line).lineLimit(1)
            }
            Text(verbatim: lines.last ?? "").lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 9).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.leading, 2)
    }
}
