#if os(Linux)
import XCTest
@testable import QudelixBar

final class GaiaFramingTests: XCTestCase {
    private func reply(_ vendor: GaiaFraming.Vendor, _ cmd: QxCmd,
                       status: UInt8, payload: [UInt8]) -> [UInt8] {
        let responseId = cmd.rawValue | 0x8000
        return [UInt8(vendor.rawValue >> 8), UInt8(vendor.rawValue & 0xFF),
                UInt8(responseId >> 8), UInt8(responseId & 0xFF), status] + payload
    }

    func testFrameCarriesVendorAndPayload() {
        for vendor in GaiaFraming.Vendor.allCases {
            let frame = GaiaFraming.frame(vendor, .setVolume, [0x01, 0x02])
            XCTAssertEqual(frame[0], UInt8(vendor.rawValue >> 8))
            XCTAssertEqual(frame[1], UInt8(vendor.rawValue & 0xFF))
            XCTAssertEqual(Array(frame[2...]), QxPacket.payload(.setVolume, [0x01, 0x02]))
        }
    }

    func testDecodeRoundTripsForBothVendors() {
        for vendor in GaiaFraming.Vendor.allCases {
            let payload: [UInt8] = [0x11, 0x22, 0x33]
            let raw = reply(vendor, .reqInitData, status: 0, payload: payload)
            guard let (packet, status) = GaiaFraming.decode(raw, expecting: vendor) else {
                return XCTFail("vendor \(vendor.label) frame did not decode")
            }
            XCTAssertEqual(status, 0)
            XCTAssertEqual(packet[0], UInt8(payload.count + 2))
            let parsed = QxPacket.parseRx(packet)
            XCTAssertEqual(parsed?.cmdId, QxCmd.reqInitData.rawValue)
            XCTAssertEqual(parsed?.data, payload)
        }
    }

    func testDecodeRejectsTheOtherVendor() {
        let raw = reply(.qudelix, .reqInitData, status: 0, payload: [0x01])
        XCTAssertNil(GaiaFraming.decode(raw, expecting: .qudelixMk2))
        XCTAssertNotNil(GaiaFraming.decode(raw, expecting: .qudelix))
    }

    func testDecodeRejectsATruncatedFrame() {
        let raw = reply(.qudelix, .reqInitData, status: 0, payload: [])
        for length in 0..<5 {
            XCTAssertNil(GaiaFraming.decode(Array(raw.prefix(length)), expecting: .qudelix),
                         "a \(length)-byte frame must not decode")
        }
        XCTAssertNotNil(GaiaFraming.decode(raw, expecting: .qudelix))
    }

    func testDecodeReportsAFailureStatus() {
        let raw = reply(.qudelix, .reqInitData, status: 1, payload: [])
        XCTAssertEqual(GaiaFraming.decode(raw, expecting: .qudelix)?.status, 1)
    }

    func testWriteRefusalAcrossTheMtuBudgets() {
        let frame = GaiaFraming.frame(.qudelix, .setEqPresetName, [UInt8](repeating: 0x41, count: 10))
        XCTAssertEqual(frame.count, 14)
        XCTAssertNotNil(GaiaFraming.writeRefusal(frame: frame, budget: 20 - 8))
        XCTAssertNil(GaiaFraming.writeRefusal(frame: frame, budget: 20))
        XCTAssertNil(GaiaFraming.writeRefusal(frame: frame, budget: 23))
        XCTAssertNil(GaiaFraming.writeRefusal(frame: frame, budget: 244))
        XCTAssertEqual(GaiaFraming.writeRefusal(frame: frame, budget: 13),
                       "14 bytes, over the 13-byte single-write budget")
    }
}
#endif
