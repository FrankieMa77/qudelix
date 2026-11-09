import Foundation

enum XDGDirectory {
    static func resolve(_ variable: String,
                        fallback: [String],
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let value = environment[variable], value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return fallback.reduce(home) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    static func config(environment: [String: String] = ProcessInfo.processInfo.environment,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        resolve("XDG_CONFIG_HOME", fallback: [".config"], environment: environment, home: home)
    }

    static func data(environment: [String: String] = ProcessInfo.processInfo.environment,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        resolve("XDG_DATA_HOME", fallback: [".local", "share"], environment: environment, home: home)
    }

    static func state(environment: [String: String] = ProcessInfo.processInfo.environment,
                      home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        resolve("XDG_STATE_HOME", fallback: [".local", "state"], environment: environment, home: home)
    }
}
