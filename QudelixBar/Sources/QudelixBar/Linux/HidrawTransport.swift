#if os(Linux)
import Foundation
import Dispatch
import Glibc

final class HidrawTransport: QxLink {
    static let txErrorLimit = 5
    static let txPacing: TimeInterval = 0.02
    static let readPollTimeoutMilliseconds: Int32 = 200
    static let udevRuleName = "70-qudelix.rules"

    let kind: QxLinkKind = .usb

    var onConnected: ((String) -> Void)?
    var onDisconnected: (() -> Void)?
    var onLinkUnusable: ((String) -> Void)?
    var onPacket: (([UInt8]) -> Void)?

    private let sysRoot: String
    private let devRoot: String
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "qudelix.hidraw")
    private let stateLock = NSLock()

    private var connectedFlag = false
    private var liveGeneration = 0
    private var running = false
    private var timer: DispatchSourceTimer?

    private var fd: Int32 = -1
    private var readerRunning = false
    private var generation = 0
    private var openNode = ""
    private var outputReportID = 8
    private var outputReportSize = 64
    private var inputReportIDs: Set<Int> = []
    private var consecutiveTxErrors = 0
    private var notices: [String: String] = [:]

    init(sysRoot: String = HidrawDevices.defaultSysRoot,
         devRoot: String = HidrawDevices.defaultDevRoot,
         pollInterval: TimeInterval = 2) {
        self.sysRoot = sysRoot
        self.devRoot = devRoot
        self.pollInterval = pollInterval
    }

    var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connectedFlag
    }

    private func setConnected(_ value: Bool) {
        stateLock.lock()
        connectedFlag = value
        stateLock.unlock()
    }

    private func newGeneration() -> Int {
        generation += 1
        stateLock.lock()
        liveGeneration = generation
        stateLock.unlock()
        return generation
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(200))
            source.setEventHandler { [weak self] in self?.scan() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            timer?.cancel()
            timer = nil
            let hadLink = fd >= 0
            _ = newGeneration()
            if !readerRunning, fd >= 0 { close(fd) }
            fd = -1
            openNode = ""
            notices.removeAll()
            setConnected(false)
            if hadLink { onDisconnected?() }
        }
    }

    private func scan() {
        guard running, fd < 0, !readerRunning else { return }
        let devices = HidrawDevices.candidates(sysRoot: sysRoot, devRoot: devRoot)
        notices = notices.filter { entry in devices.contains { $0.node == entry.key } }
        guard let device = devices.first else { return }
        guard let output = HidrawDevices.outputReport(for: device) else {
            note(device.node, "no plausible output report size on \(device.devPath) — refusing to send")
            return
        }
        let descriptor = device.devPath.withCString { open($0, O_RDWR) }
        guard descriptor >= 0 else {
            let code = errno
            if code == EACCES || code == EPERM {
                note(device.node, "permission denied opening \(device.devPath) — install the udev "
                    + "rule \(Self.udevRuleName) and replug the device, or run as root")
            } else {
                note(device.node, "open \(device.devPath) failed: \(String(cString: strerror(code)))")
            }
            return
        }
        notices.removeValue(forKey: device.node)
        fd = descriptor
        openNode = device.node
        outputReportID = output.id
        outputReportSize = output.size
        inputReportIDs = HidrawDevices.declaredReportIDs(descriptor: device.descriptor)
        consecutiveTxErrors = 0
        let gen = newGeneration()
        readerRunning = true
        setConnected(true)
        let name = device.name.isEmpty ? device.node : device.name
        DebugLog.shared.log("hidraw attached: \(name) at \(device.devPath), "
            + "txReport id=\(output.id) size=\(output.size)")
        if !device.hasExpectedProductID {
            DebugLog.shared.log("hidraw product id \(String(format: "0x%04X", device.productID)) is not the 5K's; continuing on the name match")
        }
        startReader(fd: descriptor, generation: gen)
        onConnected?(name)
    }

    private func note(_ node: String, _ message: String) {
        guard notices[node] != message else { return }
        notices[node] = message
        DebugLog.shared.log(message)
    }

    private func startReader(fd descriptor: Int32, generation gen: Int) {
        let capacity = HidrawDevices.maxReportSize + 1
        let ids = inputReportIDs
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: capacity)
            loop: while true {
                guard let self, self.readerShouldContinue(gen) else { break }
                var descriptors = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = Glibc.poll(&descriptors, 1, Self.readPollTimeoutMilliseconds)
                if ready < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    break loop
                }
                if ready == 0 { continue }
                let count = buffer.withUnsafeMutableBytes { region -> Int in
                    Glibc.read(descriptor, region.baseAddress, region.count)
                }
                if count > 0 {
                    let bytes = Array(buffer[0..<count])
                    self.deliver(bytes, ids: ids, generation: gen)
                } else if count == 0 {
                    break loop
                } else if errno == EINTR || errno == EAGAIN {
                    continue
                } else {
                    break loop
                }
            }
            close(descriptor)
            self?.queue.async { [weak self] in self?.readerFinished(gen) }
        }
        thread.name = "qudelix.hidraw.read"
        thread.start()
    }

    private func readerShouldContinue(_ gen: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return liveGeneration == gen
    }

    private func deliver(_ bytes: [UInt8], ids: Set<Int>, generation gen: Int) {
        queue.async { [self] in
            guard generation == gen else { return }
            let leading = bytes.first.map(Int.init) ?? -1
            let reportID = ids.contains(leading) ? leading : -1
            onPacket?(HidrawDevices.strippingReportID(bytes, reportID: reportID))
        }
    }

    private func readerFinished(_ gen: Int) {
        readerRunning = false
        guard generation == gen else { return }
        fd = -1
        openNode = ""
        setConnected(false)
        DebugLog.shared.log("hidraw removed")
        onDisconnected?()
    }

    func send(_ cmd: QxCmd, _ data: [UInt8] = []) {
        queue.async { [self] in sendNow(cmd, data) }
    }

    private func sendNow(_ cmd: QxCmd, _ data: [UInt8]) {
        guard fd >= 0 else { return }
        guard consecutiveTxErrors < Self.txErrorLimit else { return }
        let report = QxPacket.txReport(cmd, data, reportSize: outputReportSize)
        guard !report.isEmpty else {
            DebugLog.shared.log("TX skipped: report size \(outputReportSize) too small for \(cmd)")
            return
        }
        let buffer = [UInt8(clamping: outputReportID)] + report
        DebugLog.shared.tx(cmd, data)
        var written = -1
        var code: Int32 = 0
        while true {
            written = buffer.withUnsafeBytes { region -> Int in
                Glibc.write(fd, region.baseAddress, region.count)
            }
            code = errno
            if written < 0, code == EINTR { continue }
            break
        }
        if written == buffer.count {
            consecutiveTxErrors = 0
        } else {
            consecutiveTxErrors += 1
            let tripped = consecutiveTxErrors == Self.txErrorLimit
            let reason = written < 0
                ? String(cString: strerror(code))
                : "short write \(written)/\(buffer.count)"
            DebugLog.shared.log("TX error \(reason) cmd=\(cmd)"
                + (consecutiveTxErrors >= Self.txErrorLimit ? " — suspending TX until reattach" : ""))
            if tripped { onLinkUnusable?("USB writes keep failing (\(reason)); the link is suspended until the device is reattached") }
        }
        Thread.sleep(forTimeInterval: Self.txPacing)
    }
}
#endif
