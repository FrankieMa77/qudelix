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
    }

    private let model: SavedPresetsModel
    private let parent: () -> UnsafeMutablePointer<GtkWindow>?
    private let search: Widget
    private let notice: Widget
    private let listGroup: Widget
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
        Ui.add(top, search)
        Ui.add(top, notice)

        listGroup = Ui.group(nil)
        Ui.add(listGroup, empty)

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

        layout = SplitLayout(top: [top], left: [listGroup], right: [previewGroup])
        widget = layout.widget

        Signals.connect(search, signal: "search-changed") { [weak self] in
            onMain {
                guard let self, !self.updating else { return }
                self.model.setFilter(Ui.text(of: self.search))
            }
        }
        Signals.connect(saveButton, signal: "clicked") { [weak self] in onMain { self?.presentSave() } }
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
        if shown != next.presets { rebuild(next.presets) }
        Ui.show(empty, next.presets.isEmpty)
        if next.presets.isEmpty {
            let filtering = !next.filter.trimmingCharacters(in: .whitespaces).isEmpty
            Ui.setRow(empty, title: filtering ? "No match" : "Nothing saved yet",
                      subtitle: filtering ? "Nothing in the library matches \u{201C}\(next.filter)\u{201D}."
                          : "Save the current EQ, or keep an AutoEq or AI result.")
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

    private func rebuild(_ presets: [SavedPreset]) {
        for entry in entries.values { Ui.remove(listGroup, entry.row) }
        entries = [:]
        shown = presets
        for preset in presets {
            let row = Ui.actionRow(title: preset.name, subtitle: preset.detail)
            gtk_list_box_row_set_activatable(row.typed(GtkListBoxRow.self), 1)
            let marker = Ui.marker()
            Ui.prefix(row, marker)
            let rename = Ui.menuItem("Rename\u{2026}")
            let delete = Ui.menuItem("Delete\u{2026}")
            let menu = Ui.moreMenu("More actions for \(preset.name)", [rename, delete])
            Ui.suffix(row, menu.button)
            Ui.add(listGroup, row)
            entries[preset.id] = Entry(row: row, marker: marker)
            let id = preset.id
            let popover = menu.popover
            Signals.connect(row, signal: "activated") { [weak self] in onMain { self?.model.select(id) } }
            Signals.connect(rename, signal: "clicked") { [weak self] in
                onMain {
                    gtk_popover_popdown(popover.typed(GtkPopover.self))
                    self?.presentRename(id)
                }
            }
            Signals.connect(delete, signal: "clicked") { [weak self] in
                onMain {
                    gtk_popover_popdown(popover.typed(GtkPopover.self))
                    self?.presentDelete(id)
                }
            }
        }
    }

    @discardableResult
    func presentSave() -> UnsafeMutableRawPointer? {
        guard state.saveRefusal == nil else { return nil }
        let dialog = Ui.ask(parent: parent(), title: "Save the current EQ",
                            message: "Keeps the curve the 5K is running now as a preset on this computer.",
                            text: state.suggestedName, placeholder: "Preset name", action: "Save",
                            maxLength: SavedPresetsModel.maxNameLength) { [weak self] name in
            onMain {
                if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { self?.model.saveCurrent(name: name) }
                self?.dialog = nil
            }
        }
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
