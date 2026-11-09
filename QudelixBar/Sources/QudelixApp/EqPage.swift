import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@MainActor
final class EqPage {
    let widget: UnsafeMutablePointer<GtkWidget>

    private struct BandRow {
        let row: UnsafeMutablePointer<GtkWidget>
        let mute: UnsafeMutablePointer<GtkWidget>
        let type: UnsafeMutablePointer<GtkWidget>
        let frequency: UnsafeMutablePointer<GtkWidget>
        let gain: UnsafeMutablePointer<GtkWidget>
        let q: UnsafeMutablePointer<GtkWidget>
    }

    private let model: AppModel
    private let eq: EqEditorModel
    private let stack: OpaquePointer
    private let placeholder = ConnectionStatusPage()
    private let loading = ConnectionStatusPage()
    private let scroller: UnsafeMutablePointer<GtkWidget>
    private let scrollContent: UnsafeMutablePointer<GtkWidget>
    private let refusal: UnsafeMutablePointer<GtkWidget>
    private let retryButton: UnsafeMutablePointer<GtkWidget>
    private let banner: UnsafeMutablePointer<GtkWidget>
    private let curve: EqCurveView
    private let readout: UnsafeMutablePointer<GtkWidget>
    private let undoButton: UnsafeMutablePointer<GtkWidget>
    private let redoButton: UnsafeMutablePointer<GtkWidget>
    private let flattenButton: UnsafeMutablePointer<GtkWidget>
    private let resetButton: UnsafeMutablePointer<GtkWidget>
    private let preGainRow: UnsafeMutablePointer<GtkWidget>
    private let preGainScale: UnsafeMutablePointer<GtkWidget>
    private let bandsGroup: UnsafeMutablePointer<GtkWidget>
    private let unreadable: UnsafeMutablePointer<GtkWidget>
    private let editor: UnsafeMutablePointer<GtkWidget>
    private var rows: [BandRow] = []
    private var updating = false
    private var state = EqEditorState()

    init(model: AppModel) {
        self.model = model
        eq = model.eq
        stack = gtk_stack_new()!.opaque
        curve = EqCurveView(model: model.eq)

        banner = adw_banner_new("The equalizer is off. Your edits are kept and are heard once it is on.")!
        adw_banner_set_button_label(banner.opaque, "Turn on")

        readout = gtk_label_new("")!
        gtk_label_set_xalign(readout.opaque, 0)
        gtk_label_set_wrap(readout.opaque, 1)
        gtk_widget_add_css_class(readout, "dim-label")
        gtk_widget_add_css_class(readout, "caption")
        gtk_widget_set_hexpand(readout, 1)

        refusal = gtk_label_new("")!
        gtk_label_set_xalign(refusal.opaque, 0)
        gtk_label_set_wrap(refusal.opaque, 1)
        gtk_widget_add_css_class(refusal, "caption")
        gtk_widget_add_css_class(refusal, "warning")
        gtk_widget_set_visible(refusal, 0)

        undoButton = Self.iconButton("edit-undo-symbolic", "Nothing to undo", label: "Undo")
        redoButton = Self.iconButton("edit-redo-symbolic", "Nothing to redo", label: "Redo")
        flattenButton = gtk_button_new_with_label("Flatten")!
        resetButton = gtk_button_new_with_label("Reset")!
        gtk_widget_set_tooltip_text(flattenButton, "Take every band's gain and the pre-gain to zero, keeping the frequencies, filter types and Q.")
        gtk_widget_set_tooltip_text(resetButton, "Put the bands back to the factory layout: peak filters on the default frequencies, 0 dB, Q 1.")

        preGainRow = adw_action_row_new()!
        preGainScale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, -12, 12, 0.5)!
        bandsGroup = adw_preferences_group_new()!

        unreadable = adw_status_page_new()!
        adw_status_page_set_icon_name(unreadable.opaque, "dialog-warning-symbolic")
        adw_status_page_set_title(unreadable.opaque, "The EQ could not be read")
        adw_status_page_set_description(unreadable.opaque, "The 5K did not send an EQ this app can show. Try again, and reconnect the device if it keeps failing.")
        retryButton = gtk_button_new_with_label("Try again")!
        gtk_widget_add_css_class(retryButton, "suggested-action")
        gtk_widget_add_css_class(retryButton, "pill")
        gtk_widget_set_halign(retryButton, GTK_ALIGN_CENTER)
        adw_status_page_set_child(unreadable.opaque, retryButton)

