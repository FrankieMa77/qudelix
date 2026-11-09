import XCTest
@testable import QudelixBar

final class AutostartTests: XCTestCase {
    private var home: URL!

    override func setUp() {
        super.setUp()
        home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("autostart-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        home = nil
        super.tearDown()
    }

    func testTheFileLivesUnderXdgConfigHomeWhenSet() {
        let config = home.appendingPathComponent("cfg", isDirectory: true)
        let file = AutostartFile.system(environment: ["XDG_CONFIG_HOME": config.path], home: home)
        XCTAssertEqual(file.url.path, config.path + "/autostart/io.github.FrankieMa77.Qudelix.desktop")
    }

    func testTheFileFallsBackToDotConfigInHome() {
        let unset = AutostartFile.system(environment: [:], home: home)
        let empty = AutostartFile.system(environment: ["XDG_CONFIG_HOME": ""], home: home)
        let expected = home.path + "/.config/autostart/io.github.FrankieMa77.Qudelix.desktop"
        XCTAssertEqual(unset.url.path, expected)
        XCTAssertEqual(empty.url.path, expected)
    }

    func testEnableWritesAHiddenLaunchEntryAndDisableRemovesIt() throws {
        let file = AutostartFile(configHome: home.appendingPathComponent(".config", isDirectory: true),
                                 executable: "/opt/qudelix/bin/qudelix-app")
        XCTAssertFalse(file.isEnabled)
        try file.enable()
        XCTAssertTrue(file.isEnabled)
        let text = try String(contentsOf: file.url, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "[Desktop Entry]")
        XCTAssertTrue(lines.contains("Type=Application"))
        XCTAssertTrue(lines.contains("Exec=/opt/qudelix/bin/qudelix-app --hidden"))
        XCTAssertTrue(lines.contains("X-GNOME-Autostart-enabled=true"))
        XCTAssertTrue(lines.contains("Terminal=false"))
        try file.disable()
        XCTAssertFalse(file.isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertNoThrow(try file.disable())
    }

    func testRelativeAndEmptyConfigHomeValuesAreIgnored() {
        let expected = home.path + "/.config/autostart/io.github.FrankieMa77.Qudelix.desktop"
        for value in ["cfg", "./cfg", "", "~/cfg"] {
            let file = AutostartFile.system(environment: ["XDG_CONFIG_HOME": value], home: home)
            XCTAssertEqual(file.url.path, expected, value)
        }
    }

    func testTheEntryUsesTheRunningBinaryPathAndFallsBackToTheBareName() throws {
        let binary = home.appendingPathComponent("qudelix-app-real")
        try "x".write(to: binary, atomically: true, encoding: .utf8)
        let link = home.appendingPathComponent("exe-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: binary.path)
        XCTAssertEqual(AutostartFile.runningExecutable(link: link.path), binary.path)
        XCTAssertEqual(AutostartFile.runningExecutable(link: home.appendingPathComponent("missing").path),
                       "qudelix-app")
        let deleted = home.appendingPathComponent("deleted-link")
        try FileManager.default.createSymbolicLink(atPath: deleted.path,
                                                   withDestinationPath: binary.path + " (deleted)")
        XCTAssertEqual(AutostartFile.runningExecutable(link: deleted.path), "qudelix-app")
        let system = AutostartFile.system(environment: [:], home: home, executable: "/usr/local/bin/qudelix-app")
        XCTAssertTrue(system.contents.contains("Exec=/usr/local/bin/qudelix-app --hidden\n"))
    }

    func testAPathWithSpacesIsQuotedInTheExecLine() {
        XCTAssertEqual(AutostartFile.execArgument("/usr/bin/qudelix-app"), "/usr/bin/qudelix-app")
        XCTAssertEqual(AutostartFile.execArgument("/home/a b/qudelix-app"), "\"/home/a b/qudelix-app\"")
        XCTAssertEqual(AutostartFile.execArgument("/a/$b c"), "\"/a/\\\\$b c\"")
        XCTAssertEqual(AutostartFile.execArgument("/opt/100%/app"), "/opt/100%%/app")
        XCTAssertEqual(AutostartFile.execArgument("/opt/a b%c"), "\"/opt/a b%%c\"")
        XCTAssertEqual(AutostartFile.execArgument("/a\"b`c\\d$e%f"), "\"/a\\\\\"b\\\\`c\\\\\\\\d\\\\$e%%f\"")
    }

    func testEnableTwiceKeepsOneFile() throws {
        let file = AutostartFile(configHome: home)
        try file.enable()
        try file.enable()
        let names = try FileManager.default.contentsOfDirectory(atPath: file.url.deletingLastPathComponent().path)
        XCTAssertEqual(names, [AutostartFile.fileName])
    }

    func testStateIsReadFromTheFile() throws {
        let file = AutostartFile(configHome: home)
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "[Desktop Entry]\nExec=qudelix-app --hidden\nX-GNOME-Autostart-enabled=false\n"
            .write(to: file.url, atomically: true, encoding: .utf8)
        XCTAssertFalse(file.isEnabled)
        try "[Desktop Entry]\nExec=qudelix-app --hidden\nHidden=true\n"
            .write(to: file.url, atomically: true, encoding: .utf8)
        XCTAssertFalse(file.isEnabled)
        try "[Desktop Entry]\nType=Application\n".write(to: file.url, atomically: true, encoding: .utf8)
        XCTAssertFalse(file.isEnabled)
        try "[Desktop Entry]\nExec=qudelix-app --hidden\n".write(to: file.url, atomically: true, encoding: .utf8)
        XCTAssertTrue(file.isEnabled)
    }

    func testSetReportsSuccessAndFailure() throws {
        let file = AutostartFile(configHome: home)
        XCTAssertTrue(file.set(true))
        XCTAssertTrue(file.isEnabled)
        XCTAssertTrue(file.set(false))
        XCTAssertFalse(file.isEnabled)
        let blocker = home.appendingPathComponent("blocked")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        XCTAssertFalse(AutostartFile(configHome: blocker).set(true))
    }
}
