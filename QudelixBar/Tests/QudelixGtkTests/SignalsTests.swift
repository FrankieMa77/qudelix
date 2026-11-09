import CGtk
import XCTest
@testable import QudelixGtk

private final class DeinitFlag {
    let onDeinit: () -> Void

    init(_ onDeinit: @escaping () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit { onDeinit() }
}

final class SignalsTests: XCTestCase {
    private func makeAdjustment() -> UnsafeMutablePointer<GtkAdjustment> {
        let adjustment = gtk_adjustment_new(0, 0, 100, 1, 10, 0)!
        return adjustment
    }

    func testValueChangedDeliversNewValue() {
        let adjustment = makeAdjustment()
        var seen: [Double] = []
        Signals.onAdjustmentChanged(adjustment) { seen.append($0) }
        gtk_adjustment_set_value(adjustment, 42)
        gtk_adjustment_set_value(adjustment, 42)
        gtk_adjustment_set_value(adjustment, 7)
        XCTAssertEqual(seen, [42, 7])
        g_object_unref(adjustment.raw)
    }

    func testPlainSignalAndNotifyFire() {
        let adjustment = makeAdjustment()
        var plain = 0
        var notified = 0
        Signals.connect(adjustment, signal: "changed") { plain += 1 }
        Signals.onNotify(adjustment, property: "value") { _ in notified += 1 }
        gtk_adjustment_set_value(adjustment, 5)
        gtk_adjustment_configure(adjustment, 5, 0, 200, 1, 10, 0)
        XCTAssertEqual(notified, 1)
        XCTAssertEqual(plain, 1)
        g_object_unref(adjustment.raw)
    }

    func testDisconnectStopsDelivery() {
        let adjustment = makeAdjustment()
        var count = 0
        let id = Signals.onAdjustmentChanged(adjustment) { _ in count += 1 }
        gtk_adjustment_set_value(adjustment, 1)
        Signals.disconnect(adjustment, id: id)
        gtk_adjustment_set_value(adjustment, 2)
        XCTAssertEqual(count, 1)
        g_object_unref(adjustment.raw)
    }

    func testClosureIsReleasedWhenInstanceIsDestroyed() {
        let adjustment = makeAdjustment()
        var released = false
        var flag: DeinitFlag? = DeinitFlag { released = true }
        Signals.connect(adjustment, signal: "value-changed") { [flag] in _ = flag }
        flag = nil
        XCTAssertFalse(released)
        g_object_unref(adjustment.raw)
        XCTAssertTrue(released)
    }

    func testClosureIsReleasedOnDisconnect() {
        let adjustment = makeAdjustment()
        var released = false
        var flag: DeinitFlag? = DeinitFlag { released = true }
        let id = Signals.connect(adjustment, signal: "value-changed") { [flag] in _ = flag }
        flag = nil
        XCTAssertFalse(released)
        Signals.disconnect(adjustment, id: id)
        XCTAssertTrue(released)
        g_object_unref(adjustment.raw)
    }

    func testToggleDrawAndRangeShapesWithDisplay() throws {
        try XCTSkipUnless(gtk_init_check() != 0, "no display")

        let toggle = gtk_toggle_button_new()!
        var states: [Bool] = []
        Signals.onToggled(toggle) { states.append($0) }
        gtk_toggle_button_set_active(toggle.raw.assumingMemoryBound(to: GtkToggleButton.self), 1)
        gtk_toggle_button_set_active(toggle.raw.assumingMemoryBound(to: GtkToggleButton.self), 0)
        XCTAssertEqual(states, [true, false])

        let scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 10, 1)!
        var values: [Double] = []
        Signals.onValueChanged(scale) { values.append($0) }
        gtk_range_set_value(scale.raw.assumingMemoryBound(to: GtkRange.self), 3)
        XCTAssertEqual(values, [3])

        let area = gtk_drawing_area_new()!
        var drawn: (Int32, Int32)?
        Signals.setDrawFunc(area) { _, width, height in drawn = (width, height) }
        let window = gtk_window_new()!
        gtk_widget_set_size_request(area, 120, 80)
        gtk_window_set_child(window.raw.assumingMemoryBound(to: GtkWindow.self), area)
        gtk_window_present(window.raw.assumingMemoryBound(to: GtkWindow.self))
        let context = g_main_context_default()
        for _ in 0..<400 where drawn == nil {
            g_main_context_iteration(context, 0)
            usleep(5_000)
        }
        XCTAssertNotNil(drawn)
        XCTAssertGreaterThan(drawn?.0 ?? 0, 0)
        gtk_window_destroy(window.raw.assumingMemoryBound(to: GtkWindow.self))
    }
}
