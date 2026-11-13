import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@MainActor
final class NoticeRows {
    struct Slot {
        let row: Widget
        let icon: Widget
    }

    let group: Widget
    private var slots: [Slot] = []

    var rows: [Widget] { slots.map(\.row) }

    init(count: Int, title: String? = nil) {
        group = Ui.group(title)
        for _ in 0..<count {
            let row = Ui.actionRow(title: "", subtitle: "")
            adw_action_row_set_subtitle_lines(row.typed(AdwActionRow.self), 0)
            let icon = gtk_image_new_from_icon_name("dialog-warning-symbolic")!
            Ui.prefix(row, icon)
            gtk_widget_set_visible(row, 0)
            Ui.add(group, row)
            slots.append(Slot(row: row, icon: icon))
        }
        gtk_widget_set_visible(group, 0)
    }

    func show(_ notices: [StageNotice]) {
        for (index, slot) in slots.enumerated() {
            guard notices.indices.contains(index) else {
                gtk_widget_set_visible(slot.row, 0)
                continue
            }
            let notice = notices[index]
            Ui.setRow(slot.row, title: "", subtitle: notice.text)
            gtk_image_set_from_icon_name(slot.icon.opaque,
                                         notice.caution ? "dialog-warning-symbolic" : "dialog-information-symbolic")
            if notice.caution {
                gtk_widget_add_css_class(slot.icon, "warning")
            } else {
                gtk_widget_remove_css_class(slot.icon, "warning")
            }
            gtk_widget_set_visible(slot.row, 1)
        }
        gtk_widget_set_visible(group, notices.isEmpty ? 0 : 1)
    }
}

@MainActor
final class StagePage {
    let widget: Widget

    private let stage: StageModel
    private let notices = NoticeRows(count: 4)
    private let enableRow: Widget
    private let presetRow: Widget
    private let presetButtons: [(choice: StagePresetChoice, button: Widget)]
    private let routingRow: Widget
    private let outputRow: Widget
    private var sliders: [StageControl: SliderRow] = [:]
    private let bandsExpander: Widget
    private let bandsHolder: Widget
    private let geometryHolder: Widget
    private let geometryExpander: Widget
    private let limiterRow: Widget
    private let loudnessRow: Widget
    private let loudnessAmount: Widget
    private let bassGuardRow: Widget
    private let bassGuardAmount: Widget
    private let impulseExpander: Widget
    private let chooseButton: Widget
    private let removeButton: Widget
    private let impulseButtons: Widget
    private let impulseDetail: Widget
    private let impulseNote: Widget
    private let spinner: Widget
    private let shapeGroup: Widget
    private let balanceGroup: Widget
    private let dynamicsGroup: Widget
    private let impulseGroup: Widget
    private var updating = false
    private var state = StageModelState()
    private var levelState = LevelModelState()

