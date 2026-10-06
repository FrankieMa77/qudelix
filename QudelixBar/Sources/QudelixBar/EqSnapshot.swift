import Foundation

struct EqSnapshot: Codable, Equatable {
    var groupRaw: UInt8
    var bands: [QxEqBandValue]
    var preGain: Double
    var enabled: Bool
    var name: String?

    var mutedBands: [Int: QxFilter] = [:]

    var deviceIdentity: String?

    var activePreset: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupRaw = try c.decode(UInt8.self, forKey: .groupRaw)
        bands = try c.decode([QxEqBandValue].self, forKey: .bands)
        preGain = try c.decode(Double.self, forKey: .preGain)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        mutedBands = try c.decodeIfPresent([Int: QxFilter].self, forKey: .mutedBands) ?? [:]
        deviceIdentity = try c.decodeIfPresent(String.self, forKey: .deviceIdentity)
        activePreset = try c.decodeIfPresent(Int.self, forKey: .activePreset)
    }

    init(groupRaw: UInt8, bands: [QxEqBandValue], preGain: Double,
         enabled: Bool, name: String? = nil, mutedBands: [Int: QxFilter] = [:],
         deviceIdentity: String? = nil, activePreset: Int? = nil) {
        self.deviceIdentity = deviceIdentity
        self.activePreset = activePreset
        self.groupRaw = groupRaw
        self.bands = bands
        self.preGain = preGain
        self.enabled = enabled
        self.name = name
        self.mutedBands = mutedBands
    }

    func matches(bands other: [QxEqBandValue], preGain otherGain: Double) -> Bool {
        guard bands.count == other.count else { return false }
        guard abs(preGain - otherGain) < 0.06 else { return false }
        for (a, b) in zip(bands, other) {
            if a.filter != b.filter || a.freq != b.freq { return false }
            if abs(a.gain - b.gain) > 0.06 || abs(a.q - b.q) > 0.02 { return false }
        }
        return true
    }
}

struct EqSnapshotStore: Codable, Equatable {
    private(set) var byGroup: [UInt8: EqSnapshot] = [:]

    init() {}
    fileprivate init(byGroup: [UInt8: EqSnapshot]) { self.byGroup = byGroup }

    subscript(group: UInt8) -> EqSnapshot? { byGroup[group] }
    var isEmpty: Bool { byGroup.isEmpty }

    mutating func set(_ snapshot: EqSnapshot) { byGroup[snapshot.groupRaw] = snapshot }

    private enum CodingKeys: String, CodingKey { case groups }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let groups = try c.decodeIfPresent([String: EqSnapshot].self, forKey: .groups) {
            for (key, snapshot) in groups {
                guard let raw = UInt8(key), QxEqGroup(rawValue: raw) != nil else { continue }
                var s = snapshot
                s.groupRaw = raw
                byGroup[raw] = s
            }
            return
        }
        let single = try EqSnapshot(from: decoder)
        guard QxEqGroup(rawValue: single.groupRaw) != nil else { return }
        byGroup[single.groupRaw] = single
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let keyed = Dictionary(uniqueKeysWithValues:
            byGroup.map { (String($0.key), $0.value) })
        try c.encode(keyed, forKey: .groups)
    }
}

enum EqSnapshotFile {
    static var url: URL {
        StageStateFile.directory.appendingPathComponent("last-eq.json")
    }

    private static let maxBytes = 100_000

    static func load(from fileURL: URL = url) -> EqSnapshotStore {
        guard let data = SafeFile.read(fileURL, cap: maxBytes) else { return EqSnapshotStore() }
        guard let store = try? JSONDecoder().decode(EqSnapshotStore.self, from: data) else {
            let parked = freeParkedURL(for: fileURL)
            SafeFile.writeAtomic(data, to: parked)
            return EqSnapshotStore()
        }
        return EqSnapshotStore(byGroup: store.byGroup.mapValues(sanitized))
    }

    private static func freeParkedURL(for fileURL: URL) -> URL {
        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        func taken(_ candidate: URL) -> Bool {
            fm.fileExists(atPath: candidate.path)
                || (try? fm.destinationOfSymbolicLink(atPath: candidate.path)) != nil
        }
        let base = directory.appendingPathComponent(fileURL.lastPathComponent + ".recovered")
        guard taken(base) else { return base }
        let cap = AIResearchStore.maxParkedCopies
        for n in 2...cap {
            let candidate = directory
                .appendingPathComponent(fileURL.lastPathComponent + ".recovered-\(n)")
            if !taken(candidate) { return candidate }
        }
        return directory.appendingPathComponent(fileURL.lastPathComponent + ".recovered-\(cap)")
    }

    private static func sanitized(_ snapshot: EqSnapshot) -> EqSnapshot {
        var s = snapshot
        s.name = s.name.map { QudelixController.displayName($0) }
        s.preGain = EQHeadroom.clamp(s.preGain)
        s.activePreset = s.activePreset.flatMap { (0..<QxEq.presetCount).contains($0) ? $0 : nil }
        s.bands = s.bands.prefix(QxEq.maxBandCount).map { band in
            var b = band
            b.freq = min(max(b.freq, 20), 20000)
            b.gain = b.gain.isFinite ? min(max(b.gain, -12), 12) : 0
            b.q = b.q.isFinite ? min(max(b.q, 0.1), 10) : 1.0
            return b
        }
        return s
    }

    static func save(_ store: EqSnapshotStore, to fileURL: URL = url) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(store) else { return }
        SafeFile.writeAtomic(data, to: fileURL)
    }
}
