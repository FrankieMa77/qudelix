#if os(Linux)
import XCTest
@testable import QudelixBar

final class HidrawDevicesTests: XCTestCase {
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
        0x85, 0x01,
        0x09, 0x04,
        0x75, 0x08,
        0x95, 0x3F,
        0x81, 0x02,
        0xC0
    ]

    private let consumerDescriptor: [UInt8] = [
        0x05, 0x0C,
        0x09, 0x01,
        0xA1, 0x01,
        0x85, 0x03,
        0x09, 0xE9,
        0x75, 0x08,
        0x95, 0x02,
        0x91, 0x02,
        0xC0
    ]

    private var roots: (sys: String, dev: String)!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hidraw-\(UUID().uuidString)", isDirectory: true)
        let sys = base.appendingPathComponent("sys", isDirectory: true).path
        let dev = base.appendingPathComponent("dev", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: sys, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dev, withIntermediateDirectories: true)
        roots = (sys, dev)

        try makeNode("hidraw0",
                     hidID: "0003:00000A12:00004003",
                     hidName: "Qudelix-5K Consumer Control",
                     descriptor: consumerDescriptor)
        try makeNode("hidraw1",
                     hidID: "0003:00000A12:00004003",
                     hidName: "Qudelix-5K",
                     descriptor: vendorDescriptor)
        try makeNode("hidraw2",
                     hidID: "0003:0000046D:0000C52B",
                     hidName: "Logitech USB Receiver",
                     descriptor: vendorDescriptor)
    }

    override func tearDownWithError() throws {
        guard let roots else { return }
        let base = URL(fileURLWithPath: roots.sys).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: base)
    }

    private func makeNode(_ node: String,
                          hidID: String,
                          hidName: String,
                          descriptor: [UInt8]?) throws {
        let device = "\(roots.sys)/\(node)/device"
        try FileManager.default.createDirectory(atPath: device, withIntermediateDirectories: true)
        let uevent = "DRIVER=hid-generic\nHID_ID=\(hidID)\nHID_NAME=\(hidName)\nHID_PHYS=usb-0000:00:14.0-3/input3\n"
        try uevent.write(toFile: "\(device)/uevent", atomically: true, encoding: .utf8)
        if let descriptor {
            try Data(descriptor).write(to: URL(fileURLWithPath: "\(device)/report_descriptor"))
        }
    }

    func testOnlyTheVendorInterfaceMatches() {
        let matched = HidrawDevices.candidates(sysRoot: roots.sys, devRoot: roots.dev)
        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched.first?.node, "hidraw1")
        XCTAssertEqual(matched.first?.devPath, "\(roots.dev)/hidraw1")
        XCTAssertEqual(matched.first?.name, "Qudelix-5K")
        XCTAssertEqual(matched.first?.vendorID, 0x0A12)
        XCTAssertEqual(matched.first?.productID, 0x4003)
    }

    func testOutputReportPrefersReportEight() throws {
        let device = try XCTUnwrap(HidrawDevices.candidates(sysRoot: roots.sys, devRoot: roots.dev).first)
        XCTAssertEqual(device.outputReportSizes, [7: 0x3F, 8: 0x1F])
        let output = try XCTUnwrap(HidrawDevices.outputReport(for: device))
        XCTAssertEqual(output.id, 8)
        XCTAssertEqual(output.size, 0x1F)
    }

    func testOutputReportFallsBackToReportSevenThenTheLargest() {
        var device = HidrawDevice(node: "hidraw1", devPath: "/dev/hidraw1", name: "Qudelix-5K",
                                  vendorID: 0x0A12, productID: 0x4003, descriptor: [],
                                  outputReportSizes: [7: 63, 9: 200])
        XCTAssertEqual(HidrawDevices.outputReport(for: device)?.id, 7)
        device.outputReportSizes = [3: 12, 9: 200]
        XCTAssertEqual(HidrawDevices.outputReport(for: device)?.id, 9)
        device.outputReportSizes = [8: 2, 7: 4, 9: 4096]
        XCTAssertNil(HidrawDevices.outputReport(for: device))
    }

    func testNodeWithUnreadableDescriptorIsSkipped() throws {
        try makeNode("hidraw3",
                     hidID: "0003:00000A12:00004003",
                     hidName: "Qudelix-5K",
                     descriptor: nil)
        let matched = HidrawDevices.candidates(sysRoot: roots.sys, devRoot: roots.dev)
        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched.first?.node, "hidraw1")
        XCTAssertNil(HidrawDevices.device(node: "hidraw3", sysRoot: roots.sys, devRoot: roots.dev))
    }

    func testMissingSysRootYieldsNoCandidates() {
        XCTAssertEqual(HidrawDevices.candidates(sysRoot: "\(roots.sys)/absent",
                                                devRoot: roots.dev).count, 0)
    }

    func testHidIDParsing() {
        let parsed = HidrawDevices.parseHidID("0003:00000A12:00004003")
        XCTAssertEqual(parsed?.bus, 3)
        XCTAssertEqual(parsed?.vendor, 0x0A12)
        XCTAssertEqual(parsed?.product, 0x4003)
        XCTAssertNil(HidrawDevices.parseHidID("0003:00000A12"))
        XCTAssertNil(HidrawDevices.parseHidID("0003:zzzz:0001"))
        XCTAssertNil(HidrawDevices.parseHidID(""))
    }

    func testVendorIDAloneDoesNotMatchAnUnnamedForeignProduct() {
        var device = HidrawDevice(node: "hidraw9", devPath: "/dev/hidraw9", name: "CSR Dongle",
                                  vendorID: 0x0A12, productID: 0x0001,
                                  descriptor: vendorDescriptor, outputReportSizes: [:])
        XCTAssertFalse(HidrawDevices.matches(device))
        device.name = "Qudelix 5K"
        XCTAssertTrue(HidrawDevices.matches(device))
        device.name = "CSR Dongle"
        device.productID = 0x4003
        XCTAssertFalse(HidrawDevices.matches(device))
        device.name = "Qudelix 5K"
        device.descriptor = consumerDescriptor
        XCTAssertFalse(HidrawDevices.matches(device))
    }

    func testNameMatchesEvenWhenTheProductIDIsUnexpected() {
        let device = HidrawDevice(node: "hidraw9", devPath: "/dev/hidraw9", name: "Qudelix-5K",
                                  vendorID: 0x0A12, productID: 0x1234,
                                  descriptor: vendorDescriptor, outputReportSizes: [:])
        XCTAssertTrue(HidrawDevices.matches(device))
        XCTAssertFalse(device.hasExpectedProductID)
    }

    func testExpectedProductIDIsSurfaced() {
        let device = HidrawDevice(node: "hidraw1", devPath: "/dev/hidraw1", name: "Qudelix-5K",
                                  vendorID: 0x0A12, productID: 0x4003,
                                  descriptor: vendorDescriptor, outputReportSizes: [:])
        XCTAssertTrue(device.hasExpectedProductID)
    }

    func testDeclaredReportIDs() {
        XCTAssertEqual(HidrawDevices.declaredReportIDs(descriptor: vendorDescriptor), [1, 7, 8])
        XCTAssertEqual(HidrawDevices.declaredReportIDs(descriptor: consumerDescriptor), [3])
        XCTAssertEqual(HidrawDevices.declaredReportIDs(descriptor: []), [])
    }

    func testReportIDIsStrippedOnlyWhenTheLeadingByteMatches() {
        XCTAssertEqual(HidrawDevices.strippingReportID([1, 0x05, 0x02, 0x02], reportID: 1),
                       [0x05, 0x02, 0x02])
        XCTAssertEqual(HidrawDevices.strippingReportID([9, 0x05, 0x02, 0x02], reportID: 1),
                       [9, 0x05, 0x02, 0x02])
        XCTAssertEqual(HidrawDevices.strippingReportID([0x05, 0x02, 0x02], reportID: -1),
                       [0x05, 0x02, 0x02])
        XCTAssertEqual(HidrawDevices.strippingReportID([], reportID: 0), [])
    }

    func testTransportStartsAndStopsWithoutADevice() {
        let transport = HidrawTransport(sysRoot: "\(roots.sys)/absent",
                                        devRoot: roots.dev,
                                        pollInterval: 0.05)
        XCTAssertEqual(transport.kind, .usb)
        XCTAssertFalse(transport.isConnected)
        transport.start()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(transport.isConnected)
        transport.send(.reqDevStatus, [])
        transport.stop()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(transport.isConnected)
    }
}
#endif
