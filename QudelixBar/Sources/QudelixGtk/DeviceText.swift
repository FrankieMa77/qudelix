import CGtk
import Foundation
import QudelixBar

package enum DeviceText {
    package static func escaped(_ text: String) -> String {
        guard let raw = g_markup_escape_text(text, -1) else { return text }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    package static func setSubtitle(_ row: some GPointer, _ text: String?) {
        adw_action_row_set_subtitle(row.typed(AdwActionRow.self), escaped(text ?? "Unknown"))
    }

    package static func volume(_ db: Double) -> String {
        EqFormat.decibels(db)
    }

    package static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
