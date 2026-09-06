import Combine
import Foundation

@MainActor
protocol HeadphoneCatalogue: AnyObject {
    var catalogueEntries: [AutoEqEntry] { get }
    var catalogueReady: Bool { get }
    var catalogueFailed: Bool { get }
    func loadCatalogue()
}

extension AutoEqIndex: HeadphoneCatalogue {
    var catalogueEntries: [AutoEqEntry] { entries }
    var catalogueReady: Bool { state == .ready }
    var catalogueFailed: Bool {
        if case .failed = state { return true }
        return false
    }
    func loadCatalogue() { loadIfNeeded() }
}

@MainActor
final class HeadphoneSuggestions: ObservableObject {
    struct Suggestion: Equatable {
        var name: String
        var entry: AutoEqEntry
        var alternatives: [AutoEqEntry]
    }

    @Published private(set) var match: Suggestion?
    @Published private(set) var banner: Suggestion?
    @Published private(set) var busy = false
    @Published private(set) var lastError: String?

    static let maxAlternatives = 3
    static let minNeedleLength = 4

    var pollAttempts = 50
    var pollInterval: Duration = .milliseconds(200)

    var limits: (() -> DeviceEQLimits)?
    var applyCorrection: ((CorrectionResult, String) -> Bool)?
    var popoverIsOpen: (() -> Bool)?

    private let library: PresetLibrary
    private let catalogue: any HeadphoneCatalogue
    private let optimizer: AutoEqService
    private var sources: Set<AnyCancellable> = []
    private var lastKey: String?
    private(set) var resolveTask: Task<Void, Never>?
    private(set) var acceptTask: Task<Void, Never>?
    private var resolving = false
    private var sawStoredName = false
    private var uiHasBeenShown = false
    private var storedNameAwaitingUI: String?
    private var failedLookups: Set<String> = []
    private static let maxFailedLookups = 32

    init(library: PresetLibrary,
         catalogue: (any HeadphoneCatalogue)? = nil,
         optimizer: AutoEqService? = nil) {
        self.library = library
        self.catalogue = catalogue ?? AutoEqIndex()
        self.optimizer = optimizer ?? AutoEqService()
    }

    func start() {
        guard sources.isEmpty else { return }
        library.$headphoneName
            .removeDuplicates()
            .sink { [weak self] name in
                MainActor.assumeIsolated { self?.observedName(name) }
            }
            .store(in: &sources)
    }

    private func observedName(_ raw: String) {
        if !sawStoredName {
            sawStoredName = true
            guard uiHasBeenShown else {
                storedNameAwaitingUI = raw
                return
            }
        }
        nameChanged(raw)
    }

    func uiShown() {
        uiHasBeenShown = true
        guard let name = storedNameAwaitingUI else { return }
        storedNameAwaitingUI = nil
        nameChanged(name)
    }

    var diagSummary: String {
        if resolving { return "suggest=pending" }
        return match == nil ? "suggest=none" : "suggest=offered"
    }

    func nameChanged(_ raw: String) {
        let key = Self.normalized(raw)
        guard key != lastKey else { return }
        lastKey = key
        resolveTask?.cancel()
        resolveTask = nil
        resolving = false
        match = nil
        banner = nil
        lastError = nil
        guard key.count >= Self.minNeedleLength, !library.hasSuggested(key),
              !failedLookups.contains(key) else { return }
        resolving = true
        catalogue.loadCatalogue()
        resolveTask = Task { [weak self] in
            guard let self else { return }
            defer { self.resolving = false }
            let loaded = await self.waitFor({ self.catalogue.catalogueReady },
                                            failed: { self.catalogue.catalogueFailed })
            guard !Task.isCancelled, self.lastKey == key else { return }
            guard loaded else {
                if self.catalogue.catalogueFailed { self.markLookupFailed(key) }
                return
            }
            self.resolve(name: raw, key: key)
        }
    }

    private func markLookupFailed(_ key: String) {
        if failedLookups.count >= Self.maxFailedLookups { failedLookups.removeAll() }
        failedLookups.insert(key)
    }

