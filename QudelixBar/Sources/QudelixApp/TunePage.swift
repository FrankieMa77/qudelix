import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@MainActor
final class BipolarBar {
    let area: Widget
    private var fraction = 0.0
    private var muted = false

    init() {
        area = Accessible.drawingArea(role: GTK_ACCESSIBLE_ROLE_IMG)
        gtk_widget_set_size_request(area, 110, 12)
        gtk_widget_set_valign(area, GTK_ALIGN_CENTER)
        Signals.setDrawFunc(area) { [weak self] cr, width, height in
            onMain { self?.draw(cr, Double(width), Double(height)) }
        }
    }

    func update(fraction: Double, muted: Bool) {
        self.fraction = fraction
        self.muted = muted
        gtk_widget_queue_draw(area)
    }

    private func draw(_ cr: OpaquePointer, _ w: Double, _ h: Double) {
        var accent = GdkRGBA(red: 0.21, green: 0.52, blue: 0.89, alpha: 1)
        _ = gtk_style_context_lookup_color(gtk_widget_get_style_context(area), "accent_bg_color", &accent)
        var foreground = GdkRGBA()
        gtk_widget_get_color(area, &foreground)
        let mid = w / 2
        let barHeight = 4.0
        let top = (h - barHeight) / 2
        cairo_set_source_rgba(cr, Double(foreground.red), Double(foreground.green), Double(foreground.blue), 0.15)
        cairo_rectangle(cr, 0, top, w, barHeight)
        cairo_fill(cr)
        cairo_set_source_rgba(cr, Double(foreground.red), Double(foreground.green), Double(foreground.blue), 0.5)
        cairo_rectangle(cr, mid - 0.5, 1, 1, h - 2)
        cairo_fill(cr)
        guard !muted else { return }
        let length = max(1, mid * abs(fraction))
        cairo_set_source_rgba(cr, Double(accent.red), Double(accent.green), Double(accent.blue), 1)
        cairo_rectangle(cr, fraction >= 0 ? mid : mid - length, top, length, barHeight)
        cairo_fill(cr)
    }
}

@MainActor
final class TunePage {
    let widget: Widget

    private struct ResultSlot {
        let row: Widget
        let bar: BipolarBar
        let value: Widget
    }

    private let tune: TuneModel
    private let methodRow: Widget
    private let notices = NoticeRows(count: 4)
    private let textGroup: Widget
    private var textSlots: [Widget] = []
    private let sessionGroup: Widget
    private let sessionRow: Widget
    private let sessionProgressText: Widget
    private let progressBar: Widget
    private let playingRow: Widget
    private let playingLetter: Widget
    private let switchButton: Widget
    private let heardButton: Widget
    private let choiceBox: Widget
    private let preferA: Widget
    private let preferB: Widget
    private let sameButton: Widget
    private let stopButton: Widget
    private let resultsGroup: Widget
    private var resultSlots: [ResultSlot] = []
    private let footGroup: Widget
    private var footSlots: [Widget] = []
    private let catchRow: Widget
    private let actionsBox: Widget
    private let startButton: Widget
    private let keepButton: Widget
    private let discardButton: Widget
    private var selected = TuneMethod.compare
    private var state = TuneState()
    private var updating = false
    private var lastPhase: TunePhase?
    private var lastMethod: TuneMethod?

