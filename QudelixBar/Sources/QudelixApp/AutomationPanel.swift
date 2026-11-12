import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@MainActor
final class AutomationPanel {
    let widget: Widget

    private let automation: AutomationModel?
    private let suggestions: SuggestionsModel?
    private let fitCorrectionRow: Widget
    private let fitButton: Widget
    private let fittingLabel: Widget
    private var suggestionState = SuggestionsState()
    private var hiddenFitNote: String?
    private let available: Bool
    private let expander: Widget
    private let unavailable: Widget
    private let sourceRow: Widget
    private let showRow: Widget
    private let referenceText: Widget
    private let followRow: Widget
    private let keepButton: Widget
    private let resumeButton: Widget
    private let fitRow: Widget
    private let trimRow: Widget
    private let modeRow: Widget
    private let strengthRow: Widget
    private let strengthScale: Widget
    private let trimText: Widget
    private let balanceText: Widget
    private var updating = false
    private var wasForced = false
    private var state = AutomationState()

    init(automation: AutomationModel?, suggestions: SuggestionsModel? = nil, available: Bool) {
        self.automation = automation
        self.suggestions = suggestions
        self.available = available
        widget = Ui.group(nil)
        expander = adw_expander_row_new()!
        adw_preferences_row_set_title(expander.typed(AdwPreferencesRow.self), "Auto-fit and Auto-trim")
        adw_expander_row_set_subtitle(expander.typed(AdwExpanderRow.self), "Off")
        Accessible.setLabel(expander, "Auto-fit and Auto-trim")

        unavailable = Ui.actionRow(title: "", subtitle: AudioStack.unavailableMessage)
        adw_action_row_set_subtitle_lines(unavailable.typed(AdwActionRow.self), 0)

        sourceRow = adw_combo_row_new()!
        adw_preferences_row_set_title(sourceRow.typed(AdwPreferencesRow.self), "Reference")
        let sources = gtk_string_list_new(nil)!
        for source in AutomationSource.allCases { gtk_string_list_append(sources, source.title) }
        adw_combo_row_set_model(sourceRow.typed(AdwComboRow.self), sources)
        gtk_widget_set_tooltip_text(sourceRow, AutomationState.referenceHelp)

        showRow = adw_switch_row_new()!
        adw_preferences_row_set_title(showRow.typed(AdwPreferencesRow.self), "Show reference line")
        adw_action_row_set_subtitle(showRow.typed(AdwActionRow.self), AutomationState.showHelp)

        fitCorrectionRow = Ui.actionRow(title: "Headphone correction", subtitle: "")
        adw_action_row_set_subtitle_lines(fitCorrectionRow.typed(AdwActionRow.self), 0)
        fitButton = Ui.button(SuggestionsModel.fitLabel)
        fittingLabel = Ui.label(SuggestionsModel.fittingLabel, classes: ["dim-label", "caption"])
        for widget in [fitButton, fittingLabel] { gtk_widget_set_valign(widget, GTK_ALIGN_CENTER) }
        gtk_widget_set_hexpand(fittingLabel, 0)
        Ui.show(fittingLabel, false)
        Ui.suffix(fitCorrectionRow, fitButton)
        Ui.suffix(fitCorrectionRow, fittingLabel)

        referenceText = Ui.actionRow(title: "", subtitle: "")
        followRow = Ui.actionRow(title: "", subtitle: "")
        keepButton = Ui.button("Keep")
        resumeButton = Ui.button("Resume")
        for button in [keepButton, resumeButton] { gtk_widget_set_valign(button, GTK_ALIGN_CENTER) }
        gtk_widget_set_tooltip_text(keepButton, AutomationState.keepHelp)
        gtk_widget_set_tooltip_text(resumeButton, AutomationState.resumeHelp)
        Ui.suffix(followRow, keepButton)
        Ui.suffix(followRow, resumeButton)

        fitRow = adw_switch_row_new()!
        adw_preferences_row_set_title(fitRow.typed(AdwPreferencesRow.self), "Auto-fit")
        adw_action_row_set_subtitle(fitRow.typed(AdwActionRow.self), AutomationState.autoFitHelp)

        trimRow = adw_switch_row_new()!
        adw_preferences_row_set_title(trimRow.typed(AdwPreferencesRow.self), "Auto-trim")
        adw_action_row_set_subtitle(trimRow.typed(AdwActionRow.self), AutomationState.autoTrimHelp)

        modeRow = adw_combo_row_new()!
        adw_preferences_row_set_title(modeRow.typed(AdwPreferencesRow.self), "Auto-trim mode")
        let modes = gtk_string_list_new(nil)!
        for mode in AutomationTrimMode.allCases { gtk_string_list_append(modes, mode.label) }
        adw_combo_row_set_model(modeRow.typed(AdwComboRow.self), modes)

        strengthRow = adw_action_row_new()!
        adw_preferences_row_set_title(strengthRow.typed(AdwPreferencesRow.self), "Auto-trim strength")
        strengthScale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1, 0.01)!
        ScaleScrolling.install(on: strengthScale)
        gtk_scale_set_draw_value(strengthScale.typed(GtkScale.self), 0)
        gtk_widget_set_hexpand(strengthScale, 1)
        gtk_widget_set_valign(strengthScale, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(strengthScale, 120, -1)
        Accessible.setLabel(strengthScale, "Auto-trim strength")
        adw_action_row_add_suffix(strengthRow.typed(AdwActionRow.self), strengthScale)

        trimText = Ui.actionRow(title: "", subtitle: "")
        balanceText = Ui.actionRow(title: "", subtitle: "")
        for row in [referenceText, followRow, trimText, balanceText] {
            adw_action_row_set_subtitle_lines(row.typed(AdwActionRow.self), 0)
        }

        let rows: [Widget] = available
            ? [sourceRow, showRow, fitCorrectionRow, referenceText, followRow, fitRow, trimRow, modeRow, strengthRow, trimText, balanceText]
            : [unavailable, sourceRow, showRow, fitRow, trimRow, modeRow, strengthRow]
        for row in rows { adw_expander_row_add_row(expander.typed(AdwExpanderRow.self), row) }
        Ui.add(widget, expander)
        connect()
        if !available {
            for row in [sourceRow, showRow, fitRow, trimRow, modeRow, strengthRow] {
                gtk_widget_set_sensitive(row, 0)
            }
            adw_expander_row_set_subtitle(expander.typed(AdwExpanderRow.self), "Needs PipeWire")
        }
    }

