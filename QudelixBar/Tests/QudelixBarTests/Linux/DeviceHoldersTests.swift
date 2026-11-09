import XCTest
@testable import QudelixBar

final class DeviceHoldersTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("holders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    private func process(_ pid: Int32, comm: String?, holding targets: [String]) throws {
        let directory = root.appendingPathComponent("\(pid)/fd", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, target) in targets.enumerated() {
            try FileManager.default.createSymbolicLink(
                atPath: directory.appendingPathComponent("\(index + 3)").path,
                withDestinationPath: target)
        }
        if let comm {
            try (comm + "\n").write(to: root.appendingPathComponent("\(pid)/comm"),
                                    atomically: true, encoding: .utf8)
        }
    }

    func testHoldersAreFoundByTheirDescriptorsWithTrimmedNames() throws {
        try process(100, comm: "qudelix-app", holding: ["/dev/null", "/dev/hidraw3"])
        try process(200, comm: "qudelix", holding: ["/dev/hidraw4"])
        try process(300, comm: "bash", holding: ["/dev/pts/1"])
        try process(400, comm: nil, holding: ["/dev/hidraw3"])
        let found = DeviceHolders.find(devicePaths: ["/dev/hidraw3", "/dev/hidraw4"],
                                       procRoot: root.path)
        XCTAssertEqual(found, [DeviceHolder(pid: 100, comm: "qudelix-app"),
                               DeviceHolder(pid: 200, comm: "qudelix"),
                               DeviceHolder(pid: 400, comm: "")])
    }

    func testOurOwnProcessIsExcluded() throws {
        try process(getpid(), comm: "qudelix", holding: ["/dev/hidraw3"])
        try process(100, comm: "qudelix-app", holding: ["/dev/hidraw3"])
        let found = DeviceHolders.find(devicePaths: ["/dev/hidraw3"], procRoot: root.path)
        XCTAssertEqual(found.map(\.pid), [100])
    }

    func testUnreadableAndMalformedEntriesAreSkipped() throws {
        try process(100, comm: "qudelix-app", holding: ["/dev/hidraw3"])
        try process(200, comm: "qudelix", holding: ["/dev/hidraw3"])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: root.appendingPathComponent("200/fd").path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: root.appendingPathComponent("200/fd").path)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("self"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("300"), atomically: true, encoding: .utf8)
        let found = DeviceHolders.find(devicePaths: ["/dev/hidraw3"], procRoot: root.path)
        XCTAssertTrue(found.contains(DeviceHolder(pid: 100, comm: "qudelix-app")))
        XCTAssertFalse(found.contains { $0.pid == 300 })
        XCTAssertEqual(DeviceHolders.find(devicePaths: [], procRoot: root.path), [])
        XCTAssertEqual(DeviceHolders.find(devicePaths: ["/dev/hidraw3"],
                                          procRoot: root.appendingPathComponent("missing").path), [])
    }

    func testTheBusyTextNamesTheApp() {
        let lines = DeviceHolders.busyLines(
            holders: [DeviceHolder(pid: 42, comm: "qudelix-app")], isRoot: false)
        XCTAssertEqual(lines, ["the Qudelix app (pid 42) is connected to the 5K; it keeps running in the "
            + "top bar after its window is closed — quit it from the top-bar menu or the app menu, "
            + "then try again"])
    }

    func testTheBusyTextNamesAnotherCommand() {
        let lines = DeviceHolders.busyLines(
            holders: [DeviceHolder(pid: 7, comm: "qudelix")], isRoot: false)
        XCTAssertEqual(lines, ["another qudelix command (pid 7) is using the 5K — wait for it to finish"])
    }

    func testTheAppWinsWhenBothHold() {
        let lines = DeviceHolders.busyLines(
            holders: [DeviceHolder(pid: 7, comm: "qudelix"), DeviceHolder(pid: 42, comm: "qudelix-app")],
            isRoot: false)
        XCTAssertTrue(lines[0].hasPrefix("the Qudelix app (pid 42)"))
    }

    func testTheBusyTextWithoutAHolder() {
        let lines = DeviceHolders.busyLines(
            holders: [DeviceHolder(pid: 9, comm: "bash")], isRoot: false)
        XCTAssertEqual(lines, ["another qudelix command or the Qudelix app is using the 5K; the app keeps "
            + "running in the top bar after its window is closed — quit it there, then try again"])
        XCTAssertEqual(DeviceHolders.busyLines(holders: [], isRoot: false), lines)
    }

    func testRootGetsTheSudoLine() {
        let lines = DeviceHolders.busyLines(holders: [], isRoot: true)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1], "qudelix does not need sudo — the udev rule gives your user access to the 5K")
    }
}
