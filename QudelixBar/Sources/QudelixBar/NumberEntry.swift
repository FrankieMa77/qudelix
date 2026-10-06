import Foundation

enum NumberEntry {
    struct Resolution<Value> {
        let display: String
        let change: Value?
    }

    static let frequencyRange = QxPacket.BandLimit.freq
    static let qRange = QxPacket.BandLimit.q
    static let gainRange = QxPacket.BandLimit.gain

    private static let spaceLike: Set<Character> = [
        " ", "\u{00A0}", "\u{2007}", "\u{2009}", "\u{202F}",
    ]

    private static let groupSeparators: Set<Character> = [" ", ".", ",", "'", "\u{2019}"]

    static func formatFrequency(_ hz: Int) -> String {
        String(hz)
    }

    static func formatQ(_ q: Double) -> String {
        String(format: "%.2f", q)
    }

    static func resolve<Value>(typed: String, shown: String,
                               parse: (String) -> Value?,
                               format: (Value) -> String) -> Resolution<Value> {
        guard typed != shown, let value = parse(typed) else {
            return Resolution(display: shown, change: nil)
        }
        let canonical = format(value)
        guard canonical != shown else { return Resolution(display: shown, change: nil) }
        return Resolution(display: canonical, change: value)
    }

    static func parseQ(_ text: String) -> Double? {
        guard let raw = parseDecimal(text), qRange.contains(raw) else { return nil }
        return (raw * 100).rounded() / 100
    }

    static func parseGain(_ text: String) -> Double? {
        guard let raw = parseDecimal(text), gainRange.contains(raw) else { return nil }
        let tenths = (raw * 10).rounded() / 10
        return tenths == 0 ? 0 : tenths
    }

    static func parseFrequency(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = String(trimmed.map { spaceLike.contains($0) ? " " : $0 })
        guard let first = normalized.first, isDigit(first) || first == "." || first == ","
        else { return nil }
        if normalized.allSatisfy(isDigit) {
            return Int(normalized).flatMap(inFrequencyRange)
        }
        if let grouped = groupedInteger(normalized), frequencyRange.contains(grouped) {
            return grouped
        }
        guard let value = parseDecimal(normalized), value == value.rounded(),
              let whole = Int(exactly: value) else { return nil }
        return inFrequencyRange(whole)
    }

    static func parseDecimal(_ text: String) -> Double? {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var sign = 1.0
        if let first = body.first, first == "+" || first == "-" || first == "\u{2212}" {
            if first != "+" { sign = -1 }
            body = body.dropFirst()
        }
        var whole = ""
        var fraction = ""
        var seenMark = false
        for character in body {
            if isDigit(character) {
                if seenMark { fraction.append(character) } else { whole.append(character) }
            } else if character == "." || character == "," {
                if seenMark { return nil }
                seenMark = true
            } else {
                return nil
            }
        }
        guard !whole.isEmpty || !fraction.isEmpty else { return nil }
        let literal = (whole.isEmpty ? "0" : whole) + "." + (fraction.isEmpty ? "0" : fraction)
        guard let value = Double(literal), value.isFinite else { return nil }
        return sign * value
    }

    private static func groupedInteger(_ text: String) -> Int? {
        guard let separator = text.first(where: { !isDigit($0) }),
              groupSeparators.contains(separator) else { return nil }
        let parts = text.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count >= 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isDigit) }),
              (1...3).contains(parts[0].count), parts[0].first != "0",
              parts.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        return Int(parts.joined())
    }

    private static func inFrequencyRange(_ hz: Int) -> Int? {
        frequencyRange.contains(hz) ? hz : nil
    }

    private static func isDigit(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        return ascii >= 48 && ascii <= 57
    }
}
