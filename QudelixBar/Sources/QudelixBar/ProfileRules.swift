import Foundation

struct ProfileRule: Codable, Equatable, Identifiable {
    var id: String { outputUID }
    var outputUID: String
    var outputName: String
    var presetIndex: Int
    var eqGroupRaw: UInt8?
    var confirmed: Bool = false
    var automatic: Bool = false

    init(outputUID: String, outputName: String, presetIndex: Int,
         eqGroupRaw: UInt8? = nil, confirmed: Bool = false, automatic: Bool = false) {
        self.outputUID = outputUID
        self.outputName = outputName
        self.presetIndex = presetIndex
        self.eqGroupRaw = eqGroupRaw
        self.confirmed = confirmed
        self.automatic = automatic
    }

    private enum CodingKeys: String, CodingKey {
        case outputUID, outputName, presetIndex, eqGroupRaw, confirmed, automatic
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputUID = try c.decode(String.self, forKey: .outputUID)
        presetIndex = try c.decode(Int.self, forKey: .presetIndex)
        outputName = (try? c.decode(String.self, forKey: .outputName)) ?? ""
        eqGroupRaw = try? c.decode(UInt8.self, forKey: .eqGroupRaw)
        confirmed = (try? c.decode(Bool.self, forKey: .confirmed)) ?? false
        automatic = (try? c.decode(Bool.self, forKey: .automatic)) ?? false
    }

    enum GroupStanding {
        case matches
        case unmarked
        case wrongGroup
    }

    func standing(inGroup group: UInt8?) -> GroupStanding {
        guard let group else { return .matches }
        guard let eqGroupRaw else { return .unmarked }
        return eqGroupRaw == group ? .matches : .wrongGroup
    }
}

private func groupLabel(_ raw: UInt8?) -> String {
    guard let raw, let group = QxEqGroup(rawValue: raw) else { return "unknown" }
    return "\(group.bandCount)-band"
}

enum ProfileRulesFile {
    static var urlOverride: URL?

    static var url: URL {
        urlOverride ?? StageStateFile.directory.appendingPathComponent("profiles.json")
    }

    private static let maxBytes = 200_000
    static let maxRules = 64
    private static let presetSlotCount = 20

    static func load(from fileURL: URL = url) -> [ProfileRule] {
        guard let data = SafeFile.read(fileURL, cap: maxBytes) else { return [] }
        guard let rows = try? JSONDecoder().decode([FailableDecodable<ProfileRule>].self,
                                                   from: data) else {
            park(data, from: fileURL)
            return []
        }
        let decoded = rows.compactMap(\.value)
        let clean = sanitize(decoded)
        if decoded.count != rows.count || clean.count != decoded.count {
            park(data, from: fileURL)
        }
        return clean
    }

    private static func sanitize(_ rules: [ProfileRule]) -> [ProfileRule] {
        var seenUIDs = Set<String>()
        var out: [ProfileRule] = []
        for var rule in rules {
            guard (0..<presetSlotCount).contains(rule.presetIndex) else { continue }
            guard !rule.outputUID.isEmpty, rule.outputUID.utf8.count <= 512 else { continue }
            guard seenUIDs.insert(rule.outputUID).inserted else { continue }
            rule.outputName = QudelixController.displayName(rule.outputName)
            if let raw = rule.eqGroupRaw, QxEqGroup(rawValue: raw) == nil {
                rule.eqGroupRaw = nil
            }
            if !rule.confirmed { rule.automatic = false }
            out.append(rule)
        }
        return Array(out.prefix(maxRules))
    }

    @discardableResult
    static func save(_ rules: [ProfileRule], to fileURL: URL = url) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(rules.prefix(maxRules))) else { return false }
        return SafeFile.writeAtomic(data, to: fileURL)
    }

    private static func park(_ data: Data, from fileURL: URL) {
        ParkedCopy.park(data, beside: fileURL)
    }
}

@MainActor
final class ProfileRules: ObservableObject {
    private let watcher = OutputWatcher()

    @Published private(set) var rules: [ProfileRule] = []
    @Published private(set) var suggestion: Suggestion?
    @Published private(set) var currentOutputUID: String?
    @Published private(set) var currentOutputName: String?
    @Published var editingNow = false
    @Published var currentEqGroupRaw: UInt8? {
        didSet {
            guard currentEqGroupRaw != oldValue else { return }
            eqGroupChanged(from: oldValue)
        }
    }
    private(set) var lastSaveFailed = false

    struct Suggestion: Equatable {
        var outputUID: String
        var outputName: String
        var presetIndex: Int
        var presetLabel: String
    }

    var onApplyPreset: ((Int) -> Bool)?
    var presetLabel: ((Int) -> String)?
    var canApplyNow: (() -> Bool)?

    private struct Evaluation: Equatable {
        var uid: String
        var group: UInt8?
    }

