#if os(Linux)
import Foundation
import Glibc

final class BluezTransport: QxLink {
    static let bus = "org.bluez"
    private static let adapterInterface = "org.bluez.Adapter1"
    private static let deviceInterface = "org.bluez.Device1"
    private static let characteristicInterface = "org.bluez.GattCharacteristic1"
    private static let bearerInterface = BluezLinkPlan.leBearerInterface
    private static let propertiesInterface = "org.freedesktop.DBus.Properties"
    private static let objectManagerInterface = "org.freedesktop.DBus.ObjectManager"

    private static let servicesResolvedTimeout: TimeInterval = BluezLinkPlan.characteristicsSeconds
    private static let connectTimeoutMs = Int32(BluezLinkPlan.connectCallSeconds * 1000)
    private static let minReconnectDelay: TimeInterval = 0.5
    private static let maxReconnectDelay: TimeInterval = 8
    private static let txErrorLimit = 5
    private static let writeSpacing: TimeInterval = 0.02
    private static let readPollTimeoutMilliseconds: Int32 = 200

    var kind: QxLinkKind { .bluetooth }

    var onConnected: ((String) -> Void)?
    var onDisconnected: (() -> Void)?
    var onLinkUnusable: ((String) -> Void)?
    var onLinkBusy: ((String) -> Void)?
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
    private var weConnectedBearer = false
    private var bringUpPending = false
    private var storedFailure: String?
    private var storedNeedsAttention = false
    private var discoveringAdapter: String?
    private var resolvedGate: DispatchSemaphore?
    private var announcedUnusable = false