    private func resolve(name: String, key: String) {
        let ranked = Self.matches(for: name, in: catalogue.catalogueEntries)
        library.markSuggested(key)
        guard let best = ranked.first else { return }
        let suggestion = Suggestion(name: name, entry: best,
                                    alternatives: Array(ranked.prefix(Self.maxAlternatives)))
        match = suggestion
        banner = suggestion
        guard popoverIsOpen?() != true else { return }
        Notifier.shared.post(id: Notifier.identifier("headphone-eq-", key),
                             title: Self.notificationTitle(name),
                             body: Self.notificationBody)
    }

    private func waitFor(_ ready: @MainActor () -> Bool,
                         failed: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<max(1, pollAttempts) {
            if ready() { return true }
            if failed() { return false }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: pollInterval)
        }
        return ready()
    }

    static func matches(for name: String, in entries: [AutoEqEntry]) -> [AutoEqEntry] {
        let needle = normalized(name)
        guard needle.count >= minNeedleLength else { return [] }
        let scored: [(entry: AutoEqEntry, rank: Int, distance: Int)] = entries.compactMap {
            let title = normalized($0.title)
            guard !title.isEmpty,
                  title.contains(needle) || needle.contains(title) else { return nil }
            return ($0, sourceRank($0.source), abs(title.count - needle.count))
        }
        return scored.sorted {
            ($0.rank, $0.distance, $0.entry.title, $0.entry.path)
                < ($1.rank, $1.distance, $1.entry.title, $1.entry.path)
        }.map(\.entry)
    }

    static func normalized(_ raw: String) -> String {
        String(raw.lowercased().filter { $0.isLetter || $0.isNumber }
            .prefix(PresetLibraryFile.maxNameLength))
    }

    static func sourceRank(_ source: String) -> Int {
        switch source.lowercased() {
        case "oratory1990": return 0
        case "crinacle": return 1
        default: return 2
        }
    }

    static func headline(_ title: String) -> String {
        SafeText.scrubbed(title, limit: 48) + " — measured correction available"
    }

    static func measuredBy(_ source: String) -> String {
        "Measured by " + SafeText.scrubbed(source, limit: 32)
    }

    static func bannerDetail(source: String, bandCount: Int) -> String {
        measuredBy(source) + " — fitted to this device's \(max(1, bandCount)) bands "
            + "before anything is written."
    }

    static func notificationTitle(_ name: String) -> String {
        "Correction available for " + SafeText.scrubbed(name, limit: 48)
    }

    static let notificationBody = "AutoEq has a measured correction for these "
        + "headphones. Open QudelixBar to fit it to the 5K."

    static let applyLinkLabel = "Apply correction"

    func accept(_ entry: AutoEqEntry) {
        guard !busy, let shape = limits?() else { return }
        busy = true
        lastError = nil
        acceptTask = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            self.optimizer.prepare()
            _ = await self.waitFor({ self.optimizer.state == .ready },
                                   failed: {
                                       if case .failed = self.optimizer.state { return true }
                                       return false
                                   })
            guard !Task.isCancelled else { return }
            do {
                let result = try await self.optimizer.correction(
                    for: self.candidate(for: entry), shapedFor: shape,
                    options: CorrectionOptions())
                guard self.applyCorrection?(result, entry.title) == true else {
                    self.lastError = "Not applied — the 5K isn't taking EQ writes right now."
                    return
                }
                self.match = nil
                self.banner = nil
            } catch {
                self.lastError = SafeText.scrubbed(AutoEqService.describe(error))
            }
        }
    }

    func dismiss() {
        banner = nil
        lastError = nil
    }

    private func candidate(for entry: AutoEqEntry) -> CorrectionCandidate {
        let wanted = Self.normalized(entry.title)
        if let model = optimizer.models.first(where: { Self.normalized($0.name) == wanted }),
           let measurement = model.measurements.first(where: { $0.source == entry.source })
            ?? model.measurements.first {
            return CorrectionCandidate(title: model.name, source: measurement.source,
                                       form: measurement.form, rig: measurement.rig,
                                       token: "")
        }
        return CorrectionCandidate(title: entry.title, source: entry.source,
                                   form: nil, rig: nil, token: "")
    }

    #if DEBUG
    func previewSet(_ suggestion: Suggestion?) {
        match = suggestion
        banner = suggestion
        lastKey = suggestion.map { Self.normalized($0.name) }
    }
    #endif
}
