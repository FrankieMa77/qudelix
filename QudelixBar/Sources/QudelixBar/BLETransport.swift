import Foundation
import CoreBluetooth

/// BLE transport for the Qudelix 5K.
///
/// The device's BLE endpoint carries the same `[cmd, data…]` packets the USB HID
/// path sends, behind a 16-bit vendor field:
///
///     TX  [vendor][cmdHi cmdLo][data…]                    -> characteristic 1101
///     RX  [vendor][cmd|0x8000][status][payload…]           <- characteristic 1102
///
/// A reply carries the *response* command id, so ReqInitData (0x0100) is answered
/// by RspInitData (0x0101) with the high bit set, and its payload is byte-for-byte
/// what USB delivers after the length and command bytes. That is why everything
/// above the transport is shared between the two links.
///
/// Adoption is deliberately narrow: one known service, only its command and
/// response characteristics, and only when those characteristics really carry the
/// properties their UUIDs imply. Since every byte of a BLE advertisement is chosen
/// by the advertiser, the first device to complete a link is pinned by identifier
/// and nothing else is adopted afterwards — see `pinnedIdentifier`.
final class BLETransport: NSObject {
    /// Qualcomm GAIA v2/v3 service + endpoints.
    static let gaiaService = CBUUID(string: "00001100-D102-11E1-9B23-00025B00A5A5")
    static let gaiaCommand = CBUUID(string: "00001101-D102-11E1-9B23-00025B00A5A5")
    static let gaiaResponse = CBUUID(string: "00001102-D102-11E1-9B23-00025B00A5A5")

    /// The vendor field. A closed enum on purpose — do not add cases.
    ///
    /// Some of this device's command ids coincide with destructive commands in the
    /// underlying chip protocol, which are reachable only under a different vendor
    /// value. Making that value unrepresentable means no later edit can turn a
    /// routine setting into a reset.
    enum Vendor: UInt16, CaseIterable {
        /// The original 5K. Verified against firmware 3.1.8 and 3.2.7.
        case qudelix = 0xF001
        /// The other generation. Untested: a 5K rejects it.
        case qudelixMk2 = 0xF003

        var label: String { String(format: "0x%04X", rawValue) }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var loggedPeripherals = Set<UUID>()
    private var othersSeen = 0
    private var ignoredFrames = 0
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    /// Which vendor id we are framing with. Starts on the 5K's and falls back
    /// once if the device rejects it, so an mk2 is not left unreachable.
    private(set) var vendor: Vendor = .qudelix
    private var triedFallbackVendor = false
    private var sawGoodReply = false

    var onConnected: ((String) -> Void)?
    var onDisconnected: (() -> Void)?
    var onPacket: (([UInt8]) -> Void)?

    var isConnected: Bool { writeChar != nil && notifyChar != nil }

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// GAIA frame for one Qudelix command. The vendor can only ever be one of
    /// `Vendor`, so this cannot address GAIA's built-in command handlers.
    static func frame(_ vendor: Vendor, _ cmd: QxCmd, _ data: [UInt8]) -> [UInt8] {
        [UInt8(vendor.rawValue >> 8), UInt8(vendor.rawValue & 0xFF)]
            + QxPacket.payload(cmd, data)
    }

    /// Turn a GAIA reply into the `[len, cmdHi, cmdLo, payload…]` shape the rest
    /// of the app already parses, so nothing downstream needs to know about BLE.
    /// Returns nil for frames that are not ours, or that carry a failure status.
    static func decode(_ raw: [UInt8], expecting vendor: Vendor) -> (packet: [UInt8], status: UInt8)? {
        guard raw.count >= 5 else { return nil }
        let seen = UInt16(raw[0]) << 8 | UInt16(raw[1])
        guard seen == vendor.rawValue else { return nil }
        let status = raw[4]
        let payload = Array(raw[5...])
        // The length byte is what `QxPacket.parseRx` uses to bound the payload;
        // a frame longer than it can express would be silently truncated there.
        guard payload.count + 2 <= 0xFF else { return nil }
        let packet = [UInt8(payload.count + 2), raw[2] & 0x7F, raw[3]] + payload
        return (packet, status)
    }

