import CGtk
import Foundation
import QudelixBar

struct BatteryChartDrawing {
    let area: UnsafeMutablePointer<GtkWidget>
    var state = BatteryGraphState()

    private static let rightInset = 34.0
    private static let bottomInset = 16.0
    private static let topInset = 8.0
    private static let leftInset = 10.0

    private func color(_ name: String, fallback: GdkRGBA) -> GdkRGBA {
        var rgba = GdkRGBA()
        if gtk_style_context_lookup_color(gtk_widget_get_style_context(area), name, &rgba) != 0 {
            return rgba
        }
        return fallback
    }

    private func rounded(_ cr: OpaquePointer, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) {
        cairo_new_sub_path(cr)
        cairo_arc(cr, x + w - r, y + r, r, -Double.pi / 2, 0)
        cairo_arc(cr, x + w - r, y + h - r, r, 0, Double.pi / 2)
        cairo_arc(cr, x + r, y + h - r, r, Double.pi / 2, Double.pi)
        cairo_arc(cr, x + r, y + r, r, Double.pi, 3 * Double.pi / 2)
        cairo_close_path(cr)
    }

    private func setColor(_ cr: OpaquePointer, _ color: GdkRGBA, _ alpha: Double) {
        cairo_set_source_rgba(cr, Double(color.red), Double(color.green), Double(color.blue), alpha)
    }

    private func centered(_ cr: OpaquePointer, _ text: String, x: Double, y: Double) {
        var extents = cairo_text_extents_t()
        cairo_text_extents(cr, text, &extents)
        cairo_move_to(cr, x - extents.width / 2 - extents.x_bearing, y - extents.height / 2 - extents.y_bearing)
        cairo_show_text(cr, text)
    }

    func draw(_ cr: OpaquePointer, _ w: Double, _ h: Double) {
        var foreground = GdkRGBA()
        gtk_widget_get_color(area, &foreground)
        let accent = color("accent_color", fallback: GdkRGBA(red: 0.21, green: 0.52, blue: 0.89, alpha: 1))
        let card = color("card_bg_color", fallback: GdkRGBA(red: 1, green: 1, blue: 1, alpha: 1))
        let window = color("window_bg_color", fallback: GdkRGBA(red: 0.98, green: 0.98, blue: 0.98, alpha: 1))
        let blend = Double(card.alpha)
        let surface = GdkRGBA(red: Float(Double(card.red) * blend + Double(window.red) * (1 - blend)),
                              green: Float(Double(card.green) * blend + Double(window.green) * (1 - blend)),
                              blue: Float(Double(card.blue) * blend + Double(window.blue) * (1 - blend)),
                              alpha: 1)

        rounded(cr, 0.5, 0.5, w - 1, h - 1, 8)
        setColor(cr, surface, 1)
        cairo_fill_preserve(cr)
        cairo_save(cr)
        cairo_clip(cr)

        let left = Self.leftInset
        let top = Self.topInset
        let plotWidth = max(w - Self.rightInset - left, 1)
        let plotHeight = max(h - Self.bottomInset - top, 1)
        func px(_ x: Double) -> Double { left + max(0, min(1, x)) * plotWidth }
        func py(_ y: Double) -> Double { top + plotHeight - max(0, min(100, y)) / 100 * plotHeight }

        cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        cairo_set_font_size(cr, 10)
        cairo_set_line_width(cr, 1)

        for span in state.chargingSpans {
            cairo_rectangle(cr, px(span.lowerBound), top, px(span.upperBound) - px(span.lowerBound), plotHeight)
            cairo_set_source_rgba(cr, 0.18, 0.76, 0.49, 0.16)
            cairo_fill(cr)
        }

        for level in stride(from: 0, through: 100, by: 25) {
            let y = py(Double(level)).rounded() + 0.5
            setColor(cr, foreground, level == 0 || level == 100 ? 0.3 : 0.12)
            cairo_move_to(cr, left, y)
            cairo_line_to(cr, left + plotWidth, y)
            cairo_stroke(cr)
            if level % 50 == 0 {
                setColor(cr, foreground, 0.6)
                centered(cr, "\(level)%", x: left + plotWidth + Self.rightInset / 2, y: y)
            }
        }

        let lowY = py(Double(BatteryGraphState.lowThreshold)).rounded() + 0.5
        var dashes: [Double] = [3, 3]
        cairo_save(cr)
        cairo_set_dash(cr, &dashes, 2, 0)
        cairo_set_source_rgba(cr, 0.96, 0.45, 0.0, 0.5)
        cairo_move_to(cr, left, lowY)
        cairo_line_to(cr, left + plotWidth, lowY)
        cairo_stroke(cr)
        cairo_restore(cr)

        for tick in state.ticks {
            let x = px(tick.x).rounded() + 0.5
            setColor(cr, foreground, 0.12)
            cairo_move_to(cr, x, top)
            cairo_line_to(cr, x, top + plotHeight)
            cairo_stroke(cr)
            if x > left + 14, x < left + plotWidth - 14 {
                setColor(cr, foreground, 0.6)
                centered(cr, tick.label, x: x, y: h - Self.bottomInset / 2 + 1)
            }
        }

        for points in state.lines {
            cairo_new_path(cr)
            for (index, point) in points.enumerated() {
                if index == 0 { cairo_move_to(cr, px(point.x), py(point.y)) } else { cairo_line_to(cr, px(point.x), py(point.y)) }
            }
            cairo_save(cr)
            cairo_line_to(cr, px(points[points.count - 1].x), py(0))
            cairo_line_to(cr, px(points[0].x), py(0))
            cairo_close_path(cr)
            let gradient = cairo_pattern_create_linear(0, top, 0, top + plotHeight)
            cairo_pattern_add_color_stop_rgba(gradient, 0, Double(accent.red), Double(accent.green), Double(accent.blue), 0.3)
            cairo_pattern_add_color_stop_rgba(gradient, 1, Double(accent.red), Double(accent.green), Double(accent.blue), 0.03)
            cairo_set_source(cr, gradient)
            cairo_fill(cr)
            cairo_pattern_destroy(gradient)
            cairo_restore(cr)

            cairo_new_path(cr)
            for (index, point) in points.enumerated() {
                if index == 0 { cairo_move_to(cr, px(point.x), py(point.y)) } else { cairo_line_to(cr, px(point.x), py(point.y)) }
            }
            cairo_set_line_width(cr, 2)
            cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
            setColor(cr, accent, 1)
            cairo_stroke(cr)
        }

        if let latest = state.latest {
            cairo_new_path(cr)
            cairo_arc(cr, px(latest.x), py(latest.y), 3, 0, 2 * Double.pi)
            setColor(cr, accent, 1)
            cairo_fill(cr)
        }

        if state.isEmpty {
            setColor(cr, foreground, 0.7)
            centered(cr, "No readings in this window yet", x: left + plotWidth / 2, y: top + plotHeight / 2)
        }
        cairo_restore(cr)

        rounded(cr, 0.5, 0.5, w - 1, h - 1, 8)
        setColor(cr, foreground, 0.16)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
    }
}
