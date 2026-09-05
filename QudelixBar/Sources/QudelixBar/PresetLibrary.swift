import Foundation

enum LibraryScope: Equatable, Hashable {
    case global
    case output(uid: String, name: String)

    var outputUID: String? {
        if case .output(let uid, _) = self { return uid }
        return nil
    }

    var outputName: String? {
        if case .output(_, let name) = self { return name }
        return nil
    }
}

struct LibraryPreset: Identifiable, Equatable {
    var id: UUID
    var name: String
    var scope: LibraryScope
    var group: QxEqGroup
    var bands: [QxEqBandValue]
    var preGain: Double
    var sourceName: String?

    init(id: UUID = UUID(), name: String, scope: LibraryScope = .global,
         group: QxEqGroup, bands: [QxEqBandValue], preGain: Double,
         sourceName: String? = nil) {
        self.id = id
        self.name = name
        self.scope = scope
        self.group = group
        self.bands = bands
        self.preGain = preGain
        self.sourceName = sourceName
    }

    var groupLabel: String { "\(group.bandCount)-band" }

    var scopeLabel: String {
        switch scope {
        case .global: return "Every output"
        case .output(_, let name): return name.isEmpty ? "One output" : name
        }
    }

    func matches(outputUID: String?) -> Bool {
        switch scope {
        case .global: return true
        case .output(let uid, _): return uid == outputUID
        }
    }
}

extension LibraryPreset: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, outputUID, outputName, groupRaw, bands, preGain, sourceName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let raw = try? c.decode(UInt8.self, forKey: .groupRaw),
              let group = QxEqGroup(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .groupRaw, in: c,
                debugDescription: "no EQ group with that id")
        }
        self.group = group
        bands = (try? c.decode([QxEqBandValue].self, forKey: .bands)) ?? []
        preGain = (try? c.decode(Double.self, forKey: .preGain)) ?? 0
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        sourceName = try? c.decode(String.self, forKey: .sourceName)
        if let uid = try? c.decode(String.self, forKey: .outputUID), !uid.isEmpty {
            scope = .output(uid: uid,
                            name: (try? c.decode(String.self, forKey: .outputName)) ?? "")
        } else {
            scope = .global
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(group.rawValue, forKey: .groupRaw)
        try c.encode(bands, forKey: .bands)
        try c.encode(preGain, forKey: .preGain)
        try c.encodeIfPresent(sourceName, forKey: .sourceName)
        if case .output(let uid, let name) = scope {
            try c.encode(uid, forKey: .outputUID)
            try c.encode(name, forKey: .outputName)
        }
    }
}

struct PresetLibraryDocument: Equatable {
    var schemaVersion: Int
    var headphoneName: String
    var suggestedHeadphones: [String]
    var presets: [LibraryPreset]

    init(schemaVersion: Int = PresetLibraryFile.currentSchemaVersion,
         headphoneName: String = "", suggestedHeadphones: [String] = [],
         presets: [LibraryPreset] = []) {
        self.schemaVersion = schemaVersion
        self.headphoneName = headphoneName
        self.suggestedHeadphones = suggestedHeadphones
        self.presets = presets
    }
}

private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension PresetLibraryDocument: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, headphoneName, suggestedHeadphones, presets
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 0
            headphoneName = (try? c.decode(String.self, forKey: .headphoneName)) ?? ""
            suggestedHeadphones = (try? c.decode([String].self,
                                                 forKey: .suggestedHeadphones)) ?? []
            let rows = (try? c.decode([FailableDecodable<LibraryPreset>].self,
                                      forKey: .presets)) ?? []
            presets = rows.compactMap(\.value)
            return
        }
        let rows = try decoder.singleValueContainer()
            .decode([FailableDecodable<LibraryPreset>].self)
        schemaVersion = 0
        headphoneName = ""
        suggestedHeadphones = []
        presets = rows.compactMap(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(PresetLibraryFile.currentSchemaVersion, forKey: .schemaVersion)
        try c.encode(headphoneName, forKey: .headphoneName)
        try c.encode(suggestedHeadphones, forKey: .suggestedHeadphones)
        try c.encode(presets, forKey: .presets)
    }
}

