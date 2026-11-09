import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@MainActor
final class TrayService {
    private let tray: TrayModel
    private var notifier: StatusNotifier?

    private static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    init(model: AppModel, controller: WindowController, application: UnsafeMutableRawPointer) {
        tray = TrayModel(model: model,
                         iconName: AppIcon.trayName(),
                         open: { controller.show() },
                         quit: { g_application_quit(application.assumingMemoryBound(to: GApplication.self)) })
        var error: UnsafeMutablePointer<GError>?
        guard let connection = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, &error) else {
            g_clear_error(&error)
            Self.note("no session bus; the tray icon is unavailable")
            controller.trayUnavailable()
            return
        }
        let notifier = StatusNotifier(connection: connection)
        notifier.onActivate = { onMain { controller.show() } }
        notifier.onAction = { [tray] action in onMain { tray.perform(action) } }
        notifier.onWatcherChanged = { present in onMain { controller.watcherChanged(present) } }
        do {
            try notifier.start()
        } catch {
            Self.note("tray icon could not start: \(error)")
            controller.trayUnavailable()
            return
        }
        self.notifier = notifier
        tray.addObserver { [weak notifier] tray in
            notifier?.update(menu: tray.menu)
            notifier?.update(appearance: tray.appearance)
        }
    }
}
