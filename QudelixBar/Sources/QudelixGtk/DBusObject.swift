import CGtk
import Foundation

package final class DBusObject {
    package typealias MethodHandler = (_ method: String, _ parameters: OpaquePointer, _ invocation: OpaquePointer) -> Void
    package typealias PropertyHandler = (_ name: String) -> OpaquePointer?

    private let connection: OpaquePointer
    private let path: String
    private let nodeInfo: UnsafeMutablePointer<GDBusNodeInfo>
    private let vtable: UnsafeMutablePointer<GDBusInterfaceVTable>
    private let onMethod: MethodHandler
    private let onProperty: PropertyHandler
    private var registration: UInt32 = 0

    package let interfaceName: String

    package init(connection: OpaquePointer, path: String, xml: String,
                 onMethod: @escaping MethodHandler, onProperty: @escaping PropertyHandler) throws {
        self.connection = connection
        self.path = path
        self.onMethod = onMethod
        self.onProperty = onProperty
        var error: UnsafeMutablePointer<GError>?
        guard let info = g_dbus_node_info_new_for_xml(xml, &error) else {
            let message = error.map { String(cString: $0.pointee.message) } ?? "unknown"
            g_clear_error(&error)
            throw DBusObjectError.invalidInterface(message)
        }
        nodeInfo = info
        guard let interface = info.pointee.interfaces?.pointee else {
            throw DBusObjectError.invalidInterface("no interface")
        }
        interfaceName = String(cString: interface.pointee.name)
        vtable = UnsafeMutablePointer<GDBusInterfaceVTable>.allocate(capacity: 1)
        vtable.initialize(to: GDBusInterfaceVTable(
            method_call: { _, _, _, _, method, parameters, invocation, data in
                guard let data, let method, let parameters, let invocation else { return }
                let object = Unmanaged<DBusObject>.fromOpaque(data).takeUnretainedValue()
                object.onMethod(String(cString: method), parameters, invocation)
            },
            get_property: { _, _, _, _, name, _, data in
                guard let data, let name else { return nil }
                let object = Unmanaged<DBusObject>.fromOpaque(data).takeUnretainedValue()
                return object.onProperty(String(cString: name))
            },
            set_property: nil,
            padding: (nil, nil, nil, nil, nil, nil, nil, nil)))
        var failure: UnsafeMutablePointer<GError>?
        registration = g_dbus_connection_register_object(connection, path, interface, vtable,
                                                         Unmanaged.passUnretained(self).toOpaque(), nil, &failure)
        if registration == 0 {
            let message = failure.map { String(cString: $0.pointee.message) } ?? "unknown"
            g_clear_error(&failure)
            throw DBusObjectError.registrationFailed(message)
        }
    }

    deinit {
        unregister()
        g_dbus_node_info_unref(nodeInfo)
        vtable.deallocate()
    }

    package func unregister() {
        if registration != 0 {
            g_dbus_connection_unregister_object(connection, registration)
            registration = 0
        }
    }

    package func emit(_ signal: String, _ parameters: OpaquePointer?) {
        var error: UnsafeMutablePointer<GError>?
        g_dbus_connection_emit_signal(connection, nil, path, interfaceName, signal, parameters, &error)
        g_clear_error(&error)
    }

    package static func reply(_ invocation: OpaquePointer, _ value: OpaquePointer?) {
        g_dbus_method_invocation_return_value(invocation, value)
    }

    package static func fail(_ invocation: OpaquePointer, _ message: String) {
        g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.InvalidArgs", message)
    }
}

package enum DBusObjectError: Error {
    case invalidInterface(String)
    case registrationFailed(String)
}
