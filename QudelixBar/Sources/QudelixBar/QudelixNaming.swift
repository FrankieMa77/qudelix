import Foundation

extension QudelixController {
    nonisolated static func exportToken(for filter: QxFilter) -> String? {
        switch filter {
        case .peak: return "PK"
        case .lowShelf: return "LSC"
        case .highShelf: return "HSC"
        case .lpf: return "LPQ"
        case .hpf: return "HPQ"
        case .bypass: return nil
        }
    }

    static let presetCount = QxEq.presetCount

    nonisolated static let maxPresetNameLength = 32

    nonisolated static func displayName(_ s: String,
                                        limit: Int = maxPresetNameLength) -> String {
        let s = SafeText.scrubbed(
            String(String.UnicodeScalarView(s.unicodeScalars.prefix(limit * 4))),
            limit: limit * 4)
        let kept = s.unicodeScalars.filter { u in
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
        return String(String.UnicodeScalarView(kept))
            .trimmingCharacters(in: .whitespaces)
            .prefix(limit)
            .trimmingCharacters(in: .whitespaces)
    }

    static let maxImportBytes = 1_000_000

    nonisolated static func exportText(bands: [QxEqBandValue], preGain: Double,
                                       mutedBands: [Int: QxFilter] = [:]) -> String {
        var lines = [String(format: "Preamp: %.1f dB", preGain)]
        for (i, b) in bands.enumerated() {
            let shape = b.filter == .bypass ? (mutedBands[i] ?? .bypass) : b.filter
            guard let token = exportToken(for: shape) else { continue }
            lines.append(String(format: "Filter %d: ON %@ Fc %d Hz Gain %.1f dB Q %.2f",
                                i + 1, token, b.freq, b.gain, b.q))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated static func nameOnSave(source: String?, existing: String?,
                                       unchangedSinceSource: Bool) -> String? {
        guard unchangedSinceSource else { return nil }
        guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else { return nil }
        guard source != existing else { return nil }
        return source
    }
}
