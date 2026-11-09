import Foundation

package struct SavedPreset: Equatable {
    package var id: UUID
    package var name: String
    package var detail: String
}

package struct SavedPresetsState: Equatable {
    package var presets: [SavedPreset] = []
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
    package static let maxNameLength = Int32(PresetLibraryFile.maxNameLength)
    package static let deleteMessage = "This preset is only on this computer. It can\u{2019}t be "
        + "recovered."

    package static func deleteTitle(_ name: String) -> String {
        "Delete \u{201C}" + name + "\u{201D}?"
    }

    private unowned let host: AppModel
    private let store = PresetLibrary()

    private var observers: [Int: (SavedPresetsState) -> Void] = [:]
    private var nextObserverID = 0
    package private(set) var state = SavedPresetsState()

    private var filter = ""
    private var selected: UUID?
    private var localNotice: String?
    private var applySummary: String?

    init(host: AppModel, fileURL: URL) {
        self.host = host
        store.currentCurve = { [weak host] in host?.eq.liveCurve() }
        store.onApply = { [weak self] preset in self?.perform(preset) ?? false }
        store.tracksDiskChanges = true
        store.start(fileURL: fileURL)
        host.addObserver { [weak self] _ in self?.publish() }
        host.eq.addObserver { [weak self] _ in self?.publish() }
    }

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

    @discardableResult
    package func saveCurrent(name: String) -> Bool {
        refreshFromDisk()
        store.clearMessage()
        applySummary = nil
        guard let saved = store.saveCurrent(name: name, scope: .global) else {
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
        next.total = all.count
        next.filter = filter
        next.presets = all
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            .map { SavedPreset(id: $0.id, name: $0.name, detail: Self.detail($0)) }
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
        next.suggestedName = host.eq.liveCurve()?.sourceName ?? ""
        next.notice = [store.lastMessage, localNotice, applySummary].compactMap { $0 }
            .joined(separator: " \u{00B7} ")
        if next.notice?.isEmpty == true { next.notice = nil }
        guard next != state else { return }
        state = next
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
