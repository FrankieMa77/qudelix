import Foundation
#if canImport(Glibc)
import Glibc
#endif

struct EqHistoryEntry: Codable, Equatable {
    var recordedAt: Date
    var label: String
    var snapshot: EqSnapshot
}

struct EqHistory: Codable, Equatable {
    var entries: [EqHistoryEntry] = []

    init() {}
    init(entries: [EqHistoryEntry]) { self.entries = entries }

    private enum CodingKeys: String, CodingKey { case entries }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([EqHistoryEntry].self, forKey: .entries) ?? []
    }

    var newestFirst: [EqHistoryEntry] { Array(entries.reversed()) }

    func entry(at position: Int) -> EqHistoryEntry? {
        let list = newestFirst
        guard position >= 1, position <= list.count else { return nil }
        return list[position - 1]
    }
}

enum EqHistoryFile {
    static var directoryOverride: URL?

    static var url: URL {
        (directoryOverride ?? StageStateFile.directory)
            .appendingPathComponent("eq-history.json")
    }

    static let depth = 40
    static let maxLabelLength = 64
    private static let maxBytes = 500_000

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func load(from fileURL: URL = url) -> EqHistory {
        guard let data = SafeFile.read(fileURL, cap: maxBytes) else { return EqHistory() }
        guard let history = try? decoder.decode(EqHistory.self, from: data) else {
            let parked = fileURL.deletingLastPathComponent()
                .appendingPathComponent(fileURL.lastPathComponent + ".recovered")
            SafeFile.writeAtomic(data, to: parked)
            return EqHistory()
        }
        return EqHistory(entries: history.entries.suffix(depth).map(sanitized))
    }

    static func append(_ entry: EqHistoryEntry, to fileURL: URL = url) {
        var history = load(from: fileURL)
        history.entries.append(sanitized(entry))
        history.entries = Array(history.entries.suffix(depth))
        save(history, to: fileURL)
    }

    static func save(_ history: EqHistory, to fileURL: URL = url) {
        var trimmed = history
        let writer = encoder
        while true {
            guard let data = try? writer.encode(trimmed) else { return }
            if data.count <= maxBytes || trimmed.entries.count <= 1 {
                SafeFile.writeAtomic(data, to: fileURL)
                return
            }
            trimmed.entries.removeFirst()
        }
    }

    static func clear(at fileURL: URL = url) {
        _ = fileURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return unlink(path)
        }
    }

    private static func sanitized(_ entry: EqHistoryEntry) -> EqHistoryEntry {
        var result = entry
        result.label = QudelixController.displayName(entry.label, limit: maxLabelLength)
        var snapshot = entry.snapshot
        snapshot.name = snapshot.name.map { QudelixController.displayName($0) }
        snapshot.preGain = EQHeadroom.clamp(snapshot.preGain)
        snapshot.bands = snapshot.bands.prefix(QxEq.maxBandCount).map(QxSession.clamped)
        result.snapshot = snapshot
        return result
    }
}

enum HistoryCommand: CLIFamily {
    case list
    case show(Int)
    case restore(Int)
    case clear

    static let name = "history"

    static let usageLines: [String] = [
        usage("history list", "every recorded EQ edit, newest first"),
        usage("history show <n>", "the curve entry <n> would put back"),
        usage("history restore <n>", "write the curve of entry <n> to the device"),
        usage("history clear", "forget every recorded entry"),
    ]

    private static func usage(_ command: String, _ description: String) -> String {
        "  " + QxFormat.pad(command, 26) + description
    }

    static func parse(_ rest: [String]) throws -> HistoryCommand {
        guard let sub = rest.first else {
            throw CLIUsageError(message: "history needs list, show, restore or clear")
        }
        let arguments = Array(rest.dropFirst())
        switch sub {
        case "list":
            try requireNoArguments(arguments, after: "history list")
            return .list
        case "clear":
            try requireNoArguments(arguments, after: "history clear")
            return .clear
        case "show":
            return .show(try position(arguments, after: "history show"))
        case "restore":
            return .restore(try position(arguments, after: "history restore"))
        default:
            throw CLIUsageError(
                message: "history needs list, show, restore or clear — not \(sub)")
        }
    }

    private static func requireNoArguments(_ arguments: [String], after what: String) throws {
        guard arguments.isEmpty else {
            throw CLIUsageError(message: "\(what) takes no arguments")
        }
    }

    private static func position(_ arguments: [String], after what: String) throws -> Int {
        guard !arguments.isEmpty else {
            throw CLIUsageError(message: "\(what) needs an entry number")
        }
        guard arguments.count == 1 else {
            throw CLIUsageError(message: "\(what) takes one entry number")
        }
        guard let value = Int(arguments[0]), value >= 1 else {
            throw CLIUsageError(
                message: "an entry number is a whole number from 1, "
                    + "counting back from the newest")
        }
        return value
    }

