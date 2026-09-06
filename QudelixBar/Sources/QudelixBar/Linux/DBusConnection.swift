#if os(Linux)
import Foundation
import Glibc
import CDBus

struct DBusCallError: Error, CustomStringConvertible {
    let name: String
    let message: String

    var description: String {
        if name.isEmpty { return message.isEmpty ? "D-Bus call failed" : message }
        if message.isEmpty { return name }
        return "\(name): \(message)"
    }
}

enum DBusType {
    static let invalid: Int32 = 0
    static let byte = Int32(UInt8(ascii: "y"))
    static let boolean = Int32(UInt8(ascii: "b"))
    static let int16 = Int32(UInt8(ascii: "n"))
    static let uint16 = Int32(UInt8(ascii: "q"))
    static let int32 = Int32(UInt8(ascii: "i"))
    static let uint32 = Int32(UInt8(ascii: "u"))
    static let int64 = Int32(UInt8(ascii: "x"))
    static let uint64 = Int32(UInt8(ascii: "t"))
    static let double = Int32(UInt8(ascii: "d"))
    static let string = Int32(UInt8(ascii: "s"))
    static let objectPath = Int32(UInt8(ascii: "o"))
    static let signature = Int32(UInt8(ascii: "g"))
    static let unixFD = Int32(UInt8(ascii: "h"))
    static let array = Int32(UInt8(ascii: "a"))
    static let variant = Int32(UInt8(ascii: "v"))
    static let structure = Int32(UInt8(ascii: "r"))
    static let dictEntry = Int32(UInt8(ascii: "e"))
}

