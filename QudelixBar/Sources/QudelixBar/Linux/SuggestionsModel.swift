import Foundation

package struct SuggestionChoice: Equatable {
    package var id: String
    package var label: String
}

package struct SuggestionOffer: Equatable {
    package var id: String
    package var headline: String
    package var detail: String
    package var measuredBy: String
    package var alternatives: [SuggestionChoice]
}

package struct SuggestionsState: Equatable {
    package var banner: SuggestionOffer?
    package var row: SuggestionOffer?
    package var busy = false
    package var error: String?
    package var fitting = false
    package var fitNote: String?
    package var canApply = false
    package var applyHelp: String?
    package var unsavedWarning: String?
    package var headphoneName = ""

    package init() {}
}

@MainActor
package final class SuggestionsModel {
    package static let applyLabel = "Apply"
    package static let applyLinkLabel = HeadphoneSuggestions.applyLinkLabel
    package static let alternativesLabel = "Other measurements for these headphones"
    package static let dismissLabel = "Don\u{2019}t offer this correction"
    package static let dismissHelp = "Hide this \u{2014} it won\u{2019}t be offered again for this name"
    package static let rowHelp = "AutoEq has a measured correction for these headphones \u{2014} it is "
        + "fitted to this device before anything is written."
    package static let unsavedWarning = "Your current EQ is a custom setting that isn\u{2019}t saved to a "
        + "slot \u{2014} applying this will replace it."
    package static let fitLabel = "Fit"
    package static let refitLabel = "Re-fit"
    package static let fittingLabel = "fitting\u{2026}"
    package static let fitHelp = "Fit a correction for these headphones from their measurement "
        + "\u{2014} one click, with the recommended target. Opens the AutoEq page "
        + "if the headphones need choosing."
    package static let refitHelp = "Fit this headphone's correction again with the recommended "
        + "target, for the current band layout."

    package static func fitButtonLabel(hasReference: Bool) -> String {
        hasReference ? refitLabel : fitLabel
    }

    package static func fitButtonHelp(hasReference: Bool) -> String {
        hasReference ? refitHelp : fitHelp
    }

    private unowned let host: AppModel
    private unowned let saved: SavedPresetsModel
    private unowned let autoEq: AutoEqSearchModel
    let engine: HeadphoneSuggestions

    private var observers: [Int: (SuggestionsState) -> Void] = [:]
    private var nextObserverID = 0
    private var cancellables = Set<AnyCancellable>()
    private var automationObserver: (automation: AutomationModel, id: Int)?
    private var fitInFlight = false
    private var currentFit: AutomationModel?
    package var openAutoEq: (() -> Void)?
    package private(set) var state = SuggestionsState()

    init(host: AppModel, saved: SavedPresetsModel, autoEq: AutoEqSearchModel,
         service: AutoEqService, index: AutoEqIndex) {
        self.host = host
        self.saved = saved
        self.autoEq = autoEq
        engine = HeadphoneSuggestions(library: saved.library, catalogue: index, optimizer: service)
        engine.limits = { [weak host] in
            .qudelix(bandCount: host?.eq.bandCapacity ?? QxEqGroup.user.bandCount)
        }
        engine.writeRefusal = { [weak host] in host?.eq.writeRefusal(attempted: false) }
        engine.applyCorrection = { [weak self] result, name in
            guard let self, self.autoEq.applyCorrection(result, named: name) else { return false }
            self.host.notify(.success, "Applied the correction for \(name).")
            return true
        }
        host.addObserver { [weak self] _ in self?.refresh() }
        host.eq.addObserver { [weak self] _ in self?.refresh() }
        saved.addObserver { [weak self] _ in self?.refresh() }
        engine.$match.sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        engine.$banner.sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        engine.$busy.sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        engine.$lastError.sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        engine.$fitNote.sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        engine.$fitting.sink { [weak self] fitting in
            guard let self else { return }
            if !fitting, self.fitInFlight { self.finishFit() }
            self.refresh()
        }.store(in: &cancellables)
        engine.start()
    }

    @discardableResult
    package func addObserver(_ observer: @escaping (SuggestionsState) -> Void) -> Int {
        nextObserverID += 1
        observers[nextObserverID] = observer
        observer(state)
        return nextObserverID
    }

    package func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    package func uiShown() {
        engine.uiShown()
    }

    package func attach(automation: AutomationModel) {
        if let automationObserver { automationObserver.automation.removeObserver(automationObserver.id) }
        let id = automation.addObserver { [weak self, weak automation] next in
            guard let self, let automation else { return }
            self.fitRequested(next, automation: automation)
        }
        automationObserver = (automation, id)
    }

    private func fitRequested(_ next: AutomationState, automation: AutomationModel) {
        guard let name = next.fitRequest, !fitInFlight else { return }
        fitInFlight = true
        currentFit = automation
        engine.quickFit(name: name) { [weak self] query, note in
            self?.chooseHeadphone(query: query, note: note)
        }
        if !engine.fitting { finishFit() }
    }

    private func finishFit() {
        fitInFlight = false
        let automation = currentFit
        currentFit = nil
        automation?.clearFitRequest()
    }

    private func chooseHeadphone(query: String, note: String) {
        autoEq.setQuery(query)
        autoEq.searchNow()
        autoEq.showNote(note)
        openAutoEq?()
    }

    package func requestFit() {
        guard let automation = automationObserver?.automation else { return }
        automation.requestFit(headphone: saved.state.headphoneName)
    }

    package func accept(_ id: String) {
        guard let entry = entry(id) else { return }
        engine.accept(entry)
        Task { @MainActor [weak self] in
            await self?.engine.acceptTask?.value
            guard let self, self.engine.lastError == nil, self.engine.match == nil else { return }
            self.openAutoEq?()
        }
    }

    package func cancel() {
        engine.resolveTask?.cancel()
        engine.acceptTask?.cancel()
        engine.quickFitTask?.cancel()
    }

    package func dismiss() {
        engine.dismiss()
    }

    package func waitForIdle() async {
        await engine.resolveTask?.value
        await engine.acceptTask?.value
        await engine.quickFitTask?.value
    }

    private func entry(_ id: String) -> AutoEqEntry? {
        guard let match = engine.match ?? engine.banner else { return nil }
        return ([match.entry] + match.alternatives).first { $0.id == id }
    }

    private func offer(_ suggestion: HeadphoneSuggestions.Suggestion) -> SuggestionOffer {
        SuggestionOffer(
            id: suggestion.entry.id,
            headline: HeadphoneSuggestions.headline(suggestion.entry.title),
            detail: HeadphoneSuggestions.bannerDetail(source: suggestion.entry.source,
                                                      bandCount: host.eq.bandCapacity),
            measuredBy: HeadphoneSuggestions.measuredBy(suggestion.entry.source),
            alternatives: suggestion.alternatives.count > 1
                ? suggestion.alternatives.map {
                    SuggestionChoice(id: $0.id, label: "\($0.title) (\($0.source))")
                }
                : [])
    }

    private func refresh() {
        var next = SuggestionsState()
        next.banner = engine.banner.map(offer)
        if engine.banner == nil { next.row = engine.match.map(offer) }
        next.busy = engine.busy
        next.error = engine.lastError
        next.fitting = engine.fitting
        next.fitNote = engine.fitNote
        let refusal = host.eq.writeRefusal(attempted: false)
        next.canApply = refusal == nil
        next.applyHelp = refusal
        next.unsavedWarning = host.eq.state.activeSlot == nil ? Self.unsavedWarning : nil
        next.headphoneName = saved.state.headphoneName
        guard next != state else { return }
        state = next
        for observer in observers.values { observer(next) }
    }
}
