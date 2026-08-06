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
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.size] as? Int ?? 0) <= 100_000,
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(EqSnapshot.self, from: data)
        else { return nil }
        // Off-disk values head for the device; clamp like every other input.
        var s = snap
        s.preGain = s.preGain.isFinite ? min(max(s.preGain, -12), 12) : 0
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
