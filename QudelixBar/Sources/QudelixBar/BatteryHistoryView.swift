import AppKit
import SwiftUI

struct BatteryHistoryView: View {
    @EnvironmentObject var controller: QudelixController

    var body: some View {
        BatteryHistoryBody(log: controller.batteryLog)
    }
}

struct BatteryTickSchedule: TimelineSchedule {
    var live: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        guard live else { return AnySequence([startDate]) }
        return AnySequence(PeriodicTimelineSchedule(from: startDate, by: 60)
            .entries(from: startDate, mode: mode))
    }
}

struct BatteryHistoryBody: View {
    @EnvironmentObject var controller: QudelixController
    @ObservedObject var log: BatteryLog
    @AppStorage("batteryHistoryWindow") private var windowRaw = BatteryHistory.Window.day.rawValue
    @State private var popoverShown = true

    private var window: BatteryHistory.Window {
        BatteryHistory.Window(rawValue: windowRaw) ?? .day
    }

    var body: some View {
        TimelineView(BatteryTickSchedule(live: popoverShown)) { context in
            let now = context.date
            let plot = log.history.plot(window: window, now: now)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Battery")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Picker("Window", selection: $windowRaw) {
                        ForEach(BatteryHistory.Window.allCases) { w in
                            Text(verbatim: w.label).tag(w.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel("Graph window")
                }

                Text(verbatim: headline(now: now))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                BatteryChart(plot: plot,
                             ticks: window.ticks(now: now).map {
                                 (x: 1 - now.timeIntervalSince($0) / window.seconds,
                                  label: window.tickLabel($0))
                             })
                    .frame(height: 118)
                    .accessibilityLabel(Text(verbatim: Self.chartAccessibility(plot: plot, window: window)))

                Text(verbatim: footnote(now: now))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { _ in
            popoverShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in
            popoverShown = false
        }
    }

    private func headline(now: Date) -> String {
        guard let percent = controller.batteryPercent else {
            return "The 5K is not connected — the graph shows what was recorded while it was."
        }
        var parts = ["\(percent)%"]
        if controller.charging {
            parts.append("charging")
        } else if controller.chargerConnected {
            parts.append("plugged in, not charging")
        } else {
            let history = log.history
            if let since = history.onBatterySince {
                let prefix = history.runStartsAtHistoryStart ? "on battery for at least " : "on battery for "
                parts.append(prefix + Self.duration(now.timeIntervalSince(since)))
            } else {
                parts.append("on battery")
            }
            if let drain = history.drain(now: now) {
                parts.append(String(format: "draining %.1f%%/h", drain.percentPerHour))
                if let left = drain.hoursLeft, left.isFinite, left < 24 * 14 {
                    parts.append("about " + Self.duration(left * 3600) + " left")
                }
            } else if history.currentRun.count >= 1 {
                parts.append("measuring the drain rate")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func footnote(now: Date) -> String {
        let history = log.history
        guard let first = history.firstReading else {
            return "Nothing recorded yet. A reading is kept every time the level changes and at least every ten minutes while the 5K is connected, for seven days."
        }
        let since = first.formatted(date: .abbreviated, time: .shortened)
        let count = history.readingCount
        return "Recording since \(since) · \(count) reading\(count == 1 ? "" : "s") · kept for seven days. Shaded bands mark charging; breaks mark time away."
    }

    static func chartAccessibility(plot: BatteryHistory.Plot, window: BatteryHistory.Window) -> String {
        if plot.isEmpty { return "Battery graph, nothing recorded in the last \(window.label)" }
        var text = "Battery graph over the last \(window.label)"
        if let latest = plot.latest {
            let percent = latest.y.isNaN ? 0 : min(max(latest.y, 0), 100)
            text += ", now \(Int(percent.rounded())) percent"
        }
        return text
    }

    static let maxDurationSeconds: TimeInterval = 1e9

    static func duration(_ seconds: TimeInterval) -> String {
        let bounded = seconds.isNaN ? 0 : min(max(seconds, 0), maxDurationSeconds)
        let total = Int(bounded.rounded())
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return hours > 0 ? "\(days) d \(hours) h" : "\(days) d" }
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
        return "\(max(1, minutes)) min"
    }
}

struct BatteryChart: View {
    var plot: BatteryHistory.Plot
    var ticks: [(x: Double, label: String)]

    private let rightInset: CGFloat = 30
    private let bottomInset: CGFloat = 13
    private let topInset: CGFloat = 4

    var body: some View {
        Canvas { ctx, size in
            let plotWidth = size.width - rightInset
            let plotHeight = size.height - bottomInset - topInset
            func px(_ x: Double) -> CGFloat { CGFloat(max(0, min(1, x))) * plotWidth }
            func py(_ y: Double) -> CGFloat {
                topInset + plotHeight - CGFloat(max(0, min(100, y)) / 100) * plotHeight
            }

            for span in plot.chargingSpans {
                let rect = CGRect(x: px(span.lowerBound), y: topInset,
                                  width: px(span.upperBound) - px(span.lowerBound), height: plotHeight)
                ctx.fill(Path(rect), with: .color(.green.opacity(0.12)))
            }

            for level in stride(from: 0, through: 100, by: 25) {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: py(Double(level))))
                line.addLine(to: CGPoint(x: plotWidth, y: py(Double(level))))
                ctx.stroke(line, with: .color(.secondary.opacity(level == 0 || level == 100 ? 0.35 : 0.14)),
                           lineWidth: 0.5)
                if level % 50 == 0 {
                    ctx.draw(Text(verbatim: "\(level)%").font(.system(size: 8)).foregroundStyle(.secondary),
                             at: CGPoint(x: plotWidth + rightInset / 2 + 1, y: py(Double(level))))
                }
            }

            var lowLine = Path()
            lowLine.move(to: CGPoint(x: 0, y: py(Double(BatteryAlerts.lowThreshold))))
            lowLine.addLine(to: CGPoint(x: plotWidth, y: py(Double(BatteryAlerts.lowThreshold))))
            ctx.stroke(lowLine, with: .color(.orange.opacity(0.4)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

            for tick in ticks {
                let tx = px(tick.x)
                var line = Path()
                line.move(to: CGPoint(x: tx, y: topInset))
                line.addLine(to: CGPoint(x: tx, y: topInset + plotHeight))
                ctx.stroke(line, with: .color(.secondary.opacity(0.14)), lineWidth: 0.5)
                if tx > 14, tx < plotWidth - 14 {
                    ctx.draw(Text(verbatim: tick.label).font(.system(size: 8)).foregroundStyle(.secondary),
                             at: CGPoint(x: tx, y: size.height - bottomInset / 2))
                }
            }

            for points in plot.lines {
                var curve = Path()
                for (i, p) in points.enumerated() {
                    let point = CGPoint(x: px(p.x), y: py(p.y))
                    i == 0 ? curve.move(to: point) : curve.addLine(to: point)
                }
                var fill = curve
                fill.addLine(to: CGPoint(x: px(points[points.count - 1].x), y: py(0)))
                fill.addLine(to: CGPoint(x: px(points[0].x), y: py(0)))
                fill.closeSubpath()
                ctx.fill(fill, with: .linearGradient(
                    Gradient(colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.03)]),
                    startPoint: CGPoint(x: 0, y: topInset), endPoint: CGPoint(x: 0, y: topInset + plotHeight)))
                ctx.stroke(curve, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }

            if let latest = plot.latest {
                let dot = CGRect(x: px(latest.x) - 2.5, y: py(latest.y) - 2.5, width: 5, height: 5)
                ctx.fill(Path(ellipseIn: dot), with: .color(.accentColor))
            }

            if plot.isEmpty {
                ctx.draw(Text("No readings in this window yet").font(.system(size: 10)).foregroundStyle(.secondary),
                         at: CGPoint(x: plotWidth / 2, y: topInset + plotHeight / 2))
            }
        }
    }
}
