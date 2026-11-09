import Foundation

package struct AutostartFile {
    package static let fileName = AppInfo.identifier + ".desktop"

    package var configHome: URL
    package var executable: String

    package init(configHome: URL, executable: String = AutostartFile.runningExecutable()) {
        self.configHome = configHome
        self.executable = executable
    }

    package static func runningExecutable(link: String = "/proc/self/exe") -> String {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link),
              target.hasPrefix("/"), !target.hasSuffix(" (deleted)") else {
            return AppInfo.executable
        }
        return target
    }

    package static func execArgument(_ path: String) -> String {
        let special = Set(" \t\n\"'\\><~|&;$*?#()`")
        guard path.contains(where: { special.contains($0) }) else {
            return path.replacingOccurrences(of: "%", with: "%%")
        }
        var quoted = ""
        for character in path {
            if "\"`$\\".contains(character) { quoted.append("\\") }
            quoted.append(character)
        }
        let escaped = quoted.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "%%")
        return "\"" + escaped + "\""
    }

    package static func system(environment: [String: String] = ProcessInfo.processInfo.environment,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               executable: String = AutostartFile.runningExecutable()) -> AutostartFile {
        AutostartFile(configHome: XDGDirectory.config(environment: environment, home: home),
                      executable: executable)
    }

    package var url: URL {
        configHome
            .appendingPathComponent("autostart", isDirectory: true)
            .appendingPathComponent(Self.fileName)
    }

    package var contents: String {
        [
            "[Desktop Entry]",
            "Type=Application",
            "Name=\(AppInfo.name)",
            "Comment=Qudelix 5K companion",
            "Exec=\(Self.execArgument(executable)) --hidden",
            "Icon=\(AppInfo.identifier)",
            "Terminal=false",
            "X-GNOME-Autostart-enabled=true",
            ""
        ].joined(separator: "\n")
    }

    package var isEnabled: Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains("X-GNOME-Autostart-enabled=false") || lines.contains("Hidden=true") { return false }
        return lines.contains { $0.hasPrefix("Exec=") }
    }

    package func enable() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    package func disable() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    @discardableResult
    package func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try enable() } else { try disable() }
            return true
        } catch {
            DebugLog.shared.log("autostart change failed: \(error.localizedDescription)")
            return false
        }
    }
}
