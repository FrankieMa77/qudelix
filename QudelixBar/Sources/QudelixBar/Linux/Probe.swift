import Foundation
#if canImport(Glibc)
import Glibc
#endif

struct HidrawNode: Equatable {
    var name: String
    var devicePath: String
    var hidId: String?
    var hidName: String?
    var readable: Bool
    var writable: Bool

    var isQudelix: Bool {
        guard let hidId else { return false }
        let upper = hidId.uppercased()
        return upper.contains(Probe.vendorId) && upper.contains(Probe.productId)
    }
}

struct ProbeReport: Equatable {
    var kernelRelease: String
    var hidrawClassExists: Bool
    var nodes: [HidrawNode]
    var bluetoothctlVersion: String?
    var busctlPresent: Bool
    var bluezOnDBus: Bool?
    var logPath: String
}

struct ProbeEnvironment {
    var sysfsRoot: URL
    var devRoot: URL
    var logPath: String
    var kernelRelease: () -> String
    var readFile: (URL) -> String?
    var listDirectory: (URL) -> [String]
    var directoryExists: (URL) -> Bool
    var access: (String) -> (readable: Bool, writable: Bool)
    var runTool: (String, [String]) -> String?

    static func system() -> ProbeEnvironment {
        ProbeEnvironment(
            sysfsRoot: URL(fileURLWithPath: "/sys", isDirectory: true),
            devRoot: URL(fileURLWithPath: "/dev", isDirectory: true),
            logPath: DebugLog.shared.fileURL?.path ?? "(no log file)",
            kernelRelease: Probe.systemKernelRelease,
            readFile: { url in try? String(contentsOf: url, encoding: .utf8) },
            listDirectory: { url in
                ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
            },
            directoryExists: { url in
                var isDirectory: ObjCBool = false
                let there = FileManager.default.fileExists(atPath: url.path,
                                                           isDirectory: &isDirectory)
                return there && isDirectory.boolValue
            },
            access: Probe.systemAccess,
            runTool: Probe.runTool)
    }
}

enum Probe {
    static let vendorId = "0A12"
    static let productId = "4003"

    static func report(_ env: ProbeEnvironment) -> ProbeReport {
        let classRoot = env.sysfsRoot
            .appendingPathComponent("class", isDirectory: true)
            .appendingPathComponent("hidraw", isDirectory: true)
        let classExists = env.directoryExists(classRoot)
        var nodes: [HidrawNode] = []
        if classExists {
            for name in env.listDirectory(classRoot) where name.hasPrefix("hidraw") {
                let uevent = classRoot
                    .appendingPathComponent(name, isDirectory: true)
                    .appendingPathComponent("device", isDirectory: true)
                    .appendingPathComponent("uevent")
                let fields = parseUevent(env.readFile(uevent) ?? "")
                let devicePath = env.devRoot.appendingPathComponent(name).path
                let permission = env.access(devicePath)
                nodes.append(HidrawNode(name: name,
                                        devicePath: devicePath,
                                        hidId: fields["HID_ID"],
                                        hidName: fields["HID_NAME"],
                                        readable: permission.readable,
                                        writable: permission.writable))
            }
        }
        let bluetoothctl = env.runTool("bluetoothctl", ["--version"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let busctl = env.runTool("busctl", ["list", "--no-pager"])
        return ProbeReport(
            kernelRelease: env.kernelRelease(),
            hidrawClassExists: classExists,
            nodes: nodes,
            bluetoothctlVersion: (bluetoothctl?.isEmpty ?? true) ? nil : bluetoothctl,
            busctlPresent: busctl != nil,
            bluezOnDBus: busctl.map { $0.contains("org.bluez") },
            logPath: env.logPath)
    }

    static func parseUevent(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            fields[key] = value
        }
        return fields
    }

    static func lines(_ report: ProbeReport) -> [String] {
        var out = ["kernel        \(report.kernelRelease)"]
        out.append("hidraw class  \(report.hidrawClassExists ? "present" : "missing")")
        if report.nodes.isEmpty {
            out.append("hidraw nodes  none")
        } else {
            for node in report.nodes {
                out.append("hidraw node   \(node.devicePath)"
                    + (node.isQudelix ? "  [Qudelix 5K]" : ""))
                out.append("  HID_ID      \(node.hidId ?? "(none)")")
                out.append("  HID_NAME    \(node.hidName.map(DebugLog.sanitized) ?? "(none)")")
                out.append("  access      "
                    + (node.readable && node.writable
                        ? "read+write"
                        : "\(node.readable ? "read" : "no read")"
                          + ", \(node.writable ? "write" : "no write")"))
            }
        }
        out.append("bluetoothctl  \(report.bluetoothctlVersion ?? "not installed")")
        if !report.busctlPresent {
            out.append("org.bluez     unknown (busctl not installed)")
        } else {
            out.append("org.bluez     \(report.bluezOnDBus == true ? "on the system bus" : "not on the system bus")")
        }
        out.append("log           \(report.logPath)")
        return out
    }

    static func object(_ report: ProbeReport) -> [String: Any] {
        var object: [String: Any] = [
            "kernel_release": report.kernelRelease,
            "hidraw_class_exists": report.hidrawClassExists,
            "busctl_present": report.busctlPresent,
            "log_path": report.logPath,
            "hidraw_nodes": report.nodes.map { node -> [String: Any] in
                var entry: [String: Any] = [
                    "name": node.name,
                    "device_path": node.devicePath,
                    "readable": node.readable,
                    "writable": node.writable,
                    "is_qudelix": node.isQudelix,
                ]
                QxFormat.put(&entry, "hid_id", node.hidId)
                QxFormat.put(&entry, "hid_name", node.hidName)
                return entry
            },
        ]
        QxFormat.put(&object, "bluetoothctl_version", report.bluetoothctlVersion)
        QxFormat.put(&object, "bluez_on_dbus", report.bluezOnDBus)
        return object
    }

    static func permissionAdvice(_ report: ProbeReport) -> String? {
        let blocked = report.nodes.filter { $0.isQudelix && !($0.readable && $0.writable) }
        guard !blocked.isEmpty else { return nil }
        let paths = blocked.map(\.devicePath).joined(separator: ", ")
        return "permission denied opening \(paths) — install the udev rule "
            + "(/etc/udev/rules.d/70-qudelix.rules), run "
            + "'sudo udevadm control --reload-rules && sudo udevadm trigger', "
            + "then unplug and replug the device"
    }

    static func systemKernelRelease() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        let size = MemoryLayout.size(ofValue: info.release)
        return withUnsafePointer(to: &info.release) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: size) { String(cString: $0) }
        }
    }

    static func systemAccess(_ path: String) -> (readable: Bool, writable: Bool) {
        (FileManager.default.isReadableFile(atPath: path),
         FileManager.default.isWritableFile(atPath: path))
    }

    static func runTool(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
