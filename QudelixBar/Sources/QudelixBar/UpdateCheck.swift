import Foundation

/// A release version, compared the way versions mean rather than the way
/// strings sort.
///
/// String comparison gets this wrong in the one case that matters: "1.10.0"
/// sorts *below* "1.9.0", so the tenth release of a line would look older than
/// the ninth and the app would tell everyone they were up to date forever.
struct AppVersion: Comparable, CustomStringConvertible {
    let major: Int, minor: Int, patch: Int

    /// Parses "1.3.0", "v1.3.0", "1.3", "1". Anything with a non-numeric part
    /// where a number belongs is rejected rather than guessed at — a tag this
    /// app cannot read is not a tag it should act on.
    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("v") { text.removeFirst() }
        // Release tags sometimes carry a suffix ("1.3.0-beta.1"); the numbers
        // in front are what orders them, and a pre-release is deliberately
        // treated as equal to its release rather than newer.
        if let dash = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            text = String(text[text.startIndex..<dash])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var numbers: [Int] = []
        for p in parts {
            guard let n = Int(p), n >= 0 else { return nil }
            numbers.append(n)
        }
        major = numbers.count > 0 ? numbers[0] : 0
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

/// Asks the release list whether anything newer exists.
///
/// Only ever when the user presses the button. This app's privacy note says no
/// host is contacted at launch, and a background check that quietly phoned home
/// would make that false — which matters more than the convenience of finding
/// out about a release a few days sooner.
enum UpdateCheck {
    enum Result: Equatable {
        case upToDate(AppVersion)
        case available(AppVersion)
        /// Something answered, but not with a version this app can read. Said
        /// plainly rather than reported as "up to date", which would be a
        /// guess dressed as an answer.
        case unreadable
        case failed(String)
    }

    static let releasesURL = URL(string: "https://github.com/FrankieMa77/qudelix/releases/latest")
    private static let latestAPI =
        URL(string: "https://api.github.com/repos/FrankieMa77/qudelix/releases/latest")

    /// A release document is a few kilobytes; anything far past that is not one.
    private static let maxBytes = 256_000

    private struct LatestRelease: Decodable { let tag_name: String }

    static func run(current: String) async -> Result {
        guard let running = AppVersion(current) else { return .unreadable }
        guard let url = latestAPI else { return .failed("bad URL") }
        do {
            let request = try PinnedHTTP.request(url, accept: "application/vnd.github+json")
            let data = try await PinnedHTTP.fetch(request, limit: maxBytes)
            guard let tag = try? JSONDecoder().decode(LatestRelease.self, from: data).tag_name,
                  let latest = AppVersion(tag) else { return .unreadable }
            return latest > running ? .available(latest) : .upToDate(running)
        } catch {
            return .failed(AutoEqService.describe(error))
        }
    }

    /// One line of user-facing text for a result.
    static func summary(_ result: Result) -> String {
        switch result {
        case .upToDate(let v): return "\(v) is the latest release."
        case .available(let v): return "\(v) is available."
        case .unreadable: return "Couldn't read the latest version."
        case .failed(let why): return why
        }
    }
}
