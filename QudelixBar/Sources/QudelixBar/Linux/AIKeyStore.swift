#if os(Linux)
import Foundation

struct AIKeychain {
    enum Reading: Equatable {
        case key(String)
        case none
        case denied
    }

    static let environmentVariable = "QUDELIX_AI_KEY"
    static let fileNamePrefix = "ai-key"
    static let maxKeyBytes = 4096

    static let shared = AIKeychain()

    let directory: URL
    let environment: [String: String]

    init(directory: URL? = nil, environment: [String: String]? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        self.environment = environment ?? ProcessInfo.processInfo.environment
    }

    static var defaultDirectory: URL {
        let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        return configHome.appendingPathComponent("qudelix", isDirectory: true)
    }

    private static func lstatMode(_ url: URL) -> mode_t? {
        var status = stat()
        return url.withUnsafeFileSystemRepresentation { path -> mode_t? in
            guard let path, lstat(path, &status) == 0 else { return nil }
            return status.st_mode
        }
    }

    private func prepareDirectory() {
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        switch Self.lstatMode(directory) {
        case let mode? where mode & S_IFMT == S_IFDIR:
            if mode & 0o777 != 0o700 {
                try? fm.setAttributes([.posixPermissions: 0o700],
                                      ofItemAtPath: directory.path)
            }
        case .some:
            let aside = parent.appendingPathComponent(
                directory.lastPathComponent
                    + ".displaced-\(Int(Date().timeIntervalSince1970))")
            try? fm.moveItem(at: directory, to: aside)
            Trace.log("key directory path was not a directory — moved aside as "
                + aside.lastPathComponent)
            fallthrough
        case nil:
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try? fm.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        }
    }

    static func slug(_ provider: String) -> String {
        let kept = provider.lowercased().unicodeScalars.filter {
            (0x61...0x7A).contains($0.value) || (0x30...0x39).contains($0.value)
        }
        let text = String(String.UnicodeScalarView(kept.prefix(32)))
        return text.isEmpty ? "unnamed" : text
    }

    static func environmentVariable(provider: String) -> String {
        environmentVariable + "_" + slug(provider).uppercased()
    }

    func url(provider: String) -> URL {
        directory.appendingPathComponent(Self.fileNamePrefix + "-" + Self.slug(provider))
    }

    func load(provider: String) -> Reading {
        for name in [Self.environmentVariable(provider: provider), Self.environmentVariable] {
            guard let raw = environment[name] else { continue }
            let clean = Self.printable(raw)
            if !clean.isEmpty { return .key(clean) }
        }
        let url = url(provider: provider)
        var status = stat()
        let mode: mode_t? = url.withUnsafeFileSystemRepresentation { path -> mode_t? in
            guard let path, lstat(path, &status) == 0 else { return nil }
            return status.st_mode
        }
        guard let mode, mode & S_IFMT == S_IFREG else { return .none }
        guard mode & 0o077 == 0 else { return .denied }
        guard let data = SafeFile.read(url, cap: Self.maxKeyBytes),
              let text = String(data: data, encoding: .utf8) else { return .none }
        let clean = Self.printable(text)
        return clean.isEmpty ? .none : .key(clean)
    }

    @discardableResult
    func save(key: String, provider: String) -> Bool {
        let clean = Self.printable(key)
        guard !clean.isEmpty else { return false }
        prepareDirectory()
        let url = url(provider: provider)
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            unlink(path)
            return open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard (try? handle.write(contentsOf: Data((clean + "\n").utf8))) != nil else {
            return false
        }
        return url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return chmod(path, 0o600) == 0
        }
    }

    @discardableResult
    func delete(provider: String) -> Bool {
        let url = url(provider: provider)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    func hasKey(provider: String) -> Bool {
        if case .key = load(provider: provider) { return true }
        return false
    }
}
#endif
