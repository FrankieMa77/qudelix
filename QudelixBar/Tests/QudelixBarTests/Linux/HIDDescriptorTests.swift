import XCTest
@testable import QudelixBar

final class HIDDescriptorTests: XCTestCase {
    private let vendorDescriptor: [UInt8] = [
        0x06, 0x00, 0xFF,
        0x09, 0x01,
        0xA1, 0x01,
        0x85, 0x07,
        0x09, 0x02,
        0x15, 0x00,
        0x26, 0xFF, 0x00,
        0x75, 0x08,
        0x95, 0x3F,
        0x91, 0x02,
        0x85, 0x08,
        0x09, 0x03,
        0x75, 0x08,
        0x95, 0x1F,
        0x91, 0x02,
        0xC0
    ]

    func testOutputReportSizesReadsBothReports() {
        XCTAssertEqual(HIDDescriptor.outputReportSizes(descriptor: vendorDescriptor),
                       [7: 0x3F, 8: 0x1F])
    }

    func testFirstUsagePageIsTheVendorPage() {
        XCTAssertEqual(HIDDescriptor.firstUsagePage(descriptor: vendorDescriptor), 0xFF00)
    }

    func testEmptyDescriptorHasNoReportsAndNoUsagePage() {
        XCTAssertEqual(HIDDescriptor.outputReportSizes(descriptor: []), [:])
        XCTAssertNil(HIDDescriptor.firstUsagePage(descriptor: []))
    }

    func testTruncatedItemDoesNotTrap() {
        XCTAssertNil(HIDDescriptor.firstUsagePage(descriptor: [0x85, 0x07, 0x91]))
        XCTAssertEqual(HIDDescriptor.outputReportSizes(descriptor: [0x75]), [:])
    }
}
