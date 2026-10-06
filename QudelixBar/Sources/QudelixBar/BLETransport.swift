import Foundation
import CoreBluetooth

struct AttemptLogGate {
    private var last: String?

    mutating func shouldLog(_ key: String) -> Bool {
        guard last != key else { return false }
        last = key
        return true
    }

    mutating func reset() { last = nil }
}

final class BLETransport: NSObject {
    static let gaiaService = CBUUID(string: "00001100-D102-11E1-9B23-00025B00A5A5")
    static let gaiaCommand = CBUUID(string: "00001101-D102-11E1-9B23-00025B00A5A5")
    static let gaiaResponse = CBUUID(string: "00001102-D102-11E1-9B23-00025B00A5A5")

    enum Vendor: UInt16, CaseIterable {
        case qudelix = 0xF001
        case qudelixMk2 = 0xF003

        var label: String { String(format: "0x%04X", rawValue) }
    }

    private var central: CBCentralManager!
    private var lastReportedState: CBManagerState?
    private var peripheral: CBPeripheral?
    private var loggedPeripherals = Set<UUID>()
    private var attemptLog = AttemptLogGate()
    private var othersSeen = 0
    private var ignoredFrames = 0
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

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

    static func frame(_ vendor: Vendor, _ cmd: QxCmd, _ data: [UInt8]) -> [UInt8] {
        [UInt8(vendor.rawValue >> 8), UInt8(vendor.rawValue & 0xFF)]
            + QxPacket.payload(cmd, data)
    }

