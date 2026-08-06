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

    // EQ
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
        lastImportSummary = nil
        requestedNames = false
        pendingGroup = nil
        pendingEqMode = nil
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
            case 130: if data.count >= 3 { eqEnabled = data[2] != 0 }       // eqEnable
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
        // Consume eq_mode like the other user-changeable fields below:
        // `state` is cumulative, and re-running setEqGroup on every packet
        // would let any stale notification resolve a mode switch that is
        // still waiting on its real confirmation.
        if let mode = state.eqMode {
            setEqGroup(mode == 1 ? .b20 : .user)
            state.eqMode = nil
        }
        if let fw = state.fwVersion { firmwareVersion = fw }
        if let b = state.batteryPercent { batteryPercent = b }
        charging = state.charging
        batteryAlerts.update(batteryPercent: batteryPercent, charging: charging)
        if let sr = state.sampleRateLabel { sampleRate = sr }
        if let src = state.inputSourceLabel { inputSource = src }
        if let m = state.usbMute { muted = m }
        // EQ group config only applies when it describes the group we're
        // targeting: in 20-band mode the block carries the b20 group, and
        // reading the 10-band group's preset index / name mask against it
        // highlights the wrong slot and fetches the wrong names.
        let eqCfgApplies = state.eqCfgGroup == Int(eqGroup.rawValue)
        if let en = state.eqEnabled, eqCfgApplies { eqEnabled = en }
        if let idx = state.eqPresetIdx, eqCfgApplies { setActivePreset(idx) }
        volumeMax = state.dacOutPwr2Vrms ? min(state.volumeLimitDb ?? 6, 6)
                                         : min(state.volumeLimitDb ?? 0, 0)
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

        let compat: String
        switch compatibility {
        case .checking: compat = "checking"
        case .ok: compat = "ok"
        case .unsupported(let t, _): compat = "UNSUPPORTED(\(t))"
        }
        DebugLog.shared.log("compat=\(compat) model=\(state.deviceId) eqMode=\(state.eqMode.map(String.init) ?? "?")")
        DebugLog.shared.log("state: fw=\(firmwareVersion ?? "?") batt=\(batteryPercent.map { "\($0)%" } ?? "?")"
            + " vol=\(String(format: "%.1fdB", volumeDb))"
            + " max=\(String(format: "%.0f", volumeMax)) sr=\(sampleRate ?? "?") src=\(inputSource ?? "?")"
            + " eq=\(eqEnabled ? "on" : "off") preset=\(activePreset.map(String.init) ?? "?")"
            + " nameMask=\(String(state.presetNameMask, radix: 2))")

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
            return
        }
        // `looksPlausible` is deliberately wider than the editor's range, so a
        // real device reporting a curve we can't represent still shows up
        // instead of being discarded. Clamp it to what the sliders can express
        // and what `updateBand` would write back, so the displayed and exported
        // curve is one we could actually reproduce.
        preGain = min(max(p.preGain, -12), 12)
        bands = p.bands.map { band in
            var v = band
            v.freq = max(20, min(20000, v.freq))
            v.gain = v.gain.isFinite ? max(-12, min(12, v.gain)) : 0
            v.q = v.q.isFinite ? max(0.1, min(10, v.q)) : 1.0
            return v
        }
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
        // The active-slot highlight belongs to the group we just left; the
        // config re-request below refreshes it for this group.
        activePreset = nil
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

    func setEqEnabled(_ on: Bool) {
        guard canWriteEq else { return }
        eqEnabled = on
        transportSend(.setEqEnable, [eqGroup.rawValue, on ? 1 : 0])
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
        let clamped = max(-12, min(12, db))
        preGain = clamped
        sendEqParam(.setEqPreGain, band: 0, scaled: Int((clamped * QxScale.gain).rounded()))
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

        let payload: [UInt8] = [eqGroup.rawValue, QxEq.chMaskBoth, UInt8(index), v.filter.rawValue]
            + QxPacket.int16BE(v.freq)
            + QxPacket.int16BE(Int((v.gain * QxScale.gain).rounded()))
            + QxPacket.int16BE(Int((v.q * QxScale.q).rounded()))
        transportSendCoalesced(.setEqBandParam, payload, key: "band\(index)")
    }

    // MARK: - Preset import / export

    /// Push a parsed parametric-EQ file to the device: pre-gain, then every
    /// band, then any unused bands bypassed so leftovers from the previous
    /// preset can't linger.
    func apply(_ file: ParametricEQFile) {
        guard canWriteEq else {
            lastImportSummary = "Not applied — this device isn't supported."
            return
        }
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
        lastImportSummary = "Applied \(file.bands.count) band(s), pre-gain "
            + String(format: "%+.1f dB", file.preamp)
            + (file.droppedBands > 0 ? " · \(file.droppedBands) extra band(s) dropped" : "")
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
            apply(parsed)
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
                          [eqGroup.rawValue, QxEq.chMaskBoth, UInt8(clamping: band)]
                            + QxPacket.int16BE(scaled),
                          key: "\(cmd)-\(band)")
    }
}
