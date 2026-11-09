import Foundation

extension AudioOutputs {
    static let fullVolumeScalar: Float = 0.995

    static func trustedVolumeDb(db: Float?, scalar: @autoclosure () -> Float?) -> Float? {
        guard let db, EarLevel.plausibleVolumeDb.contains(Double(db)) else { return nil }
        guard db == 0, let scalar = scalar(),
              scalar.isFinite, scalar >= 0, scalar < fullVolumeScalar else { return db }
        return max(20 * log10f(scalar), Float(EarLevel.plausibleVolumeDb.lowerBound))
    }
}