        let built = Self.buildEditor(banner: banner, curve: curve.area, readout: readout, refusal: refusal,
                                     undo: undoButton, redo: redoButton, flatten: flattenButton,
                                     reset: resetButton, preGainRow: preGainRow,
                                     preGainScale: preGainScale, bandsGroup: bandsGroup)
        editor = built.outer
        scroller = built.scroller
        scrollContent = built.content

        gtk_stack_add_named(stack, placeholder.widget, "status")
        gtk_stack_add_named(stack, loading.widget, "loading")
        gtk_stack_add_named(stack, editor, "content")
        gtk_stack_add_named(stack, unreadable, "unreadable")
        widget = UnsafeMutableRawPointer(stack).assumingMemoryBound(to: GtkWidget.self)

        loading.showProgress(title: "Reading the EQ\u{2026}", detail: "Asking the 5K for its equalizer settings.")
        curve.onSettled = { [weak self] index in onMain { self?.reveal(index) } }
        connectControls()
        eq.addObserver { [weak self] state in onLive { self?.update(state) } }
        model.addObserver { [weak self] state in onLive { self?.connectionChanged(state) } }
    }

    private static func iconButton(_ icon: String, _ tooltip: String, label: String) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new_from_icon_name(icon)!
        gtk_widget_set_tooltip_text(button, tooltip)
        Accessible.setLabel(button, label)
        return button
    }

    private static func buildEditor(banner: UnsafeMutablePointer<GtkWidget>,
                                    curve: UnsafeMutablePointer<GtkWidget>,
                                    readout: UnsafeMutablePointer<GtkWidget>,
                                    refusal: UnsafeMutablePointer<GtkWidget>,
                                    undo: UnsafeMutablePointer<GtkWidget>,
                                    redo: UnsafeMutablePointer<GtkWidget>,
                                    flatten: UnsafeMutablePointer<GtkWidget>,
                                    reset: UnsafeMutablePointer<GtkWidget>,
                                    preGainRow: UnsafeMutablePointer<GtkWidget>,
                                    preGainScale: UnsafeMutablePointer<GtkWidget>,
                                    bandsGroup: UnsafeMutablePointer<GtkWidget>)
        -> (outer: UnsafeMutablePointer<GtkWidget>, scroller: UnsafeMutablePointer<GtkWidget>,
            content: UnsafeMutablePointer<GtkWidget>) {
        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        gtk_widget_set_margin_top(content, 12)
        gtk_widget_set_margin_bottom(content, 24)
        gtk_widget_set_margin_start(content, 12)
        gtk_widget_set_margin_end(content, 12)
        let box = content.typed(GtkBox.self)

        let toolbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        let toolbarBox = toolbar.typed(GtkBox.self)
        let history = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_widget_add_css_class(history, "linked")
        gtk_box_append(history.typed(GtkBox.self), undo)
        gtk_box_append(history.typed(GtkBox.self), redo)
        let spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(toolbarBox, history)
        gtk_box_append(toolbarBox, spacer)
        gtk_box_append(toolbarBox, flatten)
        gtk_box_append(toolbarBox, reset)
        gtk_box_append(box, toolbar)
        gtk_box_append(box, refusal)

        gtk_box_append(box, curve)
        gtk_box_append(box, readout)

        let preGroup = adw_preferences_group_new()!
        adw_preferences_row_set_title(preGainRow.typed(AdwPreferencesRow.self), "Pre-gain")
        adw_action_row_set_subtitle(preGainRow.typed(AdwActionRow.self), "")
        Accessible.setLabel(preGainScale, "Pre-gain")
        gtk_scale_set_draw_value(preGainScale.typed(GtkScale.self), 0)
        gtk_range_set_increments(preGainScale.typed(GtkRange.self), 0.5, 3)
        gtk_range_set_round_digits(preGainScale.typed(GtkRange.self), 1)
        gtk_widget_set_hexpand(preGainScale, 1)
        gtk_widget_set_valign(preGainScale, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(preGainScale, 120, -1)
        adw_action_row_add_suffix(preGainRow.typed(AdwActionRow.self), preGainScale)
        adw_preferences_group_add(preGroup.typed(AdwPreferencesGroup.self), preGainRow)
        gtk_box_append(box, preGroup)

        adw_preferences_group_set_title(bandsGroup.typed(AdwPreferencesGroup.self), "Bands")
        gtk_box_append(box, bandsGroup)

        let clamp = adw_clamp_new()!
        adw_clamp_set_maximum_size(clamp.opaque, 760)
        adw_clamp_set_child(clamp.opaque, content)

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(scroller.opaque, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(scroller.opaque, clamp)

        let outer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_box_append(outer.typed(GtkBox.self), banner)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_box_append(outer.typed(GtkBox.self), scroller)
        return (outer, scroller, clamp)
    }

    private func connectControls() {
        let eq = self.eq
        Signals.connect(banner, signal: "button-clicked") { onMain { eq.setEnabled(true) } }
        Signals.connect(retryButton, signal: "clicked") { onMain { eq.retryRead() } }
        Signals.connect(undoButton, signal: "clicked") { onMain { eq.undo() } }
        Signals.connect(redoButton, signal: "clicked") { onMain { eq.redo() } }
        Signals.connect(flattenButton, signal: "clicked") { onMain { eq.flatten() } }
        Signals.connect(resetButton, signal: "clicked") { onMain { eq.resetLayout() } }
        Signals.onValueChanged(preGainScale) { [weak self] value in
            onMain {
                guard let self, !self.updating else { return }
                eq.setPreGain(value)
            }
        }
    }

    func showForRender(_ load: EqLoadState) {
        state.loadState = load
        showContent()
    }

    func undo() { eq.undo() }
    func redo() { eq.redo() }

    private func connectionChanged(_ app: AppModelState) {
        guard case .connected = app.connection else {
            placeholder.show(for: app.connection)
            gtk_stack_set_visible_child_name(stack, "status")
            return
        }
        showContent()
    }

    private func showContent() {
        switch state.loadState {
        case .ready: gtk_stack_set_visible_child_name(stack, "content")
        case .loading: gtk_stack_set_visible_child_name(stack, "loading")
        case .failed: gtk_stack_set_visible_child_name(stack, "unreadable")
        }
    }

    private func reveal(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        let job = RevealJob(page: self, row: rows[index].row)
        g_timeout_add(350, { data in
            let job = Unmanaged<RevealJob>.fromOpaque(data!).takeRetainedValue()
            MainActor.assumeIsolated { job.page.scroll(to: job.row) }
            return 0
        }, Unmanaged.passRetained(job).toOpaque())
    }

    private final class RevealJob {
        let page: EqPage
        let row: UnsafeMutablePointer<GtkWidget>

        init(page: EqPage, row: UnsafeMutablePointer<GtkWidget>) {
            self.page = page
            self.row = row
        }
    }

    private func scroll(to row: UnsafeMutablePointer<GtkWidget>) {
        guard !UiLifetime.windowDestroyed, gtk_widget_get_mapped(row) != 0 else { return }
        var origin = graphene_point_t(x: 0, y: 0)
        var found = graphene_point_t()
        guard gtk_widget_compute_point(row, scrollContent, &origin, &found) != 0 else { return }
        let adjustment = gtk_scrolled_window_get_vadjustment(scroller.opaque)
        let top = Double(found.y) - gtk_adjustment_get_value(adjustment)
        let visible = gtk_adjustment_get_page_size(adjustment)
        guard top < 0 || top > visible - 160 else { return }
        gtk_adjustment_set_value(adjustment, Double(found.y) - 8)
    }

    private func buildRows(count: Int) {
        for existing in rows {
            adw_preferences_group_remove(bandsGroup.typed(AdwPreferencesGroup.self), existing.row)
        }
        rows = []
        for index in 0..<count {
            let row = adw_expander_row_new()!
            adw_preferences_row_set_title(row.typed(AdwPreferencesRow.self), "Band \(index + 1)")

            let mute = gtk_toggle_button_new()!
            gtk_button_set_icon_name(mute.typed(GtkButton.self), "audio-volume-high-symbolic")
            gtk_widget_add_css_class(mute, "flat")
            gtk_widget_set_valign(mute, GTK_ALIGN_CENTER)
            adw_expander_row_add_suffix(row.typed(AdwExpanderRow.self), mute)

            let type = adw_combo_row_new()!
            adw_preferences_row_set_title(type.typed(AdwPreferencesRow.self), "Filter")
            let names = gtk_string_list_new(nil)!
            for kind in EqFilterKind.allCases { gtk_string_list_append(names, kind.label) }
            adw_combo_row_set_model(type.typed(AdwComboRow.self), names)

            let frequency = adw_spin_row_new_with_range(20, 20000, 1)!
            adw_preferences_row_set_title(frequency.typed(AdwPreferencesRow.self), "Frequency (Hz)")
            adw_spin_row_set_digits(frequency.opaque, 0)

            let gain = adw_spin_row_new_with_range(-12, 12, 0.1)!
            adw_preferences_row_set_title(gain.typed(AdwPreferencesRow.self), "Gain (dB)")
            adw_spin_row_set_digits(gain.opaque, 1)

            let q = adw_spin_row_new_with_range(0.1, 10, 0.05)!
            adw_preferences_row_set_title(q.typed(AdwPreferencesRow.self), "Q")
            adw_spin_row_set_digits(q.opaque, 2)

            for child in [type, frequency, gain, q] {
                adw_expander_row_add_row(row.typed(AdwExpanderRow.self), child)
            }
            adw_preferences_group_add(bandsGroup.typed(AdwPreferencesGroup.self), row)
            rows.append(BandRow(row: row, mute: mute, type: type, frequency: frequency, gain: gain, q: q))
            connect(rows[index], index: index)
        }
    }

    private func connect(_ row: BandRow, index: Int) {
        let eq = self.eq
        func edit(_ change: @escaping (inout EqBand) -> Void) {
            guard !updating, eq.state.bands.indices.contains(index) else { return }
            var band = eq.state.bands[index]
            change(&band)
            eq.setBand(index, band)
        }
        Signals.onNotify(row.type, property: "selected") { _ in
            onMain {
                let selected = adw_combo_row_get_selected(row.type.typed(AdwComboRow.self))
                guard selected != GTK_INVALID_LIST_POSITION,
                      let kind = EqFilterKind(rawValue: Int(selected)) else { return }
                edit { $0.filter = kind }
            }
        }
        Signals.onNotify(row.frequency, property: "value") { _ in
            onMain {
                let value = adw_spin_row_get_value(row.frequency.opaque)
                edit { $0.freq = Int(value.rounded()) }
            }
        }
        Signals.onNotify(row.gain, property: "value") { _ in
            onMain {
                let value = adw_spin_row_get_value(row.gain.opaque)
                edit { $0.gain = value }
            }
        }
        Signals.onNotify(row.q, property: "value") { _ in
            onMain {
                let value = adw_spin_row_get_value(row.q.opaque)
                edit { $0.q = value }
            }
        }
        Signals.onToggled(row.mute) { on in
            onMain {
                guard !self.updating else { return }
                eq.setBandMuted(index, on)
            }
        }
        Signals.onNotify(row.row, property: "expanded") { _ in
            onMain {
                guard !self.updating else { return }
                if adw_expander_row_get_expanded(row.row.typed(AdwExpanderRow.self)) != 0 {
                    eq.select(index)
                } else if eq.state.selected == index {
                    eq.select(nil)
                }
            }
        }
    }

    private func update(_ next: EqEditorState) {
        let previous = state
        state = next
        updating = true
        defer { updating = false }

        curve.update(next)
        if rows.count != next.bandCount { buildRows(count: next.bandCount) }
        adw_banner_set_revealed(banner.opaque, next.ready && !next.enabled ? 1 : 0)

        let editable = next.canEdit
        let blocked = next.ready && !editable ? eq.writeRefusal(attempted: false) : nil
        gtk_label_set_text(refusal.opaque, blocked ?? "")
        gtk_widget_set_visible(refusal, blocked == nil ? 0 : 1)
        for control in [flattenButton, resetButton, preGainScale] {
            gtk_widget_set_sensitive(control, editable ? 1 : 0)
        }
        gtk_widget_set_sensitive(undoButton, next.canUndo && editable ? 1 : 0)
        gtk_widget_set_sensitive(redoButton, next.canRedo && editable ? 1 : 0)
        gtk_widget_set_tooltip_text(undoButton, next.undoLabel.map { "Undo \($0) (Ctrl+Z)" } ?? "Nothing to undo")
        gtk_widget_set_tooltip_text(redoButton, next.redoLabel.map { "Redo \($0) (Ctrl+Shift+Z)" } ?? "Nothing to redo")

        let preGain = gtk_range_get_value(preGainScale.typed(GtkRange.self))
        if abs(preGain - next.preGain) > 0.001 {
            gtk_range_set_value(preGainScale.typed(GtkRange.self), next.preGain)
        }
        adw_action_row_set_subtitle(preGainRow.typed(AdwActionRow.self), EqFormat.decibels(next.preGain))

        readout.setText(readoutText(next))

        for (index, band) in next.bands.enumerated() where rows.indices.contains(index) {
            let row = rows[index]
            let muted = next.isMuted(index)
            adw_preferences_row_set_title(row.row.typed(AdwPreferencesRow.self),
                                          "Band \(index + 1) \u{00B7} \(band.filter.label)")
            adw_expander_row_set_subtitle(row.row.typed(AdwExpanderRow.self),
                                          band.summary + (muted ? " \u{00B7} muted" : ""))
            adw_combo_row_set_selected(row.type.typed(AdwComboRow.self), UInt32(band.filter.rawValue))
            setSpin(row.frequency, Double(band.freq))
            setSpin(row.gain, band.gain)
            setSpin(row.q, band.q)
            gtk_widget_set_sensitive(row.type, editable ? 1 : 0)
            gtk_widget_set_sensitive(row.frequency, editable ? 1 : 0)
            gtk_widget_set_sensitive(row.q, editable ? 1 : 0)
            gtk_widget_set_sensitive(row.gain, editable && band.editsGain ? 1 : 0)
            gtk_widget_set_sensitive(row.mute, editable && (band.filter != .bypass || muted) ? 1 : 0)
            gtk_toggle_button_set_active(row.mute.typed(GtkToggleButton.self), muted ? 1 : 0)
            gtk_button_set_icon_name(row.mute.typed(GtkButton.self),
                                     muted ? "audio-volume-muted-symbolic" : "audio-volume-high-symbolic")
            gtk_widget_set_tooltip_text(row.mute, muted ? "Unmute band" : "Mute band")
            Accessible.setLabel(row.mute, (muted ? "Unmute band " : "Mute band ") + "\(index + 1)")
            Accessible.setSelected(row.row, next.selected == index)
            gtk_widget_set_opacity(row.row, band.filter == .bypass ? 0.6 : 1)
            let shouldExpand = next.selected == index
            if (adw_expander_row_get_expanded(row.row.typed(AdwExpanderRow.self)) != 0) != shouldExpand {
                adw_expander_row_set_expanded(row.row.typed(AdwExpanderRow.self), shouldExpand ? 1 : 0)
            }
        }
        if previous.loadState != next.loadState { showContentIfConnected() }
    }

    private func showContentIfConnected() {
        if model.state.connection.isConnected { showContent() }
    }

    private func setSpin(_ row: UnsafeMutablePointer<GtkWidget>, _ value: Double) {
        let spin = row.opaque
        if abs(adw_spin_row_get_value(spin) - value) > 0.0001 { adw_spin_row_set_value(spin, value) }
    }

    private func readoutText(_ state: EqEditorState) -> String {
        let kind = state.isGraphic ? "Graphic preset" : "Parametric"
        guard let selected = state.selected, state.bands.indices.contains(selected) else {
            return "\(state.bandCount) bands \u{00B7} \(kind)"
        }
        let band = state.bands[selected]
        return "Band \(selected + 1) \u{00B7} \(band.filter.label) \u{00B7} \(band.summary)"
    }
}

private extension UnsafeMutablePointer where Pointee == GtkWidget {
    func setText(_ text: String) {
        gtk_label_set_text(OpaquePointer(self), text)
    }
}
