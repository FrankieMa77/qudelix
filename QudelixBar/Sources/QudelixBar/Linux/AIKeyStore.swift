#if os(Linux)
import Foundation

struct AIKeychain {
    enum Reading: Equatable {
        case key(String)
        case none
        case denied
    }

    static let environmentVariable = "QUDELIX_AI_KEY"

    static let shared = AIKeychain()

    static var fileURL: URL {
        let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        return configHome
            .appendingPathComponent("qudelix", isDirectory: true)
            .appendingPathComponent("ai-key")
    }

    func load(provider: String) -> Reading {
        if let fromEnvironment = ProcessInfo.processInfo
            .environment[Self.environmentVariable] {
            let clean = Self.printable(fromEnvironment)
            if !clean.isEmpty { return .key(clean) }
        }
        let url = Self.fileURL
        var status = stat()
        let mode: mode_t? = url.withUnsafeFileSystemRepresentation { path -> mode_t? in
            guard let path, lstat(path, &status) == 0 else { return nil }
            return status.st_mode
        }
        guard let mode, mode & S_IFMT == S_IFREG else { return .none }
        guard mode & 0o077 == 0 else { return .denied }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return .none }
        let clean = Self.printable(text)
        return clean.isEmpty ? .none : .key(clean)
    }

    @discardableResult
    func save(key: String, provider: String) -> Bool {
        let clean = Self.printable(key)
        guard !clean.isEmpty else { return false }
        let url = Self.fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        return (try? handle.write(contentsOf: Data((clean + "\n").utf8))) != nil
    }

    @discardableResult
    func delete(provider: String) -> Bool {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    func hasKey(provider: String) -> Bool {
        if case .key = load(provider: provider) { return true }
        return false
    }
}
#endif