    init(stage: StageModel) {
        self.stage = stage

        let soundstage = Ui.group("Soundstage")
        enableRow = adw_switch_row_new()!
        adw_preferences_row_set_title(enableRow.typed(AdwPreferencesRow.self), "Soundstage")
        adw_action_row_set_subtitle_lines(enableRow.typed(AdwActionRow.self), 0)
        presetRow = Ui.actionRow(title: "Preset", subtitle: "")
        let buttons = Ui.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_add_css_class(buttons, "linked")
        gtk_widget_set_valign(buttons, GTK_ALIGN_CENTER)
        var built: [(StagePresetChoice, Widget)] = []
        for choice in StagePresetChoice.allCases {
            let button = Ui.button(choice.title)
            Accessible.setLabel(button, "\(choice.title) preset")
            Ui.append(buttons, button)
            built.append((choice, button))
        }
        presetButtons = built
        Ui.suffix(presetRow, buttons)
        Ui.add(soundstage, enableRow)
        Ui.add(soundstage, presetRow)

        let routing = Ui.group("How it reaches your output")
        routingRow = Ui.actionRow(title: "", subtitle: "")
        outputRow = Ui.actionRow(title: "", subtitle: "")
        for row in [routingRow, outputRow] {
            adw_action_row_set_subtitle_lines(row.typed(AdwActionRow.self), 0)
            Ui.add(routing, row)
        }

        shapeGroup = Ui.group("Shape")
        bandsExpander = adw_expander_row_new()!
        adw_preferences_row_set_title(bandsExpander.typed(AdwPreferencesRow.self), "Crossfeed by band")
        geometryExpander = adw_expander_row_new()!
        adw_preferences_row_set_title(geometryExpander.typed(AdwPreferencesRow.self), "Stage geometry")
        adw_expander_row_set_subtitle(geometryExpander.typed(AdwExpanderRow.self), "Distance, span, center and size")
        bandsHolder = Ui.group(nil)
        geometryHolder = Ui.group(nil)
        Ui.add(bandsHolder, bandsExpander)
        Ui.add(geometryHolder, geometryExpander)
        balanceGroup = Ui.group("Balance", StagePresentation.balanceFootnote)

        dynamicsGroup = Ui.group("Protection and compensation")
        limiterRow = adw_switch_row_new()!
        adw_preferences_row_set_title(limiterRow.typed(AdwPreferencesRow.self), "True-peak limiter")
        loudnessRow = adw_switch_row_new()!
        adw_preferences_row_set_title(loudnessRow.typed(AdwPreferencesRow.self), "Loudness")
        bassGuardRow = adw_switch_row_new()!
        adw_preferences_row_set_title(bassGuardRow.typed(AdwPreferencesRow.self), "Dynamic bass")
        loudnessAmount = Ui.label("", classes: ["dim-label", "numeric"])
        bassGuardAmount = Ui.label("", classes: ["dim-label", "numeric"])
        for (row, label) in [(loudnessRow, loudnessAmount), (bassGuardRow, bassGuardAmount)] {
            gtk_label_set_wrap(label.opaque, 0)
            gtk_widget_set_hexpand(label, 0)
            gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
            adw_action_row_add_suffix(row.typed(AdwActionRow.self), label)
        }
        for row in [limiterRow, loudnessRow, bassGuardRow] {
            adw_action_row_set_subtitle_lines(row.typed(AdwActionRow.self), 0)
        }

        impulseGroup = Ui.group("Impulse response")
        impulseExpander = adw_expander_row_new()!
        adw_preferences_row_set_title(impulseExpander.typed(AdwPreferencesRow.self), "Impulse response")
        chooseButton = Ui.button("Choose\u{2026}")
        removeButton = Ui.button("Remove", classes: ["destructive-action"])
        spinner = Ui.spinner()
        Ui.setSpinning(spinner, false)
        impulseButtons = Ui.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_margin_top(impulseButtons, 8)
        gtk_widget_set_margin_bottom(impulseButtons, 8)
        gtk_widget_set_margin_start(impulseButtons, 12)
        for part in [chooseButton, removeButton, spinner] { Ui.append(impulseButtons, part) }
        impulseDetail = Ui.actionRow(title: "", subtitle: "")
        impulseNote = Ui.actionRow(title: "", subtitle: "")
        for row in [impulseDetail, impulseNote] {
            adw_action_row_set_subtitle_lines(row.typed(AdwActionRow.self), 0)
        }

        let page = Ui.page([notices.group, soundstage, routing, shapeGroup, bandsHolder,
                            geometryHolder, balanceGroup, dynamicsGroup, impulseGroup])
        widget = page
        buildSliders()
        connect()

        stage.level.addObserver { [weak self] next in onLive { self?.levelChanged(next) } }
        stage.addObserver { [weak self] next in onLive { self?.update(next) } }
    }

    private func slider(_ control: StageControl) -> SliderRow {
        let stage = self.stage
        let row = SliderRow(control: control, onChange: { control, value in
            if control == .impulseMix {
                stage.setImpulseMix(control.quantized(value) / 100, editedFor: stage.outputKey)
            } else {
                stage.mutate(editedFor: stage.outputKey) { control.apply(value, to: &$0) }
            }
        }, onReset: { control in
            stage.mutate(editedFor: stage.outputKey) { control.apply(control.neutral, to: &$0) }
        })
        sliders[control] = row
        return row
    }

