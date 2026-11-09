import CGtk
import Foundation
import QudelixBar
import QudelixGtk

enum CurvePlot {
    static let left = 32.0
    static let right = 12.0
    static let top = 6.0
    static let bottom = 18.0

    static func width(_ total: Double) -> Double { max(total - left - right, 1) }

    static func height(_ total: Double) -> Double { max(total - top - bottom, 1) }

    static func x(_ frequency: Double, _ plotWidth: Double) -> Double {
        min(EqCurveGeometry.fraction(of: frequency), 1) * plotWidth
    }
}

struct CurveDrawing {
    let area: UnsafeMutablePointer<GtkWidget>
    var bands: [EqBand]
    var enabled = true
    var selected: Int?
    var dragging: Int?
    var hovered: Int?
    var requested: [EqBand]?
    private(set) var range = 9.0

    init(area: UnsafeMutablePointer<GtkWidget>, bands: [EqBand], enabled: Bool = true, selected: Int? = nil,
         dragging: Int? = nil, hovered: Int? = nil, requested: [EqBand]? = nil) {
        self.area = area
        self.bands = bands
        self.enabled = enabled
        self.selected = selected
        self.dragging = dragging
        self.hovered = hovered
        self.requested = requested
    }

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

    private enum Alignment {
        case left
        case center
        case right
    }

    private func label(_ cr: OpaquePointer, _ text: String, x: Double, y: Double,
                       align: Alignment = .left) {
        var extents = cairo_text_extents_t()
        cairo_text_extents(cr, text, &extents)
        switch align {
        case .left: cairo_move_to(cr, x, y)
        case .center: cairo_move_to(cr, x - extents.width / 2 - extents.x_bearing, y)
        case .right: cairo_move_to(cr, x - extents.width - extents.x_bearing, y)
        }
        cairo_show_text(cr, text)
    }

    mutating func draw(_ cr: OpaquePointer, _ w: Double, _ h: Double) {
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
        let enabled = enabled

        rounded(cr, 0.5, 0.5, w - 1, h - 1, 8)
        setColor(cr, surface, 1)
        cairo_fill_preserve(cr)
        cairo_save(cr)
        cairo_clip(cr)

        let plotW = CurvePlot.width(w)
        let plotH = CurvePlot.height(h)
        let sampleCount = max(Int(plotW / 2), 64)
        let values = EqCurveGeometry.response(bands: bands, count: sampleCount)
        range = EqCurveGeometry.plotRange(for: values)
        func yPos(_ db: Double) -> Double {
            EqCurveGeometry.yPosition(gain: db, range: range, height: plotH)
        }
        let levels = EqCurveGeometry.gridLevels(range: range)

        cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        cairo_set_font_size(cr, 10)

        cairo_save(cr)
        cairo_translate(cr, CurvePlot.left, CurvePlot.top)
        cairo_set_line_width(cr, 1)
        for db in levels {
            let y = yPos(db).rounded() + 0.5
            setColor(cr, foreground, db == 0 ? 0.35 : 0.13)
            cairo_move_to(cr, 0, y)
            cairo_line_to(cr, plotW, y)
            cairo_stroke(cr)
        }
        let frequencies = [50.0, 100, 200, 500, 1000, 2000, 5000, 10000]
        for frequency in frequencies {
            let x = (EqCurveGeometry.fraction(of: frequency) * plotW).rounded() + 0.5
            let major = [100.0, 1000, 10000].contains(frequency)
            setColor(cr, foreground, major ? 0.16 : 0.07)
            cairo_move_to(cr, x, 0)
            cairo_line_to(cr, x, plotH)
            cairo_stroke(cr)
        }

        let step = plotW / Double(max(values.count - 1, 1))
        let zero = yPos(0)
        cairo_move_to(cr, 0, yPos(values[0]))
        for (index, db) in values.enumerated() { cairo_line_to(cr, Double(index) * step, yPos(db)) }
        cairo_line_to(cr, plotW, zero)
        cairo_line_to(cr, 0, zero)
        cairo_close_path(cr)
        setColor(cr, enabled ? accent : foreground, enabled ? 0.22 : 0.08)
        cairo_fill(cr)

        cairo_set_line_width(cr, 2)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        cairo_move_to(cr, 0, yPos(values[0]))
        for (index, db) in values.enumerated() { cairo_line_to(cr, Double(index) * step, yPos(db)) }
        if enabled { setColor(cr, accent, 1) } else { setColor(cr, foreground, 0.5) }
        cairo_stroke(cr)

        if let requested {
            let asked = EqCurveGeometry.response(bands: requested, count: sampleCount)
            cairo_save(cr)
            var dashes: [Double] = [3, 2.5]
            cairo_set_dash(cr, &dashes, 2, 0)
            cairo_set_line_width(cr, 1)
            setColor(cr, foreground, 0.55)
            for (index, db) in asked.enumerated() {
                if index == 0 { cairo_move_to(cr, 0, yPos(db)) } else { cairo_line_to(cr, Double(index) * step, yPos(db)) }
            }
            cairo_stroke(cr)
            cairo_restore(cr)
        }

        for (index, band) in bands.enumerated() where band.filter != .bypass {
            let x = CurvePlot.x(Double(band.freq), plotW)
            let y = yPos(EqCurveGeometry.markerGain(band))
            let selected = selected == index
            let active = selected || dragging == index || hovered == index
            let radius = selected ? 6.5 : (active ? 6.0 : 4.5)
            cairo_new_path(cr)
            if selected {
                cairo_arc(cr, x, y, radius + 4, 0, 2 * Double.pi)
                setColor(cr, accent, 0.35)
                cairo_set_line_width(cr, 2)
                cairo_stroke(cr)
            }
            cairo_new_path(cr)
            cairo_arc(cr, x, y, radius, 0, 2 * Double.pi)
            setColor(cr, surface, 1)
            cairo_set_line_width(cr, 3.5)
            cairo_stroke_preserve(cr)
            if enabled { setColor(cr, accent, active ? 1 : 0.8) } else { setColor(cr, foreground, 0.55) }
            cairo_fill(cr)
            if active {
                cairo_set_font_size(cr, 11)
                setColor(cr, foreground, 0.9)
                let text = "\(index + 1)"
                let above = y > 24
                label(cr, text, x: x, y: above ? y - radius - 7 : y + radius + 14, align: .center)
                cairo_set_font_size(cr, 10)
            }
        }
        cairo_restore(cr)

        setColor(cr, foreground, 0.6)
        for db in levels {
            let y = CurvePlot.top + yPos(db).rounded() + 0.5
            let text = db == 0 ? "0 dB" : String(format: "%+.0f", db)
            label(cr, text, x: CurvePlot.left - 5, y: y + 3.5, align: .right)
        }
        for frequency in frequencies where [100.0, 1000, 10000].contains(frequency) {
            let x = CurvePlot.left + (EqCurveGeometry.fraction(of: frequency) * plotW).rounded() + 0.5
            let text = frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
            label(cr, text, x: x, y: h - 5, align: .center)
        }

        if !enabled {
            setColor(cr, foreground, 0.75)
            label(cr, "EQ off", x: w - 8, y: CurvePlot.top + 14, align: .right)
        }
        cairo_restore(cr)

        rounded(cr, 0.5, 0.5, w - 1, h - 1, 8)
        setColor(cr, foreground, 0.16)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
    }
}