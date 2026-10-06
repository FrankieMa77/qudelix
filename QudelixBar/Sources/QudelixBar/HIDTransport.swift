import Foundation
import IOKit.hid

final class HIDTransport {
    static let qccVendorID = 0x0A12
    static let nxpVendorID = 0x1FC9
    static let qudelix5KProductID = 0x4003
    static let productNameMarker = "qudelix"
    static let minReportSize = 8
    static let maxReportSize = 1024

    private var manager: IOHIDManager?
    private let queue = DispatchQueue(label: "qudelix.hid")

    private var device: IOHIDDevice?
    private var outputReportID: CFIndex = 8
    private var outputReportSize = 64

    private var attachedDevice: IOHIDDevice?

    private static let inputBufferSize = 1024
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)

    init() { inputBuffer.initialize(repeating: 0, count: Self.inputBufferSize) }

    deinit {
        inputBuffer.deinitialize(count: Self.inputBufferSize)
        inputBuffer.deallocate()
    }

    var onInputReport: ((Int, [UInt8]) -> Void)?
    var onDeviceConnected: ((String) -> Void)?
    var onDeviceRemoved: (() -> Void)?
    var onLinkUnusable: (() -> Void)?

    func start() {
        queue.async { self.startOnQueue() }
    }

    private func startOnQueue() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matches: [[String: Any]] = [
            [kIOHIDVendorIDKey: Self.qccVendorID, kIOHIDPrimaryUsagePageKey: 0xFF00],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(m, matches as CFArray)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            let me = Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue()
            me.deviceAttached(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            let me = Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue()
            me.deviceDetached(device)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
    }

    private func deviceAttached(_ dev: IOHIDDevice) {
        guard attachedDevice == nil else { return }

        let name = stringProperty(dev, kIOHIDProductKey) ?? ""
        guard name.lowercased().contains(Self.productNameMarker) else {
            DebugLog.shared.log("ignoring non-Qudelix HID device: \(name.isEmpty ? "(unnamed)" : name)")
            return
        }
        let pid = intProperty(dev, kIOHIDProductIDKey) ?? 0
        if pid != Self.qudelix5KProductID {
            DebugLog.shared.log(String(format: "note: product ID 0x%04X (expected 0x%04X)",
                                       pid, Self.qudelix5KProductID))
        }

        let result = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            DebugLog.shared.log("HID open failed: 0x\(String(result, radix: 16))")
            return
        }
        let outputs = Self.outputReportSizes(dev)
        DebugLog.shared.log("HID output reports: \(outputs.map { "id \($0.key)=\($0.value)B" }.sorted().joined(separator: ", "))")

        func plausible(_ n: Int?) -> Bool {
            guard let n else { return false }
            return (Self.minReportSize...Self.maxReportSize).contains(n)
        }

        var reportID: CFIndex = 8
        var reportSize = 0
        if plausible(outputs[8]) {
            reportID = 8; reportSize = outputs[8]!
        } else if plausible(outputs[7]) {
            reportID = 7; reportSize = outputs[7]!
        } else {
            let maxOut = intProperty(dev, kIOHIDMaxOutputReportSizeKey)
            guard plausible(maxOut) else {
                DebugLog.shared.log("no plausible output report size — refusing to send")
                IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
                return
            }
            reportSize = maxOut!
            DebugLog.shared.log("WARN: no output report 8/7 in descriptor, using maxOut=\(reportSize)")
        }
        DebugLog.shared.log("HID attached: \(name), txReport id=\(reportID) size=\(reportSize)")

        attachedDevice = dev
        queue.async {
            self.device = dev
            self.outputReportID = reportID
            self.outputReportSize = reportSize
            self.consecutiveTxErrors = 0
        }

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            dev, inputBuffer, Self.inputBufferSize,
            { ctx, _, _, _, reportID, report, reportLength in
                let me = Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue()
                var bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
                if let first = bytes.first, Int(first) == Int(reportID) { bytes.removeFirst() }
                me.onInputReport?(Int(reportID), bytes)
            }, ctx)

        onDeviceConnected?(name)
    }

    private func deviceDetached(_ dev: IOHIDDevice) {
        guard attachedDevice === dev else { return }
        IOHIDDeviceRegisterInputReportCallback(dev, inputBuffer, Self.inputBufferSize, nil, nil)
        IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        attachedDevice = nil
        queue.async { self.device = nil }
        DebugLog.shared.log("HID removed")
        onDeviceRemoved?()
    }

    private var consecutiveTxErrors = 0
    private static let txErrorLimit = 5

    private var pending: [String: (QxCmd, [UInt8])] = [:]
    private var pendingOrder: [String] = []
    private var draining = false

    func sendCoalesced(_ cmd: QxCmd, _ data: [UInt8], key: String) {
        queue.async { [self] in
            if pending[key] == nil { pendingOrder.append(key) }
            pending[key] = (cmd, data)
            drainIfNeeded()
        }
    }

    func flushPending() {
        queue.async { [self] in drainNow() }
    }

    private func drainIfNeeded() {
        guard !draining else { return }
        draining = true
        queue.async { [self] in
            drainNow()
            draining = false
        }
    }

    private func drainNow() {
        while !pendingOrder.isEmpty {
            let key = pendingOrder.removeFirst()
            guard let (cmd, data) = pending.removeValue(forKey: key) else { continue }
            sendNow(cmd, data)
        }
    }

    func send(_ cmd: QxCmd, _ data: [UInt8] = []) {
        queue.async { [self] in sendNow(cmd, data) }
    }

    private func sendNow(_ cmd: QxCmd, _ data: [UInt8]) {
        guard let dev = device else { return }
        guard consecutiveTxErrors < Self.txErrorLimit else { return }
        let report = QxPacket.txReport(cmd, data, reportSize: outputReportSize)
        guard !report.isEmpty else {
            DebugLog.shared.log("TX skipped: report size \(outputReportSize) too small for \(cmd)")
            return
        }
        let buffer = [UInt8(clamping: outputReportID)] + report
        DebugLog.shared.tx(cmd, data)
        let result = setReport(dev, id: outputReportID, bytes: buffer)
        if result != kIOReturnSuccess {
            consecutiveTxErrors += 1
            let tripped = consecutiveTxErrors == Self.txErrorLimit
            DebugLog.shared.log("TX error 0x\(String(format: "%08X", UInt32(bitPattern: result))) cmd=\(cmd)"
                + (consecutiveTxErrors >= Self.txErrorLimit ? " — suspending TX until reattach" : ""))
            if tripped {
                DispatchQueue.main.async { [weak self] in self?.onLinkUnusable?() }
            }
        } else {
            consecutiveTxErrors = 0
        }
        Thread.sleep(forTimeInterval: 0.02)
    }

    static func outputReportSizes(_ dev: IOHIDDevice) -> [Int: Int] {
        guard let data = IOHIDDeviceGetProperty(dev, "ReportDescriptor" as CFString) as? Data else {
            return [:]
        }
        var sizes: [Int: Int] = [:]
        var reportID = 0, reportSizeBits = 0, reportCount = 0
        var i = 0
        let bytes = [UInt8](data)
        while i < bytes.count {
            let prefix = bytes[i]
            if prefix == 0xFE {
                guard i + 1 < bytes.count else { break }
                i += 3 + Int(bytes[i + 1]); continue
            }
            var size = Int(prefix & 0x03); if size == 3 { size = 4 }
            var value = 0
            for j in 0..<size where i + 1 + j < bytes.count {
                value |= Int(bytes[i + 1 + j]) << (8 * j)
            }
            switch prefix & 0xFC {
            case 0x84: reportID = (0...255).contains(value) ? value : 0
            case 0x74: reportSizeBits = (0...4096).contains(value) ? value : 0
            case 0x94: reportCount = (0...4096).contains(value) ? value : 0
            case 0x90:
                let (bits, overflow) = reportSizeBits.multipliedReportingOverflow(by: reportCount)
                guard !overflow, bits >= 0 else { break }
                let existing = sizes[reportID, default: 0]
                let (total, sumOverflow) = existing.addingReportingOverflow(bits / 8)
                guard !sumOverflow else { break }
                sizes[reportID] = total
            default: break
            }
            i += 1 + size
        }
        return sizes
    }

    private func setReport(_ dev: IOHIDDevice, id: CFIndex, bytes: [UInt8]) -> IOReturn {
        bytes.withUnsafeBufferPointer { ptr in
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, id, ptr.baseAddress!, bytes.count)
        }
    }

    private func intProperty(_ dev: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(dev, key as CFString) as? Int
    }

    private func stringProperty(_ dev: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(dev, key as CFString) as? String
    }
}

