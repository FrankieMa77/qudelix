import CGtk

package enum DialogDismissal {
    package static func dismiss(_ dialog: UnsafeMutableRawPointer?) {
        guard let open = dialog else { return }
        gtk_window_close(open.assumingMemoryBound(to: GtkWindow.self))
    }
}
