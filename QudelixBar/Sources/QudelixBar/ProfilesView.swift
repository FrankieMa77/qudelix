import SwiftUI

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
                VStack(spacing: 3) {
                    ForEach(profileRules.rules) { rule in
                        ruleRow(rule)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func suggestionBanner(_ s: ProfileRules.Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Switch to \u{201C}" + s.presetLabel
                 + "\u{201D} for " + s.outputName + "?")
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
            Label("Link this output", systemImage: "link")
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
                Text(verbatim: rule.outputName)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                // `presetLabel` reads the *current* group's name table, so a
                // rule bound in the other mode would be labelled with a name
                // belonging to a slot it has nothing to do with. Only name it
                // when the rule and the device agree on the group.
                switch rule.standing(inGroup: profileRules.currentEqGroupRaw) {
                case .matches, .unmarked:
                    Text(verbatim: controller.presetLabel(rule.presetIndex))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                case .wrongGroup:
                    Text("Slot \(rule.presetIndex + 1), saved in "
                         + "\(rule.eqGroupRaw == 2 ? "20" : "10")-band mode — "
                         + "not used while the device is in the other one")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                    .accessibilityLabel("Remove this profile")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help("Remove this profile")
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
    }
}