    /// Why a frame may not go out, or nil if it fits. Refusal, never a trim:
    /// the only command that can reach this size is the preset name, whose
    /// header declares the length of the name that follows — a body cut short
    /// under a header that still claims the original length is precisely how a
    /// stored field ends up corrupt. Better a name that was never written.
    static func writeRefusal(frame: [UInt8], budget: Int) -> String? {
        guard frame.count > budget else { return nil }
        return "\(frame.count) bytes, over the \(budget)-byte single-write budget"
    }

    func send(_ cmd: QxCmd, _ data: [UInt8] = []) {
        guard let p = peripheral, let c = writeChar else {
            DebugLog.shared.log("BLE send dropped (not connected): \(cmd)")
            return
        }
        let type: CBCharacteristicWriteType =
            c.properties.contains(.write) ? .withResponse : .withoutResponse
        let frame = Self.frame(vendor, cmd, data)
        // Every command here bar one fits a single ATT write with room to
        // spare; naming a preset slot is the one that can run to 36 bytes,
        // which at an unnegotiated 23-byte MTU is nearly twice the 20 bytes a
        // packet can carry. Measured against the without-response budget for
        // either write type on purpose: that number is the negotiated MTU less
        // ATT overhead, so it is what actually fits in one packet. A larger
        // with-response write would be split into a queued (prepare/execute)
        // write instead, a path nothing in this app needs and no 5K has been
        // seen to answer.
        let budget = p.maximumWriteValueLength(for: .withoutResponse)
        if let reason = Self.writeRefusal(frame: frame, budget: budget) {
            DebugLog.shared.log("BLE send refused: \(cmd) is \(reason)")
            return
        }
        DebugLog.shared.tx(cmd, data)
        p.writeValue(Data(frame), for: c, type: type)
    }

    /// Latest-value-wins queue, same idea as the USB path: a slider drag emits
    /// ~60 updates a second and only the newest is worth sending. BLE writes are
    /// far cheaper than the USB path's 20 ms, so the window is short.
    private var pending: [String: (QxCmd, [UInt8])] = [:]
    private var flushScheduled = false
    private static let coalesceWindow = 0.03

