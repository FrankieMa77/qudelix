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
    private let callConnection: DBusConnection
    private let signalConnection: DBusConnection
    private let service: String

    init(address: String? = nil, service: String = BluezTransport.bus) throws {
        self.service = service
        callConnection = try DBusConnection(address: address)
        signalConnection = try DBusConnection(address: address)
        for (interface, member) in [("org.freedesktop.DBus.Properties", "PropertiesChanged"),
                                    ("org.freedesktop.DBus.ObjectManager", "InterfacesAdded"),
                                    (BluezLinkPlan.deviceInterface, "Disconnected")] {
            try? signalConnection.addMatch("type='signal',sender='\(service)',"
                + "interface='\(interface)',member='\(member)'")
        }
        signalConnection.startSignalPump()
    }

    func managedObjects() throws -> BluezLinkPlan.Objects {
        try callConnection.managedObjects(destination: service)
    }

    func call(path: String, interface: String, method: String, arguments: [DBusValue],
              timeoutMs: Int32) throws -> [DBusValue] {
        try callConnection.call(destination: service, path: path, interface: interface,
                                method: method, arguments: arguments, timeoutMs: timeoutMs)
    }

    func onSignal(_ handler: @escaping (DBusSignal) -> Void) {
        signalConnection.onSignal(handler)
    }

    func close() {
        signalConnection.stopSignalPump()
    }
}
#endif
