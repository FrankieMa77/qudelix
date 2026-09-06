import Foundation

extension QudelixController {
    /// The parametric-file token for a filter shape, or nil for one that has
    /// no representation in the format.
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

    /// Longest preset name the popover will show. The device's own field is
    /// bounded by the report size; this is about the row staying one line.
    nonisolated static let maxPresetNameLength = 32

    /// Names are stored on the device, so they are attacker-supplied in the
    /// same sense every other field is. Control and format scalars are dropped
    /// rather than escaped — a U+202E override would visually reorder the rows
    /// around it, and a newline would stretch the row.
    nonisolated static func displayName(_ s: String,
                                        limit: Int = maxPresetNameLength) -> String {
        // Bounded by scalars before anything else. The length cap below counts
        // Characters, and a grapheme cluster has no upper size — one letter
        // carrying a hundred combining marks is a single Character that
        // survives the cap intact and renders as a vertical smear over the
        // rows around it.
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

    /// EQ files are a few hundred bytes; refuse anything absurd rather than
    /// reading an arbitrary user-picked file entirely into memory.
    static let maxImportBytes = 1_000_000

    nonisolated static func exportText(bands: [QxEqBandValue], preGain: Double,
                                       mutedBands: [Int: QxFilter] = [:]) -> String {
        var lines = [String(format: "Preamp: %.1f dB", preGain)]
        for (i, b) in bands.enumerated() {
            // A muted band is still part of the user's curve — the mute is a
            // momentary A/B, so export its parked shape rather than dropping
            // the band and handing out a file with a filter silently missing.
            // A band that is bypassed with nothing parked really is empty.
            let shape = b.filter == .bypass ? (mutedBands[i] ?? .bypass) : b.filter
            guard let token = exportToken(for: shape) else { continue }
            lines.append(String(format: "Filter %d: ON %@ Fc %d Hz Gain %.1f dB Q %.2f",
                                i + 1, token, b.freq, b.gain, b.q))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The name a slot should take when the current curve is saved into it, or
    /// nil to leave whatever is there alone.
    ///
    /// A curve with a source — an import, an AutoEq fit — names the slot after
    /// it, because that is now what the slot contains. A hand-shaped curve has
    /// no name to offer, and clearing the slot's existing one would destroy
    /// something the user typed in exchange for nothing.
    nonisolated static func nameOnSave(source: String?, existing: String?,
                                       unchangedSinceSource: Bool) -> String? {
        // A curve that has been shaped since it arrived is no longer the thing
        // the name describes. Labelling a slot "HD 650" when it holds an hour
        // of by-ear tuning on top of HD 650 is worse than leaving it unnamed,
        // because the label would be believed.
        guard unchangedSinceSource else { return nil }
        guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else { return nil }
        // Re-saving a slot under the name it already has is a wasted write to
        // a device that stores it in flash.
        guard source != existing else { return nil }
        return source
    }
}
