import AppKit
import Combine

enum StatusIcon {
    struct State: Equatable, Hashable {
        var connected = false
        var eqEnabled = true
        var stageOn = false
        var quality: Quality = .unknown
        var batteryLow = false
        var charging = false
        var onCall = false

        enum Quality: Equatable, Hashable { case hi, low, unknown }

        static func from(connected: Bool,
                         eqEnabled: Bool,
                         stageOn: Bool,
                         verdict: QualityAnalyzer.Verdict?,
                         batteryPercent: Int?,
                         charging: Bool,
                         onCall: Bool) -> State {
            var s = State()
            s.connected = connected
            s.eqEnabled = eqEnabled
            s.stageOn = stageOn
            switch verdict?.isLosslessClass {
            case true?: s.quality = .hi
            case false?: s.quality = .low
            default: s.quality = .unknown
            }
            s.onCall = onCall
            guard connected else { return s }
            s.charging = charging
            if let batteryPercent { s.batteryLow = batteryPercent <= BatteryAlerts.lowThreshold }
            return s
        }
    }

    static func describe(_ state: State) -> String {
        guard state.connected else {
            return state.onCall ? "Qudelix — no device connected, on a call"
                                : "Qudelix — no device connected"
        }
        var parts = ["Qudelix connected"]
        parts.append(state.eqEnabled ? "EQ on" : "EQ off")
        if state.stageOn { parts.append("Soundstage on") }
        if state.onCall {
            parts.append("on a call")
        } else {
            switch state.quality {
            case .hi: parts.append("lossless-quality stream")
            case .low: parts.append("lossy stream")
            case .unknown: break
            }
        }
        if state.batteryLow { parts.append("battery low") }
        if state.charging { parts.append("charging") }
        return parts.joined(separator: ", ")
    }

    private static let canvasSize = NSSize(width: 18, height: 18)
    private static var cache: [State: NSImage] = [:]

    @MainActor
    static func image(for state: State) -> NSImage {
        if let hit = cache[state] { return hit }
        let image = NSImage(size: canvasSize, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            NSColor.black.setFill()
            NSColor.black.setStroke()

            let dimmed = !state.connected
            if dimmed {
                ctx.setAlpha(0.45)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            }

            drawBase(eqEnabled: state.eqEnabled)
            if state.stageOn { drawStage() }
            if !state.onCall { drawQualityBadge(state.quality) }
            drawBatteryBadge(low: state.batteryLow, charging: state.charging)

            if dimmed {
                ctx.endTransparencyLayer()
                ctx.setAlpha(1)
            }
            if state.onCall { drawCallBadge() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = describe(state)
        cache[state] = image
        return image
    }

    private static let center = NSPoint(x: 9, y: 9)
    private static let ringRadius: CGFloat = 6.8

    private static func drawBase(eqEnabled: Bool) {
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - ringRadius, y: center.y - ringRadius,
                                               width: ringRadius * 2, height: ringRadius * 2))
        ring.lineWidth = 1.3
        ring.stroke()

        let band = NSBezierPath()
        band.lineWidth = 1.4
        band.lineCapStyle = .round
        band.appendArc(withCenter: NSPoint(x: 9, y: 8.6), radius: 3.6,
                       startAngle: 0, endAngle: 180)
        band.stroke()

        for cupX in [CGFloat(5.4), CGFloat(12.6)] {
            let cup = NSBezierPath(roundedRect: NSRect(x: cupX - 1.05, y: 5.2,
                                                       width: 2.1, height: 3.6),
                                   xRadius: 0.9, yRadius: 0.9)
            if eqEnabled {
                cup.fill()
            } else {
                cup.lineWidth = 1.0
                cup.stroke()
            }
        }
    }

