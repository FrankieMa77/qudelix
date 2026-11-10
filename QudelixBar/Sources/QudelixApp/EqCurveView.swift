import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@MainActor
final class EqCurveView {
    let area: UnsafeMutablePointer<GtkWidget>

    private let model: EqEditorModel
    private var state = EqEditorState()
    private var width = 0.0
    private var height = 0.0
    private var range = 9.0
    private var dragging: Int?
    private var dragOrigin: EqBand?
    private var dragRange = 9.0
    private var hovered: Int?
    private var pointer: (x: Double, y: Double)?

    var onSettled: ((Int) -> Void)?

    private var referenceLine: AutomationLine?
    private var trimLine: AutomationLine?

    private static let grabRadius = 20.0

    init(model: EqEditorModel) {
        self.model = model
        area = Accessible.drawingArea(role: GTK_ACCESSIBLE_ROLE_IMG)
        gtk_widget_set_hexpand(area, 1)
        gtk_widget_set_size_request(area, 240, 220)
        gtk_widget_set_focusable(area, 0)
        Accessible.setLabel(area, "Equalizer curve")
        gtk_widget_set_tooltip_text(area, "Drag a handle for frequency and gain. Scroll on it to change Q. Double-click to zero its gain.")
        Signals.setDrawFunc(area) { [weak self] cr, width, height in
            onMain { self?.draw(cr, Double(width), Double(height)) }
        }
        install()
    }

    func setLines(reference: AutomationLine?, trim: AutomationLine?) {
        guard reference != referenceLine || trim != trimLine else { return }
        referenceLine = reference
        trimLine = trim
        gtk_widget_queue_draw(area)
    }

    func update(_ state: EqEditorState) {
        self.state = state
        let selected = state.selected.flatMap { state.bands.indices.contains($0) ? $0 : nil }
        var description = "\(state.bandCount) bands, \(state.enabled ? "equalizer on" : "equalizer off")"
        if let selected {
            description += ". Band \(selected + 1) selected: \(state.bands[selected].filter.label), \(state.bands[selected].summary)"
        }
        if let gap = state.divergence() {
            description += String(format: ". The requested curve differs by up to %.1f dB", abs(gap.peak))
        }
        Accessible.setDescription(area, description)
        if let hovered, !state.bands.indices.contains(hovered) { self.hovered = nil }
        gtk_widget_queue_draw(area)
    }

    private func hit(_ x: Double, _ y: Double) -> Int? {
        let clamped = state.bands.map { band -> EqBand in
            var copy = band
            copy.freq = min(copy.freq, Int(EqCurveGeometry.maxFrequency))
            return copy
        }
        return EqCurveGeometry.nearestBand(x: x - CurvePlot.left, y: y - CurvePlot.top, in: clamped,
                                           width: width, height: height, range: range,
                                           grabRadius: Self.grabRadius)
    }

    private func install() {
        Signals.addClick(to: area) { [weak self] count, x, y in
            onMain {
                guard let self else { return }
                let band = self.hit(x, y)
                self.model.select(band)
                if count == 2, let band { self.model.zeroBand(band) }
            }
        }
        Signals.addDrag(to: area, begin: { [weak self] x, y in
            onMain {
                guard let self, let band = self.hit(x, y) else { return }
                self.dragging = band
                self.dragOrigin = self.state.bands[band]
                self.dragRange = self.range
                self.model.select(band)
            }
        }, update: { [weak self] dx, dy, fine in
            onMain {
                guard let self, let band = self.dragging, let origin = self.dragOrigin,
                      self.state.bands.indices.contains(band) else { return }
                let moved = EqCurveGeometry.dragged(origin, index: band, in: self.state.bands,
                                                    dx: dx, dy: dy, width: self.width,
                                                    height: self.height, range: self.dragRange,
                                                    fine: fine)
                self.model.setBand(band, moved)
            }
        }, end: { [weak self] _, _ in
            onMain {
                let settled = self?.dragging
                self?.dragging = nil
                self?.dragOrigin = nil
                if let settled { self?.onSettled?(settled) }
            }
        })
        Signals.addMotion(to: area, move: { [weak self] x, y in
            onMain {
                guard let self else { return }
                self.pointer = (x, y)
                let band = self.hit(x, y)
                if band != self.hovered {
                    self.hovered = band
                    gtk_widget_queue_draw(self.area)
                }
            }
        }, leave: { [weak self] in
            onMain {
                guard let self else { return }
                self.pointer = nil
                if self.hovered != nil {
                    self.hovered = nil
                    gtk_widget_queue_draw(self.area)
                }
            }
        })
        Signals.addScroll(to: area) { [weak self] _, dy in
            var consumed = false
            onMain {
                guard let self, let pointer = self.pointer, let band = self.hit(pointer.x, pointer.y),
                      self.state.bands.indices.contains(band) else { return }
                self.model.select(band)
                self.model.setBand(band, EqCurveGeometry.scrolledQ(self.state.bands[band], steps: dy))
                consumed = true
            }
            return consumed
        }
    }

    private func draw(_ cr: OpaquePointer, _ w: Double, _ h: Double) {
        width = CurvePlot.width(w)
        height = CurvePlot.height(h)
        var drawing = CurveDrawing(area: area, bands: state.bands, enabled: state.enabled,
                                   selected: state.selected, dragging: dragging, hovered: hovered,
                                   requested: state.requested)
        let current = state
        drawing.divergence = { count in current.divergence(count: count) }
        drawing.referenceLine = referenceLine
        drawing.trimLine = trimLine
        drawing.draw(cr, w, h)
        range = drawing.range
    }
}
