import Foundation

extension HIDDescriptor {
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
