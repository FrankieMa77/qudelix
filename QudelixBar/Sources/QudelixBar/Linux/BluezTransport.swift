#if os(Linux)
import Foundation
import Glibc

final class BluezTransport: QxLink {
    static let bus = "org.bluez"
    private static let deviceInterface = "org.bluez.Device1"
    private static let characteristicInterface = "org.bluez.GattCharacteristic1"

    private static let minReconnectDelay: TimeInterval = 0.5
    private static let maxReconnectDelay: TimeInterval = 8
    private static let txErrorLimit = 5
    private static let writeSpacing: TimeInterval = 0.02
    private static let readPollTimeoutMilliseconds: Int32 = 200
    private static let connectTickMilliseconds: Int32 = 500
    private static let writeCallTimeoutMs: Int32 = 5_000
    private static let waitLogInterval: TimeInterval = 60

    static let armedPause: TimeInterval = 0.1
    static let relistSeconds: TimeInterval = 300
    static let noDeviceRetryDelay: TimeInterval = 3

    static let armedFailureCodes: Set<Int32> = [ECONNREFUSED, ENOSYS, EHOSTDOWN, ETIMEDOUT, EBUSY,
                                                ECONNRESET, ECONNABORTED, EHOSTUNREACH, EINTR]

    static func isArmedFailure(_ code: Int32) -> Bool {
        armedFailureCodes.contains(code)
    }

    private enum Mode {
        case none
        case le
        case bluez
    }

    var kind: QxLinkKind { .bluetooth }

    var onConnected: ((String) -> Void)?
    var onDisconnected: (() -> Void)?
    var onLinkUnusable: ((String) -> Void)?
    var onLinkBusy: ((String) -> Void)?
    var onPacket: (([UInt8]) -> Void)?

    private let queue = DispatchQueue(label: "qudelix.bluez")
    private let lock = NSLock()
    private let sessionLock = NSLock()

    private let makeBus: () throws -> BluezBus
    private let makeSocket: () -> LEAttSocket
    private let pinnedPath: () -> String?
    private let savePin: (String) -> Void
    private let armedDelay: TimeInterval
    private let relistInterval: TimeInterval
    private let noDeviceDelay: TimeInterval
    private let uptime: () -> TimeInterval

    private var bus: BluezBus?
    private var storedDevicePath: String?
    private var storedDeviceAlias = "Qudelix 5K"
    private var mode = Mode.none
    private var up = false
    private var socket: LEAttSocket?
    private var session = LEGaiaSession()
    private var linkUpAt: TimeInterval = 0
    private var notifyFD = -1 as Int32
    private var commandPath: String?
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
    private var linkStale = false
    private var lastDrop: BluezDrop?
    private var bringUpPending = false
    private var storedFailure: String?
    private var storedNeedsAttention = false
    private var announcedUnusable = false
    private var lastWaitLog: Date?
    private var announcedNoDevice = false
    private var armTarget: ArmTarget?
    private var lastListing: TimeInterval = 0
    private var relistRequested = false

    private struct ArmTarget {
        let device: String
        let address: String
        let addressType: String?
    }

    private enum Attempt {
        case connected
        case failed
        case fatal
        case relist
    }

