import CGtk
import Foundation
import QudelixBar
import QudelixGtk

enum LibrarySectionName: String, CaseIterable {
    case saved
    case autoeq
    case ai

    var title: String {
        switch self {
        case .saved: return "Saved"
        case .autoeq: return "AutoEq"
        case .ai: return "AI"
        }
    }
}

@MainActor
final class LibraryPage {
    let widget: Widget

    private let stack: OpaquePointer
    private let saved: SavedSection
    private let autoEq: AutoEqSection
    private let ai: AiSection
    let library: LibraryModel

    var layouts: [SplitLayout] { [saved.layout, autoEq.layout, ai.layout] }
    private var switchers: [LibrarySectionName: Widget] = [:]

    var dialog: UnsafeMutableRawPointer? { saved.dialog ?? autoEq.dialog ?? ai.dialog }

    init(model: AppModel) {
        library = model.library
        let box = Ui.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        stack = gtk_stack_new()!.opaque
        let holder = LibraryHolder()
        let parent: () -> UnsafeMutablePointer<GtkWindow>? = { holder.window() }
        saved = SavedSection(model: library.saved, parent: parent)
        autoEq = AutoEqSection(model: library.autoEq, parent: parent)
        ai = AiSection(model: library.ai, parent: parent)
        gtk_stack_add_titled(stack, saved.widget, LibrarySectionName.saved.rawValue, LibrarySectionName.saved.title)
        gtk_stack_add_titled(stack, autoEq.widget, LibrarySectionName.autoeq.rawValue, LibrarySectionName.autoeq.title)
        gtk_stack_add_titled(stack, ai.widget, LibrarySectionName.ai.rawValue, LibrarySectionName.ai.title)

        let switcher = Ui.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_add_css_class(switcher, "linked")
        gtk_widget_set_halign(switcher, GTK_ALIGN_CENTER)
        gtk_widget_set_margin_top(switcher, 8)
        gtk_widget_set_margin_bottom(switcher, 4)
        var first: Widget?
        for section in LibrarySectionName.allCases {
            let button = gtk_toggle_button_new_with_label(section.title)!
            if let first { gtk_toggle_button_set_group(button.typed(GtkToggleButton.self), first.typed(GtkToggleButton.self)) } else { first = button }
            gtk_toggle_button_set_active(button.typed(GtkToggleButton.self), section == .saved ? 1 : 0)
            Ui.append(switcher, button)
            switchers[section] = button
        }
        Ui.append(box, switcher)
        let content = UnsafeMutableRawPointer(stack).assumingMemoryBound(to: GtkWidget.self)
        gtk_widget_set_vexpand(content, 1)
        Ui.append(box, content)
        widget = box
        holder.anchor = widget
        for (section, button) in switchers {
            Signals.onToggled(button) { [weak self] active in
                onMain { if active { self?.show(section) } }
            }
        }
    }

    func expandOthers() { saved.expandOthers() }

    func show(_ section: LibrarySectionName) {
        gtk_stack_set_visible_child_name(stack, section.rawValue)
        if let button = switchers[section] { gtk_toggle_button_set_active(button.typed(GtkToggleButton.self), 1) }
    }

    func presentDialog(_ kind: String) -> Bool {
        switch kind {
        case "delete":
            show(.saved)
            guard let first = library.saved.state.presets.first else { return false }
            return saved.presentDelete(first.id) != nil
        case "name":
            show(.saved)
            return saved.presentSave() != nil
        case "rename":
            show(.saved)
            guard let first = library.saved.state.presets.first else { return false }
            return saved.presentRename(first.id) != nil
        case "forget":
            show(.ai)
            return ai.presentForget() != nil
        default:
            return false
        }
    }
}

@MainActor
final class LibraryHolder {
    var anchor: Widget?

    func window() -> UnsafeMutablePointer<GtkWindow>? {
        anchor.flatMap { Ui.parentWindow(of: $0) }
    }
}
