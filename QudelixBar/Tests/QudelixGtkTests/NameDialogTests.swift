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

final class NameDialogTests: XCTestCase {
    override func setUpWithError() throws {
        if !toolkitStarted {
            try XCTSkipUnless(gtk_init_check() != 0, "no display")
            adw_init()
            toolkitStarted = true
        }
    }

    private func innerText(_ entry: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget> {
        gtk_widget_get_first_child(entry)!
    }

    private func pressEnter(in entry: UnsafeMutablePointer<GtkWidget>) {
        let text = innerText(entry)
        var instance = GValue()
        g_value_init(&instance, gtk_text_get_type())
        g_value_set_object(&instance, UnsafeMutableRawPointer(text))
        g_signal_emitv(&instance, g_signal_lookup("activate", gtk_text_get_type()), 0, nil)
        g_value_unset(&instance)
        pump(for: 0.7)
    }

    private func legacyDialog(text: String, blockWhenBlank: Bool,
                              responses: @escaping (String) -> Void) -> (UnsafeMutableRawPointer, UnsafeMutablePointer<GtkWidget>) {
        let dialog = adw_message_dialog_new(nil, "Name", "Message")!
        let typed = dialog.typed(AdwMessageDialog.self)
        let entry = gtk_entry_new()!
        gtk_editable_set_text(entry.opaque, text)
        gtk_entry_set_activates_default(entry.typed(GtkEntry.self), 1)
        adw_message_dialog_set_extra_child(typed, entry)
        adw_message_dialog_add_response(typed, "cancel", "Cancel")
        adw_message_dialog_add_response(typed, "confirm", "Save")
        adw_message_dialog_set_default_response(typed, "confirm")
        adw_message_dialog_set_close_response(typed, "cancel")
        adw_message_dialog_set_response_enabled(typed, "confirm", blockWhenBlank ? 0 : 1)
        Signals.connect(entry, signal: "activate") {
            if !blockWhenBlank { adw_message_dialog_response(typed, "confirm") }
        }
        Signals.onResponse(dialog, handler: responses)
        gtk_window_present(dialog.typed(GtkWindow.self))
        pump()
        return (dialog.raw, entry)
    }

    private func newDialog(text: String, allowsBlank: Bool,
                           done: @escaping (String?) -> Void) -> (UnsafeMutableRawPointer, UnsafeMutablePointer<GtkWidget>) {
        let dialog = NameDialog.make(parent: nil, title: "Name", message: "Message", text: text,
                                     placeholder: "Name", action: "Save", maxLength: 29,
                                     allowsBlank: allowsBlank, done: done)
        g_object_ref(dialog)
        gtk_window_present(dialog.typed(GtkWindow.self))
        pump()
        return (dialog, NameDialog.entry(of: dialog)!)
    }

    func testLegacyWiringRespondsTwiceOnEnter() {
        var count = 0
        let (dialog, entry) = legacyDialog(text: "Warm", blockWhenBlank: false) { _ in count += 1 }
        g_object_ref(dialog)
        pressEnter(in: entry)
        XCTAssertEqual(count, 2)
        g_object_unref(dialog)
    }

    func testEnterRespondsOnceAndClosesTheDialog() {
        var results: [String?] = []
        let (dialog, entry) = newDialog(text: "Warm", allowsBlank: false) { results.append($0) }
        XCTAssertNotEqual(gtk_widget_get_visible(dialog.widget), 0)
        pressEnter(in: entry)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first ?? nil, "Warm")
        XCTAssertEqual(gtk_widget_get_visible(dialog.widget), 0)
        g_object_unref(dialog)
    }

    func testEnterWithBlankNameDoesNothingWhenBlankIsRefused() {
        var results: [String?] = []
        let (dialog, entry) = newDialog(text: "   ", allowsBlank: false) { results.append($0) }
        pressEnter(in: entry)
        XCTAssertTrue(results.isEmpty)
        XCTAssertNotEqual(gtk_widget_get_visible(dialog.widget), 0)
        gtk_window_close(dialog.typed(GtkWindow.self))
        pump()
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first ?? "x")
        g_object_unref(dialog)
    }

    func testLegacyWiringWithDisabledConfirmDoesNothing() {
        var count = 0
        let (dialog, entry) = legacyDialog(text: "", blockWhenBlank: true) { _ in count += 1 }
        g_object_ref(dialog)
        pressEnter(in: entry)
        XCTAssertEqual(count, 0)
        gtk_window_destroy(dialog.typed(GtkWindow.self))
        g_object_unref(dialog)
    }

    func testBlankIsAcceptedWhenAllowed() {
        var results: [String?] = []
        let (dialog, entry) = newDialog(text: "", allowsBlank: true) { results.append($0) }
        pressEnter(in: entry)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first ?? nil, "")
        g_object_unref(dialog)
    }

    func testClosingTheWindowCancelsOnce() {
        var results: [String?] = []
        let (dialog, _) = newDialog(text: "Warm", allowsBlank: false) { results.append($0) }
        gtk_window_close(dialog.typed(GtkWindow.self))
        pump()
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first ?? "x")
        XCTAssertEqual(gtk_widget_get_visible(dialog.widget), 0)
        g_object_unref(dialog)
    }

    func testAChoiceListRidesAlongAndItsSelectionIsReported() {
        var results: [(String?, Int)] = []
        let dialog = NameDialog.make(parent: nil, title: "Name", message: "Message", text: "Warm",
                                     placeholder: "Name", action: "Save", maxLength: 29,
                                     allowsBlank: false, choices: ["Every output", "Speakers"],
                                     selectedChoice: 1, choicesEnabled: true,
                                     choiceLabel: "Applies to") { results.append(($0, $1)) }
        g_object_ref(dialog)
        gtk_window_present(dialog.typed(GtkWindow.self))
        pump()
        let entry = NameDialog.entry(of: dialog)!
        XCTAssertEqual(String(cString: gtk_editable_get_text(entry.opaque)), "Warm")
        pressEnter(in: entry)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.0, "Warm")
        XCTAssertEqual(results.first?.1, 1)
        g_object_unref(dialog)
    }

    func testAChoiceListThatIsNotEnabledStillReportsItsSelection() {
        var results: [(String?, Int)] = []
        let dialog = NameDialog.make(parent: nil, title: "Name", message: "Message", text: "Warm",
                                     placeholder: "Name", action: "Save", maxLength: 29,
                                     allowsBlank: false, choices: ["Every output", "This output"],
                                     selectedChoice: 0, choicesEnabled: false,
                                     choiceLabel: "Applies to") { results.append(($0, $1)) }
        g_object_ref(dialog)
        gtk_window_present(dialog.typed(GtkWindow.self))
        pump()
        pressEnter(in: NameDialog.entry(of: dialog)!)
        XCTAssertEqual(results.first?.1, 0)
        g_object_unref(dialog)
    }
}
