import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@MainActor
final class AutoEqSection {
    let widget: Widget
    let layout: SplitLayout

    private struct Entry {
        let row: Widget
        let marker: Widget
    }

    private let model: AutoEqSearchModel
    private let parent: () -> UnsafeMutablePointer<GtkWindow>?
    private let search: Widget
    private let spinner = Ui.spinner()
    private let status: Widget
    private let cancelButton: Widget
    private let retryButton: Widget
    private let targetRow: Widget
    private let resultsGroup: Widget
    private let more: Widget
    private let previewGroup: Widget
    private let curve = CurvePreviewView()
    private let previewTitle: Widget
    private let previewSubtitle: Widget
    private let provenance: Widget
    private let warnings: Widget
    private let preference: Widget
    private let applyButton: Widget
    private let saveButton: Widget
    private let reason: Widget
    private let summary: Widget
    private var entries: [String: Entry] = [:]
    private var shown: [AutoEqResult] = []
    private var shownTargets: [String] = []
    private var state = AutoEqState()
    private var updating = false
    private(set) var dialog: UnsafeMutableRawPointer?

    init(model: AutoEqSearchModel, parent: @escaping () -> UnsafeMutablePointer<GtkWindow>?) {
        self.model = model
        self.parent = parent

        search = gtk_search_entry_new()!
        gtk_widget_set_hexpand(search, 1)
        gtk_search_entry_set_placeholder_text(search.opaque, "e.g. HD 650")
        status = Ui.label("", classes: ["caption"])
        cancelButton = Ui.button("Cancel", classes: ["flat"])
        retryButton = Ui.button("Retry", classes: ["flat"])
        let statusBox = Ui.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Ui.append(statusBox, spinner)
        Ui.append(statusBox, status)
        Ui.append(statusBox, retryButton)
        Ui.append(statusBox, cancelButton)
        Ui.setSpinning(spinner, false)
        Ui.show(cancelButton, false)
        Ui.show(retryButton, false)

        targetRow = adw_combo_row_new()!
        adw_preferences_row_set_title(targetRow.typed(AdwPreferencesRow.self), "Target curve")
        adw_combo_row_set_use_subtitle(targetRow.typed(AdwComboRow.self), 1)
        Ui.show(targetRow, false)

        let top = Ui.group("AutoEq",
                           "Find a measured headphone and fit AutoEq\u{2019}s correction to this device. "
                               + "Nothing is fetched until you search; the catalog then comes from autoeq.app.")
        Ui.add(top, search)
        Ui.add(top, statusBox)

        resultsGroup = Ui.group("Results")
        more = Ui.actionRow(title: "", subtitle: "")
        Ui.show(more, false)
        Ui.add(resultsGroup, more)
        Ui.show(resultsGroup, false)

        previewGroup = Ui.group("Correction")
        previewTitle = Ui.label("", classes: ["heading"])
        previewSubtitle = Ui.label("")
        provenance = Ui.label("")
        warnings = Ui.label("", classes: ["caption", "warning"])
        preference = Ui.label("")
        applyButton = Ui.button("Apply", classes: ["suggested-action"])
        saveButton = Ui.button("Save to library\u{2026}")
        reason = Ui.label("", classes: ["caption", "warning"])
        summary = Ui.label("", classes: ["caption"])
        let buttons = Ui.buttonRow([applyButton, saveButton])
        let card = Ui.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        for child in [previewTitle, previewSubtitle, curve.area, provenance, warnings, preference, buttons, reason, summary] {
            Ui.append(card, child)
        }
        Ui.add(previewGroup, targetRow)
        Ui.add(previewGroup, Ui.extras([card]))
        Ui.show(previewGroup, false)

        layout = SplitLayout(top: [top], left: [resultsGroup], right: [previewGroup])
        widget = layout.widget

        Signals.connect(search, signal: "search-changed") { [weak self] in
            onMain {
                guard let self, !self.updating else { return }
                self.model.setQuery(Ui.text(of: self.search))
            }
        }
        Signals.connect(search, signal: "activate") { [weak self] in onMain { self?.model.searchNow() } }
        Signals.connect(cancelButton, signal: "clicked") { [weak self] in onMain { self?.model.cancel() } }
        Signals.connect(retryButton, signal: "clicked") { [weak self] in onMain { self?.model.searchNow() } }
        Signals.connect(applyButton, signal: "clicked") { [weak self] in onMain { self?.model.apply() } }
        Signals.connect(saveButton, signal: "clicked") { [weak self] in onMain { self?.presentSave() } }
        Signals.onNotify(targetRow, property: "selected") { [weak self] _ in
            onMain {
                guard let self, !self.updating else { return }
                let index = Int(adw_combo_row_get_selected(self.targetRow.typed(AdwComboRow.self)))
                guard self.state.targets.indices.contains(index) else { return }
                self.model.setTarget(self.state.targets[index])
            }
        }
        model.addObserver { [weak self] state in onLive { self?.update(state) } }
    }

