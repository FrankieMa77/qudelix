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
    private let researchRow: Widget
    private let researchLine: Widget
    private let researchAgainButton: Widget
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
    private let slotButton: Widget
    private let slotPopover: Widget
    private let slotList: Widget
    private let unsaved: Widget
    private let overwriteBox: Widget
    private let overwriteText: Widget
    private let overwriteConfirm: Widget
    private let overwriteCancel: Widget
    private let kindButton: Widget
    private let kindPopover: Widget
    private let kindList: Widget
    private let reason: Widget
    private let summary: Widget
    private let dossierGroup: Widget
    private let dossier: Widget
    private let researchInfo: Widget
    private var shownProviders: [LibraryChoice] = []
    private var shownKinds: [AiKindGroup] = []
    private var shownSlots: [PresetSlot] = []
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
        kindRow = Ui.actionRow(title: "Preset kind")
        kindButton = gtk_menu_button_new()!
        gtk_widget_set_valign(kindButton, GTK_ALIGN_CENTER)
        gtk_widget_add_css_class(kindButton, "flat")
        gtk_widget_set_tooltip_text(kindButton, "Kind of preset to design")
        Accessible.setLabel(kindButton, "Preset kind")
        kindList = Ui.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        kindPopover = Self.listPopover(kindList, height: 460)
        gtk_menu_button_set_popover(kindButton.opaque, kindPopover)
        Ui.suffix(kindRow, kindButton)
        noteRow = adw_entry_row_new()!
        adw_preferences_row_set_title(noteRow.typed(AdwPreferencesRow.self), "Anything specific? (optional)")
        bands = Ui.label("")
        researchRow = Ui.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        researchLine = Ui.label("")
        researchAgainButton = Ui.button(AiStudioModel.researchAgainLabel, classes: ["flat"])
        gtk_widget_set_valign(researchAgainButton, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(researchAgainButton, AiStudioModel.researchAgainHelp)
        Ui.append(researchRow, researchLine)
        Ui.append(researchRow, researchAgainButton)
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
        Ui.add(design, Ui.extras([researchRow, bands, actions, progress, hint, error]))

        draftGroup = Ui.group("Draft")
        draftTitle = Ui.label("", classes: ["heading"])
        draftSubtitle = Ui.label("")
        rationale = Ui.label("", classes: [])
        notes = Ui.label("", classes: [])
        applyButton = Ui.button("Apply", classes: ["suggested-action"])
        saveButton = Ui.button("Save")
        gtk_widget_set_tooltip_text(saveButton, "Save to library")
        Accessible.setLabel(saveButton, "Save to library")
        discardButton = Ui.button("Discard", classes: ["flat"])
        slotButton = gtk_menu_button_new()!
        gtk_menu_button_set_label(slotButton.opaque, AiStudioModel.writeToSlotLabel)
        gtk_widget_set_tooltip_text(slotButton, "Apply this draft and save it to a preset slot on the 5K")
        slotList = Ui.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        slotPopover = Self.listPopover(slotList)
        gtk_menu_button_set_popover(slotButton.opaque, slotPopover)
        let unsavedIcon = gtk_image_new_from_icon_name("dialog-warning-symbolic")!
        gtk_widget_set_valign(unsavedIcon, GTK_ALIGN_START)
        gtk_widget_add_css_class(unsavedIcon, "warning")
        unsaved = Ui.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Ui.append(unsaved, unsavedIcon)
        Ui.append(unsaved, Ui.label(AiStudioModel.unsavedCurveWarning, classes: []))
        overwriteText = Ui.label("", classes: ["caption", "warning"])
        overwriteConfirm = Ui.button("Overwrite", classes: ["destructive-action"])
        overwriteCancel = Ui.button("Cancel", classes: ["flat"])
        overwriteBox = Ui.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Ui.append(overwriteBox, overwriteText)
        Ui.append(overwriteBox, Ui.buttonRow([overwriteConfirm, overwriteCancel]))
        Ui.show(overwriteBox, false)
        reason = Ui.label("", classes: ["caption", "warning"])
        summary = Ui.label("", classes: ["caption"])
        let draftButtons = Ui.buttonRow([applyButton, saveButton, discardButton])
        let slotRow = Ui.buttonRow([slotButton])
        let card = Ui.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        for child in [draftTitle, draftSubtitle, curve.area, rationale, notes, unsaved, draftButtons, slotRow, overwriteBox, reason, summary] {
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
        Signals.connect(researchAgainButton, signal: "clicked") { onMain { model.setRefreshResearch(true) } }
        Signals.connect(overwriteConfirm, signal: "clicked") { onMain { model.writeToSlot() } }
        Signals.connect(overwriteCancel, signal: "clicked") { onMain { model.cancelSlotChoice() } }
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
        if shownKinds != next.kindGroups {
            shownKinds = next.kindGroups
            rebuildKinds(next.kindGroups)
        }
        if shownSlots != next.slots {
            shownSlots = next.slots
            rebuildSlots(next.slots)
        }
        if let index = next.providers.firstIndex(where: { $0.id == next.provider }),
           Int(adw_combo_row_get_selected(providerRow.typed(AdwComboRow.self))) != index {
            adw_combo_row_set_selected(providerRow.typed(AdwComboRow.self), UInt32(index))
        }
        gtk_menu_button_set_label(kindButton.opaque, next.kindLabel)
        Accessible.setLabel(kindButton, AiStudioModel.kindAccessibleLabel(next.kindLabel))
        adw_preferences_row_set_title(modelRow.typed(AdwPreferencesRow.self), Ui.escaped("Model (default \(next.defaultModel))"))
        Ui.setText(ofEditable: modelRow, next.model)
        Ui.setText(ofEditable: headphoneRow, next.headphone)
        Ui.setText(ofEditable: noteRow, next.note)
        let researchText: String
        if next.researchFallback {
            researchText = AiStudioModel.researchFallbackNote
        } else if next.refreshResearch {
            researchText = AiStudioModel.researchPending
        } else {
            researchText = next.researchInfo ?? AiStudioModel.researchFirst
        }
        Ui.setText(researchLine, researchText)
        Ui.show(researchAgainButton, !next.researchFallback && !next.refreshResearch && next.researchInfo != nil)

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
        Ui.show(unsaved, next.draft != nil && next.unsavedCurve)
        Ui.enable(slotButton, next.canWriteSlot)
        Ui.show(overwriteBox, next.slotChoice != nil)
        if previous.slotChoice == nil, next.slotChoice != nil { Ui.focusSoon(overwriteCancel) }
        if let choice = next.slotChoice {
            Ui.setText(overwriteText, choice.message)
            gtk_button_set_label(overwriteConfirm.typed(GtkButton.self), choice.confirmLabel)
        }

        Ui.show(dossierGroup, !next.dossier.isEmpty)
        Ui.setText(researchInfo, next.researchInfo)
        Ui.setText(dossier, next.dossier.isEmpty ? nil : next.dossier.map { "\($0.label): \($0.text)" }.joined(separator: "\n"))
    }

    private static func listPopover(_ list: Widget, height: Int32 = 320) -> Widget {
        let popover = gtk_popover_new()!
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(scroller.opaque, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(scroller.opaque, 1)
        gtk_scrolled_window_set_max_content_height(scroller.opaque, height)
        gtk_scrolled_window_set_child(scroller.opaque, list)
        gtk_popover_set_child(popover.typed(GtkPopover.self), scroller)
        return popover
    }

    private func clear(_ list: Widget) {
        while let child = gtk_widget_get_first_child(list) { gtk_box_remove(list.typed(GtkBox.self), child) }
    }

    private func rebuildKinds(_ groups: [AiKindGroup]) {
        clear(kindList)
        for group in groups {
            let title = Ui.label(group.title, classes: ["heading", "dim-label"])
            gtk_widget_set_margin_start(title, 12)
            gtk_widget_set_margin_top(title, 6)
            Accessible.setLabel(title, group.title)
            Ui.append(kindList, title)
            for choice in group.kinds {
                let item = Ui.menuItem(choice.label)
                Ui.append(kindList, item)
                let id = choice.id
                Signals.connect(item, signal: "clicked") { [weak self] in
                    onMain {
                        guard let self else { return }
                        gtk_popover_popdown(self.kindPopover.typed(GtkPopover.self))
                        self.model.setKind(id)
                    }
                }
            }
        }
    }

    private func rebuildSlots(_ slots: [PresetSlot]) {
        clear(slotList)
        for slot in slots {
            let item = Ui.menuItem("\(slot.number) \u{00B7} \(slot.label)")
            Accessible.setLabel(item, "Write to slot \(slot.number), \(slot.label)")
            Ui.append(slotList, item)
            let index = slot.index
            Signals.connect(item, signal: "clicked") { [weak self] in
                onMain {
                    guard let self else { return }
                    gtk_popover_popdown(self.slotPopover.typed(GtkPopover.self))
                    self.model.chooseSlot(index)
                }
            }
        }
    }

    func openMenu(_ name: String) {
        let button = name == "kind" ? kindButton : slotButton
        gtk_menu_button_popup(button.opaque)
    }

    var openPopover: UnsafeMutableRawPointer? {
        for popover in [kindPopover, slotPopover] where gtk_widget_get_visible(popover) != 0 {
            return UnsafeMutableRawPointer(popover)
        }
        return nil
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
