import CGtk
import Foundation
import QudelixGtk

@MainActor
final class SplitLayout {
    static let narrowBreakpoint = "max-width: 800sp"

    let widget: Widget
    private let body: Widget
    private let outer: Widget
    private let content: Widget
    private let leftBox: Widget
    private let left: Widget
    private let right: Widget

    init(top: [Widget], left leftGroups: [Widget], right rightGroups: [Widget]) {
        let topBox = Ui.box(GTK_ORIENTATION_VERTICAL, spacing: 12)
        Self.margins(topBox, top: 12, bottom: 0)
        for group in top { Ui.append(topBox, group) }

        let leftColumn = Self.column(leftGroups)
        left = leftColumn.scroller
        leftBox = leftColumn.content
        right = Self.column(rightGroups).scroller
        body = Ui.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_box_set_homogeneous(body.typed(GtkBox.self), 1)
        gtk_widget_set_vexpand(body, 1)
        Ui.append(body, left)
        Ui.append(body, right)

        content = Ui.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Ui.append(content, topBox)
        Ui.append(content, body)

        outer = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(outer.opaque, GTK_POLICY_NEVER, GTK_POLICY_EXTERNAL)
        gtk_scrolled_window_set_child(outer.opaque, content)
        gtk_widget_set_vexpand(outer, 1)
        widget = outer
    }

    func reorderLeft(_ groups: [Widget]) {
        var previous: Widget?
        for group in groups {
            gtk_box_reorder_child_after(leftBox.typed(GtkBox.self), group, previous)
            previous = group
        }
    }

    private static func margins(_ widget: Widget, top: Int32, bottom: Int32) {
        gtk_widget_set_margin_top(widget, top)
        gtk_widget_set_margin_bottom(widget, bottom)
        gtk_widget_set_margin_start(widget, 12)
        gtk_widget_set_margin_end(widget, 12)
    }

    private static func column(_ groups: [Widget]) -> (scroller: Widget, content: Widget) {
        let content = Ui.box(GTK_ORIENTATION_VERTICAL, spacing: 18)
        margins(content, top: 12, bottom: 18)
        for group in groups { Ui.append(content, group) }
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(scroller.opaque, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(scroller.opaque, content)
        gtk_widget_set_hexpand(scroller, 1)
        gtk_widget_set_vexpand(scroller, 1)
        return (scroller, content)
    }

    var isNarrow: Bool {
        gtk_orientable_get_orientation(body.opaque) == GTK_ORIENTATION_VERTICAL
    }

    func addNarrowSetters(to breakpoint: OpaquePointer) {
        var vertical = GValue()
        g_value_init(&vertical, gtk_orientation_get_type())
        g_value_set_enum(&vertical, Int32(GTK_ORIENTATION_VERTICAL.rawValue))
        adw_breakpoint_add_setter(breakpoint, body.object, "orientation", &vertical)

        var uneven = GValue()
        g_value_init(&uneven, g_type_from_name("gboolean"))
        g_value_set_boolean(&uneven, 0)
        adw_breakpoint_add_setter(breakpoint, body.object, "homogeneous", &uneven)

        var scrolls = GValue()
        g_value_init(&scrolls, gtk_policy_type_get_type())
        g_value_set_enum(&scrolls, Int32(GTK_POLICY_AUTOMATIC.rawValue))
        adw_breakpoint_add_setter(breakpoint, outer.object, "vscrollbar-policy", &scrolls)

        var grows = GValue()
        g_value_init(&grows, gtk_policy_type_get_type())
        g_value_set_enum(&grows, Int32(GTK_POLICY_NEVER.rawValue))
        adw_breakpoint_add_setter(breakpoint, left.object, "vscrollbar-policy", &grows)
        adw_breakpoint_add_setter(breakpoint, right.object, "vscrollbar-policy", &grows)
    }

    private final class Reveal {
        let layout: SplitLayout
        let target: Widget

        init(layout: SplitLayout, target: Widget) {
            self.layout = layout
            self.target = target
        }
    }

    func reveal(_ target: Widget) {
        guard isNarrow else { return }
        let job = Reveal(layout: self, target: target)
        g_timeout_add(60, { data in
            let job = Unmanaged<Reveal>.fromOpaque(data!).takeRetainedValue()
            MainActor.assumeIsolated { job.layout.scroll(to: job.target) }
            return 0
        }, Unmanaged.passRetained(job).toOpaque())
    }

    private func scroll(to target: Widget) {
        guard isNarrow, gtk_widget_get_mapped(target) != 0 else { return }
        var origin = graphene_point_t(x: 0, y: 0)
        var found = graphene_point_t()
        guard gtk_widget_compute_point(target, content, &origin, &found) != 0 else { return }
        let adjustment = gtk_scrolled_window_get_vadjustment(outer.opaque)
        gtk_adjustment_set_value(adjustment, Double(found.y) - 8)
    }
}
