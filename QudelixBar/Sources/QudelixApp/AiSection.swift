import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@MainActor
final class AiSection {
    let widget: Widget
    let layout: SplitLayout

    private let model: AiStudioModel
    private let parent: () -> UnsafeMutablePointer<GtkWindow>?
    private let providerRow: Widget
    private let modelRow: Widget
    private let keyRow: Widget
    private let keyStatus: Widget
    private let forgetButton: Widget
    private let billing: Widget
    private let headphoneRow: Widget
    private let kindRow: Widget
    private let noteRow: Widget
    private let bands: Widget
    private let generateButton: Widget
    private let researchButton: Widget
    private let refreshSwitch: Widget
    private let spinner = Ui.spinner()
    private let phase: Widget
    private let cancelButton: Widget
    private let hint: Widget
    private let error: Widget
    private let draftGroup: Widget
    private let curve = CurvePreviewView()
    private let draftTitle: Widget
    private let draftSubtitle: Widget
    private let rationale: Widget
    private let notes: Widget
    private let applyButton: Widget
    private let saveButton: Widget
    private let discardButton: Widget
    private let reason: Widget
    private let summary: Widget
    private let dossierGroup: Widget
    private let dossier: Widget
    private let researchInfo: Widget
    private var shownProviders: [LibraryChoice] = []
    private var shownKinds: [LibraryChoice] = []
    private let designGroup: Widget
    private let providerGroup: Widget
    private var keyFirst = false
    private var state = AiState()
    private var updating = false
    private(set) var dialog: UnsafeMutableRawPointer?

    init(model: AiStudioModel, parent: @escaping () -> UnsafeMutablePointer<GtkWindow>?) {
        self.model = model
        self.parent = parent

        providerRow = adw_combo_row_new()!
        adw_preferences_row_set_title(providerRow.typed(AdwPreferencesRow.self), "Provider")
        adw_combo_row_set_use_subtitle(providerRow.typed(AdwComboRow.self), 1)
        modelRow = adw_entry_row_new()!
        adw_preferences_row_set_title(modelRow.typed(AdwPreferencesRow.self), "Model")
        keyRow = adw_password_entry_row_new()!
        adw_preferences_row_set_title(keyRow.typed(AdwPreferencesRow.self), AiStudioModel.keyRowTitle)
        adw_entry_row_set_show_apply_button(keyRow.typed(AdwEntryRow.self), 1)
        keyStatus = Ui.label("", classes: ["caption"])
        forgetButton = Ui.button("Forget key", classes: ["flat"])
        billing = Ui.label(AiStudioModel.billingCaption)
        let keyBox = Ui.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Ui.append(keyBox, keyStatus)
        Ui.append(keyBox, forgetButton)

        let provider = Ui.group("AI preset studio",
                                "Your own account at the provider. The key stays in a private file on this computer.")
        Ui.add(provider, providerRow)
        Ui.add(provider, modelRow)
        Ui.add(provider, keyRow)
        Ui.add(provider, Ui.extras([keyBox, billing]))

        headphoneRow = adw_entry_row_new()!
        adw_preferences_row_set_title(headphoneRow.typed(AdwPreferencesRow.self), "Headphones")
        kindRow = adw_combo_row_new()!
        adw_preferences_row_set_title(kindRow.typed(AdwPreferencesRow.self), "Preset kind")
        adw_combo_row_set_use_subtitle(kindRow.typed(AdwComboRow.self), 1)
        noteRow = adw_entry_row_new()!
        adw_preferences_row_set_title(noteRow.typed(AdwPreferencesRow.self), "Anything specific? (optional)")
        bands = Ui.label("")
        refreshSwitch = adw_switch_row_new()!
        adw_preferences_row_set_title(refreshSwitch.typed(AdwPreferencesRow.self), "Research again")
        adw_action_row_set_subtitle(refreshSwitch.typed(AdwActionRow.self), "Ask the provider again instead of using the saved research")
        generateButton = Ui.button("Generate", classes: ["suggested-action"])
        researchButton = Ui.button("Research only")
        cancelButton = Ui.button("Cancel", classes: ["flat"])
        phase = Ui.label("", classes: ["caption"])
        hint = Ui.label("")
        error = Ui.label("", classes: ["caption", "error"])
        let actions = Ui.buttonRow([generateButton, researchButton])
        let progress = Ui.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Ui.append(progress, spinner)
        Ui.append(progress, phase)
        Ui.append(progress, cancelButton)
        Ui.setSpinning(spinner, false)

        let design = Ui.group("Design a preset")
        Ui.add(design, headphoneRow)
        Ui.add(design, kindRow)
        Ui.add(design, noteRow)
        Ui.add(design, refreshSwitch)
        Ui.add(design, Ui.extras([bands, actions, progress, hint, error]))

        draftGroup = Ui.group("Draft")
        draftTitle = Ui.label("", classes: ["heading"])
        draftSubtitle = Ui.label("")
        rationale = Ui.label("", classes: [])
        notes = Ui.label("")
        applyButton = Ui.button("Apply", classes: ["suggested-action"])
        saveButton = Ui.button("Save")
        gtk_widget_set_tooltip_text(saveButton, "Save to library")
        Accessible.setLabel(saveButton, "Save to library")
        discardButton = Ui.button("Discard", classes: ["flat"])
        reason = Ui.label("", classes: ["caption", "warning"])
        summary = Ui.label("", classes: ["caption"])
        let draftButtons = Ui.buttonRow([applyButton, saveButton, discardButton])
        let card = Ui.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        for child in [draftTitle, draftSubtitle, curve.area, rationale, notes, draftButtons, reason, summary] {
            Ui.append(card, child)
        }
        Ui.add(draftGroup, Ui.extras([card]))
        Ui.show(draftGroup, false)

        dossierGroup = Ui.group("What the provider knows")
        researchInfo = Ui.label("")
        dossier = Ui.label("", classes: [])
        let dossierBox = Ui.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Ui.append(dossierBox, researchInfo)
        Ui.append(dossierBox, dossier)
        Ui.add(dossierGroup, dossierBox)
        Ui.show(dossierGroup, false)

        let privacy = Ui.group("What leaves this computer")
        Ui.add(privacy, Ui.label(AiStudioModel.privacyNote))

        self.designGroup = design
        self.providerGroup = provider
        layout = SplitLayout(top: [], left: [design, provider], right: [draftGroup, dossierGroup, privacy])
        widget = layout.widget
        connect()
        model.addObserver { [weak self] state in onLive { self?.update(state) } }
    }

