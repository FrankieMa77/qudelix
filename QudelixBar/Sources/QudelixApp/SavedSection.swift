import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@MainActor
final class SavedSection {
    let widget: Widget
    let layout: SplitLayout

    private struct Entry {
        let row: Widget
        let marker: Widget
        let dimmed: Bool
    }

    private let model: SavedPresetsModel
    private let parent: () -> UnsafeMutablePointer<GtkWindow>?
    private let search: Widget
    private let notice: Widget
    private let listGroup: Widget
    private let othersGroup: Widget
    private let othersRow: Widget
    private let headphones: Widget
    private let addButton: Widget
    private let pasteButton: Widget
    private let empty: Widget
    private let saveButton: Widget
    private let previewGroup: Widget
    private let curve = CurvePreviewView()
    private let previewTitle: Widget
    private let previewSubtitle: Widget
    private let applyButton: Widget
    private let reason: Widget
    private var entries: [UUID: Entry] = [:]
    private var shown: [SavedPreset] = []
    private var shownOthers: [SavedPreset] = []
    private var state = SavedPresetsState()
    private var updating = false
    private(set) var dialog: UnsafeMutableRawPointer?

    init(model: SavedPresetsModel, parent: @escaping () -> UnsafeMutablePointer<GtkWindow>?) {
        self.model = model
        self.parent = parent

        saveButton = Ui.button(SavedPresetsModel.saveButtonLabel)
        gtk_widget_set_valign(saveButton, GTK_ALIGN_CENTER)
        search = gtk_search_entry_new()!
        gtk_widget_set_hexpand(search, 1)
        gtk_search_entry_set_placeholder_text(search.opaque, "Filter saved presets")
        notice = Ui.label("", classes: ["caption", "dim-label"])
        empty = Ui.actionRow(title: "Nothing saved yet",
                             subtitle: "Save the current EQ, or keep an AutoEq or AI result.")
        let top = Ui.group("Library",
                           "Presets kept on this computer. Applying one writes it to the device as a single undo step.")
        adw_preferences_group_set_header_suffix(top.typed(AdwPreferencesGroup.self), saveButton)
        headphones = gtk_entry_new()!
        gtk_entry_set_placeholder_text(headphones.typed(GtkEntry.self), "Headphones")
        gtk_entry_set_max_length(headphones.typed(GtkEntry.self), SavedPresetsModel.maxNameLength)
        gtk_entry_set_icon_from_icon_name(headphones.typed(GtkEntry.self), GTK_ENTRY_ICON_PRIMARY,
                                          "audio-headphones-symbolic")
        gtk_widget_set_tooltip_text(headphones, "The headphones plugged into the 5K \u{2014} the output device "
            + "can\u{2019}t say what is on the end of it.")
        Accessible.setLabel(headphones, "Headphones")
        addButton = Ui.button(SavedPresetsModel.addFromFileLabel)
        pasteButton = Ui.button(SavedPresetsModel.pasteLabel)
        Ui.add(top, headphones)
        Ui.add(top, Ui.label(SavedPresetsModel.headphonesHint))
        Ui.add(top, search)
        Ui.add(top, Ui.buttonRow([addButton, pasteButton]))
        Ui.add(top, notice)

        listGroup = Ui.group(nil)
        Ui.add(listGroup, empty)
        othersGroup = Ui.group(nil)
        othersRow = adw_expander_row_new()!
        Ui.add(othersGroup, othersRow)
        Ui.show(othersGroup, false)

        previewGroup = Ui.group("Preview")
        previewTitle = Ui.label("", classes: ["heading"])
        previewSubtitle = Ui.label("")
        applyButton = Ui.button(SavedPresetsModel.applyLabel, classes: ["suggested-action"])
        gtk_widget_set_halign(applyButton, GTK_ALIGN_START)
        reason = Ui.label("", classes: ["caption", "warning"])
        let card = Ui.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Ui.append(card, previewTitle)
        Ui.append(card, previewSubtitle)
        Ui.append(card, curve.area)
        Ui.append(card, applyButton)
        Ui.append(card, reason)
        Ui.add(previewGroup, card)
        Ui.show(previewGroup, false)

        layout = SplitLayout(top: [top], left: [listGroup, othersGroup], right: [previewGroup])
        widget = layout.widget

        Signals.connect(search, signal: "search-changed") { [weak self] in
            onMain {
                guard let self, !self.updating else { return }
                self.model.setFilter(Ui.text(of: self.search))
            }
        }
        Signals.connect(saveButton, signal: "clicked") { [weak self] in onMain { self?.presentSave() } }
        Signals.connect(headphones, signal: "changed") { [weak self] in
            onMain {
                guard let self, !self.updating else { return }
                self.model.setHeadphoneName(Ui.text(of: self.headphones))
            }
        }
        Signals.connect(addButton, signal: "clicked") { [weak self] in onMain { self?.presentAdd() } }
        Signals.connect(pasteButton, signal: "clicked") { [weak self] in onMain { self?.paste() } }
        Signals.connect(applyButton, signal: "clicked") { [weak self] in
            onMain {
                guard let self, let id = self.state.selected else { return }
                self.model.apply(id)
            }
        }
        model.addObserver { [weak self] state in onLive { self?.update(state) } }
    }

