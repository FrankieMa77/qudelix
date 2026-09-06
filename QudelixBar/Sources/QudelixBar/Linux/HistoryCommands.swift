import Foundation

enum HistoryCommand: CLIFamily {
    case unavailable

    static let name = "history"
    static let usageLines: [String] = []

    static func parse(_ rest: [String]) throws -> HistoryCommand {
        throw CLIUsageError(message: "history is not available yet")
    }

    var needsDevice: Bool { false }
    var persistsToFlash: Bool { false }

    func run(options: CLIOptions, session: QxSession?) async throws {}
}
