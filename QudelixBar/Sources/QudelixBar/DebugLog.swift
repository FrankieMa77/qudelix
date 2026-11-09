import Foundation

final class DebugLog: ObservableObject {
    static let shared = DebugLog()
    @Published private(set) var lines: [String] = []
    static let timestampFormat = "yyyy-MM-dd HH:mm:ss.SSS"

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = DebugLog.timestampFormat
        return f
    }()

    private(set) var fileURL: URL?

    private let file: AppendingLog?

    static let maxLogBytes = 2_000_000

#if os(Linux)
    private static let testRunnerNames = [".xctest", "-test-runner", "xctest"]
#endif

    static var runningUnderTests: Bool {
#if os(Linux)
        testRunnerNames.contains { ProcessInfo.processInfo.processName.hasSuffix($0) }
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
#else
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
#endif
    }

    static func logURL(underTests: Bool = runningUnderTests) -> URL? {
        if underTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("QudelixBar-tests.log")
        }
#if os(Linux)
        let dir = XDGDirectory.state().appendingPathComponent("qudelix", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("qudelix.log")
#else
        guard let logs = try? FileManager.default.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("Logs", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("QudelixBar.log")
#endif
    }

    private init() {
        let url = Self.logURL()
        fileURL = url
        file = url.map { AppendingLog(url: $0, maxBytes: Self.maxLogBytes) }
    }

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

    func flush() {
        logQueue.sync {}
    }

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
    private let verifyEvery: TimeInterval
    private var handle: FileHandle?
    private var lastVerified = Date.distantPast

    private(set) var bytesWritten: Int

    init(url: URL, maxBytes: Int, verifyEvery: TimeInterval = 1) {
        self.url = url
        self.maxBytes = maxBytes
        self.verifyEvery = verifyEvery
        bytesWritten = Self.sizeOnDisk(url)
    }

    deinit { try? handle?.close() }

    func append(_ data: Data) {
        if bytesWritten > maxBytes { rotate() }
        dropHandleIfDetached()
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

    private func dropHandleIfDetached() {
        guard let handle else { return }
        let now = Date()
        guard now.timeIntervalSince(lastVerified) >= verifyEvery else { return }
        lastVerified = now
        guard !Self.descriptor(handle.fileDescriptor, isTheFileAt: url) else { return }
        close()
        bytesWritten = Self.sizeOnDisk(url)
    }

    static func descriptor(_ fd: Int32, isTheFileAt url: URL) -> Bool {
        var open = stat()
        guard fstat(fd, &open) == 0, open.st_nlink > 0 else { return false }
        var onDisk = stat()
        let present = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return lstat(path, &onDisk) == 0
        }
        return present && open.st_dev == onDisk.st_dev && open.st_ino == onDisk.st_ino
    }

    private static func sizeOnDisk(_ url: URL) -> Int {
        var st = stat()
        let present = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return lstat(path, &st) == 0
        }
        return present ? Int(st.st_size) : 0
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