final class DebugLog: ObservableObject {
    static let shared = DebugLog()
    @Published private(set) var lines: [String] = []
    static let timestampFormat = "yyyy-MM-dd HH:mm:ss.SSS"

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = DebugLog.timestampFormat
        return f
    }()

    private(set) var fileURL: URL?

    private let file: AppendingLog?

    static let maxLogBytes = 2_000_000

    static var runningUnderTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func logURL(underTests: Bool = runningUnderTests) -> URL? {
        if underTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("QudelixBar-tests.log")
        }
        guard let logs = try? FileManager.default.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("Logs", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("QudelixBar.log")
    }

    private init() {
        let url = Self.logURL()
        fileURL = url
        file = url.map { AppendingLog(url: $0, maxBytes: Self.maxLogBytes) }
    }

    static func sanitized(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                out += String(format: "\\u{%04X}", u.value)
            default:
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    func log(_ msg: String) {
        let line = "\(formatter.string(from: Date())) \(Self.sanitized(msg))"
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > 200 { self.lines.removeFirst(self.lines.count - 200) }
        }
        guard let file, let data = (line + "\n").data(using: .utf8) else { return }
        logQueue.async { file.append(data) }
    }

    private let logQueue = DispatchQueue(label: "qudelix.log")

    func flush() {
        logQueue.sync {}
    }

    func tx(_ cmd: QxCmd, _ data: [UInt8]) {
        log("→ \(cmd) \(hex(data))")
    }

    func rx(_ cmdId: UInt16, _ data: [UInt8]) {
        let name = QxCmd(rawValue: cmdId).map { "\($0)" } ?? String(format: "0x%04X", cmdId)
        log("← \(name) \(hex(data))")
    }

    private func hex(_ b: [UInt8]) -> String {
        b.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
            + (b.count > 24 ? "…(\(b.count))" : "")
    }
}

