import Foundation
import IOKit.hid

/// USB HID transport for the Qudelix 5K (QCC chip, vendor 0x0A12).
/// Talks to the vendor-defined HID interface (usage page 0xFF00):
/// output report ID 8 (fallback 7), input report IDs 1 and 9.
final class HIDTransport {
    static let qccVendorID = 0x0A12
    static let nxpVendorID = 0x1FC9
    /// USB product ID observed on a Qudelix 5K — logged for diagnostics, not
    /// used to include or exclude devices (see the matching dictionary).
    static let qudelix5KProductID = 0x4003
    /// Product-name substring required before we open and write to a device.
    static let productNameMarker = "qudelix"
    /// Believable output-report sizes; anything outside is treated as garbage.
    static let minReportSize = 8
    static let maxReportSize = 1024

    private var manager: IOHIDManager?
    private let queue = DispatchQueue(label: "qudelix.hid")

    /// Written and read only on `queue` — used by send().
    private var device: IOHIDDevice?
    private var outputReportID: CFIndex = 8
    private var outputReportSize = 64

    /// Written and read only on the IOKit runloop thread — used by the
    /// attach/detach callbacks so they never touch the queue-owned state.
    private var attachedDevice: IOHIDDevice?

    /// IOKit keeps this pointer and writes into it whenever a report arrives,
    /// long after the registering call returns — so it must be a stable
    /// allocation, never `&someArrayProperty` (that pointer dies immediately).
    private static let inputBufferSize = 1024
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)

    init() { inputBuffer.initialize(repeating: 0, count: Self.inputBufferSize) }

    deinit {
        inputBuffer.deinitialize(count: Self.inputBufferSize)
        inputBuffer.deallocate()
    }

    /// (reportID, bytes) for every input report received.
    var onInputReport: ((Int, [UInt8]) -> Void)?
    var onDeviceConnected: ((String) -> Void)?
    var onDeviceRemoved: (() -> Void)?
    /// Fired when the TX breaker trips: the interface is still attached but the
    /// device has stopped accepting reports, so this link is no longer usable.
    var onLinkUnusable: (() -> Void)?


    func start() {
        queue.async { self.startOnQueue() }
    }

    private func startOnQueue() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Match the vendor-defined interface only: the 5K also exposes
        // consumer-control/audio HID interfaces we must not claim.
        //
        // Product ID is deliberately NOT part of the match: 0x4003 is what one
        // 5K reports, and pinning it would lock out any unit or firmware that
        // reports something else. Safety comes from two later checks instead —
        // the product name below, and the device ID from the handshake, which
        // gates every write. Vendor 0x0A12 alone is far too broad (it's
        // Cambridge Silicon Radio, used by countless Bluetooth dongles), but
        // no dongle is named "Qudelix".
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

        // commonModes, not defaultMode: while the main runloop is tracking a
        // drag — any slider in the popover — a defaultMode source does not
        // fire. Device reports then arrive in a burst when the drag ends,
        // seconds late, which silently defeats every 1.5 s echo-suppression
        // window and lets a pre-change report snap a control back.
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
    }

    private func deviceAttached(_ dev: IOHIDDevice) {
        guard attachedDevice == nil else { return }

        // Final guard against writing this protocol to an unrelated device that
        // happens to share the vendor ID.
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
        // Exact output report sizes come from the report descriptor: sending a
        // wrong-length report makes the 5K drop off the USB bus entirely.
        let outputs = Self.outputReportSizes(dev)
        DebugLog.shared.log("HID output reports: \(outputs.map { "id \($0.key)=\($0.value)B" }.sorted().joined(separator: ", "))")

        // A report size is only believable within these bounds: below it the
        // framing bytes don't fit, above it we'd be allocating nonsense for a
        // device that isn't what it claims to be.
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
        // Publish to the send queue: `device` and the report settings are read
        // there, and this callback runs on the runloop thread.
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
                // Incoming buffers lead with the report ID; the protocol framing
                // starts after it.
                if let first = bytes.first, Int(first) == Int(reportID) { bytes.removeFirst() }
                me.onInputReport?(Int(reportID), bytes)
            }, ctx)

        onDeviceConnected?(name)
    }

    private func deviceDetached(_ dev: IOHIDDevice) {
        guard attachedDevice === dev else { return }
        // IOKit holds `inputBuffer` and an unretained `self`; unhook both rather
        // than relying on this object outliving the device.
        IOHIDDeviceRegisterInputReportCallback(dev, inputBuffer, Self.inputBufferSize, nil, nil)
        IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        attachedDevice = nil
        queue.async { self.device = nil }
        DebugLog.shared.log("HID removed")
        onDeviceRemoved?()
    }

    /// Queue-owned.
    private var consecutiveTxErrors = 0
    private static let txErrorLimit = 5

    /// Coalescing: a slider drag emits ~60 updates/second, and every send costs
    /// ~20 ms of queue time, so naive queueing would keep writing to the device
    /// for seconds after the user let go. Superseded values for the same key
    /// are dropped instead — only the newest state ever reaches the hardware.
    private var pending: [String: (QxCmd, [UInt8])] = [:]
    private var pendingOrder: [String] = []
    private var draining = false

    /// Send, replacing any queued command with the same `coalesceKey`.
    func sendCoalesced(_ cmd: QxCmd, _ data: [UInt8], key: String) {
        queue.async { [self] in
            if pending[key] == nil { pendingOrder.append(key) }
            pending[key] = (cmd, data)
            drainIfNeeded()
        }
    }

    private func drainIfNeeded() {
        guard !draining else { return }
        draining = true
        queue.async { [self] in
            while !pendingOrder.isEmpty {
                let key = pendingOrder.removeFirst()
                guard let (cmd, data) = pending.removeValue(forKey: key) else { continue }
                sendNow(cmd, data)
            }
            draining = false
        }
    }

    /// Send a framed command on the report ID chosen from the descriptor.
    ///
    /// IOKit requirement for numbered reports: the buffer must begin with the
    /// report ID even though the ID is also passed as its own argument (this is
    /// what hidapi does on macOS). Omitting it misaligns every report by a byte
    /// and the 5K stops responding and drops off the USB bus.
    func send(_ cmd: QxCmd, _ data: [UInt8] = []) {
        queue.async { [self] in sendNow(cmd, data) }
    }

    /// Must be called on `queue`.
    private func sendNow(_ cmd: QxCmd, _ data: [UInt8]) {
        guard let dev = device else { return }
        guard consecutiveTxErrors < Self.txErrorLimit else { return }  // circuit breaker
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
                // Announce it once. Silently dropping writes while every control
                // stayed enabled was the worst possible presentation: the app
                // looked connected and did nothing.
                DispatchQueue.main.async { [weak self] in self?.onLinkUnusable?() }
            }
        } else {
            consecutiveTxErrors = 0
        }
        // The device needs a breather between reports; the Chrome app waits ~15 ms.
        Thread.sleep(forTimeInterval: 0.02)
    }

    /// Parse the HID report descriptor: output report byte sizes keyed by report ID.
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
            if prefix == 0xFE { // long item: skip
                guard i + 1 < bytes.count else { break }
                i += 3 + Int(bytes[i + 1]); continue
            }
            var size = Int(prefix & 0x03); if size == 3 { size = 4 }
            var value = 0
            for j in 0..<size where i + 1 + j < bytes.count {
                value |= Int(bytes[i + 1 + j]) << (8 * j)
            }
            // Descriptor fields are up to 4 bytes, so each can be 0xFFFFFFFF.
            // Multiplying two of those overflows Int64 and traps, so both are
            // range-checked and the product is computed safely.
            switch prefix & 0xFC {
            case 0x84: reportID = (0...255).contains(value) ? value : 0
            case 0x74: reportSizeBits = (0...4096).contains(value) ? value : 0
            case 0x94: reportCount = (0...4096).contains(value) ? value : 0
            case 0x90:                                    // Output item
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

/// Ring-buffer debug log shown in the Diagnostics section of the popover.
final class DebugLog: ObservableObject {
    static let shared = DebugLog()
    @Published private(set) var lines: [String] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    /// ~/Library/Logs/QudelixBar.log. Resolved once in init — a `lazy var`
    /// would be touched from the main thread, the HID queue and URLSession
    /// tasks, and lazy initialization is not thread-safe.
    /// Where the packet log is written, for the diagnostics pane's Reveal
    /// button. Read-only: the path is decided once in `init` and nothing else
    /// gets to move it.
    private(set) var fileURL: URL?

    private let file: AppendingLog?

    static let maxLogBytes = 2_000_000

    private init() {
        let logs = try? FileManager.default.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("Logs", isDirectory: true)
        if let logs {
            try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let url = logs.appendingPathComponent("QudelixBar.log")
            fileURL = url
            file = AppendingLog(url: url, maxBytes: Self.maxLogBytes)
        } else {
            fileURL = nil
            file = nil
        }
    }

    /// Escape anything that isn't safely printable on one line.
    ///
    /// Log lines carry strings the app did not author — USB product names,
    /// preset names stored on the device. A newline in one of those forges a
    /// whole log entry, and a bidi override reorders the line when it is read
    /// back, so both are rendered as escapes rather than acted on.
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
    private var handle: FileHandle?

    private(set) var bytesWritten: Int

    init(url: URL, maxBytes: Int) {
        self.url = url
        self.maxBytes = maxBytes
        bytesWritten = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    deinit { try? handle?.close() }

    func append(_ data: Data) {
        if bytesWritten > maxBytes { rotate() }
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
