import XCTest
@testable import QudelixBar

final class BluezPresenceTests: XCTestCase {
    private struct Down: Error {}

    private func device(uuids: [String], paired: Bool = true, connected: Bool = true) -> [String: [String: DBusValue]] {
        ["org.bluez.Device1": ["UUIDs": DBusValue.strings(uuids), "Paired": .boolean(paired),
                              "Connected": .boolean(connected)]]
    }

    private func presence(owner: Bool = true, objects: BluezPresence.Objects? = nil,
                          asked: @escaping () -> Void = {}) -> BluezPresence {
        BluezPresence(nameHasOwner: { asked(); return owner },
                      managedObjects: {
                          asked()
                          guard let objects else { throw Down() }
                          return objects
                      })
    }

    func testAPairedQudelixCountsAsPresent() {
        let objects: BluezPresence.Objects = [
            "/org/bluez/hci0": ["org.bluez.Adapter1": [:]],
            "/org/bluez/hci0/dev_other": device(uuids: ["0000110a-0000-1000-8000-00805f9b34fb"]),
            "/org/bluez/hci0/dev_5K": device(uuids: [GaiaFraming.serviceUUID.uppercased()]),
        ]
        XCTAssertTrue(presence(objects: objects).qudelixPresent())
    }

    func testAConnectedButUnpairedQudelixCountsLikeTheTransportRule() {
        let objects: BluezPresence.Objects = [
            "/org/bluez/hci0/dev_5K": device(uuids: [GaiaFraming.serviceUUID], paired: false),
        ]
        XCTAssertTrue(presence(objects: objects).qudelixPresent())
    }

    func testAPairedQudelixThatIsOffIsNotPresent() {
        let objects: BluezPresence.Objects = [
            "/org/bluez/hci0/dev_5K": device(uuids: [GaiaFraming.serviceUUID], connected: false),
        ]
        XCTAssertFalse(presence(objects: objects).qudelixPresent())
        var advertising = objects
        advertising["/org/bluez/hci0/dev_5K"]?["org.bluez.Device1"]?["RSSI"] = .int16(-55)
        XCTAssertTrue(presence(objects: advertising).qudelixPresent())
    }

    func testOtherDevicesAndMissingPropertiesAreNotPresent() {
        let objects: BluezPresence.Objects = [
            "/org/bluez/hci0": ["org.bluez.Adapter1": [:]],
            "/org/bluez/hci0/dev_a": device(uuids: ["0000110a-0000-1000-8000-00805f9b34fb"]),
            "/org/bluez/hci0/dev_b": ["org.bluez.Device1": [:]],
            "/org/bluez/hci0/dev_c": ["org.bluez.Battery1": ["UUIDs": DBusValue.strings([GaiaFraming.serviceUUID])]],
        ]
        XCTAssertFalse(presence(objects: objects).qudelixPresent())
        XCTAssertFalse(presence(objects: [:]).qudelixPresent())
    }

    func testAbsentBluezStaysSilentAndNeverListsObjects() {
        var calls = 0
        let result = presence(owner: false, objects: [
            "/org/bluez/hci0/dev_5K": device(uuids: [GaiaFraming.serviceUUID]),
        ], asked: { calls += 1 }).qudelixPresent()
        XCTAssertFalse(result)
        XCTAssertEqual(calls, 1)
    }

    func testABusErrorMeansNotPresent() {
        XCTAssertFalse(presence(objects: nil).qudelixPresent())
    }

    func testUsbOrPinnedDecideWithoutAskingBluez() {
        var asked = 0
        let probe = { () -> Bool in asked += 1; return true }
        XCTAssertTrue(BluezPresence.resolve(usb: true, pinned: false, bluez: probe))
        XCTAssertTrue(BluezPresence.resolve(usb: false, pinned: true, bluez: probe))
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(BluezPresence.resolve(usb: false, pinned: false, bluez: probe))
        XCTAssertEqual(asked, 1)
        XCTAssertFalse(BluezPresence.resolve(usb: false, pinned: false, bluez: { false }))
    }
}