    func sendCoalesced(_ cmd: QxCmd, _ data: [UInt8], key: String) {
        pending[key] = (cmd, data)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceWindow) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            let batch = self.pending
            self.pending = [:]
            for (_, item) in batch { self.send(item.0, item.1) }
        }
    }

    func flushPending() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = [:]
        for (_, item) in batch { send(item.0, item.1) }
    }

    /// Drop anything queued but not yet flushed. Used when the controller moves
    /// to the other transport, so a stale write cannot arrive afterwards.
    func clearPending() { pending = [:] }

    /// Identifier of the peripheral this app has already linked with.
    ///
    /// Trust on first use. A BLE advertisement is entirely attacker-controlled:
    /// the local name is a free-form string, and the GAIA service UUID is a
    /// generic Qualcomm identifier that many unrelated devices expose, so
    /// "named Qudelix, speaks GAIA" is not an identity. Once a link has been
    /// established the peripheral's identifier is remembered, and from then on
    /// nothing else is adopted — a spoofer has to win the very first
    /// connection, not merely be in radio range later.
    private static let pinnedKey = "BLEPinnedPeripheral"

    private var pinnedIdentifier: UUID? {
        get { UserDefaults.standard.string(forKey: Self.pinnedKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.pinnedKey) }
    }

    var hasPinnedDevice: Bool { pinnedIdentifier != nil }

    /// The remembered peripheral, for tagging saved state with the device it
    /// came from. Read-only; adoption is the only thing that sets it.
    var pinnedIdentity: String? { pinnedIdentifier?.uuidString }

    /// A device the user just asked us to forget, held back briefly so it cannot
    /// immediately re-pin itself.
    ///
    /// `cancelPeripheralConnection` only drops *our* connection; the 5K normally
    /// stays connected to the system as an audio device, so
    /// `retrieveConnectedPeripherals` hands it straight back — ahead of any
    /// advertisement — and with the pin gone it would be adopted and re-pinned.
    /// Pressing Forget repeatedly could never escape that. The exclusion expires
    /// so that forgetting the only 5K in the room doesn't disable Bluetooth
    /// until relaunch: a different device gets first refusal, and if none turns
    /// up we go back to the original.
    private var shunned: (id: UUID, until: Date)?
    private static let shunWindow: TimeInterval = 60

    /// Drop the current link and go back to scanning, so a newly-unpinned device
    /// can be replaced by another one without relaunching.
    func disconnectAndRescan() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        connectTimeout?.cancel()
        teardown(reason: "forget device")
        reconnectDelay = 0.5
        consecutiveConnectFailures = 0
        // Deliberately scheduled rather than immediate. Scanning straight away
        // re-adopts the peripheral we just cancelled — it is still connected at
        // the system level — and the cancellation's disconnect callback then
        // arrives and tears the fresh link down again. Letting the backoff run
        // gives the cancellation time to land first.
        scheduleScan()
    }

    /// Forget the pinned device, so the next adoptable one becomes the new pin.
    func forgetPinnedDevice() {
        if let id = peripheral?.identifier ?? pinnedIdentifier {
            shunned = (id, Date().addingTimeInterval(Self.shunWindow))
        }
        UserDefaults.standard.removeObject(forKey: Self.pinnedKey)
        DebugLog.shared.log("BLE pinned device cleared; giving another device "
            + "\(Int(Self.shunWindow))s of priority")
    }

    /// Whether this peripheral may be adopted at all. Once pinned, identity is
    /// the only question; before that, the name is a filter and the real check
    /// happens against the GATT database in `didDiscoverCharacteristicsFor`.
    private func isAdoptable(_ p: CBPeripheral, advertisedName: String? = nil) -> Bool {
        if let s = shunned {
            if Date() >= s.until { shunned = nil }            // exclusion expired
            else if p.identifier == s.id { return false }
        }
        if let pinned = pinnedIdentifier { return p.identifier == pinned }
        let name = advertisedName ?? p.name ?? ""
        return name.localizedCaseInsensitiveContains("qudelix")
    }

    nonisolated static func mayScan(suspended: Bool, poweredOn: Bool,
                                    linked: Bool) -> Bool {
        !suspended && poweredOn && !linked
    }

    private(set) var scanSuspended = false

    func setScanSuspended(_ suspended: Bool) {
        guard suspended != scanSuspended else { return }
        scanSuspended = suspended
        DebugLog.shared.log("BLE discovery \(suspended ? "suspended" : "resumed")")
        if suspended {
            scanBurstEnd?.cancel()
            scanBurstEnd = nil
            central?.stopScan()
        } else if mayScanNow {
            beginScan()
        }
    }

    private var mayScanNow: Bool {
        Self.mayScan(suspended: scanSuspended,
                     poweredOn: central?.state == .poweredOn,
                     linked: peripheral != nil)
    }

    private func beginScan() {
        guard mayScanNow else { return }
        DebugLog.shared.log("BLE scanning…")
        // Devices that rotate their random address yield a fresh identifier each
        // time, so this set would grow without bound across a long scan.
        loggedPeripherals.removeAll()
        // A known device can be reconnected by identifier without scanning, and
        // without any name matching being involved.
        if let pinned = pinnedIdentifier,
           let known = central.retrievePeripherals(withIdentifiers: [pinned]).first {
            DebugLog.shared.log("BLE reconnecting to pinned device")
            adopt(known)
            return
        }
        // The 5K may already be connected at the system level — check first.
        // `withServices:` matches on the generic GAIA UUID, which any Qualcomm
        // audio device may expose, so the candidate still has to be adoptable.
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.gaiaService])
        if let p = connected.first(where: { isAdoptable($0) }) {
            DebugLog.shared.log("BLE found system-connected: \(p.name ?? "?")")
            adopt(p)
            return
        }
        central.scanForPeripherals(withServices: nil, options: nil)
        // Duty-cycle the unfiltered scan: continuous discovery is this
        // app's single biggest idle energy cost, and a 5K that isn't in
        // range now is rarely in range one second later. Bursts of 10 s
        // scanning, then 50 s of radio quiet — worst-case pickup latency
        // rises to a minute, which a menu bar companion can afford. The
        // pinned-reconnect path above never reaches this (it connects by
        // identifier without scanning).
        scanBurstEnd?.cancel()
        let pause = DispatchWorkItem { [weak self] in
            guard let self, self.peripheral == nil else { return }
            self.central.stopScan()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanRestSeconds) { [weak self] in
                guard let self, self.mayScanNow else { return }
                self.beginScan()
            }
        }
        scanBurstEnd = pause
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanBurstSeconds,
                                      execute: pause)
    }

    /// Backoff between reconnect attempts, and a ceiling on a pending connect.
    ///
    /// `central.connect` never times out on its own, so a pinned device that is
    /// switched off left the app in a permanently pending connect that never
    /// fell back to scanning. And retrying with no delay let a peripheral that
    /// accepts then immediately drops the link spin us as fast as the radio
    /// allows, each cycle costing a fresh handshake burst upstream.
    private var reconnectDelay: TimeInterval = 0.5
    private static let maxReconnectDelay: TimeInterval = 8
    private static let connectTimeoutSeconds: TimeInterval = 10
    private static let scanBurstSeconds: TimeInterval = 10
    private static let scanRestSeconds: TimeInterval = 50

    /// Where the backoff settles once the pinned device has stopped answering
    /// altogether, and how many failures it takes to decide that.
    ///
    /// A remembered device is reconnected by identifier, which skips the
    /// duty-cycled scan below and so skips the energy budget that goes with it.
    /// That is right for a device that blinked — the first retries should be
    /// quick. It is wrong for one that is switched off or out of range, where
    /// the 8 s ceiling meant a connection attempt every 18 s for as long as the
    /// app stayed open, indefinitely, and made the cheap path three times more
    /// expensive than the expensive one. Once the device has clearly gone, the
    /// delay converges on the same worst-case pickup latency the scan
    /// duty-cycle already accepts.
    private static let absentReconnectDelay: TimeInterval = 60
    private static let failuresBeforeAbsent = 3

    private var lastRejectLog = Date.distantPast
    private var suppressedRejects = 0
    private var connectTimeout: DispatchWorkItem?
    private var scanBurstEnd: DispatchWorkItem?
    private var scanScheduled = false
    /// Consecutive connect attempts that ended in a timeout. Reset by any link
    /// that comes up, so one good connection restores the fast retries.
    private var consecutiveConnectFailures = 0

    private func scheduleScan() {
        guard !scanScheduled else { return }
        scanScheduled = true
        let delay = reconnectDelay
        let ceiling = consecutiveConnectFailures >= Self.failuresBeforeAbsent
            ? Self.absentReconnectDelay : Self.maxReconnectDelay
        reconnectDelay = min(reconnectDelay * 2, ceiling)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.scanScheduled = false
            guard self.mayScanNow else { return }
            self.beginScan()
        }
    }

    private func adopt(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        central.stopScan()
        central.connect(p, options: nil)

        connectTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.peripheral, !self.isConnected else { return }
            self.consecutiveConnectFailures += 1
            // Logged once at the transition rather than on every attempt: this
            // line was 3,000 entries of the diagnostics buffer, which pushed out
            // everything anyone would actually want to read there.
            if self.consecutiveConnectFailures == Self.failuresBeforeAbsent {
                DebugLog.shared.log("BLE device not answering — backing off to "
                                    + "\(Int(Self.absentReconnectDelay))s retries")
            } else if self.consecutiveConnectFailures < Self.failuresBeforeAbsent {
                DebugLog.shared.log("BLE connect timed out — cancelling and rescanning")
            }
            self.central.cancelPeripheralConnection(pending)
            self.teardown(reason: "connect timeout")
            self.scheduleScan()
        }
        connectTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeoutSeconds, execute: work)
    }
}

