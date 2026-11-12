import CGtk
import Foundation
import QudelixBar
import QudelixGtk

typealias Widget = UnsafeMutablePointer<GtkWidget>

enum Ui {
    static func escaped(_ text: String) -> String {
        guard let raw = g_markup_escape_text(text, -1) else { return text }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    static func label(_ text: String = "", classes: [String] = ["dim-label", "caption"]) -> Widget {
        let label = gtk_label_new(text)!
        gtk_label_set_xalign(label.opaque, 0)
        gtk_label_set_wrap(label.opaque, 1)
        gtk_widget_set_hexpand(label, 1)
        for name in classes { gtk_widget_add_css_class(label, name) }
        return label
    }

    static func setText(_ label: Widget, _ text: String?) {
        gtk_label_set_text(label.opaque, text ?? "")
        gtk_widget_set_visible(label, (text ?? "").isEmpty ? 0 : 1)
    }

    static func show(_ widget: Widget, _ visible: Bool) {
        gtk_widget_set_visible(widget, visible ? 1 : 0)
    }

    static func enable(_ widget: Widget, _ enabled: Bool, reason: String? = nil) {
        gtk_widget_set_sensitive(widget, enabled ? 1 : 0)
        if let reason, !enabled {
            gtk_widget_set_tooltip_text(widget, reason)
        } else {
            gtk_widget_set_tooltip_text(widget, nil)
        }
    }

    static func button(_ title: String, classes: [String] = []) -> Widget {
        let button = gtk_button_new_with_label(title)!
        for name in classes { gtk_widget_add_css_class(button, name) }
        return button
    }

    static func box(_ orientation: GtkOrientation, spacing: Int32 = 6) -> Widget {
        gtk_box_new(orientation, spacing)!
    }

    static func append(_ box: Widget, _ child: Widget) {
        gtk_box_append(box.typed(GtkBox.self), child)
    }

    static func buttonRow(_ buttons: [Widget]) -> Widget {
        let row = box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        for button in buttons {
            gtk_widget_set_hexpand(button, 0)
            append(row, button)
        }
        return row
    }

    static func extras(_ children: [Widget]) -> Widget {
        let column = box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        gtk_widget_set_margin_top(column, 8)
        for child in children { append(column, child) }
        return column
    }

    static func wrapHeader(of group: Widget) {
        guard let first = gtk_widget_get_first_child(group) else { return }
        wrapLabels(from: first)
    }

    private static func wrapLabels(from start: Widget) {
        var node: Widget? = start
        while let current = node {
            if g_type_check_instance_is_a(UnsafeMutableRawPointer(current).assumingMemoryBound(to: GTypeInstance.self),
                                          gtk_label_get_type()) != 0 {
                let label = OpaquePointer(current)
                gtk_label_set_ellipsize(label, PANGO_ELLIPSIZE_NONE)
                gtk_label_set_wrap(label, 1)
                gtk_label_set_wrap_mode(label, PANGO_WRAP_WORD_CHAR)
            } else if g_type_check_instance_is_a(UnsafeMutableRawPointer(current).assumingMemoryBound(to: GTypeInstance.self),
                                                 gtk_list_box_get_type()) == 0,
                      let child = gtk_widget_get_first_child(current) {
                wrapLabels(from: child)
            }
            node = gtk_widget_get_next_sibling(current)
        }
    }

    static func keepWholeLabels(in row: Widget) {
        var pending: [Widget] = [row]
        while let current = pending.popLast() {
            if g_type_check_instance_is_a(UnsafeMutableRawPointer(current).assumingMemoryBound(to: GTypeInstance.self),
                                          gtk_label_get_type()) != 0 {
                gtk_label_set_ellipsize(OpaquePointer(current), PANGO_ELLIPSIZE_NONE)
            }
            var child = gtk_widget_get_first_child(current)
            while let next = child {
                pending.append(next)
                child = gtk_widget_get_next_sibling(next)
            }
        }
    }

    static func group(_ title: String?, _ description: String? = nil) -> Widget {
        let group = adw_preferences_group_new()!
        wrapHeader(of: group)
        if let title { adw_preferences_group_set_title(group.typed(AdwPreferencesGroup.self), title) }
        if let description {
            adw_preferences_group_set_description(group.typed(AdwPreferencesGroup.self), description)
        }
        return group
    }

    static func add(_ group: Widget, _ child: Widget) {
        adw_preferences_group_add(group.typed(AdwPreferencesGroup.self), child)
    }

    static func remove(_ group: Widget, _ child: Widget) {
        adw_preferences_group_remove(group.typed(AdwPreferencesGroup.self), child)
    }

    static func page(_ groups: [Widget]) -> Widget {
        let page = adw_preferences_page_new()!
        for group in groups {
            adw_preferences_page_add(page.typed(AdwPreferencesPage.self), group.typed(AdwPreferencesGroup.self))
        }
        return page
    }

    static func actionRow(title: String, subtitle: String = "") -> Widget {
        let row = adw_action_row_new()!
        setRow(row, title: title, subtitle: subtitle)
        return row
    }

    static func setRow(_ row: Widget, title: String, subtitle: String) {
        adw_preferences_row_set_title(row.typed(AdwPreferencesRow.self), escaped(title))
        adw_action_row_set_subtitle(row.typed(AdwActionRow.self), escaped(subtitle))
    }

    static func suffix(_ row: Widget, _ child: Widget) {
        adw_action_row_add_suffix(row.typed(AdwActionRow.self), child)
    }

    static func prefix(_ row: Widget, _ child: Widget) {
        adw_action_row_add_prefix(row.typed(AdwActionRow.self), child)
    }

    static func text(of editable: Widget) -> String {
        String(cString: gtk_editable_get_text(editable.opaque))
    }

    static func setText(ofEditable editable: Widget, _ text: String) {
        guard Self.text(of: editable) != text else { return }
        gtk_editable_set_text(editable.opaque, text)
    }

    static func spinner() -> Widget {
        let spinner = gtk_spinner_new()!
        gtk_widget_set_valign(spinner, GTK_ALIGN_CENTER)
        Accessible.setLabel(spinner, "Working")
        return spinner
    }

    static func setSpinning(_ spinner: Widget, _ on: Bool) {
        gtk_spinner_set_spinning(spinner.opaque, on ? 1 : 0)
        gtk_widget_set_visible(spinner, on ? 1 : 0)
    }

    static func menuItem(_ title: String, destructive: Bool = false) -> Widget {
        let button = gtk_button_new_with_label(title)!
        gtk_widget_add_css_class(button, "flat")
        if destructive { gtk_widget_add_css_class(button, "destructive-action") }
        if let child = gtk_button_get_child(button.typed(GtkButton.self)) {
            gtk_label_set_xalign(child.opaque, 0)
        }
        return button
    }

    static func moreMenu(_ tooltip: String, _ items: [Widget]) -> (button: Widget, popover: Widget) {
        let more = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(more.opaque, "view-more-symbolic")
        gtk_widget_add_css_class(more, "flat")
        gtk_widget_set_valign(more, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(more, tooltip)
        Accessible.setLabel(more, tooltip)
        let popover = gtk_popover_new()!
        let menu = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        for item in items { gtk_box_append(menu.typed(GtkBox.self), item) }
        gtk_popover_set_child(popover.typed(GtkPopover.self), menu)
        gtk_menu_button_set_popover(more.opaque, popover)
        return (more, popover)
    }

    static func parentWindow(of widget: Widget) -> UnsafeMutablePointer<GtkWindow>? {
        guard let root = gtk_widget_get_root(widget) else { return nil }
        return UnsafeMutableRawPointer(root).assumingMemoryBound(to: GtkWindow.self)
    }

    static func marker() -> Widget {
        let marker = gtk_image_new_from_icon_name("object-select-symbolic")!
        gtk_widget_add_css_class(marker, "accent")
        gtk_widget_set_opacity(marker, 0)
        return marker
    }

    static func confirm(parent: UnsafeMutablePointer<GtkWindow>?, title: String, message: String,
                        action: String, destructive: Bool,
                        done: @escaping (Bool) -> Void) -> UnsafeMutableRawPointer {
        let dialog = adw_message_dialog_new(parent, title, message)!
        let typed = dialog.typed(AdwMessageDialog.self)
        adw_message_dialog_add_response(typed, "cancel", "Cancel")
        adw_message_dialog_add_response(typed, "confirm", action)
        adw_message_dialog_set_response_appearance(typed, "confirm",
                                                   destructive ? ADW_RESPONSE_DESTRUCTIVE : ADW_RESPONSE_SUGGESTED)
        adw_message_dialog_set_default_response(typed, "cancel")
        adw_message_dialog_set_close_response(typed, "cancel")
        Signals.onResponse(dialog) { response in done(response == "confirm") }
        gtk_window_present(dialog.typed(GtkWindow.self))
        return dialog.raw
    }

    static func ask(parent: UnsafeMutablePointer<GtkWindow>?, title: String, message: String,
                    text: String, placeholder: String, action: String, maxLength: Int32,
                    done: @escaping (String?) -> Void) -> UnsafeMutableRawPointer {
        let dialog = NameDialog.make(parent: parent, title: title, message: message, text: text,
                                     placeholder: placeholder, action: action, maxLength: maxLength,
                                     allowsBlank: false, done: done)
        gtk_window_present(dialog.typed(GtkWindow.self))
        NameDialog.focusEntry(of: dialog)
        return dialog
    }
}

@MainActor
final class CurvePreviewView {
    let area: Widget
    private var preview: CurvePreview?

    init() {
        area = Accessible.drawingArea(role: GTK_ACCESSIBLE_ROLE_IMG)
        gtk_widget_set_hexpand(area, 1)
        gtk_widget_set_size_request(area, 200, 160)
        gtk_widget_set_visible(area, 0)
        Accessible.setLabel(area, "Equalizer curve preview")
        Signals.setDrawFunc(area) { [weak self] cr, width, height in
            onMain { self?.draw(cr, Double(width), Double(height)) }
        }
    }

    func update(_ next: CurvePreview?) {
        preview = next
        if let next { Accessible.setDescription(area, "\(next.title). \(next.subtitle)") }
        gtk_widget_set_visible(area, next == nil ? 0 : 1)
        gtk_widget_queue_draw(area)
    }

    private func draw(_ cr: OpaquePointer, _ w: Double, _ h: Double) {
        guard let preview else { return }
        var drawing = CurveDrawing(area: area, bands: preview.bands, requested: preview.requested)
        drawing.draw(cr, w, h)
    }
}
