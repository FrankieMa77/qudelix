#if os(Linux)
import Foundation
import Glibc

final class BluezTransport: QxLink {
    private static let bus = "org.bluez"
    private static let adapterInterface = "org.bluez.Adapter1"
    private static let deviceInterface = "org.bluez.Device1"
    private static let characteristicInterface = "org.bluez.GattCharacteristic1"
    private static let propertiesInterface = "org.freedesktop.DBus.Properties"
    private static let objectManagerInterface = "org.freedesktop.DBus.ObjectManager"

    private static let servicesResolvedTimeout: TimeInterval = 15
    private static let minReconnectDelay: TimeInterval = 0.5
    private static let maxReconnectDelay: TimeInterval = 8
    private static let txErrorLimit = 5
    private static let writeSpacing: TimeInterval = 0.02
    private static let readPollTimeoutMilliseconds: Int32 = 200

    var kind: QxLinkKind { .bluetooth }

    var onConnected: ((String) -> Void)?
    var onDisconnected: (() -> Void)?
    var onLinkUnusable: ((String) -> Void)?
    var onPacket: (([UInt8]) -> Void)?

    private let queue = DispatchQueue(label: "qudelix.bluez")
    private let lock = NSLock()

    private var connection: DBusConnection?
    private var storedDevicePath: String?
    private var storedDeviceAlias = "Qudelix 5K"
    private var notifyFD: Int32 = -1
    private var writeFD: Int32 = -1
    private var writeBudget = 20
    private var notifyBudget = 512
    private var generation = 0
    private var readerGeneration: Int?
    private var vendor = GaiaFraming.Vendor.qudelix
    private var triedFallbackVendor = false
    private var sawGoodReply = false
    private var consecutiveTxErrors = 0
    private var ignoredFrames = 0
    private var reconnectDelay = BluezTransport.minReconnectDelay
    private var reconnectScheduled = false
    private var stopping = false
    private var weInitiatedConnection = false
    private var discoveringAdapter: String?
    private var resolvedGate: DispatchSemaphore?
    private var announcedUnusable = false

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return notifyFD >= 0 && writeFD >= 0
    }

    private var devicePath: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedDevicePath
        }
        set {
            lock.lock()
            storedDevicePath = newValue
            lock.unlock()
        }
    }

    private var deviceAlias: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedDeviceAlias
        }
        set {
            lock.lock()
            storedDeviceAlias = newValue
            lock.unlock()
        }
    }

    static var pinnedDeviceFile: URL {
        let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        return configHome
            .appendingPathComponent("qudelix", isDirectory: true)
            .appendingPathComponent("ble-device")
    }

    static func pinnedDevicePath() -> String? {
        guard let text = try? String(contentsOf: pinnedDeviceFile, encoding: .utf8) else { return nil }
        let line = text.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.hasPrefix("/") ? line : nil
    }

    static func forgetPinnedDevice() {
        try? FileManager.default.removeItem(at: pinnedDeviceFile)
        DebugLog.shared.log("BLE pinned device cleared")
    }

    private static func pinDevice(_ path: String) {
        let file = pinnedDeviceFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? (path + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    func start() {
        lock.lock()
        stopping = false
        lock.unlock()
        queue.async { [weak self] in self?.bringUp() }
    }

    func stop() {
        lock.lock()
        stopping = true
        let gate = resolvedGate
        lock.unlock()
        gate?.signal()
        queue.async { [weak self] in
            guard let self else { return }
            self.stopDiscovery()
            let initiated = self.weInitiatedConnection
            let path = self.devicePath
            self.teardown(reason: "stopped", notify: false)
            if initiated, let path {
                _ = try? self.connection?.call(destination: Self.bus, path: path,
                                               interface: Self.deviceInterface,
                                               method: "Disconnect")
            }
            self.connection?.stopSignalPump()
            self.connection = nil
            self.devicePath = nil
            self.weInitiatedConnection = false
        }
    }

    func send(_ cmd: QxCmd, _ data: [UInt8]) {
        queue.async { [weak self] in self?.sendNow(cmd, data) }
    }

    private func sendNow(_ cmd: QxCmd, _ data: [UInt8]) {
        lock.lock()
        let fd = writeFD
        let budget = writeBudget
        let currentVendor = vendor
        let tripped = consecutiveTxErrors >= Self.txErrorLimit
        lock.unlock()
        guard fd >= 0 else {
            DebugLog.shared.log("BLE send dropped (not connected): \(cmd)")
            return
        }
        guard !tripped else { return }
        let frame = GaiaFraming.frame(currentVendor, cmd, data)
        if let reason = GaiaFraming.writeRefusal(frame: frame, budget: budget) {
            DebugLog.shared.log("BLE send refused: \(cmd) is \(reason)")
            return
        }
        DebugLog.shared.tx(cmd, data)
        let written = frame.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return write(fd, base, buffer.count)
        }
        if written == frame.count {
            lock.lock()
            consecutiveTxErrors = 0
            lock.unlock()
        } else {
            let code = errno
            lock.lock()
            consecutiveTxErrors += 1
            let count = consecutiveTxErrors
            lock.unlock()
            DebugLog.shared.log("BLE write error \(String(cString: strerror(code))) cmd=\(cmd)"
                + (count >= Self.txErrorLimit ? " — suspending TX until the link comes back" : ""))
            if count == Self.txErrorLimit { onLinkUnusable?("Bluetooth writes keep failing (\(String(cString: strerror(code)))); the link is suspended until it comes back") }
        }
        Thread.sleep(forTimeInterval: Self.writeSpacing)
    }

    private func bringUp() {
        guard !isStopping, !isConnected else { return }
        let connection: DBusConnection
        do {
            connection = try openConnection()
        } catch {
            reportUnusable("Bluetooth is unavailable: \(error)")
            return
        }

        let objects: [String: [String: [String: DBusValue]]]
        do {
            objects = try connection.managedObjects(destination: Self.bus)
        } catch {
            reportUnusable("Bluetooth is unavailable: BlueZ is not answering on the system bus "
                + "(\(error)). Install and start bluetoothd, or use the USB link.")
            return
        }

        guard let candidate = pickDevice(in: objects) else {
            DebugLog.shared.log("BLE no Qudelix among BlueZ's known devices — watching for one")
            beginDiscovery(in: objects, on: connection)
            return
        }
        devicePath = candidate
        deviceAlias = objects[candidate]?[Self.deviceInterface]?["Alias"]?.stringValue
            ?? objects[candidate]?[Self.deviceInterface]?["Name"]?.stringValue
            ?? "Qudelix 5K"

        let alreadyConnected = objects[candidate]?[Self.deviceInterface]?["Connected"]?.boolValue ?? false
        if !alreadyConnected {
            do {
                weInitiatedConnection = true
                _ = try connection.call(destination: Self.bus, path: candidate,
                                        interface: Self.deviceInterface, method: "Connect",
                                        timeoutMs: 30_000)
            } catch {
                weInitiatedConnection = false
                DebugLog.shared.log("BLE connect to \(deviceAlias) failed: \(error)")
                scheduleReconnect()
                return
            }
        }

        guard waitForServicesResolved(connection, path: candidate) else {
            DebugLog.shared.log("BLE \(deviceAlias) is connected but its control service has not "
                + "appeared: BlueZ reported no ServicesResolved within "
                + "\(Int(Self.servicesResolvedTimeout))s. If the headset is paired as audio only, "
                + "reconnect it or use the USB link.")
            scheduleReconnect()
            return
        }

        let resolved: [String: [String: [String: DBusValue]]]
        do {
            resolved = try connection.managedObjects(destination: Self.bus)
        } catch {
            DebugLog.shared.log("BLE cannot list the device's characteristics: \(error)")
            scheduleReconnect()
            return
        }
        guard let commandPath = characteristic(GaiaFraming.commandUUID, under: candidate, in: resolved),
              let responsePath = characteristic(GaiaFraming.responseUUID, under: candidate, in: resolved) else {
            DebugLog.shared.log("BLE \(deviceAlias) does not expose the GAIA command and response "
                + "characteristics; nothing to talk to over Bluetooth")
            scheduleReconnect()
            return
        }

        do {
            let notify = try acquire("AcquireNotify", path: responsePath, on: connection)
            let write: (fd: Int32, mtu: UInt16)
            do {
                write = try acquire("AcquireWrite", path: commandPath, on: connection)
            } catch {
                close(notify.fd)
                throw error
            }
            lock.lock()
            notifyFD = notify.fd
            writeFD = write.fd
            notifyBudget = max(Int(notify.mtu), 23)
            writeBudget = max(Int(write.mtu), 20)
            vendor = .qudelix
            triedFallbackVendor = false
            sawGoodReply = false
            consecutiveTxErrors = 0
            reconnectDelay = Self.minReconnectDelay
            announcedUnusable = false
            lock.unlock()
        } catch {
            DebugLog.shared.log("BLE cannot open the GAIA channels: \(error)")
            scheduleReconnect()
            return
        }

        stopDiscovery()
        startReader()
        DebugLog.shared.log("BLE adopted GAIA link on \(candidate) "
            + "(write budget \(writeBudget) bytes)")
        onConnected?(deviceAlias)
    }

    private func openConnection() throws -> DBusConnection {
        if let connection { return connection }
        let connection = try DBusConnection()
        connection.onSignal { [weak self] signal in self?.handle(signal) }
        try? connection.addMatch("type='signal',sender='\(Self.bus)',"
            + "interface='\(Self.propertiesInterface)',member='PropertiesChanged'")
        try? connection.addMatch("type='signal',sender='\(Self.bus)',"
            + "interface='\(Self.objectManagerInterface)',member='InterfacesAdded'")
        connection.startSignalPump()
        self.connection = connection
        return connection
    }

    private func pickDevice(in objects: [String: [String: [String: DBusValue]]]) -> String? {
        let matches = objects.filter { _, interfaces in
            guard let device = interfaces[Self.deviceInterface] else { return false }
            let uuids = (device["UUIDs"]?.stringArray ?? []).map { $0.lowercased() }
            return uuids.contains(GaiaFraming.serviceUUID)
        }
        guard !matches.isEmpty else { return nil }
        if let pinned = Self.pinnedDevicePath(), matches[pinned] != nil { return pinned }
        let sorted = matches.keys.sorted()
        if let paired = sorted.first(where: {
            matches[$0]?[Self.deviceInterface]?["Paired"]?.boolValue == true
        }) {
            return paired
        }
        return sorted.first
    }

    private func characteristic(_ uuid: String, under device: String,
                                in objects: [String: [String: [String: DBusValue]]]) -> String? {
        objects.keys.sorted().first { path in
            guard path.hasPrefix(device + "/"),
                  let props = objects[path]?[Self.characteristicInterface] else { return false }
            return props["UUID"]?.stringValue?.lowercased() == uuid
        }
    }

    private func acquire(_ method: String, path: String,
                         on connection: DBusConnection) throws -> (fd: Int32, mtu: UInt16) {
        let reply = try connection.call(destination: Self.bus, path: path,
                                        interface: Self.characteristicInterface,
                                        method: method,
                                        arguments: [.dictionary([])])
        let fields = reply.count >= 2 ? reply : (reply.first?.items ?? [])
        let harvested = Self.descriptors(in: reply)
        guard fields.count >= 2, let fd = fields[0].fdValue, fd >= 0,
              let mtu = fields[1].uint16Value else {
            for descriptor in harvested { close(descriptor) }
            throw DBusCallError(name: "", message: "\(method) returned no usable descriptor")
        }
        for descriptor in harvested where descriptor != fd { close(descriptor) }
        return (fd, mtu)
    }

    private static func descriptors(in values: [DBusValue]) -> [Int32] {
        values.flatMap { value -> [Int32] in
            let inner = value.unwrapped
            if case .unixFD(let descriptor) = inner { return descriptor >= 0 ? [descriptor] : [] }
            if case .dictEntry(let key, let element) = inner { return descriptors(in: [key, element]) }
            return descriptors(in: inner.items ?? [])
        }
    }

    private func waitForServicesResolved(_ connection: DBusConnection, path: String) -> Bool {
        if (try? connection.property(destination: Self.bus, path: path,
                                     interface: Self.deviceInterface,
                                     name: "ServicesResolved"))??.boolValue == true {
            return true
        }
        let gate = DispatchSemaphore(value: 0)
        lock.lock()
        resolvedGate = gate
        lock.unlock()
        defer {
            lock.lock()
            resolvedGate = nil
            lock.unlock()
        }
        let deadline = Date().addingTimeInterval(Self.servicesResolvedTimeout)
        while Date() < deadline {
            if gate.wait(timeout: .now() + 1) == .success, !isStopping {
                if (try? connection.property(destination: Self.bus, path: path,
                                             interface: Self.deviceInterface,
                                             name: "ServicesResolved"))??.boolValue == true {
                    return true
                }
            }
            if isStopping { return false }
        }
        return false
    }

    private func beginDiscovery(in objects: [String: [String: [String: DBusValue]]],
                                on connection: DBusConnection) {
        guard discoveringAdapter == nil else { return }
        guard let adapter = objects.keys.sorted().first(where: {
            objects[$0]?[Self.adapterInterface] != nil
        }) else {
            reportUnusable("No Bluetooth adapter is present, so there is nothing to scan with.")
            return
        }
        do {
            _ = try connection.call(destination: Self.bus, path: adapter,
                                    interface: Self.adapterInterface,
                                    method: "SetDiscoveryFilter",
                                    arguments: [.dictionary([("Transport", .string("le"))])])
        } catch {
            DebugLog.shared.log("BLE adapter \(adapter) refused a low-energy scan filter "
                + "(\(error)); scanning without one")
        }
        do {
            _ = try connection.call(destination: Self.bus, path: adapter,
                                    interface: Self.adapterInterface, method: "StartDiscovery")
            discoveringAdapter = adapter
            DebugLog.shared.log("BLE scanning on \(adapter)")
        } catch {
            reportUnusable("The Bluetooth adapter would not start a low-energy scan (\(error)). "
                + "This adapter may not support Bluetooth LE; use the USB link.")
        }
    }

    private func stopDiscovery() {
        guard let adapter = discoveringAdapter, let connection else { return }
        discoveringAdapter = nil
        _ = try? connection.call(destination: Self.bus, path: adapter,
                                 interface: Self.adapterInterface, method: "StopDiscovery")
    }

    private func startReader() {
        lock.lock()
        generation += 1
        let gen = generation
        let descriptor = notifyFD
        let capacity = max(notifyBudget, 64)
        readerGeneration = descriptor >= 0 ? gen : nil
        lock.unlock()
        guard descriptor >= 0 else { return }
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: capacity)
            var reason = "the device closed the channel"
            loop: while true {
                guard let self, self.readerShouldContinue(gen) else {
                    reason = ""
                    break loop
                }
                var descriptors = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = Glibc.poll(&descriptors, 1, Self.readPollTimeoutMilliseconds)
                if ready < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    reason = String(cString: strerror(errno))
                    break loop
                }
                if ready == 0 { continue }
                let count = buffer.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Glibc.read(descriptor, base, raw.count)
                }
                if count > 0 {
                    self.deliver(Array(buffer[0..<count]), generation: gen)
                } else if count == 0 {
                    break loop
                } else if errno == EINTR || errno == EAGAIN {
                    continue
                } else {
                    reason = String(cString: strerror(errno))
                    break loop
                }
            }
            close(descriptor)
            let ended = reason
            self?.queue.async { [weak self] in self?.readerFinished(gen, reason: ended) }
        }
        thread.name = "qudelix.bluez.rx"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private func readerShouldContinue(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == gen
    }

    private func readerFinished(_ gen: Int, reason: String) {
        lock.lock()
        if readerGeneration == gen { readerGeneration = nil }
        let live = generation == gen
        lock.unlock()
        guard live else { return }
        teardown(reason: reason, notify: true)
        scheduleReconnect()
    }

    private func deliver(_ raw: [UInt8], generation gen: Int) {
        lock.lock()
        let stale = generation != gen
        let currentVendor = vendor
        lock.unlock()
        guard !stale else { return }
        guard let (packet, status) = GaiaFraming.decode(raw, expecting: currentVendor) else {
            ignoredFrames += 1
            if ignoredFrames == 1 || ignoredFrames % 50 == 0 {
                DebugLog.shared.log("BLE ignored \(ignoredFrames) undecodable frame(s); latest: "
                    + raw.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " "))
            }
            return
        }
        guard status == 0 else {
            lock.lock()
            let good = sawGoodReply
            let tried = triedFallbackVendor
            var fallback: GaiaFraming.Vendor?
            if !good, !tried, let other = GaiaFraming.Vendor.allCases.first(where: { $0 != currentVendor }) {
                triedFallbackVendor = true
                vendor = other
                fallback = other
            }
            lock.unlock()
            DebugLog.shared.log("BLE vendor \(currentVendor.label) rejected the command (status \(status))")
            if let fallback {
                DebugLog.shared.log("BLE retrying as vendor \(fallback.label)")
                onConnected?(deviceAlias)
            }
            return
        }
        lock.lock()
        let firstGoodReply = !sawGoodReply
        sawGoodReply = true
        lock.unlock()
        if firstGoodReply, let path = devicePath {
            Self.pinDevice(path)
            DebugLog.shared.log("BLE pinned \(path) for future sessions")
        }
        onPacket?(packet)
    }

    private func handle(_ signal: DBusSignal) {
        switch signal.member {
        case "PropertiesChanged":
            guard signal.arguments.count >= 2,
                  signal.arguments[0].stringValue == Self.deviceInterface,
                  signal.path == devicePath,
                  let changed = signal.arguments[1].dictionaryValue else { return }
            if changed["ServicesResolved"]?.boolValue == true {
                lock.lock()
                let gate = resolvedGate
                lock.unlock()
                gate?.signal()
            }
            if changed["Connected"]?.boolValue == false {
                queue.async { [weak self] in
                    guard let self else { return }
                    self.teardown(reason: "the device disconnected", notify: true)
                    self.scheduleReconnect()
                }
            }
        case "InterfacesAdded":
            guard devicePath == nil, !isConnected,
                  signal.arguments.count >= 2,
                  let interfaces = signal.arguments[1].dictionaryValue,
                  let device = interfaces[Self.deviceInterface]?.dictionaryValue else { return }
            let uuids = (device["UUIDs"]?.stringArray ?? []).map { $0.lowercased() }
            guard uuids.contains(GaiaFraming.serviceUUID) else { return }
            queue.async { [weak self] in self?.bringUp() }
        default:
            return
        }
    }

    private func teardown(reason: String, notify: Bool) {
        lock.lock()
        let wasUp = notifyFD >= 0 && writeFD >= 0
        generation += 1
        let orphanedNotify = readerGeneration == nil ? notifyFD : -1
        let writeDescriptor = writeFD
        notifyFD = -1
        writeFD = -1
        vendor = .qudelix
        triedFallbackVendor = false
        sawGoodReply = false
        consecutiveTxErrors = 0
        lock.unlock()
        if orphanedNotify >= 0 { close(orphanedNotify) }
        if writeDescriptor >= 0 { close(writeDescriptor) }
        if wasUp {
            DebugLog.shared.log("BLE link torn down (\(reason))")
            if notify { onDisconnected?() }
        }
    }

    private func scheduleReconnect() {
        guard !isStopping, !reconnectScheduled else { return }
        reconnectScheduled = true
        lock.lock()
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, Self.maxReconnectDelay)
        lock.unlock()
        DebugLog.shared.log("BLE reconnecting in \(String(format: "%.1f", delay))s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.reconnectScheduled = false
            self.bringUp()
        }
    }

    private func reportUnusable(_ message: String) {
        lock.lock()
        let firstAnnouncement = !announcedUnusable
        announcedUnusable = true
        lock.unlock()
        if firstAnnouncement {
            DebugLog.shared.log(message)
            onLinkUnusable?(message)
        }
        scheduleReconnect()
    }

    var reconnectBackoff: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return reconnectDelay
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }
}
#endif
