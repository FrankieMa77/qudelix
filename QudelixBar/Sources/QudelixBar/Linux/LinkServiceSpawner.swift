#if os(Linux)
import Foundation
import Glibc

enum LinkServiceSpawner {
    static let binaryName = "qudelix"

    static func runningExecutable() -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = readlink("/proc/self/exe", &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        buffer[count] = 0
        return String(cString: buffer)
    }

    static let deletedSuffix = " (deleted)"

    static func peerExecutable(_ descriptor: Int32) -> String? {
        guard let pid = LinkServiceSocket.peerProcessID(descriptor) else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = readlink("/proc/\(pid)/exe", &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        buffer[count] = 0
        return String(cString: buffer)
    }

    static func isReplaced(peerExecutable executable: String?) -> Bool {
        executable?.hasSuffix(deletedSuffix) ?? false
    }

    static func locateBinary(
        executable: String? = runningExecutable(),
        searchPath: String? = ProcessInfo.processInfo.environment["PATH"],
        isExecutable: (String) -> Bool = { access($0, X_OK) == 0 }
    ) -> String? {
        var candidates: [String] = []
        if let executable {
            let directory = (executable as NSString).deletingLastPathComponent
            candidates.append((directory as NSString).appendingPathComponent(binaryName))
        }
        for directory in (searchPath ?? "").split(separator: ":") where directory.hasPrefix("/") {
            candidates.append((String(directory) as NSString).appendingPathComponent(binaryName))
        }
        return candidates.first { isExecutable($0) }
    }

    static func serviceSpawner(binary: String) -> () -> Bool {
        { spawnDetached(binary: binary, arguments: ["link-service"], waitForChild: true) }
    }

    @discardableResult
    static func spawnDetached(binary: String, arguments: [String], waitForChild: Bool) -> Bool {
        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        closeInheritedDescriptors(&actions)

        var attributes = posix_spawnattr_t()
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(0x80))

        var argv: [UnsafeMutablePointer<CChar>?] = ([binary] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv { free(pointer) } }

        var child: pid_t = 0
        let status = posix_spawn(&child, binary, &actions, &attributes, argv, environ)
        guard status == 0 else {
            Trace.log("service spawn failed: " + String(cString: strerror(status)))
            return false
        }
        guard waitForChild else { return true }
        var wait: Int32 = 0
        while waitpid(child, &wait, 0) < 0 && errno == EINTR {}
        return true
    }

    private typealias CloseFrom = @convention(c) (UnsafeMutablePointer<posix_spawn_file_actions_t>?, Int32) -> Int32

    private static func closeInheritedDescriptors(_ actions: inout posix_spawn_file_actions_t) {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: 0),
                                 "posix_spawn_file_actions_addclosefrom_np") else { return }
        let function = unsafeBitCast(symbol, to: CloseFrom.self)
        _ = function(&actions, 3)
    }
}

enum LinkServiceCommand {
    static func run(_ arguments: [String]) -> Int32 {
        switch arguments {
        case []:
            guard let executable = LinkServiceSpawner.runningExecutable(),
                  LinkServiceSpawner.spawnDetached(binary: executable,
                                                   arguments: ["link-service", "--foreground"],
                                                   waitForChild: false) else {
                return CLIExit.deviceError
            }
            return CLIExit.ok
        case ["--foreground"]:
            guard let path = LinkServicePaths.socketPath() else {
                Trace.log("service: no socket path is available; exiting")
                return CLIExit.deviceError
            }
            let service = LinkService(socketPath: path, lockURL: LinkServicePaths.lockURL,
                                      makeTransport: { BluezTransport() }, handlesSignals: true)
            return service.run()
        default:
            return CLIExit.usageError
        }
    }
}
#endif
