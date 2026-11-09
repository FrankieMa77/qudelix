import CGtk

package enum NameDialog {
    package static let cancelResponse = "cancel"
    package static let confirmResponse = "confirm"

    package static func make(parent: UnsafeMutablePointer<GtkWindow>?, title: String, message: String,
                             text: String, placeholder: String, action: String, maxLength: Int32,
                             allowsBlank: Bool,
                             done: @escaping (String?) -> Void) -> UnsafeMutableRawPointer {
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
        adw_message_dialog_set_extra_child(typed, entry)
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
            done(response == confirmResponse ? current(entry) : nil)
        }
        return dialog.raw
    }

    package static func entry(of dialog: UnsafeMutableRawPointer) -> UnsafeMutablePointer<GtkWidget>? {
        adw_message_dialog_get_extra_child(dialog.typed(AdwMessageDialog.self))
    }

    package static func focusEntry(of dialog: UnsafeMutableRawPointer) {
        if let entry = entry(of: dialog) { gtk_widget_grab_focus(entry) }
    }
}
