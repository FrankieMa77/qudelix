import SwiftUI

struct AIPresetSection: View {
    @EnvironmentObject var controller: QudelixController
    @EnvironmentObject var library: PresetLibrary
    @EnvironmentObject var studio: AIPresetStudio
    @EnvironmentObject var profileRules: ProfileRules

    @State private var expanded = false
    @State private var kind: AIPresetKind = .correction
    @State private var note = ""
    @State private var keyEntry = ""
    @State private var enteringKey = false
    @State private var confirmingForget = false
    @State private var keyPresent = false
    @State private var refreshResearch = false
    @State private var slotChoice: Int?

    static let maxNote = AIPresetService.maxNoteLength
    static let bodyHeight: CGFloat = 195
    static let applyLabel = "Apply"
    static let researchAgainLabel = "Research again"
    static let forgetKeyLabel = "Forget key"
    static let forgetKeyMessage = "It is deleted from the macOS Keychain. You will "
        + "need to paste it again, and many providers show a key only once."

    static func forgetKeyTitle(_ provider: AIProvider) -> String {
        "Forget the " + provider.label + " key?"
    }

    static let billingCaption = "Uses your own account at the provider "
        + "\u{2014} generations are billed to you."
    static let unsavedCurveWarning =
        "Your current EQ is a custom setting that isn\u{2019}t saved to a "
        + "slot \u{2014} applying this will replace it."

    private var headphoneName: String {
        library.headphoneName.trimmingCharacters(in: .whitespaces)
    }

    private var bandCount: Int { controller.eqGroup.bandCount }

    private var named: Bool { headphoneName.count >= 2 }

