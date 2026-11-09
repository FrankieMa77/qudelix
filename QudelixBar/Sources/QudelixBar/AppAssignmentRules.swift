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
