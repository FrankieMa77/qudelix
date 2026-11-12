#if os(Linux)
import Foundation

protocol BluezBus: AnyObject {
    var isAlive: Bool { get }
    func managedObjects() throws -> BluezLinkPlan.Objects
    func managedObjects(timeoutMs: Int32) throws -> BluezLinkPlan.Objects
    func call(path: String, interface: String, method: String, arguments: [DBusValue],
              timeoutMs: Int32) throws -> [DBusValue]
    func onSignal(_ handler: @escaping (DBusSignal) -> Void)
    func close()
}

extension BluezBus {
    var isAlive: Bool { true }
    func managedObjects(timeoutMs: Int32) throws -> BluezLinkPlan.Objects { try managedObjects() }
}

final class SystemBluezBus: BluezBus {
    private let callConnection: DBusConnection
    private let signalConnection: DBusConnection
    private let service: String
    private let permit: (String, String) throws -> Void

    init(address: String? = nil, service: String = BluezTransport.bus,
         permit: @escaping (String, String) throws -> Void = SystemBluezBus.requireAllowed) throws {
        self.service = service
        self.permit = permit
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

    var isAlive: Bool {
        callConnection.isAlive && signalConnection.isAlive
    }

    func managedObjects() throws -> BluezLinkPlan.Objects {
        try callConnection.managedObjects(destination: service)
    }

    func managedObjects(timeoutMs: Int32) throws -> BluezLinkPlan.Objects {
        try callConnection.managedObjects(destination: service, timeoutMs: timeoutMs)
    }

    static let allowedCharacteristicMethods: Set<String> = ["AcquireNotify", "StopNotify", "WriteValue"]

    static func requireAllowed(_ interface: String, _ method: String) throws {
        guard interface == BluezLinkPlan.characteristicInterface,
              allowedCharacteristicMethods.contains(method) else {
            throw DBusCallError(name: "", message: "refused to call \(interface).\(method)")
        }
    }

    func call(path: String, interface: String, method: String, arguments: [DBusValue],
              timeoutMs: Int32) throws -> [DBusValue] {
        try permit(interface, method)
        return try callConnection.call(destination: service, path: path, interface: interface,
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
