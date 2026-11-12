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
    private let modeButtons: [AutoEqMode: Widget]
    private let personalGroup: Widget
    private let bassRow: Widget
    private let bassScale: Widget
    private let tiltRow: Widget
    private let tiltScale: Widget
    private let hint: Widget
    private let resetButton: Widget
    private let cutoffRow: Widget
    private let cutoffCheck: Widget
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
        gtk_widget_set_tooltip_text(targetRow, AutoEqSearchModel.targetHelp)
        Ui.show(targetRow, false)

        let switcher = Ui.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_add_css_class(switcher, "linked")
        gtk_widget_set_halign(switcher, GTK_ALIGN_START)
        Accessible.setLabel(switcher, AutoEqSearchModel.sourceLabel)
        var modeToggles: [AutoEqMode: Widget] = [:]
        var first: Widget?
        for mode in AutoEqMode.allCases {
            let button = gtk_toggle_button_new_with_label(mode.label)!
            if let first { gtk_toggle_button_set_group(button.typed(GtkToggleButton.self), first.typed(GtkToggleButton.self)) } else { first = button }
            gtk_toggle_button_set_active(button.typed(GtkToggleButton.self), mode == .fit ? 1 : 0)
            gtk_widget_set_tooltip_text(button, mode.help)
            Ui.append(switcher, button)
            modeToggles[mode] = button
        }
        modeButtons = modeToggles

        bassRow = Ui.actionRow(title: "Bass")
        bassScale = Self.scale(range: AutoEqSearchModel.bassRange, step: AutoEqSearchModel.bassStep,
                               label: "Bass", help: AutoEqSearchModel.bassHelp)
        Ui.suffix(bassRow, bassScale)
        gtk_widget_set_tooltip_text(bassRow, AutoEqSearchModel.bassHelp)
        tiltRow = Ui.actionRow(title: "Tilt")
        tiltScale = Self.scale(range: AutoEqSearchModel.tiltRange, step: AutoEqSearchModel.tiltStep,
                               label: "Tilt", help: AutoEqSearchModel.tiltHelp)
        Ui.suffix(tiltRow, tiltScale)
        gtk_widget_set_tooltip_text(tiltRow, AutoEqSearchModel.tiltHelp)
        hint = Ui.label("")
        resetButton = Ui.button(AutoEqSearchModel.resetLabel, classes: ["flat"])
        gtk_widget_set_halign(resetButton, GTK_ALIGN_START)
        cutoffCheck = gtk_check_button_new()!
        gtk_widget_set_valign(cutoffCheck, GTK_ALIGN_CENTER)
        cutoffRow = Ui.actionRow(title: "")
        adw_action_row_set_title_lines(cutoffRow.typed(AdwActionRow.self), 0)
        Ui.prefix(cutoffRow, cutoffCheck)
        adw_action_row_set_activatable_widget(cutoffRow.typed(AdwActionRow.self), cutoffCheck)
        gtk_widget_set_tooltip_text(cutoffRow, AutoEqSearchModel.cutoffHelp)
        Ui.show(cutoffRow, false)

        personalGroup = Ui.group(nil)
        Ui.add(personalGroup, targetRow)
        Ui.add(personalGroup, bassRow)
        Ui.add(personalGroup, tiltRow)
        Ui.add(personalGroup, Ui.extras([hint, resetButton]))
        Ui.add(personalGroup, cutoffRow)

        let top = Ui.group("AutoEq",
                           "Find a measured headphone and fit AutoEq\u{2019}s correction to this device. "
                               + "Nothing is fetched until you search; the catalog then comes from autoeq.app.")
        Ui.add(top, switcher)
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
        Ui.add(previewGroup, Ui.extras([card]))
        Ui.show(previewGroup, false)

        layout = SplitLayout(top: [top, personalGroup], left: [resultsGroup], right: [previewGroup])
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
        for (mode, button) in modeButtons {
            Signals.onToggled(button) { [weak self] active in
                onMain {
                    guard active, let self, !self.updating else { return }
                    self.model.setMode(mode)
                }
            }
        }
        Signals.onValueChanged(bassScale) { [weak self] value in
            onMain {
                guard let self, !self.updating else { return }
                self.model.setBass(value)
            }
        }
        Signals.onValueChanged(tiltScale) { [weak self] value in
            onMain {
                guard let self, !self.updating else { return }
                self.model.setTilt(value)
            }
        }
        Signals.connect(resetButton, signal: "clicked") { [weak self] in onMain { self?.model.resetPersonalization() } }
        Signals.connect(cutoffCheck, signal: "toggled") { [weak self] in
            onMain {
                guard let self, !self.updating else { return }
                self.model.setLimitToCutoff(gtk_check_button_get_active(self.cutoffCheck.typed(GtkCheckButton.self)) != 0)
            }
        }
        model.addObserver { [weak self] state in onLive { self?.update(state) } }
    }

    private static func scale(range: ClosedRange<Double>, step: Double, label: String, help: String) -> Widget {
        let scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, range.lowerBound, range.upperBound, step)!
        ScaleScrolling.install(on: scale)
        gtk_scale_set_draw_value(scale.typed(GtkScale.self), 0)
        gtk_range_set_increments(scale.typed(GtkRange.self), step, step * 2)
        gtk_widget_set_hexpand(scale, 1)
        gtk_widget_set_valign(scale, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(scale, 120, -1)
        Accessible.setLabel(scale, label)
        Accessible.setDescription(scale, help)
        return scale
    }

    private func update(_ next: AutoEqState) {
        let previous = state
        state = next
        updating = true
        defer { updating = false }

        Ui.setText(ofEditable: search, next.query)
        updatePersonalization(next)
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
        Ui.show(targetRow, next.mode == .fit && next.targets.count > 1)
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

    private func updatePersonalization(_ next: AutoEqState) {
        for (mode, button) in modeButtons {
            let want: Int32 = mode == next.mode ? 1 : 0
            if gtk_toggle_button_get_active(button.typed(GtkToggleButton.self)) != want {
                gtk_toggle_button_set_active(button.typed(GtkToggleButton.self), want)
            }
        }
        let fit = next.mode == .fit
        Ui.show(bassRow, fit)
        Ui.show(tiltRow, fit)
        Ui.show(hint, fit)
        Ui.show(resetButton, fit && next.canReset)
        Ui.setText(hint, fit ? next.fitHint : nil)
        Ui.setRow(bassRow, title: "Bass", subtitle: next.bassText)
        Ui.setRow(tiltRow, title: "Tilt", subtitle: next.tiltText)
        if abs(gtk_range_get_value(bassScale.typed(GtkRange.self)) - next.bass) > 0.0001 {
            gtk_range_set_value(bassScale.typed(GtkRange.self), next.bass)
        }
        if abs(gtk_range_get_value(tiltScale.typed(GtkRange.self)) - next.tilt) > 0.0001 {
            gtk_range_set_value(tiltScale.typed(GtkRange.self), next.tilt)
        }
        Ui.show(cutoffRow, next.cutoffLabel != nil)
        if let label = next.cutoffLabel {
            adw_preferences_row_set_title(cutoffRow.typed(AdwPreferencesRow.self), Ui.escaped(label))
        }
        let checked: Int32 = next.limitToCutoff ? 1 : 0
        if gtk_check_button_get_active(cutoffCheck.typed(GtkCheckButton.self)) != checked {
            gtk_check_button_set_active(cutoffCheck.typed(GtkCheckButton.self), checked)
        }
        Accessible.setLabel(cutoffCheck, next.cutoffLabel ?? "Limit correction to the source cutoff")
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