    private func update(_ next: SavedPresetsState) {
        let previous = state
        state = next
        updating = true
        defer { updating = false }
        Ui.setText(ofEditable: search, next.filter)
        if shown != next.presets || shownOthers != next.others { rebuild(next.presets, next.others) }
        Ui.show(empty, next.presets.isEmpty)
        if next.presets.isEmpty {
            let filtering = !next.filter.trimmingCharacters(in: .whitespaces).isEmpty
            let elsewhere = !next.others.isEmpty
            Ui.setRow(empty, title: filtering ? "No match"
                          : elsewhere ? "Nothing saved for this output yet" : "Nothing saved yet",
                      subtitle: filtering ? "Nothing in the library matches \u{201C}\(next.filter)\u{201D}."
                          : elsewhere ? "Presets made for other outputs are listed under Other outputs."
                          : "Save the current EQ, or keep an AutoEq or AI result.")
        }
        Ui.show(othersGroup, !next.others.isEmpty)
        adw_preferences_row_set_title(othersRow.typed(AdwPreferencesRow.self),
                                      Ui.escaped(SavedPresetsModel.othersTitle(next.others.count)))
        let typedName = Ui.text(of: headphones).trimmingCharacters(in: .whitespaces)
        if typedName != next.headphoneName { Ui.setText(ofEditable: headphones, next.headphoneName) }
        Ui.enable(addButton, next.importRefusal == nil,
                  reason: next.importRefusal)
        Ui.enable(pasteButton, next.importRefusal == nil, reason: next.importRefusal)
        if next.importRefusal == nil {
            gtk_widget_set_tooltip_text(addButton, SavedPresetsModel.addFromFileHelp)
            gtk_widget_set_tooltip_text(pasteButton, SavedPresetsModel.pasteHelp)
        }
        for (id, entry) in entries {
            gtk_widget_set_opacity(entry.marker, id == next.selected ? 1 : 0)
            Accessible.setSelected(entry.row, id == next.selected)
        }
        Ui.setText(notice, next.notice ?? next.saveRefusal)
        if next.notice == nil, next.saveRefusal != nil {
            gtk_widget_remove_css_class(notice, "dim-label")
            gtk_widget_add_css_class(notice, "warning")
        } else {
            gtk_widget_remove_css_class(notice, "warning")
            gtk_widget_add_css_class(notice, "dim-label")
        }
        Ui.enable(saveButton, next.saveRefusal == nil, reason: next.saveRefusal)
        if previous.preview != next.preview { curve.update(next.preview) }
        Ui.show(previewGroup, next.preview != nil)
        if previous.selected != next.selected, next.selected != nil { layout.reveal(previewGroup) }
        Ui.setText(previewTitle, next.preview?.title)
        Ui.setText(previewSubtitle, next.preview?.subtitle)
        Ui.enable(applyButton, next.applyRefusal == nil)
        Ui.setText(reason, next.applyRefusal)
    }

    private func rebuild(_ presets: [SavedPreset], _ others: [SavedPreset]) {
        for entry in entries.values {
            if entry.dimmed {
                adw_expander_row_remove(othersRow.typed(AdwExpanderRow.self), entry.row)
            } else {
                Ui.remove(listGroup, entry.row)
            }
        }
        entries = [:]
        shown = presets
        shownOthers = others
        for preset in presets { add(preset, dimmed: false) }
        for preset in others { add(preset, dimmed: true) }
    }

    private func add(_ preset: SavedPreset, dimmed: Bool) {
        let row = Ui.actionRow(title: preset.name, subtitle: preset.detail)
        gtk_list_box_row_set_activatable(row.typed(GtkListBoxRow.self), 1)
        if dimmed { gtk_widget_set_opacity(row, 0.55) }
        let marker = Ui.marker()
        Ui.prefix(row, marker)
        let rename = Ui.menuItem("Rename\u{2026}")
        let export = Ui.menuItem("Export\u{2026}")
        let delete = Ui.menuItem("Delete\u{2026}")
        var items = [rename, export]
        let everywhere = preset.canUseEverywhere ? Ui.menuItem(SavedPresetsModel.useEverywhereLabel) : nil
        let onlyHere = preset.canUseOnlyHere
            ? Ui.menuItem(SavedPresetsModel.useOnlyHereLabel(state.outputName)) : nil
        if let everywhere { items.append(everywhere) }
        if let onlyHere { items.append(onlyHere) }
        items.append(delete)
        let menu = Ui.moreMenu("More actions for \(preset.name)", items)
        Ui.suffix(row, menu.button)
        if dimmed {
            adw_expander_row_add_row(othersRow.typed(AdwExpanderRow.self), row)
        } else {
            Ui.add(listGroup, row)
        }
        entries[preset.id] = Entry(row: row, marker: marker, dimmed: dimmed)
        let id = preset.id
        let popover = menu.popover
        Signals.connect(row, signal: "activated") { [weak self] in onMain { self?.model.select(id) } }
        Signals.connect(rename, signal: "clicked") { [weak self] in
            onMain {
                gtk_popover_popdown(popover.typed(GtkPopover.self))
                self?.presentRename(id)
            }
        }
        Signals.connect(export, signal: "clicked") { [weak self] in
            onMain {
                gtk_popover_popdown(popover.typed(GtkPopover.self))
                self?.presentExport(id)
            }
        }
        if let everywhere {
            Signals.connect(everywhere, signal: "clicked") { [weak self] in
                onMain {
                    gtk_popover_popdown(popover.typed(GtkPopover.self))
                    self?.model.useEverywhere(id)
                }
            }
        }
        if let onlyHere {
            Signals.connect(onlyHere, signal: "clicked") { [weak self] in
                onMain {
                    gtk_popover_popdown(popover.typed(GtkPopover.self))
                    self?.model.useOnlyHere(id)
                }
            }
        }
        Signals.connect(delete, signal: "clicked") { [weak self] in
            onMain {
                gtk_popover_popdown(popover.typed(GtkPopover.self))
                self?.presentDelete(id)
            }
        }
    }

