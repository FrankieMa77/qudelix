import CGtk
import Foundation
import QudelixGtk

enum Snapshot {
    static func writePNG(of window: some GPointer, to path: String) -> String? {
        let widget = window.widget
        let width = gtk_widget_get_width(widget)
        let height = gtk_widget_get_height(widget)
        guard width > 0, height > 0 else { return "window has no size (\(width)x\(height))" }
        guard let paintable = gtk_widget_paintable_new(widget) else { return "no paintable" }
        guard let snapshot = gtk_snapshot_new() else { return "no snapshot" }
        gdk_paintable_snapshot(paintable, snapshot, Double(width), Double(height))
        guard let node = gtk_snapshot_free_to_node(snapshot) else { return "empty render node" }
        let native = gtk_widget_get_native(widget)
        guard let renderer = gtk_native_get_renderer(native) else { return "no renderer" }
        guard let texture = gsk_renderer_render_texture(renderer, node, nil) else { return "render failed" }
        let saved = gdk_texture_save_to_png(texture, path) != 0
        gsk_render_node_unref(node)
        g_object_unref(texture.raw)
        g_object_unref(paintable.raw)
        return saved ? nil : "png write failed"
    }
}