    init(tune: TuneModel) {
        self.tune = tune

        let picker = Ui.group("Method")
        methodRow = adw_combo_row_new()!
        adw_preferences_row_set_title(methodRow.typed(AdwPreferencesRow.self), "Tuning method")
        let names = gtk_string_list_new(nil)!
        for method in TuneMethod.allCases { gtk_string_list_append(names, TunePresentation.title(method)) }
        adw_combo_row_set_model(methodRow.typed(AdwComboRow.self), names)
        adw_action_row_set_subtitle_lines(methodRow.typed(AdwActionRow.self), 0)
        Accessible.setLabel(methodRow, TunePresentation.pickerLabel)
        Ui.add(picker, methodRow)
        Signals.connect(methodRow, signal: "map") { [methodRow] in Ui.keepWholeLabels(in: methodRow) }

        textGroup = Ui.group(nil)
        for _ in 0..<3 {
            let row = Ui.actionRow(title: "", subtitle: "")
            adw_action_row_set_subtitle_lines(row.typed(AdwActionRow.self), 0)
            Ui.show(row, false)
            Ui.add(textGroup, row)
            textSlots.append(row)
        }

        sessionGroup = Ui.group(nil)
        sessionRow = Ui.actionRow(title: "", subtitle: "")
        adw_action_row_set_subtitle_lines(sessionRow.typed(AdwActionRow.self), 0)
        sessionProgressText = Ui.label("", classes: ["numeric", "dim-label"])
        gtk_label_set_wrap(sessionProgressText.opaque, 0)
        gtk_widget_set_hexpand(sessionProgressText, 0)
        gtk_widget_set_valign(sessionProgressText, GTK_ALIGN_CENTER)
        Ui.suffix(sessionRow, sessionProgressText)
        let progressHolder = adw_preferences_row_new()!
        gtk_list_box_row_set_activatable(progressHolder.typed(GtkListBoxRow.self), 0)
        progressBar = gtk_progress_bar_new()!
        gtk_widget_set_margin_top(progressBar, 10)
        gtk_widget_set_margin_bottom(progressBar, 10)
        gtk_widget_set_margin_start(progressBar, 12)
        gtk_widget_set_margin_end(progressBar, 12)
        gtk_widget_set_valign(progressBar, GTK_ALIGN_CENTER)
        Accessible.setLabel(progressBar, "Progress")
        gtk_list_box_row_set_child(progressHolder.typed(GtkListBoxRow.self), progressBar)
        playingRow = Ui.actionRow(title: "Playing", subtitle: "")
        playingLetter = Ui.label("A", classes: ["title-1", "numeric"])
        gtk_widget_set_hexpand(playingLetter, 0)
        gtk_widget_set_valign(playingLetter, GTK_ALIGN_CENTER)
        switchButton = Ui.button(TunePresentation.switchLabel, classes: [])
        gtk_widget_set_valign(switchButton, GTK_ALIGN_CENTER)
        Accessible.setLabel(switchButton, TunePresentation.switchAccessible)
        gtk_widget_set_tooltip_text(switchButton, "Space")
        Ui.suffix(playingRow, switchButton)
        Ui.suffix(playingRow, playingLetter)
        heardButton = Ui.button(TunePresentation.heardLabel, classes: ["suggested-action", "pill"])
        Accessible.setLabel(heardButton, TunePresentation.heardLabel)
        gtk_widget_set_tooltip_text(heardButton, "Space")
        gtk_widget_set_halign(heardButton, GTK_ALIGN_FILL)
        gtk_widget_set_margin_top(heardButton, 8)
        gtk_widget_set_margin_bottom(heardButton, 8)
        gtk_widget_set_margin_start(heardButton, 12)
        gtk_widget_set_margin_end(heardButton, 12)
        preferA = Ui.button(TunePresentation.preferALabel, classes: ["suggested-action"])
        preferB = Ui.button(TunePresentation.preferBLabel, classes: ["suggested-action"])
        sameButton = Ui.button(TunePresentation.sameLabel)
        Accessible.setLabel(preferA, "Prefer side A")
        Accessible.setLabel(preferB, "Prefer side B")
        Accessible.setLabel(sameButton, "A and B sound the same")
        gtk_widget_set_hexpand(preferA, 1)
        gtk_widget_set_hexpand(preferB, 1)
        gtk_widget_set_hexpand(sameButton, 1)
        let choices = Ui.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        let pair = Ui.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_set_homogeneous(pair.typed(GtkBox.self), 1)
        Ui.append(pair, preferA)
        Ui.append(pair, preferB)
        Ui.append(choices, pair)
        Ui.append(choices, sameButton)
        gtk_widget_set_margin_top(choices, 8)
        gtk_widget_set_margin_bottom(choices, 8)
        gtk_widget_set_margin_start(choices, 12)
        gtk_widget_set_margin_end(choices, 12)
        choiceBox = choices
        stopButton = Ui.button(TunePresentation.stopLabel, classes: ["destructive-action"])
        Accessible.setLabel(stopButton, "Stop the session")
        gtk_widget_set_halign(stopButton, GTK_ALIGN_END)
        gtk_widget_set_margin_top(stopButton, 4)
        gtk_widget_set_margin_bottom(stopButton, 8)
        gtk_widget_set_margin_end(stopButton, 12)
        for part in [sessionRow, progressHolder, playingRow, heardButton, choiceBox, stopButton] {
            Ui.add(sessionGroup, part)
        }
        Ui.show(sessionGroup, false)

        resultsGroup = Ui.group(nil)
        for _ in 0..<10 {
            let row = Ui.actionRow(title: "", subtitle: "")
            adw_action_row_set_subtitle_lines(row.typed(AdwActionRow.self), 0)
            let value = Ui.label("", classes: ["numeric"])
            gtk_widget_set_hexpand(value, 0)
            gtk_widget_set_valign(value, GTK_ALIGN_CENTER)
            gtk_label_set_wrap(value.opaque, 0)
            let bar = BipolarBar()
            Ui.suffix(row, bar.area)
            Ui.suffix(row, value)
            gtk_widget_set_visible(row, 0)
            Ui.add(resultsGroup, row)
            resultSlots.append(ResultSlot(row: row, bar: bar, value: value))
        }
        Ui.show(resultsGroup, false)

        footGroup = Ui.group(nil)
        for _ in 0..<3 {
            let row = Ui.actionRow(title: "", subtitle: "")
            adw_action_row_set_subtitle_lines(row.typed(AdwActionRow.self), 0)
            Ui.show(row, false)
            Ui.add(footGroup, row)
            footSlots.append(row)
        }
        catchRow = Ui.actionRow(title: "", subtitle: "")
        adw_action_row_set_subtitle_lines(catchRow.typed(AdwActionRow.self), 0)
        Ui.show(catchRow, false)
        Ui.add(footGroup, catchRow)
        Ui.show(footGroup, false)

        startButton = Ui.button(TunePresentation.startLabel, classes: ["suggested-action", "pill"])
        keepButton = Ui.button("Keep", classes: ["suggested-action"])
        discardButton = Ui.button("Discard")
        Accessible.setLabel(startButton, "Start the session")
        actionsBox = Ui.buttonRow([startButton, keepButton, discardButton])
        gtk_widget_set_margin_top(actionsBox, 4)
        gtk_widget_set_margin_bottom(actionsBox, 12)
        gtk_widget_set_margin_start(actionsBox, 12)

        let page = Ui.page([picker, notices.group, textGroup, sessionGroup, resultsGroup, footGroup])
        let actionsGroup = Ui.group(nil)
        Ui.add(actionsGroup, actionsBox)
        adw_preferences_page_add(page.typed(AdwPreferencesPage.self), actionsGroup.typed(AdwPreferencesGroup.self))
        widget = page

        connect()
        tune.addObserver { [weak self] next in onLive { self?.update(next) } }
    }