    static func decode(_ raw: [UInt8], expecting vendor: Vendor) -> (packet: [UInt8], status: UInt8)? {
        guard raw.count >= 5 else { return nil }
        let seen = UInt16(raw[0]) << 8 | UInt16(raw[1])
        guard seen == vendor.rawValue else { return nil }
        let status = raw[4]
        let payload = Array(raw[5...])
        guard payload.count + 2 <= 0xFF else { return nil }
        let packet = [UInt8(payload.count + 2), raw[2] & 0x7F, raw[3]] + payload
        return (packet, status)
    }

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
        let budget = p.maximumWriteValueLength(for: .withoutResponse)
        if let reason = Self.writeRefusal(frame: frame, budget: budget) {
            DebugLog.shared.log("BLE send refused: \(cmd) is \(reason)")
            return
        }
        DebugLog.shared.tx(cmd, data)
        p.writeValue(Data(frame), for: c, type: type)
    }

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

    func clearPending() { pending = [:] }

    private static let pinnedKey = "BLEPinnedPeripheral"

    private var pinnedIdentifier: UUID? {
        get { UserDefaults.standard.string(forKey: Self.pinnedKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.pinnedKey) }
    }

    var hasPinnedDevice: Bool { pinnedIdentifier != nil }

    var pinnedIdentity: String? { pinnedIdentifier?.uuidString }

    private var shunned: (id: UUID, until: Date)?
    private static let shunWindow: TimeInterval = 60

    func disconnectAndRescan() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        connectTimeout?.cancel()
        teardown(reason: "forget device")
        reconnectDelay = 0.5
        consecutiveConnectFailures = 0
        scheduleScan()
    }

    func forgetPinnedDevice() {
        attemptLog.reset()
        if let id = peripheral?.identifier ?? pinnedIdentifier {
            shunned = (id, Date().addingTimeInterval(Self.shunWindow))
        }
        UserDefaults.standard.removeObject(forKey: Self.pinnedKey)
        DebugLog.shared.log("BLE pinned device cleared; giving another device "
            + "\(Int(Self.shunWindow))s of priority")
    }

    private func isAdoptable(_ p: CBPeripheral, advertisedName: String? = nil) -> Bool {
        if let s = shunned {
            if Date() >= s.until { shunned = nil }
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
        attemptLog.reset()
        DebugLog.shared.log("BLE discovery \(suspended ? "suspended" : "resumed")")
        if suspended {
            scanBurstEnd?.cancel()
            scanBurstEnd = nil
            central?.stopScan()
            releasePendingConnect()
        } else if mayScanNow {
            beginScan()
        }
    }

    private var mayScanNow: Bool {
        Self.mayScan(suspended: scanSuspended,
                     poweredOn: central?.state == .poweredOn,
                     linked: peripheral != nil)
    }

    private func logAttempt(_ key: String, _ message: String) {
        if attemptLog.shouldLog(key) { DebugLog.shared.log(message) }
    }

    nonisolated static func staysPending(failures: Int, state: CBPeripheralState) -> Bool {
        state == .connecting && failures >= failuresBeforeAbsent
    }

    private func releasePendingConnect() {
        guard let pending = peripheral, !isConnected, pending.state == .connecting else { return }
        connectTimeout?.cancel()
        central?.cancelPeripheralConnection(pending)
        teardown(reason: "discovery suspended")
    }

    private func beginScan() {
        guard mayScanNow else { return }
        loggedPeripherals.removeAll()
        if let pinned = pinnedIdentifier,
           let known = central.retrievePeripherals(withIdentifiers: [pinned]).first {
            logAttempt("pinned", "BLE reconnecting to pinned device")
            adopt(known)
            return
        }
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.gaiaService])
        if let p = connected.first(where: { isAdoptable($0) }) {
            DebugLog.shared.log("BLE found system-connected: \(p.name ?? "?")")
            adopt(p)
            return
        }
        logAttempt("scan", "BLE scanning…")
        central.scanForPeripherals(withServices: nil, options: nil)
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

    private var reconnectDelay: TimeInterval = 0.5
    private static let maxReconnectDelay: TimeInterval = 8
    private static let connectTimeoutSeconds: TimeInterval = 10
    private static let scanBurstSeconds: TimeInterval = 10
    private static let scanRestSeconds: TimeInterval = 50

    private static let absentReconnectDelay: TimeInterval = 60
    static let failuresBeforeAbsent = 3

    private var lastRejectLog = Date.distantPast
    private var suppressedRejects = 0
    private var connectTimeout: DispatchWorkItem?
    private var scanBurstEnd: DispatchWorkItem?
    private var scanScheduled = false
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
        armConnectTimeout()
    }

    private func armConnectTimeout() {
        connectTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.peripheral, !self.isConnected else { return }
            self.consecutiveConnectFailures += 1
            let failures = self.consecutiveConnectFailures
            if Self.staysPending(failures: failures, state: pending.state) {
                if failures == Self.failuresBeforeAbsent {
                    DebugLog.shared.log("BLE device not answering — leaving the "
                                        + "connection pending until it returns")
                }
                return
            }
            if failures == Self.failuresBeforeAbsent {
                DebugLog.shared.log("BLE device not answering — backing off to "
                                    + "\(Int(Self.absentReconnectDelay))s retries")
            } else if failures < Self.failuresBeforeAbsent {
                DebugLog.shared.log("BLE connect timed out — cancelling and retrying")
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
        if central.state != lastReportedState {
            lastReportedState = central.state
            attemptLog.reset()
        }
        guard central.state == .poweredOn else {
            teardown(reason: "adapter state \(central.state.rawValue)")
            return
        }
        beginScan()
    }

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
            attemptLog.reset()
            DebugLog.shared.log("BLE link torn down (\(reason))")
            onDisconnected?()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let advServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []

        if loggedPeripherals.insert(p.identifier).inserted {
            othersSeen += 1
            if othersSeen % 25 == 0 {
                DebugLog.shared.log("BLE scanning: \(othersSeen) other peripherals ignored")
            }
        }

        guard isAdoptable(p, advertisedName: name) else { return }
        guard advServices.isEmpty || advServices.contains(Self.gaiaService) else { return }
        DebugLog.shared.log("BLE candidate: \(name) rssi=\(RSSI)")
        adopt(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        DebugLog.shared.log("BLE connected: \(p.name ?? "?") — discovering services")
        armConnectTimeout()
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
        if error != nil { consecutiveConnectFailures += 1 }
        teardown(reason: "peer disconnected")
        scheduleScan()
    }

    private func isCurrent(_ p: CBPeripheral) -> Bool {
        guard let current = peripheral else { return false }
        return p.identifier == current.identifier
    }
}

extension BLETransport: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard isCurrent(p) else { return }
        guard let services = p.services else { return }
        for s in services {
            DebugLog.shared.log("BLE service: \(s.uuid)")
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isCurrent(p) else { return }
        guard let chars = service.characteristics else { return }
        for c in chars {
            DebugLog.shared.log("BLE char: \(service.uuid) / \(c.uuid) props=\(describe(c.properties))")
        }
        guard service.uuid == Self.gaiaService else { return }
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
            attemptLog.reset()
            reconnectDelay = 0.5
            consecutiveConnectFailures = 0
            DebugLog.shared.log("BLE adopted GAIA link: tx=\(w.uuid) rx=\(n.uuid)")
            onConnected?(p.name ?? "Qudelix 5K")
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        DebugLog.shared.log("BLE notify \(c.uuid): \(error.map { "error \($0.localizedDescription)" } ?? (c.isNotifying ? "on" : "off"))")
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard isCurrent(p), c.uuid == Self.gaiaResponse else { return }
        guard error == nil, let data = c.value else { return }
        let raw = [UInt8](data)
        guard let (packet, status) = Self.decode(raw, expecting: vendor) else {
            ignoredFrames += 1
            if ignoredFrames == 1 || ignoredFrames % 50 == 0 {
                DebugLog.shared.log("BLE ignored \(ignoredFrames) undecodable frame(s); latest: "
                    + raw.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " "))
            }
            return
        }
        guard status == 0 else {
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