    private func buildSliders() {
        for control in StageControl.controls(in: .shape) { Ui.add(shapeGroup, slider(control).widget) }
        for control in StageControl.controls(in: .crossBands) {
            adw_expander_row_add_row(bandsExpander.typed(AdwExpanderRow.self), slider(control).widget)
        }
        let bandsNote = Ui.actionRow(title: "", subtitle: StagePresentation.crossBandsFootnote)
        adw_action_row_set_subtitle_lines(bandsNote.typed(AdwActionRow.self), 0)
        adw_expander_row_add_row(bandsExpander.typed(AdwExpanderRow.self), bandsNote)
        for control in StageControl.controls(in: .geometry) {
            adw_expander_row_add_row(geometryExpander.typed(AdwExpanderRow.self), slider(control).widget)
        }
        for control in StageControl.controls(in: .balance) { Ui.add(balanceGroup, slider(control).widget) }

        Ui.add(dynamicsGroup, limiterRow)
        Ui.add(dynamicsGroup, loudnessRow)
        Ui.add(dynamicsGroup, slider(.loudnessStrength).widget)
        Ui.add(dynamicsGroup, bassGuardRow)
        Ui.add(dynamicsGroup, slider(.bassGuardStrength).widget)

        let expander = impulseExpander.typed(AdwExpanderRow.self)
        adw_expander_row_add_row(expander, impulseButtons)
        adw_expander_row_add_row(expander, impulseDetail)
        adw_expander_row_add_row(expander, slider(.impulseMix).widget)
        adw_expander_row_add_row(expander, impulseNote)
        Ui.add(impulseGroup, impulseExpander)
    }

    private func connect() {
        let stage = self.stage
        Signals.onNotify(enableRow, property: "active") { [weak self] _ in
            onMain {
                guard let self, !self.updating else { return }
                var next = stage.settings
                let on = adw_switch_row_get_active(self.enableRow.opaque) != 0
                next.enabled = on
                if on, !next.doesAnything { next = .music }
                stage.setStage(next, editedFor: stage.outputKey)
            }
        }
        for (choice, button) in presetButtons {
            Signals.connect(button, signal: "clicked") {
                onMain { stage.applyPreset(choice.settings, editedFor: stage.outputKey) }
            }
        }
        connectToggle(limiterRow) { $0.limiter = $1 }
        connectToggle(loudnessRow) { $0.loudness = $1 }
        connectToggle(bassGuardRow) { $0.bassGuard = $1 }
        Signals.connect(chooseButton, signal: "clicked") { [weak self] in
            onMain {
                guard let self else { return }
                let parent = Ui.parentWindow(of: self.widget).map { UnsafeMutableRawPointer($0) }
                FileDialog.openText(parent: parent, title: StagePresentation.impulseDialogTitle,
                                    specs: WavFileFilters.specs) { path in
                    onMain {
                        guard let path else { return }
                        stage.installImpulse(URL(fileURLWithPath: path), editedFor: stage.outputKey)
                    }
                }
            }
        }
        Signals.connect(removeButton, signal: "clicked") {
            onMain { stage.removeImpulse(editedFor: stage.outputKey) }
        }
    }

    private func connectToggle(_ row: Widget, _ change: @escaping (inout StageSettings, Bool) -> Void) {
        let stage = self.stage
        Signals.onNotify(row, property: "active") { [weak self] _ in
            onMain {
                guard let self, !self.updating else { return }
                var next = stage.settings
                change(&next, adw_switch_row_get_active(row.opaque) != 0)
                stage.setStage(next, editedFor: stage.outputKey)
            }
        }
    }

    private func levelChanged(_ next: LevelModelState) {
        levelState = next
        refreshNotes()
    }

