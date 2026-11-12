import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@MainActor
final class SuggestionBanner {
    let widget: Widget

    private let model: SuggestionsModel
    private let banner: Widget
    private let strip: Widget
    private let detail: Widget
    private let note: Widget
    private let spinner = Ui.spinner()
    private let alternatives: Widget
    private let alternativesPopover: Widget
    private let alternativesBox: Widget
    private let dismiss: Widget
    private var offerID = ""
    private var shownChoices: [SuggestionChoice] = []

    init(model: SuggestionsModel) {
        self.model = model
        widget = Ui.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        banner = adw_banner_new("")!
        adw_banner_set_use_markup(banner.opaque, 1)
        adw_banner_set_button_label(banner.opaque, SuggestionsModel.applyLabel)
        Ui.append(widget, banner)

        strip = Ui.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_margin_start(strip, 12)
        gtk_widget_set_margin_end(strip, 12)
        gtk_widget_set_margin_top(strip, 4)
        gtk_widget_set_margin_bottom(strip, 4)
        detail = Ui.label("", classes: ["caption", "dim-label"])
        note = Ui.label("", classes: ["caption", "warning"])
        let text = Ui.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_hexpand(text, 1)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        Ui.append(text, detail)
        Ui.append(text, note)
        alternatives = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(alternatives.opaque, "view-more-symbolic")
        gtk_widget_add_css_class(alternatives, "flat")
        gtk_widget_set_valign(alternatives, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(alternatives, SuggestionsModel.alternativesLabel)
        Accessible.setLabel(alternatives, SuggestionsModel.alternativesLabel)
        alternativesPopover = gtk_popover_new()!
        alternativesBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        gtk_popover_set_child(alternativesPopover.typed(GtkPopover.self), alternativesBox)
        gtk_menu_button_set_popover(alternatives.opaque, alternativesPopover)
        dismiss = Ui.button("", classes: ["flat"])
        gtk_button_set_icon_name(dismiss.typed(GtkButton.self), "window-close-symbolic")
        gtk_widget_set_valign(dismiss, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(dismiss, SuggestionsModel.dismissHelp)
        Accessible.setLabel(dismiss, SuggestionsModel.dismissLabel)
        Ui.append(strip, text)
        Ui.append(strip, spinner)
        Ui.append(strip, alternatives)
        Ui.append(strip, dismiss)
        Ui.append(widget, strip)
        Ui.setSpinning(spinner, false)
        Ui.show(widget, false)

        Signals.connect(banner, signal: "button-clicked") { [weak self] in
            onMain {
                guard let self, !self.offerID.isEmpty else { return }
                self.model.accept(self.offerID)
            }
        }
        Signals.connect(dismiss, signal: "clicked") { [weak self] in onMain { self?.model.dismiss() } }
        model.addObserver { [weak self] state in onLive { self?.update(state) } }
    }

    private func update(_ next: SuggestionsState) {
        guard let offer = next.banner else {
            offerID = ""
            adw_banner_set_revealed(banner.opaque, 0)
            Ui.show(widget, false)
            return
        }
        offerID = offer.id
        Ui.show(widget, true)
        adw_banner_set_title(banner.opaque, Ui.escaped(offer.headline))
        Ui.setText(detail, offer.detail)
        let canClick = !next.busy && next.canApply
        adw_banner_set_button_label(banner.opaque, canClick ? SuggestionsModel.applyLabel : nil)
        adw_banner_set_revealed(banner.opaque, 1)
        Ui.setSpinning(spinner, next.busy)
        var lines: [String] = []
        if let warning = next.unsavedWarning { lines.append(warning) }
        if let error = next.error {
            lines.append(error)
        } else if !next.canApply, let help = next.applyHelp {
            lines.append(help)
        }
        Ui.setText(note, lines.isEmpty ? nil : lines.joined(separator: "\n"))
        Ui.show(alternatives, !offer.alternatives.isEmpty && !next.busy && next.canApply)
        if shownChoices != offer.alternatives { rebuildChoices(offer.alternatives) }
    }

    private func rebuildChoices(_ choices: [SuggestionChoice]) {
        shownChoices = choices
        while let child = gtk_widget_get_first_child(alternativesBox) {
            gtk_box_remove(alternativesBox.typed(GtkBox.self), child)
        }
        for choice in choices {
            let item = Ui.menuItem(choice.label)
            Signals.connect(item, signal: "clicked") { [weak self] in
                onMain {
                    guard let self else { return }
                    gtk_popover_popdown(self.alternativesPopover.typed(GtkPopover.self))
                    self.model.accept(choice.id)
                }
            }
            gtk_box_append(alternativesBox.typed(GtkBox.self), item)
        }
    }
}