enum PresetLibraryFile {
    static var url: URL {
        StageStateFile.directory.appendingPathComponent("presets.json")
    }

    static let currentSchemaVersion = 1
    static let maxPresets = 512
    static let maxNameLength = 64
    static let maxOutputUIDBytes = 512
    static let maxSuggestedNames = 64
    private static let maxBytes = 2_000_000

    static func load(from fileURL: URL = url) -> PresetLibraryDocument? {
        guard let data = SafeFile.read(fileURL, cap: maxBytes) else {
            return PresetLibraryDocument()
        }
        guard let decoded = try? JSONDecoder().decode(PresetLibraryDocument.self,
                                                      from: data) else {
            let parked = fileURL.deletingLastPathComponent()
                .appendingPathComponent(fileURL.lastPathComponent + ".recovered")
            SafeFile.writeAtomic(data, to: parked)
            return nil
        }
        return sanitize(decoded)
    }

    static func sanitize(_ document: PresetLibraryDocument) -> PresetLibraryDocument {
        var seen = Set<UUID>()
        var out: [LibraryPreset] = []
        for var preset in document.presets {
            preset.name = QudelixController.displayName(preset.name, limit: maxNameLength)
            if preset.name.isEmpty { preset.name = "Untitled" }
            if case .output(let uid, let name) = preset.scope {
                if uid.isEmpty || uid.utf8.count > maxOutputUIDBytes {
                    preset.scope = .global
                } else {
                    preset.scope = .output(
                        uid: uid,
                        name: QudelixController.displayName(name, limit: maxNameLength))
                }
            }
            preset.sourceName = preset.sourceName
                .map { QudelixController.displayName($0, limit: maxNameLength) }
                .flatMap { $0.isEmpty ? nil : $0 }
            preset.preGain = EQHeadroom.clamp(preset.preGain)
            preset.bands = preset.bands.prefix(preset.group.bandCount).map(clamped)
            guard !preset.bands.isEmpty else { continue }
            if !seen.insert(preset.id).inserted {
                preset.id = UUID()
                seen.insert(preset.id)
            }
            out.append(preset)
            if out.count == maxPresets { break }
        }
        return PresetLibraryDocument(
            schemaVersion: currentSchemaVersion,
            headphoneName: QudelixController.displayName(document.headphoneName,
                                                         limit: maxNameLength),
            suggestedHeadphones: trimmedSuggestions(document.suggestedHeadphones),
            presets: out)
    }

    static func trimmedSuggestions(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in raw.reversed() {
            let key = String(SafeText.scrubbed(name, limit: maxNameLength)
                .prefix(maxNameLength))
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(key)
            if out.count == maxSuggestedNames { break }
        }
        return out.reversed()
    }

    static func clamped(_ band: QxEqBandValue) -> QxEqBandValue {
        var b = band
        b.freq = min(max(b.freq, 20), 20000)
        b.gain = b.gain.isFinite ? min(max(b.gain, -12), 12) : 0
        b.q = b.q.isFinite ? min(max(b.q, 0.1), 10) : 1.0
        return b
    }

    static func save(_ document: PresetLibraryDocument, to fileURL: URL = url) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sanitize(document)) else { return }
        SafeFile.writeAtomic(data, to: fileURL)
    }
}

@MainActor
final class PresetLibrary: ObservableObject {
    struct LiveCurve {
        var bands: [QxEqBandValue]
        var preGain: Double
        var group: QxEqGroup
        var sourceName: String?
    }

    @Published private(set) var presets: [LibraryPreset] = []
    @Published private(set) var headphoneName = ""
    @Published private(set) var suggestedHeadphones: [String] = []
    @Published private(set) var lastMessage: String?

    var currentCurve: (() -> LiveCurve?)?
    var onApply: ((LibraryPreset) -> Bool)?

    private var fileURL = PresetLibraryFile.url
    private var started = false
    private var persistable = true

    func start(fileURL url: URL = PresetLibraryFile.url) {
        guard !started else { return }
        started = true
        fileURL = url
        guard let document = PresetLibraryFile.load(from: url) else {
            persistable = false
            DebugLog.shared.log("preset library file could not be read; "
                                + "kept as presets.json.recovered and left alone")
            return
        }
        presets = document.presets
        headphoneName = document.headphoneName
        suggestedHeadphones = document.suggestedHeadphones
    }

