import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@discardableResult
func onMain<Result>(_ body: @MainActor () -> Result) -> Result {
    MainActor.assumeIsolated(body)
}

func onLive(_ body: @MainActor () -> Void) {
    UiLifetime.ifAlive { MainActor.assumeIsolated(body) }
}

@MainActor
final class DevicePage {
    let widget: UnsafeMutablePointer<GtkWidget>

    private let model: AppModel
    private let stack: OpaquePointer
    private let placeholder = ConnectionStatusPage()
    private var updating = false

    private let modelRow = DevicePage.valueRow("Model")
    private let firmwareRow = DevicePage.valueRow("Firmware")
    private let linkRow = DevicePage.valueRow("Connection")
    private let batteryRow = DevicePage.valueRow("Battery")
    private let eqTypeRow = DevicePage.valueRow("EQ type")
    private let eqGroupRow = DevicePage.valueRow("EQ group")
    private let presetRow = DevicePage.valueRow("Active preset")
    private let rateRow = DevicePage.valueRow("Sample rate")
    private let inputRow = DevicePage.valueRow("Input")

    private let volumeRow: UnsafeMutablePointer<GtkWidget>
    private let volumeScale: UnsafeMutablePointer<GtkWidget>
    private let muteRow: UnsafeMutablePointer<GtkWidget>
    private let filterRow: UnsafeMutablePointer<GtkWidget>
    private let eqRow: UnsafeMutablePointer<GtkWidget>
    private var scaleRange = -60.0...0.0

    private let graph: BatteryGraphModel
    private let graphArea: UnsafeMutablePointer<GtkWidget>
    private let headline: UnsafeMutablePointer<GtkWidget>
    private let footnote: UnsafeMutablePointer<GtkWidget>
    private var chart: BatteryChartDrawing
    private var windowButtons: [BatteryGraphWindow: UnsafeMutablePointer<GtkWidget>] = [:]

    init(model: AppModel) {
        self.model = model
        stack = gtk_stack_new()!.opaque
        volumeRow = adw_action_row_new()!
        volumeScale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, -60, 0, 0.5)!
        muteRow = adw_switch_row_new()!
        filterRow = adw_combo_row_new()!
        eqRow = adw_switch_row_new()!
        graph = model.batteryGraph
        graphArea = Accessible.drawingArea(role: GTK_ACCESSIBLE_ROLE_IMG)
        Accessible.setLabel(graphArea, "Battery history chart")
        headline = Self.caption()
        footnote = Self.caption()
        chart = BatteryChartDrawing(area: graphArea)

        let page = adw_preferences_page_new()!

        let device = Self.group("Device")
        for row in [modelRow, firmwareRow, linkRow, batteryRow] {
            adw_preferences_group_add(device.typed(AdwPreferencesGroup.self), row)
        }

