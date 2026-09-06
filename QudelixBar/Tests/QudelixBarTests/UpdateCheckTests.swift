import XCTest
@testable import QudelixBar

/// Version comparison, which is the part of an update check that fails
/// silently. A wrong answer here does not crash or log — it just tells
/// everyone they are up to date forever, and nobody ever finds out.
final class UpdateCheckTests: XCTestCase {

    // MARK: - Parsing

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

    /// A tag this app cannot read is not a tag it should act on. Guessing
    /// would mean either a false "update available" or a false "up to date".
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

    // MARK: - Ordering

    /// The bug this whole type exists to avoid: as strings, "1.10.0" sorts
    /// below "1.9.0", so the tenth release of a line would look older than the
    /// ninth and nobody would ever be offered an update again.
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

    // MARK: - What the user is told

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

    /// A build ahead of the tags must not announce its own version as the
    /// latest release — that is a claim about the release list, and it is
    /// false for every pre-release build.
    func testABuildAheadOfTheTagsDoesNotClaimToBeTheLatestRelease() {
        let text = UpdateCheck.summary(.upToDate(latest: AppVersion("1.2.0")!,
                                                 running: AppVersion("1.3.0")!))
        XCTAssertFalse(text.contains("1.3.0 is the latest release"))
        XCTAssertTrue(text.contains("1.2.0"), "it must name the actual latest release")
    }

    /// An answer that could not be read is said plainly. Reporting it as "up
    /// to date" would be a guess dressed as a fact.
    func testAnUnreadableAnswerIsNotReportedAsUpToDate() {
        let text = UpdateCheck.summary(.unreadable).lowercased()
        // It may mention "the latest version" — what it must never do is
        // assert that the running one *is* it, or offer one that isn't there.
        XCTAssertFalse(text.contains("is the latest"))
        XCTAssertFalse(text.contains("available"))
        XCTAssertTrue(text.contains("couldn't"))
    }

    // MARK: - Network policy

    /// The check must be refused for any host outside the pinned list, and the
    /// releases host has to be on it or the feature silently never works.
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

    /// A running version the app cannot parse must not produce a confident
    /// answer either — it short-circuits before any request is made.
    func testAnUnparseableRunningVersionShortCircuits() async {
        let result = await UpdateCheck.run(current: "not-a-version")
        XCTAssertEqual(result, .unreadable)
    }
}