    private func connect() {
        let model = self.model
        Signals.onNotify(providerRow, property: "selected") { [weak self] _ in
            onMain {
                guard let self, !self.updating else { return }
                let index = Int(adw_combo_row_get_selected(self.providerRow.typed(AdwComboRow.self)))
                if self.state.providers.indices.contains(index) { model.setProvider(self.state.providers[index].id) }
            }
        }
        Signals.onNotify(kindRow, property: "selected") { [weak self] _ in
            onMain {
                guard let self, !self.updating else { return }
                let index = Int(adw_combo_row_get_selected(self.kindRow.typed(AdwComboRow.self)))
                if self.state.kinds.indices.contains(index) { model.setKind(self.state.kinds[index].id) }
            }
        }
        for (row, apply) in [(modelRow, { (text: String) in model.setModel(text) }),
                             (headphoneRow, { (text: String) in model.setHeadphone(text) }),
                             (noteRow, { (text: String) in model.setNote(text) })] {
            Signals.connect(row, signal: "changed") { [weak self] in
                onMain {
                    guard let self, !self.updating else { return }
                    apply(Ui.text(of: row))
                }
            }
        }
        Signals.connect(keyRow, signal: "apply") { [weak self] in
            onMain {
                guard let self else { return }
                let typed = Ui.text(of: self.keyRow)
                if model.saveKey(typed) { Ui.setText(ofEditable: self.keyRow, "") }
            }
        }
        Signals.onNotify(refreshSwitch, property: "active") { [weak self] _ in
            onMain {
                guard let self, !self.updating else { return }
                model.setRefreshResearch(adw_switch_row_get_active(self.refreshSwitch.opaque) != 0)
            }
        }
        Signals.connect(generateButton, signal: "clicked") { onMain { model.generate() } }
        Signals.connect(researchButton, signal: "clicked") { onMain { model.research() } }
        Signals.connect(cancelButton, signal: "clicked") { onMain { model.cancel() } }
        Signals.connect(applyButton, signal: "clicked") { onMain { model.apply() } }
        Signals.connect(saveButton, signal: "clicked") { onMain { model.saveDraftToLibrary() } }
        Signals.connect(discardButton, signal: "clicked") { onMain { model.discardDraft() } }
        Signals.connect(forgetButton, signal: "clicked") { [weak self] in onMain { self?.presentForget() } }
    }

