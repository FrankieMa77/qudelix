import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@MainActor
final class PresetsPage {
    let widget: UnsafeMutablePointer<GtkWidget>

    private struct SlotRow {
        let row: UnsafeMutablePointer<GtkWidget>
        let marker: UnsafeMutablePointer<GtkWidget>
        let load: UnsafeMutablePointer<GtkWidget>
        let more: UnsafeMutablePointer<GtkWidget>
    }

    private let model: AppModel
    private let presets: PresetSlotsModel
    private let stack: OpaquePointer
    private let placeholder = ConnectionStatusPage()
    private let group: UnsafeMutablePointer<GtkWidget>
    private var rows: [SlotRow] = []
    private var state = PresetSlotsState()
    private(set) var dialog: UnsafeMutableRawPointer?

    init(model: AppModel) {
        self.model = model
        presets = model.presets
        stack = gtk_stack_new()!.opaque
        group = adw_preferences_group_new()!
        adw_preferences_group_set_title(group.typed(AdwPreferencesGroup.self), "Presets on the device")
        adw_preferences_group_set_description(group.typed(AdwPreferencesGroup.self),
                                              "Loading a preset replaces the live EQ. Save writes the live EQ into a slot.")
        let page = adw_preferences_page_new()!
        adw_preferences_page_add(page.typed(AdwPreferencesPage.self), group.typed(AdwPreferencesGroup.self))

        gtk_stack_add_named(stack, placeholder.widget, "status")
        gtk_stack_add_named(stack, page, "content")
        widget = UnsafeMutableRawPointer(stack).assumingMemoryBound(to: GtkWidget.self)

        presets.addObserver { [weak self] state in onLive { self?.update(state) } }
        model.addObserver { [weak self] state in onLive { self?.connectionChanged(state) } }
    }

    private func connectionChanged(_ app: AppModelState) {
        if case .connected = app.connection {
            if state.ready { gtk_stack_set_visible_child_name(stack, "content") }
        } else {
            placeholder.show(for: app.connection)
            gtk_stack_set_visible_child_name(stack, "status")
            dismissDialog()
        }
    }

    private func dismissDialog() {
        let open = dialog
        dialog = nil
        DialogDismissal.dismiss(open)
    }

    private func buildRows() {
        for existing in rows {
            adw_preferences_group_remove(group.typed(AdwPreferencesGroup.self), existing.row)
        }
        rows = []
        for index in 0..<PresetSlotsModel.slotCount {
            let row = adw_action_row_new()!

            let marker = gtk_image_new_from_icon_name("object-select-symbolic")!
            gtk_widget_add_css_class(marker, "accent")
            gtk_widget_set_tooltip_text(marker, "Active on the device")
            adw_action_row_add_prefix(row.typed(AdwActionRow.self), marker)

            let load = gtk_button_new_with_label("Load")!
            gtk_widget_set_valign(load, GTK_ALIGN_CENTER)
            adw_action_row_add_suffix(row.typed(AdwActionRow.self), load)

            let more = gtk_menu_button_new()!
            gtk_menu_button_set_icon_name(more.opaque, "view-more-symbolic")
            gtk_widget_add_css_class(more, "flat")
            gtk_widget_set_valign(more, GTK_ALIGN_CENTER)
            gtk_widget_set_tooltip_text(more, "More actions for this slot")
            Accessible.setLabel(more, "More actions for slot \(index + 1)")
            let popover = gtk_popover_new()!
            let menu = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
            let save = Self.menuItem("Save current EQ here\u{2026}")
            let rename = Self.menuItem("Rename\u{2026}")
            gtk_box_append(menu.typed(GtkBox.self), save)
            gtk_box_append(menu.typed(GtkBox.self), rename)
            gtk_popover_set_child(popover.typed(GtkPopover.self), menu)
            gtk_menu_button_set_popover(more.opaque, popover)
            adw_action_row_add_suffix(row.typed(AdwActionRow.self), more)

            adw_preferences_group_add(group.typed(AdwPreferencesGroup.self), row)
            rows.append(SlotRow(row: row, marker: marker, load: load, more: more))

            Signals.connect(load, signal: "clicked") { [weak self] in
                onMain { self?.presets.load(slot: index) }
            }
            Signals.connect(save, signal: "clicked") { [weak self] in
                onMain {
                    gtk_popover_popdown(popover.typed(GtkPopover.self))
                    self?.requestSave(slot: index)
                }
            }
            Signals.connect(rename, signal: "clicked") { [weak self] in
                onMain {
                    gtk_popover_popdown(popover.typed(GtkPopover.self))
                    _ = self?.presentRename(slot: index)
                }
            }
        }
    }

