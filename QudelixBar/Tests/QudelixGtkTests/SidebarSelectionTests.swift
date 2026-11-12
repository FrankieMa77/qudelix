import CGtk
import XCTest
@testable import QudelixGtk

nonisolated(unsafe) private var capturedCriticals: [String] = []
nonisolated(unsafe) private var capturing = false

private let captureWriter: GLogWriterFunc = { level, fields, count, _ in
    guard capturing, level.rawValue & (G_LOG_LEVEL_CRITICAL.rawValue | G_LOG_LEVEL_WARNING.rawValue) != 0, let fields else {
        return g_log_writer_default(level, fields, count, nil)
    }
    for index in 0..<Int(count) {
        let field = fields[index]
        if let key = field.key, String(cString: key) == "MESSAGE", let value = field.value {
            capturedCriticals.append(String(cString: value.assumingMemoryBound(to: CChar.self)))
        }
    }
    return G_LOG_WRITER_HANDLED
}

final class SidebarSelectionTests: XCTestCase {
    private static let installWriter: Void = g_log_set_writer_func(captureWriter, nil, nil)

    private let names = ["device", "eq", "presets", "library"]

    override func setUpWithError() throws {
        try XCTSkipUnless(gtk_init_check() != 0, "no display")
        adw_init()
    }

    private func pump(_ rounds: Int = 20) {
        let context = g_main_context_default()
        for _ in 0..<rounds {
            while g_main_context_iteration(context, 0) != 0 {}
            usleep(2_000)
        }
    }

    func testSelectingSidebarRowsSwitchesTheStackWhileStateKeepsUpdating() {
        let stack = adw_view_stack_new()!
        let status = gtk_label_new("")!
        for name in names {
            adw_view_stack_add_named(stack.opaque, gtk_label_new(name)!, name)
        }
        let list = gtk_list_box_new()!
        var rows: [UnsafeMutablePointer<GtkWidget>] = []
        for name in names {
            let row = gtk_list_box_row_new()!
            gtk_list_box_row_set_child(row.typed(GtkListBoxRow.self), gtk_label_new(name)!)
            gtk_list_box_append(list.opaque, row)
            rows.append(row)
        }
        var selected: [Int] = []
        Signals.onRowSelected(list) { index in
            selected.append(index)
            adw_view_stack_set_visible_child_name(stack.opaque, self.names[index])
        }
        let timer = g_timeout_add(5, { data in
            gtk_label_set_text(OpaquePointer(data), "tick")
            return 1
        }, UnsafeMutableRawPointer(status))
        defer { g_source_remove(timer) }

        func visible() -> String? {
            adw_view_stack_get_visible_child_name(stack.opaque).map { String(cString: $0) }
        }

        XCTAssertEqual(visible(), "device")
        for index in [1, 2, 3, 1] {
            gtk_list_box_select_row(list.opaque, rows[index].typed(GtkListBoxRow.self))
            pump()
            XCTAssertEqual(visible(), names[index])
        }
        XCTAssertEqual(selected, [1, 2, 3, 1])
        pump(60)
        XCTAssertEqual(visible(), "eq")
    }

    func testRowActivatedReportsTheRowIndex() {
        let list = gtk_list_box_new()!
        var rows: [UnsafeMutablePointer<GtkWidget>] = []
        for name in names {
            let row = gtk_list_box_row_new()!
            gtk_list_box_row_set_child(row.typed(GtkListBoxRow.self), gtk_label_new(name)!)
            gtk_list_box_append(list.opaque, row)
            rows.append(row)
        }
        var activated: [Int] = []
        Signals.onRowActivated(list) { activated.append($0) }
        gtk_list_box_select_row(list.opaque, rows[2].typed(GtkListBoxRow.self))
        gtk_widget_activate(rows[2])
        XCTAssertEqual(activated, [2])
    }

    func testAccessibleStatesAndSpinButtonsRaiseNoCriticals() {
        capturedCriticals = []
        capturing = true
        defer { capturing = false }
        SidebarSelectionTests.installWriter
        let list = gtk_list_box_new()!
        let row = gtk_list_box_row_new()!
        gtk_list_box_append(list.opaque, row)
        Accessible.setSelected(row, true)
        Accessible.setSelected(row, false)
        let spin = gtk_spin_button_new_with_range(-10, 10, 1)!
        var seen: [Double] = []
        Signals.onSpinChanged(spin) { seen.append($0) }
        gtk_spin_button_set_value(spin.opaque, 4)
        XCTAssertEqual(seen, [4])
        let window = gtk_window_new()!
        gtk_window_set_child(window.typed(GtkWindow.self), list)
        gtk_window_present(window.typed(GtkWindow.self))
        pump()
        gtk_window_destroy(window.typed(GtkWindow.self))
        XCTAssertEqual(capturedCriticals.filter { $0.contains("assertion") }, [])
    }
}
