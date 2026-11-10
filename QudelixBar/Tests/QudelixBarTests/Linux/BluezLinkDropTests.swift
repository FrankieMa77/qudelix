#if os(Linux)
import XCTest
@testable import QudelixBar

final class BluezLinkDropTests: XCTestCase {
    private let path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"

    private func parse(interface: String, path: String? = nil, arguments: [DBusValue],
                       device: String? = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF") -> BluezDrop? {
        BluezLinkPlan.parseDrop(interface: interface, path: path ?? self.path,
                                arguments: arguments, devicePath: device)
    }

    func testBearerDropOnDevicePath() {
        let drop = parse(interface: "org.bluez.Bearer.LE1",
                         arguments: [.string("org.bluez.Reason.Timeout"), .string("Connection timeout")])
        XCTAssertEqual(drop, BluezDrop(kind: .bearer, name: "org.bluez.Reason.Timeout",
                                       message: "Connection timeout"))
    }

    func testDeviceDropOnDevicePath() {
        let drop = parse(interface: "org.bluez.Device1",
                         arguments: [.string("org.bluez.Reason.Remote"), .string("gone")])
        XCTAssertEqual(drop?.kind, .device)
        XCTAssertEqual(drop?.name, "org.bluez.Reason.Remote")
    }

    func testOtherPathIsIgnored() {
        XCTAssertNil(parse(interface: "org.bluez.Bearer.LE1", path: "/org/bluez/hci0/dev_11_22_33_44_55_66",
                           arguments: [.string("a"), .string("b")]))
    }

    func testNoDevicePathIsIgnored() {
        XCTAssertNil(parse(interface: "org.bluez.Bearer.LE1", arguments: [.string("a"), .string("b")],
                           device: nil))
    }

    func testOtherInterfaceIsIgnored() {
        XCTAssertNil(parse(interface: "org.bluez.Bearer.BREDR1", arguments: [.string("a"), .string("b")]))
        XCTAssertNil(parse(interface: "org.bluez.Adapter1", arguments: [.string("a"), .string("b")]))
    }

    func testFewerThanTwoStringsIsIgnored() {
        XCTAssertNil(parse(interface: "org.bluez.Bearer.LE1", arguments: [.string("a")]))
        XCTAssertNil(parse(interface: "org.bluez.Bearer.LE1", arguments: []))
        XCTAssertNil(parse(interface: "org.bluez.Bearer.LE1", arguments: [.string("a"), .boolean(true)]))
    }

    func testReasonWording() {
        let cases: [(String, String)] = [
            ("org.bluez.Reason.Timeout", "connection timeout"),
            ("org.bluez.Reason.Remote", "the 5K closed it"),
            ("org.bluez.Reason.Local", "this computer closed it"),
            ("org.bluez.Reason.Authentication", "authentication failure"),
            ("org.bluez.Reason.Suspend", "this computer was going to sleep")
        ]
        for (name, text) in cases {
            XCTAssertEqual(BluezLinkFailure.dropReason(name: name, message: "ignored"), text)
        }
    }

    func testUnknownReasonUsesMessageOrFallback() {
        XCTAssertEqual(BluezLinkFailure.dropReason(name: "org.bluez.Reason.Unknown", message: "Odd thing"),
                       "Odd thing")
        XCTAssertEqual(BluezLinkFailure.dropReason(name: "org.bluez.Reason.Unknown", message: ""),
                       "no reason given")
        XCTAssertEqual(BluezLinkFailure.dropReason(name: "something.else", message: ""), "no reason given")
    }

    func testDropSentences() {
        let bearer = BluezDrop(kind: .bearer, name: "org.bluez.Reason.Timeout", message: "x")
        let device = BluezDrop(kind: .device, name: "org.bluez.Reason.Remote", message: "x")
        XCTAssertEqual(BluezLinkFailure.dropSentence(bearer), "the LE link dropped (connection timeout)")
        XCTAssertEqual(BluezLinkFailure.dropSentence(device), "the 5K disconnected (the 5K closed it)")
    }

    func testComposer() {
        let drop = BluezDrop(kind: .bearer, name: "org.bluez.Reason.Local", message: "x")
        XCTAssertEqual(BluezLinkFailure.detail("it failed", drop: drop),
                       "it failed; the LE link dropped (this computer closed it)")
        XCTAssertEqual(BluezLinkFailure.detail("it failed", drop: nil), "it failed")
    }
}
#endif