    var currentGroup: QxEqGroup? { currentCurve?()?.group }

    func visible(for outputUID: String?) -> [LibraryPreset] {
        sorted(presets.filter { $0.matches(outputUID: outputUID) })
    }

    func otherOutputs(for outputUID: String?) -> [LibraryPreset] {
        sorted(presets.filter { !$0.matches(outputUID: outputUID) })
    }

    private func sorted(_ list: [LibraryPreset]) -> [LibraryPreset] {
        list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func saveCurrent(name: String, scope: LibraryScope) -> LibraryPreset? {
        guard let live = currentCurve?() else {
            lastMessage = "The 5K isn't connected, so there is no curve to save."
            return nil
        }
        guard !live.bands.isEmpty else {
            lastMessage = "The device hasn't reported a curve yet."
            return nil
        }
        return insert(LibraryPreset(
            name: name, scope: scope, group: live.group,
            bands: Array(live.bands.prefix(live.group.bandCount)),
            preGain: live.preGain, sourceName: live.sourceName))
    }

    @discardableResult
    func saveCurve(name: String, group: QxEqGroup, bands: [QxEqBandValue],
                   preGain: Double, sourceName: String? = nil,
                   scope: LibraryScope = .global) -> LibraryPreset? {
        guard !bands.isEmpty else {
            lastMessage = "That preset has no filters in it."
            return nil
        }
        return insert(LibraryPreset(name: name, scope: scope, group: group,
                                    bands: Array(bands.prefix(group.bandCount)),
                                    preGain: preGain, sourceName: sourceName))
    }

    @discardableResult
    func importText(_ text: String, name: String,
                    scope: LibraryScope = .global) -> LibraryPreset? {
        guard let group = currentGroup else {
            lastMessage = "Connect the 5K first — a saved preset records which of "
                + "the device's two EQ banks it was made for."
            return nil
        }
        guard text.utf8.count <= QudelixController.maxImportBytes else {
            lastMessage = "That is too much text to be an EQ preset."
            return nil
        }
        guard let parsed = ParametricEQFile.parse(text), !parsed.bands.isEmpty else {
            lastMessage = "No EQ filters found in what was pasted."
            return nil
        }
        let dropped = parsed.droppedBands
            + max(0, parsed.bands.count - group.bandCount)
        let saved = insert(LibraryPreset(
            name: name, scope: scope, group: group,
            bands: Array(parsed.bands.prefix(group.bandCount)),
            preGain: EQHeadroom.clamp(parsed.preamp), sourceName: name))
        guard saved != nil else { return nil }
        var notes = ["Added to the library — nothing has been sent to the 5K."]
        if dropped > 0 {
            notes.append("\(dropped) band(s) dropped, past the \(group.bandCount) "
                         + "this bank holds")
        }
        notes.append(contentsOf: parsed.notes)
        lastMessage = notes.joined(separator: " · ")
        return saved
    }

    @discardableResult
    func importFile(at url: URL, scope: LibraryScope = .global) -> LibraryPreset? {
        let shown = QudelixController.displayName(url.lastPathComponent,
                                                  limit: PresetLibraryFile.maxNameLength)
        guard let data = SafeFile.read(url, cap: QudelixController.maxImportBytes) else {
            lastMessage = "Couldn't read \(shown) — an EQ preset is a plain text file, "
                + "and not a large one."
            return nil
        }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            lastMessage = "Could not read \(shown) as text."
            return nil
        }
        return importText(text,
                          name: url.deletingPathExtension().lastPathComponent,
                          scope: scope)
    }

    private func insert(_ preset: LibraryPreset) -> LibraryPreset? {
        guard presets.count < PresetLibraryFile.maxPresets else {
            lastMessage = "The library is full at \(PresetLibraryFile.maxPresets) "
                + "presets. Delete one to make room."
            return nil
        }
        var p = preset
        p.name = freeName(cleaned(p.name, fallback: "Untitled"), in: p.scope, excluding: nil)
        p.bands = p.bands.map(PresetLibraryFile.clamped)
        p.preGain = EQHeadroom.clamp(p.preGain)
        guard !p.bands.isEmpty else {
            lastMessage = "That preset has no filters in it."
            return nil
        }
        presets.append(p)
        lastMessage = nil
        persist()
        return p
    }