final class AppendingLog {
    private let url: URL
    private let maxBytes: Int
    private let verifyEvery: TimeInterval
    private var handle: FileHandle?
    private var lastVerified = Date.distantPast

    private(set) var bytesWritten: Int

    init(url: URL, maxBytes: Int, verifyEvery: TimeInterval = 1) {
        self.url = url
        self.maxBytes = maxBytes
        self.verifyEvery = verifyEvery
        bytesWritten = Self.sizeOnDisk(url)
    }

    deinit { try? handle?.close() }

    func append(_ data: Data) {
        if bytesWritten > maxBytes { rotate() }
        dropHandleIfDetached()
        guard let handle = liveHandle() else { return }
        if (try? handle.write(contentsOf: data)) != nil {
            bytesWritten += data.count
        } else {
            close()
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    private func liveHandle() -> FileHandle? {
        if let handle { return handle }
        handle = openAppending()
        return handle
    }

    private func dropHandleIfDetached() {
        guard let handle else { return }
        let now = Date()
        guard now.timeIntervalSince(lastVerified) >= verifyEvery else { return }
        lastVerified = now
        guard !Self.descriptor(handle.fileDescriptor, isTheFileAt: url) else { return }
        close()
        bytesWritten = Self.sizeOnDisk(url)
    }

    static func descriptor(_ fd: Int32, isTheFileAt url: URL) -> Bool {
        var open = stat()
        guard fstat(fd, &open) == 0, open.st_nlink > 0 else { return false }
        var onDisk = stat()
        let present = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return lstat(path, &onDisk) == 0
        }
        return present && open.st_dev == onDisk.st_dev && open.st_ino == onDisk.st_ino
    }

    private static func sizeOnDisk(_ url: URL) -> Int {
        var st = stat()
        let present = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return lstat(path, &st) == 0
        }
        return present ? Int(st.st_size) : 0
    }

    private func openAppending() -> FileHandle? {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func rotate() {
        close()
        let previous = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        bytesWritten = 0
    }
}
