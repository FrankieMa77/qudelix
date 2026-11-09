import CGtk
import Foundation
import QudelixBar

@MainActor
enum TrayDump {
    @MainActor
    private final class Job {
        let model: AppModel
        let tray: TrayModel
        let path: String
        let application: UnsafeMutableRawPointer
        let expectsDevice: Bool
        var attempts = 0

        init(model: AppModel, tray: TrayModel, path: String, application: UnsafeMutableRawPointer,
             expectsDevice: Bool) {
            self.model = model
            self.tray = tray
            self.path = path
            self.application = application
            self.expectsDevice = expectsDevice
        }

        var ready: Bool {
            let state = model.state
            if !expectsDevice { return state.connection == .searching }
            return state.connection.isConnected
                && model.presets.state.slots.count == PresetSlotsModel.slotCount
                && model.presets.state.slots[2].name != nil
        }

        var text: String {
            var lines = ["tooltip: \(tray.appearance.toolTipTitle)",
                         "tooltip text: \(tray.appearance.toolTipText)",
                         "icon: \(tray.appearance.iconName)",
                         "status: \(tray.appearance.status)",
                         "menu:"]
            lines += tray.menu.lines.map { "  " + $0 }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    static func run(model: AppModel, path: String, application: UnsafeMutableRawPointer, expectsDevice: Bool) {
        let tray = TrayModel(model: model, iconName: AppIcon.trayName(), open: {}, quit: {})
        g_application_hold(application.assumingMemoryBound(to: GApplication.self))
        model.start()
        let job = Job(model: model, tray: tray, path: path, application: application, expectsDevice: expectsDevice)
        g_timeout_add(100, { data in
            let job = Unmanaged<Job>.fromOpaque(data!).takeUnretainedValue()
            var finished = false
            onMain {
                job.attempts += 1
                guard job.ready || job.attempts >= 100 else { return }
                try? job.text.write(toFile: job.path, atomically: true, encoding: .utf8)
                finished = true
            }
            guard finished else { return 1 }
            g_application_quit(job.application.assumingMemoryBound(to: GApplication.self))
            Unmanaged<Job>.fromOpaque(data!).release()
            return 0
        }, Unmanaged.passRetained(job).toOpaque())
    }
}