        let output = Self.group("Output")
        adw_preferences_row_set_title(volumeRow.typed(AdwPreferencesRow.self), "Volume")
        adw_action_row_set_subtitle(volumeRow.typed(AdwActionRow.self), "")
        Accessible.setLabel(volumeScale, "Volume")
        gtk_scale_set_draw_value(volumeScale.raw.assumingMemoryBound(to: GtkScale.self), 0)
        gtk_range_set_increments(volumeScale.raw.assumingMemoryBound(to: GtkRange.self), 0.5, 3)
        gtk_range_set_round_digits(volumeScale.raw.assumingMemoryBound(to: GtkRange.self), 1)
        gtk_widget_set_hexpand(volumeScale, 1)
        gtk_widget_set_valign(volumeScale, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(volumeScale, 160, -1)
        adw_action_row_add_suffix(volumeRow.typed(AdwActionRow.self), volumeScale)
        adw_preferences_row_set_title(muteRow.typed(AdwPreferencesRow.self), "Mute")
        adw_preferences_row_set_title(filterRow.typed(AdwPreferencesRow.self), "DAC filter")
        let names = gtk_string_list_new(nil)!
        for name in AppModel.dacFilters { gtk_string_list_append(names, name) }
        adw_combo_row_set_model(filterRow.typed(AdwComboRow.self), names)
        adw_combo_row_set_use_subtitle(filterRow.typed(AdwComboRow.self), 1)
        for row in [volumeRow, muteRow, filterRow] {
            adw_preferences_group_add(output.typed(AdwPreferencesGroup.self), row)
        }

        let eq = Self.group("EQ")
        adw_preferences_row_set_title(eqRow.typed(AdwPreferencesRow.self), "Equalizer")
        for row in [eqRow, eqTypeRow, eqGroupRow, presetRow] {
            adw_preferences_group_add(eq.typed(AdwPreferencesGroup.self), row)
        }

        let audio = Self.group("Audio")
        for row in [rateRow, inputRow] {
            adw_preferences_group_add(audio.typed(AdwPreferencesGroup.self), row)
        }

        let history = Self.group("Battery history")

        for group in [device, output, eq, audio, history] {
            adw_preferences_page_add(page.typed(AdwPreferencesPage.self), group.typed(AdwPreferencesGroup.self))
        }

        gtk_stack_add_named(stack, placeholder.widget, "status")
        gtk_stack_add_named(stack, page, "content")
        widget = stack.widgetPointer

        buildGraph(in: history)
        connectControls()
        graph.addObserver { [weak self] state in onLive { self?.showGraph(state) } }
        g_timeout_add_seconds(60, { data in
            guard data != nil else { return 0 }
            onMain { Unmanaged<BatteryGraphModel>.fromOpaque(data!).takeUnretainedValue().refresh() }
            return 1
        }, Unmanaged.passUnretained(graph).toOpaque())
        model.addObserver { [weak self] state in onLive { self?.update(state) } }
    }

    private static func group(_ title: String) -> UnsafeMutablePointer<GtkWidget> {
        let group = adw_preferences_group_new()!
        adw_preferences_group_set_title(group.typed(AdwPreferencesGroup.self), title)
        return group
    }

    private static func caption() -> UnsafeMutablePointer<GtkWidget> {
        let label = gtk_label_new("")!
        let typed = label.opaque
        gtk_label_set_xalign(typed, 0)
        gtk_label_set_wrap(typed, 1)
        gtk_label_set_wrap_mode(typed, PANGO_WRAP_WORD_CHAR)
        gtk_widget_add_css_class(label, "dim-label")
        gtk_widget_add_css_class(label, "caption")
        return label
    }

    private func buildGraph(in group: UnsafeMutablePointer<GtkWidget>) {
        let switcher = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_widget_add_css_class(switcher, "linked")
        gtk_widget_set_valign(switcher, GTK_ALIGN_CENTER)
        var first: UnsafeMutablePointer<GtkWidget>?
        for window in BatteryGraphWindow.allCases {
            let button = gtk_toggle_button_new_with_label(window.label)!
            if let first {
                gtk_toggle_button_set_group(button.typed(GtkToggleButton.self), first.typed(GtkToggleButton.self))
            } else {
                first = button
            }
            gtk_box_append(switcher.typed(GtkBox.self), button)
            windowButtons[window] = button
            Signals.onToggled(button) { [weak self] active in
                onMain {
                    guard active, let self else { return }
                    self.graph.setWindow(window)
                }
            }
        }
        adw_preferences_group_set_header_suffix(group.typed(AdwPreferencesGroup.self), switcher)

        gtk_widget_set_hexpand(graphArea, 1)
        gtk_widget_set_size_request(graphArea, -1, 170)
        Signals.setDrawFunc(graphArea) { [weak self] cr, width, height in
            onMain { self?.chart.draw(cr, Double(width), Double(height)) }
        }

        let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_box_append(column.typed(GtkBox.self), headline)
        gtk_box_append(column.typed(GtkBox.self), graphArea)
        gtk_box_append(column.typed(GtkBox.self), footnote)
        adw_preferences_group_add(group.typed(AdwPreferencesGroup.self), column)
    }