    private func connect() {
        let model = tune
        Signals.onNotify(methodRow, property: "selected") { [weak self] _ in
            onMain {
                guard let self, !self.updating else { return }
                let index = Int(adw_combo_row_get_selected(self.methodRow.typed(AdwComboRow.self)))
                guard TuneMethod.allCases.indices.contains(index) else { return }
                self.selected = TuneMethod.allCases[index]
                self.render()
            }
        }
        Signals.connect(startButton, signal: "clicked") { [weak self] in
            onMain { if let method = self?.selected { model.start(method) } }
        }
        Signals.connect(switchButton, signal: "clicked") { onMain { model.toggleSide() } }
        Signals.connect(heardButton, signal: "clicked") { onMain { model.reportHeard() } }
        Signals.connect(preferA, signal: "clicked") { onMain { model.choose(preferA: true) } }
        Signals.connect(preferB, signal: "clicked") { onMain { model.choose(preferA: false) } }
        Signals.connect(sameButton, signal: "clicked") { onMain { model.noDifference() } }
        Signals.connect(stopButton, signal: "clicked") { onMain { model.cancel() } }
        Signals.connect(keepButton, signal: "clicked") { onMain { model.keep() } }
        Signals.connect(discardButton, signal: "clicked") { [weak self] in
            onMain {
                guard let self else { return }
                if self.state.active == nil { return }
                model.discard()
            }
        }
        Signals.addKey(to: widget) { [weak self] keyval, modifiers in
            guard let self else { return false }
            let modified = modifiers & (GDK_CONTROL_MASK.rawValue | GDK_ALT_MASK.rawValue | GDK_SUPER_MASK.rawValue) != 0
            guard let action = TunePresentation.keyAction(keyval: keyval, modified: modified, state: self.state) else {
                return false
            }
            switch action {
            case .toggleSide: model.toggleSide()
            case .heard: model.reportHeard()
            }
            return true
        }
    }

    func select(_ method: TuneMethod) {
        selected = method
        syncPicker()
        render()
    }

    private func syncPicker() {
        guard let index = TuneMethod.allCases.firstIndex(of: selected) else { return }
        updating = true
        adw_combo_row_set_selected(methodRow.typed(AdwComboRow.self), UInt32(index))
        updating = false
    }

    private func update(_ next: TuneState) {
        state = next
        if let active = next.active, active != selected {
            selected = active
            syncPicker()
        }
        render()
    }

