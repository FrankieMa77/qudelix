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
    private let presets: PresetSlotsModel
    private let audio: AudioStack?
    private let panel: AutomationPanel
    private let headroomLabel: UnsafeMutablePointer<GtkWidget>
    private let headroomButton: UnsafeMutablePointer<GtkWidget>
    private let bandsTen: UnsafeMutablePointer<GtkWidget>
    private let bandsTwenty: UnsafeMutablePointer<GtkWidget>
    private let loadButton: UnsafeMutablePointer<GtkWidget>
    private let exportButton: UnsafeMutablePointer<GtkWidget>
    private let updateButton: UnsafeMutablePointer<GtkWidget>
    private let saveButton: UnsafeMutablePointer<GtkWidget>
    private let saveList: UnsafeMutablePointer<GtkWidget>
    private let savePopover: UnsafeMutablePointer<GtkWidget>
    private var saveItems: [UnsafeMutablePointer<GtkWidget>] = []
    private var pendingTwenty: Bool?
    private(set) var dialog: UnsafeMutableRawPointer?
    private let stack: OpaquePointer
    private let placeholder = ConnectionStatusPage()
    private let loading = ConnectionStatusPage()
    private let scroller: UnsafeMutablePointer<GtkWidget>
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

    init(model: AppModel, audio: AudioStack?) {
        self.model = model
        self.audio = audio
        eq = model.eq
        presets = model.presets
        stack = gtk_stack_new()!.opaque
        curve = EqCurveView(model: model.eq)
        panel = AutomationPanel(automation: audio?.automation, suggestions: model.library.suggestions,
                                available: audio?.available == true)

        headroomLabel = Ui.label("")
        headroomButton = Ui.button("Set")
        gtk_widget_set_valign(headroomButton, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(headroomButton, "Attenuates ahead of the filters by as much as the bands boost, so the equalizer passes on no more level than it was given. Clipping already in the source is untouched.")
        bandsTen = gtk_toggle_button_new_with_label("10")!
        bandsTwenty = gtk_toggle_button_new_with_label("20")!
        gtk_toggle_button_set_group(bandsTwenty.typed(GtkToggleButton.self), bandsTen.typed(GtkToggleButton.self))
        Accessible.setLabel(bandsTen, "10 EQ bands")
        Accessible.setLabel(bandsTwenty, "20 EQ bands")
        let bandsTooltip = "EQ bands. The two modes keep separate presets, so switching changes the active curve."
        gtk_widget_set_tooltip_text(bandsTen, bandsTooltip)
        gtk_widget_set_tooltip_text(bandsTwenty, bandsTooltip)
        loadButton = Ui.button("Load from file\u{2026}")
        gtk_widget_set_tooltip_text(loadButton, "Apply an AutoEq or Equalizer APO parametric EQ text file to the live EQ. Save it to a slot afterwards to keep it.")
        exportButton = Ui.button("Export current EQ\u{2026}")
        gtk_widget_set_tooltip_text(exportButton, EqEditorModel.exportHelp)
        updateButton = Ui.button("Update")
        saveButton = gtk_menu_button_new()!
        gtk_menu_button_set_label(saveButton.opaque, "Save to slot\u{2026}")
        saveList = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        savePopover = gtk_popover_new()!
        let saveScroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(saveScroller.opaque, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(saveScroller.opaque, 1)
        gtk_scrolled_window_set_max_content_height(saveScroller.opaque, 320)
        gtk_scrolled_window_set_child(saveScroller.opaque, saveList)
        gtk_popover_set_child(savePopover.typed(GtkPopover.self), saveScroller)
        gtk_menu_button_set_popover(saveButton.opaque, savePopover)

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
        Ui.wrapHeader(of: bandsGroup)

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
                                     preGainScale: preGainScale, bandsGroup: bandsGroup,
                                     modeSwitch: [bandsTen, bandsTwenty],
                                     headroom: [headroomLabel, headroomButton],
                                     actions: (load: loadButton, export: exportButton, update: updateButton, save: saveButton),
                                     automation: panel.widget)
        editor = built.outer
        scroller = built.scroller

        gtk_stack_add_named(stack, placeholder.widget, "status")
        gtk_stack_add_named(stack, loading.widget, "loading")
        gtk_stack_add_named(stack, editor, "content")
        gtk_stack_add_named(stack, unreadable, "unreadable")
        widget = UnsafeMutableRawPointer(stack).assumingMemoryBound(to: GtkWidget.self)

        loading.showProgress(title: "Reading the EQ\u{2026}", detail: "Asking the 5K for its equalizer settings.")
        connectControls()
        eq.addObserver { [weak self] state in onLive { self?.update(state) } }
        model.addObserver { [weak self] state in onLive { self?.connectionChanged(state) } }
        presets.addObserver { [weak self] state in onLive { self?.presetsChanged(state) } }
        if let automation = audio?.automation {
            automation.addObserver { [weak self] state in onLive { self?.automationChanged(state) } }
        } else {
            panel.update(AutomationState())
        }
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
                                    bandsGroup: UnsafeMutablePointer<GtkWidget>,
                                    modeSwitch: [UnsafeMutablePointer<GtkWidget>],
                                    headroom: [UnsafeMutablePointer<GtkWidget>],
                                    actions: (load: UnsafeMutablePointer<GtkWidget>,
                                              export: UnsafeMutablePointer<GtkWidget>,
                                              update: UnsafeMutablePointer<GtkWidget>,
                                              save: UnsafeMutablePointer<GtkWidget>),
                                    automation: UnsafeMutablePointer<GtkWidget>)
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
        let modes = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_widget_add_css_class(modes, "linked")
        gtk_widget_set_valign(modes, GTK_ALIGN_CENTER)
        for button in modeSwitch { gtk_box_append(modes.typed(GtkBox.self), button) }
        gtk_box_append(box, toolbar)
        gtk_box_append(box, refusal)

        gtk_box_append(box, curve)
        gtk_box_append(box, readout)

        let headroomRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        for part in headroom { gtk_box_append(headroomRow.typed(GtkBox.self), part) }
        gtk_box_append(box, headroomRow)

        let actionRow = gtk_flow_box_new()!
        gtk_flow_box_set_selection_mode(actionRow.opaque, GTK_SELECTION_NONE)
        gtk_flow_box_set_homogeneous(actionRow.opaque, 0)
        gtk_flow_box_set_max_children_per_line(actionRow.opaque, 5)
        gtk_flow_box_set_column_spacing(actionRow.opaque, 6)
        gtk_flow_box_set_row_spacing(actionRow.opaque, 6)
        gtk_flow_box_set_activate_on_single_click(actionRow.opaque, 0)
        for button in [actions.load, actions.export, modes, actions.update, actions.save] {
            gtk_flow_box_append(actionRow.opaque, button)
            if let wrapper = gtk_widget_get_parent(button) { gtk_widget_set_focusable(wrapper, 0) }
        }
        gtk_box_append(box, actionRow)

        let preGroup = adw_preferences_group_new()!
        adw_preferences_row_set_title(preGainRow.typed(AdwPreferencesRow.self), "Pre-gain")
        adw_action_row_set_subtitle(preGainRow.typed(AdwActionRow.self), "")
        Accessible.setLabel(preGainScale, "Pre-gain")
        ScaleScrolling.install(on: preGainScale)
        gtk_scale_set_draw_value(preGainScale.typed(GtkScale.self), 0)
        gtk_range_set_increments(preGainScale.typed(GtkRange.self), 0.5, 3)
        gtk_range_set_round_digits(preGainScale.typed(GtkRange.self), 1)
        gtk_widget_set_hexpand(preGainScale, 1)
        gtk_widget_set_valign(preGainScale, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(preGainScale, 120, -1)
        adw_action_row_add_suffix(preGainRow.typed(AdwActionRow.self), preGainScale)
        adw_preferences_group_add(preGroup.typed(AdwPreferencesGroup.self), preGainRow)
        gtk_box_append(box, preGroup)
        gtk_box_append(box, automation)

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
        Signals.connect(headroomButton, signal: "clicked") { onMain { eq.applySuggestedPreGain() } }
        for (button, twenty) in [(bandsTen, false), (bandsTwenty, true)] {
            Signals.onToggled(button) { [weak self] on in
                onMain {
                    guard let self, !self.updating, on else { return }
                    self.pendingTwenty = twenty
                    eq.setEqMode(twentyBand: twenty)
                    self.syncModeSwitch(eq.state)
                }
            }
        }
        Signals.connect(loadButton, signal: "clicked") { [weak self] in
            onMain { if let self { EqFileLoader.present(from: self.widget, eq: eq) } }
        }
        Signals.connect(exportButton, signal: "clicked") { [weak self] in
            onMain { if let self { EqFileLoader.presentExport(from: self.widget, eq: eq) } }
        }
        Signals.connect(updateButton, signal: "clicked") { [weak self] in onMain { self?.presets.updateActive() } }
        Signals.onValueChanged(preGainScale) { [weak self] value in
            onMain {
                guard let self, !self.updating else { return }
                eq.setPreGain(value)
            }
        }
    }

    private var automationState = AutomationState()

    func openAutomation() { panel.open() }

    private func automationChanged(_ next: AutomationState) {
        automationState = next
        panel.update(next)
        curve.setLines(reference: next.referenceLine, trim: next.trimLine)
        update(state)
    }

    private func presetsChanged(_ next: PresetSlotsState) {
        if saveItems.count != next.slots.count { rebuildSaveItems(count: next.slots.count) }
        for slot in next.slots where saveItems.indices.contains(slot.index) {
            if let label = gtk_button_get_child(saveItems[slot.index].typed(GtkButton.self)) {
                gtk_label_set_text(label.opaque, "\(slot.number) \u{00B7} \(slot.label)")
            }
            Accessible.setLabel(saveItems[slot.index], "Save to slot \(slot.number), \(slot.label)")
        }
        refreshActions()
    }

    private func rebuildSaveItems(count: Int) {
        for item in saveItems { gtk_box_remove(saveList.typed(GtkBox.self), item) }
        saveItems = []
        for index in 0..<count {
            let item = Ui.menuItem("\(index + 1)")
            gtk_box_append(saveList.typed(GtkBox.self), item)
            saveItems.append(item)
            Signals.connect(item, signal: "clicked") { [weak self] in
                onMain {
                    guard let self else { return }
                    gtk_popover_popdown(self.savePopover.typed(GtkPopover.self))
                    if let prompt = self.presets.requestSave(slot: index) { self.presentOverwrite(prompt) }
                }
            }
        }
    }

    @discardableResult
    func presentOverwrite(_ prompt: SlotOverwritePrompt) -> UnsafeMutableRawPointer {
        if let open = dialog { return open }
        var opened: UnsafeMutableRawPointer?
        let created = Ui.confirm(parent: Ui.parentWindow(of: widget), title: prompt.title,
                                 message: prompt.message, action: prompt.confirmLabel,
                                 destructive: true) { [weak self] confirmed in
            onMain {
                if confirmed { self?.presets.save(slot: prompt.slot) }
                if self?.dialog == opened { self?.dialog = nil }
            }
        }
        opened = created
        dialog = created
        return created
    }

    private func refreshActions() {
        let editable = state.canEdit
        let following = state.readOnlyReason != nil
        gtk_widget_set_sensitive(loadButton, editable ? 1 : 0)
        gtk_widget_set_sensitive(exportButton, eq.canExport ? 1 : 0)
        gtk_widget_set_sensitive(updateButton, presets.canUpdateActive ? 1 : 0)
        gtk_widget_set_tooltip_text(updateButton, presets.updateHelp())
        gtk_widget_set_sensitive(saveButton, presets.canWrite && !following ? 1 : 0)
    }

    private func syncModeSwitch(_ next: EqEditorState) {
        let wasUpdating = updating
        updating = true
        defer { updating = wasUpdating }
        if !next.modeChanging { pendingTwenty = nil }
        let twenty = next.modeChanging ? (pendingTwenty ?? next.isTwentyBand) : next.isTwentyBand
        gtk_toggle_button_set_active((twenty ? bandsTwenty : bandsTen).typed(GtkToggleButton.self), 1)
        gtk_widget_set_sensitive(bandsTen, next.canSwitchMode ? 1 : 0)
        gtk_widget_set_sensitive(bandsTwenty, next.canSwitchMode ? 1 : 0)
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
        var blocked = next.ready && !editable ? eq.writeRefusal(attempted: false) : nil
        if next.ready, !editable, next.readOnlyReason != nil {
            blocked = automationState.following ? AutomationState.readOnlyHelp : next.readOnlyReason
        }
        gtk_label_set_text(refusal.opaque, blocked ?? "")
        gtk_widget_set_visible(refusal, blocked == nil ? 0 : 1)
        gtk_label_set_text(headroomLabel.opaque, next.headroom.text)
        let title = next.headroom.buttonTitle
        gtk_widget_set_visible(headroomLabel, next.ready && editable ? 1 : 0)
        gtk_widget_set_visible(headroomButton, next.ready && editable && title != nil ? 1 : 0)
        if let title { gtk_button_set_label(headroomButton.typed(GtkButton.self), title) }
        syncModeSwitch(next)
        refreshActions()
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
            let shown = muted ? (next.muted[index] ?? band.filter) : band.filter
            adw_preferences_row_set_title(row.row.typed(AdwPreferencesRow.self),
                                          "Band \(index + 1) \u{00B7} \(shown.label)")
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
        let shown = state.isMuted(selected) ? (state.muted[selected] ?? band.filter) : band.filter
        return "Band \(selected + 1) \u{00B7} \(shown.label) \u{00B7} \(band.summary)"
    }
}

private extension UnsafeMutablePointer where Pointee == GtkWidget {
    func setText(_ text: String) {
        gtk_label_set_text(OpaquePointer(self), text)
    }
}
