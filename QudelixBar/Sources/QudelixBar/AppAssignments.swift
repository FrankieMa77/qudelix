import Combine
import CoreAudio
import Foundation

struct AppAssignment: Equatable, Identifiable {
    var bundleID: String
    var displayName: String
    var presetID: UUID?

    var id: String { bundleID }

    init(bundleID: String, displayName: String = "", presetID: UUID? = nil) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.presetID = presetID
    }
}

extension AppAssignment: Codable {
    private enum CodingKeys: String, CodingKey {
        case bundleID, displayName, presetID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = (try? c.decode(String.self, forKey: .bundleID)) ?? ""
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? ""
        presetID = try? c.decode(UUID.self, forKey: .presetID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bundleID, forKey: .bundleID)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(presetID, forKey: .presetID)
    }
}

struct ResolvedAssignment: Equatable, Identifiable {
    var bundleID: String
    var displayName: String
    var preset: LibraryPreset?
    var missingPreset: Bool

    var id: String { bundleID }

    var wantsTap: Bool { preset != nil }
}

struct RunningAudioProcess: Equatable {
    var bundleID: String
    var pid: pid_t
    var object: AudioObjectID
    var playing: Bool

    init(bundleID: String, pid: pid_t, object: AudioObjectID, playing: Bool = false) {
        self.bundleID = bundleID
        self.pid = pid
        self.object = object
        self.playing = playing
    }
}

@MainActor
final class AppAssignments: ObservableObject {
    struct AppRow: Identifiable, Equatable {
        var bundleID: String
        var displayName: String
        var presetID: UUID?
        var preset: LibraryPreset?
        var missingPreset: Bool
        var playing: Bool
        var assigned: Bool

        var id: String { bundleID }
    }

    @Published private(set) var assignments: [AppAssignment] = []
    @Published private(set) var enabled = true
    @Published private(set) var running: [RunningAudioProcess] = []

    var libraryPresets: () -> [LibraryPreset] = { [] }
    var persistAssignments: ([AppAssignment]) -> Void = { _ in }
    var persistEnabled: (Bool) -> Void = { _ in }
    var onChange: () -> Void = {}
    var listProcesses: () -> [RunningAudioProcess] = { AudioOutputs.audioProcesses() }

    private var started = false

    func start(assignments: [AppAssignment], enabled: Bool) {
        guard !started else { return }
        started = true
        self.assignments = Self.sanitized(assignments)
        self.enabled = enabled
        refreshRunning()
    }

    func refreshRunning() {
        let next = listProcesses()
        guard next != running else { return }
        running = next
    }

    var resolved: [ResolvedAssignment] {
        Self.resolve(assignments: assignments, presets: libraryPresets())
    }

    var activeAssignments: [ResolvedAssignment] {
        enabled ? resolved.filter(\.wantsTap) : []
    }

    var activeCount: Int { activeAssignments.count }

