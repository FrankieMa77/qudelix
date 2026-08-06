import SwiftUI

@main
struct QudelixBarApp: App {
    @StateObject private var controller = QudelixController()
    /// App-owned, not popover-owned: the stage engine and the exposure meter
    /// must survive the popover closing.
    @StateObject private var stageState = StageState()
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
        } label: {
            // The menu bar renders template-style (no colour), so battery
            // state is shown with shapes and text: a bolt while charging,
            // the battery glyph plus the percentage once it runs low.
            HStack(spacing: 3) {
                Image(systemName: menuIcon)
                if case .connected = controller.connection,
                   let batt = controller.batteryPercent {
                    if controller.charging {
                        Image(systemName: "bolt.fill")
                    } else if batt <= BatteryAlerts.veryLowThreshold {
                        Image(systemName: "battery.0")
                        Text("\(batt)%")
                    } else if batt <= BatteryAlerts.lowThreshold {
                        Image(systemName: "battery.25")
                        Text("\(batt)%")
                    }
                }
            }
            .onAppear {
                if !started {
                    started = true
                    controller.start()
                    stageState.start()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuIcon: String {
        if case .connected = controller.connection { return "headphones.circle.fill" }
        return "headphones.circle"
    }
}
