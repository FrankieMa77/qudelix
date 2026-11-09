import Foundation

struct DeviceHolder: Equatable {
    var pid: Int32
    var comm: String
}

enum DeviceHolders {
    static let defaultProcRoot = "/proc"

    static func find(devicePaths: [String], procRoot: String = defaultProcRoot) -> [DeviceHolder] {
        let wanted = Set(devicePaths)
        guard !wanted.isEmpty else { return [] }
        let own = getpid()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: procRoot)) ?? []
        var holders: [DeviceHolder] = []
        for entry in entries.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            guard let pid = Int32(entry), pid != own else { continue }
            let fdDirectory = "\(procRoot)/\(entry)/fd"
            guard let descriptors = try? FileManager.default.contentsOfDirectory(atPath: fdDirectory) else { continue }
            let holds = descriptors.contains { descriptor in
                guard let target = try? FileManager.default.destinationOfSymbolicLink(
                    atPath: "\(fdDirectory)/\(descriptor)") else { return false }
                return wanted.contains(target)
            }
            guard holds else { continue }
            let comm = (try? String(contentsOfFile: "\(procRoot)/\(entry)/comm", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            holders.append(DeviceHolder(pid: pid, comm: comm))
        }
        return holders
    }

    static func qudelixDevicePaths(report: ProbeReport) -> [String] {
        report.nodes.filter { $0.isQudelix }.map { $0.devicePath }
    }

    static func busyLines(holders: [DeviceHolder], isRoot: Bool) -> [String] {
        var lines: [String]
        if let app = holders.first(where: { $0.comm == "qudelix-app" }) {
            lines = ["the Qudelix app (pid \(app.pid)) is connected to the 5K; it keeps running in the "
                + "top bar after its window is closed — quit it from the top-bar menu or the app menu, "
                + "then try again"]
        } else if let cli = holders.first(where: { $0.comm == "qudelix" }) {
            lines = ["another qudelix command (pid \(cli.pid)) is using the 5K — wait for it to finish"]
        } else {
            lines = ["another qudelix command or the Qudelix app is using the 5K; the app keeps running "
                + "in the top bar after its window is closed — quit it there, then try again"]
        }
        if isRoot {
            lines.append("qudelix does not need sudo — the udev rule gives your user access to the 5K")
        }
        return lines
    }

    static func currentBusyLines() -> [String] {
        let paths = qudelixDevicePaths(report: Probe.report(.system()))
        return busyLines(holders: find(devicePaths: paths), isRoot: geteuid() == 0)
    }
}