    var isFull: Bool { assignments.count >= Self.maxAssignments }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        persistEnabled(on)
        onChange()
    }

    func assign(_ presetID: UUID?, to bundleID: String, named name: String) {
        let key = Self.clampedBundleID(bundleID)
        guard !key.isEmpty else { return }
        let shown = Self.clampedName(name)
        if let index = assignments.firstIndex(where: { $0.bundleID == key }) {
            guard assignments[index].presetID != presetID
                || (!shown.isEmpty && assignments[index].displayName != shown) else { return }
            assignments[index].presetID = presetID
            if !shown.isEmpty { assignments[index].displayName = shown }
        } else {
            guard presetID != nil, assignments.count < Self.maxAssignments else { return }
            assignments.append(AppAssignment(bundleID: key, displayName: shown,
                                             presetID: presetID))
        }
        commit()
    }

    func forget(_ bundleID: String) {
        let key = Self.clampedBundleID(bundleID)
        let before = assignments.count
        assignments.removeAll { $0.bundleID == key }
        guard assignments.count != before else { return }
        commit()
    }

    func rows() -> [AppRow] {
        let presets = libraryPresets()
        let resolvedByID = Dictionary(
            Self.resolve(assignments: assignments, presets: presets).map { ($0.bundleID, $0) },
            uniquingKeysWith: { first, _ in first })
        let playing = Set(running.filter(\.playing).map(\.bundleID))
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var out: [AppRow] = []
        for entry in Self.sanitized(assignments) {
            guard seen.insert(entry.bundleID).inserted else { continue }
            let r = resolvedByID[entry.bundleID]
            out.append(AppRow(bundleID: entry.bundleID,
                              displayName: r?.displayName
                                ?? Self.displayName(for: entry.bundleID,
                                                    fallbackName: entry.displayName),
                              presetID: entry.presetID,
                              preset: r?.preset,
                              missingPreset: r?.missingPreset ?? false,
                              playing: playing.contains(entry.bundleID),
                              assigned: true))
        }
        var offered: [AppRow] = []
        for process in running {
            let key = Self.clampedBundleID(process.bundleID)
            guard !Self.isHiddenFromList(key, own: own),
                  seen.insert(key).inserted else { continue }
            offered.append(AppRow(bundleID: key,
                                  displayName: Self.displayName(for: key, fallbackName: ""),
                                  presetID: nil, preset: nil, missingPreset: false,
                                  playing: playing.contains(key),
                                  assigned: false))
        }
        offered.sort { $0.displayName.localizedStandardCompare($1.displayName)
            == .orderedAscending }
        return Array((out + offered).prefix(Self.maxListedApps))
    }

    private func commit() {
        assignments = Self.sanitized(assignments)
        persistAssignments(assignments)
        onChange()
    }

    #if DEBUG
    var previewExpanded = false

    func previewSet(assignments: [AppAssignment], enabled: Bool = true,
                    running: [RunningAudioProcess] = []) {
        started = true
        self.assignments = Self.sanitized(assignments)
        self.enabled = enabled
        self.running = running
    }
    #endif
}

extension AppAssignments {
    nonisolated static let maxAssignments = 8

    nonisolated static let maxBundleIDLength = 128

    nonisolated static let maxNameLength = 64

    nonisolated static let maxProcessObjectsPerApp = 16

    nonisolated static let maxListedApps = 24

    nonisolated static func clampedBundleID(_ raw: String) -> String {
        String(SafeText.scrubbed(headroom(raw, limit: maxBundleIDLength),
                                 limit: maxBundleIDLength)
            .prefix(maxBundleIDLength))
    }

    nonisolated static func clampedName(_ raw: String) -> String {
        String(SafeText.scrubbed(headroom(raw, limit: maxNameLength),
                                 limit: maxNameLength)
            .prefix(maxNameLength))
    }

    nonisolated static func headroom(_ raw: String, limit: Int) -> String {
        String(String.UnicodeScalarView(raw.unicodeScalars.prefix(limit * 4)))
    }

    nonisolated static func displayName(for bundleID: String, fallbackName: String) -> String {
        let name = clampedName(fallbackName)
        if !name.isEmpty { return name }
        let tail = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return clampedName(tail)
    }

    nonisolated static func sanitized(_ raw: [AppAssignment]) -> [AppAssignment] {
        var seen = Set<String>()
        var out: [AppAssignment] = []
        for entry in raw {
            if out.count == maxAssignments { break }
            let key = clampedBundleID(entry.bundleID)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(AppAssignment(bundleID: key,
                                     displayName: clampedName(entry.displayName),
                                     presetID: entry.presetID))
        }
        return out
    }

    nonisolated static func resolve(assignments: [AppAssignment],
                        presets: [LibraryPreset]) -> [ResolvedAssignment] {
        var byID: [UUID: LibraryPreset] = [:]
        for preset in presets where byID[preset.id] == nil { byID[preset.id] = preset }
        return sanitized(assignments).map { entry in
            guard let wanted = entry.presetID else {
                return ResolvedAssignment(
                    bundleID: entry.bundleID,
                    displayName: displayName(for: entry.bundleID,
                                             fallbackName: entry.displayName),
                    preset: nil, missingPreset: false)
            }
            let found = byID[wanted]
            return ResolvedAssignment(
                bundleID: entry.bundleID,
                displayName: displayName(for: entry.bundleID,
                                         fallbackName: entry.displayName),
                preset: found, missingPreset: found == nil)
        }
    }

    nonisolated static func isHiddenFromList(_ bundleID: String, own: String?) -> Bool {
        if bundleID.isEmpty { return true }
        if let own, bundleID == own { return true }
        if bundleID == "com.qudelixbar.app" { return true }
        if bundleID.hasPrefix("com.apple.audio.") { return true }
        return bundleID == "com.apple.controlcenter"
    }
}