    func open() {
        adw_expander_row_set_expanded(expander.typed(AdwExpanderRow.self), 1)
    }

    private func connect() {
        guard let automation else { return }
        Signals.onNotify(sourceRow, property: "selected") { [weak self] _ in
            onMain {
                guard let self, !self.updating else { return }
                let index = Int(adw_combo_row_get_selected(self.sourceRow.typed(AdwComboRow.self)))
                guard AutomationSource.allCases.indices.contains(index) else { return }
                automation.setReferenceSource(AutomationSource.allCases[index])
            }
        }
        Signals.onNotify(showRow, property: "active") { [weak self] _ in
            onMain {
                guard let self, !self.updating else { return }
                automation.setShowReference(adw_switch_row_get_active(self.showRow.opaque) != 0)
            }
        }
        Signals.onNotify(fitRow, property: "active") { [weak self] _ in
            onMain {
                guard let self, !self.updating else { return }
                automation.setAutoFit(adw_switch_row_get_active(self.fitRow.opaque) != 0)
            }
        }
        Signals.onNotify(trimRow, property: "active") { [weak self] _ in
            onMain {
                guard let self, !self.updating else { return }
                automation.setAutoTrim(on: adw_switch_row_get_active(self.trimRow.opaque) != 0)
            }
        }
        Signals.onNotify(modeRow, property: "selected") { [weak self] _ in
            onMain {
                guard let self, !self.updating else { return }
                let index = Int(adw_combo_row_get_selected(self.modeRow.typed(AdwComboRow.self)))
                guard AutomationTrimMode.allCases.indices.contains(index) else { return }
                automation.setAutoTrim(mode: AutomationTrimMode.allCases[index])
            }
        }
        Signals.onValueChanged(strengthScale) { [weak self] value in
            onMain {
                guard let self, !self.updating else { return }
                automation.setAutoTrim(strength: (value * 100).rounded() / 100)
            }
        }
        Signals.connect(fitButton, signal: "clicked") { [weak self] in onMain { self?.suggestions?.requestFit() } }
        suggestions?.addObserver { [weak self] next in onLive { self?.suggestionsChanged(next) } }
        Signals.connect(keepButton, signal: "clicked") { onMain { automation.keep() } }
        Signals.connect(resumeButton, signal: "clicked") { onMain { automation.resume() } }
    }