    var needsDevice: Bool {
        if case .restore = self { return true }
        return false
    }

    var persistsToFlash: Bool { needsDevice }

    func run(options: CLIOptions, session: QxSession?) async throws {
        switch self {
        case .list:
            emitList(json: options.json)
        case .show(let position):
            try emitShow(position, json: options.json)
        case .clear:
            EqHistoryFile.clear()
            StdIO.out(options.json
                ? QxFormat.json(["cleared": true])
                : "history cleared")
        case .restore(let position):
            guard let session else {
                throw CLIUsageError(message: "this command needs the device")
            }
            try await restore(position, options: options, session: session)
        }
    }

    private func emitList(json: Bool) {
        let entries = EqHistoryFile.load().newestFirst
        if json {
            let objects = entries.enumerated().map {
                HistoryCommand.object($0.offset + 1, $0.element)
            }
            StdIO.out(QxFormat.json(["entries": objects]))
            return
        }
        guard !entries.isEmpty else {
            StdIO.out("no EQ edits recorded yet")
            return
        }
        StdIO.out(QxFormat.pad("#", 5) + QxFormat.pad("when", 21)
            + QxFormat.pad("label", 26) + "bands")
        for (offset, entry) in entries.enumerated() {
            StdIO.out(QxFormat.pad("\(offset + 1)", 5)
                + QxFormat.pad(QxFormat.timestamp(entry.recordedAt), 21)
                + QxFormat.pad(entry.label, 26)
                + "\(entry.snapshot.bands.count)")
        }
    }

    private func emitShow(_ position: Int, json: Bool) throws {
        let history = EqHistoryFile.load()
        let entry = try HistoryCommand.require(history, position)
        let group = QxEqGroup(rawValue: entry.snapshot.groupRaw) ?? .user
        if json {
            var object = QxFormat.eqObject(preGain: entry.snapshot.preGain,
                                           bands: entry.snapshot.bands,
                                           enabled: entry.snapshot.enabled,
                                           group: group)
            object["index"] = position
            object["recorded_at"] = QxFormat.isoTimestamp(entry.recordedAt)
            object["label"] = entry.label
            StdIO.out(QxFormat.json(object))
            return
        }
        StdIO.out("\(position)  \(QxFormat.timestamp(entry.recordedAt))  \(entry.label)")
        StdIO.out("")
        for line in QxFormat.eqLines(preGain: entry.snapshot.preGain,
                                     bands: entry.snapshot.bands) {
            StdIO.out(line)
        }
    }

    private func restore(_ position: Int, options: CLIOptions,
                         session: QxSession) async throws {
        let history = EqHistoryFile.load()
        let entry = try HistoryCommand.require(history, position)
        let group = await session.snapshot().eqGroup
        guard entry.snapshot.bands.count == group.bandCount else {
            throw CLIUsageError(
                message: "entry \(position) holds \(entry.snapshot.bands.count) bands, "
                    + "and this device is in " + QxFormat.groupLabel(group) + " mode")
        }
        var file = ParametricEQFile()
        file.preamp = entry.snapshot.preGain
        file.bands = entry.snapshot.bands
        let applied = try await session.applyParametric(
            file, expecting: group, recording: "restore \(position)")
        if !entry.snapshot.enabled { try await session.setEqEnabled(false) }
        if options.json {
            var object = QxFormat.eqObject(preGain: applied.preGain,
                                           bands: applied.bands,
                                           enabled: entry.snapshot.enabled,
                                           group: group)
            object["restored"] = position
            object["recorded_at"] = QxFormat.isoTimestamp(entry.recordedAt)
            object["label"] = entry.label
            StdIO.out(QxFormat.json(object))
            return
        }
        StdIO.out("restored entry \(position) — \(entry.label)")
        for line in QxFormat.eqLines(preGain: applied.preGain, bands: applied.bands) {
            StdIO.out(line)
        }
    }

    private static func require(_ history: EqHistory, _ position: Int) throws -> EqHistoryEntry {
        guard let entry = history.entry(at: position) else {
            let count = history.entries.count
            throw CLIUsageError(message: count == 0
                ? "no EQ edits recorded yet"
                : "there is no entry \(position) — history holds \(count)")
        }
        return entry
    }

    private static func object(_ position: Int, _ entry: EqHistoryEntry) -> [String: Any] {
        [
            "index": position,
            "recorded_at": QxFormat.isoTimestamp(entry.recordedAt),
            "label": entry.label,
            "bands": entry.snapshot.bands.count,
            "eq_group": Int(entry.snapshot.groupRaw),
            "enabled": entry.snapshot.enabled,
        ]
    }
}
