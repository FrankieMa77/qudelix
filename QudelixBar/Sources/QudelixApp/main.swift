import CGtk
import Foundation
import QudelixAudio
import QudelixBar
import QudelixGtk

MainLoopBridge.install()

let options = LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
if options.version {
    print("\(AppInfo.executable) \(AppInfo.version)")
    exit(0)
}
if options.help {
    print(LaunchOptions.usage)
    exit(0)
}
let flags = options.render == nil && options.trayDump == nil ? G_APPLICATION_DEFAULT_FLAGS : G_APPLICATION_NON_UNIQUE
let application = adw_application_new("io.github.FrankieMa77.Qudelix", flags)!

let model: AppModel = MainActor.assumeIsolated {
    if options.demo { return AppModel.demo(power: options.power, activeSlot: options.customEq ? nil : 5) }
    if options.noDevice { return AppModel.noDevice() }
    return AppModel(makeLinks: { makeLinks(preferred: nil) }, batteryStore: .system)
}

let audio: AudioStack = MainActor.assumeIsolated {
    let isolated = options.demo || options.noDevice || options.render != nil || options.trayDump != nil
    if isolated {
        let locations = AudioStackLocations.isolated(in: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qudelix-render-\(UUID().uuidString)", isDirectory: true))
        return AudioStack(app: model, backend: options.noAudio ? nil : DemoAudioBackend(), locations: locations)
    }
    return AudioStack(app: model, backendFactory: { try? PipeWireAudioBackend() })
}

Signals.connect(application, signal: "activate") {
    onMain {
        if let routing = audio.routing { model.library.saved.attach(routing: routing) }
        if let stage = audio.stage { model.library.autoEq.attach(level: stage.level) }
        model.library.suggestions.attach(automation: audio.automation)
        audio.start()
        if let path = options.trayDump {
            TrayDump.run(model: model, path: path, application: application.raw, expectsDevice: options.demo)
        } else {
            AppWindow.present(for: application, options: options, model: model, audio: audio)
        }
    }
}

Signals.connect(application, signal: "shutdown") {
    onMain {
        model.library.saved.flushPendingWrites()
        var finished = false
        Task { @MainActor in
            await audio.shutdown()
            finished = true
        }
        let deadline = Date().addingTimeInterval(3)
        while !finished && Date() < deadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            usleep(5_000)
        }
    }
}

UnixSignals.onTerminate {
    g_application_quit(UnsafeMutablePointer<GApplication>(OpaquePointer(application)))
}

AppMenu.installOnMain(application: application)

let quit = g_simple_action_new("quit", nil)!
Signals.onActivate(quit) {
    g_application_quit(UnsafeMutablePointer<GApplication>(OpaquePointer(application)))
}
g_action_map_add_action(application.opaque, quit.opaque)
"<Primary>q".withCString { accelerator in
    var accelerators: [UnsafePointer<CChar>?] = [accelerator, nil]
    gtk_application_set_accels_for_action(application.raw.assumingMemoryBound(to: GtkApplication.self),
                                          "app.quit", &accelerators)
}

var arguments: [UnsafeMutablePointer<CChar>?] = [strdup(CommandLine.arguments[0]), nil]
let status = g_application_run(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), 1, &arguments)
exit(status)
