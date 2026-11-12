import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@MainActor
final class SliderRow {
    let widget: Widget

    private let control: StageControl
    private let scale: Widget
    private let valueLabel: Widget
    private let helpLabel: Widget
    private var updating = false

    init(control: StageControl, onChange: @escaping (StageControl, Double) -> Void,
         onReset: ((StageControl) -> Void)? = nil) {
        self.control = control
        let row = adw_preferences_row_new()!
        gtk_list_box_row_set_activatable(row.typed(GtkListBoxRow.self), 0)
        gtk_widget_set_focusable(row, 0)
        widget = row

        let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
        gtk_widget_set_margin_top(column, 8)
        gtk_widget_set_margin_bottom(column, 8)
        gtk_widget_set_margin_start(column, 12)
        gtk_widget_set_margin_end(column, 12)

        let top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let title = gtk_label_new(control.label)!
        gtk_label_set_xalign(title.opaque, 0)
        gtk_widget_set_hexpand(title, 1)
        valueLabel = gtk_label_new("")!
        gtk_label_set_xalign(valueLabel.opaque, 1)
        gtk_widget_add_css_class(valueLabel, "dim-label")
        gtk_widget_add_css_class(valueLabel, "numeric")
        gtk_box_append(top.typed(GtkBox.self), title)
        gtk_box_append(top.typed(GtkBox.self), valueLabel)
        var reset: Widget?
        if control.hasReset {
            let button = gtk_button_new_from_icon_name("edit-undo-symbolic")!
            gtk_widget_add_css_class(button, "flat")
            gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
            gtk_widget_set_tooltip_text(button, "Reset \(control.label)")
            Accessible.setLabel(button, "Reset \(control.label)")
            gtk_box_append(top.typed(GtkBox.self), button)
            reset = button
        }

        scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, control.range.lowerBound,
                                         control.range.upperBound, control.step)!
        ScaleScrolling.install(on: scale)
        gtk_scale_set_draw_value(scale.typed(GtkScale.self), 0)
        gtk_range_set_increments(scale.typed(GtkRange.self), control.step, control.step * 5)
        gtk_widget_set_hexpand(scale, 1)
        Accessible.setLabel(scale, control.label)
        Accessible.setDescription(scale, control.help)

        helpLabel = Ui.label(control.help)

        gtk_box_append(column.typed(GtkBox.self), top)
        gtk_box_append(column.typed(GtkBox.self), scale)
        gtk_box_append(column.typed(GtkBox.self), helpLabel)
        gtk_list_box_row_set_child(row.typed(GtkListBoxRow.self), column)

        Signals.onValueChanged(scale) { [weak self] value in
            onMain {
                guard let self, !self.updating else { return }
                onChange(self.control, value)
            }
        }
        if let reset, let onReset {
            Signals.connect(reset, signal: "clicked") { onMain { onReset(control) } }
        }
    }

    func update(_ next: StageSettings) {
        updating = true
        defer { updating = false }
        let value = control.value(next)
        let current = gtk_range_get_value(scale.typed(GtkRange.self))
        if control.quantized(current) != control.quantized(value) {
            gtk_range_set_value(scale.typed(GtkRange.self), value)
        }
        let display = control.display(next)
        gtk_label_set_text(valueLabel.opaque, display)
        Accessible.setLabel(scale, "\(control.label), \(display)")
    }

    func setEnabled(_ enabled: Bool) {
        gtk_widget_set_sensitive(scale, enabled ? 1 : 0)
    }
}
