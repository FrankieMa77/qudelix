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
    @Published var sampleRate: String?
    @Published var inputSource: String?
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
    /// `QxStatusParser.dacFilters`). Read only — see `dacFilterLabel`.
    @Published var dacFilterType: Int?

    /// Crossfeed level stored in the preset the device is currently running,
    /// in its own 0…63 steps, or nil if no preset has been read. Read only.
    @Published var crossfeedLevel: Int?

    /// Active Bluetooth codec, when one is in use. Nil over USB.
    @Published var codecLabel: String?
    /// True while the amp is in its high-gain / higher-output state.
    @Published var outputHighGain: Bool?

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

    /// Set only by UIPreview to force a starting pane when rendering mocks.
    var previewPane: PopoverView.Pane?
    /// Set only by UIPreview: seeds the AutoEq list so it renders offline.
    var previewAutoEq: (entries: [AutoEqEntry], query: String)?
    static let presetCount = 20

    /// EQ group the device is currently using — driven by `dd.eq_mode`.
    /// 10-band user EQ by default; 20-band (b20) when the device is in that mode.
    @Published private(set) var eqGroup: QxEqGroup = .user
    var bandCount: Int { eqGroup.bandCount }

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
    private var eqSnapshot = EqSnapshotFile.load()
    private var snapshotWork: DispatchWorkItem?
    private var saveAllWork: DispatchWorkItem?
    /// One restore decision per connection, taken at the first preset
    /// read-back — later read-backs are the result of user actions.
    private var restoreDecided = false
    /// Whether this connection has read the device's EQ at least once.
    private var presetRead = false
    /// Whether this connection has seen the device report its eq_mode.
    private var sawEqMode = false
    /// The name attached to the current curve (import file, AutoEq entry).
    private var eqSourceName: String?
    private var lastImplausibleDump = Date.distantPast
    private var lastStateLogLine = ""

    /// Call after any EQ mutation reaches the device. Debounced twice:
    /// a quick app-side snapshot, and a slower ask for the device to
    /// persist its settings to flash (the official app only does that
    /// before firmware updates, so a restart otherwise reverts the EQ).
    private func eqEdited() {
        snapshotWork?.cancel()
        let snap = DispatchWorkItem { [weak self] in self?.snapshotNow() }
        snapshotWork = snap
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: snap)

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
        let snap = EqSnapshot(groupRaw: eqGroup.rawValue, bands: bands,
                              preGain: preGain, enabled: eqEnabled,
                              name: eqSourceName)
        guard snap != eqSnapshot else { return }
        eqSnapshot = snap
        EqSnapshotFile.save(snap)
    }

    /// First preset read-back of a connection: if the device came back with
    /// a different curve than this app last saw — a hard restart reverted
    /// its RAM state, or a reset wiped it — put the last one back.
    private func restoreIfNeeded() {
        // Everything here must hold before the once-per-connection decision
        // is taken: the read-back can beat the compatibility verdict, a
        // pending group switch gates the very writes a restore would send
        // (they'd be dropped silently), and deciding against the handshake's
        // provisional group burns the decision before eq_mode has spoken.
        guard !restoreDecided, presetRead, compatibility.canWrite,
              pendingGroup == nil, pendingEqMode == nil else { return }
        if let snap = eqSnapshot, snap.groupRaw != eqGroup.rawValue, !sawEqMode {
            return   // the device's real mode isn't known yet; stay undecided
        }
        restoreDecided = true
        guard let snap = eqSnapshot, snap.groupRaw == eqGroup.rawValue,
              snap.bands.count == bandCount,
              !snap.matches(bands: bands, preGain: preGain) else { return }
        DebugLog.shared.log("device EQ differs from last seen — restoring")
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
                guard let self, self.link != .usb else { return }
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
        compatibility = .checking
        receivingReports = false
        firmwareVersion = nil
        batteryPercent = nil
        charging = false
        sampleRate = nil
        inputSource = nil
        muted = false
        activePreset = nil
        presetNames = [:]
        usbFsMode = nil
        lastImportSummary = nil
        requestedNames = false
        pendingGroup = nil
        pendingEqMode = nil
        restoreDecided = false
        presetRead = false
        sawEqMode = false
        eqSourceName = nil
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
        dacFilterType = nil
        crossfeedLevel = nil
        eqGroup = .user
        assembler.group = .user
        assembler.reset()
        lastGroupSwitch = .distantPast   // don't let the rate limit defer the first real switch
        bands = QxEq.defaultFreqs.map { QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1.0) }
        preGain = 0
        eqEnabled = true
    }

    /// Whether a Bluetooth device is remembered, so the UI can offer to forget it.
    /// Published rather than computed: read straight from UserDefaults it never
    /// told SwiftUI to redraw, so the button stayed on screen after being used.
    @Published private(set) var hasPinnedBluetoothDevice = false

    /// Forget the remembered Bluetooth device and start looking again. Drops the
    /// current link if it is the Bluetooth one, so the next device can be adopted.
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
        DebugLog.shared.rx(cmdId, data)

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
            guard group == eqGroup.rawValue || data[0] == 129 else { return }
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
        guard end > 3 else { return }
        let nameBytes = data[3..<end].prefix { $0 != 0 }
        guard let raw = String(bytes: nameBytes, encoding: .utf8) else { return }
        let name = Self.displayName(raw)
        if !name.isEmpty { presetNames[idx] = name }
    }

    /// Longest preset name the popover will show. The device's own field is
    /// bounded by the report size; this is about the row staying one line.
    nonisolated static let maxPresetNameLength = 32

    /// Names are stored on the device, so they are attacker-supplied in the
    /// same sense every other field is. Control and format scalars are dropped
    /// rather than escaped — a U+202E override would visually reorder the rows
    /// around it, and a newline would stretch the row.
    nonisolated static func displayName(_ s: String) -> String {
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
        batteryAlerts.update(batteryPercent: batteryPercent, charging: charging)
        if let sr = state.sampleRateLabel, sr != sampleRate { sampleRate = sr }
        if let src = state.inputSourceLabel, src != inputSource { inputSource = src }
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
        if let f = state.dacFilterType, f != dacFilterType { dacFilterType = f }
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
        // Crossfeed is stored per preset, so it belongs to the group we left.
        crossfeedLevel = nil
        transportSend(.reqEqPreset, [group.requestMask])
        transportSend(.reqDevConfig, [0xC0])   // sys2 | eq → this group's cfg + name mask
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
        guard pendingGroup == nil else {
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

    /// Reports of the enable flag are ignored for this long after a local
    /// toggle. The device answers a toggle by broadcasting its config, and
    /// that broadcast can carry the PRE-change enable bit — one round trip
    /// behind — which snapped the switch straight back off. The user's click
    /// wins for the echo window; the next unsolicited report rules again.
    private var eqEnableEditUntil = Date.distantPast

    func setEqEnabled(_ on: Bool) {
        guard canWriteEq else { return }
        eqEnabled = on
        eqEnableEditUntil = Date().addingTimeInterval(1.5)
        transportSend(.setEqEnable, [eqGroup.rawValue, on ? 1 : 0])
        eqEdited()
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

    func loadPreset(_ index: Int) {
        guard canWriteEq, (0..<Self.presetCount).contains(index) else { return }
        eqSourceName = presetLabel(index)
        activePreset = index
        assembler.reset()
        transportSend(.loadEqPreset, [UInt8(index)])
        transportSend(.reqEqPreset, [eqGroup.requestMask])   // refresh band values
    }

    /// Display name for a preset slot, falling back to its number.
    func presetLabel(_ index: Int) -> String {
        presetNames[index] ?? "Preset \(index + 1)"
    }

    /// Reset every band to flat (0 dB, default frequencies) and clear pre-gain.
    func flatten() {
        guard canWriteEq else { return }
        eqSourceName = nil
        setPreGain(0)
        let defaults = eqGroup.defaultFreqs
        for i in 0..<bandCount {
            updateBand(i, QxEqBandValue(filter: .peak, freq: defaults[i], gain: 0, q: 1.0))
        }
        lastImportSummary = "Reset to flat"
    }

    func savePreset(_ index: Int) {
        guard canWriteEq, (0..<Self.presetCount).contains(index) else { return }
        transportSend(.saveEqPreset, [UInt8(index)])
    }

    func setPreGain(_ db: Double) {
        guard canWriteEq, db.isFinite else { return }
        let clamped = EQHeadroom.clamp(db)
        preGain = clamped
        sendEqParam(.setEqPreGain, band: 0, scaled: Int((clamped * QxScale.gain).rounded()))
        eqEdited()
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
    /// off the USB bus.
    func updateBand(_ index: Int, _ value: QxEqBandValue) {
        guard canWriteEq, bands.indices.contains(index), index < bandCount else { return }
        var v = value
        v.freq = max(20, min(20000, v.freq))
        v.gain = v.gain.isFinite ? max(-12, min(12, v.gain)) : 0
        v.q = v.q.isFinite ? max(0.1, min(10, v.q)) : 1.0
        bands[index] = v

        let payload: [UInt8] = [eqGroup.rawValue, eqGroup.writeChannelMask, UInt8(index), v.filter.rawValue]
            + QxPacket.int16BE(v.freq)
            + QxPacket.int16BE(Int((v.gain * QxScale.gain).rounded()))
            + QxPacket.int16BE(Int((v.q * QxScale.q).rounded()))
        transportSendCoalesced(.setEqBandParam, payload, key: "band\(index)")
        eqEdited()
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
        eqSourceName = name
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
        lastImportSummary = "Applied \(applied) band(s), pre-gain "
            + String(format: "%+.1f dB", file.preamp)
            + (dropped > 0 ? " · \(dropped) band(s) dropped"
                + (file.bands.count > bandCount && eqGroup != .b20
                   ? " (fit in 20-band mode)" : "") : "")
        DebugLog.shared.log("import: \(lastImportSummary ?? "")")
    }

    /// EQ files are a few hundred bytes; refuse anything absurd rather than
    /// reading an arbitrary user-picked file entirely into memory.
    static let maxImportBytes = 1_000_000

    func importFile(at url: URL) {
        do {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maxImportBytes else {
                lastImportSummary = "That file is too large to be an EQ preset."
                return
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                lastImportSummary = "Could not read \(url.lastPathComponent) as text."
                return
            }
            guard let parsed = ParametricEQFile.parse(text) else {
                lastImportSummary = "No filters found in \(url.lastPathComponent)"
                return
            }
            apply(parsed, named: url.deletingPathExtension().lastPathComponent)
        } catch {
            lastImportSummary = "Could not read file: \(error.localizedDescription)"
        }
    }

    /// Serialise the current bands in the same format we import.
    func exportText() -> String {
        var lines = [String(format: "Preamp: %.1f dB", preGain)]
        for (i, b) in bands.enumerated() {
            let token: String
            switch b.filter {
            case .peak: token = "PK"
            case .lowShelf: token = "LSC"
            case .highShelf: token = "HSC"
            case .lpf: token = "LPQ"
            case .hpf: token = "HPQ"
            case .bypass: continue
            }
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

    private func sendEqParam(_ cmd: QxCmd, band: Int, scaled: Int) {
        transportSendCoalesced(cmd,
                          [eqGroup.rawValue, eqGroup.writeChannelMask, UInt8(clamping: band)]
                            + QxPacket.int16BE(scaled),
                          key: "\(cmd)-\(band)")
    }
}
