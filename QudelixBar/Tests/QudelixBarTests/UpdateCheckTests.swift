import XCTest
@testable import QudelixBar

final class UpdateCheckTests: XCTestCase {
    func testParsesTheShapesReleaseTagsActuallyUse() {
        XCTAssertEqual(AppVersion("1.3.0")?.description, "1.3.0")
        XCTAssertEqual(AppVersion("v1.3.0")?.description, "1.3.0")
        XCTAssertEqual(AppVersion("V1.3.0")?.description, "1.3.0")
        XCTAssertEqual(AppVersion("  v1.3.0  ")?.description, "1.3.0")
        XCTAssertEqual(AppVersion("1.3")?.description, "1.3.0")
        XCTAssertEqual(AppVersion("2")?.description, "2.0.0")
    }

    func testAReleaseSuffixIsIgnoredForOrdering() {
        XCTAssertEqual(AppVersion("1.3.0-beta.1")?.description, "1.3.0")
        XCTAssertEqual(AppVersion("1.3.0+build7")?.description, "1.3.0")
    }

    func testUnreadableTagsAreRejectedRatherThanGuessedAt() {
        for bad in ["", "latest", "v", "1.x.0", "1..0", "-1.0.0", "1.2.3.4", "nightly-2026"] {
            XCTAssertNil(AppVersion(bad), "\(bad) must not parse")
        }
    }

    func testAnErrorTextIsScrubbedBeforeItReachesTheUpdateLine() {
        let error = CorrectionError.unavailable("rate limited\u{202E} \u{0007}now")

        guard case .failed(let why) = UpdateCheck.failure(for: error) else {
            return XCTFail("a thrown error is a failed check")
        }

        XCTAssertFalse(why.unicodeScalars.contains { $0.value == 0x202E },
                       "a server's own words never reach the UI unscrubbed")
        XCTAssertFalse(why.unicodeScalars.contains { $0.value == 0x0007 })
        XCTAssertEqual(UpdateCheck.summary(.failed(why)), why)
    }

    func testDoubleDigitComponentsOrderNumericallyNotAlphabetically() {
        XCTAssertTrue(AppVersion("1.10.0")! > AppVersion("1.9.0")!)
        XCTAssertTrue(AppVersion("1.2.10")! > AppVersion("1.2.9")!)
        XCTAssertTrue(AppVersion("10.0.0")! > AppVersion("9.9.9")!)
        XCTAssertTrue("1.10.0" < "1.9.0", "the string comparison this replaces really is wrong")
    }

    func testOrderingAcrossEachComponent() {
        XCTAssertTrue(AppVersion("2.0.0")! > AppVersion("1.9.9")!)
        XCTAssertTrue(AppVersion("1.3.0")! > AppVersion("1.2.9")!)
        XCTAssertTrue(AppVersion("1.3.1")! > AppVersion("1.3.0")!)
        XCTAssertEqual(AppVersion("1.3.0")!, AppVersion("v1.3.0")!)
        XCTAssertEqual(AppVersion("1.3")!, AppVersion("1.3.0")!)
    }

    func testAnOlderRunningVersionIsReportedAsAvailable() {
        XCTAssertEqual(UpdateCheck.summary(.available(AppVersion("1.4.0")!)),
                       "1.4.0 is available.")
    }

    func testTheCurrentVersionIsReportedAsLatest() {
        XCTAssertEqual(
            UpdateCheck.summary(.upToDate(latest: AppVersion("1.3.0")!,
                                          running: AppVersion("1.3.0")!)),
            "1.3.0 is the latest release.")
    }

    func testABuildAheadOfTheTagsDoesNotClaimToBeTheLatestRelease() {
        let text = UpdateCheck.summary(.upToDate(latest: AppVersion("1.2.0")!,
                                                 running: AppVersion("1.3.0")!))
        XCTAssertFalse(text.contains("1.3.0 is the latest release"))
        XCTAssertTrue(text.contains("1.2.0"), "it must name the actual latest release")
    }

    func testAnUnreadableAnswerIsNotReportedAsUpToDate() {
        let text = UpdateCheck.summary(.unreadable).lowercased()
        XCTAssertFalse(text.contains("is the latest"))
        XCTAssertFalse(text.contains("available"))
        XCTAssertTrue(text.contains("couldn't"))
    }

    func testTheReleasesHostIsPinnedAndOthersAreRefused() {
        XCTAssertTrue(PinnedHTTP.allowedHosts.contains(UpdateCheck.host))
        XCTAssertNoThrow(
            try PinnedHTTP.request(URL(string: "https://api.github.com/x")!, accept: "*/*",
                                   allowing: [UpdateCheck.host]))
        XCTAssertThrowsError(
            try PinnedHTTP.request(URL(string: "https://example.com/x")!, accept: "*/*",
                                   allowing: [UpdateCheck.host]))
        XCTAssertThrowsError(
            try PinnedHTTP.request(URL(string: "http://api.github.com/x")!, accept: "*/*",
                                   allowing: [UpdateCheck.host]),
            "plain HTTP must be refused even for an allowed host")
    }

    func testAnAllowedHostForAnotherFeatureIsStillRefusedHere() {
        XCTAssertTrue(PinnedHTTP.allowedHosts.contains(AutoEqService.host))
        XCTAssertThrowsError(
            try PinnedHTTP.request(URL(string: "https://\(AutoEqService.host)/x")!,
                                   accept: "*/*", allowing: [UpdateCheck.host]))
        XCTAssertThrowsError(
            try PinnedHTTP.request(URL(string: "https://\(UpdateCheck.host)/x")!,
                                   accept: "*/*", allowing: [AutoEqIndex.host]))
    }

    func testAnUnparseableRunningVersionShortCircuits() async {
        let result = await UpdateCheck.run(current: "not-a-version")
        XCTAssertEqual(result, .unreadable)
    }
}
