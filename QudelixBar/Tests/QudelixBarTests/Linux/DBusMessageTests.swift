#if os(Linux)
import XCTest
@testable import QudelixBar

final class DBusMessageTests: XCTestCase {
    private func methodCall(_ method: String) -> DBusMessage? {
        DBusMessage.methodCall(destination: "org.bluez", path: "/org/bluez/hci0",
                               interface: "org.bluez.Adapter1", method: method)
    }

    func testMethodCallCarriesItsHeader() throws {
        let message = try XCTUnwrap(methodCall("StartDiscovery"))
        XCTAssertEqual(message.path, "/org/bluez/hci0")
        XCTAssertEqual(message.interface, "org.bluez.Adapter1")
        XCTAssertEqual(message.member, "StartDiscovery")
        XCTAssertTrue(message.arguments().isEmpty)
    }

    func testPropertiesGetArgumentsRoundTrip() throws {
        let message = try XCTUnwrap(
            DBusMessage.methodCall(destination: "org.bluez", path: "/org/bluez/hci0/dev_11_22",
                                   interface: "org.freedesktop.DBus.Properties", method: "Get"))
        message.append([.string("org.bluez.Device1"), .string("ServicesResolved")])
        let read = message.arguments()
        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read[0].stringValue, "org.bluez.Device1")
        XCTAssertEqual(read[1].stringValue, "ServicesResolved")
    }

    func testObjectPathIsDistinctFromString() throws {
        let message = try XCTUnwrap(methodCall("RemoveDevice"))
        message.append([.objectPath("/org/bluez/hci0/dev_11_22_33_44_55_66")])
        let read = message.arguments()
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].typeSignature, "o")
        XCTAssertEqual(read[0].stringValue, "/org/bluez/hci0/dev_11_22_33_44_55_66")
    }

    func testDiscoveryFilterDictOfVariants() throws {
        let message = try XCTUnwrap(methodCall("SetDiscoveryFilter"))
        message.append([.dictionary([("Transport", .string("le")),
                                     ("DuplicateData", .boolean(false))])])
        let read = message.arguments()
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].typeSignature, "a{sv}")
        let filter = try XCTUnwrap(read[0].dictionaryValue)
        XCTAssertEqual(filter["Transport"]?.stringValue, "le")
        XCTAssertEqual(filter["DuplicateData"]?.boolValue, false)
    }

    func testEmptyOptionsDictForAcquireWrite() throws {
        let message = try XCTUnwrap(
            DBusMessage.methodCall(destination: "org.bluez", path: "/org/bluez/hci0/dev_11/char0",
                                   interface: "org.bluez.GattCharacteristic1", method: "AcquireWrite"))
        message.append([.dictionary([])])
        let read = message.arguments()
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].typeSignature, "a{sv}")
        XCTAssertEqual(read[0].dictionaryValue?.isEmpty, true)
    }

    func testStringArrayAndNumbersRoundTrip() throws {
        let message = try XCTUnwrap(methodCall("SetDiscoveryFilter"))
        message.append([.strings(["0000110a-0000-1000-8000-00805f9b34fb"]),
                        .uint16(517),
                        .boolean(true)])
        let read = message.arguments()
        XCTAssertEqual(read.count, 3)
        XCTAssertEqual(read[0].stringArray, ["0000110a-0000-1000-8000-00805f9b34fb"])
        XCTAssertEqual(read[1].uint16Value, 517)
        XCTAssertEqual(read[2].boolValue, true)
    }

    func testManagedObjectsShapeRoundTrips() throws {
        let message = try XCTUnwrap(methodCall("SetDiscoveryFilter"))
        let device = DBusValue.dictionary([
            ("Alias", .string("Qudelix-5K")),
            ("Paired", .boolean(true)),
            ("UUIDs", .strings([GaiaFraming.serviceUUID.uppercased()]))
        ])
        let interfaces = DBusValue.array(element: "{sa{sv}}", items: [
            .dictEntry(.string("org.bluez.Device1"), device)
        ])
        let root = DBusValue.array(element: "{oa{sa{sv}}}", items: [
            .dictEntry(.objectPath("/org/bluez/hci0/dev_11"), interfaces)
        ])
        message.append([root])

        let read = try XCTUnwrap(message.arguments().first)
        XCTAssertEqual(read.typeSignature, "a{oa{sa{sv}}}")
        let entry = try XCTUnwrap(read.items?.first)
        guard case .dictEntry(let path, let value) = entry else {
            return XCTFail("expected a dict entry keyed by object path")
        }
        XCTAssertEqual(path.stringValue, "/org/bluez/hci0/dev_11")
        let byInterface = try XCTUnwrap(value.dictionaryValue)
        let props = try XCTUnwrap(byInterface["org.bluez.Device1"]?.dictionaryValue)
        XCTAssertEqual(props["Alias"]?.stringValue, "Qudelix-5K")
        XCTAssertEqual(props["Paired"]?.boolValue, true)
        XCTAssertEqual(props["UUIDs"]?.stringArray?.map { $0.lowercased() },
                       [GaiaFraming.serviceUUID])
    }
}
#endif
