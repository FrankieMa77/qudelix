import AppKit
import SwiftUI

/// The debounced saves and the 30-second exposure cadence assume someone
/// flushes the remainder at the end; without this hook, quitting always
/// discarded the last half-minute of listening history and any edit made in
/// the final half-second.
@MainActor
final class QuitFlushDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?
    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
}

@main
struct QudelixBarApp: App {
    @NSApplicationDelegateAdaptor(QuitFlushDelegate.self) private var quitDelegate
    @StateObject private var controller = QudelixController()
    /// App-owned, not popover-owned: the stage engine and the exposure meter
    /// must survive the popover closing.
    @StateObject private var stageState = StageState()
    /// Also app-owned: it has to notice an output change while the popover is
    /// closed, which is when swapping headphones actually happens.
    @StateObject private var profileRules = ProfileRules()
    /// The menu bar label's `onAppear` can fire more than once; starting twice
    /// would replace the BLE central while the old one still held the link.
    @State private var started = false

    init() {
        #if DEBUG
        UIPreview.runIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(controller)
                .environmentObject(stageState)
                .environmentObject(profileRules)
        } label: {
            // One composed template image, not an HStack of Images — the
            // menu bar item drops all but the first SF symbol when handed
            // several. Colour is stripped up there anyway, so battery state
            // is shapes and text: a bolt while charging, the battery glyph
            // plus the percentage once it runs low.
            HStack(spacing: 3) {
                Image(nsImage: NSImage.traySymbols(traySymbols))
                if let percent = trayPercent {
                    Text(percent)
                }
            }
            .onAppear {
                if !started {
                    started = true
                    controller.start()
                    stageState.start()

                    // The rules engine decides *what* should happen and this
                    // is the only place that lets it happen, so it can never
                    // reach the device except through the controller's own
                    // gated write path.
                    profileRules.onApplyPreset = { [weak controller] index in
                        controller?.loadPreset(index) ?? false
                    }
                    profileRules.presetLabel = { [weak controller] index in
                        controller?.presetLabel(index) ?? "Preset \(index + 1)"
                    }
                    // Switching silently is only ever allowed when there is
                    // nothing to lose by it: the device must be writable, the
                    // running curve must be a saved slot rather than an unsaved
                    // custom one, and no band may be mid-edit. When this is
                    // false an automatic rule degrades to asking.
                    profileRules.canApplyNow = { [weak controller, weak profileRules] in
                        guard let controller, controller.canWriteNow,
                              controller.activePreset != nil else { return false }
                        return profileRules?.editingNow != true
                    }
                    profileRules.start()
                    quitDelegate.onTerminate = { [weak stageState, weak controller] in
                        // A stale EQ snapshot doesn't just lose the last
                        // edit — the next connect restores over it.
                        controller?.flushEqSnapshot()
                        stageState?.saveNow()
                        stageState?.engine.stop()
                    }
                }
            }
            .onChange(of: trayTooltip, initial: true) { _, tip in
                Self.setTrayTooltip(tip)
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var connected: Bool {
        if case .connected = controller.connection { return true }
        return false
    }

    private var menuIcon: String {
        connected ? "headphones.circle.fill" : "headphones.circle"
    }

    private var traySymbols: [String] {
        var symbols = [menuIcon]
        if connected, let batt = controller.batteryPercent {
            if controller.charging {
                symbols.append("bolt.fill")
            } else if batt <= BatteryAlerts.veryLowThreshold {
                symbols.append("battery.0")
            } else if batt <= BatteryAlerts.lowThreshold {
                symbols.append("battery.25")
            }
        }
        return symbols
    }

    private var trayPercent: String? {
        guard connected, let batt = controller.batteryPercent, !controller.charging,
              batt <= BatteryAlerts.lowThreshold else { return nil }
        return "\(batt)%"
    }

    /// What hovering the menu bar item shows: charge, preset, link.
    private var trayTooltip: String {
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
                // A low battery outranks the charger state: "plugged in and
                // not charging" is useful, but if it is also nearly flat that
                // is the part that needs acting on, so both get said.
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
            lines.append("Preset: \(controller.presetLabel(idx))")
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

    /// MenuBarExtra exposes no NSStatusItem, so the tooltip goes onto the
    /// status item's window directly. Class-name check, not private API; if
    /// the window isn't found the tooltip is simply absent, nothing worse.
    private static func setTrayTooltip(_ text: String) {
        DispatchQueue.main.async {
            for window in NSApp.windows where window.className == "NSStatusBarWindow" {
                guard let view = window.contentView else { continue }
                view.toolTip = text
                for sub in view.subviews { sub.toolTip = text }
            }
        }
    }
}

extension NSImage {
    /// The given SF symbols drawn side by side as one template image, sized
    /// for the menu bar. Drawn through a drawingHandler so it re-rasterises
    /// at the screen's actual scale instead of shipping a 1x bitmap.
    /// Composed images are cached: the label re-evaluates on every publish
    /// (once a second while the meter runs), and a fresh NSImage instance
    /// defeats SwiftUI's diffing, redrawing the status item each time. The
    /// cache key is the symbol list — a handful of distinct states, ever.
    private static var trayCache: [String: NSImage] = [:]

    static func traySymbols(_ names: [String]) -> NSImage {
        let key = names.joined(separator: "|")
        if let cached = trayCache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let images = names.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        }
        let spacing: CGFloat = 2
        let height = images.map(\.size.height).max() ?? 18
        let width = images.map(\.size.width).reduce(0, +)
            + spacing * CGFloat(max(images.count - 1, 0))
        let composed = NSImage(size: NSSize(width: width, height: height),
                               flipped: false) { _ in
            var x: CGFloat = 0
            for image in images {
                image.draw(in: NSRect(x: x, y: (height - image.size.height) / 2,
                                      width: image.size.width,
                                      height: image.size.height))
                x += image.size.width + spacing
            }
            return true
        }
        composed.isTemplate = true
        trayCache[key] = composed
        return composed
    }
}
