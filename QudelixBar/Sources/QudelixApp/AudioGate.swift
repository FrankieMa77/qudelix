import CGtk
import QudelixBar
import QudelixGtk

@MainActor
enum AudioGate {
    static func wrap(_ content: UnsafeMutablePointer<GtkWidget>, page: AppPage,
                     audio: AudioStack?) -> UnsafeMutablePointer<GtkWidget> {
        guard let audio, audio.stage != nil else { return content }
        let stack = gtk_stack_new()!.opaque
        let status = adw_status_page_new()!
        adw_status_page_set_title(status.opaque, page.title)
        adw_status_page_set_icon_name(status.opaque, "dialog-warning-symbolic")
        gtk_stack_add_named(stack, status.widget, "status")
        gtk_stack_add_named(stack, content, "content")
        gtk_widget_set_hexpand(stack.widget, 1)
        gtk_widget_set_vexpand(stack.widget, 1)
        audio.addStatusObserver { next in
            if let message = next.message {
                adw_status_page_set_description(status.opaque, message)
                gtk_stack_set_visible_child_name(stack, "status")
            } else {
                gtk_stack_set_visible_child_name(stack, "content")
            }
        }
        return stack.widget
    }
}
