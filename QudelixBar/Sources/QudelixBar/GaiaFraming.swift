import Foundation

enum GaiaFraming {
    static let serviceUUID = "00001100-d102-11e1-9b23-00025b00a5a5"
    static let commandUUID = "00001101-d102-11e1-9b23-00025b00a5a5"
    static let responseUUID = "00001102-d102-11e1-9b23-00025b00a5a5"

    enum Vendor: UInt16, CaseIterable {
        case qudelix = 0xF001
        case qudelixMk2 = 0xF003

        var label: String { String(format: "0x%04X", rawValue) }
    }

    static func frame(_ vendor: Vendor, _ cmd: QxCmd, _ data: [UInt8]) -> [UInt8] {
        [UInt8(vendor.rawValue >> 8), UInt8(vendor.rawValue & 0xFF)]
            + QxPacket.payload(cmd, data)
    }

    static func decode(_ raw: [UInt8], expecting vendor: Vendor) -> (packet: [UInt8], status: UInt8)? {
        guard raw.count >= 5 else { return nil }
        let seen = UInt16(raw[0]) << 8 | UInt16(raw[1])
        guard seen == vendor.rawValue else { return nil }
        let status = raw[4]
        let payload = Array(raw[5...])
        guard payload.count + 2 <= 0xFF else { return nil }
        let packet = [UInt8(payload.count + 2), raw[2] & 0x7F, raw[3]] + payload
        return (packet, status)
    }

    static func writeRefusal(frame: [UInt8], budget: Int) -> String? {
        guard frame.count > budget else { return nil }
        return "\(frame.count) bytes, over the \(budget)-byte single-write budget"
    }
}
