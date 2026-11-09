import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@MainActor
final class ConnectionStatusPage {
    let statusPage: OpaquePointer
    private let spinner: UnsafeMutablePointer<GtkWidget>

    init() {
        statusPage = adw_status_page_new()!.opaque
        spinner = gtk_spinner_new()!
        gtk_widget_set_size_request(spinner, 32, 32)
        gtk_widget_set_halign(spinner, GTK_ALIGN_CENTER)
        Accessible.setLabel(spinner, "Working")
        adw_status_page_set_child(statusPage, spinner)
    }

    var widget: UnsafeMutablePointer<GtkWidget> {
        UnsafeMutableRawPointer(statusPage).assumingMemoryBound(to: GtkWidget.self)
    }

    private static func escaped(_ text: String) -> String { Ui.escaped(text) }

    func showProgress(title: String, detail: String) {
        adw_status_page_set_icon_name(statusPage, "audio-headphones-symbolic")
        adw_status_page_set_title(statusPage, title)
        adw_status_page_set_description(statusPage, Self.escaped(detail))
        gtk_widget_set_visible(spinner, 1)
        gtk_spinner_set_spinning(spinner.opaque, 1)
    }

    private static func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + String(text.dropFirst())
    }

    func show(for connection: AppConnection) {
        let icon: String
        let title: String
        let detail: String
        var busy = false
        switch connection {
        case .searching:
            icon = "audio-headphones-symbolic"
            title = "Looking for your Qudelix 5K"
            detail = "Connect it with a USB cable (recommended). Bluetooth is untested. This window connects by itself."
            busy = true
        case .connecting:
            icon = "audio-headphones-symbolic"
            title = "Connecting"
            detail = "Talking to the device."
            busy = true
        case .busy:
            icon = "dialog-information-symbolic"
            title = "The device is in use"
            detail = "Another copy of Qudelix, or the qudelix command, is using it. Close the other one and this window connects by itself."
        case .noTransport(let advice):
            icon = "dialog-warning-symbolic"
            title = "No way to reach the device"
            detail = advice ?? "This system offers neither USB nor Bluetooth access to the device."
        case .permissionDenied(let advice):
            icon = "dialog-password-symbolic"
            title = "Cannot open the device"
            detail = advice
        case .unsupported(let reason):
            icon = "dialog-warning-symbolic"
            title = "This device is not supported"
            detail = Self.sentence(reason) + "."
        case .error(let message):
            icon = "dialog-error-symbolic"
            title = "Could not connect"
            detail = Self.sentence(message) + ". Trying again."
        case .connected:
            return
        }
        adw_status_page_set_icon_name(statusPage, icon)
        adw_status_page_set_title(statusPage, title)
        adw_status_page_set_description(statusPage, Self.escaped(detail))
        gtk_widget_set_visible(spinner, busy ? 1 : 0)
        gtk_spinner_set_spinning(spinner.opaque, busy ? 1 : 0)
    }
}