    private func update(_ next: AiState) {
        let previous = state
        state = next
        updating = true
        defer { updating = false }

        if shownProviders != next.providers {
            shownProviders = next.providers
            let names = gtk_string_list_new(nil)!
            for choice in next.providers { gtk_string_list_append(names, choice.label) }
            adw_combo_row_set_model(providerRow.typed(AdwComboRow.self), names)
        }
        if shownKinds != next.kinds {
            shownKinds = next.kinds
            let names = gtk_string_list_new(nil)!
            for choice in next.kinds { gtk_string_list_append(names, choice.label) }
            adw_combo_row_set_model(kindRow.typed(AdwComboRow.self), names)
        }
        if let index = next.providers.firstIndex(where: { $0.id == next.provider }),
           Int(adw_combo_row_get_selected(providerRow.typed(AdwComboRow.self))) != index {
            adw_combo_row_set_selected(providerRow.typed(AdwComboRow.self), UInt32(index))
        }
        if let index = next.kinds.firstIndex(where: { $0.id == next.kind }),
           Int(adw_combo_row_get_selected(kindRow.typed(AdwComboRow.self))) != index {
            adw_combo_row_set_selected(kindRow.typed(AdwComboRow.self), UInt32(index))
        }
        adw_preferences_row_set_title(modelRow.typed(AdwPreferencesRow.self), Ui.escaped("Model (default \(next.defaultModel))"))
        Ui.setText(ofEditable: modelRow, next.model)
        Ui.setText(ofEditable: headphoneRow, next.headphone)
        Ui.setText(ofEditable: noteRow, next.note)
        adw_switch_row_set_active(refreshSwitch.opaque, next.refreshResearch ? 1 : 0)

        switch next.keyStatus {
        case .none: Ui.setText(keyStatus, "No key saved for this provider.")
        case .saved: Ui.setText(keyStatus, "Key saved.")
        case .environment: Ui.setText(keyStatus, "Key taken from the environment.")
        case .unsafeMode: Ui.setText(keyStatus, "The saved key can be read by other users. Save it again.")
        }
        Ui.show(forgetButton, next.keyStatus == .saved || next.keyStatus == .unsafeMode)
        Ui.setText(bands, "\(next.bandCount) bands \u{2014} the bank the device is in now.")

        Ui.show(spinner, next.busy)
        Ui.setSpinning(spinner, next.busy)
        switch next.phase {
        case .idle: Ui.setText(phase, nil)
        case .researching: Ui.setText(phase, "Researching\u{2026}")
        case .designing: Ui.setText(phase, "Designing preset\u{2026}")
        }
        Ui.show(cancelButton, next.busy)
        Ui.enable(generateButton, next.canGenerate)
        Ui.enable(researchButton, next.phase == .idle && next.headphone.trimmingCharacters(in: .whitespaces).count >= 2
                  && next.keyStatus != .none)
        let needsKey = next.keyStatus == .none && next.kind != "correction"
        if needsKey, next.generateHint != nil {
            let named = !next.headphone.trimmingCharacters(in: .whitespaces).isEmpty
            Ui.setText(hint, named ? "Add an API key to start." : "Add an API key, then name your headphones.")
        } else {
            Ui.setText(hint, next.generateHint)
        }
        let noKey = next.keyStatus == .none
        if noKey != keyFirst {
            keyFirst = noKey
            layout.reorderLeft(noKey ? [providerGroup, designGroup] : [designGroup, providerGroup])
        }
        Ui.setText(error, next.error)

        if previous.draft?.preview != next.draft?.preview { curve.update(next.draft?.preview) }
        Ui.show(draftGroup, next.draft != nil)
        if previous.draft?.preview != next.draft?.preview, next.draft != nil { layout.reveal(draftGroup) }
        Ui.setText(draftTitle, next.draft?.name)
        Ui.setText(draftSubtitle, next.draft?.preview.subtitle)
        Ui.setText(rationale, next.draft?.rationale)
        Ui.setText(notes, next.draft.map { $0.notes.joined(separator: "\n") })
        Ui.enable(applyButton, next.applyRefusal == nil)
        Ui.setText(reason, next.applyRefusal)
        Ui.setText(summary, next.summary)

        Ui.show(dossierGroup, !next.dossier.isEmpty)
        Ui.setText(researchInfo, next.researchInfo)
        Ui.setText(dossier, next.dossier.isEmpty ? nil : next.dossier.map { "\($0.label): \($0.text)" }.joined(separator: "\n"))
    }

    @discardableResult
    func presentForget() -> UnsafeMutableRawPointer? {
        let label = state.providers.first { $0.id == state.provider }?.label ?? "provider"
        let dialog = Ui.confirm(parent: parent(), title: AiStudioModel.forgetKeyTitle(label),
                                message: AiStudioModel.forgetKeyMessage, action: "Forget key",
                                destructive: true) { [weak self] confirmed in
            onMain {
                if confirmed { self?.model.forgetKey() }
                self?.dialog = nil
            }
        }
        self.dialog = dialog
        return dialog
    }
}
