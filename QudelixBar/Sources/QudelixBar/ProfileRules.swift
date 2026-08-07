import Foundation

/// One output device paired with an EQ preset slot — the pairing this file
/// exists to remember and act on when the Mac's default output changes.
///
/// Devices are identified by their CoreAudio UID, not by name and not by the
/// `AudioDeviceID` the HAL hands out. The object ID is reassigned on every
/// enumeration and is never the same after a reboot, so it can't identify
/// anything across sessions — it isn't even a candidate. The UID is the
/// durable choice: for most hardware (the 5K itself, most USB DACs, every
/// Bluetooth device) it carries the unit's own serial number and survives
/// unplug/replug and reboot. It is NOT guaranteed unique, though: a fair
/// number of inexpensive USB-C-to-3.5mm adapters and no-name DACs ship with
/// no serial burned in at all, and CoreAudio then reports the identical UID
/// string for every unit of that model — two such adapters bought together
/// are, as far as this app (and macOS itself) can tell, the same device. A
/// name would collide even more often (that's the example the brief for
/// this feature led with), so UID is still what a rule keys on; the
/// collision isn't hidden — `ProfilesView` says in plain words that this
/// matches the output device, not the headphones on the end of it, and
/// `ProfileRules.bind` treats a second binding of an already-known UID as
/// replacing the first rule rather than creating a second one nothing could
/// ever tell apart.
struct ProfileRule: Codable, Equatable, Identifiable {
    var id: String { outputUID }
    var outputUID: String
    /// Last name this UID was seen under. Display only — matching is by UID
    /// alone, so this can go stale (a device renamed itself, a Bluetooth
    /// peripheral changed its advertised name) without breaking the rule.
    var outputName: String
    var presetIndex: Int
    /// Set once the user has acted on this rule while present — either by
    /// confirming a suggested switch, or by using "bind current output",
    /// which is itself a deliberate action taken in front of the app.
    /// Nothing may go silent before this is true; see `automatic`.
    var confirmed: Bool = false
    /// Apply without asking when this output becomes the default. Only ever
    /// set by the user, and only reachable once `confirmed` — see
    /// `ProfileRules.setAutomatic`.
    var automatic: Bool = false

    init(outputUID: String, outputName: String, presetIndex: Int,
         confirmed: Bool = false, automatic: Bool = false) {
        self.outputUID = outputUID
        self.outputName = outputName
        self.presetIndex = presetIndex
        self.confirmed = confirmed
        self.automatic = automatic
    }

    private enum CodingKeys: String, CodingKey {
        case outputUID, outputName, presetIndex, confirmed, automatic
    }

    /// A hand-edited file might drop a field, or get its type wrong. Only
    /// `outputUID` and `presetIndex` are load-bearing enough to refuse the
    /// record over — no UID means nothing to match, no index means nothing
    /// to switch to. Everything else falls back to a safe default instead of
    /// failing the whole array's decode over a missing display name.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputUID = try c.decode(String.self, forKey: .outputUID)
        presetIndex = try c.decode(Int.self, forKey: .presetIndex)
        outputName = (try? c.decode(String.self, forKey: .outputName)) ?? ""
        confirmed = (try? c.decode(Bool.self, forKey: .confirmed)) ?? false
        automatic = (try? c.decode(Bool.self, forKey: .automatic)) ?? false
    }
}

/// Loads and saves the rule list. Same defensive posture as `EqSnapshot`'s
/// and `StageStateFile`'s file handling: a hand-edited or hostile file must
/// never crash the app or hand back a rule that would apply a nonsense
/// preset — at worst it's treated as empty, with the original parked next to
/// it for recovery, the same gesture a corrupt stage.json gets.
enum ProfileRulesFile {
    static var url: URL {
        StageStateFile.directory.appendingPathComponent("profiles.json")
    }

    /// A rule list someone could plausibly hand-maintain is a few hundred
    /// bytes per entry; this is generous headroom, not an expected size.
    private static let maxBytes = 200_000
    /// However many outputs someone actually owns, it isn't more than this —
    /// a bound against a hostile or runaway file growing the list forever.
    static let maxRules = 64
    /// Mirrors `QudelixController.presetCount`. Kept as a private constant
    /// here rather than referenced directly: that property lives on a
    /// `@MainActor` type, and this sanitizer runs off the actor so a corrupt
    /// file can be scrubbed from a plain, synchronous `load()` — including
    /// from tests that never touch the main actor at all. The two numbers
    /// have to move together if the device ever grows more preset slots.
    private static let presetSlotCount = 20

