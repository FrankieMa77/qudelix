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

@MainActor
final class EqRenderDriver {
    private static let boosted = """
        Preamp: -6 dB
        Filter 1: ON LSC Fc 105 Hz Gain 17 dB Q 0.7
        Filter 2: ON PK Fc 250 Hz Gain -4.5 dB Q 1.1
        Filter 3: ON PK Fc 3000 Hz Gain 5 dB Q 2.0
        Filter 4: ON HSC Fc 9000 Hz Gain -14 dB Q 0.7
        """

    private let options: LaunchOptions
    private let model: AppModel
    private let audio: AudioStack?
    private var imported = false
    private var previewed = false

    init(options: LaunchOptions, model: AppModel, audio: AudioStack?) {
        self.options = options
        self.model = model
        self.audio = audio
    }

    func ready() -> Bool {
        if options.ghost {
            if !imported {
                imported = true
                model.eq.importText(Self.boosted, named: "Sennheiser HD 650")
                return false
            }
            guard model.eq.state.divergence() != nil else { return false }
        }
        if options.follow, let automation = audio?.automation {
            if !previewed {
                previewed = true
                automation.showPreview(Self.followingState())
                return false
            }
            return model.eq.state.readOnlyReason != nil
        }
        return true
    }

    static func followingState() -> AutomationState {
        var state = AutomationState()
        state.autoFit = true
        state.autoTrimOn = true
        state.trimMode = .clarity
        state.source = .catalog
        state.effectiveSource = .catalog
        state.hasReference = true
        state.referenceActive = true
        state.following = true
        state.deviationDb = 0.6
        state.referenceTexts = ["Sennheiser HD 650 \u{00B7} oratory1990", "Sennheiser HD 650"]
        state.followNote = "Following the reference \u{2014} within 0.6 dB"
        state.trimTexts = ["bass +0.5 \u{00B7} tilt +0.3 dB/oct \u{00B7} presence +0.8 \u{00B7} air +0.0"]
        state.balanceText = "balance: a touch bright"
        state.referenceLine = AutomationLine(
            bands: [EqBand(filter: .lowShelf, freq: 105, gain: 6, q: 0.7),
                    EqBand(filter: .peak, freq: 2800, gain: 4, q: 1.4),
                    EqBand(filter: .highShelf, freq: 9000, gain: -5, q: 0.7)], offsetDb: 0)
        state.trimLine = AutomationLine(
            bands: [EqBand(filter: .peak, freq: 120, gain: 0.5, q: 0.8),
                    EqBand(filter: .peak, freq: 3500, gain: 0.8, q: 1.0)], offsetDb: 0)
        return state
    }
}

@MainActor
final class AudioRenderDriver {
    private let options: LaunchOptions
    private let audio: AudioStack?
    private let levelPage: LevelPage?
    private var applied = false
    private var dialogRequested = false

    init(options: LaunchOptions, audio: AudioStack?, levelPage: LevelPage?) {
        self.options = options
        self.audio = audio
        self.levelPage = levelPage
    }

    func ready() -> Bool {
        guard let stage = audio?.stage else { return true }
        if !applied {
            applied = true
            let stageScenario = options.stageDemo.flatMap(DemoStageScenario.init(rawValue:))
            let levelScenario = options.levelDemo.flatMap(DemoLevelScenario.init(rawValue:))
                ?? (stageScenario == .on ? .lossy : .empty)
            let stageState = stageScenario.map(DemoAudioData.stage) ?? DemoAudioData.runningStage(for: levelScenario)
            stage.showPreview(stageState, level: DemoAudioData.level(levelScenario))
            return false
        }
        if options.dialog == "delete", let levelPage {
            if levelPage.dialog == nil {
                if !dialogRequested {
                    dialogRequested = true
                    _ = levelPage.presentDelete()
                }
                return false
            }
            return levelPage.dialog.map { gtk_widget_get_width($0.assumingMemoryBound(to: GtkWidget.self)) > 0 } ?? false
        }
        return true
    }
}
