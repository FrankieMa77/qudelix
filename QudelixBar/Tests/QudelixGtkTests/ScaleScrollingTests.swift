import CGtk
import XCTest
@testable import QudelixGtk

private nonisolated(unsafe) var toolkitStarted = false

final class ScaleScrollingTests: XCTestCase {
    override func setUpWithError() throws {
        if !toolkitStarted {
            try XCTSkipUnless(gtk_init_check() != 0, "no display")
            adw_init()
            toolkitStarted = true
        }
    }

    private struct Fixture {
        let scale: UnsafeMutablePointer<GtkWidget>
        let window: UnsafeMutablePointer<GtkWidget>
        let host: UnsafeMutablePointer<GtkWidget>
    }

    private func makeFixture(installed: Bool) -> Fixture {
        let scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, -60, 0, 0.5)!
        gtk_range_set_value(scale.typed(GtkRange.self), -30)
        if installed { ScaleScrolling.install(on: scale) }
        let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        let filler = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_widget_set_size_request(filler, 100, 2000)
        gtk_box_append(column.typed(GtkBox.self), scale)
        gtk_box_append(column.typed(GtkBox.self), filler)
        let window = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_child(window.opaque, column)
        gtk_widget_set_size_request(window, 300, 300)
        let host = gtk_window_new()!
        gtk_window_set_child(host.typed(GtkWindow.self), window)
        gtk_window_present(host.typed(GtkWindow.self))
        for _ in 0..<50 { g_main_context_iteration(nil, 0) }
        return Fixture(scale: scale, window: window, host: host)
    }

    private func deliverScroll(to widget: UnsafeMutablePointer<GtkWidget>, dx: Double, dy: Double) {
        guard let model = gtk_widget_observe_controllers(widget) else { return }
        defer { g_object_unref(UnsafeMutableRawPointer(model)) }
        var captures: [UnsafeMutableRawPointer] = []
        var others: [UnsafeMutableRawPointer] = []
        let count = g_list_model_get_n_items(model)
        for index in 0..<count {
            guard let item = g_list_model_get_item(model, index) else { continue }
            let controller = UnsafeMutableRawPointer(item)
            let phase = gtk_event_controller_get_propagation_phase(OpaquePointer(controller))
            if phase == GTK_PHASE_CAPTURE { captures.append(controller) } else { others.append(controller) }
        }
        defer { (captures + others).forEach { g_object_unref($0) } }
        for controller in captures + others where emitScroll(controller, dx: dx, dy: dy) { return }
    }

    private func emitScroll(_ controller: UnsafeMutableRawPointer, dx: Double, dy: Double) -> Bool {
        guard g_type_check_instance_is_a(controller.assumingMemoryBound(to: GTypeInstance.self),
                                         gtk_event_controller_scroll_get_type()) != 0 else { return false }
        let signal = g_signal_lookup("scroll", gtk_event_controller_scroll_get_type())
        var values = [GValue](repeating: GValue(), count: 3)
        g_value_init(&values[0], gtk_event_controller_scroll_get_type())
        g_value_set_object(&values[0], controller)
        g_value_init(&values[1], GType(15 << 2))
        g_value_set_double(&values[1], dx)
        g_value_init(&values[2], GType(15 << 2))
        g_value_set_double(&values[2], dy)
        var result = GValue()
        g_value_init(&result, GType(5 << 2))
        g_signal_emitv(&values, signal, 0, &result)
        let handled = g_value_get_boolean(&result) != 0
        for index in 0..<3 { g_value_unset(&values[index]) }
        g_value_unset(&result)
        return handled
    }

    private func value(_ scale: UnsafeMutablePointer<GtkWidget>) -> Double {
        gtk_range_get_value(scale.typed(GtkRange.self))
    }

    private func offset(_ window: UnsafeMutablePointer<GtkWidget>) -> Double {
        gtk_adjustment_get_value(gtk_scrolled_window_get_vadjustment(window.opaque))
    }

    func testWheelOverAScaleLeavesTheValueAndScrollsThePage() {
        let fixture = makeFixture(installed: true)
        defer { gtk_window_destroy(fixture.host.typed(GtkWindow.self)) }
        deliverScroll(to: fixture.scale, dx: 0, dy: 3)
        XCTAssertEqual(value(fixture.scale), -30)
        XCTAssertGreaterThan(offset(fixture.window), 0)
        deliverScroll(to: fixture.scale, dx: 0, dy: -10)
        XCTAssertEqual(value(fixture.scale), -30)
        XCTAssertEqual(offset(fixture.window), 0)
    }

    func testWheelChangesAnUnprotectedScaleSoTheProbeIsSound() {
        let fixture = makeFixture(installed: false)
        defer { gtk_window_destroy(fixture.host.typed(GtkWindow.self)) }
        deliverScroll(to: fixture.scale, dx: 0, dy: 3)
        XCTAssertNotEqual(value(fixture.scale), -30)
    }
}
