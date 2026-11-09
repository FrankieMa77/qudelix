import CGtk
import XCTest
@testable import QudelixGtk

private nonisolated(unsafe) var toolkitStarted = false

private func pump(for seconds: Double = 0) {
    let deadline = g_get_monotonic_time() + Int(seconds * 1_000_000)
    repeat {
        while g_main_context_iteration(nil, 0) != 0 {}
        if seconds > 0 { g_usleep(10_000) }
    } while g_get_monotonic_time() < deadline
}

final class DialogDismissalTests: XCTestCase {
    override func setUpWithError() throws {
        if !toolkitStarted {
            try XCTSkipUnless(gtk_init_check() != 0, "no display")
            adw_init()
            toolkitStarted = true
        }
    }

    func testAnOpenDialogIsClosedWhenDismissed() {
        let dialog = adw_message_dialog_new(nil, "Overwrite", "Message")!
        let typed = dialog.typed(AdwMessageDialog.self)
        adw_message_dialog_add_response(typed, "cancel", "Cancel")
        adw_message_dialog_set_close_response(typed, "cancel")
        var closed = false
        Signals.onResponse(dialog) { _ in closed = true }
        gtk_window_present(dialog.typed(GtkWindow.self))
        pump(for: 0.3)
        DialogDismissal.dismiss(dialog.raw)
        pump(for: 0.3)
        XCTAssertTrue(closed)
    }

    func testDismissingWithNothingOpenDoesNothing() {
        DialogDismissal.dismiss(nil)
    }
}

final class HistoryActionGateTests: XCTestCase {
    override func setUpWithError() throws {
        if !toolkitStarted {
            try XCTSkipUnless(gtk_init_check() != 0, "no display")
            adw_init()
            toolkitStarted = true
        }
    }

    func testBothActionsNeedTheEqPageNoTextFocusAndAnEditableModel() {
        let on = HistoryActionGate.enabled(onEqPage: true, typing: false, canEdit: true, canUndo: true, canRedo: true)
        XCTAssertTrue(on.undo)
        XCTAssertTrue(on.redo)
        let off = [
            HistoryActionGate.enabled(onEqPage: false, typing: false, canEdit: true, canUndo: true, canRedo: true),
            HistoryActionGate.enabled(onEqPage: true, typing: true, canEdit: true, canUndo: true, canRedo: true),
            HistoryActionGate.enabled(onEqPage: true, typing: false, canEdit: false, canUndo: true, canRedo: true)
        ]
        for result in off {
            XCTAssertFalse(result.undo)
            XCTAssertFalse(result.redo)
        }
    }

    func testEachActionFollowsItsOwnHistory() {
        let undoOnly = HistoryActionGate.enabled(onEqPage: true, typing: false, canEdit: true, canUndo: true, canRedo: false)
        XCTAssertTrue(undoOnly.undo)
        XCTAssertFalse(undoOnly.redo)
        let redoOnly = HistoryActionGate.enabled(onEqPage: true, typing: false, canEdit: true, canUndo: false, canRedo: true)
        XCTAssertFalse(redoOnly.undo)
        XCTAssertTrue(redoOnly.redo)
    }

    func testOnlyEditableWidgetsCountAsTyping() {
        XCTAssertTrue(HistoryActionGate.isEditable(gtk_entry_new()!))
        XCTAssertTrue(HistoryActionGate.isEditable(gtk_search_entry_new()!))
        XCTAssertFalse(HistoryActionGate.isEditable(gtk_button_new()!))
    }
}
