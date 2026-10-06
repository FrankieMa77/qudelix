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
        let bandRows = (try? c.decode([FailableDecodable<QxEqBandValue>].self,
                                      forKey: .bands)) ?? []
        bands = bandRows.compactMap(\.value)
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
    var appAssignments: [AppAssignment]

    init(schemaVersion: Int = PresetLibraryFile.currentSchemaVersion,
         headphoneName: String = "", suggestedHeadphones: [String] = [],
         presets: [LibraryPreset] = [], appAssignments: [AppAssignment] = []) {
        self.schemaVersion = schemaVersion
        self.headphoneName = headphoneName
        self.suggestedHeadphones = suggestedHeadphones
        self.presets = presets
        self.appAssignments = appAssignments
    }
}

enum ParkedCopy {
    static let maxCopies = 9

    static func candidates(beside fileURL: URL) -> [URL] {
        let folder = fileURL.deletingLastPathComponent()
        let name = fileURL.lastPathComponent
        return [folder.appendingPathComponent(name + ".recovered")]
            + (2...maxCopies).map { folder.appendingPathComponent(name + ".recovered-\($0)") }
    }

    @discardableResult
    static func park(_ data: Data, beside fileURL: URL) -> URL? {
        let fm = FileManager.default
        func taken(_ candidate: URL) -> Bool {
            fm.fileExists(atPath: candidate.path)
                || (try? fm.destinationOfSymbolicLink(atPath: candidate.path)) != nil
        }
        let all = candidates(beside: fileURL)
        for candidate in all where taken(candidate) {
            if SafeFile.read(candidate, cap: data.count) == data { return candidate }
        }
        let target = all.first { !taken($0) } ?? all[0]
        return SafeFile.writeAtomic(data, to: target) ? target : nil
    }
}

struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension PresetLibraryDocument: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, headphoneName, suggestedHeadphones, presets
        case appAssignments
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
            let assigned = (try? c.decode([FailableDecodable<AppAssignment>].self,
                                          forKey: .appAssignments)) ?? []
            appAssignments = assigned.compactMap(\.value)
            return
        }
        let rows = try decoder.singleValueContainer()
            .decode([FailableDecodable<LibraryPreset>].self)
        schemaVersion = 0
        headphoneName = ""
        suggestedHeadphones = []
        presets = rows.compactMap(\.value)
        appAssignments = []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(PresetLibraryFile.currentSchemaVersion, forKey: .schemaVersion)
        try c.encode(headphoneName, forKey: .headphoneName)
        try c.encode(suggestedHeadphones, forKey: .suggestedHeadphones)
        try c.encode(presets, forKey: .presets)
        try c.encode(appAssignments, forKey: .appAssignments)
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

    enum Outcome {
        case loaded(PresetLibraryDocument)
        case recovered(PresetLibraryDocument, parked: String)
        case unreadable
        case undecodable(parked: String)
        case newer(Int, parked: String)
    }

    static func load(from fileURL: URL = url) -> PresetLibraryDocument? {
        switch outcome(from: fileURL) {
        case .loaded(let document), .recovered(let document, _): return document
        case .unreadable, .undecodable, .newer: return nil
        }
    }

    static func outcome(from fileURL: URL = url) -> Outcome {
        guard let data = SafeFile.read(fileURL, cap: maxBytes) else {
            return hasContent(fileURL) ? .unreadable : .loaded(PresetLibraryDocument())
        }
        guard let shape = Shape(data) else {
            return .undecodable(parked: park(data, beside: fileURL))
        }
        if shape.schemaVersion > currentSchemaVersion {
            return .newer(shape.schemaVersion, parked: park(data, beside: fileURL))
        }
        guard shape.hasPresets,
              let decoded = try? JSONDecoder().decode(PresetLibraryDocument.self,
                                                      from: data) else {
            return .undecodable(parked: park(data, beside: fileURL))
        }
        let clean = sanitize(decoded)
        guard shape.accounts(for: clean) else {
            return .recovered(clean, parked: park(data, beside: fileURL))
        }
        return .loaded(clean)
    }

    private struct Shape {
        var schemaVersion = 0
        var hasPresets = false
        var presetCount = 0
        var bandCount = 0
        var assignmentCount = 0

        init?(_ data: Data) {
            guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
            var rows: [Any] = []
            if let list = root as? [Any] {
                hasPresets = true
                rows = list
            } else if let object = root as? [String: Any] {
                schemaVersion = (object["schemaVersion"] as? Int) ?? 0
                if let list = object["presets"] as? [Any] {
                    hasPresets = true
                    rows = list
                }
                assignmentCount = (object["appAssignments"] as? [Any])?.count ?? 0
            } else {
                return nil
            }
            presetCount = rows.count
            for case let row as [String: Any] in rows {
                bandCount += (row["bands"] as? [Any])?.count ?? 0
            }
        }

        func accounts(for document: PresetLibraryDocument) -> Bool {
            document.presets.count == presetCount
                && document.presets.reduce(0) { $0 + $1.bands.count } == bandCount
                && document.appAssignments.count == assignmentCount
        }
    }

    private static func park(_ data: Data, beside fileURL: URL) -> String {
        ParkedCopy.park(data, beside: fileURL)?.lastPathComponent
            ?? fileURL.lastPathComponent + ".recovered"
    }

    private static func hasContent(_ fileURL: URL) -> Bool {
        var info = stat()
        let found = fileURL.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return lstat(path, &info) == 0
        }
        guard found else { return false }
        if info.st_mode & S_IFMT == S_IFREG, info.st_size == 0 { return false }
        return true
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
            presets: out,
            appAssignments: AppAssignments.sanitized(document.appAssignments))
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

    @discardableResult
    static func save(_ document: PresetLibraryDocument, to fileURL: URL = url) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sanitize(document)) else { return false }
        return SafeFile.writeAtomic(data, to: fileURL)
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
    @Published private(set) var appAssignments: [AppAssignment] = []
    @Published private(set) var headphoneName = ""
    @Published private(set) var committedHeadphoneName = ""
    @Published private(set) var suggestedHeadphones: [String] = []
    @Published private(set) var lastMessage: String?

    var currentCurve: (() -> LiveCurve?)?
    var onApply: ((LibraryPreset) -> Bool)?
    var nameCommitDelay: TimeInterval = 0.8

    private var fileURL = PresetLibraryFile.url
    private var started = false
    private var persistable = true
    private var transientMessage: String?
    private var readOnlyNotice: String?
    private var writeFailureNotice: String?
    private var nameWindow: DispatchWorkItem?
    private var nameUnsettled = false
    private var parkedSuggestion: String?

    func start(fileURL url: URL = PresetLibraryFile.url) {
        guard !started else { return }
        started = true
        fileURL = url
        let name = url.lastPathComponent
        let document: PresetLibraryDocument
        switch PresetLibraryFile.outcome(from: url) {
        case .loaded(let loaded):
            document = loaded
        case .recovered(let loaded, let parked):
            document = loaded
            say("Some entries in \(name) couldn't be understood and were left out. "
                + "The original is kept beside it as \(parked).")
            DebugLog.shared.log("preset library had entries that could not be read; "
                                + "original kept as \(parked)")
        case .undecodable(let parked):
            holdReadOnly("\(name) couldn't be understood, so the saved library is "
                         + "left alone. A copy is kept beside it as \(parked).")
            DebugLog.shared.log("preset library file could not be decoded; "
                                + "kept as \(parked) and left alone")
            return
        case .newer(let version, let parked):
            holdReadOnly("\(name) was written by a newer QudelixBar (format \(version)), "
                         + "so the saved library is left alone. A copy is kept beside it "
                         + "as \(parked).")
            DebugLog.shared.log("preset library file is format \(version), newer than "
                                + "this build; kept as \(parked) and left alone")
            return
        case .unreadable:
            holdReadOnly("\(name) couldn't be read, so the saved library is left "
                         + "alone. Check the file's permissions and its size.")
            DebugLog.shared.log("preset library file could not be read; left alone")
            return
        }
        presets = document.presets
        appAssignments = document.appAssignments
        headphoneName = document.headphoneName
        committedHeadphoneName = document.headphoneName
        suggestedHeadphones = document.suggestedHeadphones
    }

    private func holdReadOnly(_ reason: String) {
        persistable = false
        readOnlyNotice = reason + " Anything saved now stays in memory only and is "
            + "lost when the app quits."
        publishMessage()
    }

    private func say(_ text: String?) {
        transientMessage = text
        publishMessage()
    }

    private func publishMessage() {
        let parts = [transientMessage, readOnlyNotice ?? writeFailureNotice]
            .compactMap { $0 }
        lastMessage = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func setAppAssignments(_ next: [AppAssignment]) {
        let clean = AppAssignments.sanitized(next)
        guard clean != appAssignments else { return }
        appAssignments = clean
        persist()
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
            say("The 5K isn't connected, so there is no curve to save.")
            return nil
        }
        guard !live.bands.isEmpty else {
            say("The device hasn't reported a curve yet.")
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
            say("That preset has no filters in it.")
            return nil
        }
        return insert(LibraryPreset(name: name, scope: scope, group: group,
                                    bands: Array(bands.prefix(group.bandCount)),
                                    preGain: preGain, sourceName: sourceName))
    }

    @discardableResult
    func importText(_ text: String, name: String,
                    scope: LibraryScope = .global,
                    origin: String = "what was pasted") -> LibraryPreset? {
        guard let group = currentGroup else {
            say("Connect the 5K first — a saved preset records which of "
                + "the device's two EQ banks it was made for.")
            return nil
        }
        guard text.utf8.count <= QudelixController.maxImportBytes else {
            say("That is too much text to be an EQ preset.")
            return nil
        }
        guard let parsed = ParametricEQFile.parse(text), !parsed.bands.isEmpty else {
            say("No EQ filters found in \(origin).")
            return nil
        }
        let fitted = parsed.fitted(toBandCount: group.bandCount)
        let saved = insert(LibraryPreset(
            name: name, scope: scope, group: group,
            bands: fitted.bands,
            preGain: EQHeadroom.clamp(fitted.preamp), sourceName: name))
        guard saved != nil else { return nil }
        var notes = ["Added to the library — nothing has been sent to the 5K."]
        if fitted.droppedBands > 0 {
            notes.append("\(fitted.droppedBands) band(s) dropped, past the "
                         + "\(group.bandCount) this bank holds")
        }
        notes.append(contentsOf: fitted.notes)
        say(notes.joined(separator: " · "))
        return saved
    }

    @discardableResult
    func importFile(at url: URL, scope: LibraryScope = .global) -> LibraryPreset? {
        let shown = QudelixController.displayName(url.lastPathComponent,
                                                  limit: PresetLibraryFile.maxNameLength)
        guard let data = SafeFile.read(url, cap: QudelixController.maxImportBytes) else {
            say("Couldn't read \(shown) — an EQ preset is a plain text file, "
                + "and not a large one.")
            return nil
        }
        guard let text = ParametricEQFile.decodeText(data) else {
            say("Could not read \(shown) as text.")
            return nil
        }
        return importText(text,
                          name: url.deletingPathExtension().lastPathComponent,
                          scope: scope, origin: shown)
    }

    private func insert(_ preset: LibraryPreset) -> LibraryPreset? {
        guard presets.count < PresetLibraryFile.maxPresets else {
            say("The library is full at \(PresetLibraryFile.maxPresets) "
                + "presets. Delete one to make room.")
            return nil
        }
        var p = preset
        p.name = freeName(cleaned(p.name, fallback: "Untitled"), in: p.scope, excluding: nil)
        p.bands = p.bands.map(PresetLibraryFile.clamped)
        p.preGain = EQHeadroom.clamp(p.preGain)
        guard !p.bands.isEmpty else {
            say("That preset has no filters in it.")
            return nil
        }
        presets.append(p)
        say(nil)
        persist()
        return p
    }

    @discardableResult
    func apply(_ preset: LibraryPreset) -> Bool {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return false }
        let stored = presets[index]
        guard let live = currentCurve?() else {
            say("The 5K isn't connected, so there is nothing to apply this to.")
            return false
        }
        guard live.group == stored.group else {
            say("\u{201C}\(stored.name)\u{201D} was made for the "
                + "\(stored.group.bandCount)-band EQ and the device is in "
                + "\(live.group.bandCount)-band mode. Those are two separate banks with "
                + "different numbers of bands, so this curve is not stretched to fit — "
                + "switch the device to \(stored.group.bandCount)-band mode to use it.")
            return false
        }
        guard onApply?(stored) == true else {
            say("\u{201C}\(stored.name)\u{201D} wasn't applied — the device "
                + "isn't taking EQ writes right now.")
            return false
        }
        say(nil)
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

    @discardableResult
    func exportFile(_ preset: LibraryPreset, to url: URL) -> Bool {
        do {
            try exportText(preset).write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            let shown = QudelixController.displayName(url.lastPathComponent,
                                                      limit: PresetLibraryFile.maxNameLength)
            say("Couldn't save \(shown) — check that the folder is writable "
                + "and the disk has room.")
            return false
        }
    }

    func setHeadphoneName(_ name: String) {
        let clean = cleaned(name, fallback: "")
        guard clean != headphoneName else { return }
        headphoneName = clean
        if nameWindow == nil {
            settleHeadphoneName()
        } else {
            nameUnsettled = true
        }
        openNameWindow()
    }

    func flushPendingWrites() {
        nameWindow?.cancel()
        nameWindow = nil
        if nameUnsettled { settleHeadphoneName() }
    }

    private func openNameWindow() {
        nameWindow?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.closeNameWindow() }
        nameWindow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + nameCommitDelay, execute: work)
    }

    private func closeNameWindow() {
        nameWindow = nil
        if nameUnsettled { settleHeadphoneName() }
    }

    private func settleHeadphoneName() {
        nameUnsettled = false
        committedHeadphoneName = headphoneName
        persist()
        guard let key = parkedSuggestion else { return }
        parkedSuggestion = nil
        if HeadphoneSuggestions.normalized(headphoneName) == key { recordSuggested(key) }
    }

    func hasSuggested(_ key: String) -> Bool {
        !key.isEmpty && suggestedHeadphones.contains(key)
    }

    func markSuggested(_ key: String) {
        guard !key.isEmpty else { return }
        if nameUnsettled {
            parkedSuggestion = key
            return
        }
        recordSuggested(key)
    }

    private func recordSuggested(_ key: String) {
        suggestedHeadphones.removeAll { $0 == key }
        suggestedHeadphones.append(key)
        let over = suggestedHeadphones.count - PresetLibraryFile.maxSuggestedNames
        if over > 0 { suggestedHeadphones.removeFirst(over) }
        persist()
    }

    func clearMessage() {
        transientMessage = nil
        lastMessage = nil
    }

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
        let written = PresetLibraryFile.save(
            PresetLibraryDocument(headphoneName: headphoneName,
                                  suggestedHeadphones: suggestedHeadphones,
                                  presets: presets,
                                  appAssignments: appAssignments),
            to: fileURL)
        if written {
            guard writeFailureNotice != nil else { return }
            writeFailureNotice = nil
            DebugLog.shared.log("preset library is being written again")
        } else {
            let first = writeFailureNotice == nil
            writeFailureNotice = "Couldn't write \(fileURL.lastPathComponent) — the "
                + "change is only in memory and will be lost when the app quits."
            if first {
                DebugLog.shared.log("preset library could not be written; "
                                    + "changes are held in memory")
            }
        }
        publishMessage()
    }

    #if DEBUG
    func previewSet(presets: [LibraryPreset], headphoneName: String = "",
                    suggestedHeadphones: [String] = [], message: String? = nil,
                    appAssignments: [AppAssignment] = []) {
        self.presets = presets
        self.appAssignments = AppAssignments.sanitized(appAssignments)
        self.headphoneName = headphoneName
        self.committedHeadphoneName = headphoneName
        self.suggestedHeadphones = suggestedHeadphones
        transientMessage = message
        lastMessage = message
        started = true
        persistable = false
    }
    #endif
}
