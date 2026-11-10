import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@MainActor
final class LevelPage {
    let widget: Widget

    private struct MeterSlot {
        let row: Widget
        let value: Widget
    }

    private struct HistorySlot {
        let row: Widget
        let bar: Widget
        let duration: Widget
    }

    private let stage: StageModel
    private let level: LevelModel
    private let automation: AutomationModel?
    private let notices = NoticeRows(count: 2)
    private let trackRow: Widget
    private let outputValue: Widget
    private let outputBar: Widget
    private let outputRow: Widget
    private var meterSlots: [MeterSlot] = []
    private let earValue: Widget
    private let earRow: Widget
    private let earDisclaimer: Widget
    private let calibrationRow: Widget
    private let calibrationSpin: Widget
    private let calibrationReset: Widget
    private let detectRow: Widget
    private let verdictRow: Widget
    private let verdictValue: Widget
    private let balanceRow: Widget
    private let autoMatchRow: Widget
    private let historyGroup: Widget
    private let historyHeadline: Widget
    private let deleteButton: Widget
    private let todayRow: Widget
    private let previousExpander: Widget
    private var historySlots: [HistorySlot] = []
    private var updating = false
    private var stageState = StageModelState()
    private var levelState = LevelModelState()
    private var baselineText = ""
    private(set) var dialog: UnsafeMutableRawPointer?

