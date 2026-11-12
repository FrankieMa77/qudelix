import Foundation

@MainActor
package final class LibraryModel {
    package let saved: SavedPresetsModel
    package let autoEq: AutoEqSearchModel
    package let ai: AiStudioModel
    package let suggestions: SuggestionsModel

    init(host: AppModel, environment: LibraryEnvironment) {
        saved = SavedPresetsModel(host: host, fileURL: environment.libraryFile)
        let service = AutoEqService(transport: environment.autoEqTransport)
        let published = PublishedCorrectionSource(environment: environment)
        autoEq = AutoEqSearchModel(host: host, saved: saved, environment: environment,
                                   service: service, published: published)
        ai = AiStudioModel(host: host, saved: saved, runtime: environment.ai)
        suggestions = SuggestionsModel(host: host, saved: saved, autoEq: autoEq,
                                       service: service, index: published.index)
    }

    package func cancelNetworkWork() {
        autoEq.cancel()
        ai.cancel()
        suggestions.cancel()
    }
}