    private func setSlots(_ slots: [Widget], _ texts: [String]) {
        for (index, row) in slots.enumerated() {
            if texts.indices.contains(index) {
                Ui.setRow(row, title: "", subtitle: texts[index])
                Ui.show(row, true)
            } else {
                Ui.show(row, false)
            }
        }
    }

    private func render() {
        let screen = TunePresentation.screen(selected, state)
        let running = screen.phase == .running
        let finished = screen.phase == .finished
        let idle = screen.phase == .idle

        adw_action_row_set_subtitle(methodRow.typed(AdwActionRow.self), Ui.escaped(TunePresentation.summary(selected)))
        Ui.enable(methodRow, state.active == nil,
                  reason: state.active == nil ? nil : "A session is running. Stop it to change the method.")

        var items: [StageNotice] = []
        if idle, let blocker = screen.blocker { items.append(StageNotice(text: blocker, caution: true)) }
        for text in screen.cautions { items.append(StageNotice(text: text, caution: true)) }
        if let restore = screen.restoreLine { items.append(StageNotice(text: restore, caution: false)) }
        notices.show(items)

        Ui.show(textGroup, !running)
        adw_preferences_group_set_title(textGroup.typed(AdwPreferencesGroup.self), Ui.escaped(running ? "" : screen.headline))
        setSlots(textSlots, running ? [] : screen.paragraphs)

        Ui.show(sessionGroup, running)
        if running {
            Ui.setRow(sessionRow, title: screen.headline, subtitle: screen.detail)
            gtk_label_set_text(sessionProgressText.opaque, screen.progressText)
            gtk_progress_bar_set_fraction(progressBar.opaque, screen.progressFraction)
            Accessible.setLabel(progressBar, "Progress, \(screen.progressText)")
            gtk_label_set_text(playingLetter.opaque, screen.playingLabel)
            Accessible.setLabel(playingLetter, "Playing \(screen.playingLabel)")
            Ui.show(playingRow, !screen.isTones)
            Ui.show(choiceBox, !screen.isTones)
            Ui.show(heardButton, screen.isTones)
            if lastPhase != .running || lastMethod != selected {
                gtk_widget_grab_focus(screen.isTones ? heardButton : switchButton)
            }
        }

        let hasRows = finished && !screen.rows.isEmpty
        Ui.show(resultsGroup, hasRows)
        adw_preferences_group_set_title(resultsGroup.typed(AdwPreferencesGroup.self), Ui.escaped(screen.rowsTitle ?? ""))
        for (index, slot) in resultSlots.enumerated() {
            guard hasRows, screen.rows.indices.contains(index) else {
                gtk_widget_set_visible(slot.row, 0)
                continue
            }
            let row = screen.rows[index]
            Ui.setRow(slot.row, title: row.title, subtitle: row.detail)
            gtk_label_set_text(slot.value.opaque, row.value)
            slot.bar.update(fraction: row.fraction, muted: row.muted)
            Ui.show(slot.bar.area, row.hasBar)
            Accessible.setLabel(slot.bar.area, TunePresentation.accessibleRow(row))
            gtk_widget_set_sensitive(slot.row, screen.rowsDimmed ? 0 : 1)
            gtk_widget_set_opacity(slot.row, screen.rowsDimmed || row.muted ? 0.55 : 1)
            gtk_widget_set_visible(slot.row, 1)
        }

        setSlots(footSlots, screen.footnotes)
        let showFoot = !screen.footnotes.isEmpty || screen.catchSummary != nil
        if let summary = screen.catchSummary {
            Ui.setRow(catchRow, title: "", subtitle: summary)
            Ui.show(catchRow, true)
        } else {
            Ui.show(catchRow, false)
        }
        Ui.show(footGroup, showFoot)

        Ui.show(startButton, idle)
        Ui.enable(startButton, screen.startEnabled, reason: screen.blocker)
        Accessible.setLabel(startButton, "Start \(TunePresentation.title(selected))")
        Ui.show(keepButton, finished && screen.keepLabel != nil)
        if let keep = screen.keepLabel {
            gtk_button_set_label(keepButton.typed(GtkButton.self), keep)
            Accessible.setLabel(keepButton, keep)
        }
        Ui.show(discardButton, finished)
        gtk_button_set_label(discardButton.typed(GtkButton.self), screen.discardLabel)
        Accessible.setLabel(discardButton, screen.discardLabel == "Close" ? "Close the result" : "Discard the result")
        Ui.show(actionsBox, !running)
        lastPhase = screen.phase
        lastMethod = selected
    }
}
