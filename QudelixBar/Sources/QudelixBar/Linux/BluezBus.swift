#if os(Linux)
import Foundation

protocol BluezBus: AnyObject {
    func managedObjects() throws -> BluezLinkPlan.Objects
    func call(path: String, interface: String, method: String, arguments: [DBusValue],
              timeoutMs: Int32) throws -> [DBusValue]
    func onSignal(_ handler: @escaping (DBusSignal) -> Void)
    func close()
}

final class SystemBluezBus: BluezBus {
    private let connection: DBusConnection

    init() throws {
        connection = try DBusConnection()
        let bus = BluezTransport.bus
        for (interface, member) in [("org.freedesktop.DBus.Properties", "PropertiesChanged"),
                                    ("org.freedesktop.DBus.ObjectManager", "InterfacesAdded"),
                                    (BluezLinkPlan.deviceInterface, "Disconnected")] {
            try? connection.addMatch("type='signal',sender='\(bus)',"
                + "interface='\(interface)',member='\(member)'")
        }
        connection.startSignalPump()
    }

    func managedObjects() throws -> BluezLinkPlan.Objects {
        try connection.managedObjects(destination: BluezTransport.bus)
    }

    func call(path: String, interface: String, method: String, arguments: [DBusValue],
              timeoutMs: Int32) throws -> [DBusValue] {
        try connection.call(destination: BluezTransport.bus, path: path, interface: interface,
                            method: method, arguments: arguments, timeoutMs: timeoutMs)
    }

    func onSignal(_ handler: @escaping (DBusSignal) -> Void) {
        connection.onSignal(handler)
    }

    func close() {
        connection.stopSignalPump()
    }
}
#endif
