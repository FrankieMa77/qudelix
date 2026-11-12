#if os(Linux)
import XCTest
@testable import QudelixBar

final class LEAttSocketTests: XCTestCase {
    func testTheAddressIsParsedAndReversed() {
        XCTAssertEqual(LEAttAddress.parse("AA:BB:CC:DD:EE:FF"), [0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA])
        XCTAssertEqual(LEAttAddress.parse("00:11:22:33:44:55"), [0x55, 0x44, 0x33, 0x22, 0x11, 0x00])
        XCTAssertEqual(LEAttAddress.parse("aa:bb:cc:dd:ee:0f"), [0x0F, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA])
    }

    func testBadAddressesAreRefused() {
        for text in ["", "AA:BB:CC:DD:EE", "AA:BB:CC:DD:EE:FF:00", "AA-BB-CC-DD-EE-FF", "GG:BB:CC:DD:EE:FF",
                     "A:BB:CC:DD:EE:FF", "AAA:BB:CC:DD:EE:FF", "AA:BB:CC:DD:EE:"] {
            XCTAssertNil(LEAttAddress.parse(text), text)
        }
    }

    func testTheAddressTypeFollowsBlueZ() {
        XCTAssertEqual(LEAttAddress.addressType("random"), 2)
        XCTAssertEqual(LEAttAddress.addressType("Random"), 2)
        XCTAssertEqual(LEAttAddress.addressType("public"), 1)
        XCTAssertEqual(LEAttAddress.addressType(nil), 1)
        XCTAssertEqual(LEAttAddress.addressType("something"), 1)
    }

    func testTheConnectImageIsTheFourteenByteSockaddr() {
        let image = LEAttAddress.connectImage(address: "AA:BB:CC:DD:EE:FF", type: "public")
        XCTAssertEqual(image, [31, 0, 0, 0, 0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA, 4, 0, 1, 0])
        XCTAssertEqual(image?.count, LEAttAddress.imageSize)
        let random = LEAttAddress.connectImage(address: "01:02:03:04:05:06", type: "random")
        XCTAssertEqual(random, [31, 0, 0, 0, 6, 5, 4, 3, 2, 1, 4, 0, 2, 0])
        XCTAssertNil(LEAttAddress.connectImage(address: "nonsense", type: nil))
    }

    func testTheBindImageIsTheAnyAddressOnTheAttributeChannel() {
        XCTAssertEqual(LEAttAddress.bindImage(), [31, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 1, 0])
    }

    func testTheKernelStructAgreesWithTheImage() {
        XCTAssertGreaterThanOrEqual(MemoryLayout<sockaddr>.size, 14)
        XCTAssertEqual(LEAttAddress.family, 31)
        XCTAssertEqual(LEAttAddress.attributeChannel, 4)
    }

    func testTheSocketErrorNamesTheCause() {
        let error = LEAttSocketError(code: EAFNOSUPPORT, what: "cannot open a Bluetooth LE socket")
        XCTAssertTrue(error.description.hasPrefix("cannot open a Bluetooth LE socket: "))
    }

    func testArmedFailuresAreTheListedErrors() {
        for code in [ECONNREFUSED, ENOSYS, EHOSTDOWN, ETIMEDOUT, EBUSY] {
            XCTAssertTrue(BluezTransport.isArmedFailure(code))
        }
        for code in [EAFNOSUPPORT, EPROTONOSUPPORT, EACCES, EPERM, ENODEV, ENETDOWN] {
            XCTAssertFalse(BluezTransport.isArmedFailure(code))
        }
    }
}
#endif