    func expandOthers() {
        guard !state.others.isEmpty else { return }
        adw_expander_row_set_expanded(othersRow.typed(AdwExpanderRow.self), 1)
    }

    private func presentAdd() {
        guard state.importRefusal == nil else { return }
        let parent = self.parent().map { UnsafeMutableRawPointer($0) }
        FileDialog.openText(parent: parent, title: SavedPresetsModel.addFromFileTitle,
                            specs: EqTextFileFilters.specs) { [weak self] path in
            onMain {
                guard let path else { return }
                self?.model.importFile(at: URL(fileURLWithPath: path))
            }
        }
    }

    private func paste() {
        guard state.importRefusal == nil else { return }
        Clipboard.readText(from: pasteButton) { [weak self] text in
            onMain { self?.model.importText(text ?? "") }
        }
    }

    private func presentExport(_ id: UUID) {
        guard let name = model.name(of: id) else { return }
        let parent = self.parent().map { UnsafeMutableRawPointer($0) }
        FileDialog.saveText(parent: parent, title: SavedPresetsModel.exportTitle,
                            initialName: SavedPresetsModel.exportFileName(name)) { [weak self] path in
            onMain {
                guard let path else { return }
                self?.model.exportFile(id, to: URL(fileURLWithPath: path))
            }
        }
    }

    @discardableResult
    func presentSave() -> UnsafeMutableRawPointer? {
        guard state.saveRefusal == nil else { return nil }
        let scoped = state.scopeShown
        let noOutput = scoped && !state.outputAvailable
        let message = "Keeps the curve the 5K is running now as a preset on this computer."
            + (noOutput ? " " + SavedPresetsModel.noOutputNotice : "")
        let dialog = NameDialog.make(
            parent: parent(), title: "Save the current EQ", message: message,
            text: state.suggestedName, placeholder: "Preset name", action: "Save",
            maxLength: SavedPresetsModel.maxNameLength, allowsBlank: false,
            choices: scoped ? [SavedPresetsModel.everyOutputLabel,
                               SavedPresetsModel.thisOutputLabel(state.outputName)] : [],
            selectedChoice: state.outputAvailable ? 1 : 0, choicesEnabled: state.outputAvailable,
            choiceLabel: "Applies to") { [weak self] name, choice in
            onMain {
                if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    self?.model.saveCurrent(name: name, onlyHere: scoped && choice == 1)
                }
                self?.dialog = nil
            }
        }
        gtk_window_present(dialog.typed(GtkWindow.self))
        NameDialog.focusEntry(of: dialog)
        self.dialog = dialog
        return dialog
    }

    @discardableResult
    func presentRename(_ id: UUID) -> UnsafeMutableRawPointer? {
        guard let name = model.name(of: id) else { return nil }
        let dialog = Ui.ask(parent: parent(), title: "Rename preset", message: "Give \u{201C}\(name)\u{201D} a new name.",
                            text: name, placeholder: "Preset name", action: "Rename",
                            maxLength: SavedPresetsModel.maxNameLength) { [weak self] text in
            onMain {
                if let text { self?.model.rename(id, to: text) }
                self?.dialog = nil
            }
        }
        self.dialog = dialog
        return dialog
    }

    @discardableResult
    func presentDelete(_ id: UUID) -> UnsafeMutableRawPointer? {
        guard let name = model.name(of: id) else { return nil }
        let dialog = Ui.confirm(parent: parent(), title: SavedPresetsModel.deleteTitle(name),
                                message: SavedPresetsModel.deleteMessage, action: "Delete",
                                destructive: true) { [weak self] confirmed in
            onMain {
                if confirmed { self?.model.delete(id) }
                self?.dialog = nil
            }
        }
        self.dialog = dialog
        return dialog
    }
}
