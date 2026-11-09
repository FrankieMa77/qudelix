import Foundation

enum DisplayFormat {
    static let minus = "\u{2212}"

    static func signed(_ value: Double, decimals: Int = 1) -> String {
        guard value.isFinite else { return "\u{2014}" }
        let rounded = String(format: "%.\(decimals)f", abs(value))
        let isZero = rounded.allSatisfy { $0 == "0" || $0 == "." }
        if isZero { return "+" + rounded }
        return (value < 0 ? minus : "+") + rounded
    }

    static func decibels(_ value: Double, decimals: Int = 1) -> String {
        signed(value, decimals: decimals) + " dB"
    }

    static func accessibleDecibels(_ value: Double) -> String {
        guard value.isFinite else { return "unknown" }
        let rounded = String(format: "%.1f", abs(value))
        let isZero = rounded.allSatisfy { $0 == "0" || $0 == "." }
        return (value < 0 && !isZero ? "minus " : "") + rounded + " decibels"
    }
}