    private func showGraph(_ state: BatteryGraphState) {
        chart.state = state
        if let button = windowButtons[state.window],
           gtk_toggle_button_get_active(button.typed(GtkToggleButton.self)) == 0 {
            gtk_toggle_button_set_active(button.typed(GtkToggleButton.self), 1)
        }
        gtk_label_set_label(headline.opaque, state.headline)
        gtk_label_set_label(footnote.opaque, state.footnote)
        gtk_widget_set_tooltip_text(graphArea, state.accessibility)
        Accessible.setDescription(graphArea, state.accessibility)
        gtk_widget_queue_draw(graphArea)
    }

    private static func valueRow(_ title: String) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_action_row_new()!
        adw_preferences_row_set_title(row.typed(AdwPreferencesRow.self), title)
        adw_action_row_set_subtitle(row.typed(AdwActionRow.self), "")
        gtk_widget_add_css_class(row, "property")
        return row
    }

    private func connectControls() {
        let model = self.model
        Signals.onValueChanged(volumeScale) { [weak self] value in
            onMain {
                guard let self, !self.updating else { return }
                self.showVolume(value)
                model.setVolume(db: value)
            }
        }
        Signals.onNotify(muteRow, property: "active") { [weak self] _ in
            onMain {
                guard let self, !self.updating else { return }
                model.setMute(adw_switch_row_get_active(self.muteRow.opaque) != 0)
            }
        }
        Signals.onNotify(eqRow, property: "active") { [weak self] _ in
            onMain {
                guard let self, !self.updating else { return }
                model.setEqEnabled(adw_switch_row_get_active(self.eqRow.opaque) != 0)
            }
        }
        Signals.onNotify(filterRow, property: "selected") { [weak self] _ in
            onMain {
                guard let self, !self.updating else { return }
                let index = adw_combo_row_get_selected(self.filterRow.typed(AdwComboRow.self))
                guard index != GTK_INVALID_LIST_POSITION else { return }
                model.setDacFilter(index: Int(index))
            }
        }
    }

    private func showVolume(_ db: Double) {
        DeviceText.setSubtitle(volumeRow, DeviceText.volume(db))
    }

    private static func set(_ row: UnsafeMutablePointer<GtkWidget>, _ value: String?) {
        DeviceText.setSubtitle(row, value)
    }

    func update(_ state: AppModelState) {
        guard case .connected = state.connection, let status = state.status else {
            showStatusPage(for: state.connection)
            return
        }
        gtk_stack_set_visible_child_name(stack, "content")
        updating = true
        defer { updating = false }

        Self.set(modelRow, status.modelName)
        Self.set(firmwareRow, status.firmware)
        Self.set(linkRow, status.linkLabel)
        Self.set(batteryRow, status.batteryLabel)
        Self.set(eqTypeRow, status.eqType)
        Self.set(eqGroupRow, status.eqBandsLabel)
        Self.set(presetRow, status.activeSlotLabel)
        Self.set(rateRow, status.sampleRate)
        Self.set(inputRow, status.inputSource)

        let range = status.volumeRange
        let scale = volumeScale.raw.assumingMemoryBound(to: GtkRange.self)
        if range != scaleRange {
            scaleRange = range
            gtk_range_set_range(scale, range.lowerBound, range.upperBound)
        }
        let volume = status.volumeDb ?? range.upperBound
        gtk_range_set_value(scale, volume)
        showVolume(volume)
        adw_switch_row_set_active(muteRow.opaque, (status.muted ?? false) ? 1 : 0)
        adw_switch_row_set_active(eqRow.opaque, (status.eqEnabled ?? false) ? 1 : 0)
        adw_combo_row_set_selected(filterRow.typed(AdwComboRow.self),
                                   status.dacFilterIndex.map { UInt32($0) } ?? GTK_INVALID_LIST_POSITION)
    }

    private func showStatusPage(for connection: AppConnection) {
        placeholder.show(for: connection)
        gtk_stack_set_visible_child_name(stack, "status")
    }
}

private extension OpaquePointer {
    var widgetPointer: UnsafeMutablePointer<GtkWidget> {
        UnsafeMutableRawPointer(self).assumingMemoryBound(to: GtkWidget.self)
    }
}
