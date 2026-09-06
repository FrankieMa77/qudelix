import Foundation

enum AICommand: CLIFamily {
    case unavailable

    static let name = "ai"
    static let usageLines: [String] = []

    static func parse(_ rest: [String]) throws -> AICommand {
        throw CLIUsageError(message: "ai is not available yet")
    }

    var needsDevice: Bool { false }
    var persistsToFlash: Bool { false }

    func run(options: CLIOptions, session: QxSession?) async throws {}
}