    static func load(from fileURL: URL = url) -> [ProfileRule] {
        guard let data = SafeFile.read(fileURL, cap: maxBytes) else { return [] }
        guard let decoded = try? JSONDecoder().decode([ProfileRule].self, from: data) else {
            park(data, from: fileURL)
            return []
        }
        return sanitize(decoded)
    }

    /// Off-disk values head for a live preset switch, so they get the same
    /// treatment every other on-disk value in this app gets: clamped,
    /// deduplicated, capped — never trusted at face value just because the
    /// JSON parsed.
    private static func sanitize(_ rules: [ProfileRule]) -> [ProfileRule] {
        var seenUIDs = Set<String>()
        var out: [ProfileRule] = []
        for var rule in rules {
            guard (0..<presetSlotCount).contains(rule.presetIndex) else { continue }
            guard !rule.outputUID.isEmpty, rule.outputUID.utf8.count <= 512 else { continue }
            // First entry for a UID wins. A hand-edited file listing the same
            // output twice must resolve to one rule, not two that disagree
            // about which preset it means.
            guard seenUIDs.insert(rule.outputUID).inserted else { continue }
            rule.outputName = QudelixController.displayName(rule.outputName)
            // A crafted document could set automatic without confirmed —
            // the whole point of the flag is that nothing goes silent
            // unseen, so that combination is not one this file reproduces.
            if !rule.confirmed { rule.automatic = false }
            out.append(rule)
        }
        return Array(out.prefix(maxRules))
    }

    static func save(_ rules: [ProfileRule], to fileURL: URL = url) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(rules.prefix(maxRules))) else { return }
        try? data.write(to: fileURL, options: .atomic)
        // Which outputs someone owns and which presets they use with them is
        // personal, like the rest of this app's state files.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
    }

    /// Same recovery gesture as `StageStateFile`: don't let the next save
    /// silently overwrite whatever a person — or a bug — put in this file.
    private static func park(_ data: Data, from fileURL: URL) {
        let parked = fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + ".recovered")
        try? data.write(to: parked, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: parked.path)
    }
}

/// Watches the default output device and offers to switch EQ presets when it
/// changes to one the user has paired with a preset slot.
///
/// This is a suggestion machine, not a remote control: it never touches the
/// device. `onApplyPreset` is the one seam to the outside world, set by
/// whoever owns the `QudelixController` — every path here that could change
/// the running EQ goes through that single closure, so the actual write
/// stays behind the controller's own gating (compatibility, connection
/// state, the EQ-group rate limiter). This file only ever decides whether to
/// ask, and — once a rule has been confirmed and switched to automatic —
/// whether it's safe to skip asking.
@MainActor
final class ProfileRules: ObservableObject {
    private let watcher = OutputWatcher()

    @Published private(set) var rules: [ProfileRule] = []
    /// A rule matched the output that just became default, and either isn't
    /// automatic yet or couldn't be applied safely right now. Shown as a
    /// banner; the user confirms or dismisses it. Cleared as soon as either
    /// happens, or the moment the output changes again.
    @Published private(set) var suggestion: Suggestion?
    /// The current default output, for the "bind current output" action.
    /// nil while no output is known yet, or none is connected.
    @Published private(set) var currentOutputUID: String?
    @Published private(set) var currentOutputName: String?
    /// Whether the popover currently has a band slider mid-drag. This file
    /// has no way to see that on its own — `PopoverView` owns the state —
    /// so it's surfaced here as one bit for `canApplyNow` to read. See the
    /// integration note in `ProfilesView.swift` for where this gets set.
    @Published var editingNow = false

    struct Suggestion: Equatable {
        var outputUID: String
        var outputName: String
        var presetIndex: Int
        var presetLabel: String
    }

    /// The one thing this file is allowed to cause: a request to load a
    /// preset slot. Wire this to `QudelixController.loadPreset` — that
    /// method is the only code that may actually write to the device.
    var onApplyPreset: ((Int) -> Void)?
    /// Display name for a preset slot. Wire to `QudelixController.presetLabel`;
    /// falls back to "Preset N" if never wired, matching that method's own
    /// fallback.
    var presetLabel: ((Int) -> String)?
    /// Whether a switch may happen without asking, checked at the moment one
    /// is due. Expected to cover: connected and compatible, not mid-edit on
    /// a band (a live drag interrupted by a device swap must not also lose
    /// its target under it), and not sitting on a custom curve no preset
    /// slot describes (switching would discard it with no way to say so,
    /// which the hard rule for this feature rules out — so automatic mode
    /// simply declines and falls back to asking instead). Leaving this
    /// unwired is treated as "never safe", not "always safe": an automatic
    /// rule with no safety check wired is a bug, not a green light.
    var canApplyNow: (() -> Bool)?