    private var canGenerate: Bool {
        named && !studio.busy && (keyPresent || !studio.needsKey(for: kind))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    providerRow
                    keyRow
                    headphoneRow
                    researchRow
                    Divider().padding(.vertical, 1)
                    kindRow
                    noteRow
                    generateRow
                    if let draft = studio.draft { draftCard(draft) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 2)
                .padding(.top, 6)
            }
            .frame(maxHeight: Self.bodyHeight)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("AI preset studio")
                    .font(.system(size: 11, weight: .medium))
                if studio.busy {
                    ProgressView().controlSize(.mini)
                    Button("Cancel") { studio.cancel() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9))
                }
            }
        }
        .onAppear {
            #if DEBUG
            if studio.previewExpanded { expanded = true }
            #endif
            refreshKeyPresence()
            studio.refreshDossierInfo(for: headphoneName)
        }
        .onChange(of: studio.provider) {
            keyEntry = ""
            enteringKey = false
            refreshKeyPresence()
        }
        .onChange(of: headphoneName) {
            refreshResearch = false
            slotChoice = nil
            studio.clearDraft()
            studio.refreshDossierInfo(for: headphoneName)
        }
        .onChange(of: controller.eqGroup) {
            slotChoice = nil
            studio.clearDraft()
        }
    }

    private var providerRow: some View {
        HStack(spacing: 6) {
            Picker("", selection: $studio.provider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.label).tag(provider)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 116)
            .accessibilityLabel("AI provider")

            TextField("", text: Binding(
                get: { studio.modelEntry(for: studio.provider) },
                set: { studio.setModel($0, for: studio.provider) }),
                prompt: Text(verbatim: studio.provider.defaultModel))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 10))
                .accessibilityLabel("Model name")
                .help("The model name at your provider — leave it empty to use the "
                      + "default shown")
        }
    }

    @ViewBuilder
    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            keyControls
            Text(Self.billingCaption)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var keyControls: some View {
        HStack(spacing: 6) {
            if enteringKey {
                SecureField("API key", text: $keyEntry)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 10))
                    .onSubmit { saveKey() }
                Button("Save", action: saveKey)
                    .controlSize(.small)
                    .font(.system(size: 10))
                    .disabled(keyEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") {
                    keyEntry = ""
                    enteringKey = false
                }
                .controlSize(.mini)
                .font(.system(size: 10))
            } else {
                Image(systemName: keyPresent ? "key.fill" : "key")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(keyPresent ? "Key saved" : "No key saved")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(keyPresent ? "Replace key…" : "Set key…") {
                    keyEntry = ""
                    enteringKey = true
                }
                .controlSize(.small)
                .font(.system(size: 10))
                if keyPresent {
                    Button(Self.forgetKeyLabel) { confirmingForget = true }
                        .controlSize(.small)
                        .font(.system(size: 10))
                }
            }
        }
        .help("Your own key, kept in the macOS Keychain. It never reaches this app's "
              + "state files, its log, or anyone but the provider you picked.")
        .confirmationDialog(Text(verbatim: Self.forgetKeyTitle(studio.provider)),
                            isPresented: $confirmingForget,
                            titleVisibility: .visible) {
            Button(Self.forgetKeyLabel, role: .destructive) {
                studio.forgetKey(for: studio.provider)
                keyEntry = ""
                refreshKeyPresence()
                confirmingForget = false
            }
            Button("Cancel", role: .cancel) { confirmingForget = false }
        } message: {
            Text(verbatim: Self.forgetKeyMessage)
        }
    }

    private var headphoneRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "headphones")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            if named {
                Text(verbatim: headphoneName)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Name your headphones in the Library above — the design is "
                     + "made for a specific model.")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
        }
    }

    @ViewBuilder
    private var researchRow: some View {
        HStack(spacing: 6) {
            if studio.researchFallback {
                Text("Research didn't come back — designed from general knowledge "
                     + "instead.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if refreshResearch {
                Text("Will research this model again on the next generate.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            } else if let info = studio.dossierInfo {
                Text(verbatim: "Researched \(Self.shortDate(info.researchedAt)) · "
                     + "\(info.confidence) confidence")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(Self.researchAgainLabel) { refreshResearch = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9))
                    .help("Research this headphone again on the next generate")
            } else {
                Text("Will research this model on first generate.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private static func shortDate(_ date: Date) -> String {
        dateFormat.string(from: date)
    }

    private var kindRow: some View {
        HStack(spacing: 6) {
            Menu {
                Section("Character") {
                    ForEach(AIPresetKind.character) { k in
                        Button(k.label) { kind = k }
                    }
                }
                Section("Targets") {
                    ForEach(AIPresetKind.targets) { k in
                        Button(k.label) { kind = k }
                    }
                }
            } label: {
                Text(kind.label).font(.system(size: 10))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .frame(maxWidth: 170, alignment: .leading)
            .accessibilityLabel("Kind of preset to design")

            Spacer(minLength: 4)

            Text("\(bandCount) bands")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
                .help("The bank the device is in now. Switch it on the EQ pane.")
        }
    }

    private var noteRow: some View {
        TextField("", text: Binding(
            get: { note },
            set: { note = String($0.prefix(Self.maxNote)) }),
            prompt: Text("Anything specific? e.g. less sibilance"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.system(size: 10))
            .accessibilityLabel("Note for the designer")
    }

    private var buttonLabel: String {
        switch studio.phase {
        case .researching: return "Researching…"
        case .designing: return "Designing…"
        case .idle: return studio.busy ? "Generating…" : "Generate"
        }
    }

    private var phaseCaption: String {
        switch studio.phase {
        case .researching: return "Researching \(SafeText.scrubbed(headphoneName, limit: 24))…"
        case .designing: return "Designing preset…"
        case .idle: return ""
        }
    }

    private var generateRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    let launched = studio.generate(kind: kind, bandCount: bandCount,
                                                   headphoneName: headphoneName,
                                                   note: note,
                                                   refreshResearch: refreshResearch)
                    if launched { refreshResearch = false }
                } label: {
                    Text(buttonLabel).font(.system(size: 11))
                }
                .controlSize(.small)
                .disabled(!canGenerate)
                if studio.busy {
                    ProgressView().controlSize(.small)
                    Text(verbatim: phaseCaption)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Button("Cancel") { studio.cancel() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9))
                }
                Spacer(minLength: 4)
                if !named {
                    Text("Name your headphones")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                } else if !keyPresent, studio.needsKey(for: kind) {
                    Text("Save a key to start")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            if !keyPresent, !studio.needsKey(for: kind) {
                Text("Correction needs no key: it is taken from the published "
                     + "measurement when this model has one.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = studio.errorText {
                Text(verbatim: error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func draftCard(_ draft: AIDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: draft.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if let context = studio.draftContext {
                Text(verbatim: context.caption)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let rationale = draft.rationale {
                Text(verbatim: rationale)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: String(format: "Pre-gain %+.1f dB, worked out here from "
                                  + "the bands above.", draft.preGain))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            if let note = draft.quantisationNote {
                Text(verbatim: note)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if controller.activePreset == nil {
                Text(Self.unsavedCurveWarning)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Button(Self.applyLabel) {
                    studio.apply(draft, using: controller, group: controller.eqGroup)
                }
                .controlSize(.small)
                .font(.system(size: 10))
                .disabled(!controller.canEditEqNow || studio.applying)
                if studio.applying { ProgressView().controlSize(.mini) }
                Button("Save to library") { saveToLibrary(draft) }
                    .controlSize(.small)
                    .font(.system(size: 10))
                Menu("Write to slot…") {
                    ForEach(0..<QudelixController.presetCount, id: \.self) { i in
                        Button {
                            slotChoice = i
                        } label: {
                            Text(verbatim: "\(i + 1) · \(controller.presetLabel(i))")
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .font(.system(size: 10))
                .frame(width: 92)
                .disabled(!controller.canEditEqNow || studio.applying)
                Spacer(minLength: 4)
                Button {
                    slotChoice = nil
                    studio.clearDraft()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .accessibilityLabel("Discard this draft")
                }
                .buttonStyle(.borderless)
                .help("Discard this draft")
            }
            if let slot = slotChoice {
                overwriteRow(draft, slot: slot)
            }
            if let message = studio.applyError {
                Text(verbatim: message)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(studio.grounded
                 ? "Grounded in a published measurement of this model."
                 : "No measurement found for this model — designed from general "
                    + "knowledge.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private func overwriteRow(_ draft: AIDraft, slot: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "Slot \(slot + 1), \u{201C}\(controller.presetLabel(slot))"
                 + "\u{201D}, holds a preset on the device. Writing replaces it, and "
                 + "the device keeps no copy.")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Overwrite slot \(slot + 1)") { writeToSlot(draft, slot: slot) }
                    .controlSize(.mini)
                    .font(.system(size: 10))
                    .disabled(!controller.canEditEqNow)
                Button("Cancel") { slotChoice = nil }
                    .controlSize(.mini)
                    .font(.system(size: 10))
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
    }

    private func saveToLibrary(_ draft: AIDraft) {
        let scope: LibraryScope = profileRules.currentOutputUID.map {
            .output(uid: $0, name: profileRules.currentOutputName ?? "")
        } ?? .global
        library.clearMessage()
        library.saveCurve(name: draft.name, group: controller.eqGroup,
                          bands: draft.bands, preGain: draft.preGain,
                          sourceName: draft.name, scope: scope)
    }

    private func writeToSlot(_ draft: AIDraft, slot: Int) {
        slotChoice = nil
        guard studio.apply(draft, using: controller, group: controller.eqGroup) else {
            return
        }
        controller.savePreset(slot)
    }

    private func saveKey() {
        let key = keyEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        studio.saveKey(key, for: studio.provider)
        keyEntry = ""
        enteringKey = false
        refreshKeyPresence()
    }

    private func refreshKeyPresence() {
        keyPresent = studio.hasKey(for: studio.provider)
    }
}
