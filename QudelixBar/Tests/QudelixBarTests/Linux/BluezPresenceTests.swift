import XCTest
@testable import QudelixBar

final class BluezPresenceTests: XCTestCase {
    private struct Down: Error {}

    private func device(uuids: [String], paired: Bool = true) -> [String: [String: DBusValue]] {
        ["org.bluez.Device1": ["UUIDs": DBusValue.strings(uuids), "Paired": .boolean(paired)]]
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
        XCTAssertTrue(presence(objects: objects).qudelixKnown())
    }

    func testAKnownButUnpairedQudelixCountsLikeTheTransportRule() {
        let objects: BluezPresence.Objects = [
            "/org/bluez/hci0/dev_5K": device(uuids: [GaiaFraming.serviceUUID], paired: false),
        ]
        XCTAssertTrue(presence(objects: objects).qudelixKnown())
    }

    func testOtherDevicesAndMissingPropertiesAreNotPresent() {
        let objects: BluezPresence.Objects = [
            "/org/bluez/hci0": ["org.bluez.Adapter1": [:]],
            "/org/bluez/hci0/dev_a": device(uuids: ["0000110a-0000-1000-8000-00805f9b34fb"]),
            "/org/bluez/hci0/dev_b": ["org.bluez.Device1": [:]],
            "/org/bluez/hci0/dev_c": ["org.bluez.Battery1": ["UUIDs": DBusValue.strings([GaiaFraming.serviceUUID])]],
        ]
        XCTAssertFalse(presence(objects: objects).qudelixKnown())
        XCTAssertFalse(presence(objects: [:]).qudelixKnown())
    }

    func testAbsentBluezStaysSilentAndNeverListsObjects() {
        var calls = 0
        let result = presence(owner: false, objects: [
            "/org/bluez/hci0/dev_5K": device(uuids: [GaiaFraming.serviceUUID]),
        ], asked: { calls += 1 }).qudelixKnown()
        XCTAssertFalse(result)
        XCTAssertEqual(calls, 1)
    }

    func testABusErrorMeansNotPresent() {
        XCTAssertFalse(presence(objects: nil).qudelixKnown())
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
