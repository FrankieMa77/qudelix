import Foundation

/// Ring-buffer debug log shown in the Diagnostics section of the popover.
final class DebugLog: ObservableObject {
    static let shared = DebugLog()
    @Published private(set) var lines: [String] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    /// ~/Library/Logs/QudelixBar.log. Resolved once in init — a `lazy var`
    /// would be touched from the main thread, the HID queue and URLSession
    /// tasks, and lazy initialization is not thread-safe.
    /// Where the packet log is written, for the diagnostics pane's Reveal
    /// button. Read-only: the path is decided once in `init` and nothing else
    /// gets to move it.
    private(set) var fileURL: URL?

    private let file: AppendingLog?

    static let maxLogBytes = 2_000_000

    private static func resolveFileURL() -> URL? {
        #if os(Linux)
        let stateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("state", isDirectory: true)
        let dir = stateHome.appendingPathComponent("qudelix", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("qudelix.log")
        #else
        let logs = try? FileManager.default.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("Logs", isDirectory: true)
        guard let logs else { return nil }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("QudelixBar.log")
        #endif
    }

    private init() {
        if let url = Self.resolveFileURL() {
            fileURL = url
            file = AppendingLog(url: url, maxBytes: Self.maxLogBytes)
        } else {
            fileURL = nil
            file = nil
        }
    }

    /// Escape anything that isn't safely printable on one line.
    ///
    /// Log lines carry strings the app did not author — USB product names,
    /// preset names stored on the device. A newline in one of those forges a
    /// whole log entry, and a bidi override reorders the line when it is read
    /// back, so both are rendered as escapes rather than acted on.
    static func sanitized(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                out += String(format: "\\u{%04X}", u.value)
            default:
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    func log(_ msg: String) {
        let line = "\(formatter.string(from: Date())) \(Self.sanitized(msg))"
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > 200 { self.lines.removeFirst(self.lines.count - 200) }
        }
        guard let file, let data = (line + "\n").data(using: .utf8) else { return }
        logQueue.async { file.append(data) }
    }

    private let logQueue = DispatchQueue(label: "qudelix.log")

    func tx(_ cmd: QxCmd, _ data: [UInt8]) {
        log("→ \(cmd) \(hex(data))")
    }

    func rx(_ cmdId: UInt16, _ data: [UInt8]) {
        let name = QxCmd(rawValue: cmdId).map { "\($0)" } ?? String(format: "0x%04X", cmdId)
        log("← \(name) \(hex(data))")
    }

    private func hex(_ b: [UInt8]) -> String {
        b.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
            + (b.count > 24 ? "…(\(b.count))" : "")
    }
}

final class AppendingLog {
    private let url: URL
    private let maxBytes: Int
    private var handle: FileHandle?

    private(set) var bytesWritten: Int

    init(url: URL, maxBytes: Int) {
        self.url = url
        self.maxBytes = maxBytes
        bytesWritten = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    deinit { try? handle?.close() }

    func append(_ data: Data) {
        if bytesWritten > maxBytes { rotate() }
        guard let handle = liveHandle() else { return }
        if (try? handle.write(contentsOf: data)) != nil {
            bytesWritten += data.count
        } else {
            close()
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    private func liveHandle() -> FileHandle? {
        if let handle { return handle }
        handle = openAppending()
        return handle
    }

    private func openAppending() -> FileHandle? {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func rotate() {
        close()
        let previous = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        bytesWritten = 0
    }
}
