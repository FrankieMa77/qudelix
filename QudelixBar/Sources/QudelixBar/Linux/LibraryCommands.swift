import Foundation

enum LibraryCommand: CLIFamily {
    case unavailable

    static let name = "library"
    static let usageLines: [String] = []

    static func parse(_ rest: [String]) throws -> LibraryCommand {
        throw CLIUsageError(message: "library is not available yet")
    }

    var needsDevice: Bool { false }
    var persistsToFlash: Bool { false }

    func run(options: CLIOptions, session: QxSession?) async throws {}
}