    private static func menuItem(_ title: String) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new_with_label(title)!
        gtk_widget_add_css_class(button, "flat")
        if let child = gtk_button_get_child(button.typed(GtkButton.self)) {
            gtk_label_set_xalign(child.opaque, 0)
        }
        return button
    }

    private func update(_ next: PresetSlotsState) {
        state = next
        if rows.isEmpty { buildRows() }
        if next.ready, model.state.connection.isConnected {
            gtk_stack_set_visible_child_name(stack, "content")
        }
        for slot in next.slots where rows.indices.contains(slot.index) {
            let row = rows[slot.index]
            adw_preferences_row_set_title(row.row.typed(AdwPreferencesRow.self), Self.escaped(slot.label))
            adw_action_row_set_subtitle(row.row.typed(AdwActionRow.self),
                                        "Slot \(slot.number)" + (slot.isActive ? " \u{00B7} Active" : ""))
            gtk_widget_set_opacity(row.marker, slot.isActive ? 1 : 0)
            gtk_widget_set_sensitive(row.load, next.busy ? 0 : 1)
            gtk_widget_set_sensitive(row.more, next.busy ? 0 : 1)
            gtk_widget_set_tooltip_text(row.load, "Load \(slot.label)")
            Accessible.setLabel(row.load, "Load slot \(slot.number), \(slot.label)")
            Accessible.setLabel(row.more, "More actions for slot \(slot.number), \(slot.label)")
        }
    }

    private static func escaped(_ text: String) -> String { Ui.escaped(text) }

    private var parentWindow: UnsafeMutablePointer<GtkWindow>? {
        guard let root = gtk_widget_get_root(widget) else { return nil }
        return UnsafeMutableRawPointer(root).assumingMemoryBound(to: GtkWindow.self)
    }

    func requestSave(slot index: Int) {
        guard presets.needsOverwriteConfirmation(slot: index) else {
            presets.save(slot: index)
            return
        }
        presentSaveConfirmation(slot: index)
    }

    @discardableResult
    func presentSaveConfirmation(slot index: Int) -> UnsafeMutableRawPointer? {
        let name = presets.label(forSlot: index)
        let dialog = adw_message_dialog_new(parentWindow, PresetSlotsModel.overwriteTitle,
                                            PresetSlotsModel.overwriteMessage(slot: index, name: name))!
        let dialogPointer = dialog.raw
        let typed = dialog.typed(AdwMessageDialog.self)
        adw_message_dialog_add_response(typed, "cancel", "Cancel")
        adw_message_dialog_add_response(typed, "save", PresetSlotsModel.saveHereLabel)
        adw_message_dialog_set_response_appearance(typed, "save", ADW_RESPONSE_DESTRUCTIVE)
        adw_message_dialog_set_default_response(typed, "cancel")
        adw_message_dialog_set_close_response(typed, "cancel")
        Signals.onResponse(dialog) { [weak self] response in
            onMain {
                if response == "save" { self?.presets.save(slot: index) }
                if self?.dialog == dialogPointer { self?.dialog = nil }
            }
        }
        self.dialog = dialog.raw
        gtk_window_present(dialog.typed(GtkWindow.self))
        return dialog.raw
    }

    @discardableResult
    func presentRename(slot index: Int) -> UnsafeMutableRawPointer? {
        let current = state.slots.indices.contains(index) ? (state.slots[index].name ?? "") : ""
        var opened: UnsafeMutableRawPointer?
        let dialog = NameDialog.make(parent: parentWindow, title: "Rename preset \(index + 1)",
                                     message: "Leave the name empty to clear it.", text: current,
                                     placeholder: "Preset \(index + 1)", action: "Rename",
                                     maxLength: 29, allowsBlank: true) { [weak self] text in
            onMain {
                if let text { self?.presets.rename(slot: index, to: text) }
                if self?.dialog == opened { self?.dialog = nil }
            }
        }
        opened = dialog
        self.dialog = dialog
        gtk_window_present(dialog.typed(GtkWindow.self))
        NameDialog.focusEntry(of: dialog)
        return dialog
    }
}
