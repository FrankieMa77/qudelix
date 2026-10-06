import Foundation

enum SafeText {
    static let defaultLimit = 160

    static func scrubbed(_ raw: String, limit: Int = defaultLimit) -> String {
        var out = String.UnicodeScalarView()
        var kept = 0
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0..<0x20, 0x7F...0x9F, 0x2028, 0x2029,
                 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0xFEFF,
                 0xE0000...0xE007F, 0x00AD, 0x061C, 0xFE00...0xFE0F,
                 0x115F, 0x1160, 0x3164:
                continue
            default:
                break
            }
            if kept == limit { return String(out) + "…" }
            out.append(scalar)
            kept += 1
        }
        return String(out)
    }
}
