import Foundation

package struct SavedPreset: Equatable {
    package var id: UUID
    package var name: String
    package var detail: String
    package var canUseEverywhere = false
    package var canUseOnlyHere = false
}

package enum LibraryOutputState: Equatable {
    case unavailable
    case noOutput
    case output(key: String, name: String)

    package var key: String? {
        if case .output(let key, _) = self { return key }
        return nil
    }

    package var name: String {
        if case .output(_, let name) = self { return name }
        return ""
    }
}

package struct SavedPresetsState: Equatable {
    package var presets: [SavedPreset] = []
    package var others: [SavedPreset] = []
    package var scopeShown = false
    package var outputName = ""
    package var outputAvailable = false
    package var headphoneName = ""
    package var importRefusal: String?
    package var total = 0
    package var filter = ""
    package var selected: UUID?
    package var preview: CurvePreview?
    package var applyRefusal: String?
    package var saveRefusal: String?
    package var suggestedName = ""
    package var notice: String?

    package init() {}
}

@MainActor
package final class SavedPresetsModel {
    package static let saveButtonLabel = "Save current EQ\u{2026}"
    package static let applyLabel = "Apply"
    package static let everyOutputLabel = "Every output"
    package static let useEverywhereLabel = "Use with every output"
    package static let noOutputNotice = "No default output is available, so this can only be saved for "
        + "every output."
    package static let headphonesHint = "Used to find measurements and corrections for the pair you "
        + "actually wear."
    package static let pasteName = "Pasted EQ"
    package static let addFromFileLabel = "Add from file\u{2026}"
    package static let addFromFileTitle = "Choose a parametric EQ file to keep in the library"
    package static let addFromFileHelp = "Add a parametric EQ file to the library without applying it."
    package static let pasteLabel = "Paste"
    package static let pasteHelp = "Add a correction from text on the clipboard \u{2014} the filter list as "
        + "published sites print it. Nothing is sent to the 5K."
    package static let exportTitle = "Save this preset as a parametric EQ file"
    package static let connectToImport = "Connect the 5K first \u{2014} a file is filed under its current "
        + "EQ mode."

    package static func thisOutputLabel(_ name: String) -> String {
        name.isEmpty ? "This output" : name
    }

    package static func useOnlyHereLabel(_ name: String) -> String {
        "Use only with " + (name.isEmpty ? "this output" : name)
    }

    package static func othersTitle(_ count: Int) -> String {
        "Other outputs (\(count))"
    }

    package static func exportFileName(_ name: String) -> String {
        let flat = name.replacingOccurrences(of: "/", with: "-")
        return (flat.isEmpty ? "preset" : flat) + ".txt"
    }

    package static let maxNameLength = Int32(PresetLibraryFile.maxNameLength)
    package static let deleteMessage = "This preset is only on this computer. It can\u{2019}t be "
        + "recovered."

    package static func deleteTitle(_ name: String) -> String {
        "Delete \u{201C}" + name + "\u{201D}?"
    }

    private unowned let host: AppModel
    private let store = PresetLibrary()

    var library: PresetLibrary { store }

    private var observers: [Int: (SavedPresetsState) -> Void] = [:]
    private var nextObserverID = 0
    package private(set) var state = SavedPresetsState()

    private var filter = ""
    private var selected: UUID?
    private var localNotice: String?
    private var applySummary: String?
    private var outputSource: (() -> LibraryOutputState)?
    private var routingObserver: (routing: OutputRouting, id: Int)?

    init(host: AppModel, fileURL: URL) {
        self.host = host
        store.currentCurve = { [weak host] in host?.eq.liveCurve() }
        store.onApply = { [weak self] preset in self?.perform(preset) ?? false }
        store.tracksDiskChanges = true
        store.start(fileURL: fileURL)
        host.addObserver { [weak self] _ in self?.publish() }
        host.eq.addObserver { [weak self] _ in self?.publish() }
    }

    package func useOutputs(_ source: (() -> LibraryOutputState)?) {
        outputSource = source
        publish()
    }

    package func attach(routing: OutputRouting) {
        if let routingObserver { routingObserver.routing.removeObserver(routingObserver.id) }
        useOutputs { [weak routing] in
            guard let routing, routing.connected else { return .unavailable }
            guard let sink = routing.realOutput else { return .noOutput }
            return .output(key: sink.name, name: sink.description.isEmpty ? sink.name : sink.description)
        }
        let id = routing.addObserver { [weak self] in self?.publish() }
        routingObserver = (routing, id)
    }

    private var output: LibraryOutputState { outputSource?() ?? .unavailable }

    private var scopeShown: Bool { output != .unavailable }

    @discardableResult
    package func addObserver(_ observer: @escaping (SavedPresetsState) -> Void) -> Int {
        nextObserverID += 1
        observers[nextObserverID] = observer
        observer(state)
        return nextObserverID
    }

    package func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    private var sorted: [LibraryPreset] {
        store.presets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func entry(_ id: UUID?) -> LibraryPreset? {
        guard let id else { return nil }
        return store.presets.first { $0.id == id }
    }

    package func setFilter(_ text: String) {
        guard text != filter else { return }
        filter = text
        publish()
    }

    package func select(_ id: UUID?) {
        guard selected != id, id == nil || entry(id) != nil else { return }
        selected = id
        applySummary = nil
        publish()
    }

    package func refusal(forApplying id: UUID, attempted: Bool = true) -> String? {
        guard let preset = entry(id) else { return "That preset is no longer in the library." }
        if let refusal = host.eq.writeRefusal(attempted: attempted) { return refusal }
        guard preset.group == host.eq.currentGroup else {
            return "\u{201C}\(preset.name)\u{201D} was made for the "
                + "\(preset.group.bandCount)-band EQ and the device is in "
                + "\(host.eq.bandCapacity)-band mode \u{2014} switch the device to "
                + "\(preset.group.bandCount)-band mode to use it."
        }
        return nil
    }

    package func refreshFromDisk() {
        if store.reloadIfChangedOnDisk() { publish() }
    }

    @discardableResult
    package func apply(_ id: UUID) -> Bool {
        refreshFromDisk()
        guard let preset = entry(id) else { return false }
        localNotice = nil
        applySummary = nil
        let accepted = store.apply(preset)
        publish()
        return accepted
    }

    private func perform(_ preset: LibraryPreset) -> Bool {
        var file = ParametricEQFile()
        file.preamp = preset.preGain
        file.bands = preset.bands
        let result = host.eq.apply(file, named: preset.name, undoLabel: "apply \(preset.name)")
        applySummary = result.accepted ? result.summary : nil
        return result.accepted
    }

    private func scope(onlyHere: Bool) -> LibraryScope {
        guard onlyHere, case .output(let key, let name) = output else { return .global }
        return .output(uid: key, name: name)
    }

    @discardableResult
    package func saveCurrent(name: String, onlyHere: Bool = false) -> Bool {
        refreshFromDisk()
        store.clearMessage()
        applySummary = nil
        guard let saved = store.saveCurrent(name: name, scope: scope(onlyHere: onlyHere)) else {
            localNotice = nil
            publish()
            return false
        }
        selected = saved.id
        localNotice = "Saved \u{201C}\(saved.name)\u{201D} to the library."
        publish()
        return true
    }

    @discardableResult
    func saveCurve(name: String, group: QxEqGroup, bands: [QxEqBandValue],
                   preGain: Double, source: String?) -> Bool {
        refreshFromDisk()
        store.clearMessage()
        guard let saved = store.saveCurve(name: name, group: group, bands: bands,
                                          preGain: preGain, sourceName: source) else {
            localNotice = nil
            publish()
            return false
        }
        selected = saved.id
        localNotice = "Saved \u{201C}\(saved.name)\u{201D} to the library."
        publish()
        return true
    }

    package func rename(_ id: UUID, to name: String) {
        refreshFromDisk()
        guard let preset = entry(id) else { return }
        store.rename(preset, to: name)
        publish()
    }

    package func delete(_ id: UUID) {
        refreshFromDisk()
        guard let preset = entry(id) else { return }
        store.delete(preset)
        if selected == id { selected = nil }
        localNotice = nil
        applySummary = nil
        publish()
    }

    package func useEverywhere(_ id: UUID) {
        refreshFromDisk()
        guard let preset = entry(id) else { return }
        store.setScope(preset, to: .global)
        publish()
    }

    package func useOnlyHere(_ id: UUID) {
        refreshFromDisk()
        guard let preset = entry(id), case .output(let key, let name) = output else { return }
        store.setScope(preset, to: .output(uid: key, name: name))
        publish()
    }

    @discardableResult
    package func importFile(at url: URL) -> Bool {
        refreshFromDisk()
        store.clearMessage()
        applySummary = nil
        localNotice = nil
        guard let saved = store.importFile(at: url, scope: scope(onlyHere: scopeShown)) else {
            publish()
            return false
        }
        selected = saved.id
        publish()
        return true
    }

    @discardableResult
    package func importText(_ text: String, name: String = SavedPresetsModel.pasteName) -> Bool {
        refreshFromDisk()
        store.clearMessage()
        applySummary = nil
        localNotice = nil
        guard let saved = store.importText(text, name: name, scope: scope(onlyHere: scopeShown)) else {
            publish()
            return false
        }
        selected = saved.id
        publish()
        return true
    }

    package func exportText(of id: UUID) -> String? {
        entry(id).map { store.exportText($0) }
    }

    @discardableResult
    package func exportFile(_ id: UUID, to url: URL) -> Bool {
        guard let preset = entry(id) else { return false }
        store.clearMessage()
        applySummary = nil
        localNotice = nil
        let written = store.exportFile(preset, to: url)
        if written {
            localNotice = "Exported \u{201C}\(preset.name)\u{201D}."
        }
        publish()
        return written
    }

    package func setHeadphoneName(_ name: String) {
        store.setHeadphoneName(name)
        publish()
    }

    package func flushPendingWrites() {
        store.flushPendingWrites()
    }

    package func name(of id: UUID) -> String? { entry(id)?.name }

    package func dismissNotice() {
        store.clearMessage()
        localNotice = nil
        applySummary = nil
        publish()
    }

    package func presetCount() -> Int { store.presets.count }

    private func publish() {
        var next = SavedPresetsState()
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let all = sorted
        let state = output
        next.total = all.count
        next.filter = filter
        next.scopeShown = state != .unavailable
        next.outputName = state.name
        next.outputAvailable = state.key != nil
        next.headphoneName = store.headphoneName
        func row(_ preset: LibraryPreset) -> SavedPreset {
            var shown = SavedPreset(id: preset.id, name: preset.name, detail: Self.detail(preset))
            if next.scopeShown {
                shown.canUseEverywhere = preset.scope != .global
                shown.canUseOnlyHere = state.key != nil && preset.scope.outputUID != state.key
            }
            return shown
        }
        let matching = all.filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
        if next.scopeShown {
            next.presets = matching.filter { $0.matches(outputUID: state.key) }.map(row)
            next.others = matching.filter { !$0.matches(outputUID: state.key) }.map(row)
        } else {
            next.presets = matching.map(row)
        }
        if let current = selected, entry(current) == nil { selected = nil }
        next.selected = selected
        if let chosen = entry(selected) {
            next.preview = LibraryFormat.preview(title: chosen.name, group: chosen.group,
                                                 bands: chosen.bands, preGain: chosen.preGain,
                                                 source: chosen.sourceName)
            next.applyRefusal = refusal(forApplying: chosen.id, attempted: false)
        }
        next.saveRefusal = host.eq.liveCurve() == nil
            ? "Connect the 5K to save its current EQ."
            : nil
        next.importRefusal = host.eq.liveCurve() == nil ? Self.connectToImport : nil
        next.suggestedName = host.eq.liveCurve()?.sourceName ?? ""
        next.notice = [store.lastMessage, localNotice, applySummary].compactMap { $0 }
            .joined(separator: " \u{00B7} ")
        if next.notice?.isEmpty == true { next.notice = nil }
        guard next != self.state else { return }
        self.state = next
        for observer in observers.values { observer(next) }
    }

    private static func detail(_ preset: LibraryPreset) -> String {
        var parts = [preset.groupLabel]
        if preset.scope != .global { parts.append(preset.scopeLabel) }
        if let source = preset.sourceName, !source.isEmpty, source != preset.name {
            parts.append(source)
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}