    private var lastOutputUID: String?
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
            // No default output at all — nothing to bind, and a suggestion
            // aimed at a device that's no longer current would confirm into
            // whatever shows up next instead of what it was asked about.
            lastOutputUID = nil
            currentOutputUID = nil
            currentOutputName = nil
            suggestion = nil
            return
        }
        outputChanged(uid: device.uid, name: device.name)
    }

    /// The matching/suggestion/automatic decision, factored out from the
    /// CoreAudio watcher so it can be driven directly — by tests, and by
    /// `noteCurrentOutput` alike.
    func outputChanged(uid: String, name: String) {
        currentOutputUID = uid
        currentOutputName = QudelixController.displayName(name)
        renameKnownRule(uid: uid, to: name)

        // A redundant report of the same still-current output must not
        // resurrect a banner the user just dismissed, or re-fire an
        // automatic switch that already happened.
        guard uid != lastOutputUID else { return }
        lastOutputUID = uid

        guard let rule = rules.first(where: { $0.outputUID == uid }) else {
            suggestion = nil
            return
        }
        if rule.automatic, rule.confirmed, canApplyNow?() == true {
            onApplyPreset?(rule.presetIndex)
            suggestion = nil
        } else {
            suggestion = Suggestion(outputUID: uid, outputName: rule.outputName,
                                    presetIndex: rule.presetIndex,
                                    presetLabel: presetLabel?(rule.presetIndex)
                                        ?? "Preset \(rule.presetIndex + 1)")
        }
    }

    private func renameKnownRule(uid: String, to name: String) {
        guard let idx = rules.firstIndex(where: { $0.outputUID == uid }) else { return }
        let cleaned = QudelixController.displayName(name)
        guard !cleaned.isEmpty, rules[idx].outputName != cleaned else { return }
        rules[idx].outputName = cleaned
        persist()
    }

    // MARK: - User actions

    /// Pair the given output with a preset slot — "bind current output" in
    /// the UI. A deliberate, present action, so it counts as the one
    /// confirmation `automatic` requires; it does not turn `automatic` on by
    /// itself, since binding while this output is already active produces no
    /// actual switch for the user to have watched happen.
    ///
    /// Binding a UID that already has a rule replaces it rather than adding
    /// a second one — the collision case from the type's doc comment: two
    /// physically different adapters that happen to share a UID would
    /// otherwise silently overwrite each other's rule one switch at a time
    /// anyway, so doing it explicitly here is at least honest about it.
    func bind(outputUID: String, outputName: String, presetIndex: Int) {
        guard (0..<QudelixController.presetCount).contains(presetIndex) else { return }
        let name = QudelixController.displayName(outputName)
        if let idx = rules.firstIndex(where: { $0.outputUID == outputUID }) {
            rules[idx].outputName = name
            rules[idx].presetIndex = presetIndex
            rules[idx].confirmed = true
        } else {
            rules.append(ProfileRule(outputUID: outputUID, outputName: name,
                                     presetIndex: presetIndex, confirmed: true))
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

    /// Turn automatic switching on or off for a rule. Only reachable when
    /// turning it ON if the rule is already `confirmed` — the gate that
    /// keeps a preset from ever changing unannounced the first time an
    /// output is seen. Turning it off is always allowed.
    func setAutomatic(_ on: Bool, forUID uid: String) {
        guard let idx = rules.firstIndex(where: { $0.outputUID == uid }),
              rules[idx].confirmed || !on else { return }
        rules[idx].automatic = on
        persist()
    }

    /// The user tapped "Switch" on the suggestion banner.
    func confirmSuggestion() {
        guard let s = suggestion else { return }
        onApplyPreset?(s.presetIndex)
        if let idx = rules.firstIndex(where: { $0.outputUID == s.outputUID }) {
            rules[idx].confirmed = true
        }
        suggestion = nil
        persist()
    }

    /// The user tapped "Not now". The rule is untouched — it will suggest
    /// again next time this output actually becomes the default again.
    func dismissSuggestion() {
        suggestion = nil
    }

    private func persist() {
        ProfileRulesFile.save(rules)
    }

    #if DEBUG
    /// UI previews and tests that want a populated list without touching
    /// disk or CoreAudio.
    func previewSet(rules: [ProfileRule], currentOutputUID: String? = nil,
                    currentOutputName: String? = nil, suggestion: Suggestion? = nil) {
        self.rules = rules
        self.currentOutputUID = currentOutputUID
        self.currentOutputName = currentOutputName
        self.suggestion = suggestion
    }
    #endif
}