    private var lastOutputUID: String?
    private var evaluated: Evaluation?
    private var deferredAutomaticUID: String?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        rules = ProfileRulesFile.load()
        watcher.onChange = { [weak self] in self?.noteCurrentOutput() }
        watcher.start()
        noteCurrentOutput()
    }

    private func noteCurrentOutput() {
        guard let device = watcher.defaultOutput else {
            lastOutputUID = nil
            currentOutputUID = nil
            currentOutputName = nil
            suggestion = nil
            return
        }
        outputChanged(uid: device.uid, name: device.name)
    }

    func outputChanged(uid: String, name: String) {
        currentOutputUID = uid
        currentOutputName = QudelixController.displayName(name)
        renameKnownRule(uid: uid, to: name)

        guard uid != lastOutputUID else { return }
        lastOutputUID = uid
        evaluate(uid: uid)
    }

    private func evaluate(uid: String) {
        deferredAutomaticUID = nil
        evaluated = Evaluation(uid: uid, group: currentEqGroupRaw)
        guard let rule = rules.first(where: { $0.outputUID == uid }) else {
            suggestion = nil
            return
        }
        let standing = rule.standing(inGroup: currentEqGroupRaw)
        guard standing != .wrongGroup else {
            suggestion = nil
            DebugLog.shared.log(
                "profile for \(rule.outputName) was set in "
                + "\(groupLabel(rule.eqGroupRaw)) mode; the device is in "
                + "\(groupLabel(currentEqGroupRaw)) mode — leaving the EQ alone")
            return
        }
        if rule.automatic, rule.confirmed, standing == .matches,
           canApplyNow?() == true,
           onApplyPreset?(rule.presetIndex) == true {
            suggestion = nil
        } else {
            if rule.automatic, rule.confirmed, standing == .matches {
                deferredAutomaticUID = uid
            }
            suggestion = Suggestion(outputUID: uid, outputName: rule.outputName,
                                    presetIndex: rule.presetIndex,
                                    presetLabel: presetLabel?(rule.presetIndex)
                                        ?? "Preset \(rule.presetIndex + 1)")
        }
    }

    private func eqGroupChanged(from previous: UInt8?) {
        if let offered = suggestion,
           let rule = rules.first(where: { $0.outputUID == offered.outputUID }),
           rule.standing(inGroup: currentEqGroupRaw) == .wrongGroup {
            suggestion = nil
            deferredAutomaticUID = nil
        }
        guard previous == nil, let group = currentEqGroupRaw,
              let uid = currentOutputUID,
              evaluated != Evaluation(uid: uid, group: group) else { return }
        evaluate(uid: uid)
    }

    func retryDeferredAutomatic() {
        guard let uid = deferredAutomaticUID, uid == currentOutputUID,
              suggestion?.outputUID == uid else { return }
        evaluate(uid: uid)
    }

    private func renameKnownRule(uid: String, to name: String) {
        guard let idx = rules.firstIndex(where: { $0.outputUID == uid }) else { return }
        let cleaned = QudelixController.displayName(name)
        guard !cleaned.isEmpty, rules[idx].outputName != cleaned else { return }
        rules[idx].outputName = cleaned
        persist()
    }

    func bind(outputUID: String, outputName: String, presetIndex: Int) {
        guard (0..<QudelixController.presetCount).contains(presetIndex) else { return }
        let name = QudelixController.displayName(outputName)
        if let idx = rules.firstIndex(where: { $0.outputUID == outputUID }) {
            rules[idx].outputName = name
            rules[idx].presetIndex = presetIndex
            rules[idx].eqGroupRaw = currentEqGroupRaw
            rules[idx].confirmed = true
        } else {
            rules.append(ProfileRule(outputUID: outputUID, outputName: name,
                                     presetIndex: presetIndex,
                                     eqGroupRaw: currentEqGroupRaw, confirmed: true))
            if rules.count > ProfileRulesFile.maxRules {
                rules.removeFirst(rules.count - ProfileRulesFile.maxRules)
            }
        }
        if suggestion?.outputUID == outputUID { suggestion = nil }
        persist()
    }

    func removeRule(outputUID: String) {
        rules.removeAll { $0.outputUID == outputUID }
        if suggestion?.outputUID == outputUID { suggestion = nil }
        persist()
    }

    func setAutomatic(_ on: Bool, forUID uid: String) {
        guard let idx = rules.firstIndex(where: { $0.outputUID == uid }),
              rules[idx].confirmed || !on else { return }
        rules[idx].automatic = on
        persist()
    }

    func confirmSuggestion() {
        guard let s = suggestion else { return }
        if let rule = rules.first(where: { $0.outputUID == s.outputUID }),
           rule.standing(inGroup: currentEqGroupRaw) == .wrongGroup {
            suggestion = nil
            deferredAutomaticUID = nil
            return
        }
        guard onApplyPreset?(s.presetIndex) == true else { return }
        if let idx = rules.firstIndex(where: { $0.outputUID == s.outputUID }) {
            rules[idx].confirmed = true
            if let group = currentEqGroupRaw { rules[idx].eqGroupRaw = group }
        }
        suggestion = nil
        deferredAutomaticUID = nil
        persist()
    }

    func dismissSuggestion() {
        suggestion = nil
        deferredAutomaticUID = nil
    }

    private func persist() {
        if ProfileRulesFile.save(rules) {
            lastSaveFailed = false
        } else if !lastSaveFailed {
            lastSaveFailed = true
            DebugLog.shared.log("profile rules could not be written; changes are held "
                                + "in memory")
        }
    }

    #if DEBUG
    func previewSet(rules: [ProfileRule], currentOutputUID: String? = nil,
                    currentOutputName: String? = nil, suggestion: Suggestion? = nil) {
        self.rules = rules
        self.currentOutputUID = currentOutputUID
        self.currentOutputName = currentOutputName
        self.suggestion = suggestion
    }
    #endif
}