    private static func drawStage() {
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: 0.9, y: 6.2)); path.line(to: NSPoint(x: 0.9, y: 11.8))
        path.move(to: NSPoint(x: 17.1, y: 6.2)); path.line(to: NSPoint(x: 17.1, y: 11.8))
        path.stroke()
    }

    private static func knockout(center: NSPoint, radius: CGFloat) {
        guard let gc = NSGraphicsContext.current else { return }
        let previous = gc.compositingOperation
        gc.compositingOperation = .destinationOut
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
        gc.compositingOperation = previous
    }

    private static let qualityCenter = NSPoint(x: 14.3, y: 14.3)

    private static func drawQualityBadge(_ quality: State.Quality) {
        switch quality {
        case .unknown:
            return
        case .hi:
            knockout(center: qualityCenter, radius: 3.7)
            drawSparkle(center: qualityCenter)
        case .low:
            knockout(center: qualityCenter, radius: 2.6)
            let circle = NSBezierPath(ovalIn: NSRect(x: qualityCenter.x - 1.65,
                                                     y: qualityCenter.y - 1.65,
                                                     width: 3.3, height: 3.3))
            circle.lineWidth = 1.1
            circle.stroke()
        }
    }

    private static func drawCallBadge() {
        knockout(center: qualityCenter, radius: 4.3)
        let handset = NSBezierPath()
        handset.appendRoundedRect(NSRect(x: -2.5, y: -0.65, width: 5.0, height: 1.3),
                                  xRadius: 0.6, yRadius: 0.6)
        handset.appendRoundedRect(NSRect(x: -2.6, y: -1.9, width: 1.7, height: 2.3),
                                  xRadius: 0.7, yRadius: 0.7)
        handset.appendRoundedRect(NSRect(x: 0.9, y: -1.9, width: 1.7, height: 2.3),
                                  xRadius: 0.7, yRadius: 0.7)
        var placement = AffineTransform(translationByX: qualityCenter.x,
                                        byY: qualityCenter.y)
        placement.rotate(byDegrees: -45)
        handset.transform(using: placement)
        handset.windingRule = .nonZero
        handset.fill()
    }

    private static func addQuadCurve(_ path: NSBezierPath, to end: NSPoint, control: NSPoint) {
        let start = path.currentPoint
        let cp1 = NSPoint(x: start.x + (control.x - start.x) * 2 / 3,
                          y: start.y + (control.y - start.y) * 2 / 3)
        let cp2 = NSPoint(x: end.x + (control.x - end.x) * 2 / 3,
                          y: end.y + (control.y - end.y) * 2 / 3)
        path.curve(to: end, controlPoint1: cp1, controlPoint2: cp2)
    }

    private static func drawSparkle(center: NSPoint) {
        let tip: CGFloat = 2.9
        let pinch: CGFloat = 0.85
        let north = NSPoint(x: center.x, y: center.y + tip)
        let east = NSPoint(x: center.x + tip, y: center.y)
        let south = NSPoint(x: center.x, y: center.y - tip)
        let west = NSPoint(x: center.x - tip, y: center.y)
        let ne = NSPoint(x: center.x + pinch, y: center.y + pinch)
        let se = NSPoint(x: center.x + pinch, y: center.y - pinch)
        let sw = NSPoint(x: center.x - pinch, y: center.y - pinch)
        let nw = NSPoint(x: center.x - pinch, y: center.y + pinch)

        let path = NSBezierPath()
        path.move(to: north)
        addQuadCurve(path, to: east, control: ne)
        addQuadCurve(path, to: south, control: se)
        addQuadCurve(path, to: west, control: sw)
        addQuadCurve(path, to: north, control: nw)
        path.close()
        path.fill()
    }

    private static let batteryCenter = NSPoint(x: 13.9, y: 3.6)
    private static let batteryBody = NSRect(x: 10.7, y: 1.75, width: 6.0, height: 3.7)

    private static func drawBatteryBadge(low: Bool, charging: Bool) {
        guard low || charging else { return }
        knockout(center: batteryCenter, radius: 4.3)
        if low {
            let body = NSBezierPath(roundedRect: batteryBody, xRadius: 0.8, yRadius: 0.8)
            body.lineWidth = 0.9
            body.stroke()
            NSBezierPath(rect: NSRect(x: batteryBody.maxX + 0.15, y: batteryCenter.y - 0.75,
                                      width: 0.9, height: 1.5)).fill()
            if charging {
                drawBolt(in: batteryBody.insetBy(dx: 1.95, dy: 0.75))
            }
        } else {
            drawBolt(in: NSRect(x: batteryCenter.x - 1.9, y: batteryCenter.y - 3.1,
                                width: 3.8, height: 6.2))
        }
    }

    private static func drawBolt(in rect: NSRect) {
        let unit: [NSPoint] = [
            NSPoint(x: 0.58, y: 1.00), NSPoint(x: 0.00, y: 0.46), NSPoint(x: 0.36, y: 0.46),
            NSPoint(x: 0.30, y: 0.00), NSPoint(x: 1.00, y: 0.58), NSPoint(x: 0.60, y: 0.58),
        ]
        let path = NSBezierPath()
        for (i, p) in unit.enumerated() {
            let point = NSPoint(x: rect.minX + p.x * rect.width,
                                y: rect.minY + p.y * rect.height)
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        path.fill()
    }
}

