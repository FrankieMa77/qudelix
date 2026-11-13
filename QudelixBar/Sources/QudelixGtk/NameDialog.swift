import CGtk

package enum NameDialog {
    package static let cancelResponse = "cancel"
    package static let confirmResponse = "confirm"

    package static func make(parent: UnsafeMutablePointer<GtkWindow>?, title: String, message: String,
                             text: String, placeholder: String, action: String, maxLength: Int32,
                             allowsBlank: Bool,
                             done: @escaping (String?) -> Void) -> UnsafeMutableRawPointer {
        make(parent: parent, title: title, message: message, text: text, placeholder: placeholder,
             action: action, maxLength: maxLength, allowsBlank: allowsBlank, choices: [], selectedChoice: 0,
             choicesEnabled: true, choiceLabel: "") { name, _ in done(name) }
    }

    package static func make(parent: UnsafeMutablePointer<GtkWindow>?, title: String, message: String,
                             text: String, placeholder: String, action: String, maxLength: Int32,
                             allowsBlank: Bool, choices: [String], selectedChoice: Int,
                             choicesEnabled: Bool, choiceLabel: String,
                             done: @escaping (String?, Int) -> Void) -> UnsafeMutableRawPointer {
        func current(_ entry: UnsafeMutablePointer<GtkWidget>) -> String {
            String(cString: gtk_editable_get_text(entry.opaque))
        }
        func accepts(_ entry: UnsafeMutablePointer<GtkWidget>) -> Bool {
            allowsBlank || !DeviceText.isBlank(current(entry))
        }
        let dialog = adw_message_dialog_new(parent, title, message)!
        let typed = dialog.typed(AdwMessageDialog.self)
        let entry = gtk_entry_new()!
        gtk_editable_set_text(entry.opaque, text)
        gtk_entry_set_max_length(entry.typed(GtkEntry.self), maxLength)
        gtk_entry_set_placeholder_text(entry.typed(GtkEntry.self), placeholder)
        gtk_entry_set_activates_default(entry.typed(GtkEntry.self), 1)
        var dropDown: UnsafeMutablePointer<GtkWidget>?
        if choices.isEmpty {
            adw_message_dialog_set_extra_child(typed, entry)
        } else {
            var pointers: [UnsafePointer<CChar>?] = choices.map { UnsafePointer(g_strdup($0)) } + [nil]
            defer { for pointer in pointers { g_free(UnsafeMutableRawPointer(mutating: pointer)) } }
            let list = gtk_drop_down_new_from_strings(&pointers)!
            gtk_drop_down_set_selected(list.opaque, UInt32(max(0, min(selectedChoice, choices.count - 1))))
            gtk_widget_set_sensitive(list, choicesEnabled ? 1 : 0)
            Accessible.setLabel(list, choiceLabel)
            if !choiceLabel.isEmpty { gtk_widget_set_tooltip_text(list, choiceLabel) }
            let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
            gtk_box_append(column.typed(GtkBox.self), entry)
            gtk_box_append(column.typed(GtkBox.self), list)
            adw_message_dialog_set_extra_child(typed, column)
            dropDown = list
        }
        adw_message_dialog_add_response(typed, cancelResponse, "Cancel")
        adw_message_dialog_add_response(typed, confirmResponse, action)
        adw_message_dialog_set_response_appearance(typed, confirmResponse, ADW_RESPONSE_SUGGESTED)
        adw_message_dialog_set_default_response(typed, confirmResponse)
        adw_message_dialog_set_close_response(typed, cancelResponse)
        adw_message_dialog_set_response_enabled(typed, confirmResponse, accepts(entry) ? 1 : 0)
        Signals.connect(entry, signal: "changed") {
            adw_message_dialog_set_response_enabled(typed, confirmResponse, accepts(entry) ? 1 : 0)
        }
        Signals.onResponse(dialog) { response in
            let chosen = dropDown.map { Int(gtk_drop_down_get_selected($0.opaque)) } ?? 0
            done(response == confirmResponse ? current(entry) : nil, chosen)
        }
        return dialog.raw
    }

    package static func entry(of dialog: UnsafeMutableRawPointer) -> UnsafeMutablePointer<GtkWidget>? {
        guard let extra = adw_message_dialog_get_extra_child(dialog.typed(AdwMessageDialog.self)) else { return nil }
        if g_type_check_instance_is_a(UnsafeMutableRawPointer(extra).assumingMemoryBound(to: GTypeInstance.self),
                                      gtk_box_get_type()) != 0 {
            return gtk_widget_get_first_child(extra)
        }
        return extra
    }

    package static func focusEntry(of dialog: UnsafeMutableRawPointer) {
        if let entry = entry(of: dialog) { gtk_widget_grab_focus(entry) }
    }
}
