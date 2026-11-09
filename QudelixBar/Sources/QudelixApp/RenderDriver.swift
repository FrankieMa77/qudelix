import CGtk
import Foundation
import QudelixBar

@MainActor
final class LibraryRenderDriver {
    private let options: LaunchOptions
    private let page: LibraryPage
    private var generated = false
    private var dialogRequested = false
    private var searched = false

    init(options: LaunchOptions, page: LibraryPage) {
        self.options = options
        self.page = page
    }

    func ready() -> Bool {
        let library = page.library
        let section = options.section.flatMap(LibrarySectionName.init(rawValue:)) ?? .saved
        page.show(section)
        switch section {
        case .saved:
            if let item = options.selectItem {
                let presets = library.saved.state.presets
                guard presets.indices.contains(item) else { return false }
                if library.saved.state.selected != presets[item].id { library.saved.select(presets[item].id) }
                guard library.saved.state.preview != nil else { return false }
            }
        case .autoeq:
            if let query = options.query {
                if !searched {
                    searched = true
                    library.autoEq.setQuery(query)
                    library.autoEq.searchNow()
                    return false
                }
                let results = library.autoEq.state.results
                guard !results.isEmpty else { return false }
                if let item = options.selectItem {
                    guard results.indices.contains(item) else { return false }
                    if library.autoEq.state.selected != results[item].id { library.autoEq.select(results[item].id) }
                    guard library.autoEq.state.preview != nil else { return false }
                }
            }
        case .ai:
            if options.aiDraft {
                if library.ai.state.keyStatus == .none { library.ai.saveKey("render-key-not-real") }
                if !generated {
                    generated = true
                    library.ai.setHeadphone("Sennheiser HD 650")
                    library.ai.setKind("warmth")
                    library.ai.generate()
                    return false
                }
                guard library.ai.state.draft != nil else { return false }
            }
        }
        if let kind = options.dialog {
            if page.dialog == nil {
                if !dialogRequested {
                    dialogRequested = true
                    _ = page.presentDialog(kind)
                }
                return false
            }
            return page.dialog.map { gtk_widget_get_width($0.assumingMemoryBound(to: GtkWidget.self)) > 0 } ?? false
        }
        return true
    }
}