    @discardableResult
    func apply(_ preset: LibraryPreset) -> Bool {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return false }
        let stored = presets[index]
        guard let live = currentCurve?() else {
            lastMessage = "The 5K isn't connected, so there is nothing to apply this to."
            return false
        }
        guard live.group == stored.group else {
            lastMessage = "\u{201C}\(stored.name)\u{201D} was made for the "
                + "\(stored.group.bandCount)-band EQ and the device is in "
                + "\(live.group.bandCount)-band mode. Those are two separate banks with "
                + "different numbers of bands, so this curve is not stretched to fit — "
                + "switch the device to \(stored.group.bandCount)-band mode to use it."
            return false
        }
        guard onApply?(stored) == true else {
            lastMessage = "\u{201C}\(stored.name)\u{201D} wasn't applied — the device "
                + "isn't taking EQ writes right now."
            return false
        }
        lastMessage = nil
        return true
    }

    func rename(_ preset: LibraryPreset, to name: String) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        let wanted = cleaned(name, fallback: "")
        guard !wanted.isEmpty else { return }
        presets[index].name = freeName(wanted, in: presets[index].scope,
                                       excluding: presets[index].id)
        persist()
    }

    func delete(_ preset: LibraryPreset) {
        let before = presets.count
        presets.removeAll { $0.id == preset.id }
        guard presets.count != before else { return }
        persist()
    }

    func setScope(_ preset: LibraryPreset, to scope: LibraryScope) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        var clean = scope
        if case .output(let uid, let name) = scope {
            guard !uid.isEmpty, uid.utf8.count <= PresetLibraryFile.maxOutputUIDBytes else {
                return
            }
            clean = .output(uid: uid,
                            name: cleaned(name, fallback: ""))
        }
        guard clean != presets[index].scope else { return }
        presets[index].scope = clean
        presets[index].name = freeName(presets[index].name, in: clean,
                                       excluding: presets[index].id)
        persist()
    }

    nonisolated func exportText(_ preset: LibraryPreset) -> String {
        QudelixController.exportText(bands: preset.bands, preGain: preset.preGain)
    }

    func setHeadphoneName(_ name: String) {
        let clean = cleaned(name, fallback: "")
        guard clean != headphoneName else { return }
        headphoneName = clean
        persist()
    }

    func hasSuggested(_ key: String) -> Bool {
        !key.isEmpty && suggestedHeadphones.contains(key)
    }

    func markSuggested(_ key: String) {
        guard !key.isEmpty else { return }
        suggestedHeadphones.removeAll { $0 == key }
        suggestedHeadphones.append(key)
        let over = suggestedHeadphones.count - PresetLibraryFile.maxSuggestedNames
        if over > 0 { suggestedHeadphones.removeFirst(over) }
        persist()
    }

    func clearMessage() { lastMessage = nil }

    private func cleaned(_ name: String, fallback: String) -> String {
        let clean = QudelixController.displayName(name,
                                                  limit: PresetLibraryFile.maxNameLength)
        return clean.isEmpty ? fallback : clean
    }

    private func freeName(_ base: String, in scope: LibraryScope,
                          excluding id: UUID?) -> String {
        let taken = Set(presets.filter { $0.scope == scope && $0.id != id }.map(\.name))
        return Self.uniqueName(base, taken: taken)
    }

    nonisolated static func uniqueName(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        for n in 2...(taken.count + 2) where !taken.contains("\(base) \(n)") {
            return "\(base) \(n)"
        }
        return base
    }

    private func persist() {
        guard persistable else { return }
        PresetLibraryFile.save(
            PresetLibraryDocument(headphoneName: headphoneName,
                                  suggestedHeadphones: suggestedHeadphones,
                                  presets: presets),
            to: fileURL)
    }

    #if DEBUG
    func previewSet(presets: [LibraryPreset], headphoneName: String = "",
                    suggestedHeadphones: [String] = [], message: String? = nil) {
        self.presets = presets
        self.headphoneName = headphoneName
        self.suggestedHeadphones = suggestedHeadphones
        lastMessage = message
        started = true
        persistable = false
    }
    #endif
}
