import Foundation

/// The last EQ this app saw on the device for ONE group — bands, pre-gain,
/// mode, and the name of whatever produced it. Kept on disk so a device that
/// comes back from a restart or reset with a different curve can be put back
/// the way the user left it. This is a cache of device state, not a preset
/// library: the 5K's own preset slots remain the place presets live.
///
/// One of these per EQ group; `EqSnapshotStore` owns the collection.
struct EqSnapshot: Codable, Equatable {
    var groupRaw: UInt8
    var bands: [QxEqBandValue]
    var preGain: Double
    var enabled: Bool
    /// Where the curve came from — an import file name, an AutoEq entry,
    /// or nil for hand edits.
    var name: String?

    /// Filter shapes parked by a per-band mute, keyed by band index.
    ///
    /// A mute writes `.bypass` to the device, and that write is durable: it
    /// reaches the device's own state and this snapshot. The shape needed to
    /// undo it used to live only in memory, so any disconnect — including the
    /// re-enumeration a USB rate change causes by design — left the band
    /// silent with no way back and no record of what it had been.
    var mutedBands: [Int: QxFilter] = [:]

    /// Which device this curve was read from.
    ///
    /// Restoring is the one place a saved curve is written *back* to hardware,
    /// so it must not cross devices. Adoption over Bluetooth is trust on first
    /// use — any peripheral in range that advertises the right name and
    /// service can be pinned, answer the handshake as a supported model, and
    /// report a curve, which is then filed here. Without an identity on the
    /// record, attaching the real device afterwards let that curve be written
    /// onto it and committed to its flash under the banner "Restored your last
    /// EQ". nil means a file written before this existed, whose provenance
    /// cannot be established.
    var deviceIdentity: String?

    /// Written by hand rather than synthesised so that a file saved before
    /// `mutedBands` existed still loads. Swift's generated decoder treats a
    /// missing key as an error even when the property has a default, and this
    /// file is read with `try?`, so that error would surface as the user
    /// silently losing their saved EQ.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupRaw = try c.decode(UInt8.self, forKey: .groupRaw)
        bands = try c.decode([QxEqBandValue].self, forKey: .bands)
        preGain = try c.decode(Double.self, forKey: .preGain)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        mutedBands = try c.decodeIfPresent([Int: QxFilter].self, forKey: .mutedBands) ?? [:]
        deviceIdentity = try c.decodeIfPresent(String.self, forKey: .deviceIdentity)
    }

    init(groupRaw: UInt8, bands: [QxEqBandValue], preGain: Double,
         enabled: Bool, name: String? = nil, mutedBands: [Int: QxFilter] = [:],
         deviceIdentity: String? = nil) {
        self.deviceIdentity = deviceIdentity
        self.groupRaw = groupRaw
        self.bands = bands
        self.preGain = preGain
        self.enabled = enabled
        self.name = name
        self.mutedBands = mutedBands
    }

    /// Loose value comparison: the device echoes gains/Qs through its own
    /// fixed-point scaling, so exact equality would flag every readback.
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

/// Every group's last-seen curve, keyed by the device's group id.
///
/// The 5K's EQ groups are independent stores: the 10-band user group and the
/// 20-band b20 group hold different curves, and changing mode selects which
/// one is live without disturbing the other. Keeping a single snapshot could
/// not describe that. A mode switch re-requests the preset, and the read-back
/// wrote the incoming group's curve over the file — so the group the user had
/// just left lost its saved curve, and the restore this file exists for found
/// a snapshot for the wrong group and declined for the rest of the session.
struct EqSnapshotStore: Codable, Equatable {
    /// Keyed by `QxEqGroup.rawValue`. Private so the key and the snapshot's
    /// own `groupRaw` cannot drift apart — `set` is the only way in.
    private(set) var byGroup: [UInt8: EqSnapshot] = [:]

    init() {}
    /// For the loader's clamping pass alone — it re-files exactly the entries
    /// the decoder keyed, so the invariant `set` protects still holds.
    fileprivate init(byGroup: [UInt8: EqSnapshot]) { self.byGroup = byGroup }

    subscript(group: UInt8) -> EqSnapshot? { byGroup[group] }
    var isEmpty: Bool { byGroup.isEmpty }

    mutating func set(_ snapshot: EqSnapshot) { byGroup[snapshot.groupRaw] = snapshot }

    private enum CodingKeys: String, CodingKey { case groups }

    /// Written by hand so that a file saved before snapshots were kept per
    /// group still loads. Such a file IS one snapshot, at the top level, with
    /// no container around it — the shape this type would otherwise reject
    /// outright. That rejection is silent (the load path swallows it) and its
    /// symptom is the user's saved EQ disappearing, so the old shape is
    /// migrated into the new one rather than discarded.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let groups = try c.decodeIfPresent([String: EqSnapshot].self, forKey: .groups) {
            for (key, snapshot) in groups {
                guard let raw = UInt8(key), QxEqGroup(rawValue: raw) != nil else { continue }
                var s = snapshot
                // The key decides which group this curve belongs to; a
                // hand-edited file that disagrees with itself would otherwise
                // offer a curve for one group to a device reading another.
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

    /// Three groups of at most twenty bands. Generous headroom, not an
    /// expected size — anything past it is not a file this app wrote.
    private static let maxBytes = 100_000

    static func load(from fileURL: URL = url) -> EqSnapshotStore {
        guard let data = SafeFile.read(fileURL, cap: maxBytes) else { return EqSnapshotStore() }
        guard let store = try? JSONDecoder().decode(EqSnapshotStore.self, from: data) else {
            // Decode failed — the next read-back would save over the file and
            // take every group's curve with it. Park the undecodable document
            // where the user (or a newer app version) can recover it, the same
            // gesture a corrupt stage.json or profiles.json gets.
            let parked = fileURL.deletingLastPathComponent()
                .appendingPathComponent(fileURL.lastPathComponent + ".recovered")
            SafeFile.writeAtomic(data, to: parked)
            return EqSnapshotStore()
        }
        return EqSnapshotStore(byGroup: store.byGroup.mapValues(sanitized))
    }

    /// Off-disk values head for the device; clamp like every other input.
    private static func sanitized(_ snapshot: EqSnapshot) -> EqSnapshot {
        var s = snapshot
        // The name heads for the UI: the one string in this pipeline that a
        // handcrafted file controls gets the same scrub every device string
        // gets (control/bidi scalars out, length capped).
        s.name = s.name.map(QudelixController.displayName)
        s.preGain = EQHeadroom.clamp(s.preGain)
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