indirect enum DBusValue {
    case byte(UInt8)
    case boolean(Bool)
    case int16(Int16)
    case uint16(UInt16)
    case int32(Int32)
    case uint32(UInt32)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case string(String)
    case objectPath(String)
    case signature(String)
    case unixFD(Int32)
    case array(element: String, items: [DBusValue])
    case structure([DBusValue])
    case dictEntry(DBusValue, DBusValue)
    case variant(DBusValue)

    static func dictionary(_ pairs: [(String, DBusValue)]) -> DBusValue {
        .array(element: "{sv}",
               items: pairs.map { .dictEntry(.string($0.0), .variant($0.1)) })
    }

    static func strings(_ values: [String]) -> DBusValue {
        .array(element: "s", items: values.map { .string($0) })
    }

    var typeSignature: String {
        switch self {
        case .byte: return "y"
        case .boolean: return "b"
        case .int16: return "n"
        case .uint16: return "q"
        case .int32: return "i"
        case .uint32: return "u"
        case .int64: return "x"
        case .uint64: return "t"
        case .double: return "d"
        case .string: return "s"
        case .objectPath: return "o"
        case .signature: return "g"
        case .unixFD: return "h"
        case .array(let element, _): return "a" + element
        case .structure(let fields): return "(" + fields.map(\.typeSignature).joined() + ")"
        case .dictEntry(let key, let value): return "{\(key.typeSignature)\(value.typeSignature)}"
        case .variant: return "v"
        }
    }

    var unwrapped: DBusValue {
        if case .variant(let inner) = self { return inner.unwrapped }
        return self
    }

    var stringValue: String? {
        switch unwrapped {
        case .string(let s), .objectPath(let s), .signature(let s): return s
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .boolean(let b) = unwrapped { return b }
        return nil
    }

    var uint16Value: UInt16? {
        switch unwrapped {
        case .uint16(let v): return v
        case .uint32(let v): return UInt16(clamping: v)
        case .int32(let v): return UInt16(clamping: v)
        default: return nil
        }
    }

    var fdValue: Int32? {
        if case .unixFD(let fd) = unwrapped { return fd }
        return nil
    }

    var items: [DBusValue]? {
        switch unwrapped {
        case .array(_, let items): return items
        case .structure(let fields): return fields
        default: return nil
        }
    }

    var stringArray: [String]? {
        guard let items else { return nil }
        return items.compactMap(\.stringValue)
    }

    var dictionaryValue: [String: DBusValue]? {
        guard let items else { return nil }
        var out: [String: DBusValue] = [:]
        for item in items {
            guard case .dictEntry(let key, let value) = item.unwrapped,
                  let name = key.stringValue else { continue }
            out[name] = value.unwrapped
        }
        return out
    }
}

final class DBusMessage {
    let handle: OpaquePointer

    init(adopting handle: OpaquePointer) {
        self.handle = handle
    }

    init(retaining handle: OpaquePointer) {
        _ = dbus_message_ref(handle)
        self.handle = handle
    }

    deinit { dbus_message_unref(handle) }

    static func methodCall(destination: String, path: String,
                           interface: String, method: String) -> DBusMessage? {
        guard let raw = dbus_message_new_method_call(destination, path, interface, method) else {
            return nil
        }
        return DBusMessage(adopting: raw)
    }

    var interface: String { DBusMessage.text(dbus_message_get_interface(handle)) }
    var member: String { DBusMessage.text(dbus_message_get_member(handle)) }
    var path: String { DBusMessage.text(dbus_message_get_path(handle)) }

    private static func text(_ pointer: UnsafePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        return String(cString: pointer)
    }

    func append(_ values: [DBusValue]) {
        var iter = DBusMessageIter()
        dbus_message_iter_init_append(handle, &iter)
        withUnsafeMutablePointer(to: &iter) { p in
            for value in values { DBusMessage.append(value, to: p) }
        }
    }

    func arguments() -> [DBusValue] {
        var iter = DBusMessageIter()
        guard dbus_message_iter_init(handle, &iter) != 0 else { return [] }
        return withUnsafeMutablePointer(to: &iter) { DBusMessage.readAll($0) }
    }

    private static func append(_ value: DBusValue, to iter: UnsafeMutablePointer<DBusMessageIter>) {
        switch value {
        case .byte(let v): appendBasic(v, DBusType.byte, iter)
        case .boolean(let v): appendBasic(dbus_bool_t(v ? 1 : 0), DBusType.boolean, iter)
        case .int16(let v): appendBasic(v, DBusType.int16, iter)
        case .uint16(let v): appendBasic(v, DBusType.uint16, iter)
        case .int32(let v): appendBasic(v, DBusType.int32, iter)
        case .uint32(let v): appendBasic(v, DBusType.uint32, iter)
        case .int64(let v): appendBasic(v, DBusType.int64, iter)
        case .uint64(let v): appendBasic(v, DBusType.uint64, iter)
        case .double(let v): appendBasic(v, DBusType.double, iter)
        case .unixFD(let v): appendBasic(v, DBusType.unixFD, iter)
        case .string(let s): appendString(s, DBusType.string, iter)
        case .objectPath(let s): appendString(s, DBusType.objectPath, iter)
        case .signature(let s): appendString(s, DBusType.signature, iter)
        case .array(let element, let contents):
            appendContainer(DBusType.array, element, contents, iter)
        case .structure(let fields):
            appendContainer(DBusType.structure, nil, fields, iter)
        case .dictEntry(let key, let value):
            appendContainer(DBusType.dictEntry, nil, [key, value], iter)
        case .variant(let inner):
            appendContainer(DBusType.variant, inner.typeSignature, [inner], iter)
        }
    }

    private static func appendBasic<T>(_ value: T, _ type: Int32,
                                       _ iter: UnsafeMutablePointer<DBusMessageIter>) {
        withUnsafeBytes(of: value) { buffer in
            _ = dbus_message_iter_append_basic(iter, type, buffer.baseAddress)
        }
    }

    private static func appendString(_ value: String, _ type: Int32,
                                     _ iter: UnsafeMutablePointer<DBusMessageIter>) {
        value.withCString { raw in
            var pointer: UnsafePointer<CChar>? = raw
            _ = dbus_message_iter_append_basic(iter, type, &pointer)
        }
    }

    private static func appendContainer(_ type: Int32, _ signature: String?,
                                        _ contents: [DBusValue],
                                        _ iter: UnsafeMutablePointer<DBusMessageIter>) {
        var sub = DBusMessageIter()
        let opened: dbus_bool_t
        if let signature {
            opened = signature.withCString { dbus_message_iter_open_container(iter, type, $0, &sub) }
        } else {
            opened = dbus_message_iter_open_container(iter, type, nil, &sub)
        }
        guard opened != 0 else { return }
        withUnsafeMutablePointer(to: &sub) { p in
            for value in contents { append(value, to: p) }
        }
        _ = dbus_message_iter_close_container(iter, &sub)
    }

    private static func readAll(_ iter: UnsafeMutablePointer<DBusMessageIter>) -> [DBusValue] {
        var out: [DBusValue] = []
        while dbus_message_iter_get_arg_type(iter) != DBusType.invalid {
            if let value = read(iter) { out.append(value) }
            dbus_message_iter_next(iter)
        }
        return out
    }

    private static func read(_ iter: UnsafeMutablePointer<DBusMessageIter>) -> DBusValue? {
        switch dbus_message_iter_get_arg_type(iter) {
        case DBusType.byte:
            return .byte(readBasic(iter, UInt8.self))
        case DBusType.boolean:
            return .boolean(readBasic(iter, dbus_bool_t.self) != 0)
        case DBusType.int16:
            return .int16(readBasic(iter, Int16.self))
        case DBusType.uint16:
            return .uint16(readBasic(iter, UInt16.self))
        case DBusType.int32:
            return .int32(readBasic(iter, Int32.self))
        case DBusType.uint32:
            return .uint32(readBasic(iter, UInt32.self))
        case DBusType.int64:
            return .int64(readBasic(iter, Int64.self))
        case DBusType.uint64:
            return .uint64(readBasic(iter, UInt64.self))
        case DBusType.double:
            return .double(readBasic(iter, Double.self))
        case DBusType.unixFD:
            let raw = readBasic(iter, Int32.self)
            return .unixFD(raw < 0 ? raw : dup(raw))
        case DBusType.string:
            return .string(readString(iter))
        case DBusType.objectPath:
            return .objectPath(readString(iter))
        case DBusType.signature:
            return .signature(readString(iter))
        case DBusType.array:
            var sub = DBusMessageIter()
            dbus_message_iter_recurse(iter, &sub)
            var element = ""
            if let raw = dbus_message_iter_get_signature(&sub) {
                element = String(cString: raw)
                dbus_free(raw)
            }
            let contents = withUnsafeMutablePointer(to: &sub) { readAll($0) }
            if element.isEmpty {
                element = contents.first?.typeSignature
                    ?? basicSignature(dbus_message_iter_get_element_type(iter))
            }
            return .array(element: element, items: contents)
        case DBusType.structure:
            return .structure(readContainer(iter))
        case DBusType.dictEntry:
            let contents = readContainer(iter)
            guard contents.count == 2 else { return nil }
            return .dictEntry(contents[0], contents[1])
        case DBusType.variant:
            guard let inner = readContainer(iter).first else { return nil }
            return .variant(inner)
        default:
            return nil
        }
    }

    private static func readContainer(_ iter: UnsafeMutablePointer<DBusMessageIter>) -> [DBusValue] {
        var sub = DBusMessageIter()
        dbus_message_iter_recurse(iter, &sub)
        return withUnsafeMutablePointer(to: &sub) { readAll($0) }
    }

    private static func readBasic<T>(_ iter: UnsafeMutablePointer<DBusMessageIter>,
                                     _ type: T.Type) -> T {
        var storage = [UInt8](repeating: 0, count: MemoryLayout<T>.size)
        return storage.withUnsafeMutableBytes { buffer -> T in
            dbus_message_iter_get_basic(iter, buffer.baseAddress)
            return buffer.loadUnaligned(as: T.self)
        }
    }

    private static func readString(_ iter: UnsafeMutablePointer<DBusMessageIter>) -> String {
        var pointer: UnsafePointer<CChar>?
        dbus_message_iter_get_basic(iter, &pointer)
        guard let pointer else { return "" }
        return String(cString: pointer)
    }

    private static func basicSignature(_ type: Int32) -> String {
        guard type > 0, type < 128 else { return "" }
        return String(UnicodeScalar(UInt8(type)))
    }
}

private let dbusSignalFilter: DBusHandleMessageFunction = { _, message, data in
    guard let message, let data else { return DBUS_HANDLER_RESULT_NOT_YET_HANDLED }
    guard dbus_message_get_type(message) == DBUS_MESSAGE_TYPE_SIGNAL else {
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED
    }
    let connection = Unmanaged<DBusConnection>.fromOpaque(data).takeUnretainedValue()
    let wrapped = DBusMessage(retaining: message)
    connection.deliver(DBusSignal(path: wrapped.path,
                                  interface: wrapped.interface,
                                  member: wrapped.member,
                                  arguments: wrapped.arguments()))
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED
}

struct DBusSignal {
    let path: String
    let interface: String
    let member: String
    let arguments: [DBusValue]
}

final class DBusConnection {
    private let handle: OpaquePointer
    private let lock = NSLock()
    private var handlers: [(DBusSignal) -> Void] = []
    private var pump: Thread?
    private var pumpStopped: DispatchSemaphore?
    private var running = false
    private var filterContext: UnsafeMutableRawPointer?

    static let defaultTimeoutMs: Int32 = 15_000

    init() throws {
        _ = dbus_threads_init_default()
        var error = DBusError()
        dbus_error_init(&error)
        defer { dbus_error_free(&error) }
        guard let handle = dbus_bus_get_private(DBUS_BUS_SYSTEM, &error) else {
            throw DBusConnection.failure(&error, fallback: "cannot reach the system bus")
        }
        dbus_connection_set_exit_on_disconnect(handle, 0)
        self.handle = handle
    }

    deinit {
        stopSignalPump()
        dbus_connection_close(handle)
        dbus_connection_unref(handle)
    }

    private static func failure(_ error: UnsafeMutablePointer<DBusError>,
                                fallback: String) -> DBusCallError {
        let name = error.pointee.name.map { String(cString: $0) } ?? ""
        let message = error.pointee.message.map { String(cString: $0) } ?? ""
        return DBusCallError(name: name, message: message.isEmpty ? fallback : message)
    }

    func call(destination: String, path: String, interface: String, method: String,
              arguments: [DBusValue] = [],
              timeoutMs: Int32 = DBusConnection.defaultTimeoutMs) throws -> [DBusValue] {
        guard let message = DBusMessage.methodCall(destination: destination, path: path,
                                                   interface: interface, method: method) else {
            throw DBusCallError(name: "", message: "out of memory building \(interface).\(method)")
        }
        message.append(arguments)
        var error = DBusError()
        dbus_error_init(&error)
        defer { dbus_error_free(&error) }
        guard let raw = dbus_connection_send_with_reply_and_block(handle, message.handle,
                                                                  timeoutMs, &error) else {
            throw DBusConnection.failure(&error, fallback: "\(interface).\(method) failed")
        }
        return DBusMessage(adopting: raw).arguments()
    }

    func managedObjects(destination: String) throws -> [String: [String: [String: DBusValue]]] {
        let reply = try call(destination: destination, path: "/",
                             interface: "org.freedesktop.DBus.ObjectManager",
                             method: "GetManagedObjects")
        guard let root = reply.first?.items else { return [:] }
        var out: [String: [String: [String: DBusValue]]] = [:]
        for entry in root {
            guard case .dictEntry(let pathValue, let interfacesValue) = entry.unwrapped,
                  let objectPath = pathValue.stringValue,
                  let interfaces = interfacesValue.unwrapped.items else { continue }
            var byInterface: [String: [String: DBusValue]] = [:]
            for pair in interfaces {
                guard case .dictEntry(let nameValue, let propsValue) = pair.unwrapped,
                      let name = nameValue.stringValue,
                      let props = propsValue.unwrapped.dictionaryValue else { continue }
                byInterface[name] = props
            }
            out[objectPath] = byInterface
        }
        return out
    }

    func property(destination: String, path: String, interface: String,
                  name: String) throws -> DBusValue? {
        let reply = try call(destination: destination, path: path,
                             interface: "org.freedesktop.DBus.Properties",
                             method: "Get",
                             arguments: [.string(interface), .string(name)])
        return reply.first?.unwrapped
    }

    func setProperty(destination: String, path: String, interface: String,
                     name: String, value: DBusValue) throws {
        _ = try call(destination: destination, path: path,
                     interface: "org.freedesktop.DBus.Properties",
                     method: "Set",
                     arguments: [.string(interface), .string(name), .variant(value)])
    }

    func addMatch(_ rule: String) throws {
        var error = DBusError()
        dbus_error_init(&error)
        defer { dbus_error_free(&error) }
        dbus_bus_add_match(handle, rule, &error)
        if dbus_error_is_set(&error) != 0 {
            throw DBusConnection.failure(&error, fallback: "cannot watch \(rule)")
        }
        dbus_connection_flush(handle)
    }

    func onSignal(_ handler: @escaping (DBusSignal) -> Void) {
        lock.lock()
        handlers.append(handler)
        lock.unlock()
    }

    fileprivate func deliver(_ signal: DBusSignal) {
        lock.lock()
        let current = handlers
        lock.unlock()
        for handler in current { handler(signal) }
    }

    func startSignalPump() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()

        let context = Unmanaged.passUnretained(self).toOpaque()
        filterContext = context
        _ = dbus_connection_add_filter(handle, dbusSignalFilter, context, nil)

        let stopped = DispatchSemaphore(value: 0)
        pumpStopped = stopped
        let thread = Thread { [weak self] in
            defer { stopped.signal() }
            guard let self else { return }
            while self.isRunning {
                if dbus_connection_read_write_dispatch(self.handle, 200) == 0 { break }
            }
        }
        thread.name = "qudelix.dbus"
        thread.stackSize = 512 * 1024
        pump = thread
        thread.start()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func stopSignalPump() {
        lock.lock()
        let wasRunning = running
        running = false
        handlers = []
        lock.unlock()
        guard wasRunning else { return }
        _ = pumpStopped?.wait(timeout: .now() + 2)
        pumpStopped = nil
        if let filterContext {
            dbus_connection_remove_filter(handle, dbusSignalFilter, filterContext)
        }
        filterContext = nil
        pump = nil
    }
}
#endif