@MainActor
final class StatusIconModel: ObservableObject {
    struct Presentation: Equatable {
        var icon = StatusIcon.State()
        var title: String?
        var tooltip = ""
        var accessibility = ""
    }

    @Published private(set) var presentation = Presentation()

    private weak var controller: QudelixController?
    private weak var stage: StageState?
    private var sources: Set<AnyCancellable> = []
    private var pending = false

    func follow(controller: QudelixController, stage: StageState) {
        self.controller = controller
        self.stage = stage
        controller.objectWillChange
            .sink { [weak self] _ in self?.schedule() }
            .store(in: &sources)
        stage.onStatusChange = { [weak self] in self?.schedule() }
        refresh()
    }

    private func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.refresh()
        }
    }

    func refresh() {
        guard let controller else { return }
        var connected = false
        if case .connected = controller.connection { connected = true }
        let icon = StatusIcon.State.from(
            connected: connected,
            eqEnabled: controller.eqEnabled,
            stageOn: stage?.stage.enabled ?? false,
            verdict: stage?.qualityVerdictLive,
            batteryPercent: controller.batteryPercent,
            charging: controller.charging,
            onCall: stage?.callActiveLive ?? false)
        let next = Presentation(icon: icon,
                                title: Self.title(controller),
                                tooltip: Self.tooltip(controller),
                                accessibility: StatusIcon.describe(icon))
        if presentation != next { presentation = next }
    }

    private static func title(_ controller: QudelixController) -> String? {
        guard case .connected = controller.connection,
              let batt = controller.batteryPercent, !controller.charging,
              batt <= BatteryAlerts.lowThreshold else { return nil }
        return "\(batt)%"
    }

    static func tooltip(_ controller: QudelixController) -> String {
        guard case .connected(let rawName) = controller.connection else {
            return "Qudelix — no device connected"
        }
        let cleaned = QudelixController.displayName(
            rawName.replacingOccurrences(of: " USB DAC 96KHz", with: ""))
        var lines = [cleaned.isEmpty ? "Qudelix" : cleaned]
        if let batt = controller.batteryPercent {
            var line = "Battery \(batt)%"
            if controller.charging {
                line += " — charging"
            } else {
                if batt <= BatteryAlerts.veryLowThreshold {
                    line += " — very low"
                } else if batt <= BatteryAlerts.lowThreshold {
                    line += " — low"
                }
                if controller.chargerConnected {
                    line += batt <= BatteryAlerts.lowThreshold
                        ? " (plugged in, not charging)" : " — plugged in, not charging"
                }
            }
            lines.append(line)
        }
        if let idx = controller.activePreset {
            lines.append("Preset: " + controller.presetLabel(idx))
        } else {
            lines.append("Preset: custom")
        }
        switch controller.link {
        case .usb: lines.append("Connected over USB")
        case .bluetooth: lines.append("Connected over Bluetooth")
        case .none: break
        }
        return lines.joined(separator: "\n")
    }
}