extension BLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DebugLog.shared.log("BLE state: \(central.state.rawValue)")
        guard central.state == .poweredOn else {
            // Turning Bluetooth off does not reliably deliver a disconnect, so
            // without this the characteristics stay non-nil, `isConnected` keeps
            // answering true, every send goes nowhere, and the re-adoption guard
            // (`writeChar == nil`) then refuses to reconnect when it comes back.
            teardown(reason: "adapter state \(central.state.rawValue)")
            return
        }
        beginScan()
    }

    /// Drop everything tied to a live link. Safe to call when already down.
    private func teardown(reason: String) {
        let wasUp = isConnected
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        pending = [:]
        vendor = .qudelix
        triedFallbackVendor = false
        sawGoodReply = false
        if wasUp {
            DebugLog.shared.log("BLE link torn down (\(reason))")
            onDisconnected?()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let advServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []

        // Deliberately does NOT log every peripheral it sees. A scan picks up the
        // names of neighbours' televisions, thermometers and headphones, and this
        // log is what users attach to bug reports — so only devices that pass the
        // name filter are ever named here. The rest are counted, which is all
        // that is needed to tell "scanning works" from "nothing in range".
        if loggedPeripherals.insert(p.identifier).inserted {
            othersSeen += 1
            if othersSeen % 25 == 0 {
                DebugLog.shared.log("BLE scanning: \(othersSeen) other peripherals ignored")
            }
        }

        // Everything here is advertiser-controlled, so this is a filter to
        // decide what is worth connecting to — never a decision that the
        // peripheral is genuine. That comes from the GATT database below, and
        // from the pin once one exists. A device that advertises no service
        // UUIDs at all is still worth probing, since the 5K may not list them.
        guard isAdoptable(p, advertisedName: name) else { return }
        guard advServices.isEmpty || advServices.contains(Self.gaiaService) else { return }
        DebugLog.shared.log("BLE candidate: \(name) rssi=\(RSSI)")
        adopt(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        DebugLog.shared.log("BLE connected: \(p.name ?? "?") — discovering services")
        p.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard isCurrent(p) else { return }
        DebugLog.shared.log("BLE connect failed: \(error?.localizedDescription ?? "?")")
        connectTimeout?.cancel()
        teardown(reason: "connect failed")
        scheduleScan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard isCurrent(p) else { return }
        DebugLog.shared.log("BLE disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        connectTimeout?.cancel()
        // A link that came up and then dropped on its own is a failure too.
        // Only the connect *timeout* used to count, so a peripheral that
        // accepted and immediately dropped reset the backoff every cycle and
        // spun at the floor delay forever — the exact flap the backoff exists
        // to stop. A disconnect we asked for carries no error and is left out.
        if error != nil { consecutiveConnectFailures += 1 }
        // `teardown` also restarts each link on the 5K's vendor id. Latching the
        // fallback for the life of the process meant one rejected frame — which
        // any peripheral can send — left every later session framed for hardware
        // we are not talking to, with no way back short of relaunching.
        teardown(reason: "peer disconnected")
        scheduleScan()
    }

    /// Ignore delegate callbacks for a peripheral we are no longer tracking; a
    /// late callback for a stale one would otherwise tear down the live link.
    private func isCurrent(_ p: CBPeripheral) -> Bool {
        guard let current = peripheral else { return false }
        return p.identifier == current.identifier
    }
}

extension BLETransport: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        // Pinned like every other callback. Discovery can land after the
        // connect timeout has already torn this peripheral down and adopted
        // another, and installing a dropped peripheral's characteristics
        // against the live one leaves a link that reports connected and
        // carries nothing.
        guard isCurrent(p) else { return }
        guard let services = p.services else { return }
        for s in services {
            DebugLog.shared.log("BLE service: \(s.uuid)")
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // Pinned like every other callback. Discovery can land after the
        // connect timeout has already torn this peripheral down and adopted
        // another, and installing a dropped peripheral's characteristics
        // against the live one leaves a link that reports connected and
        // carries nothing.
        guard isCurrent(p) else { return }
        guard let chars = service.characteristics else { return }
        for c in chars {
            DebugLog.shared.log("BLE char: \(service.uuid) / \(c.uuid) props=\(describe(c.properties))")
        }
        // Only the GAIA service. Adopting "any service with a writable and a
        // notifying characteristic" would send this protocol to whatever
        // unrelated endpoint happened to match.
        guard service.uuid == Self.gaiaService else { return }
        // The UUID says what a characteristic claims to be; the properties say
        // what it can actually do. Requiring both means a peripheral that
        // merely mirrors the GAIA UUIDs back at us doesn't get adopted.
        let writable = chars.first {
            $0.uuid == Self.gaiaCommand
                && !$0.properties.intersection([.write, .writeWithoutResponse]).isEmpty
        }
        let notifying = chars.first {
            $0.uuid == Self.gaiaResponse
                && !$0.properties.intersection([.notify, .indicate]).isEmpty
        }
        if let w = writable, let n = notifying, writeChar == nil {
            writeChar = w
            notifyChar = n
            p.setNotifyValue(true, for: n)
            // CoreBluetooth pairs only when the peripheral demands encryption,
            // and nothing here can force it. Worth recording which link we got:
            // an unencrypted one is readable by anyone in range.
            let encrypted = n.properties
                .intersection([.notifyEncryptionRequired, .indicateEncryptionRequired])
            if encrypted.isEmpty {
                DebugLog.shared.log("BLE link: the peripheral does not declare encryption "
                                    + "as required. This is its own claim about its "
                                    + "characteristics, not an observation of the link — "
                                    + "CoreBluetooth exposes no way to check.")
            }
            if pinnedIdentifier == nil {
                pinnedIdentifier = p.identifier
                if shunned?.id != p.identifier { shunned = nil }
                DebugLog.shared.log("BLE pinned this device for future sessions")
            }
            connectTimeout?.cancel()
            reconnectDelay = 0.5           // a good link earns a fast retry next time
            consecutiveConnectFailures = 0
            DebugLog.shared.log("BLE adopted GAIA link: tx=\(w.uuid) rx=\(n.uuid)")
            onConnected?(p.name ?? "Qudelix 5K")
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        DebugLog.shared.log("BLE notify \(c.uuid): \(error.map { "error \($0.localizedDescription)" } ?? (c.isNotifying ? "on" : "off"))")
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        // ATT permits a server to notify any handle regardless of what we
        // subscribed to, so pin the source: our peripheral, our response
        // characteristic. Otherwise a peripheral could feed protocol frames in
        // through any characteristic it happens to expose.
        guard isCurrent(p), c.uuid == Self.gaiaResponse else { return }
        guard error == nil, let data = c.value else { return }
        let raw = [UInt8](data)
        guard let (packet, status) = Self.decode(raw, expecting: vendor) else {
            // One line per frame would let a notification flood rotate the
            // user's real diagnostics out of the log.
            ignoredFrames += 1
            if ignoredFrames == 1 || ignoredFrames % 50 == 0 {
                DebugLog.shared.log("BLE ignored \(ignoredFrames) undecodable frame(s); latest: "
                    + raw.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " "))
            }
            return
        }
        guard status == 0 else {
            // Status 1 is NOT_SUPPORTED. Before any successful exchange that
            // most likely means the wrong vendor id for this hardware, so try
            // the other one once rather than sitting mute.
            // Throttled, and deliberately not gated on which link owns the
            // device: a pinned peripheral can send these while the user is on
            // USB, and one line per frame evicts the whole diagnostics log —
            // which is the thing people attach to bug reports. The undecodable
            // path next to it is already rate limited for the same reason.
            let now = Date()
            if now.timeIntervalSince(lastRejectLog) > 2 {
                lastRejectLog = now
                let extra = suppressedRejects > 0 ? " (\(suppressedRejects) more suppressed)" : ""
                DebugLog.shared.log("BLE vendor \(vendor.label) rejected the command "
                                    + "(status \(status))\(extra)")
                suppressedRejects = 0
            } else {
                suppressedRejects += 1
            }
            if !sawGoodReply, !triedFallbackVendor,
               let other = Vendor.allCases.first(where: { $0 != vendor }) {
                triedFallbackVendor = true
                vendor = other
                DebugLog.shared.log("BLE retrying as vendor \(other.label)")
                onConnected?(peripheral?.name ?? "Qudelix 5K")
            }
            return
        }
        sawGoodReply = true
        onPacket?(packet)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let e = error { DebugLog.shared.log("BLE write error: \(e.localizedDescription)") }
    }

    private func describe(_ props: CBCharacteristicProperties) -> String {
        var out: [String] = []
        if props.contains(.read) { out.append("read") }
        if props.contains(.write) { out.append("write") }
        if props.contains(.writeWithoutResponse) { out.append("writeNR") }
        if props.contains(.notify) { out.append("notify") }
        if props.contains(.indicate) { out.append("indicate") }
        return out.joined(separator: ",")
    }
}
