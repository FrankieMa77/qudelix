import Foundation
import SwiftUI

/// Connection + device state, and all user actions.
///
/// Two transports carry the same protocol, and both are live:
///
/// - USB HID over the vendor-defined interface — full duplex, the device answers
///   every request and pushes notifications unprompted.
/// - Bluetooth LE, carrying the identical `[cmd, data…]` packets (`BLETransport`).
///
/// USB wins whenever it is present; Bluetooth takes over otherwise. Everything
/// above the transport is shared, because both deliver packets in the same
/// `[len, cmdHi, cmdLo, payload…]` shape.
///
/// UI state is optimistic: writes apply locally immediately; device pushes
/// (notifications) overwrite local state when they arrive.
@MainActor
final class QudelixController: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connected(name: String)
    }

    /// Whether this particular device speaks the protocol we implement.
    ///
    /// The handshake tells us the model and firmware, so rather than writing
    /// blind we verify first: writing 10-band legacy EQ commands to a 5K Plus,
    /// to firmware 2.x, or to a device in 20-band mode silently does the wrong
    /// thing, which is worse than refusing.
    enum Compatibility: Equatable {
        case checking
        case ok
        case unsupported(title: String, detail: String)

        var canWrite: Bool { self == .ok }
    }

    @Published var compatibility: Compatibility = .checking

    @Published var connection: ConnectionState = .disconnected
    @Published var usbWired = false           // the USB control interface is attached
    @Published var firmwareVersion: String?
    @Published var batteryPercent: Int?
    @Published var charging = false
    /// A charger is physically attached. Separate from `charging`: the 5K
    /// spends most of a permanently-plugged life connected but not charging,
    /// and the two together are what say why.
    @Published var chargerConnected = false
    /// The device's own low-battery flag, as opposed to this app's opinion of
    /// the percentage. False until a power block has been read.
    @Published var batteryLow = false
    /// Raw `charger_state` / `dac_state` from the power block. Published
    /// without labels because the values have no established names — they are
    /// here so a report can quote them, not so the UI can pretend to read them.
    @Published var chargerState: Int?
    @Published var dacState: Int?
    /// Whether the 5K is allowed to charge, and whether it holds the charge
    /// short of full. Both are settings stored on the device, both are read
    /// only here — see `QxCmd.setCharger` / `QxCmd.setBatteryCare`. Nil until
    /// the sys config block has been read.
    @Published var chargerEnabled: Bool?
    @Published var batteryCare: Bool?
    @Published var sampleRate: String?
    @Published var inputSource: String?
    @Published var activeCall: Bool?
    @Published var receivingReports = false   // true once the active link answers

    // Volume (dB). 60 dB window; max is 0 dB (or +6 in 2 Vrms mode).
    @Published var volumeDb: Double = -30
    @Published var volumeMax: Double = 0
    @Published var muted = false
    var volumeRange: ClosedRange<Double> { (volumeMax - 60)...volumeMax }

    /// Per-channel output trim, applied by the device on top of the master
    /// level. Attenuation only (−24…0 dB); equal values on both channels is
    /// the same as no trim at all, so the pair is really a balance control.
    @Published var trimLeftDb: Double = 0
    @Published var trimRightDb: Double = 0

    /// The device's own volume ceiling. This is enforced in the hardware, not
    /// in this app: it is what `volumeMax` is derived from, together with the
    /// DAC's output-power mode. Defaults to 0 dB — the 1 Vrms cap — until the
    /// device reports its real setting, which the handshake asks for.
    @Published var volumeLimitDb: Double = 0

    /// DAC reconstruction filter the device is running (index into
    /// `QxStatusParser.dacFilters`). Set with `setDacFilter`; see
    /// `dacFilterLabel` for the display name.
    @Published var dacFilterType: Int?

    /// Crossfeed level stored in the preset the device is currently running,
    /// in its own 0…63 steps, or nil if no preset has been read. Read only.
    @Published var crossfeedLevel: Int?

    /// Active Bluetooth codec, when one is in use. Nil over USB.
    @Published var codecLabel: String?
    /// True while the amp is in its high-gain / higher-output state.
    @Published var outputHighGain: Bool?

    /// One line for what the power path is doing, or nil before any power
    /// block has been read.
    ///
    /// It states only what the device reported: whether a charger is
    /// attached, whether it is charging, and — because that one turns an
    /// absence of charging from a guess into a certainty — whether charging
    /// is switched off altogether. Battery care is deliberately not folded in
    /// here: it is shown as its own fact, because "not charging" has other
    /// causes (a full battery, a warm one) and this line must not claim to
    /// know which.
    var chargeSummary: String? {
        guard chargerState != nil else { return nil }
        if !chargerConnected { return "On battery" }
        if charging { return "Plugged in, charging" }
        if chargerEnabled == false { return "Plugged in — charging is switched off" }
        return "Plugged in, not charging"
    }

    /// The parametric-file token for a filter shape, or nil for one that has
    /// no representation in the format.
    nonisolated static func exportToken(for filter: QxFilter) -> String? {
        switch filter {
        case .peak: return "PK"
        case .lowShelf: return "LSC"
        case .highShelf: return "HSC"
        case .lpf: return "LPQ"
        case .hpf: return "HPQ"
        case .bypass: return nil
        }
    }

    /// The filter's display name, or nil when the device hasn't reported one
    /// (or reported an index this build has no name for).
    var dacFilterLabel: String? {
        guard let i = dacFilterType,
              QxStatusParser.dacFilters.indices.contains(i) else { return nil }
        return QxStatusParser.dacFilters[i]
    }

    // EQ
    /// Which rates the 5K's USB descriptor offers the host (dd.usb_fs_mode):
    /// 0…3 pin one rate (44.1/48/88.2/96 kHz), 4 offers all. nil until the
    /// device reports it.
    @Published var usbFsMode: Int?

    @Published var eqEnabled = true
    @Published var preGain: Double = 0
    @Published var bands: [QxEqBandValue] = QxEq.defaultFreqs.map {
        QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1.0)
    }
    @Published var presetNames: [Int: String] = [:]
    @Published var activePreset: Int?
    @Published var lastImportSummary: String?

    /// Bands muted from the band table, and the filter shape each one had
    /// when it was muted so unmuting can put it back.
    ///
    /// The mute itself is a real write, not a display trick: the band's
    /// filter type goes to bypass — the one type that contributes nothing to
    /// the response — while its gain, frequency and Q ride along in the same
    /// packet, unchanged. So the values being A/B-ed never leave the
    /// hardware, and nothing here has to hold them: a preset load, another
    /// app's write or a device restart can't lose a number this app is
    /// keeping in memory, because it isn't keeping any.
    ///
    /// What's here is only which shape to come back to, which is why an entry
    /// is dropped the moment anything writes a real filter to that band, why
    /// a read-back that disagrees wins (`applyPreset`), and why the whole map
    /// is cleared when the bands underneath it are replaced wholesale — a
    /// group switch, a preset load, an import, a new connection. An entry
    /// that outlived its band would offer to unmute something else.
    @Published private(set) var mutedBands: [Int: QxFilter] = [:]

    /// The correction as the file asked for it, before the device's limits were
    /// applied to it. Kept so the curve view can show what was requested next to
    /// what the 5K could actually hold — the import summary says how many bands
    /// were clamped, which does not tell anyone *where* the shape changed.
    ///
    /// Deliberately not persisted: there is no way to dismiss the overlay, and a
    /// ghost curve that outlived the session would become furniture rather than
    /// an answer to a question the user just asked.
    @Published private(set) var requestedCorrection: ParametricEQFile?

    var previewPane: PopoverView.Pane?
    private(set) var paneRequest: PopoverView.Pane?
    @Published private(set) var paneRequests = 0
    func requestPane(_ pane: PopoverView.Pane) {
        paneRequest = pane
        paneRequests &+= 1
    }
    /// Set only by UIPreview: seeds the AutoEq list so it renders offline.
    var previewAutoEq: (entries: [AutoEqEntry], query: String)?
    static let presetCount = QxEq.presetCount

    /// EQ group the device is currently using — driven by `dd.eq_mode`.
    /// 10-band user EQ by default; 20-band (b20) when the device is in that mode.
    @Published private(set) var eqGroup: QxEqGroup = .user
    var bandCount: Int { eqGroup.bandCount }

    @Published private(set) var byEarSessionActive = false

    func setByEarSessionActive(_ active: Bool) { byEarSessionActive = active }

    private let hid = HIDTransport()
    private let ble = BLETransport()

    /// Which link is carrying the protocol right now. USB wins when both are
    /// available: it is faster, needs no pairing, and is the better-tested path.
    enum Link: String { case none, usb, bluetooth }
    @Published private(set) var link: Link = .none

    /// Single choke point for writes, so no caller has to know which link is up.
    private func transportSend(_ cmd: QxCmd, _ data: [UInt8] = []) {
        switch link {
        case .usb: hid.send(cmd, data)
        case .bluetooth: ble.send(cmd, data)
        case .none: DebugLog.shared.log("send dropped (no link): \(cmd)")
        }
    }

    private func transportSendCoalesced(_ cmd: QxCmd, _ data: [UInt8], key: String) {
        switch link {
        case .usb: hid.sendCoalesced(cmd, data, key: key)
        case .bluetooth: ble.sendCoalesced(cmd, data, key: key)
        case .none: DebugLog.shared.log("coalesced send dropped (no link): \(cmd)")
        }
    }

    /// Outlives connections deliberately: its once-per-episode latches must
    /// survive a Bluetooth blip, or every reconnect re-announces the same
    /// low battery.
    private let batteryAlerts = BatteryAlerts()

    // MARK: - EQ persistence

    /// The last EQ this app saw or applied, kept on disk. Two jobs: EQ
    /// writes land in the device's RAM and are lost on a hard restart (a
    /// USB-mode change, a battery death) unless persisted, and the flash
    /// save below can still be missed. On connect, a device reporting a
    /// different curve than last seen gets the last one back.
    ///
    /// One entry per EQ group: the groups hold independent curves, and the
    /// user switching mode must not cost them the group they switched away
    /// from.
    private var eqSnapshots = EqSnapshotFile.load()

    private var eqSnapshot: EqSnapshot? { eqSnapshots[eqGroup.rawValue] }

    /// Which device is on the other end, as far as anything can tell.
    ///
    /// Over Bluetooth the pinned peripheral's identifier; over USB the name
    /// the device reports. Neither is authenticated — a peripheral chooses its
    /// own name — but tagging a saved curve with one is enough to stop it
    /// being written back onto a *different* device, which is the failure that
    /// matters: adoption over Bluetooth is trust on first use, so anything in
    /// range can be pinned, pass the handshake as a supported model, report a
    /// curve, and have it filed as "your last EQ".
    private var deviceIdentity: String? {
        switch link {
        case .bluetooth: return ble.pinnedIdentity.map { "ble:" + $0 }
        case .usb:
            if case .connected(let name) = connection { return "usb:" + name }
            return nil
        default: return nil
        }
    }

    // MARK: - Undo

    /// One reversible EQ state. Only what this app can put back: the curve, the
    /// pre-gain and which bands are muted. Not the preset slot — undoing a
    /// slot load restores the curve, which is what the user is looking at.
    /// Not `Equatable`: the dedup below compares the fields that decide
    /// whether anything changed, and a parsed correction file has no
    /// meaningful equality of its own.
    struct EqEdit {
        var bands: [QxEqBandValue]
        var preGain: Double
        var mutedBands: [Int: QxFilter]
        var activePreset: Int?
        /// What the curve was understood to be at the time. Restored with it:
        /// undoing an import that left a requested-curve overlay behind would
        /// otherwise keep drawing "the device could not hold this" over a curve
        /// the device was never asked to hold, and leave a slot able to be
        /// named after a correction that is no longer loaded.
        var sourceName: String?
        var requested: ParametricEQFile?
        var sourceCurve: [QxEqBandValue]?
        var sourcePreGain: Double?
        /// What this step would undo, shown on the button.
        var label: String
    }

    @Published private(set) var undoStack: [EqEdit] = []
    @Published private(set) var redoStack: [EqEdit] = []
    /// Deep enough for a session of shaping, shallow enough that the memory is
    /// bounded no matter how long the app stays open.
    private static let undoDepth = 40
    /// Set while an undo, a redo or a device-state repair is writing. Those
    /// replay history rather than making it, and recording them would make the
    /// stack grow as the user tried to walk back through it.
    private var suppressUndo = false
    private var lastEditLabel = ""
    private var lastEditAt = Date.distantPast

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoLabel: String? { undoStack.last?.label }
    var redoLabel: String? { redoStack.last?.label }

    private var currentEqEdit: EqEdit {
        EqEdit(bands: bands, preGain: preGain, mutedBands: mutedBands,
               activePreset: activePreset,
               sourceName: eqSourceName, requested: requestedCorrection,
               sourceCurve: sourceCurve, sourcePreGain: sourcePreGain, label: "")
    }

    /// Record the state *before* a change, coalescing a continuous gesture into
    /// one step.
    ///
    /// A drag on the curve and a drag on a slider both emit a change per frame.
    /// Undo has to step over the whole gesture, not one frame of it, so a fresh
    /// entry is only pushed when the kind of edit changes or after a pause —
    /// which is also how a user perceives "one edit".
    private func checkpoint(_ label: String, discrete: Bool = false) {
        guard !suppressUndo else { return }
        let now = Date()
        let continuing = !discrete && label == lastEditLabel
            && now.timeIntervalSince(lastEditAt) < 0.7
        lastEditLabel = label
        lastEditAt = now
        guard !continuing else { return }

        var entry = currentEqEdit
        entry.label = label
        // Nothing to undo back to if the state is already what the top of the
        // stack holds — a click that changes nothing should not cost a step.
        if let top = undoStack.last,
           top.bands == entry.bands, top.preGain == entry.preGain,
           top.mutedBands == entry.mutedBands { return }
        undoStack.append(entry)
        if undoStack.count > Self.undoDepth { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Open one undo step covering everything a caller is about to write.
    func beginUndoStep(_ label: String) { checkpoint(label, discrete: true) }

    func undoEqEdit() { step(from: &undoStack, to: &redoStack) }
    func redoEqEdit() { step(from: &redoStack, to: &undoStack) }

    private func step(from source: inout [EqEdit], to destination: inout [EqEdit]) {
        guard canWriteEq, var entry = source.popLast() else { return }
        var here = currentEqEdit
        here.label = entry.label
        destination.append(here)
        if destination.count > Self.undoDepth { destination.removeFirst() }

        suppressUndo = true
        defer { suppressUndo = false; lastEditLabel = ""; lastEditAt = .distantPast }
        activePreset = entry.activePreset
        eqSourceName = entry.sourceName
        requestedCorrection = entry.requested
        sourceCurve = entry.sourceCurve
        sourcePreGain = entry.sourcePreGain
        // Mutes first: restoring a band's shape and then muting it again would
        // write the band twice and leave the mute map disagreeing with it.
        mutedBands = entry.mutedBands
        setPreGain(entry.preGain, persistToFlash: false)
        for (i, band) in entry.bands.enumerated() where i < bandCount {
            guard bands.indices.contains(i), bands[i] != band else { continue }
            updateBand(i, band, persistToFlash: false)
        }
        mutedBands = entry.mutedBands
        entry.label = ""
    }

    /// Reclaim the parked mute shapes from the snapshot for bands the device
    /// still reports as bypassed.
    ///
    /// Writes nothing: a mute already reached the device, and this only puts
    /// back the app's ability to undo it. Bands the device reports as live
    /// are dropped, so a shape parked before someone else rewrote the curve
    /// cannot resurrect itself over their edit.
    private func reclaimMutedBands() {
        guard mutedBands.isEmpty, let snap = eqSnapshot, !snap.mutedBands.isEmpty
        else { return }
        let usable = snap.mutedBands.filter { index, shape in
            shape != .bypass && bands.indices.contains(index)
                && bands[index].filter == .bypass
        }
        guard !usable.isEmpty else { return }
        mutedBands = usable
        DebugLog.shared.log("reclaimed \(usable.count) muted band(s) from the last session")
    }
    private var snapshotWork: DispatchWorkItem?
    private var saveAllWork: DispatchWorkItem?
    /// One restore decision per group per connection, taken at that group's
    /// first preset read-back — later read-backs are the result of user
    /// actions. Per group rather than per connection because the handshake
    /// reads the provisional group before `eq_mode` names the real one: with
    /// a single latch, deciding for the group we happened to start on left
    /// the group the device is actually in unrepaired for the whole session.
    private var restoreDecidedGroups: Set<UInt8> = []
    /// Whether the two pre-gain channels have already been evened up on this
    /// connection. One attempt per link; see `applyPreset`.
    private var preGainRepaired = false
    /// Whether this connection has read the device's EQ at least once.
    private var presetRead = false
    /// Whether this connection has seen the device report its eq_mode.
    private var sawEqMode = false
    /// The name attached to the current curve (import file, AutoEq entry).
    private var eqSourceName: String?
    /// The curve exactly as the source produced it.
    ///
    /// Naming a slot after a correction is only honest while the curve still
    /// is that correction. A Tune session or a dragged node can move it a long
    /// way, and `eqSourceName` does not notice — it survives every hand edit
    /// by design, because the requested-curve overlay wants it. Comparing
    /// against what was applied is exact and needs no flag threaded through
    /// the edit paths, so undoing back to the imported curve makes the name
    /// honest again on its own.
    private var sourceCurve: [QxEqBandValue]?
    private var sourcePreGain: Double?

    /// Whether the curve is still what `eqSourceName` describes.
    var curveMatchesSource: Bool {
        guard let curve = sourceCurve, let gain = sourcePreGain,
              curve.count == bands.count, abs(gain - preGain) < 0.06 else { return false }
        // Same tolerance the snapshot comparison uses: values come back
        // through the device's fixed-point scaling, so exact equality would
        // report a difference after every read-back.
        for (a, b) in zip(curve, bands) {
            if a.filter != b.filter || a.freq != b.freq { return false }
            if abs(a.gain - b.gain) > 0.06 || abs(a.q - b.q) > 0.02 { return false }
        }
        return true
    }
    private var packetLogWindow = Date.distantPast
    private var packetsLoggedThisSecond = 0
    private var suppressedPackets = 0
    private var lastImplausibleDump = Date.distantPast
    private var lastStateLogLine = ""

    /// Call after any EQ mutation reaches the device. Debounced twice:
    /// a quick app-side snapshot, and a slower ask for the device to
    /// persist its settings to flash (the official app only does that
    /// before firmware updates, so a restart otherwise reverts the EQ).
    ///
    /// `persistToFlash: false` keeps the app-side snapshot but skips the
    /// device's own save. A per-band mute is a moment's A/B, not a curve the
    /// user chose, and writing one into flash both wears the part and makes a
    /// temporary comparison outlive the power cycle that should have ended it.
    private func eqEdited(persistToFlash: Bool = true) {
        snapshotWork?.cancel()
        let snap = DispatchWorkItem { [weak self] in self?.snapshotNow() }
        snapshotWork = snap
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: snap)

        guard persistToFlash else { return }
        saveAllWork?.cancel()
        let persist = DispatchWorkItem { [weak self] in
            guard let self, self.canWrite else { return }
            DebugLog.shared.log("asking the device to persist settings")
            self.transportSend(.saveAll)
        }
        saveAllWork = persist
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: persist)
    }

    /// A read-back changed the curve (device truth) — snapshot it, but a
    /// read is not an edit: no flash save.
    private func eqObserved() {
        snapshotWork?.cancel()
        let snap = DispatchWorkItem { [weak self] in self?.snapshotNow() }
        snapshotWork = snap
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: snap)
    }

    /// For the quit path: the debounced snapshot must not die with the
    /// process — a stale snapshot doesn't just lose the last edit, the next
    /// connect RESTORES over it.
    func flushEqSnapshot() {
        snapshotWork?.cancel()
        snapshotNow()
    }

    private func snapshotNow() {
        // Only ever snapshot a curve that came from a device.
        //
        // Without this, the published properties are a flat 10-band user-group
        // curve until a device is read — and `resetDeviceState` puts them back
        // to exactly that on every disconnect. Quitting with the 5K unplugged,
        // or losing the link within a second of an edit, would therefore save
        // "flat" as the last EQ. The next connect in 10-band mode passes every
        // one of `restoreIfNeeded`'s guards and writes that flat curve over the
        // user's real one, then commits it to flash five seconds later. The
        // safety net would be the thing that destroys the curve.
        guard presetRead, case .connected = connection else { return }
        let snap = EqSnapshot(groupRaw: eqGroup.rawValue, bands: bands,
                              preGain: preGain, enabled: eqEnabled,
                              name: eqSourceName, mutedBands: mutedBands,
                              deviceIdentity: deviceIdentity)
        guard snap != eqSnapshot else { return }
        // Only this group's entry is replaced; the other group's stays as it
        // was last seen, which is what makes a mode switch survivable.
        eqSnapshots.set(snap)
        EqSnapshotFile.save(eqSnapshots)
    }

    /// First preset read-back of a connection: if the device came back with
    /// a different curve than this app last saw — a hard restart reverted
    /// its RAM state, or a reset wiped it — put the last one back.
    private func restoreIfNeeded() {
        // Everything here must hold before this group's one decision is
        // taken: the read-back can beat the compatibility verdict, and a
        // pending group switch gates the very writes a restore would send
        // (they'd be dropped silently) as well as meaning the group being
        // judged is about to change.
        guard !restoreDecidedGroups.contains(eqGroup.rawValue), presetRead,
              compatibility.canWrite,
              pendingGroup == nil, pendingEqMode == nil else { return }
        if eqSnapshot == nil, !eqSnapshots.isEmpty, !sawEqMode {
            // Nothing stored for the group we are provisionally addressing,
            // but something is stored for another one — and the device's real
            // mode isn't known yet. Stay undecided rather than conclude
            // "nothing to restore" against a group it may not be in.
            return
        }
        restoreDecidedGroups.insert(eqGroup.rawValue)
        // Never write a curve back onto a device it did not come from. A file
        // written before identities were recorded has no provenance to check,
        // and is therefore not restored either — it will be re-tagged the next
        // time this device's own curve is saved.
        if let snap = eqSnapshots[eqGroup.rawValue],
           snap.deviceIdentity == nil || snap.deviceIdentity != deviceIdentity {
            DebugLog.shared.log("not restoring: that curve was saved from a different device")
            return
        }
        guard let snap = eqSnapshot,
              snap.bands.count == bandCount,
              !snap.matches(bands: bands, preGain: preGain) else { return }
        DebugLog.shared.log("device EQ differs from last seen — restoring")
        suppressUndo = true
        defer { suppressUndo = false }
        // The same preamble apply() sends: band params are only meaningful
        // against the parametric EQ type.
        transportSend(.setEqType, [eqGroup.rawValue, 1])
        setPreGain(snap.preGain)
        for (i, band) in snap.bands.enumerated() { updateBand(i, band) }
        if eqEnabled != snap.enabled { setEqEnabled(snap.enabled) }
        lastImportSummary = "Restored your last EQ"
            + (snap.name.map { ": \($0)" } ?? "")
    }

    private var assembler = QxPresetAssembler()
    private var state = QxDeviceState()
    private var requestedNames = false
    private var handshakeAttempt = 0
    /// Bumped on every connect so retry Tasks from a previous episode retire
    /// instead of reviving against the freshly-zeroed attempt counter.
    private var handshakeGeneration = 0

    func start() {
        hid.onDeviceConnected = { [weak self] name in
            Task { @MainActor in
                guard let self else { return }
                self.usbWired = true
                self.link = .usb                     // USB takes over from BLE
                // Anything queued for the old link would otherwise be delivered
                // over it up to a coalescing window later.
                self.ble.clearPending()
                self.deviceConnected(name)
            }
        }
        hid.onDeviceRemoved = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.usbWired = false
                guard self.link == .usb else { return }
                self.link = .none
                self.connection = .disconnected
                self.resetDeviceState()
                // The 5K may still be reachable over Bluetooth; if it is, its
                // link will announce itself and we pick the handshake up there.
                if self.ble.isConnected { self.adoptBluetooth() }
            }
        }
        // Only the link that is actually carrying the protocol may feed the
        // parsers. Both transports stay connected and subscribed regardless of
        // which one is active, so without this a peripheral in radio range could
        // inject device state while the user is on USB — forging a handshake to
        // flip `compatibility`, or an eq_mode change that makes us re-request
        // presets *over USB*. The write path is gated on `link`; the read path
        // has to be too.
        hid.onLinkUnusable = { [weak self] in
            Task { @MainActor in
                guard let self, self.link == .usb else { return }
                DebugLog.shared.log("USB stopped accepting reports — releasing the link")
                self.link = .none
                self.connection = .disconnected
                self.resetDeviceState()
                // A healthy Bluetooth link may be sitting right there.
                if self.ble.isConnected { self.adoptBluetooth() }
            }
        }
        hid.onInputReport = { [weak self] _, bytes in
            Task { @MainActor in
                guard let self, self.link == .usb else { return }
                self.handlePacket(bytes)
            }
        }

        ble.onConnected = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // The pin happens the moment characteristics are adopted, USB
                // or not, so the state that shows the Forget button has to be
                // refreshed before the early return below — otherwise a pin
                // made while USB owned the link stayed invisible all session.
                self.refreshBluetoothPinState()
                guard self.link != .usb else { return }
                self.adoptBluetooth()
            }
        }
        ble.onDisconnected = { [weak self] in
            Task { @MainActor in
                guard let self, self.link == .bluetooth else { return }
                self.link = .none
                self.connection = .disconnected
                self.resetDeviceState()
            }
        }
        ble.onPacket = { [weak self] bytes in
            Task { @MainActor in
                guard let self, self.link == .bluetooth else { return }
                self.handlePacket(bytes)
            }
        }

        hid.start()
        ble.start()
        hasPinnedBluetoothDevice = ble.hasPinnedDevice
    }

    /// Clear everything that describes the device we were talking to. Used on
    /// every teardown and before each handshake: after a link handover the
    /// popover would otherwise show the previous session's firmware, sample rate
    /// and preset names against a different device.
    private func resetDeviceState() {
        // A snapshot queued by an edit a moment ago must not fire against the
        // values this method is about to reset — that is the same flat-curve
        // trap, reached through a link drop instead of a quit.
        snapshotWork?.cancel()
        saveAllWork?.cancel()
        undoStack.removeAll()
        redoStack.removeAll()
        preGainRepaired = false
        compatibility = .checking
        receivingReports = false
        firmwareVersion = nil
        batteryPercent = nil
        charging = false
        chargerConnected = false
        batteryLow = false
        chargerState = nil
        dacState = nil
        chargerEnabled = nil
        batteryCare = nil
        sampleRate = nil
        inputSource = nil
        activeCall = nil
        muted = false
        activePreset = nil
        presetNames = [:]
        usbFsMode = nil
        lastImportSummary = nil
        requestedNames = false
        pendingGroup = nil
        pendingEqMode = nil
        restoreDecidedGroups = []
        presetRead = false
        sawEqMode = false
        eqSourceName = nil
        sourceCurve = nil
        sourcePreGain = nil
        lastImportSummary = nil
        requestedCorrection = nil
        batteryAlerts.connectionReset()
        state = QxDeviceState()

        // The EQ belongs to the device too. `eqGroup` in particular reaches the
        // wire — it is the group byte on every EQ write and the mask on the
        // preset request the handshake sends — so carrying it across a handover
        // would address the *previous* device's group until the new eq_mode
        // arrives a round trip later. Back to the 10-band default, which is what
        // an unidentified device is assumed to be.
        volumeDb = -30
        volumeMax = 0
        trimLeftDb = 0
        trimRightDb = 0
        volumeLimitDb = 0
        volumeFieldEditUntil = .distantPast
        eqEnableEditUntil = .distantPast
        dacFilterType = nil
        dacFilterEditUntil = .distantPast
        crossfeedLevel = nil
        eqGroup = .user
        assembler.group = .user
        assembler.reset()
        lastGroupSwitch = .distantPast   // don't let the rate limit defer the first real switch
        bands = QxEq.defaultFreqs.map { QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1.0) }
        preGain = 0
        eqEnabled = true
        // A mute is a state of the curve on the device; the shapes to come
        // back to describe the curve we were just looking at. Neither
        // survives a handover to a device this link hasn't identified.
        mutedBands = [:]
    }

    /// Whether a Bluetooth device is remembered, so the UI can offer to forget it.
    /// Published rather than computed: read straight from UserDefaults it never
    /// told SwiftUI to redraw, so the button stayed on screen after being used.
    @Published private(set) var hasPinnedBluetoothDevice = false

    /// Forget the remembered Bluetooth device and start looking again. Drops the
    /// current link if it is the Bluetooth one, so the next device can be adopted.
    /// Kept in step with the transport rather than only at the moments the
    /// controller happens to adopt a link. A peripheral is pinned as soon as
    /// its characteristics are adopted, which can happen in the background
    /// while USB owns the link — and the button that undoes a wrong pin was
    /// then hidden for the rest of the session.
    func refreshBluetoothPinState() {
        let pinned = ble.hasPinnedDevice
        if hasPinnedBluetoothDevice != pinned { hasPinnedBluetoothDevice = pinned }
    }

    func forgetBluetoothDevice() {
        ble.forgetPinnedDevice()
        hasPinnedBluetoothDevice = ble.hasPinnedDevice
        if link == .bluetooth {
            link = .none
            connection = .disconnected
            resetDeviceState()
        }
        ble.disconnectAndRescan()
    }

    private func adoptBluetooth() {
        link = .bluetooth
        hasPinnedBluetoothDevice = ble.hasPinnedDevice
        DebugLog.shared.log("link → bluetooth (vendor \(ble.vendor.label))")
        // The popover shows the link with its own icon, so the name stays clean.
        deviceConnected("Qudelix 5K")
    }

    private func deviceConnected(_ name: String) {
        connection = .connected(name: name)
        handshakeAttempt = 0
        handshakeGeneration += 1
        // Everything describing the device belongs to the link we are now on, so
        // none of it may carry over. Keeping `compatibility` would authorise
        // writes to a device this link has never identified, and keeping
        // `receivingReports` would defeat the handshake retry below.
        resetDeviceState()
        // Give the interface a moment after enumeration, then run the same
        // handshake the official app sends on connect.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.sendHandshake()
        }
    }

    private func sendHandshake() {
        handshakeAttempt += 1
        let generation = handshakeGeneration
        // If the burst is lost the popover would sit blank until replug, so
        // retry a couple of times until the device answers.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, generation == self.handshakeGeneration,
                  !self.receivingReports, self.handshakeAttempt < 3,
                  case .connected = self.connection else { return }
            DebugLog.shared.log("no response — retrying handshake (\(self.handshakeAttempt + 1))")
            self.sendHandshake()
        }

        transportSend(.reqInitData, QxInit.requestPayload)   // [0, 0, At.Req]
        // sys is included for dd.eq_mode — needed to detect 20-band mode.
        transportSend(.reqDevConfig, [QxConfigMask.sys | QxConfigMask.playTime
                                 | QxConfigMask.dac | QxConfigMask.mic | QxConfigMask.batt])
        transportSend(.reqDevConfig, [0xC0])                 // sys2 | eq
        // audio | power | conn | vol — sample rate, battery, and current volume.
        transportSend(.reqDevStatus, [QxStatusMask.audio | QxStatusMask.power
                                 | QxStatusMask.conn | QxStatusMask.vol])
        transportSend(.reqEqPreset, [eqGroup.requestMask])
    }

    // MARK: - RX

    /// Report framing: [payloadLen, cmdHi, cmdLo, data...] — the leading
    /// report-ID byte is already stripped by HIDTransport.
    private func handlePacket(_ bytes: [UInt8]) {
        guard bytes.count >= 3 else { return }
        guard let (cmdId, data) = QxPacket.parseRx(bytes) else { return }
        // Only a packet we could actually parse counts as the device answering;
        // otherwise stray garbage cancels the handshake retry at `start()`.
        receivingReports = true
        dispatch(cmdId, data)
    }

    private func dispatch(_ cmdId: UInt16, _ data: [UInt8]) {
        // One line per accepted packet, throttled by volume rather than by
        // content. A device — broken or hostile — can push notifications fast
        // enough to roll the 2 MB log in under a minute, leaving a bug report
        // with two minutes of history. Above the burst allowance only the
        // count is kept, so the log still says what happened.
        if packetLogWindow.timeIntervalSinceNow < -1 {
            if suppressedPackets > 0 {
                DebugLog.shared.log("… \(suppressedPackets) further packets not logged")
            }
            packetLogWindow = Date()
            packetsLoggedThisSecond = 0
            suppressedPackets = 0
        }
        if packetsLoggedThisSecond < 40 {
            packetsLoggedThisSecond += 1
            DebugLog.shared.rx(cmdId, data)
        } else {
            suppressedPackets += 1
        }

        switch QxCmd(rawValue: cmdId) {
        case .rspInitData:
            if QxStatusParser.parseInitData(data, into: &state) { applyState() }
        case .rspDevStatus:
            _ = QxStatusParser.parseDevStatus(data, into: &state)
            applyState()
        case .rspDevConfig:
            _ = QxStatusParser.parseDevConfig(data, into: &state)
            applyState()
        case .rspEqPreset, .rspEqPresetL, .rspEqPresetH:
            if assembler.ingest(data) {
                applyPreset(QxUserEqPreset.decode(assembler.buffer, group: eqGroup))
                assembler.reset()
            }
        case .rspEqPresetName:
            parsePresetName(data)
        case .notification:
            parseNotification(data)
        default:
            break
        }
    }

    /// Notification (0x2000), fw >= 3: byte0 >= 128 → EQ (Et sub-param,
    /// then group byte); byte0 < 128 → [_, St flags, blocks...].
    private func parseNotification(_ data: [UInt8]) {
        guard data.count >= 2 else { return }
        if data[0] >= 128 {
            let group = data[1]
            // Every field here belongs to one EQ group, including the active
        // preset index: accepting it from a group the app is not in highlights
        // and names the wrong slot, and satisfies one of the gates on silent
        // preset switching.
        guard group == eqGroup.rawValue else { return }
            switch data[0] {
            case 129: if data.count >= 3 { setActivePreset(Int(data[2])) }  // eqPresetIdx
            case 130:                                                        // eqEnable
                if data.count >= 3, Date() >= eqEnableEditUntil {
                    eqEnabled = data[2] != 0
                }
            default: break
            }
        } else {
            let flags = data[1]
            var off = 2
            if flags & QxNotifyMask.status != 0 {
                off += QxStatusParser.parseDevStatus(data.tail(from: off), into: &state)
            }
            if flags & QxNotifyMask.config != 0 {
                _ = QxStatusParser.parseDevConfig(data.tail(from: off), into: &state)
            }
            applyState()
        }
    }

    /// RspEqPresetName, fw >= 3: [group, index, endOffset, utf8...]
    private func parsePresetName(_ data: [UInt8]) {
        guard data.count >= 3, data[0] == eqGroup.rawValue else { return }
        let idx = Int(data[1])
        guard (0..<Self.presetCount).contains(idx) else { return }
        let end = min(Int(data[2]), data.count)
        // An empty field is a real answer, not a non-answer: it is what a
        // cleared slot reports, and until this app could write names there was
        // nothing that could produce one, so it used to be ignored.
        guard end > 3 else { presetNames[idx] = nil; return }
        let nameBytes = data[3..<end].prefix { $0 != 0 }
        guard let raw = String(bytes: nameBytes, encoding: .utf8) else { return }
        let name = Self.displayName(raw)
        presetNames[idx] = name.isEmpty ? nil : name
    }

    /// Longest preset name the popover will show. The device's own field is
    /// bounded by the report size; this is about the row staying one line.
    nonisolated static let maxPresetNameLength = 32

    /// Names are stored on the device, so they are attacker-supplied in the
    /// same sense every other field is. Control and format scalars are dropped
    /// rather than escaped — a U+202E override would visually reorder the rows
    /// around it, and a newline would stretch the row.
    nonisolated static func displayName(_ s: String) -> String {
        // Bounded by scalars before anything else. The length cap below counts
        // Characters, and a grapheme cluster has no upper size — one letter
        // carrying a hundred combining marks is a single Character that
        // survives the cap intact and renders as a vertical smear over the
        // rows around it.
        let s = SafeText.scrubbed(
            String(String.UnicodeScalarView(s.unicodeScalars.prefix(maxPresetNameLength * 4))),
            limit: maxPresetNameLength * 4)
        let kept = s.unicodeScalars.filter { u in
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
        return String(String.UnicodeScalarView(kept))
            .trimmingCharacters(in: .whitespaces)
            .prefix(maxPresetNameLength)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Decide whether we may write to this device, from what the handshake told
    /// us. Only positive identification enables writing.
    private func evaluateCompatibility() {
        // Nothing conclusive yet — RspInitData hasn't landed.
        guard state.deviceId != 0, let major = state.fwMajor else { return }

        if state.deviceId != QxDeviceModel.qudelix5K {
            let known = QxDeviceModel.name(for: state.deviceId)
            compatibility = .unsupported(
                title: "\(known) isn't supported",
                detail: "This app implements the original Qudelix 5K protocol. "
                      + "\(known) uses a different EQ command set, so nothing will be written.")
            return
        }
        if major < 2 {
            compatibility = .unsupported(
                title: "Firmware \(state.fwVersion ?? "?") is too old",
                detail: "Update the 5K with the official Qudelix app, then reconnect.")
            return
        }
        if major == 2 {
            compatibility = .unsupported(
                title: "Firmware \(state.fwVersion ?? "2.x") uses a different protocol",
                detail: "Qudelix changed the EQ command format in firmware 3. "
                      + "Update with the official app, then reconnect.")
            return
        }
        compatibility = .ok
    }

    private func applyState() {
        evaluateCompatibility()
        // The other half of the restore race: compatibility may arrive after
        // the preset read-back. No-op once decided.
        if compatibility.canWrite { restoreIfNeeded() }
        // Consume eq_mode like the other user-changeable fields below:
        // `state` is cumulative, and re-running setEqGroup on every packet
        // would let any stale notification resolve a mode switch that is
        // still waiting on its real confirmation.
        if let mode = state.eqMode {
            sawEqMode = true
            setEqGroup(mode == 1 ? .b20 : .user)
            state.eqMode = nil
        }
        if let fw = state.fwVersion, fw != firmwareVersion { firmwareVersion = fw }
        if let b = state.batteryPercent, b != batteryPercent { batteryPercent = b }
        if charging != state.charging { charging = state.charging }
        if chargerConnected != state.chargerConnected {
            chargerConnected = state.chargerConnected
        }
        // None of these are locally editable, so unlike the volume and EQ
        // fields below they need no echo window and are not consumed: the
        // device's latest report is always the whole truth about them.
        if let low = state.batteryLow, low != batteryLow { batteryLow = low }
        if let cs = state.chargerState, cs != chargerState { chargerState = cs }
        if let ds = state.dacState, ds != dacState { dacState = ds }
        if let ce = state.chargerEnabled, ce != chargerEnabled { chargerEnabled = ce }
        if let bc = state.batteryCare, bc != batteryCare { batteryCare = bc }
        batteryAlerts.update(batteryPercent: batteryPercent, charging: charging,
                             deviceSaysLow: batteryLow ?? false)
        if let sr = state.sampleRateLabel, sr != sampleRate { sampleRate = sr }
        if let src = state.inputSourceLabel, src != inputSource { inputSource = src }
        if let call = state.activeCall, call != activeCall { activeCall = call }
        // Only meaningful on a Bluetooth link; over USB the device keeps
        // reporting whatever it last negotiated, which would be a lie in the
        // header.
        let codec = link == .bluetooth ? state.codecLabel : nil
        if codec != codecLabel { codecLabel = codec }
        if let gain = state.outputHighGain, gain != outputHighGain {
            outputHighGain = gain
        }
        if let m = state.usbMute { muted = m }
        if let fs = state.usbFsMode { usbFsMode = fs }
        // EQ group config only applies when it describes the group we're
        // targeting: in 20-band mode the block carries the b20 group, and
        // reading the 10-band group's preset index / name mask against it
        // highlights the wrong slot and fetches the wrong names.
        let eqCfgApplies = state.eqCfgGroup == Int(eqGroup.rawValue)
        if let en = state.eqEnabled, eqCfgApplies, Date() >= eqEnableEditUntil {
            eqEnabled = en
        }
        if let idx = state.eqPresetIdx, eqCfgApplies { setActivePreset(idx) }
        // Same echo as the EQ enable flag below: a write's own broadcast can
        // still carry the pre-change index for one round trip, so a report
        // inside the edit window is ignored rather than snapping the picker
        // back to what was just changed away from.
        if let f = state.dacFilterType, Date() >= dacFilterEditUntil, f != dacFilterType {
            dacFilterType = f
        }
        // Trim and limit ride in the same volume block as the level, so a
        // device push can carry the values from *before* a local edit — one
        // round trip behind, the same echo the EQ enable flag guards against.
        // The user's edit wins for the echo window; after it the device rules.
        if Date() >= volumeFieldEditUntil {
            if let l = state.trimLeftDb { trimLeftDb = l }
            if let r = state.trimRightDb { trimRightDb = r }
            if let lim = state.volumeLimitDb { volumeLimitDb = lim }
        } else {
            // volumeMax is recomputed from `state` on every pass, so a local
            // limit has to be written back there too or the ceiling — and
            // with it the whole slider range — flaps for a round trip. The
            // trims need no equivalent: they are consumed below.
            state.volumeLimitDb = volumeLimitDb
        }
        recomputeVolumeMax()
        // After volumeMax, so the slider's value always sits inside its range —
        // the device reports level and limit independently and can disagree.
        if let v = state.volumeDb {
            volumeDb = min(max(v, volumeRange.lowerBound), volumeRange.upperBound)
        }

        // Consume the fields the user can also change locally. `state` is
        // cumulative and applyState runs after *every* packet, so leaving these
        // set meant an unrelated push — a battery notification, say — re-applied
        // the last polled volume and mute over an edit the user had just made,
        // snapping the slider back mid-drag and flipping the EQ switch back on.
        // Config values (volumeLimitDb, dacOutPwr2Vrms) are deliberately kept,
        // because volumeMax is recomputed from them on every pass.
        state.volumeDb = nil
        state.usbMute = nil
        state.eqEnabled = nil
        state.eqPresetIdx = nil
        state.trimLeftDb = nil
        state.trimRightDb = nil

        let compat: String
        switch compatibility {
        case .checking: compat = "checking"
        case .ok: compat = "ok"
        case .unsupported(let t, _): compat = "UNSUPPORTED(\(t))"
        }
        // Change-only: a battery push every five seconds was writing three
        // identical log lines per packet, forever.
        let stateLine = "compat=\(compat) model=\(state.deviceId)"
            + " | fw=\(firmwareVersion ?? "?") batt=\(batteryPercent.map { "\($0)%" } ?? "?")"
            + (batteryLow ? " LOW" : "")
            + " chg=\(chargerConnected ? (charging ? "on" : "idle") : "off")"
            + "/\(chargerState.map(String.init) ?? "?")"
            + " chgEn=\(chargerEnabled.map { $0 ? "1" : "0" } ?? "?")"
            + " care=\(batteryCare.map { $0 ? "1" : "0" } ?? "?")"
            + " dacState=\(dacState.map(String.init) ?? "?")"
            + " vol=\(String(format: "%.1fdB", volumeDb))"
            + " max=\(String(format: "%.0f", volumeMax)) sr=\(sampleRate ?? "?") src=\(inputSource ?? "?")"
            + " eq=\(eqEnabled ? "on" : "off") preset=\(activePreset.map(String.init) ?? "?")"
            + " nameMask=\(String(state.presetNameMask, radix: 2))"
        if stateLine != lastStateLogLine {
            lastStateLogLine = stateLine
            DebugLog.shared.log(stateLine)
        }

        // Fetch saved preset names once the name mask is known — but not while a
        // group change is still queued, or we would request names using the mask
        // parsed for the group we are about to leave. The mask must also
        // belong to the current group, for the same reason.
        if !requestedNames, pendingGroup == nil, eqCfgApplies, state.presetNameMask != 0 {
            requestedNames = true
            for i in 0..<Self.presetCount where state.presetNameMask & (1 << i) != 0 {
                transportSend(.reqEqPresetName, [eqGroup.rawValue, UInt8(i)])
            }
        }
    }

    private func applyPreset(_ p: QxUserEqPreset) {
        guard p.bands.count == bandCount else { return }
        // The 20-band layout is derived from the firmware's parser but has not
        // been run against real hardware. If it decodes to nonsense, keep the
        // defaults rather than presenting garbage as the device's curve —
        // writing is unaffected either way.
        guard p.looksPlausible else {
            DebugLog.shared.log("preset decode implausible for group \(eqGroup) — ignoring")
            // An unreadable device state is exactly when the snapshot is
            // the best truth available: restoring rewrites the device
            // cleanly instead of leaving the UI flat and the struct broken.
            presetRead = true
            restoreIfNeeded()
            // The raw buffer is the only way to fix a wrong layout against
            // real hardware — but the device decides how many readbacks
            // happen, and a hostile one could flood these ~400-char lines
            // until rotation evicts the history a bug report needs.
            if Date().timeIntervalSince(lastImplausibleDump) > 10 {
                lastImplausibleDump = Date()
                let hex = assembler.buffer.map { String(format: "%02X", $0) }.joined(separator: " ")
                DebugLog.shared.log("raw preset buffer: \(hex)")
                let decoded = p.bands.map { String(format: "f%d g%.1f q%.2f %d",
                                                   $0.freq, $0.gain, $0.q, $0.filter.rawValue) }
                DebugLog.shared.log("decoded: preGain \(p.preGain) | " + decoded.joined(separator: " · "))
            }
            return
        }
        // `looksPlausible` is deliberately wider than the editor's range, so a
        // real device reporting a curve we can't represent still shows up
        // instead of being discarded. Clamp it to what the sliders can express
        // and what `updateBand` would write back, so the displayed and exported
        // curve is one we could actually reproduce.
        preGain = EQHeadroom.clamp(p.preGain)
        // The two stored channels are meant to agree. If they don't, the device
        // is playing at different levels left and right, and the app cannot
        // show it — one number is all there is room for. Correct it rather than
        // report it: the value the user set is channel 0, so channel 1 is
        // simply wrong, and rewriting pre-gain sends both from now on.
        if abs(p.preGain - p.preGainCh1) > 0.06, canWriteEq, !preGainRepaired {
            // Once per connection. Every completed preset read-back used to
            // retrigger this, and a single inbound frame can complete one — so
            // a device that kept reporting a mismatch, whether broken or
            // hostile, drove an unbounded pair of writes back at itself. One
            // attempt is all a repair is worth: if it did not take, sending it
            // again on the next report will not help either.
            preGainRepaired = true
            DebugLog.shared.log(String(
                format: "pre-gain channels disagree (%.1f / %.1f dB) — evening them up",
                p.preGain, p.preGainCh1))
            sendPreGain(Int((preGain * QxScale.gain).rounded()))
        }
        // Crossfeed is part of the preset the device just handed back, so it
        // is only known once a preset decodes cleanly.
        crossfeedLevel = p.crossfeedLevel
        bands = p.bands.map { band in
            var v = band
            v.freq = max(20, min(20000, v.freq))
            v.gain = v.gain.isFinite ? max(-12, min(12, v.gain)) : 0
            v.q = v.q.isFinite ? max(0.1, min(10, v.q)) : 1.0
            return v
        }
        // The device's report ends any mute it disagrees with. A band that
        // came back carrying a real filter is audible again — whatever this
        // app last asked for — so the shape held for it is no longer a way
        // back to anything.
        // Read-backs are frequent; only assign when it actually changes, so
        // an unchanged curve doesn't redraw the band table on every poll.
        let surviving = mutedBands.filter { index, _ in
            bands.indices.contains(index) && bands[index].filter == .bypass
        }
        if surviving != mutedBands { mutedBands = surviving }
        // Only once the real band values are in: the snapshot's shapes are
        // only usable against bands the device actually reports as bypassed.
        reclaimMutedBands()
        presetRead = true
        restoreIfNeeded()
        eqObserved()
    }

    #if DEBUG
    /// UIPreview only: force a group without a device attached.
    func applyPreviewGroup(_ group: QxEqGroup) {
        eqGroup = group
        assembler.group = group
    }
    #endif

    /// The device reports which preset slot is active. Out-of-range values are
    /// dropped rather than stored: nothing indexes an array with this, but a
    /// bogus index silently un-highlights every row.
    private func setActivePreset(_ idx: Int) {
        // 255 is the device's explicit "custom curve, no slot" sentinel —
        // dropping it left the previous slot highlighted for a curve it no
        // longer describes.
        if idx == 255 { activePreset = nil; return }
        guard (0..<Self.presetCount).contains(idx) else { return }
        activePreset = idx
    }

    /// Rate limit for EQ-group switches. Each switch clears the cached preset
    /// names and re-requests up to 20 of them, and every send costs ~20 ms of
    /// transport queue time — so a device flipping `dd.eq_mode` in a loop can
    /// starve the user's own volume and EQ writes. Real mode changes are a
    /// human action; one per second is generous.
    private var lastGroupSwitch = Date.distantPast
    /// A group change that arrived inside the rate-limit window, waiting to apply.
    private var pendingGroup: QxEqGroup?
    private static let groupSwitchInterval: TimeInterval = 1

    /// Re-target the EQ when the device reports a different mode.
    private func setEqGroup(_ group: QxEqGroup) {
        // Whatever the device reports IS the truth now; a click waiting on
        // confirmation is resolved either way.
        pendingEqMode = nil
        guard group != eqGroup else { pendingGroup = nil; return }
        // The bands are about to be replaced with the other group's. An edit
        // made a moment ago has a snapshot queued against the outgoing curve;
        // letting it fire would file one group's bands under the other's.
        snapshotWork?.cancel()
        // Rate limited, but the change is *deferred* rather than dropped. Simply
        // discarding it left `eqGroup` — which selects the band count and the
        // group byte on every write — disagreeing with the device until it
        // happened to re-report, so a correction arriving inside the window used
        // to be lost.
        let wait = Self.groupSwitchInterval - Date().timeIntervalSince(lastGroupSwitch)
        if wait > 0 {
            guard pendingGroup != group else { return }
            pendingGroup = group
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, let queued = self.pendingGroup else { return }
                self.pendingGroup = nil
                self.setEqGroup(queued)
            }
            return
        }
        pendingGroup = nil
        lastGroupSwitch = Date()
        DebugLog.shared.log("EQ group → \(group) (\(group.bandCount) bands)")
        // Now that the switch is actually going ahead. The history describes
        // the outgoing group's curve, and replaying an entry onto the incoming
        // group's bands would write a shape that was never on them. Done here
        // rather than on every differing report, so a deferred or rate-limited
        // one no longer throws the history away for a switch that never
        // happened.
        undoStack.removeAll()
        redoStack.removeAll()
        eqGroup = group
        assembler.group = group
        assembler.reset()
        bands = group.defaultFreqs.map {
            QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1.0)
        }
        requestedNames = false
        presetNames = [:]
        // The active-slot highlight and the curve's source name belong to
        // the group we just left; the config re-request below refreshes the
        // slot for this group.
        activePreset = nil
        eqSourceName = nil
        sourceCurve = nil
        sourcePreGain = nil
        lastImportSummary = nil
        requestedCorrection = nil
        // Crossfeed is stored per preset, so it belongs to the group we left.
        crossfeedLevel = nil
        // The bands were just replaced with this group's defaults, so band 3
        // is a different band than the one that was muted a moment ago.
        mutedBands = [:]
        // Those defaults are a placeholder, not something the device said.
        // Until the request below is answered, nothing may treat them as this
        // group's curve — neither the snapshot (quitting inside the round trip
        // would file "flat" as the group's last EQ) nor the restore check
        // (which would read the placeholder as a device that had diverged and
        // write over the curve it is about to report).
        presetRead = false
        transportSend(.reqEqPreset, [group.requestMask])
        transportSend(.reqDevConfig, [0xC0])   // sys2 | eq → this group's cfg + name mask
    }

    var reportedVolumeDb: Double? {
        guard case .connected = connection, receivingReports, !muted,
              volumeDb.isFinite else { return nil }
        return min(max(volumeDb, volumeRange.lowerBound), volumeRange.upperBound)
    }

    // MARK: - Actions

    /// Single gate for everything that writes to the hardware.
    private var canWrite: Bool {
        if case .connected = connection { return compatibility.canWrite }
        return false
    }

    /// Gate for writes that carry the EQ group byte (band edits, pre-gain,
    /// preset slots). While a device-reported group change sits in the rate
    /// limiter's deferral window, `eqGroup` still names the group the device
    /// just left — an edit sent then would silently modify the wrong curve.
    private var canWriteEq: Bool {
        guard canWrite else { return false }
        // Both halves of "the group is in flux" matter. `pendingGroup` is the
        // device deferring a switch; `pendingEqMode` is one this app asked for
        // and the device has not confirmed. Gating only the first let a band
        // edit made straight after clicking 10/20 go out carrying the old
        // group byte — editing the curve the user had just left, while the
        // table showed it as applied. `restoreIfNeeded` already checked both.
        guard pendingGroup == nil, pendingEqMode == nil else {
            DebugLog.shared.log("EQ write dropped: group switch in progress")
            return false
        }
        return true
    }

    func setVolume(_ db: Double) {
        guard canWrite, db.isFinite else { return }
        let clamped = max(volumeMax - 60, min(volumeMax, db))
        volumeDb = clamped
        let scaled = Int((clamped * QxScale.volume).rounded())
        transportSendCoalesced(.setVolume,
                          [QxVolumeParam.sink.rawValue] + QxPacket.int16BE(scaled),
                          key: "volume")
    }

    func setMute(_ on: Bool) {
        guard canWrite else { return }
        muted = on
        transportSend(.setVolume, [QxVolumeParam.mute.rawValue, 0, on ? 1 : 0])
    }

    /// How long a locally-edited volume-block field ignores device reports.
    /// Same reasoning as the EQ enable flag's window: the device answers a
    /// write by broadcasting the block, and that broadcast can still carry
    /// the pre-change value.
    private static let volumeEchoWindow: TimeInterval = 1.5
    private var volumeFieldEditUntil = Date.distantPast

    /// Ranges for the UI, so the sliders and the wire agree on the bounds.
    /// Whether hardware settings can be written right now — for disabling
    /// controls rather than letting them move and silently do nothing.
    var canWriteNow: Bool { canWrite }

    /// Whether an EQ write would actually go out right now.
    ///
    /// `canWriteNow` only answers "is there a device"; EQ writes additionally
    /// need the group settled. Controls that go through the EQ path have to
    /// disable on this one, or they stay live during a mode switch and drop
    /// the click silently.
    var canEditEqNow: Bool { canWriteEq }

    var trimRange: ClosedRange<Double> { QxVolumeRange.trim }
    var volumeLimitRange: ClosedRange<Double> { QxVolumeRange.limit }

    /// Trim one channel down against the other. Attenuation only, so the pair
    /// behaves as a balance control that can never raise the output.
    func setTrimLeft(_ db: Double) { setTrim(.sysTrimL, db) }
    func setTrimRight(_ db: Double) { setTrim(.sysTrimR, db) }

    private func setTrim(_ param: QxVolumeParam, _ db: Double) {
        // volumePayload refuses non-finite input, which is also the only input
        // that has no sane clamp — so the guard covers both.
        guard canWrite, let payload = QxPacket.volumePayload(param, db: db) else { return }
        let clamped = param.clamp(db)
        if param == .sysTrimL { trimLeftDb = clamped } else { trimRightDb = clamped }
        volumeFieldEditUntil = Date().addingTimeInterval(Self.volumeEchoWindow)
        transportSendCoalesced(.setVolume, payload, key: "trim\(param.rawValue)")
    }

    /// Set the device's own volume ceiling. The hardware enforces it, so this
    /// is a real limit rather than a UI one — and lowering it below the
    /// current level pulls the whole slider range down immediately, without
    /// waiting for the device to report back.
    func setVolumeLimit(_ db: Double) {
        guard canWrite,
              let payload = QxPacket.volumePayload(.sysLimit, db: db) else { return }
        let clamped = QxVolumeParam.sysLimit.clamp(db)
        volumeLimitDb = clamped
        state.volumeLimitDb = clamped
        volumeFieldEditUntil = Date().addingTimeInterval(Self.volumeEchoWindow)
        recomputeVolumeMax()
        transportSendCoalesced(.setVolume, payload, key: "volumeLimit")
    }

    /// The ceiling is the lower of the device's volume limit and its hardware
    /// cap (+6 dB in 2 Vrms output mode, 0 dB in 1 Vrms), and the slider's
    /// 60 dB window hangs off it.
    private func recomputeVolumeMax() {
        volumeMax = state.dacOutPwr2Vrms ? min(state.volumeLimitDb ?? 6, 6)
                                         : min(state.volumeLimitDb ?? 0, 0)
        // A lowered limit can leave the displayed level above the new ceiling.
        volumeDb = min(max(volumeDb, volumeRange.lowerBound), volumeRange.upperBound)
    }

    /// Names for the usb_fs_mode values, in wire order — which is
    /// DESCENDING for the pinned rates. Verified live: sending 3 pins the
    /// device to 44.1 kHz (it re-enumerates and renames itself
    /// "…USB DAC 44.1KHz"), not to 96 as an ascending reading would say.
    static let usbFsModeLabels = ["96 kHz only", "88.2 kHz only", "48 kHz only",
                                  "44.1 kHz only", "All rates",
                                  "48 kHz + mic", "44.1 kHz + mic"]

    /// Change which rates the USB descriptor offers. The device restarts its
    /// USB connection to re-enumerate — audio drops for a couple of seconds
    /// and this app reconnects on its own.
    func setUsbFsMode(_ idx: Int) {
        guard canWrite, (0...6).contains(idx), idx != usbFsMode else { return }
        DebugLog.shared.log("requesting USB FS mode → \(Self.usbFsModeLabels[idx])")
        usbFsMode = idx
        transportSend(.setUsbFsMode, [UInt8(idx)])
    }

    /// Reports of the filter are ignored for this long after a local pick,
    /// for the same reason as the EQ enable flag just below: the device
    /// answers by broadcasting its dac config block, and that can still
    /// carry the pre-change index for one round trip. After the window, the
    /// device's own report is what the picker shows — never what was asked
    /// for.
    private var dacFilterEditUntil = Date.distantPast

    /// Switch the DAC's reconstruction filter. Only ever sends an index this
    /// build's own label table defines: `dacFilterPayload` refuses anything
    /// else, so a bad index from the UI can't reach the wire and land on some
    /// other setting the device would silently accept in its place.
    func setDacFilter(_ index: Int) {
        guard canWrite, let payload = QxPacket.dacFilterPayload(index) else { return }
        dacFilterType = index
        dacFilterEditUntil = Date().addingTimeInterval(1.5)
        transportSend(.setDacFilter, payload)
    }

    /// Reports of the enable flag are ignored for this long after a local
    /// toggle. The device answers a toggle by broadcasting its config, and
    /// that broadcast can carry the PRE-change enable bit — one round trip
    /// behind — which snapped the switch straight back off. The user's click
    /// wins for the echo window; the next unsolicited report rules again.
    private var eqEnableEditUntil = Date.distantPast

    func setEqEnabled(_ on: Bool, persistToFlash: Bool = true) {
        guard canWriteEq else { return }
        eqEnabled = on
        eqEnableEditUntil = Date().addingTimeInterval(1.5)
        transportSend(.setEqEnable, [eqGroup.rawValue, on ? 1 : 0])
        eqEdited(persistToFlash: persistToFlash)
    }

    /// What the last setEqMode click asked for, while the device has not yet
    /// confirmed. Without it, a "switch back" click made inside the round
    /// trip compares equal to the still-unchanged `eqGroup` and is swallowed
    /// — the device then lands on the mode the user just backed out of.
    private var pendingEqMode: QxEqGroup?
    private var lastEqModeSend = Date.distantPast

    /// Switch the device between its 10-band and 20-band EQ modes. The two
    /// modes are separate EQ groups with separate presets, so the curve
    /// changes completely — that is the device's design, not a bug here.
    ///
    /// Deliberately NOT optimistic: `eqGroup` re-targets only when the
    /// device confirms the flip through its config notification (the same
    /// path that follows a switch made in any other app), so the band table
    /// can never disagree with what the hardware is actually running.
    func setEqMode(twentyBand: Bool) {
        guard canWrite else { return }
        let desired: QxEqGroup = twentyBand ? .b20 : .user
        // Compare against what was last ASKED for, not only what the device
        // last confirmed.
        guard desired != (pendingEqMode ?? eqGroup) else { return }
        // One human click per send; the picker is the only caller, and this
        // is a hardware write with no other throttle.
        guard Date().timeIntervalSince(lastEqModeSend) > 0.3 else { return }
        lastEqModeSend = Date()
        pendingEqMode = desired == eqGroup ? nil : desired
        DebugLog.shared.log("requesting EQ mode → \(twentyBand ? "20-band" : "10-band")")
        transportSend(.setEqMode, [twentyBand ? 1 : 0])
        // The device pushes the config change. Also ask — a silently ignored
        // click is the worst outcome here — but only after the device has
        // had time to apply: an immediate read can race the switch and
        // report the old mode as if it were a fresh confirmation.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.pendingEqMode != nil else { return }
            self.transportSend(.reqDevConfig, [QxConfigMask.sys])
        }
    }

    /// Returns whether the load was actually sent. Callers that record a
    /// consequence of it — the profile rules mark an output as confirmed —
    /// must not treat a dropped write as a completed switch.
    @discardableResult
    func loadPreset(_ index: Int) -> Bool {
        guard canWriteEq, (0..<Self.presetCount).contains(index) else { return false }
        checkpoint("load \(presetLabel(index))", discrete: true)
        eqSourceName = presetLabel(index)
        requestedCorrection = nil
        sourceCurve = nil
        sourcePreGain = nil
        activePreset = index
        // The slot brings its own curve, including whichever of its bands it
        // stores as bypassed. Those are the preset's, not mutes of ours.
        mutedBands = [:]
        assembler.reset()
        transportSend(.loadEqPreset, [UInt8(index)])
        transportSend(.reqEqPreset, [eqGroup.requestMask])   // refresh band values
        return true
    }

    /// Display name for a preset slot, falling back to its number.
    func presetLabel(_ index: Int) -> String {
        presetNames[index] ?? "Preset \(index + 1)"
    }

    func flatten() {
        guard canWriteEq else { return }
        checkpoint("flatten", discrete: true)
        suppressUndo = true
        defer { suppressUndo = false }
        forgetSource()
        setPreGain(0)
        for i in 0..<bandCount where bands.indices.contains(i) {
            var b = bands[i]
            guard b.gain != 0 else { continue }
            b.gain = 0
            updateBand(i, b)
        }
        lastImportSummary = "Band gains zeroed"
    }

    func resetBandLayout() {
        guard canWriteEq else { return }
        checkpoint("reset band layout", discrete: true)
        suppressUndo = true
        defer { suppressUndo = false }
        forgetSource()
        setPreGain(0)
        let defaults = eqGroup.defaultFreqs
        for i in 0..<bandCount where defaults.indices.contains(i) {
            updateBand(i, QxEqBandValue(filter: .peak, freq: defaults[i], gain: 0, q: 1.0))
        }
        lastImportSummary = "Band layout reset"
    }

    func zeroBand(_ index: Int) {
        guard canWriteEq, bands.indices.contains(index), index < bandCount else { return }
        var b = bands[index]
        if b.filter != .bypass, !b.filter.hasGain { b.filter = .peak }
        b.gain = 0
        guard b != bands[index] else { return }
        checkpoint("zero band \(index + 1)", discrete: true)
        suppressUndo = true
        defer { suppressUndo = false }
        updateBand(index, b)
    }

    private func forgetSource() {
        eqSourceName = nil
        sourceCurve = nil
        sourcePreGain = nil
        lastImportSummary = nil
        requestedCorrection = nil
    }

    func savePreset(_ index: Int) {
        guard canWriteEq, (0..<Self.presetCount).contains(index) else { return }
        transportSend(.saveEqPreset, [UInt8(index)])
        // The slot now holds this correction, so give it the correction's
        // name. Saving into slot 7 and reading back "Preset 7" is the gap
        // naming was built to close.
        if let name = Self.nameOnSave(source: eqSourceName,
                                      existing: presetNames[index],
                                      unchangedSinceSource: curveMatchesSource) {
            setPresetName(index, name)
        }
    }

    /// The name a slot should take when the current curve is saved into it, or
    /// nil to leave whatever is there alone.
    ///
    /// A curve with a source — an import, an AutoEq fit — names the slot after
    /// it, because that is now what the slot contains. A hand-shaped curve has
    /// no name to offer, and clearing the slot's existing one would destroy
    /// something the user typed in exchange for nothing.
    nonisolated static func nameOnSave(source: String?, existing: String?,
                                       unchangedSinceSource: Bool) -> String? {
        // A curve that has been shaped since it arrived is no longer the thing
        // the name describes. Labelling a slot "HD 650" when it holds an hour
        // of by-ear tuning on top of HD 650 is worse than leaving it unnamed,
        // because the label would be believed.
        guard unchangedSinceSource else { return nil }
        guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else { return nil }
        // Re-saving a slot under the name it already has is a wasted write to
        // a device that stores it in flash.
        guard source != existing else { return nil }
        return source
    }

    /// Name a preset slot on the device.
    ///
    /// The name is scrubbed the same way names arriving *from* the device are,
    /// before it is sent: this app is not the only thing that will read it
    /// back, and a control or direction-override scalar written into a slot
    /// would misrender wherever it is shown. An empty name clears the slot.
    ///
    /// The local value is set optimistically so the row does not flicker, then
    /// the slot is read back — the device's answer is what finally stands.
    func setPresetName(_ index: Int, _ name: String) {
        guard canWriteEq,
              let payload = QxPacket.presetNamePayload(
                  group: eqGroup, index: index,
                  name: Self.displayName(name)) else { return }

        let stored = QxPacket.truncatingUTF8(Self.displayName(name),
                                             to: QxPacket.maxPresetNameBytes)
        if stored.isEmpty { presetNames[index] = nil } else { presetNames[index] = stored }

        transportSend(.setEqPresetName, payload)
        // Confirm rather than assume. A name is the one device string this app
        // writes, and the slot is worth re-reading to see what actually landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.canWriteEq else { return }
            self.transportSend(.reqEqPresetName, [self.eqGroup.rawValue, UInt8(index)])
        }
    }

    func setPreGain(_ db: Double, persistToFlash: Bool = true, recordUndo: Bool = true) {
        guard canWriteEq, db.isFinite else { return }
        if recordUndo { checkpoint("pre-gain") }
        let clamped = EQHeadroom.clamp(db)
        preGain = clamped
        sendPreGain(Int((clamped * QxScale.gain).rounded()))
        eqEdited(persistToFlash: persistToFlash)
    }

    /// How much headroom the curve on screen needs, and the pre-gain that
    /// would give it.
    ///
    /// Computed on every read rather than cached. A full 20-band curve costs
    /// about 0.6 ms of biquad arithmetic, which a slider drag can afford,
    /// while a cache would have to be invalidated from band edits, pre-gain
    /// writes, preset loads, device read-backs and mode switches to buy
    /// nothing anyone could see.
    var eqHeadroom: EQHeadroom.Advice {
        EQHeadroom.advice(for: bands, preGain: preGain)
    }

    /// Take the suggestion. Nothing special about this write: it goes through
    /// `setPreGain`, so it is gated, clamped and snapshotted like a drag of
    /// the slider would be.
    func applySuggestedPreGain() {
        guard let db = eqHeadroom.suggestion else { return }
        setPreGain(db)
    }

    /// Every value written to the device is clamped here — a text field can
    /// produce anything, and out-of-range reports are what knock this hardware
    /// off the USB bus. `bandParamPayload` refuses whatever the clamp couldn't
    /// rescue, and the local value is only adopted once a packet exists for
    /// it: a rejected edit changes nothing on either side.
    /// `recordUndo: false` writes without adding a step. For a caller that is
    /// making many writes it does not want walked back one at a time — an A/B
    /// trial curve, twenty times a session — which should instead take a single
    /// step of its own with `beginUndoStep`.
    func updateBand(_ index: Int, _ value: QxEqBandValue,
                    persistToFlash: Bool = true, recordUndo: Bool = true) {
        guard canWriteEq, bands.indices.contains(index), index < bandCount else { return }
        if recordUndo { checkpoint("band \(index + 1)") }
        var v = value
        v.freq = max(20, min(20000, v.freq))
        v.gain = v.gain.isFinite ? max(-12, min(12, v.gain)) : 0
        v.q = v.q.isFinite ? max(0.1, min(10, v.q)) : 1.0
        guard let payload = QxPacket.bandParamPayload(group: eqGroup, band: index, v) else { return }
        bands[index] = v
        // Any edit that gives the band a filter again ends its mute: there is
        // nothing left to restore, and a shape kept past that point would
        // later offer to "unmute" a band the user had since shaped by hand.
        if v.filter != .bypass, mutedBands[index] != nil { mutedBands[index] = nil }

        transportSendCoalesced(.setEqBandParam, payload, key: "band\(index)")
        eqEdited(persistToFlash: persistToFlash)
    }

    /// Whether this band is muted — bypassed by this app, with a shape kept
    /// to bring back.
    ///
    /// Deliberately narrower than "bypassed". An import leaves the bands it
    /// didn't fill bypassed too, and those are empty slots: showing them as
    /// muted would promise an unmute that restores nothing.
    func isBandMuted(_ index: Int) -> Bool {
        guard mutedBands[index] != nil, bands.indices.contains(index) else { return false }
        return bands[index].filter == .bypass
    }

    /// Silence one band, or bring it back, without touching its gain.
    ///
    /// This is the cheapest A/B the EQ has: it answers "what is this band
    /// doing for me" in one click and one packet, and the answer costs
    /// nothing to undo. It writes through `updateBand`, so it is gated,
    /// clamped, coalesced and snapshotted exactly like moving the slider —
    /// the only difference is which field changes.
    func setBandMuted(_ index: Int, _ muted: Bool) {
        guard canWriteEq, bands.indices.contains(index), index < bandCount else { return }
        checkpoint(muted ? "mute band \(index + 1)" : "unmute band \(index + 1)",
                   discrete: true)
        suppressUndo = true
        defer { suppressUndo = false }
        if muted {
            let shape = bands[index].filter
            // A band already contributing nothing has no shape to keep, and
            // recording bypass as the way back would make unmute a no-op
            // that looks like a broken button.
            guard shape != .bypass else { return }
            var b = bands[index]
            b.filter = .bypass
            updateBand(index, b, persistToFlash: false)
            // Only after the write is known to have gone out: a refused one
            // leaves the band audible, and a mute recorded against it would
            // put a slash through a row that is still playing.
            guard bands[index].filter == .bypass else { return }
            mutedBands[index] = shape
        } else {
            guard isBandMuted(index), let shape = mutedBands[index] else { return }
            var b = bands[index]
            b.filter = shape
            updateBand(index, b, persistToFlash: false)   // clears the entry itself
        }
    }

    // MARK: - Preset import / export

    /// Push a parsed parametric-EQ file to the device: pre-gain, then every
    /// band, then any unused bands bypassed so leftovers from the previous
    /// preset can't linger.
    func apply(_ file: ParametricEQFile, named name: String? = nil) {
        guard canWriteEq else {
            lastImportSummary = "Not applied — this device isn't supported."
            return
        }
        checkpoint("import", discrete: true)
        suppressUndo = true
        defer { suppressUndo = false }
        eqSourceName = name
        requestedCorrection = file
        // Every band is about to be rewritten, and the bands past the file's
        // length are bypassed on purpose — empty slots, not mutes.
        mutedBands = [:]
        if !eqEnabled { setEqEnabled(true) }
        transportSend(.setEqType, [eqGroup.rawValue, 1])   // 1 = PEQ
        setPreGain(max(-12, min(12, file.preamp)))

        for i in 0..<bandCount {
            guard bands.indices.contains(i) else { break }
            if i < file.bands.count {
                var b = file.bands[i]
                b.gain = max(-12, min(12, b.gain))
                b.q = max(0.1, min(10, b.q))
                b.freq = max(20, min(20000, b.freq))
                updateBand(i, b)
            } else {
                var b = bands[i]
                b.filter = .bypass
                updateBand(i, b)
            }
        }
        // A file can carry more bands than the ACTIVE mode holds (a 12-band
        // file in 10-band mode): count those as dropped too, and say which
        // mode would fit them.
        let applied = min(file.bands.count, bandCount)
        let dropped = file.droppedBands + max(0, file.bands.count - bandCount)
        lastImportSummary = (["Applied \(applied) band(s), pre-gain "
            + String(format: "%+.1f dB", file.preamp)
            + (dropped > 0 ? " · \(dropped) band(s) dropped"
                + (file.bands.count > bandCount && eqGroup != .b20
                   ? " (fit in 20-band mode)" : "") : "")]
            + file.notes).joined(separator: " · ")
        DebugLog.shared.log("import: \(lastImportSummary ?? "")")
        sourceCurve = bands
        sourcePreGain = preGain
    }

    /// EQ files are a few hundred bytes; refuse anything absurd rather than
    /// reading an arbitrary user-picked file entirely into memory.
    static let maxImportBytes = 1_000_000

    /// Import a correction from text rather than a file.
    ///
    /// Sites that publish these show the filter list on the page, and copying
    /// it is what people already do. Drag-and-drop would be the other obvious
    /// route and is not available here: this window belongs to a menu bar
    /// item, and the first click in Finder to start a drag dismisses it.
    ///
    /// `named` is nil for pasted text on purpose — a clipboard has no name,
    /// and inventing one would put a label on a preset slot that nothing
    /// stands behind.
    func importText(_ text: String, named: String? = nil) {
        guard text.utf8.count <= Self.maxImportBytes else {
            lastImportSummary = "That is too much text to be an EQ preset."
            return
        }
        guard let parsed = ParametricEQFile.parse(text) else {
            lastImportSummary = "No EQ filters found in what was pasted."
            return
        }
        apply(parsed, named: named)
    }

    func importFile(at url: URL) {
        let name = SafeText.scrubbed(url.lastPathComponent, limit: 64)
        guard let data = SafeFile.read(url, cap: Self.maxImportBytes) else {
            lastImportSummary = "Couldn't read \(name) — an EQ preset is a plain "
                + "text file, and not a large one."
            return
        }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            lastImportSummary = "Could not read \(name) as text."
            return
        }
        guard let parsed = ParametricEQFile.parse(text) else {
            lastImportSummary = "No filters found in \(name)"
            return
        }
        apply(parsed, named: url.deletingPathExtension().lastPathComponent)
    }

    /// Serialise the current bands in the same format we import.
    func exportText() -> String {
        var lines = [String(format: "Preamp: %.1f dB", preGain)]
        for (i, b) in bands.enumerated() {
            // A muted band is still part of the user's curve — the mute is a
            // momentary A/B, so export its parked shape rather than dropping
            // the band and handing out a file with a filter silently missing.
            // A band that is bypassed with nothing parked really is empty.
            let shape = b.filter == .bypass ? (mutedBands[i] ?? .bypass) : b.filter
            guard let token = Self.exportToken(for: shape) else { continue }
            lines.append(String(format: "Filter %d: ON %@ Fc %d Hz Gain %.1f dB Q %.2f",
                                i + 1, token, b.freq, b.gain, b.q))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func refresh() {
        guard case .connected = connection else { return }
        // Read requests are safe on any model; only writes are gated.
        // Same curated mask as the handshake. `Yc.all` (0xFF) would set the
        // runtimeEq bit the firmware never uses plus an undefined bit 0x80,
        // and this device drops off the bus when it dislikes a report.
        transportSend(.reqDevStatus, [QxStatusMask.audio | QxStatusMask.power
                                 | QxStatusMask.conn | QxStatusMask.vol])
        transportSend(.reqEqPreset, [eqGroup.requestMask])
    }

    /// Pre-gain, to both stored channels.
    ///
    /// The preset keeps two pre-gain fields and this app only ever wrote the
    /// first, leaving the second at whatever it already held — a left/right
    /// imbalance the app could not even see, because the decoder reads channel
    /// 0 and steps over channel 1. One device was found holding -8.0 and -3.7.
    ///
    /// Two single-channel writes rather than the both-channels mask. That mask
    /// is what made the firmware corrupt its own preset struct once before, so
    /// it is not sent here on any group; a hardware probe on both groups showed
    /// mask 2 reaches channel 1 on its own, changing nothing else in the
    /// preset. Separate coalescing keys, or the second would replace the first
    /// during a slider drag.
    private func sendPreGain(_ scaled: Int) {
        for mask in [UInt8(1), UInt8(2)] {
            transportSendCoalesced(
                .setEqPreGain,
                [eqGroup.rawValue, mask, 0] + QxPacket.int16BE(scaled),
                key: "preGain-\(mask)")
        }
    }

    private func sendEqParam(_ cmd: QxCmd, band: Int, scaled: Int) {
        transportSendCoalesced(cmd,
                          [eqGroup.rawValue, eqGroup.writeChannelMask, UInt8(clamping: band)]
                            + QxPacket.int16BE(scaled),
                          key: "\(cmd)-\(band)")
    }
}
