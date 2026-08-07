import Foundation

/// The last EQ this app saw on the device — bands, pre-gain, mode, and the
/// name of whatever produced it. Kept on disk so a device that comes back
/// from a restart or reset with a different curve can be put back the way
/// the user left it. This is a cache of device state, not a preset library:
/// the 5K's own preset slots remain the place presets live.
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
    }

    init(groupRaw: UInt8, bands: [QxEqBandValue], preGain: Double,
         enabled: Bool, name: String? = nil, mutedBands: [Int: QxFilter] = [:]) {
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

enum EqSnapshotFile {
    static var url: URL {
        StageStateFile.directory.appendingPathComponent("last-eq.json")
    }

    static func load() -> EqSnapshot? {
        guard let data = SafeFile.read(url, cap: 100_000),
              let snap = try? JSONDecoder().decode(EqSnapshot.self, from: data)
        else { return nil }
        // Off-disk values head for the device; clamp like every other input.
        var s = snap
        // The name heads for the UI: the one string in this pipeline that a
        // handcrafted file controls gets the same scrub every device string
        // gets (control/bidi scalars out, length capped).
        s.name = s.name.map(QudelixController.displayName)
        s.preGain = EQHeadroom.clamp(s.preGain)
        s.bands = s.bands.map { band in
            var b = band
            b.freq = min(max(b.freq, 20), 20000)
            b.gain = b.gain.isFinite ? min(max(b.gain, -12), 12) : 0
            b.q = b.q.isFinite ? min(max(b.q, 0.1), 10) : 1.0
            return b
        }
        return s
    }

    static func save(_ snapshot: EqSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }
}
