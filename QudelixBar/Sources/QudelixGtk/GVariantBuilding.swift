import CGtk
import Foundation

package enum GV {
    package static func string(_ value: String) -> OpaquePointer { g_variant_new_string(value) }

    package static func int32(_ value: Int32) -> OpaquePointer { g_variant_new_int32(value) }

    package static func uint32(_ value: UInt32) -> OpaquePointer { g_variant_new_uint32(value) }

    package static func bool(_ value: Bool) -> OpaquePointer { g_variant_new_boolean(value ? 1 : 0) }

    package static func objectPath(_ value: String) -> OpaquePointer { g_variant_new_object_path(value) }

    package static func variant(_ value: OpaquePointer) -> OpaquePointer { g_variant_new_variant(value) }

    package static func tuple(_ children: [OpaquePointer]) -> OpaquePointer {
        var items: [OpaquePointer?] = children
        return items.withUnsafeMutableBufferPointer { g_variant_new_tuple($0.baseAddress, gsize($0.count)) }
    }

    package static func array(of elementType: String, _ children: [OpaquePointer]) -> OpaquePointer {
        let type = g_variant_type_new(elementType)
        defer { g_variant_type_free(type) }
        var items: [OpaquePointer?] = children
        return items.withUnsafeMutableBufferPointer { g_variant_new_array(type, $0.baseAddress, gsize($0.count)) }
    }

    package static func dict(_ pairs: [(String, OpaquePointer)]) -> OpaquePointer {
        array(of: "{sv}", pairs.map { g_variant_new_dict_entry(string($0.0), variant($0.1)) })
    }

    package static func stringArray(_ values: [String]) -> OpaquePointer {
        array(of: "s", values.map(string))
    }

    package static func child(_ value: OpaquePointer, _ index: Int) -> OpaquePointer? {
        guard index < Int(g_variant_n_children(value)) else { return nil }
        return g_variant_get_child_value(value, gsize(index))
    }

    package static func readInt32(_ value: OpaquePointer, _ index: Int) -> Int32? {
        guard let item = child(value, index) else { return nil }
        defer { g_variant_unref(item) }
        return g_variant_get_int32(item)
    }

    package static func readUInt32(_ value: OpaquePointer, _ index: Int) -> UInt32? {
        guard let item = child(value, index) else { return nil }
        defer { g_variant_unref(item) }
        return g_variant_get_uint32(item)
    }

    package static func readString(_ value: OpaquePointer, _ index: Int) -> String? {
        guard let item = child(value, index) else { return nil }
        defer { g_variant_unref(item) }
        return text(item)
    }

    package static func text(_ value: OpaquePointer) -> String? {
        g_variant_get_string(value, nil).map { String(cString: $0) }
    }

    package static func strings(_ value: OpaquePointer) -> [String] {
        (0..<Int(g_variant_n_children(value))).compactMap { index in
            guard let item = g_variant_get_child_value(value, gsize(index)) else { return nil }
            defer { g_variant_unref(item) }
            return text(item)
        }
    }

    package static func int32s(_ value: OpaquePointer) -> [Int32] {
        (0..<Int(g_variant_n_children(value))).compactMap { index in
            guard let item = g_variant_get_child_value(value, gsize(index)) else { return nil }
            defer { g_variant_unref(item) }
            return g_variant_get_int32(item)
        }
    }

    package static func printed(_ value: OpaquePointer) -> String {
        guard let raw = g_variant_print(value, 0) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw)
    }
}
