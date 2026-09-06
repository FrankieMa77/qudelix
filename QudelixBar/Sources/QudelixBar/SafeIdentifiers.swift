import Foundation

extension Notifier {
    nonisolated static let maxIdentifierLength = 64

    nonisolated static func identifier(_ prefix: String, _ raw: String = "") -> String {
        String((prefix + SafeText.scrubbed(raw, limit: maxIdentifierLength))
            .prefix(maxIdentifierLength))
    }
}

extension AIKeychain {
    static func printable(_ raw: String) -> String {
        let kept = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars.filter { (0x21...0x7E).contains($0.value) }
        return String(String.UnicodeScalarView(kept))
    }
}
