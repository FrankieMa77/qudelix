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

    var crossLowTrim: Double?
    var crossMidTrim: Double?
    var crossHighTrim: Double?

    var balanceDb: Double?
    var alignMs: Double?

    var distanceValue: Double { distance ?? 0.35 }
    var spanValue: Double { span ?? 0.5 }
    var centerValue: Double { center ?? 0 }
    var sizeValue: Double { size ?? 0.5 }
    var nightValue: Double { night ?? 0 }
    var crossLowTrimValue: Double { crossLowTrim ?? 1 }
    var crossMidTrimValue: Double { crossMidTrim ?? 1 }
    var crossHighTrimValue: Double { crossHighTrim ?? 1 }
    var balanceDbValue: Double { balanceDb ?? 0 }
    var alignMsValue: Double { alignMs ?? 0 }

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
            && crossLowTrimValue == other.crossLowTrimValue
            && crossMidTrimValue == other.crossMidTrimValue
            && crossHighTrimValue == other.crossHighTrimValue
            && balanceDbValue == other.balanceDbValue
            && alignMsValue == other.alignMsValue
    }

    /// True when these settings differ from a fresh default in ANY audible
    /// way — geometry included: Center and Distance act even with the four
    /// main controls neutral, and toggling on must never discard them.
    var doesAnything: Bool {
        var neutral = StageSettings()
        neutral.enabled = enabled
        return !audiblyEquals(neutral)
    }

    var isAudiblyNeutral: Bool {
        width == 100 && crossfeed == 0 && dialogue <= 0.05 && room == 0
            && distanceValue == 0 && centerValue == 0 && nightValue == 0
            && balanceDbValue == 0 && alignMsValue == 0
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
        func trim(_ v: Double?) -> Double? {
            guard let v else { return nil }
            return v.isFinite ? min(max(v, 0), 1) : nil
        }
        s.crossLowTrim = trim(s.crossLowTrim)
        s.crossMidTrim = trim(s.crossMidTrim)
        s.crossHighTrim = trim(s.crossHighTrim)
        if let b = s.balanceDb {
            s.balanceDb = b.isFinite ? min(max(b, -3), 3) : nil
        }
        if let a = s.alignMs {
            s.alignMs = a.isFinite ? min(max(a, -0.5), 0.5) : nil
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
    // Optionals so documents written before these existed still decode.
    /// Stream-quality detection (spectral analysis of the tap).
    var detectQuality: Bool?
    /// Auto-match the USB rate to the detected quality class.
    var autoRate: Bool?
    /// The rate the user last picked by hand — where "lossy" returns to.
    var manualRateHz: Double?
}

/// Reads for user-writable state files. `Data(contentsOf:)` follows a
/// symlink that the size pre-check (attributesOfItem stats the LINK) never
/// saw — a planted link at one of our paths defeats every cap. Same
/// O_NOFOLLOW posture the log files have had all along.
enum SafeFile {
    static func read(_ url: URL, cap: Int) -> Data? {
        // O_NOFOLLOW turns away a symlink, but a symlink is not the only thing
        // that can be sitting at one of these paths. A FIFO is not a link and
        // passes that check, and opening one blocks until somebody opens the
        // other end — which never happens. These files are read from
        // `StageState.init()`, on the main actor, during launch: the app would
        // simply hang with no window and no message. O_NONBLOCK makes the open
        // return whatever is there, and fstat then insists it is the one kind
        // of file this could legitimately be. Regular-file reads are unaffected
        // by the flag, so nothing else changes.
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        var data = Data(count: cap + 1)
        let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard n > 0, n <= cap else { return nil }   // oversized = not ours
        return data.prefix(n)
    }
}

enum StageStateFile {
    /// `~/Library/Application Support/QudelixBar`, which everything this app
    /// persists lives in — and which it therefore has to be sure is really a
    /// directory it created, at a mode matching the 0600 files inside it.
    static var directory: URL {
        let fm = FileManager.default
        let parent = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = parent.appendingPathComponent("QudelixBar", isDirectory: true)
        switch lstatMode(dir) {
        case let mode? where mode & S_IFMT == S_IFDIR:
            // Created without a mode until now, so it came out 0755 under the
            // umask: a world-readable wrapper around files deliberately kept
            // 0600. Bring an inherited one in line — but only when it is out
            // of line, since this runs on the way to every save.
            if mode & 0o777 != 0o700 {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            }
        case .some:
            // The name is taken by something that is not a directory. A symlink
            // is the case that matters: `withIntermediateDirectories: true`
            // follows one without a word, and every state file would then be
            // written — atomically, over whatever is there — wherever it
            // points. Move it aside rather than delete it: its target is not
            // ours to touch, and a link here is more likely to be an
            // arrangement somebody made than an attack.
            let aside = parent.appendingPathComponent(
                "QudelixBar.displaced-\(Int(Date().timeIntervalSince1970))")
            try? fm.moveItem(at: dir, to: aside)
            DebugLog.shared.log("state directory path was not a directory — "
                + "moved aside as \(aside.lastPathComponent)")
            fallthrough
        case nil:
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            // One level only, so the leaf cannot be created *through* a link
            // that reappeared between the check above and here — mkdir never
            // follows its final component — and with the mode spelled out
            // instead of left to the umask.
            try? fm.createDirectory(at: dir, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        }
        return dir
    }

    /// The file mode of the path itself, following nothing. nil when there is
    /// nothing there.
    private static func lstatMode(_ url: URL) -> mode_t? {
        var st = stat()
        return url.withUnsafeFileSystemRepresentation { path -> mode_t? in
            guard let path, lstat(path, &st) == 0 else { return nil }
            return st.st_mode
        }
    }

    static var url: URL { directory.appendingPathComponent("stage.json") }

    /// A genuine state file is a few KB. Anything bigger is not ours;
    /// refusing to read it beats decoding a crafted mountain into memory.
    private static let maxBytes = 1_000_000

    static func load() -> PersistedStageState? {
        guard let data = SafeFile.read(url, cap: maxBytes) else { return nil }
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
