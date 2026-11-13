#if os(Linux)
import Foundation

enum FiveKAddresses {
    static func matching(_ objects: BluezPresence.Objects) -> Set<String> {
        var found = Set<String>()
        for interfaces in objects.values {
            guard let device = interfaces[BluezLinkPlan.deviceInterface],
                  let name = device["Name"]?.stringValue,
                  name.lowercased().contains(BluezLinkPlan.nameMarker),
                  let address = device["Address"]?.stringValue else { continue }
            found.insert(AudioSink.normalizedAddress(address))
        }
        return found
    }

    static func system() -> Set<String>? {
        guard let objects = try? BluezPresence.system().managedObjects() else { return nil }
        return matching(objects)
    }
}
#endif
