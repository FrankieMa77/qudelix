#if os(Linux)
import Foundation

struct BluezPresence {
    typealias Objects = [String: [String: [String: DBusValue]]]

    var nameHasOwner: () -> Bool
    var managedObjects: () throws -> Objects

    func qudelixPresent() -> Bool {
        guard nameHasOwner() else { return false }
        guard let objects = try? managedObjects() else { return false }
        return objects.values.contains { BluezLinkPlan.isPresent($0) || BluezLinkPlan.isArmable($0) }
    }

    static func resolve(usb: Bool, pinned: Bool, bluez: () -> Bool) -> Bool {
        usb || pinned || bluez()
    }

    static let callTimeoutMs: Int32 = 2_000

    static func system() -> BluezPresence {
        BluezPresence(
            nameHasOwner: {
                (try? SystemBus.shared.run { connection in
                    let reply = try connection.call(destination: "org.freedesktop.DBus",
                                                    path: "/org/freedesktop/DBus",
                                                    interface: "org.freedesktop.DBus",
                                                    method: "NameHasOwner",
                                                    arguments: [.string(BluezTransport.bus)],
                                                    timeoutMs: callTimeoutMs)
                    return reply.first?.boolValue ?? false
                }) ?? false
            },
            managedObjects: {
                try SystemBus.shared.run { connection in
                    try connection.managedObjects(destination: BluezTransport.bus, timeoutMs: callTimeoutMs)
                } ?? [:]
            })
    }
}

private final class SystemBus {
    static let shared = SystemBus()

    private let lock = NSLock()
    private var connection: DBusConnection?

    func run<Value>(_ body: (DBusConnection) throws -> Value) rethrows -> Value? {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil { connection = try? DBusConnection() }
        guard let connection else { return nil }
        do {
            return try body(connection)
        } catch {
            self.connection = nil
            throw error
        }
    }
}
#endif
