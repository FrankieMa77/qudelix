import Foundation

package enum AiKeyStatus: Equatable {
    case none
    case saved
    case environment
    case unsafeMode
}

package enum AiPhase: Equatable {
    case idle
    case researching
    case designing
}

package struct AiFact: Equatable {
    package var label: String
    package var text: String
}

package struct AiDraftView: Equatable {
    package var name: String
    package var rationale: String?
    package var notes: [String]
    package var preview: CurvePreview
}

package struct AiKindGroup: Equatable {
    package var title: String
    package var kinds: [LibraryChoice]
}

package struct AiSlotChoice: Equatable {
    package var slot: Int
    package var message: String
    package var confirmLabel: String
}

package struct AiState: Equatable {
    package var providers: [LibraryChoice] = []
    package var provider = ""
    package var providerHost = ""
    package var model = ""
    package var defaultModel = ""
    package var keyStatus = AiKeyStatus.none
    package var kinds: [LibraryChoice] = []
    package var kindGroups: [AiKindGroup] = []
    package var kind = ""
    package var kindLabel = ""
    package var headphone = ""
    package var note = ""
    package var bandCount = 10
    package var phase = AiPhase.idle
    package var error: String?
    package var draft: AiDraftView?
    package var dossier: [AiFact] = []
    package var researchInfo: String?
    package var refreshResearch = false
    package var researchFallback = false
    package var slots: [PresetSlot] = []
    package var canWriteSlot = false
    package var unsavedCurve = false
    package var slotChoice: AiSlotChoice?
    package var generateHint: String?
    package var canGenerate = false
    package var applyRefusal: String?
    package var summary: String?

    package init() {}

    package var busy: Bool { phase != .idle }
}

