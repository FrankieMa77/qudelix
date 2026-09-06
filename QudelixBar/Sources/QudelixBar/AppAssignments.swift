import Combine
import CoreAudio
import Foundation

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