    init(stage: StageModel, automation: AutomationModel?) {
        self.stage = stage
        level = stage.level
        self.automation = automation

        let tracking = Ui.group("Listening")
        trackRow = adw_switch_row_new()!
        adw_preferences_row_set_title(trackRow.typed(AdwPreferencesRow.self), "Track listening levels")
        adw_action_row_set_subtitle_lines(trackRow.typed(AdwActionRow.self), 0)
        Ui.add(tracking, trackRow)

        let meters = Ui.group("Output")
        outputRow = adw_preferences_row_new()!
        gtk_list_box_row_set_activatable(outputRow.typed(GtkListBoxRow.self), 0)
        let column = Ui.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_widget_set_margin_top(column, 10)
        gtk_widget_set_margin_bottom(column, 10)
        gtk_widget_set_margin_start(column, 12)
        gtk_widget_set_margin_end(column, 12)
        let top = Ui.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let title = gtk_label_new("Output level")!
        gtk_label_set_xalign(title.opaque, 0)
        gtk_widget_set_hexpand(title, 1)
        outputValue = gtk_label_new("")!
        gtk_widget_add_css_class(outputValue, "dim-label")
        gtk_widget_add_css_class(outputValue, "numeric")
        Ui.append(top, title)
        Ui.append(top, outputValue)
        outputBar = gtk_level_bar_new_for_interval(0, 1)!
        gtk_level_bar_remove_offset_value(outputBar.opaque, "low")
        gtk_level_bar_remove_offset_value(outputBar.opaque, "high")
        gtk_level_bar_remove_offset_value(outputBar.opaque, "full")
        gtk_level_bar_add_offset_value(outputBar.opaque, "low", LevelPresentation.meterFraction(LevelPresentation.loudMarkerDb) - 0.0001)
        gtk_level_bar_add_offset_value(outputBar.opaque, "high", 0.93)
        gtk_level_bar_add_offset_value(outputBar.opaque, "full", 1)
        Accessible.setLabel(outputBar, "Output level")
        Ui.append(column, top)
        Ui.append(column, outputBar)
        gtk_list_box_row_set_child(outputRow.typed(GtkListBoxRow.self), column)
        Ui.add(meters, outputRow)
        for _ in 0..<3 {
            let row = Ui.actionRow(title: "", subtitle: "")
            let value = Ui.label("", classes: ["numeric"])
            gtk_label_set_wrap(value.opaque, 0)
            gtk_widget_set_hexpand(value, 0)
            gtk_widget_set_valign(value, GTK_ALIGN_CENTER)
            Ui.suffix(row, value)
            gtk_widget_set_visible(row, 0)
            Ui.add(meters, row)
            meterSlots.append(MeterSlot(row: row, value: value))
        }

        let ear = Ui.group("Estimated level at ear")
        earRow = Ui.actionRow(title: "Estimated level at ear", subtitle: "")
        earValue = Ui.label("", classes: ["numeric"])
        gtk_widget_set_hexpand(earValue, 0)
        gtk_widget_set_valign(earValue, GTK_ALIGN_CENTER)
        Ui.suffix(earRow, earValue)
        earDisclaimer = Ui.actionRow(title: "", subtitle: "")
        calibrationRow = Ui.actionRow(title: "Reads loud or quiet? Nudge it", subtitle: LevelPresentation.calibrationHelp)
        gtk_widget_set_size_request(calibrationRow, 1, -1)
        let span = (EarLevel.calibrationRange.upperBound - EarLevel.calibrationRange.lowerBound) / 2
        calibrationSpin = gtk_spin_button_new_with_range(-span, span, 1)!
        gtk_widget_set_valign(calibrationSpin, GTK_ALIGN_CENTER)
        Accessible.setLabel(calibrationSpin, "Ear level calibration")
        calibrationReset = gtk_button_new_from_icon_name("edit-undo-symbolic")!
        gtk_widget_add_css_class(calibrationReset, "flat")
        gtk_widget_set_valign(calibrationReset, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(calibrationReset, "Back to the typical-headphone assumption for this output.")
        Accessible.setLabel(calibrationReset, "Reset ear level calibration")
        Ui.suffix(calibrationRow, calibrationReset)
        Ui.suffix(calibrationRow, calibrationSpin)
        for row in [earRow, earDisclaimer, calibrationRow] {
            adw_action_row_set_subtitle_lines(row.typed(AdwActionRow.self), 0)
            Ui.add(ear, row)
        }

        let quality = Ui.group("Stream quality", LevelPresentation.qualityHelp)
        detectRow = adw_switch_row_new()!
        adw_preferences_row_set_title(detectRow.typed(AdwPreferencesRow.self), "Detect stream quality")
        verdictRow = Ui.actionRow(title: "Verdict", subtitle: "")
        verdictValue = Ui.label("", classes: [])
        gtk_widget_set_hexpand(verdictValue, 0)
        gtk_widget_set_valign(verdictValue, GTK_ALIGN_CENTER)
        gtk_label_set_xalign(verdictValue.opaque, 1)
        gtk_label_set_wrap(verdictValue.opaque, 1)
        gtk_label_set_justify(verdictValue.opaque, GTK_JUSTIFY_RIGHT)
        gtk_label_set_max_width_chars(verdictValue.opaque, 28)
        Ui.suffix(verdictRow, verdictValue)
        balanceRow = Ui.actionRow(title: "Balance", subtitle: "")
        gtk_widget_set_tooltip_text(balanceRow, LevelPresentation.balanceHelp)
        autoMatchRow = adw_switch_row_new()!
        adw_preferences_row_set_title(autoMatchRow.typed(AdwPreferencesRow.self), "Auto-match USB rate")
        gtk_widget_set_tooltip_text(autoMatchRow, LevelPresentation.autoMatchHelp)
        for row in [detectRow, verdictRow, balanceRow, autoMatchRow] {
            adw_action_row_set_subtitle_lines(row.typed(AdwActionRow.self), 0)
            Ui.add(quality, row)
        }

        historyGroup = Ui.group("Listening history", LevelPresentation.historyFootnote)
        historyHeadline = Ui.actionRow(title: "", subtitle: "")
        deleteButton = Ui.button("Delete", classes: ["destructive-action"])
        gtk_widget_set_valign(deleteButton, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(deleteButton, "Deletes every day recorded so far, from disk too.")
        adw_preferences_group_set_header_suffix(historyGroup.typed(AdwPreferencesGroup.self), deleteButton)
        todayRow = Ui.actionRow(title: "Today", subtitle: "")
        previousExpander = adw_expander_row_new()!
        adw_preferences_row_set_title(previousExpander.typed(AdwPreferencesRow.self), "Previous days")
        for row in [historyHeadline, todayRow] { adw_action_row_set_subtitle_lines(row.typed(AdwActionRow.self), 0) }
        Ui.add(historyGroup, historyHeadline)
        Ui.add(historyGroup, todayRow)
        Ui.add(historyGroup, previousExpander)
        for _ in 0..<7 {
            let row = Ui.actionRow(title: "", subtitle: "")
            let bar = gtk_level_bar_new_for_interval(0, 1)!
            gtk_widget_set_size_request(bar, 90, -1)
            gtk_widget_set_valign(bar, GTK_ALIGN_CENTER)
            let duration = Ui.label("", classes: ["numeric"])
            gtk_widget_set_hexpand(duration, 0)
            gtk_widget_set_valign(duration, GTK_ALIGN_CENTER)
            gtk_label_set_width_chars(duration.opaque, 7)
            gtk_label_set_xalign(duration.opaque, 1)
            Ui.suffix(row, bar)
            Ui.suffix(row, duration)
            adw_expander_row_add_row(previousExpander.typed(AdwExpanderRow.self), row)
            historySlots.append(HistorySlot(row: row, bar: bar, duration: duration))
        }

        widget = Ui.page([notices.group, tracking, meters, ear, quality, historyGroup])
        connect()
        automation?.addObserver { [weak self] next in onLive { self?.automationChanged(next) } }
        stage.addObserver { [weak self] next in onLive { self?.stageChanged(next) } }
        level.addObserver { [weak self] next in onLive { self?.levelChanged(next) } }
    }

    private func connect() {
        let level = self.level
        let stage = self.stage
        Signals.onNotify(trackRow, property: "active") { [weak self] _ in
            onMain {
                guard let self, !self.updating else { return }
                level.setLevelTracking(adw_switch_row_get_active(self.trackRow.opaque) != 0)
            }
        }
        Signals.onNotify(detectRow, property: "active") { [weak self] _ in
            onMain {
                guard let self, !self.updating else { return }
                level.setDetectQuality(adw_switch_row_get_active(self.detectRow.opaque) != 0)
            }
        }
        Signals.onNotify(autoMatchRow, property: "active") { [weak self] _ in
            onMain {
                guard let self, !self.updating else { return }
                level.setAutoRate(adw_switch_row_get_active(self.autoMatchRow.opaque) != 0)
            }
        }
        Signals.onValueChanged(calibrationSpin) { [weak self] value in
            onMain {
                guard let self, !self.updating else { return }
                stage.setEarCalibration(EarLevel.defaultCalibrationDb + value.rounded(), editedFor: stage.outputKey)
            }
        }
        Signals.connect(calibrationReset, signal: "clicked") {
            onMain { stage.setEarCalibration(EarLevel.defaultCalibrationDb, editedFor: stage.outputKey) }
        }
        Signals.connect(deleteButton, signal: "clicked") { [weak self] in onMain { self?.presentDelete() } }
    }

    @discardableResult
    func presentDelete() -> UnsafeMutableRawPointer? {
        guard dialog == nil else { return dialog }
        var opened: UnsafeMutableRawPointer?
        let created = Ui.confirm(parent: Ui.parentWindow(of: widget), title: LevelPresentation.historyDeleteTitle,
                                 message: LevelPresentation.historyDeleteMessage, action: "Delete",
                                 destructive: true) { [weak self] confirmed in
            onMain {
                if confirmed { self?.level.clearExposureHistory() }
                if self?.dialog == opened { self?.dialog = nil }
            }
        }
        opened = created
        dialog = created
        return created
    }

    private func automationChanged(_ next: AutomationState) {
        baselineText = next.baselineText
        refresh()
    }

    private func stageChanged(_ next: StageModelState) {
        stageState = next
        var shown: [StageNotice] = []
        if let notice = next.settingsNotice { shown.append(StageNotice(text: notice, caution: true)) }
        if let failure = LevelPresentation.failureNotice(next) { shown.append(StageNotice(text: failure, caution: true)) }
        notices.show(shown)
        refresh()
    }

    private func levelChanged(_ next: LevelModelState) {
        levelState = next
        refresh()
    }

    private func refresh() {
        updating = true
        defer { updating = false }
        let level = levelState
        let stage = stageState
        let now = Date()

        adw_switch_row_set_active(trackRow.opaque, level.levelTracking ? 1 : 0)
        let note = LevelPresentation.trackingNote(stage: stage, level: level)
        Ui.setRow(trackRow, title: "Track listening levels", subtitle: note ?? "")
        gtk_widget_set_visible(trackRow, 1)

        gtk_label_set_text(outputValue.opaque, LevelPresentation.outputLevelText(stage: stage, level: level))
        let fraction = LevelPresentation.meterFraction(stage: stage, level: level) ?? 0
        gtk_level_bar_set_value(outputBar.opaque, fraction)
        Accessible.setDescription(outputBar, LevelPresentation.outputLevelText(stage: stage, level: level))

        let rows = LevelPresentation.meterRows(stage: stage)
        for (index, slot) in meterSlots.enumerated() {
            guard rows.indices.contains(index) else {
                gtk_widget_set_visible(slot.row, 0)
                continue
            }
            let row = rows[index]
            Ui.setRow(slot.row, title: row.label, subtitle: row.note)
            gtk_label_set_text(slot.value.opaque, row.value)
            gtk_widget_set_tooltip_text(slot.row, row.help)
            if row.lit {
                gtk_widget_remove_css_class(slot.value, "dim-label")
                if row.caution { gtk_widget_add_css_class(slot.value, "warning") } else { gtk_widget_remove_css_class(slot.value, "warning") }
            } else {
                gtk_widget_remove_css_class(slot.value, "warning")
                gtk_widget_add_css_class(slot.value, "dim-label")
            }
            gtk_widget_set_visible(slot.row, 1)
        }

        gtk_label_set_text(earValue.opaque, LevelPresentation.earLevelText(stage: stage, level: level))
        Ui.setRow(earDisclaimer, title: "", subtitle: LevelPresentation.earDisclaimer(level))
        Ui.setRow(calibrationRow, title: "Reads loud or quiet? Nudge it",
                  subtitle: LevelPresentation.calibrationHelp)
        adw_preferences_row_set_title(calibrationRow.typed(AdwPreferencesRow.self), "Reads loud or quiet? Nudge it")
        Accessible.setLabel(calibrationSpin, LevelPresentation.calibrationTitle(stage))
        let offset = level.earCalibrationDb - EarLevel.defaultCalibrationDb
        if gtk_spin_button_get_value(calibrationSpin.opaque) != offset {
            gtk_spin_button_set_value(calibrationSpin.opaque, offset)
        }
        gtk_widget_set_tooltip_text(calibrationSpin, "Offset from the typical-headphone assumption: "
            + LevelPresentation.calibrationOffsetText(level))
        Ui.show(calibrationReset, !LevelPresentation.calibrationIsDefault(level))

        adw_switch_row_set_active(detectRow.opaque, level.detectQuality ? 1 : 0)
        Ui.setRow(detectRow, title: "Detect stream quality",
                  subtitle: level.detectQuality ? "" : "Turn this on to measure what is playing.")
        Ui.show(verdictRow, level.detectQuality)
        gtk_label_set_text(verdictValue.opaque, LevelPresentation.verdictText(stage: stage, level: level))
        for name in ["success", "warning", "dim-label"] { gtk_widget_remove_css_class(verdictValue, name) }
        switch LevelPresentation.verdictTone(stage: stage, level: level) {
        case .good: gtk_widget_add_css_class(verdictValue, "success")
        case .caution: gtk_widget_add_css_class(verdictValue, "warning")
        case .neutral: gtk_widget_add_css_class(verdictValue, "dim-label")
        }
        let showsBalance = LevelPresentation.showsBalance(stage: stage, level: level)
        Ui.show(balanceRow, showsBalance)
        Ui.setRow(balanceRow, title: "Balance",
                  subtitle: LevelPresentation.balanceText(level) + (baselineText.isEmpty ? "" : "\n" + baselineText))
        adw_switch_row_set_active(autoMatchRow.opaque, level.autoRate ? 1 : 0)
        var autoMatch = LevelPresentation.autoMatchExplanation
        if let status = LevelPresentation.autoMatchStatus(level) { autoMatch += " " + status }
        Ui.setRow(autoMatchRow, title: "Auto-match USB rate", subtitle: autoMatch)
        Ui.show(autoMatchRow, level.detectQuality)

        refreshHistory(level, now: now)
    }

    private func refreshHistory(_ level: LevelModelState, now: Date) {
        Ui.setRow(historyHeadline, title: LevelPresentation.historyHeadline(level: level, now: now), subtitle: "")
        Ui.show(deleteButton, !level.exposureDays.isEmpty)
        let hasToday = (LevelPresentation.today(level, now: now)?.audibleSeconds ?? 0) > 0
        Ui.show(historyHeadline, !hasToday)
        if let today = LevelPresentation.today(level, now: now), today.audibleSeconds > 0 {
            let reading = LevelPresentation.todayReading(today)
            Ui.setRow(todayRow, title: "Today",
                      subtitle: "Listened \(reading.listened) \u{00B7} Loud \(reading.loud) \u{00B7} Average \(reading.average)")
            Ui.show(todayRow, true)
        } else {
            Ui.show(todayRow, false)
        }
        let previous = LevelPresentation.previousDays(level: level, now: now)
        Ui.show(previousExpander, !previous.isEmpty)
        adw_preferences_row_set_title(previousExpander.typed(AdwPreferencesRow.self),
                                      LevelPresentation.previousTitle(previous.count))
        for (index, slot) in historySlots.enumerated() {
            guard previous.indices.contains(index) else {
                gtk_widget_set_visible(slot.row, 0)
                continue
            }
            let day = previous[index]
            Ui.setRow(slot.row, title: day.date, subtitle: "Loud \(day.loudDuration)")
            gtk_level_bar_set_value(slot.bar.opaque, day.audibleFraction)
            gtk_label_set_text(slot.duration.opaque, day.duration)
            Accessible.setLabel(slot.bar, "\(day.date), listened \(day.duration)")
            gtk_widget_set_visible(slot.row, 1)
        }
    }
}