    var failureReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure
    }

    var failureNeedsAttention: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedNeedsAttention
    }

    private func setFailure(_ reason: String?, needsAttention: Bool = false) {
        lock.lock()
        storedFailure = reason.map { BluezMask.text($0) }
        storedNeedsAttention = reason != nil && needsAttention
        lock.unlock()
    }

    private func log(_ text: String) {
        DebugLog.shared.log(BluezMask.text(text))
    }

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
        XDGDirectory.config()
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
        bringUpPending = false
        lock.unlock()
        queue.async { [weak self] in self?.bringUp() }
    }

    func stop() {
        stop(completion: nil)
    }

    func stopAndWait(timeout: TimeInterval) {
        let done = DispatchSemaphore(value: 0)
        stop(completion: { done.signal() })
        _ = done.wait(timeout: .now() + timeout)
    }

    private func stop(completion: (() -> Void)?) {
        lock.lock()
        stopping = true
        let gate = resolvedGate
        lock.unlock()
        gate?.signal()
        queue.async { [weak self] in
            defer { completion?() }
            guard let self else { return }
            self.stopDiscovery()
            let action = BluezLinkPlan.stopAction(calledBearerConnect: self.weConnectedBearer)
            let path = self.devicePath
            self.teardown(reason: "stopped", notify: false)
            if let path, action == .disconnectBearer {
                _ = try? self.connection?.call(destination: Self.bus, path: path,
                                               interface: Self.bearerInterface,
                                               method: "Disconnect",
                                               timeoutMs: 2_000)
            }
            self.connection?.stopSignalPump()
            self.connection = nil
            self.devicePath = nil
            self.weConnectedBearer = false
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
            log("BLE send dropped (not connected): \(cmd)")
            return
        }
        guard !tripped else { return }
        let frame = GaiaFraming.frame(currentVendor, cmd, data)
        if let reason = GaiaFraming.writeRefusal(frame: frame, budget: budget) {
            log("BLE send refused: \(cmd) is \(reason)")
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
            log("BLE write error \(String(cString: strerror(code))) cmd=\(cmd)"
                + (count >= Self.txErrorLimit ? " — suspending TX until the link comes back" : ""))
            if count == Self.txErrorLimit { onLinkUnusable?("Bluetooth writes keep failing (\(String(cString: strerror(code)))); the link is suspended until it comes back") }
        }
        Thread.sleep(forTimeInterval: Self.writeSpacing)
    }

    private func bringUp() {
        lock.lock()
        bringUpPending = false
        lock.unlock()
        if isStopping {
            stopDiscovery()
            return
        }
        guard !isConnected else { return }
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

        guard let candidate = Self.pickDevice(in: objects) else {
            log("BLE no Qudelix among BlueZ's known devices — watching for one")
            _ = startScan(in: objects, on: connection, reportFailure: true)
            return
        }
        devicePath = candidate
        deviceAlias = objects[candidate]?[Self.deviceInterface]?["Alias"]?.stringValue
            ?? objects[candidate]?[Self.deviceInterface]?["Name"]?.stringValue
            ?? "Qudelix 5K"
        let connectedNow = BluezLinkPlan.isConnected(candidate, in: objects)
        log("BLE picked \(deviceAlias) at \(candidate)"
            + (connectedNow ? " (already connected, e.g. for audio)" : " (not connected)"))

        guard let paths = establishLink(connection, device: candidate, connectedNow: connectedNow) else {
            scheduleReconnect()
            return
        }
        let commandPath = paths.command
        let responsePath = paths.response

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
            let detail = "the Bluetooth channels could not be opened (\(error))"
            setFailure(BluezLinkFailure.text(alias: deviceAlias, connectedForAudio: connectedNow,
                                             detail: detail), needsAttention: connectedNow)
            log("BLE cannot open the GAIA channels: \(error)")
            scheduleReconnect()
            return
        }

        stopDiscovery()
        setFailure(nil)
        startReader()
        log("BLE adopted GAIA link on \(candidate) "
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

    static func looksLikeQudelix(_ interfaces: [String: [String: DBusValue]]) -> Bool {
        BluezLinkPlan.looksLikeQudelix(interfaces)
    }

    private static func pickDevice(in objects: [String: [String: [String: DBusValue]]]) -> String? {
        BluezLinkPlan.pickDevice(in: objects, pinned: pinnedDevicePath())
    }

    private func establishLink(_ connection: DBusConnection, device: String,
                               connectedNow: Bool) -> (command: String, response: String)? {
        var scanned = false
        var objects: [String: [String: [String: DBusValue]]]
        do {
            objects = try connection.managedObjects(destination: Self.bus)
        } catch {
            log("BLE cannot list the device's characteristics: \(error)")
            return nil
        }

        func failWith(_ reason: String, needsAttention: Bool) -> (command: String, response: String)? {
            stopDiscovery()
            setFailure(reason, needsAttention: needsAttention)
            log("BLE \(reason)")
            return nil
        }

        func fail(_ detail: String) -> (command: String, response: String)? {
            failWith(BluezLinkFailure.text(alias: deviceAlias, connectedForAudio: connectedNow,
                                           detail: detail), needsAttention: connectedNow)
        }

        func awaitCharacteristics() -> (command: String, response: String)? {
            stopDiscovery()
            var found: (command: String, response: String)?
            let appeared = waitUntil(Self.servicesResolvedTimeout) {
                guard let latest = try? connection.managedObjects(destination: Self.bus),
                      let paths = BluezLinkPlan.characteristics(under: device, in: latest) else {
                    return false
                }
                found = paths
                return true
            }
            guard appeared, let found else {
                if isStopping { return nil }
                return fail("the GAIA command and response characteristics did not appear "
                    + "within \(Int(Self.servicesResolvedTimeout)) s")
            }
            log("BLE GAIA characteristics found under \(device)")
            return found
        }

        for _ in 0..<4 {
            if isStopping {
                stopDiscovery()
                return nil
            }
            let step = BluezLinkPlan.step(objects: objects, device: device, scanned: scanned)
            log("BLE link step for \(device): \(step)")
            switch step {
            case .useCharacteristics:
                stopDiscovery()
                if let paths = BluezLinkPlan.characteristics(under: device, in: objects) {
                    log("BLE GAIA characteristics already present under \(device)")
                    return paths
                }
                return fail("the GAIA characteristics vanished")
            case .awaitCharacteristics:
                return awaitCharacteristics()
            case .connectBearer:
                stopDiscovery()
                do {
                    _ = try connection.call(destination: Self.bus, path: device,
                                            interface: Self.bearerInterface, method: "Connect",
                                            timeoutMs: Self.connectTimeoutMs)
                    weConnectedBearer = true
                    log("BLE LE bearer connected on \(device)")
                } catch let error as DBusCallError where BluezLinkPlan.isBenign(error, "AlreadyConnected") {
                    log("BLE LE bearer was already connected on \(device)")
                } catch let error as DBusCallError where BluezLinkPlan.isBenign(error, "InProgress") {
                    log("BLE LE bearer connect already in progress on \(device)")
                } catch {
                    return fail("\(error)")
                }
                return awaitCharacteristics()
            case .scanForLE:
                scanned = true
                switch startScan(in: objects, on: connection, reportFailure: false) {
                case .failed(let detail):
                    return fail(detail)
                case .started, .alreadyRunning:
                    break
                }
                let isLEReady = waitUntil(BluezLinkPlan.scanSeconds) {
                    guard let latest = try? connection.managedObjects(destination: Self.bus) else {
                        return false
                    }
                    objects = latest
                    if BluezLinkPlan.bearerState(of: device, in: latest) != .unknown { return true }
                    return BluezLinkPlan.characteristics(under: device, in: latest) != nil
                }
                log("BLE scan ended on \(device): " + (isLEReady ? "LE side seen" : "nothing seen"))
                stopDiscovery()
                if let latest = try? connection.managedObjects(destination: Self.bus) { objects = latest }
            case .connectDevice:
                stopDiscovery()
                do {
                    _ = try connection.call(destination: Self.bus, path: device,
                                            interface: Self.deviceInterface, method: "Connect",
                                            timeoutMs: Self.connectTimeoutMs)
                    log("BLE Device1.Connect returned for \(device)")
                } catch let error as DBusCallError
                            where BluezLinkPlan.isBenign(error, "AlreadyConnected", "InProgress") {
                    log("BLE Device1.Connect answered \(error.name) for \(device)")
                } catch {
                    return fail("\(error)")
                }
                return awaitCharacteristics()
            case .notConnected:
                return failWith(BluezLinkFailure.notConnected(alias: deviceAlias), needsAttention: false)
            }
        }
        return fail("the link steps did not converge")
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

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let gate = DispatchSemaphore(value: 0)
        lock.lock()
        resolvedGate = gate
        lock.unlock()
        defer {
            lock.lock()
            resolvedGate = nil
            lock.unlock()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !isStopping {
            if condition() { return true }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            _ = gate.wait(timeout: .now() + min(1, remaining))
        }
        return false
    }

    private enum ScanStart {
        case started
        case alreadyRunning
        case failed(String)
    }

    private func startScan(in objects: [String: [String: [String: DBusValue]]],
                           on connection: DBusConnection, reportFailure: Bool) -> ScanStart {
        guard discoveringAdapter == nil else { return .alreadyRunning }
        guard let adapter = objects.keys.sorted().first(where: {
            objects[$0]?[Self.adapterInterface] != nil
        }) else {
            let text = "No Bluetooth adapter is present, so there is nothing to scan with."
            if reportFailure { reportUnusable(text) }
            return .failed(text)
        }
        do {
            _ = try connection.call(destination: Self.bus, path: adapter,
                                    interface: Self.adapterInterface,
                                    method: "SetDiscoveryFilter",
                                    arguments: [.dictionary([("Transport", .string("le"))])])
        } catch {
            log("BLE adapter \(adapter) refused a low-energy scan filter "
                + "(\(error)); scanning without one")
        }
        do {
            _ = try connection.call(destination: Self.bus, path: adapter,
                                    interface: Self.adapterInterface, method: "StartDiscovery")
            discoveringAdapter = adapter
            log("BLE scan started on \(adapter)")
            return .started
        } catch let error as DBusCallError where error.name.hasSuffix("InProgress") {
            log("BLE a scan is already running on \(adapter)")
            return .alreadyRunning
        } catch {
            let text = "The Bluetooth adapter would not start a low-energy scan (\(error)). "
                + "This adapter may not support Bluetooth LE; use the USB link."
            if reportFailure { reportUnusable(text) }
            return .failed(text)
        }
    }

    private func stopDiscovery() {
        guard let adapter = discoveringAdapter, let connection else { return }
        discoveringAdapter = nil
        _ = try? connection.call(destination: Self.bus, path: adapter,
                                 interface: Self.adapterInterface, method: "StopDiscovery")
        log("BLE scan stopped on \(adapter)")
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
                log("BLE ignored \(ignoredFrames) undecodable frame(s); latest: "
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
            log("BLE vendor \(currentVendor.label) rejected the command (status \(status))")
            if let fallback {
                log("BLE retrying as vendor \(fallback.label)")
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
            log("BLE pinned \(path) for future sessions")
        }
        onPacket?(packet)
    }

    private func handle(_ signal: DBusSignal) {
        switch signal.member {
        case "PropertiesChanged":
            guard signal.arguments.count >= 2,
                  signal.arguments[0].stringValue == Self.deviceInterface,
                  let changed = signal.arguments[1].dictionaryValue else { return }
            guard signal.path == devicePath else {
                guard devicePath == nil, !isConnected,
                      BluezLinkPlan.looksLikeQudelix(properties: changed) else { return }
                requestBringUp()
                return
            }
            lock.lock()
            let gate = resolvedGate
            lock.unlock()
            gate?.signal()
            if changed["Connected"]?.boolValue == false {
                queue.async { [weak self] in
                    guard let self else { return }
                    self.teardown(reason: "the device disconnected", notify: true)
                    self.scheduleReconnect()
                }
            }
        case "InterfacesAdded":
            guard signal.arguments.count >= 2 else { return }
            if let added = signal.arguments[0].stringValue, let path = devicePath,
               added == path || added.hasPrefix(path + "/") {
                lock.lock()
                let gate = resolvedGate
                lock.unlock()
                gate?.signal()
                return
            }
            guard devicePath == nil, !isConnected,
                  let interfaces = signal.arguments[1].dictionaryValue,
                  let device = interfaces[Self.deviceInterface]?.dictionaryValue,
                  BluezLinkPlan.looksLikeQudelix(properties: device) else { return }
            requestBringUp()
        default:
            return
        }
    }

    private func requestBringUp() {
        lock.lock()
        let alreadyQueued = bringUpPending || stopping
        bringUpPending = true
        lock.unlock()
        guard !alreadyQueued else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if self.reconnectScheduled {
                self.lock.lock()
                self.bringUpPending = false
                self.lock.unlock()
                return
            }
            self.bringUp()
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
        weConnectedBearer = false
        if orphanedNotify >= 0 { close(orphanedNotify) }
        if writeDescriptor >= 0 { close(writeDescriptor) }
        if wasUp {
            log("BLE link torn down (\(reason))")
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
        log("BLE reconnecting in \(String(format: "%.1f", delay))s")
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
            log(message)
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
