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

    @discardableResult
    func flushPendingAndWait(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            drainNow()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
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
        return HIDDescriptor.outputReportSizes(descriptor: [UInt8](data))
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