    init(bus: @escaping () throws -> BluezBus = { try SystemBluezBus() },
         socket: @escaping () -> LEAttSocket = { LEAttSystemSocket() },
         pinnedPath: @escaping () -> String? = { BluezTransport.pinnedDevicePath() },
         savePin: @escaping (String) -> Void = { BluezTransport.pinDevice($0) },
         armedDelay: TimeInterval = BluezTransport.armedPause,
         relistInterval: TimeInterval = BluezTransport.relistSeconds,
         noDeviceDelay: TimeInterval = BluezTransport.noDeviceRetryDelay,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        makeBus = bus
        makeSocket = socket
        self.pinnedPath = pinnedPath
        self.savePin = savePin
        self.armedDelay = armedDelay
        self.relistInterval = relistInterval
        self.noDeviceDelay = noDeviceDelay
        self.uptime = uptime
    }

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
        Trace.log(BluezMask.text(text))
    }

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return up
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

    static func pinDevice(_ path: String) {
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
        lastDrop = nil
        lock.unlock()
        queue.async { [weak self] in
            defer { completion?() }
            guard let self else { return }
            self.teardown(reason: "stopped", notify: false)
            self.bus?.close()
            self.bus = nil
            self.devicePath = nil
        }
    }

    func send(_ cmd: QxCmd, _ data: [UInt8]) {
        queue.async { [weak self] in self?.sendNow(cmd, data) }
    }

    private func sendNow(_ cmd: QxCmd, _ data: [UInt8]) {
        lock.lock()
        let current = mode
        let isUp = up
        let budget = writeBudget
        let currentVendor = vendor
        let tripped = consecutiveTxErrors >= Self.txErrorLimit
        let gen = generation
        let path = commandPath
        lock.unlock()
        guard isUp, current != .none else {
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
        switch current {
        case .le:
            drive(gen) { session, now in session.send(frame, now: now) }
        case .bluez:
            writeThroughBlueZ(frame, to: path, cmd: cmd)
        case .none:
            return
        }
    }

    private func writeThroughBlueZ(_ frame: [UInt8], to path: String?, cmd: QxCmd) {
        guard let path, let bus else { return }
        let value = DBusValue.array(element: "y", items: frame.map { .byte($0) })
        let options = DBusValue.dictionary([("type", .string("request"))])
        do {
            _ = try bus.call(path: path, interface: Self.characteristicInterface,
                             method: "WriteValue", arguments: [value, options],
                             timeoutMs: Self.writeCallTimeoutMs)
            lock.lock()
            consecutiveTxErrors = 0
            lock.unlock()
        } catch {
            recordTxError("\(error)", cmd: cmd)
        }
        Thread.sleep(forTimeInterval: Self.writeSpacing)
    }

    private func recordTxError(_ detail: String, cmd: QxCmd?) {
        lock.lock()
        consecutiveTxErrors += 1
        let count = consecutiveTxErrors
        lock.unlock()
        log("BLE write error \(detail)" + (cmd.map { " cmd=\($0)" } ?? "")
            + (count >= Self.txErrorLimit ? " — suspending TX until the link comes back" : ""))
        if count == Self.txErrorLimit {
            onLinkUnusable?("Bluetooth writes keep failing (\(detail)); the link is suspended until it comes back")
        }
    }

    private func bringUp() {
        lock.lock()
        bringUpPending = false
        lock.unlock()
        guard !isStopping, !isConnected else { return }
        let bus: BluezBus
        do {
            bus = try openBus()
        } catch {
            reportUnusable("Bluetooth is unavailable: \(error)")
            return
        }

        let objects: BluezLinkPlan.Objects
        let listingStarted = Date()
        armTarget = nil
        do {
            objects = try bus.managedObjects()
            lock.lock()
            relistRequested = false
            lock.unlock()
            lastListing = uptime()
            let listingSeconds = Date().timeIntervalSince(listingStarted)
            if listingSeconds > 1 {
                log(String(format: "BLE listing BlueZ objects took %.1f s (%d objects)",
                           listingSeconds, objects.count))
            }
        } catch {
            reportUnusable("Bluetooth is unavailable: BlueZ is not answering on the system bus "
                + "(\(error)). Install and start bluetoothd, or use the USB link.")
            return
        }

        guard BluezLinkPlan.adapterPath(in: objects) != nil else {
            reportUnusable("No Bluetooth adapter is present, so there is no link to open.")
            return
        }

        guard let candidate = BluezLinkPlan.pickDevice(in: objects, pinned: pinnedPath()) else {
            if !announcedNoDevice {
                announcedNoDevice = true
                log("BLE no Qudelix among BlueZ's known devices — watching for one")
            }
            setFailure(BluezLinkFailure.noDeviceKnown)
            scheduleRearm(after: noDeviceDelay)
            return
        }
        announcedNoDevice = false
        devicePath = candidate
        deviceAlias = objects[candidate]?[Self.deviceInterface]?["Alias"]?.stringValue
            ?? objects[candidate]?[Self.deviceInterface]?["Name"]?.stringValue
            ?? "Qudelix 5K"
        let connectedNow = BluezLinkPlan.isConnected(candidate, in: objects)
        log("BLE picked \(deviceAlias) at \(candidate)"
            + (connectedNow ? " (already connected, e.g. for audio)" : " (not connected)"))

        if let paths = BluezLinkPlan.ready(candidate, in: objects) {
            if !linkStale {
                adoptBlueZLink(bus, device: candidate, paths: paths, connectedNow: connectedNow)
                return
            }
        } else {
            linkStale = false
        }
        guard let address = BluezLinkPlan.address(of: candidate, in: objects) else {
            reportUnusable("The Qudelix 5K's Bluetooth address is not known to BlueZ.")
            return
        }
        armLE(ArmTarget(device: candidate, address: address,
                        addressType: BluezLinkPlan.addressType(of: candidate, in: objects)))
    }

    private func rearmNow() {
        guard !isStopping, !reconnectScheduled else { return }
        lock.lock()
        let requested = relistRequested
        lock.unlock()
        if let target = armTarget, !requested, uptime() - lastListing < relistInterval {
            armLE(target)
        } else {
            bringUp()
        }
    }

    private func relistDue() -> Bool {
        lock.lock()
        let requested = relistRequested
        lock.unlock()
        return requested || uptime() - lastListing >= relistInterval
    }

    private func openBus() throws -> BluezBus {
        if let bus { return bus }
        let created = try makeBus()
        created.onSignal { [weak self] signal in self?.handle(signal) }
        bus = created
        return created
    }

    static func looksLikeQudelix(_ interfaces: [String: [String: DBusValue]]) -> Bool {
        BluezLinkPlan.looksLikeQudelix(interfaces)
    }

    private func adoptBlueZLink(_ bus: BluezBus, device: String,
                                paths: (command: String, response: String), connectedNow: Bool) {
        log("BLE BlueZ already owns the LE link; using its GATT characteristics under \(device)")
        do {
            let notify = try acquireNotify(path: paths.response, on: bus)
            lock.lock()
            notifyFD = notify.fd
            notifyBudget = max(Int(notify.mtu), 23)
            writeBudget = max(Int(notify.mtu) - 3, 20)
            commandPath = paths.command
            armTarget = nil
            mode = .bluez
            up = true
            vendor = .qudelix
            triedFallbackVendor = false
            sawGoodReply = false
            consecutiveTxErrors = 0
            reconnectDelay = Self.minReconnectDelay
            lastDrop = nil
            announcedUnusable = false
            lock.unlock()
        } catch {
            if let callError = error as? DBusCallError, BluezLinkPlan.isNotConnected(callError) {
                linkStale = true
            }
            lock.lock()
            let drop = lastDrop
            lock.unlock()
            let detail = BluezLinkFailure.detail("the Bluetooth channels could not be opened (\(error))",
                                                 drop: drop)
            setFailure("found \(deviceAlias)"
                + (connectedNow ? " (connected for audio)" : "")
                + ", but its Bluetooth LE control link did not come up: \(detail)",
                       needsAttention: connectedNow)
            log("BLE cannot open the GAIA channels: \(error)")
            scheduleReconnect()
            return
        }
        setFailure(nil)
        startNotifyReader()
        log("BLE adopted GAIA link on \(device) (write budget \(writeBudget) bytes)")
        onConnected?(deviceAlias)
    }

    private func acquireNotify(path: String,
                               on bus: BluezBus) throws -> (fd: Int32, mtu: UInt16) {
        do {
            return try acquire(path: path, on: bus)
        } catch let error as DBusCallError where BluezLinkPlan.isNotifyHeld(error) {
            _ = try? bus.call(path: path, interface: Self.characteristicInterface,
                              method: "StopNotify", arguments: [],
                              timeoutMs: DBusConnection.defaultTimeoutMs)
            log("BLE BlueZ still held the notify channel from an earlier attempt; released it")
            return try acquire(path: path, on: bus)
        }
    }

    private func acquire(path: String, on bus: BluezBus) throws -> (fd: Int32, mtu: UInt16) {
        let reply = try bus.call(path: path, interface: Self.characteristicInterface,
                                 method: "AcquireNotify", arguments: [.dictionary([])],
                                 timeoutMs: DBusConnection.defaultTimeoutMs)
        let fields = reply.count >= 2 ? reply : (reply.first?.items ?? [])
        let harvested = Self.descriptors(in: reply)
        guard fields.count >= 2, let fd = fields[0].fdValue, fd >= 0,
              let mtu = fields[1].uint16Value else {
            for descriptor in harvested { close(descriptor) }
            throw DBusCallError(name: "", message: "AcquireNotify returned no usable descriptor")
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

    private func armLE(_ target: ArmTarget) {
        armTarget = target
        setFailure(BluezLinkFailure.waitingForLink)
        log("BLE armed: waiting for the 5K to accept an LE control link at \(target.address)")
        while !isStopping {
            let candidate = makeSocket()
            switch attempt(candidate, target) {
            case .connected:
                linkConnected(candidate)
                return
            case .fatal:
                return
            case .relist:
                scheduleRearm(after: 0)
                return
            case .failed:
                break
            }
            let resume = Date().addingTimeInterval(armedDelay)
            while !isStopping, Date() < resume {
                if relistDue() {
                    scheduleRearm(after: 0)
                    return
                }
                Thread.sleep(forTimeInterval: min(0.05, max(0, resume.timeIntervalSinceNow)))
            }
        }
    }

    private func attempt(_ candidate: LEAttSocket, _ target: ArmTarget) -> Attempt {
        var state: LEAttConnectState
        do {
            state = try candidate.beginConnect(address: target.address, addressType: target.addressType)
        } catch let error as LEAttSocketError {
            candidate.close()
            if Self.isArmedFailure(error.code) {
                armedFailure(error.description)
                return .failed
            }
            reportUnusable("Bluetooth LE control links are not available here (\(error)). "
                + "Use the USB link.")
            return .fatal
        } catch {
            candidate.close()
            reportUnusable("Bluetooth LE control links are not available here (\(error)).")
            return .fatal
        }
        while !isStopping {
            switch state {
            case .connected:
                return .connected
            case .failed(let code):
                candidate.close()
                let text = String(cString: strerror(code))
                if Self.isArmedFailure(code) {
                    armedFailure(text)
                    return .failed
                }
                reportUnusable("Bluetooth LE control links are not available here (\(text)). "
                    + "Use the USB link.")
                return .fatal
            case .pending:
                if relistDue() {
                    candidate.close()
                    return .relist
                }
                state = candidate.pollConnect(timeoutMs: Self.connectTickMilliseconds)
            }
        }
        candidate.close()
        return .failed
    }

    private func armedFailure(_ detail: String) {
        let now = Date()
        if lastWaitLog.map({ now.timeIntervalSince($0) >= Self.waitLogInterval }) ?? true {
            lastWaitLog = now
            log(BluezLinkFailure.waitLog(detail))
        }
    }

    private func linkConnected(_ connected: LEAttSocket) {
        let now = uptime()
        lock.lock()
        socket = connected
        mode = .le
        up = false
        generation += 1
        let gen = generation
        vendor = .qudelix
        triedFallbackVendor = false
        sawGoodReply = false
        consecutiveTxErrors = 0
        linkUpAt = now
        lock.unlock()
        sessionLock.lock()
        session = LEGaiaSession()
        sessionLock.unlock()
        log("BLE LE link is up; discovering the GAIA service")
        drive(gen) { session, now in session.linkUp(now: now) }
        startLEReader(connected, generation: gen)
    }

    private func drive(_ gen: Int,
                       _ body: (inout LEGaiaSession, TimeInterval) -> [LEGaiaOutput]) {
        lock.lock()
        let target = generation == gen ? socket : nil
        lock.unlock()
        guard let target else { return }
        var rest: [LEGaiaOutput] = []
        var writeFailed = false
        sessionLock.lock()
        let outputs = body(&session, uptime())
        for output in outputs {
            if case .send(let pdu) = output {
                if !target.write(pdu) { writeFailed = true }
            } else {
                rest.append(output)
            }
        }
        sessionLock.unlock()
        if writeFailed { recordTxError("the LE socket refused a write", cmd: nil) }
        for output in rest { handle(output, generation: gen) }
    }

    private func handle(_ output: LEGaiaOutput, generation gen: Int) {
        switch output {
        case .send:
            return
        case .ready(let budget):
            lock.lock()
            let live = generation == gen
            if live {
                writeBudget = budget
                up = true
                reconnectDelay = Self.minReconnectDelay
                lastDrop = nil
                announcedUnusable = false
            }
            let started = linkUpAt
            lock.unlock()
            guard live else { return }
            setFailure(nil)
            log(String(format: "BLE GAIA link ready in %.2f s (write budget %d bytes)",
                       uptime() - started, budget))
            onConnected?(deviceAlias)
        case .packet(let raw):
            deliver(raw, generation: gen)
        case .writeRejected(let code):
            recordTxError(String(format: "the 5K rejected a write (ATT error 0x%02X)", code), cmd: nil)
        case .failed(let reason):
            log("BLE link failed: \(reason)")
            queue.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let live = self.generation == gen
                self.lock.unlock()
                guard live else { return }
                self.teardown(reason: reason, notify: true)
                self.rearmNow()
            }
        }
    }

    private func startLEReader(_ link: LEAttSocket, generation gen: Int) {
        lock.lock()
        readerGeneration = gen
        lock.unlock()
        let thread = Thread { [weak self] in
            var reason = "the device closed the link"
            loop: while true {
                guard let self, self.readerShouldContinue(gen) else {
                    reason = ""
                    break loop
                }
                switch link.read(timeoutMs: Self.readPollTimeoutMilliseconds) {
                case .pdu(let pdu):
                    self.drive(gen) { session, now in session.receive(pdu, now: now) }
                case .timeout:
                    self.drive(gen) { session, now in session.tick(now: now) }
                case .closed(let text):
                    reason = text
                    break loop
                }
            }
            link.close()
            let ended = reason
            self?.queue.async { [weak self] in self?.readerFinished(gen, reason: ended) }
        }
        thread.name = "qudelix.bluez.rx"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private func startNotifyReader() {
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
        rearmNow()
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
            savePin(path)
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
            let identity: Set<String> = ["Address", "AddressType", "Paired"]
            lock.lock()
            let viaBlueZ = mode == .bluez
            if !Set(changed.keys).isDisjoint(with: identity) { relistRequested = true }
            lock.unlock()
            if viaBlueZ, changed["Connected"]?.boolValue == false {
                queue.async { [weak self] in
                    guard let self else { return }
                    self.teardown(reason: "the device disconnected", notify: true)
                    self.rearmNow()
                }
            }
        case "InterfacesAdded":
            guard signal.arguments.count >= 2 else { return }
            if let added = signal.arguments[0].stringValue, let path = devicePath,
               added == path || added.hasPrefix(path + "/") {
                let interfaces = signal.arguments[1].dictionaryValue ?? [:]
                let relevant = interfaces[Self.deviceInterface] != nil
                    || interfaces.keys.contains { $0.hasPrefix("org.bluez.Gatt") }
                if relevant {
                    lock.lock()
                    relistRequested = true
                    lock.unlock()
                }
                return
            }
            guard devicePath == nil, !isConnected,
                  let interfaces = signal.arguments[1].dictionaryValue,
                  let device = interfaces[Self.deviceInterface]?.dictionaryValue,
                  BluezLinkPlan.looksLikeQudelix(properties: device) else { return }
            requestBringUp()
        case "Disconnected":
            guard let drop = BluezLinkPlan.parseDrop(interface: signal.interface, path: signal.path,
                                                     arguments: signal.arguments,
                                                     devicePath: devicePath) else { return }
            lock.lock()
            let skip = stopping
            if !skip { lastDrop = drop }
            lock.unlock()
            guard !skip else { return }
            log("BLE \(signal.path) " + BluezLinkFailure.dropSentence(drop))
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
        let wasUp = up
        generation += 1
        let orphanedNotify = mode == .bluez && readerGeneration == nil ? notifyFD : -1
        let leSocket = socket
        socket = nil
        notifyFD = -1
        commandPath = nil
        mode = .none
        up = false
        vendor = .qudelix
        triedFallbackVendor = false
        sawGoodReply = false
        consecutiveTxErrors = 0
        lock.unlock()
        sessionLock.lock()
        session = LEGaiaSession()
        sessionLock.unlock()
        if orphanedNotify >= 0 { close(orphanedNotify) }
        leSocket?.close()
        if wasUp {
            log("BLE link torn down (\(reason))")
            if notify { onDisconnected?() }
        }
    }

    private func scheduleRearm(after delay: TimeInterval) {
        guard !isStopping, !reconnectScheduled else { return }
        reconnectScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.reconnectScheduled = false
            self.bringUp()
        }
    }

    private func scheduleReconnect() {
        lock.lock()
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, Self.maxReconnectDelay)
        lock.unlock()
        log("BLE retrying in \(String(format: "%.1f", delay))s")
        scheduleRearm(after: delay)
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