@MainActor
package final class AiStudioModel {
    package static let billingCaption = "Uses your own account at the provider "
        + "\u{2014} generations are billed to you."
    package static let privacyNote = "Nothing is sent until you press Generate or Research. "
        + "Then the headphone name, the preset kind and your note go to the one provider you "
        + "picked, on your own key, and when the AutoEq project has measured that headphone "
        + "its published correction goes with them. The AutoEq list is read from "
        + "raw.githubusercontent.com. Never your EQ curve, your presets or your device. "
        + "The key stays in a private file on this computer and is only ever sent to that "
        + "provider."
    package static let unsavedCurveWarning =
        "Your current EQ is a custom setting that isn\u{2019}t saved to a "
        + "slot \u{2014} applying this will replace it."
    package static let writeToSlotLabel = "Write to slot\u{2026}"
    package static let researchAgainLabel = "Research again"
    package static let researchAgainHelp = "Research this headphone again on the next generate"
    package static let researchPending = "Will research this model again on the next generate."
    package static let researchFirst = "Will research this model on first generate."
    package static let researchFallbackNote = "Research didn\u{2019}t come back \u{2014} designed "
        + "from general knowledge instead."
    package static let characterTitle = "Character"
    package static let targetsTitle = "Targets"

    package static func overwriteCopy(slot: Int, name: String?) -> String {
        guard let name else {
            return "Slot \(slot + 1) is empty. Writing puts this preset there."
        }
        return PresetSlotsModel.overwriteMessage(slot: slot, name: name)
    }

    package static func overwriteLabel(slot: Int) -> String {
        "Overwrite slot \(slot + 1)"
    }

    package static let correctionNote = "Correction needs no key: it is taken from the "
        + "published measurement when this model has one."
    package static let keyRowTitle = "API key"
    package static let maxNoteLength = AIPresetService.maxNoteLength

    package static func forgetKeyTitle(_ provider: String) -> String {
        "Forget the " + provider + " key?"
    }

    package static let forgetKeyMessage = "It is deleted from this computer. You will need to "
        + "paste it again, and many providers show a key only once."

    private unowned let host: AppModel
    private let saved: SavedPresetsModel
    private let runtime: AIRuntime

    private var observers: [Int: (AiState) -> Void] = [:]
    private var nextObserverID = 0
    package private(set) var state = AiState()

    private var provider: AIProvider
    private var models: [AIProvider: String] = [:]
    private var kind: AIPresetKind = .correction
    private var headphone = ""
    private var note = ""
    private var refreshResearch = false
    private var researchFallback = false
    private var slotChoice: Int?
    private var phase = AiPhase.idle
    private var error: String?
    private var draft: AiDraftView?
    private var draftGroup: QxEqGroup = .user
    private var draftBands: [QxEqBandValue] = []
    private var draftPreGain = 0.0
    private var dossier: [AiFact] = []
    private var summary: String?
    private var cachedKey = AiKeyStatus.none
    private var cachedInfo: String?
    private var task: Task<Void, Never>?
    private var generation = 0

    init(host: AppModel, saved: SavedPresetsModel, runtime: AIRuntime) {
        self.host = host
        self.saved = saved
        self.runtime = runtime
        self.provider = AICommand.defaultProvider(runtime)
        self.cachedKey = keyStatus()
        host.addObserver { [weak self] _ in self?.publish() }
        host.eq.addObserver { [weak self] _ in self?.publish() }
        host.presets.addObserver { [weak self] _ in self?.publish() }
    }

    @discardableResult
    package func addObserver(_ observer: @escaping (AiState) -> Void) -> Int {
        nextObserverID += 1
        observers[nextObserverID] = observer
        observer(state)
        return nextObserverID
    }

    package func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    package func waitForIdle() async {
        await task?.value
    }

    private var trimmedHeadphone: String {
        String(headphone.trimmingCharacters(in: .whitespaces)
            .prefix(AICommand.maxHeadphoneNameLength))
    }

    private var effectiveModel: String {
        let typed = (models[provider] ?? "").trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? provider.defaultModel : typed
    }

    package func setProvider(_ id: String) {
        guard let next = AIProvider(rawValue: id), next != provider, !state.busy else { return }
        provider = next
        error = nil
        cachedKey = keyStatus()
        publish()
    }

    package func setModel(_ text: String) {
        let clean = SafeText.scrubbed(text, limit: HeadphoneDossier.maxModel)
        guard clean != (models[provider] ?? "") else { return }
        models[provider] = clean
        publish()
    }

    package func setKind(_ id: String) {
        guard let next = AIPresetKind(rawValue: id), next != kind else { return }
        kind = next
        error = nil
        publish()
    }

    package func setHeadphone(_ text: String) {
        guard text != headphone else { return }
        headphone = String(text.prefix(AICommand.maxHeadphoneNameLength))
        cachedInfo = researchInfo()
        publish()
    }

    package func setNote(_ text: String) {
        let clean = String(text.prefix(Self.maxNoteLength))
        guard clean != note else { return }
        note = clean
        publish()
    }

    package func setRefreshResearch(_ on: Bool) {
        guard on != refreshResearch else { return }
        refreshResearch = on
        publish()
    }

    private func keyStatus() -> AiKeyStatus {
        switch runtime.keychain.load(provider: provider.rawValue) {
        case .none:
            return .none
        case .denied:
            return .unsafeMode
        case .key:
            let name = AIKeychain.environmentVariable(provider: provider.rawValue)
            let fromEnvironment = !AIKeychain.printable(runtime.keychain.environment[name] ?? "").isEmpty
            return fromEnvironment ? .environment : .saved
        }
    }

    @discardableResult
    package func saveKey(_ key: String) -> Bool {
        let clean = AIKeychain.printable(key)
        guard !clean.isEmpty else {
            error = "That key is empty."
            publish()
            return false
        }
        guard runtime.keychain.save(key: clean, provider: provider.rawValue) else {
            error = "Couldn\u{2019}t save the key."
            publish()
            return false
        }
        error = nil
        cachedKey = keyStatus()
        publish()
        return true
    }

    package func forgetKey() {
        runtime.keychain.delete(provider: provider.rawValue)
        cachedKey = keyStatus()
        publish()
    }

    package func clearError() {
        error = nil
        publish()
    }

    package func discardDraft() {
        generation += 1
        draft = nil
        draftBands = []
        summary = nil
        slotChoice = nil
        researchFallback = false
        publish()
    }

    package func cancel() {
        guard phase != .idle else { return }
        generation += 1
        task?.cancel()
        task = nil
        phase = .idle
        publish()
    }

    private static func unreadableKey(_ provider: AIProvider) -> String {
        "The saved \(provider.label) key can be read by other users, so it was not used. "
            + "Save it again here to fix that."
    }

    private func translated(_ error: Error) -> String {
        if error is CLIUsageError {
            if case .denied = runtime.keychain.load(provider: provider.rawValue) {
                return Self.unreadableKey(provider)
            }
            return AIError.missingKey(provider.label).localizedDescription
        }
        return AICommand.message(for: error)
    }

    @discardableResult
    package func generate() -> Bool {
        guard phase == .idle else { return false }
        let name = trimmedHeadphone
        guard name.count >= AICommand.minimumHeadphoneNameLength else { return false }
        switch runtime.keychain.load(provider: provider.rawValue) {
        case .denied:
            error = Self.unreadableKey(provider)
            publish()
            return false
        case .none where kind != .correction:
            error = AIError.missingKey(provider.label).localizedDescription
            publish()
            return false
        default:
            break
        }
        let group = host.eq.currentGroup
        let bandCount = group.bandCount
        var request = AISuggestRequest(headphone: name, kind: kind)
        request.note = note
        let chosen = provider
        let useModel = effectiveModel
        let useRuntime = runtime
        let refresh = refreshResearch
        refreshResearch = false
        error = nil
        summary = nil
        draft = nil
        slotChoice = nil
        researchFallback = false
        generation += 1
        let token = generation
        phase = .researching
        publish()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if token == self.generation {
                    self.task = nil
                    self.phase = .idle
                    self.publish()
                }
            }
            do {
                let outcome = try await AICommand.draft(
                    request, bandCount: bandCount, provider: chosen, model: useModel,
                    runtime: useRuntime, refresh: refresh,
                    phase: { [weak self] next in
                        guard let self, token == self.generation else { return }
                        self.phase = next == .researching ? .researching : .designing
                        self.publish()
                    })
                guard token == self.generation else { return }
                self.cachedInfo = self.researchInfo()
                self.adopt(outcome, headphone: name, kind: request.kind, group: group,
                           provider: chosen, model: useModel)
            } catch {
                guard token == self.generation, !(error is CancellationError) else { return }
                self.error = self.translated(error)
            }
        }
        return true
    }

    private func adopt(_ outcome: AICommand.Outcome, headphone name: String,
                       kind: AIPresetKind, group: QxEqGroup, provider: AIProvider,
                       model: String) {
        var notes = [outcome.grounded
            ? "Grounded in a published measurement of this model."
            : "No measurement found for this model \u{2014} designed from general knowledge."]
        researchFallback = outcome.researchFallback
        if let quantisation = outcome.draft.quantisationNote { notes.append(quantisation) }
        draftGroup = group
        draftBands = outcome.draft.bands
        draftPreGain = outcome.draft.preGain
        notes.append("Pre-gain " + DisplayFormat.decibels(outcome.draft.preGain)
            + ", worked out here from the bands, not by the model.")
        var preview = LibraryFormat.preview(
            title: outcome.draft.name, group: group, bands: outcome.draft.bands,
            preGain: outcome.draft.preGain)
        preview.subtitle = "\(name) \u{00B7} \(kind.label) \u{00B7} \(group.bandCount) bands"
            + " \u{00B7} \(provider.label)"
        draft = AiDraftView(name: outcome.draft.name, rationale: outcome.draft.rationale,
                            notes: notes, preview: preview)
    }

    package func applyRefusal(attempted: Bool = true) -> String? {
        guard draft != nil else { return nil }
        if let refusal = host.eq.writeRefusal(attempted: attempted) { return refusal }
        if draftBands.count > host.eq.bandCapacity {
            return "This draft has more bands than the bank the device is in."
        }
        return nil
    }

    @discardableResult
    package func apply() -> Bool {
        guard let shown = draft else { return false }
        if let refusal = applyRefusal() {
            summary = refusal
            publish()
            return false
        }
        var file = ParametricEQFile()
        file.preamp = draftPreGain
        file.bands = draftBands
        let result = host.eq.apply(file, named: shown.name, undoLabel: "apply \(shown.name)")
        summary = result.summary
        publish()
        return result.accepted
    }

    package var canWriteSlot: Bool {
        draft != nil && applyRefusal(attempted: false) == nil && host.presets.canWrite
            && !host.presets.state.busy
    }

    package func chooseSlot(_ index: Int) {
        guard canWriteSlot, (0..<PresetSlotsModel.slotCount).contains(index) else { return }
        slotChoice = index
        publish()
    }

    package func cancelSlotChoice() {
        guard slotChoice != nil else { return }
        slotChoice = nil
        publish()
    }

    @discardableResult
    package func writeToSlot() -> Bool {
        guard let index = slotChoice else { return false }
        slotChoice = nil
        guard canWriteSlot, apply() else {
            publish()
            return false
        }
        host.presets.save(slot: index)
        return true
    }

    @discardableResult
    package func saveDraftToLibrary() -> Bool {
        guard let shown = draft else { return false }
        let stored = saved.saveCurve(name: shown.name, group: draftGroup, bands: draftBands,
                                     preGain: draftPreGain, source: shown.name)
        summary = stored ? "Saved to the library \u{2014} nothing was sent to the 5K." : nil
        publish()
        return stored
    }

    @discardableResult
    package func research() -> Bool {
        guard phase == .idle else { return false }
        let name = trimmedHeadphone
        guard name.count >= AICommand.minimumHeadphoneNameLength else { return false }
        switch runtime.keychain.load(provider: provider.rawValue) {
        case .denied:
            error = Self.unreadableKey(provider)
            publish()
            return false
        case .none:
            error = AIError.missingKey(provider.label).localizedDescription
            publish()
            return false
        case .key:
            break
        }
        var request = AIResearchRequest(headphone: name)
        request.provider = provider
        request.model = effectiveModel
        request.refresh = refreshResearch
        refreshResearch = false
        error = nil
        generation += 1
        let token = generation
        phase = .researching
        publish()
        let useRuntime = runtime
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if token == self.generation {
                    self.task = nil
                    self.phase = .idle
                    self.publish()
                }
            }
            do {
                let found = try await AICommand.dossier(for: request, runtime: useRuntime)
                guard token == self.generation else { return }
                self.dossier = Self.facts(found.dossier, cached: found.cached)
                self.cachedInfo = self.researchInfo()
            } catch {
                guard token == self.generation, !(error is CancellationError) else { return }
                self.error = self.translated(error)
            }
        }
        return true
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let shortStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d/yy"
        return formatter
    }()

    static func facts(_ dossier: HeadphoneDossier, cached: Bool) -> [AiFact] {
        var rows = [AiFact(label: "Researched",
                           text: stamp.string(from: dossier.researchedAt)
                               + (cached ? " (from the cache)" : "")),
                    AiFact(label: "By", text: [dossier.provider, dossier.model]
                        .filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")),
                    AiFact(label: "Confidence", text: dossier.confidence)]
        for (label, text) in [("Signature", dossier.signature), ("Bass", dossier.bass),
                              ("Mids", dossier.mids), ("Treble", dossier.treble),
                              ("Soundstage", dossier.soundstage)] where !text.isEmpty {
            rows.append(AiFact(label: label, text: text))
        }
        if let measurement = dossier.measurement {
            rows.append(AiFact(label: "Measurement", text: measurement.title.isEmpty
                ? "\(measurement.bands.count) published filters"
                : "\(measurement.title) \u{2014} \(measurement.bands.count) published filters"))
        }
        for issue in dossier.knownIssues {
            rows.append(AiFact(label: issue.region, text: issue.issue))
        }
        return rows
    }

    private func researchInfo() -> String? {
        let key = AIResearchStore.key(for: trimmedHeadphone)
        guard let cached = runtime.research.dossier(for: key) else { return nil }
        return "Researched " + Self.shortStamp.string(from: cached.researchedAt) + " \u{00B7} "
            + cached.confidence + " confidence"
    }

    private static func choice(_ kind: AIPresetKind) -> LibraryChoice {
        LibraryChoice(id: kind.rawValue, label: kind.label)
    }

    private func publish() {
        var next = AiState()
        next.providers = AIProvider.allCases.map { LibraryChoice(id: $0.rawValue, label: $0.label) }
        next.provider = provider.rawValue
        next.providerHost = provider.host
        next.model = models[provider] ?? ""
        next.defaultModel = provider.defaultModel
        next.keyStatus = cachedKey
        next.kinds = AIPresetKind.allCases.map { LibraryChoice(id: $0.rawValue, label: $0.label) }
        next.kindGroups = [
            AiKindGroup(title: Self.characterTitle, kinds: AIPresetKind.character.map(Self.choice)),
            AiKindGroup(title: Self.targetsTitle, kinds: AIPresetKind.targets.map(Self.choice))]
        next.kind = kind.rawValue
        next.kindLabel = kind.label
        next.headphone = headphone
        next.note = note
        next.bandCount = host.eq.bandCapacity
        next.phase = phase
        next.error = error
        next.draft = draft
        next.dossier = dossier
        next.researchInfo = cachedInfo
        next.refreshResearch = refreshResearch
        next.researchFallback = researchFallback
        next.slots = host.presets.state.slots
        next.unsavedCurve = host.presets.activeSlotIndex == nil
        next.canWriteSlot = canWriteSlot
        if !next.canWriteSlot { slotChoice = nil }
        next.slotChoice = slotChoice.map { index in
            let name = next.slots.first { $0.index == index }?.name
            return AiSlotChoice(slot: index, message: Self.overwriteCopy(slot: index, name: name),
                                confirmLabel: Self.overwriteLabel(slot: index))
        }
        next.summary = summary
        next.applyRefusal = applyRefusal(attempted: false)
        if phase != .idle {
            next.generateHint = nil
        } else if trimmedHeadphone.count < AICommand.minimumHeadphoneNameLength {
            next.generateHint = "Name your headphones"
        } else if next.keyStatus == .none, kind != .correction {
            next.generateHint = "Save a key to start"
        }
        next.canGenerate = phase == .idle && next.generateHint == nil
        guard next != state else { return }
        state = next
        for observer in observers.values { observer(next) }
    }
}
