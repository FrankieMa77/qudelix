import CGtk

package protocol GPointer {
    var raw: UnsafeMutableRawPointer { get }
}

extension OpaquePointer: GPointer {
    package var raw: UnsafeMutableRawPointer { UnsafeMutableRawPointer(self) }
}

extension UnsafeMutablePointer: GPointer {
    package var raw: UnsafeMutableRawPointer { UnsafeMutableRawPointer(self) }
}

extension UnsafeMutableRawPointer: GPointer {
    package var raw: UnsafeMutableRawPointer { self }
}

extension GPointer {
    package var opaque: OpaquePointer { OpaquePointer(raw) }
    package func typed<T>(_ type: T.Type) -> UnsafeMutablePointer<T> { raw.assumingMemoryBound(to: type) }
    package var widget: UnsafeMutablePointer<GtkWidget> { raw.assumingMemoryBound(to: GtkWidget.self) }
    package var object: UnsafeMutablePointer<GObject> { raw.assumingMemoryBound(to: GObject.self) }
}
