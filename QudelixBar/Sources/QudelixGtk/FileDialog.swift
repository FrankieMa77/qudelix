import CGtk
import Foundation

package struct FileFilterSpec: Equatable {
    package let name: String
    package let suffixes: [String]
}

package enum TextFileFilters {
    package static let specs: [FileFilterSpec] = [
        FileFilterSpec(name: "Text files", suffixes: ["txt", "text"]),
        FileFilterSpec(name: "All files", suffixes: [])
    ]

    package static func matches(_ fileName: String, _ spec: FileFilterSpec) -> Bool {
        guard !spec.suffixes.isEmpty else { return true }
        let lowered = fileName.lowercased()
        return spec.suffixes.contains { lowered.hasSuffix("." + $0) }
    }
}

private final class FileDialogCompletion {
    let handler: (String?) -> Void
    let dialog: UnsafeMutableRawPointer

    init(dialog: UnsafeMutableRawPointer, handler: @escaping (String?) -> Void) {
        self.dialog = dialog
        self.handler = handler
    }
}

private let fileDialogFinished: @convention(c) (UnsafeMutablePointer<GObject>?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, result, data in
    guard let data else { return }
    let completion = Unmanaged<FileDialogCompletion>.fromOpaque(data).takeRetainedValue()
    var error: UnsafeMutablePointer<GError>?
    let dialog = OpaquePointer(completion.dialog)
    let file = gtk_file_dialog_open_finish(dialog, result, &error)
    if let error { g_error_free(error) }
    var path: String?
    if let file {
        if let raw = g_file_get_path(file) {
            path = String(cString: raw)
            g_free(raw)
        }
        g_object_unref(UnsafeMutableRawPointer(file))
    }
    g_object_unref(completion.dialog)
    completion.handler(path)
}

package enum FileDialog {
    package static func openText(parent: UnsafeMutableRawPointer?, title: String,
                                 specs: [FileFilterSpec] = TextFileFilters.specs,
                                 handler: @escaping (String?) -> Void) {
        let dialog = gtk_file_dialog_new()!
        gtk_file_dialog_set_title(dialog, title)
        gtk_file_dialog_set_modal(dialog, 1)
        let store = g_list_store_new(gtk_file_filter_get_type())!
        var first: OpaquePointer?
        for spec in specs {
            let filter = gtk_file_filter_new()!
            gtk_file_filter_set_name(filter, spec.name)
            if spec.suffixes.isEmpty {
                gtk_file_filter_add_pattern(filter, "*")
            } else {
                for suffix in spec.suffixes { gtk_file_filter_add_suffix(filter, suffix) }
            }
            g_list_store_append(store, UnsafeMutableRawPointer(filter))
            if first == nil { first = filter }
            g_object_unref(UnsafeMutableRawPointer(filter))
        }
        gtk_file_dialog_set_filters(dialog, store)
        if let first { gtk_file_dialog_set_default_filter(dialog, first) }
        g_object_unref(UnsafeMutableRawPointer(store))
        let raw = UnsafeMutableRawPointer(dialog)
        let completion = FileDialogCompletion(dialog: raw, handler: handler)
        gtk_file_dialog_open(dialog, parent?.assumingMemoryBound(to: GtkWindow.self), nil, fileDialogFinished,
                             Unmanaged.passRetained(completion).toOpaque())
    }
}
