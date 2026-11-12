import CGtk

private final class ClipboardCompletion {
    let handler: (String?) -> Void

    init(handler: @escaping (String?) -> Void) {
        self.handler = handler
    }
}

private let clipboardRead: @convention(c) (UnsafeMutablePointer<GObject>?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { source, result, data in
    guard let data else { return }
    let completion = Unmanaged<ClipboardCompletion>.fromOpaque(data).takeRetainedValue()
    var error: UnsafeMutablePointer<GError>?
    var text: String?
    if let source, let result {
        if let raw = gdk_clipboard_read_text_finish(OpaquePointer(source), result, &error) {
            text = String(cString: raw)
            g_free(raw)
        }
    }
    if let error { g_error_free(error) }
    completion.handler(text)
}

package enum Clipboard {
    package static func readText(from widget: UnsafeMutablePointer<GtkWidget>,
                                 handler: @escaping (String?) -> Void) {
        guard let clipboard = gtk_widget_get_clipboard(widget) else {
            handler(nil)
            return
        }
        let completion = ClipboardCompletion(handler: handler)
        gdk_clipboard_read_text_async(clipboard, nil, clipboardRead,
                                      Unmanaged.passRetained(completion).toOpaque())
    }
}
