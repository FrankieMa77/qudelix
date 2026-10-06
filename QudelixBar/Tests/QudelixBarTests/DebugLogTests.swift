import XCTest
@testable import QudelixBar

final class DebugLogTests: XCTestCase {
    func testTheLogIsKeptOutOfTheUsersLogsFolderWhileTestsRun() throws {
        XCTAssertTrue(DebugLog.runningUnderTests)
        let url = try XCTUnwrap(DebugLog.shared.fileURL)
        XCTAssertEqual(url, DebugLog.logURL(underTests: true))
        XCTAssertEqual(url.deletingLastPathComponent().resolvingSymlinksInPath().path,
                       FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path)
        XCTAssertNotEqual(url.lastPathComponent, "QudelixBar.log")
    }

    func testTheRealLogStaysInTheLogsFolderOutsideTests() throws {
        let url = try XCTUnwrap(DebugLog.logURL(underTests: false))
        XCTAssertTrue(url.path.hasSuffix("/Library/Logs/QudelixBar.log"), url.path)
    }

    func testEveryLogLineStartsWithTheDateAndTime() throws {
        let marker = "probe-\(UUID().uuidString)"
        DebugLog.shared.log(marker)
        DebugLog.shared.flush()

        let url = try XCTUnwrap(DebugLog.shared.fileURL)
        let text = [url, url.appendingPathExtension("1")]
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let line = try XCTUnwrap(text.split(separator: "\n").last { $0.hasSuffix(marker) })

        let stamp = String(line.prefix(DebugLog.timestampFormat.count))
        XCTAssertEqual(String(line.dropFirst(stamp.count)), " " + marker)
        XCTAssertNotNil(stamp.range(
            of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$"#, options: .regularExpression))

        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = DebugLog.timestampFormat
        let written = try XCTUnwrap(parser.date(from: stamp))
        XCTAssertLessThan(abs(written.timeIntervalSinceNow), 120)
    }
}
