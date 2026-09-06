#if os(Linux)
import Foundation
import Glibc

struct HidrawDevice: Equatable {
    var node: String
    var devPath: String
    var name: String
    var vendorID: Int
    var productID: Int
    var descriptor: [UInt8]
    var outputReportSizes: [Int: Int]
}

enum HidrawDevices {
    static let qccVendorID = 0x0A12
    static let qudelix5KProductID = 0x4003
    static let productNameMarker = "qudelix"
    static let vendorUsagePage = 0xFF00
    static let minReportSize = 8
    static let maxReportSize = 1024

    static let defaultSysRoot = "/sys/class/hidraw"
    static let defaultDevRoot = "/dev"

    static func candidates(sysRoot: String = defaultSysRoot,
                           devRoot: String = defaultDevRoot) -> [HidrawDevice] {
        nodeNames(sysRoot: sysRoot)
            .compactMap { device(node: $0, sysRoot: sysRoot, devRoot: devRoot) }
            .filter(matches)
    }

    static func nodeNames(sysRoot: String) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: sysRoot)) ?? []
        return entries.filter { $0.hasPrefix("hidraw") }.sorted()
    }

    static func device(node: String, sysRoot: String, devRoot: String) -> HidrawDevice? {
        let base = "\(sysRoot)/\(node)/device"
        guard let ueventBytes = readBytes(atPath: "\(base)/uevent") else { return nil }
        let fields = parseUevent(String(decoding: ueventBytes, as: UTF8.self))
        guard let ids = parseHidID(fields["HID_ID"] ?? "") else { return nil }
        guard let descriptor = readBytes(atPath: "\(base)/report_descriptor") else { return nil }
        return HidrawDevice(
            node: node,
            devPath: "\(devRoot)/\(node)",
            name: fields["HID_NAME"] ?? "",
            vendorID: ids.vendor,
            productID: ids.product,
            descriptor: descriptor,
            outputReportSizes: HIDDescriptor.outputReportSizes(descriptor: descriptor)
        )
    }

    static func matches(_ device: HidrawDevice) -> Bool {
        guard device.vendorID == qccVendorID else { return false }
        guard HIDDescriptor.firstUsagePage(descriptor: device.descriptor) == vendorUsagePage else {
            return false
        }
        return device.productID == qudelix5KProductID
            || device.name.lowercased().contains(productNameMarker)
    }

    static func parseUevent(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let split = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<split])
            let value = String(line[line.index(after: split)...])
            guard !key.isEmpty else { continue }
            fields[key] = value.trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    static func parseHidID(_ value: String) -> (bus: Int, vendor: Int, product: Int)? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { Int($0, radix: 16) }
        guard numbers.count == 3 else { return nil }
        return (numbers[0], numbers[1], numbers[2])
    }

    static func plausibleReportSize(_ size: Int?) -> Bool {
        guard let size else { return false }
        return (minReportSize...maxReportSize).contains(size)
    }

    static func outputReport(for device: HidrawDevice) -> (id: Int, size: Int)? {
        let sizes = device.outputReportSizes
        if plausibleReportSize(sizes[8]) { return (8, sizes[8]!) }
        if plausibleReportSize(sizes[7]) { return (7, sizes[7]!) }
        let largest = sizes
            .filter { plausibleReportSize($0.value) }
            .max { left, right in
                left.value == right.value ? left.key < right.key : left.value < right.value
            }
        guard let largest else { return nil }
        return (largest.key, largest.value)
    }

    static func declaredReportIDs(descriptor bytes: [UInt8]) -> Set<Int> {
        var ids: Set<Int> = []
        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]
            if prefix == 0xFE {
                guard i + 1 < bytes.count else { break }
                i += 3 + Int(bytes[i + 1]); continue
            }
            var size = Int(prefix & 0x03); if size == 3 { size = 4 }
            if prefix & 0xFC == 0x84 {
                var value = 0
                for j in 0..<size where i + 1 + j < bytes.count {
                    value |= Int(bytes[i + 1 + j]) << (8 * j)
                }
                if (1...255).contains(value) { ids.insert(value) }
            }
            i += 1 + size
        }
        return ids
    }

    static func strippingReportID(_ bytes: [UInt8], reportID: Int) -> [UInt8] {
        guard let first = bytes.first, Int(first) == reportID else { return bytes }
        return Array(bytes.dropFirst())
    }

    static let maxFileBytes = 65536

    static func readBytes(atPath path: String) -> [UInt8]? {
        let fd = path.withCString { open($0, O_RDONLY) }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while out.count <= maxFileBytes {
            let read = chunk.withUnsafeMutableBytes { buffer -> Int in
                Glibc.read(fd, buffer.baseAddress, buffer.count)
            }
            if read > 0 {
                out.append(contentsOf: chunk[0..<read])
            } else if read == 0 {
                return out
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return out
    }
}
#endif