    private func update(_ next: StageModelState) {
        state = next
        updating = true
        defer { updating = false }
        let settings = next.settings
        adw_switch_row_set_active(enableRow.opaque, settings.enabled ? 1 : 0)
        Ui.setRow(enableRow, title: "Soundstage", subtitle: StagePresentation.outputLabel(next))
        var custom = ""
        if next.isCustomPreset { custom = "Custom" }
        Ui.setRow(presetRow, title: "Preset", subtitle: custom)
        for (choice, button) in presetButtons {
            if choice.isSelected(settings) {
                gtk_widget_add_css_class(button, "suggested-action")
            } else {
                gtk_widget_remove_css_class(button, "suggested-action")
            }
        }
        notices.show(StagePresentation.notices(next))
        for row in sliders.values { row.update(settings) }
        gtk_widget_set_visible(bandsHolder, settings.crossfeed > 0 ? 1 : 0)
        adw_expander_row_set_subtitle(bandsExpander.typed(AdwExpanderRow.self),
                                      Ui.escaped(StagePresentation.bandTrimSummary(settings) ?? "Low, mid and high"))
        adw_switch_row_set_active(limiterRow.opaque, settings.limiterValue ? 1 : 0)
        adw_switch_row_set_active(loudnessRow.opaque, settings.loudnessValue ? 1 : 0)
        adw_switch_row_set_active(bassGuardRow.opaque, settings.bassGuardValue ? 1 : 0)
        gtk_widget_set_visible(sliders[.loudnessStrength]!.widget, settings.loudnessValue ? 1 : 0)
        gtk_widget_set_visible(sliders[.bassGuardStrength]!.widget, settings.bassGuardValue ? 1 : 0)
        gtk_widget_set_visible(sliders[.impulseMix]!.widget, settings.hasImpulse ? 1 : 0)
        let loudnessShown = settings.enabled && settings.loudnessValue
        Ui.setText(loudnessAmount, loudnessShown ? StagePresentation.loudnessAmount(next) : nil)
        let guardShown = settings.enabled && settings.bassGuardValue && !next.bassGuardInert
        Ui.setText(bassGuardAmount, guardShown ? StagePresentation.bassGuardAmount(next) : nil)
        gtk_widget_set_tooltip_text(bassGuardAmount, guardShown ? StagePresentation.bassGuardCeilingHelp(next) : nil)

        Ui.setRow(routingRow, title: "Where the sound goes", subtitle: StagePresentation.routingExplanation(next))
        Ui.setRow(outputRow, title: "Per-output settings", subtitle: StagePresentation.perOutputNote(next))
        for group in [shapeGroup, balanceGroup, dynamicsGroup, impulseGroup, bandsHolder, geometryHolder] {
            gtk_widget_set_opacity(group, settings.enabled ? 1 : 0.55)
        }

        adw_preferences_row_set_title(impulseExpander.typed(AdwPreferencesRow.self), "Impulse response")
        adw_expander_row_set_subtitle(impulseExpander.typed(AdwExpanderRow.self),
                                      Ui.escaped(StagePresentation.impulseTitle(next)))
        gtk_button_set_label(chooseButton.typed(GtkButton.self), settings.hasImpulse ? "Replace\u{2026}" : "Choose\u{2026}")
        Ui.enable(chooseButton, settings.enabled && !next.impulseBusy)
        Ui.show(removeButton, settings.hasImpulse)
        Ui.enable(removeButton, settings.enabled)
        Ui.setSpinning(spinner, next.impulseBusy)
        refreshNotes()
    }

    private func refreshNotes() {
        let detail = StagePresentation.impulseDetail(state)
        Ui.setRow(impulseDetail, title: "", subtitle: detail ?? "")
        gtk_widget_set_visible(impulseDetail, detail == nil ? 0 : 1)
        Ui.setRow(impulseNote, title: "", subtitle: StagePresentation.impulseNote(state))
        Ui.setRow(limiterRow, title: "True-peak limiter", subtitle: StagePresentation.limiterNote(state))
        Ui.setRow(loudnessRow, title: "Loudness",
                  subtitle: StagePresentation.loudnessNote(state, level: levelState))
        Ui.setRow(bassGuardRow, title: "Dynamic bass", subtitle: StagePresentation.bassGuardNote(state))
    }
}
