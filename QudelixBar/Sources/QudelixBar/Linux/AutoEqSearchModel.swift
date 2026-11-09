import Foundation

package struct AutoEqResult: Equatable {
    package var id: String
    package var title: String
    package var detail: String
}

package enum AutoEqCatalogue: Equatable {
    case idle
    case loading
    case ready(Int)
    case failed(String)
}

package struct AutoEqState: Equatable {
    package var query = ""
    package var catalogue = AutoEqCatalogue.idle
    package var results: [AutoEqResult] = []
    package var hiddenCount = 0
    package var status: String?
    package var targets: [String] = []
    package var target: String?
    package var selected: String?
    package var fitting = false
    package var preview: CurvePreview?
    package var provenance: String?
    package var warnings: [String] = []
    package var preference: [String] = []
    package var error: String?
    package var applyRefusal: String?
    package var summary: String?
    package var fitBandCount = 10

    package init() {}
}

@MainActor
package final class AutoEqSearchModel {
    package static let maxQueryLength = 64
    package static let recommendedTarget = "Recommended for this measurement"
    package static let searchHint = "Search AutoEq \u{2014} e.g. HD 650. The catalog is "
        + "fetched from autoeq.app the first time you search."

    private unowned let host: AppModel
    private let saved: SavedPresetsModel
    private let service: AutoEqService
    private let delay: TimeInterval

    private var observers: [Int: (AutoEqState) -> Void] = [:]
    private var nextObserverID = 0
    package private(set) var state = AutoEqState()

    private var query = ""
    private var candidates: [CorrectionCandidate] = []
    private var selected: CorrectionCandidate?
    private var target: String?
    private var fitted: CorrectionResult?
    private var fittedGroup: QxEqGroup = .user
    private var catalogue = AutoEqCatalogue.idle
    private var fitting = false
    private var error: String?
    private var summary: String?
    private var debounce: AppTimer?
    private var searchTask: Task<Void, Never>?
    private var fitTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var fitGeneration = 0

    init(host: AppModel, saved: SavedPresetsModel, environment: LibraryEnvironment) {
        self.host = host
        self.saved = saved
        self.service = AutoEqService(transport: environment.autoEqTransport)
        self.delay = environment.searchDelay
        host.addObserver { [weak self] _ in self?.publish() }
        host.eq.addObserver { [weak self] _ in self?.publish() }
    }

    @discardableResult
    package func addObserver(_ observer: @escaping (AutoEqState) -> Void) -> Int {
        nextObserverID += 1
        observers[nextObserverID] = observer
        observer(state)
        return nextObserverID
    }

    package func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    package func waitForIdle() async {
        await searchTask?.value
        await fitTask?.value
    }

    package func setQuery(_ text: String) {
        let clean = String(text.prefix(Self.maxQueryLength))
        guard clean != query else { return }
        query = clean
        debounce?.cancel()
        debounce = nil
        if clean.trimmingCharacters(in: .whitespaces).isEmpty {
            searchTask?.cancel()
            searchGeneration += 1
            candidates = []
            clearSelection()
            publish()
            return
        }
        publish()
        debounce = host.clock.schedule(after: delay) { [weak self] in
            self?.debounce = nil
            self?.searchNow()
        }
    }

    package func searchNow() {
        debounce?.cancel()
        debounce = nil
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searchGeneration += 1
        let token = searchGeneration
        error = nil
        searchTask?.cancel()
        switch service.state {
        case .ready:
            catalogue = .ready(service.models.count)
            refreshResults()
            return
        case .idle, .loading, .failed:
            catalogue = .loading
        }
        publish()
        service.prepare()
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.service.loadTask?.value
            guard token == self.searchGeneration else { return }
            switch self.service.state {
            case .ready:
                self.catalogue = .ready(self.service.models.count)
                self.refreshResults()
            case .failed(let why):
                self.catalogue = .failed(why)
                self.error = "Couldn\u{2019}t load the AutoEq catalog: " + why
                self.publish()
            case .idle, .loading:
                self.catalogue = .idle
                self.publish()
            }
        }
    }

    private func refreshResults() {
        candidates = service.search(query)
        if let current = selected, !candidates.contains(where: { $0.id == current.id }) {
            clearSelection()
        }
        publish()
    }

    package func cancel() {
        searchGeneration += 1
        fitGeneration += 1
        searchTask?.cancel()
        fitTask?.cancel()
        debounce?.cancel()
        debounce = nil
        fitting = false
        if case .loading = catalogue { catalogue = .idle }
        publish()
    }

    package func select(_ id: String?) {
        guard let id, let candidate = candidates.first(where: { $0.id == id }) else {
            clearSelection()
            publish()
            return
        }
        selected = candidate
        fit()
    }

    package func setTarget(_ label: String?) {
        let wanted = label == Self.recommendedTarget ? nil : label
        guard wanted != target else { return }
        target = wanted
        if selected != nil { fit() } else { publish() }
    }

    private func clearSelection() {
        fitGeneration += 1
        fitTask?.cancel()
        selected = nil
        fitted = nil
        fitting = false
        summary = nil
        error = nil
    }

    private func fit() {
        guard let candidate = selected else { return }
        fitTask?.cancel()
        fitGeneration += 1
        let token = fitGeneration
        fitted = nil
        summary = nil
        error = nil
        fitting = true
        let group = host.eq.currentGroup
        fittedGroup = group
        var options = CorrectionOptions()
        options.target = target
        publish()
        fitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.service.correction(
                    for: candidate, shapedFor: .qudelix(bandCount: group.bandCount),
                    options: options.quantized())
                guard token == self.fitGeneration else { return }
                self.fitted = result
                self.fitting = false
            } catch {
                guard token == self.fitGeneration else { return }
                self.fitting = false
                self.error = SafeText.scrubbed(AutoEqService.describe(error), limit: 160)
            }
            self.publish()
        }
    }

    package func refusal(attempted: Bool = true) -> String? {
        guard fitted != nil else { return "Pick a headphone first." }
        if let refusal = host.eq.writeRefusal(attempted: attempted) { return refusal }
        if fittedGroup != host.eq.currentGroup {
            return "The device switched EQ mode \u{2014} pick the headphone again so the "
                + "correction is fitted to the bank it is in now."
        }
        return nil
    }

    @discardableResult
    package func apply() -> Bool {
        guard let result = fitted, let candidate = selected else { return false }
        if let refusal = refusal() {
            summary = refusal
            publish()
            return false
        }
        let outcome = host.eq.apply(result.file, named: candidate.title)
        var parts = [result.provenance]
        if outcome.accepted { parts.append(outcome.summary) } else { parts = [outcome.summary] }
        parts.append(contentsOf: result.warnings)
        summary = parts.joined(separator: " \u{00B7} ")
        publish()
        return outcome.accepted
    }

    @discardableResult
    package func saveToLibrary(name: String? = nil) -> Bool {
        guard let result = fitted, let candidate = selected else { return false }
        let capacity = fittedGroup.bandCount
        let fit = result.file.fitted(toBandCount: capacity)
        let stored = saved.saveCurve(name: name ?? candidate.title, group: fittedGroup,
                                     bands: fit.bands.map(PresetLibraryFile.clamped),
                                     preGain: EQHeadroom.clamp(max(-12, min(12, fit.preamp))),
                                     source: candidate.title)
        summary = stored ? "Saved to the library \u{2014} nothing was sent to the 5K." : nil
        publish()
        return stored
    }

    package var selectedTitle: String? { selected?.title }

    private func publish() {
        var next = AutoEqState()
        next.query = query
        next.catalogue = catalogue
        next.fitBandCount = host.eq.bandCapacity
        let limit = AutoEqService.displayLimit
        next.results = candidates.prefix(limit).map {
            AutoEqResult(id: $0.id, title: $0.title, detail: $0.detail)
        }
        next.hiddenCount = max(0, candidates.count - limit)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        switch catalogue {
        case .ready(let count) where trimmed.isEmpty:
            next.status = "\(count) headphones available. Start typing to search."
        case .ready where candidates.isEmpty:
            next.status = "No match for \u{201C}\(trimmed)\u{201D}."
        case .loading:
            next.status = "Loading the AutoEq catalog\u{2026}"
        default:
            break
        }
        next.targets = [Self.recommendedTarget]
            + AutoEqService.groupedTargets(service.targets).flatMap { $0.targets.map(\.label) }
        next.target = target ?? Self.recommendedTarget
        next.selected = selected?.id
        next.fitting = fitting
        next.error = error
        next.summary = summary
        if let result = fitted, let candidate = selected {
            let capacity = fittedGroup.bandCount
            let fit = result.file.fitted(toBandCount: capacity)
            let asked = result.file.bands.count > capacity ? result.file.bands : nil
            next.preview = LibraryFormat.preview(
                title: candidate.title, group: fittedGroup, bands: fit.bands,
                preGain: max(-12, min(12, fit.preamp)),
                source: candidate.detail, requested: asked)
            next.provenance = result.provenance
            next.warnings = result.warnings
            if let reading = result.preference {
                next.preference = [
                    "Predicted \(Int(reading.score.rounded())) \u{2014} how a listening panel "
                        + "rated headphones this close to the target, on average.",
                    "From a study of 31 over-ear models and 130 listeners. It predicts the "
                        + "group average to within about \u{00B1}7, and roughly a third of "
                        + "listeners prefer more or less bass than the target \u{2014} so it "
                        + "is not a measure of how this will sound to you.",
                ]
            }
        }
        next.applyRefusal = fitted == nil ? nil : refusal(attempted: false)
        guard next != state else { return }
        state = next
        for observer in observers.values { observer(next) }
    }
}