    private func update(_ next: AutoEqState) {
        let previous = state
        state = next
        updating = true
        defer { updating = false }

        Ui.setText(ofEditable: search, next.query)
        if shown != next.results { rebuild(next.results) }
        for (id, entry) in entries {
            gtk_widget_set_opacity(entry.marker, id == next.selected ? 1 : 0)
            Accessible.setSelected(entry.row, id == next.selected)
        }
        Ui.show(resultsGroup, !next.results.isEmpty)
        Ui.show(more, next.hiddenCount > 0)
        if next.hiddenCount > 0 {
            Ui.setRow(more, title: "+\(next.hiddenCount) more",
                      subtitle: "Keep typing to narrow it down.")
        }

        let loading = next.catalogue == .loading
        let busy = loading || next.fitting
        Ui.setSpinning(spinner, busy)
        var line = next.status
        if next.fitting { line = "Fitting a correction to your device\u{2026}" }
        if let error = next.error { line = error }
        Ui.setText(status, line)
        Ui.show(cancelButton, busy)
        var failed = false
        if case .failed = next.catalogue { failed = true }
        Ui.show(retryButton, failed)

        if shownTargets != next.targets {
            shownTargets = next.targets
            let names = gtk_string_list_new(nil)!
            for name in next.targets { gtk_string_list_append(names, name) }
            adw_combo_row_set_model(targetRow.typed(AdwComboRow.self), names)
        }
        Ui.show(targetRow, next.targets.count > 1 && next.selected != nil)
        if let target = next.target, let index = next.targets.firstIndex(of: target) {
            let current = Int(adw_combo_row_get_selected(targetRow.typed(AdwComboRow.self)))
            if current != index { adw_combo_row_set_selected(targetRow.typed(AdwComboRow.self), UInt32(index)) }
        }

        if previous.preview != next.preview { curve.update(next.preview) }
        Ui.show(previewGroup, next.preview != nil || next.fitting)
        if previous.selected != next.selected, next.selected != nil { layout.reveal(previewGroup) }
        Ui.setText(previewTitle, next.preview?.title)
        Ui.setText(previewSubtitle, next.preview.map { "Pre-gain " + EqFormat.decibels($0.preGain) })
        Ui.setText(provenance, next.provenance)
        Ui.setText(warnings, next.warnings.isEmpty ? nil : next.warnings.joined(separator: "\n"))
        Ui.setText(preference, next.preference.isEmpty ? nil : next.preference.joined(separator: "\n"))
        Ui.show(applyButton, next.preview != nil)
        Ui.show(saveButton, next.preview != nil)
        Ui.enable(applyButton, next.applyRefusal == nil)
        Ui.setText(reason, next.applyRefusal)
        Ui.setText(summary, next.summary)
    }

    private func rebuild(_ results: [AutoEqResult]) {
        for entry in entries.values { Ui.remove(resultsGroup, entry.row) }
        entries = [:]
        shown = results
        for result in results {
            let row = Ui.actionRow(title: result.title, subtitle: result.detail)
            gtk_list_box_row_set_activatable(row.typed(GtkListBoxRow.self), 1)
            let marker = Ui.marker()
            Ui.prefix(row, marker)
            let chevron = gtk_image_new_from_icon_name("go-next-symbolic")!
            Ui.suffix(row, chevron)
            Ui.add(resultsGroup, row)
            entries[result.id] = Entry(row: row, marker: marker)
            let id = result.id
            Signals.connect(row, signal: "activated") { [weak self] in onMain { self?.model.select(id) } }
        }
    }

    @discardableResult
    func presentSave() -> UnsafeMutableRawPointer? {
        guard let title = model.selectedTitle else { return nil }
        let dialog = Ui.ask(parent: parent(), title: "Save to the library",
                            message: "Keeps this correction as a preset on this computer. Nothing is sent to the 5K.",
                            text: title, placeholder: "Preset name", action: "Save",
                            maxLength: SavedPresetsModel.maxNameLength) { [weak self] name in
            onMain {
                if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { self?.model.saveToLibrary(name: name) }
                self?.dialog = nil
            }
        }
        self.dialog = dialog
        return dialog
    }
}
