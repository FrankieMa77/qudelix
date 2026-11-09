import XCTest
@testable import QudelixBar

final class LinuxPathsTests: XCTestCase {
    private var scratch: URL!
    private var savedData: String?
    private var savedState: String?

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("linux-paths-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        savedData = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        savedState = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
    }

    override func tearDownWithError() throws {
        restore("XDG_DATA_HOME", savedData)
        restore("XDG_STATE_HOME", savedState)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func restore(_ name: String, _ value: String?) {
        if let value { setenv(name, value, 1) } else { unsetenv(name) }
    }

    func testTheStateDirectoryFollowsXDGDataHomeAndIsPrivate() throws {
        setenv("XDG_DATA_HOME", scratch.path, 1)
        let directory = StageStateFile.directory
        XCTAssertEqual(directory.resolvingSymlinksInPath().path,
                       scratch.appendingPathComponent("QudelixBar").resolvingSymlinksInPath().path)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testTheLogLivesUnderXDGStateHome() {
        setenv("XDG_STATE_HOME", scratch.path, 1)
        let url = DebugLog.logURL(underTests: false)
        XCTAssertEqual(url?.resolvingSymlinksInPath().path,
                       scratch.appendingPathComponent("qudelix/qudelix.log")
                           .resolvingSymlinksInPath().path)
    }

    func testTheLogIsKeptOutOfTheRealStateFolderWhileTestsRun() {
        XCTAssertTrue(DebugLog.runningUnderTests)
        XCTAssertEqual(DebugLog.logURL()?.lastPathComponent, "QudelixBar-tests.log")
    }

    func testTheHelperIgnoresRelativeEmptyAndUnsetValues() {
        let home = URL(fileURLWithPath: "/home/someone", isDirectory: true)
        XCTAssertEqual(XDGDirectory.data(environment: ["XDG_DATA_HOME": "/srv/data"], home: home).path, "/srv/data")
        for value in ["data", "./data", "", "~/data", "../x"] {
            XCTAssertEqual(XDGDirectory.data(environment: ["XDG_DATA_HOME": value], home: home).path,
                           "/home/someone/.local/share", value)
        }
        XCTAssertEqual(XDGDirectory.data(environment: [:], home: home).path, "/home/someone/.local/share")
        XCTAssertEqual(XDGDirectory.state(environment: ["XDG_STATE_HOME": "state"], home: home).path,
                       "/home/someone/.local/state")
        XCTAssertEqual(XDGDirectory.config(environment: ["XDG_CONFIG_HOME": "cfg"], home: home).path,
                       "/home/someone/.config")
        XCTAssertEqual(XDGDirectory.config(environment: ["XDG_CONFIG_HOME": "/etc/cfg"], home: home).path, "/etc/cfg")
    }

    func testRelativeConfigHomeIsIgnoredByTheKeyStoreAndTheBluetoothPin() {
        let saved = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        defer { restore("XDG_CONFIG_HOME", saved) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        setenv("XDG_CONFIG_HOME", "relative/cfg", 1)
        XCTAssertEqual(AIKeychain.defaultDirectory.path, home + "/.config/qudelix")
        XCTAssertEqual(BluezTransport.pinnedDeviceFile.path, home + "/.config/qudelix/ble-device")
        setenv("XDG_CONFIG_HOME", scratch.path, 1)
        XCTAssertEqual(AIKeychain.defaultDirectory.path, scratch.path + "/qudelix")
        XCTAssertEqual(BluezTransport.pinnedDeviceFile.path, scratch.path + "/qudelix/ble-device")
    }
}
