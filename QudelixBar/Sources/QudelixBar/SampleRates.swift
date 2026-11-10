import Foundation

extension AudioOutputs {
    static let fallbackRate: Double = 48000

    static func isPlausibleRate(_ rate: Double) -> Bool {
        rate.isFinite && (8000...768_000).contains(rate)
    }

    static func plausibleRate(_ rate: Double) -> Double {
        isPlausibleRate(rate) ? rate : fallbackRate
    }

    static let callModeCeilingHz: Double = 16000

    nonisolated static func rateChangeAllowed(bluetooth: Bool, rate: Double) -> Bool {
        !(bluetooth && rate <= callModeCeilingHz)
    }
}
