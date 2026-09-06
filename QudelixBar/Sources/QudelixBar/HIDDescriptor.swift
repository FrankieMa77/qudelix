import Foundation

enum HIDDescriptor {
    static func outputReportSizes(descriptor bytes: [UInt8]) -> [Int: Int] {
        var sizes: [Int: Int] = [:]
        var reportID = 0, reportSizeBits = 0, reportCount = 0
        var i = 0
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

    static func firstUsagePage(descriptor bytes: [UInt8]) -> Int? {
        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]
            if prefix == 0xFE {
                guard i + 1 < bytes.count else { return nil }
                i += 3 + Int(bytes[i + 1]); continue
            }
            var size = Int(prefix & 0x03); if size == 3 { size = 4 }
            if prefix & 0xFC == 0x04 {
                var value = 0
                for j in 0..<size where i + 1 + j < bytes.count {
                    value |= Int(bytes[i + 1 + j]) << (8 * j)
                }
                return value
            }
            i += 1 + size
        }
        return nil
    }
}
