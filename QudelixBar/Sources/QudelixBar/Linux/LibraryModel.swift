import Foundation

@MainActor
package final class LibraryModel {
    package let saved: SavedPresetsModel
    package let autoEq: AutoEqSearchModel
    package let ai: AiStudioModel

    init(host: AppModel, environment: LibraryEnvironment) {
        saved = SavedPresetsModel(host: host, fileURL: environment.libraryFile)
        autoEq = AutoEqSearchModel(host: host, saved: saved, environment: environment)
        ai = AiStudioModel(host: host, saved: saved, runtime: environment.ai)
    }

    package func cancelNetworkWork() {
        autoEq.cancel()
        ai.cancel()
    }
}
