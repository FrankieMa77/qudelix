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
            Image(systemName: menuIcon)
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
