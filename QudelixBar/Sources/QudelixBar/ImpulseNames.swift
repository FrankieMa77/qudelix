import Foundation

extension ImpulseLimits {
    static let maxStoredNameLength = 96
    static let maxDisplayLength = 40
    static let allowedExtensions: Set<String> = ["wav", "wave", "aif", "aiff",
                                                 "aifc", "caf"]
}

extension IRLibrary {
    static func safeName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= ImpulseLimits.maxStoredNameLength,
              !raw.contains("/"), !raw.contains(".."), raw != ".", raw != ".."
        else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
                          + "0123456789._-")
        guard raw.allSatisfy({ allowed.contains($0) }) else { return nil }
        let ext = (raw as NSString).pathExtension.lowercased()
        guard ImpulseLimits.allowedExtensions.contains(ext) else { return nil }
        return raw
    }
}