    private var visibleFitNote: String? {
        guard let note = suggestionState.fitNote, note != hiddenFitNote else { return nil }
        return note
    }

    private func suggestionsChanged(_ next: SuggestionsState) {
        suggestionState = next
        if next.fitNote == nil { hiddenFitNote = nil }
        refreshFit()
    }

    private func refreshFit() {
        guard available else { return }
        let fitting = suggestionState.fitting
        Ui.show(fitButton, !fitting)
        Ui.show(fittingLabel, fitting)
        gtk_button_set_label(fitButton.typed(GtkButton.self), SuggestionsModel.fitButtonLabel(hasReference: state.hasReference))
        Ui.enable(fitButton, suggestionState.canApply, reason: suggestionState.applyHelp)
        if suggestionState.canApply {
            gtk_widget_set_tooltip_text(fitButton, SuggestionsModel.fitButtonHelp(hasReference: state.hasReference))
        }
        adw_action_row_set_subtitle(fitCorrectionRow.typed(AdwActionRow.self), Ui.escaped(visibleFitNote ?? ""))
        Accessible.setLabel(fitButton, "\(SuggestionsModel.fitButtonLabel(hasReference: state.hasReference)) the headphone correction")
    }

    func update(_ next: AutomationState) {
        if next.hasReference != state.hasReference || next.source != state.source
            || next.referenceTexts != state.referenceTexts {
            hiddenFitNote = suggestionState.fitNote
        }
        state = next
        updating = true
        defer { updating = false }
        let expanded = expander.typed(AdwExpanderRow.self)
        if available {
            adw_expander_row_set_subtitle(expanded, Ui.escaped(next.summary))
            if next.isForced, !wasForced { adw_expander_row_set_expanded(expanded, 1) }
            wasForced = next.isForced
        }
        if let index = AutomationSource.allCases.firstIndex(of: next.source) {
            adw_combo_row_set_selected(sourceRow.typed(AdwComboRow.self), UInt32(index))
        }
        adw_switch_row_set_active(showRow.opaque, next.showReference ? 1 : 0)
        adw_switch_row_set_active(fitRow.opaque, next.autoFit ? 1 : 0)
        adw_switch_row_set_active(trimRow.opaque, next.autoTrimOn ? 1 : 0)
        if let index = AutomationTrimMode.allCases.firstIndex(of: next.trimMode) {
            adw_combo_row_set_selected(modeRow.typed(AdwComboRow.self), UInt32(index))
        }
        let scale = strengthScale.typed(GtkRange.self)
        if abs(gtk_range_get_value(scale) - next.trimStrength) > 0.001 { gtk_range_set_value(scale, next.trimStrength) }
        adw_action_row_set_subtitle(strengthRow.typed(AdwActionRow.self),
                                    "\(Int((next.trimStrength * 100).rounded())) percent")
        guard available else { return }
        refreshFit()
        gtk_widget_set_sensitive(modeRow, next.autoTrimOn ? 1 : 0)
        gtk_widget_set_sensitive(strengthRow, next.strengthEnabled ? 1 : 0)
        setLine(referenceText, next.referenceTexts.first)
        setLine(followRow, next.followNote)
        setLine(trimText, next.trimTexts.first)
        setLine(balanceText, next.balanceText.isEmpty ? nil : next.balanceText)
        gtk_widget_set_visible(keepButton, next.following ? 1 : 0)
        gtk_widget_set_visible(resumeButton, next.paused ? 1 : 0)
        gtk_widget_set_sensitive(keepButton, next.canKeep ? 1 : 0)
        Accessible.setLabel(keepButton, "Keep the followed gains")
        Accessible.setLabel(resumeButton, "Resume following")
    }

    private func setLine(_ row: Widget, _ text: String?) {
        let text = text ?? ""
        adw_action_row_set_subtitle(row.typed(AdwActionRow.self), Ui.escaped(text))
        gtk_widget_set_visible(row, text.isEmpty ? 0 : 1)
    }
}
