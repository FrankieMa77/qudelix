import Foundation

package struct AudioStackLocations {
    package var stageSettings: URL
    package var routingMemory: URL?
    package var impulseDirectory: (() -> URL)?
    package var autofit: URL

    package init(stageSettings: URL, routingMemory: URL?, impulseDirectory: (() -> URL)?, autofit: URL) {
        self.stageSettings = stageSettings
        self.routingMemory = routingMemory
        self.impulseDirectory = impulseDirectory
        self.autofit = autofit
    }

    package static var system: AudioStackLocations {
        AudioStackLocations(stageSettings: StageStateFile.url,
                            routingMemory: OutputRouting.defaultMemoryURL(),
                            impulseDirectory: nil,
                            autofit: AutofitFile.url)
    }

    package static func isolated(in directory: URL) -> AudioStackLocations {
        AudioStackLocations(stageSettings: directory.appendingPathComponent("stage.json"),
                            routingMemory: directory.appendingPathComponent("routing.json"),
                            impulseDirectory: { directory.appendingPathComponent("impulses", isDirectory: true) },
                            autofit: directory.appendingPathComponent("autofit.json"))
    }
}

@MainActor
package final class AudioStack {
    package static let unavailableMessage =
        "Needs PipeWire. The audio server could not be reached, so this part of Qudelix is off. "
        + "Everything that talks to the 5K still works."

    package let app: AppModel
    package let backend: LinuxAudioBackend?
    package let routing: OutputRouting?
    package let stage: StageModel?
    package let automation: AutomationModel
    package let tune: TuneModel
    private var started = false
    private var stopped = false

    package var available: Bool { stage != nil }

    package init(app: AppModel,
                 backend: LinuxAudioBackend?,
                 locations: AudioStackLocations = .system,
                 clock: AppClock = SystemClock(),
                 hop: @escaping OutputRouting.Hop = OutputRouting.mainHop) {
        self.app = app
        self.backend = backend
        if let backend {
            let routing = OutputRouting(backend: backend, clock: clock, hop: hop,
                                        memoryURL: locations.routingMemory)
            let stage = StageModel(backend: backend, routing: routing, clock: clock,
                                   settingsURL: locations.stageSettings,
                                   impulseDirectory: locations.impulseDirectory)
            stage.reporter = app
            self.routing = routing
            self.stage = stage
        } else {
            routing = nil
            stage = nil
        }
        automation = AutomationModel(app: app, stage: stage, url: locations.autofit)
        tune = TuneModel(app: app, routing: routing, backend: backend, stage: stage, automation: automation)
    }

    package func start() {
        guard !started, !stopped else { return }
        started = true
        stage?.start()
    }

    package func shutdown() async {
        guard !stopped else { return }
        stopped = true
        tune.shutdown()
        automation.shutdown()
        stage?.shutdown()
        backend?.shutdown()
        await app.shutdown()
    }
}
