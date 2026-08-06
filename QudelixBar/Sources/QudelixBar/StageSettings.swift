import Foundation

/// The Soundstage controls: stereo-derived spaciousness for headphones.
/// Everything here works on the stereo mix the Mac is playing — it widens,
/// blends and rooms what is already there; it does not unfold surround
/// content.
struct StageSettings: Codable, Equatable {
    var enabled = false
    /// Side-channel level, percent. 100 = untouched, 200 = double.
    var width: Double = 130
    /// 0…1. Delayed, low-passed feed of each channel into the opposite ear.
    var crossfeed: Double = 0.3
    /// 0…6 dB presence lift applied to the mid channel only, so speech cuts
    /// through without sharpening the whole mix.
    var dialogue: Double = 0
    /// 0…1. Early reflections + diffuse tail level.
    var room: Double = 0

    // Stage geometry. Optionals so settings saved before these existed still
    // decode; the *Value accessors carry the defaults.
    /// 0…1. Pre-delays the room field and eases the direct level — pushes
    /// the sources away from the head.
    var distance: Double?
    /// 0…1. The virtual speaker angle: interaural delay and head-shadow
    /// darkness of the crossfeed.
    var span: Double?
    /// −6…+3 dB on the mid. Cramped stages are usually center-heavy.
    var center: Double?
    /// 0…1. Scales the whole room: reflection distances and tail lengths.
    var size: Double?
    /// 0…1. Night mode: converge levels toward a comfort point — quiet
    /// dialogue up, explosions down.
    var night: Double?

    var distanceValue: Double { distance ?? 0.35 }
    var spanValue: Double { span ?? 0.5 }
    var centerValue: Double { center ?? 0 }
    var sizeValue: Double { size ?? 0.5 }
    var nightValue: Double { night ?? 0 }

    static let music = StageSettings(enabled: true, width: 115, crossfeed: 0.35,
                                     dialogue: 0, room: 0.1,
                                     distance: 0.15, span: 0.4, center: 0, size: 0.4)
    static let movie = StageSettings(enabled: true, width: 140, crossfeed: 0.25,
                                     dialogue: 2.5, room: 0.35,
                                     distance: 0.35, span: 0.55, center: 0, size: 0.55)
    static let theater = StageSettings(enabled: true, width: 180, crossfeed: 0.15,
                                       dialogue: 3, room: 0.7,
                                       distance: 0.55, span: 0.75, center: -1.5, size: 0.75)

    /// Value-level comparison: nil geometry equals its default. The
    /// synthesized == compares the optionals themselves, which makes a
    /// pre-geometry saved stage "differ" from a preset it sounds identical to.
    func audiblyEquals(_ other: StageSettings) -> Bool {
        enabled == other.enabled && width == other.width
            && crossfeed == other.crossfeed && dialogue == other.dialogue
            && room == other.room
            && distanceValue == other.distanceValue
            && spanValue == other.spanValue
            && centerValue == other.centerValue
            && sizeValue == other.sizeValue
            && nightValue == other.nightValue
    }

    /// True when these settings differ from a fresh default in ANY audible
    /// way — geometry included: Center and Distance act even with the four
    /// main controls neutral, and toggling on must never discard them.
    var doesAnything: Bool {
        var neutral = StageSettings()
        neutral.enabled = enabled
        return !audiblyEquals(neutral)
    }

    /// The file this comes from is user-writable, so everything headed to
    /// the DSP gets clamped — on load AND on apply.
    func clamped() -> StageSettings {
        var s = self
        s.width = s.width.isFinite ? min(max(s.width, 0), 200) : 100
        s.crossfeed = s.crossfeed.isFinite ? min(max(s.crossfeed, 0), 1) : 0
        s.dialogue = s.dialogue.isFinite ? min(max(s.dialogue, 0), 6) : 0
        s.room = s.room.isFinite ? min(max(s.room, 0), 1) : 0
        func unit(_ v: Double?) -> Double? {
            guard let v else { return nil }
            return v.isFinite ? min(max(v, 0), 1) : nil
        }
        s.distance = unit(s.distance)
        s.span = unit(s.span)
        s.size = unit(s.size)
        s.night = unit(s.night)
        if let c = s.center {
            s.center = c.isFinite ? min(max(c, -6), 3) : nil
        }
        return s
    }
}

/// One day of listening, measured as digital signal level (dBFS) — not
/// calibrated sound pressure, which the app has no way to know.
struct DayExposure: Codable, Equatable {
    var day: String            // "2026-08-06"
    var audibleSeconds: Double // signal above the silence floor
    var loudSeconds: Double    // signal above the loud threshold
    var energySum: Double      // Σ linear power · seconds, for the average
}

/// Everything the Stage and Level features persist. The 5K holds its own EQ
/// state on-device; this file only carries what lives on the Mac side.
struct PersistedStageState: Codable {
    /// Soundstage settings per output device UID — headphones each keep
    /// their own.
    var stageByDevice: [String: StageSettings] = [:]
    var exposure: [DayExposure] = []
    /// Level tracking without the Stage: metering-only tap, no audio path.
    var levelTracking = false
}

enum StageStateFile {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("QudelixBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var url: URL { directory.appendingPathComponent("stage.json") }

    /// A genuine state file is a few KB. Anything bigger is not ours;
    /// refusing to read it beats decoding a crafted mountain into memory.
    private static let maxBytes = 1_000_000

    static func load() -> PersistedStageState? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.size] as? Int ?? 0) <= maxBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        if let state = try? JSONDecoder().decode(PersistedStageState.self, from: data) {
            return state
        }
        // Decode failed — the next save would overwrite the file with
        // defaults and silently destroy the settings in it. Park the
        // undecodable document where the user (or a newer app version) can
        // recover it.
        let parked = directory.appendingPathComponent("stage.json.recovered")
        try? data.write(to: parked, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: parked.path)
        return nil
    }

    static func save(_ state: PersistedStageState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
        // Listening history and device identifiers: user-private, like the
        // packet log (Data.write creates 0644 under the default umask).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }
}
