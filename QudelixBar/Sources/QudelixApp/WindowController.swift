import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@MainActor
final class WindowController {
    private var lifecycle = WindowLifecycle()
    private var window: UnsafeMutablePointer<GtkWidget>?
    private var application: UnsafeMutableRawPointer?
    private var held = false
    var shown: (() -> Void)?

    func attach(window: UnsafeMutablePointer<GtkWidget>, application: UnsafeMutableRawPointer) {
        self.window = window
        self.application = application
        Signals.onCloseRequest(window) { [unowned self] in
            onMain {
                switch self.lifecycle.closeRequested() {
                case .hide:
                    gtk_widget_set_visible(window, 0)
                    self.hold()
                    return true
                case .quit:
                    if let application = self.application {
                        g_application_quit(application.assumingMemoryBound(to: GApplication.self))
                    }
                    return true
                }
            }
        }
    }

    func launch(startHidden: Bool) {
        let effect = lifecycle.launch(startHidden: startHidden)
        if startHidden { hold() }
        apply(effect)
        guard startHidden else { return }
        g_timeout_add_seconds(UInt32(WindowLifecycle.watcherGrace), { data in
            onMain { Unmanaged<WindowController>.fromOpaque(data!).takeUnretainedValue().graceExpired() }
            return 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func watcherChanged(_ present: Bool) {
        apply(lifecycle.watcherChanged(present))
    }

    func trayUnavailable() {
        apply(lifecycle.watcherChanged(false))
        apply(lifecycle.graceExpired())
    }

    func show() {
        apply(lifecycle.present())
    }

    private func graceExpired() {
        apply(lifecycle.graceExpired())
    }

    private func apply(_ effect: WindowLifecycle.Effect) {
        guard effect == .show, let window else { return }
        gtk_window_present(window.typed(GtkWindow.self))
        shown?()
        release()
    }

    private func hold() {
        guard !held, let application else { return }
        held = true
        g_application_hold(application.assumingMemoryBound(to: GApplication.self))
    }

    private func release() {
        guard held, let application else { return }
        held = false
        g_application_release(application.assumingMemoryBound(to: GApplication.self))
    }
}
