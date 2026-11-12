import CGtk
import Foundation

package enum ScaleScrolling {
    package static func install(on scale: some GPointer) {
        let target = scale.widget
        Signals.addCaptureScroll(to: scale) { dx, dy in
            forward(from: target, dx: dx, dy: dy)
            return true
        }
    }

    static func forward(from widget: UnsafeMutablePointer<GtkWidget>, dx: Double, dy: Double) {
        guard let ancestor = gtk_widget_get_ancestor(widget, gtk_scrolled_window_get_type()) else { return }
        let window = OpaquePointer(ancestor)
        if dy != 0, let adjustment = gtk_scrolled_window_get_vadjustment(window) {
            move(adjustment, by: dy)
        }
        if dx != 0, let adjustment = gtk_scrolled_window_get_hadjustment(window) {
            move(adjustment, by: dx)
        }
    }

    private static func move(_ adjustment: UnsafeMutablePointer<GtkAdjustment>, by delta: Double) {
        let page = gtk_adjustment_get_page_size(adjustment)
        let step = pow(page, 2.0 / 3.0)
        let lower = gtk_adjustment_get_lower(adjustment)
        let upper = max(lower, gtk_adjustment_get_upper(adjustment) - page)
        let next = min(max(gtk_adjustment_get_value(adjustment) + delta * step, lower), upper)
        gtk_adjustment_set_value(adjustment, next)
    }
}
