import SwiftUI

/// The Profiles section: known output-to-preset pairings, a way to bind the
/// current one, and the confirmation banner for a switch `ProfileRules` is
/// suggesting right now.
///
/// This view only calls into `ProfileRules` and reads from
/// `QudelixController` — it never writes to the device itself. It is not
/// wired into `PopoverView` yet; see the integration note below for exactly
/// what that wiring looks like.
///
/// --- Integration note (for `QudelixController.swift` and `PopoverView.swift`) ---
///
/// 1. Instantiate one `ProfileRules` alongside the other app-owned state —
///    `App.swift`, next to `controller` and `stageState`:
///        @StateObject private var profileRules = ProfileRules()
///    inject it the same way (`.environmentObject(profileRules)`), and call
///    `profileRules.start()` where `controller.start()` / `stageState.start()`
///    already are.
///
/// 2. Wire the three closures once, also in `App.swift`, after `controller`
///    exists:
///        profileRules.onApplyPreset = { [weak controller] idx in
///            controller?.loadPreset(idx)
///        }
///        profileRules.presetLabel = { [weak controller] idx in
///            controller?.presetLabel(idx) ?? "Preset \(idx + 1)"
///        }
///        profileRules.canApplyNow = { [weak controller, weak profileRules] in
///            guard let controller, case .connected = controller.connection,
///                  controller.compatibility.canWrite,
///                  controller.activePreset != nil        // not a dirty custom curve
///            else { return false }
///            return profileRules?.editingNow != true      // see step 3
///        }
///    `loadPreset` is already the gated, clamped write path (`canWriteEq`,
///    range-checked index) — this file never needs to know any of that.
///
/// 3. `PopoverView` is the only place that knows a band slider is mid-drag
///    (`editingBand`, private `@State` in `EqEditorView`) — `ProfileRules`
///    has no way to see it otherwise. Add one published flag to carry that
///    one bit across, e.g. on `ProfileRules` itself (`@Published var
///    editingNow = false`, already assumed by the `canApplyNow` closure
///    above), and set it from `PopoverView`:
///        .onChange(of: editingBand) { _, newValue in
///            profileRules.editingNow = newValue != nil
///        }
///    placed wherever `editingBand` is already declared. Without this, an
///    automatic switch can only be *mostly* ruled out during a live drag —
///    the hard rule ("never apply while editing") deserves the real signal.
///
/// 4. Add a case to `PopoverView.Pane` (or a row in an existing pane —
///    "Presets" reads naturally) that shows `ProfilesView()`. It needs both
///    `controller` and `profileRules` in the environment, which step 1
///    already provides everywhere `PopoverView` itself is shown.
///
/// Nothing above lets this file (or `ProfileRules`) write to the device —
/// every write still goes through `controller.loadPreset`, called from
/// exactly one place: the closure in step 2.
struct ProfilesView: View {
    @EnvironmentObject var controller: QudelixController
    @EnvironmentObject var profileRules: ProfileRules

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let suggestion = profileRules.suggestion {
                suggestionBanner(suggestion)
            }

            HStack {
                Text("Profiles").font(.system(size: 11, weight: .medium))
                Spacer()
                bindButton
            }

            // Plain about what this actually detects: an output device, not
            // the headphones on the end of it. Two headphones sharing one
            // adapter — or two adapters of the same cheap model — can look
            // identical to this feature even though they aren't.
            Text("Pairs an output device with an EQ preset, and offers to "
                + "switch when that output becomes active. This matches the "
                + "output device itself, not your headphones — two pairs "
                + "sharing one adapter will be treated as the same output.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if profileRules.rules.isEmpty {
                Text("No profiles yet.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(profileRules.rules) { rule in
                            ruleRow(rule)
                        }
                    }
                }
                .frame(height: 140)
            }
        }
    }

    @ViewBuilder
    private func suggestionBanner(_ s: ProfileRules.Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Switch to \u{201C}\(s.presetLabel)\u{201D} for \(s.outputName)?")
                .font(.system(size: 11, weight: .medium))
            // The one place this file can discard something without saying
            // so — an unsaved custom curve — so it says so, right here,
            // before the button that would do it.
            if controller.activePreset == nil {
                Text("Your current EQ is a custom setting that isn't saved "
                    + "to a slot — switching will replace it.")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Switch") { profileRules.confirmSuggestion() }
                    .controlSize(.small)
                Button("Not now") { profileRules.dismissSuggestion() }
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var bindButton: some View {
        Button {
            guard let uid = profileRules.currentOutputUID,
                  let name = profileRules.currentOutputName,
                  let preset = controller.activePreset else { return }
            profileRules.bind(outputUID: uid, outputName: name, presetIndex: preset)
        } label: {
            Label("Bind current", systemImage: "link")
        }
        .controlSize(.small)
        .font(.system(size: 10))
        .disabled(profileRules.currentOutputUID == nil || controller.activePreset == nil)
        .help(controller.activePreset == nil
              ? "Load or save a preset first — there's no saved slot to bind yet."
              : "Remember the current output as the home for this preset.")
    }

    private func ruleRow(_ rule: ProfileRule) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.outputName)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(controller.presetLabel(rule.presetIndex))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Auto", isOn: Binding(
                get: { rule.automatic },
                set: { profileRules.setAutomatic($0, forUID: rule.outputUID) }))
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                .font(.system(size: 9))
                .disabled(!rule.confirmed)
                .help(rule.confirmed
                      ? "Switch to this preset automatically when this output "
                        + "becomes active — no confirmation asked."
                      : "Confirm a switch for this output at least once before "
                        + "this can be turned on.")
            Button {
                profileRules.removeRule(outputUID: rule.outputUID)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help("Remove this profile")
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
    }
}
