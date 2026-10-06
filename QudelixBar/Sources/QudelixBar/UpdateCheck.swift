import Foundation

struct AppVersion: Comparable, CustomStringConvertible {
    let major: Int, minor: Int, patch: Int

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("v") { text.removeFirst() }
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

enum UpdateCheck {
    enum Result: Equatable {
        case upToDate(latest: AppVersion, running: AppVersion)
        case available(AppVersion)
        case unreadable
        case failed(String)
    }

    static let host = "api.github.com"
    static let releasesURL = URL(string: "https://github.com/FrankieMa77/qudelix/releases/latest")
    private static let latestAPI =
        URL(string: "https://api.github.com/repos/FrankieMa77/qudelix/releases/latest")

    private static let maxBytes = 256_000

    private struct LatestRelease: Decodable { let tag_name: String }

    static func run(current: String) async -> Result {
        guard let running = AppVersion(current) else { return .unreadable }
        guard let url = latestAPI else { return .failed("bad URL") }
        do {
            let request = try PinnedHTTP.request(url, accept: "application/vnd.github+json",
                                                 allowing: [host])
            let data = try await PinnedHTTP.fetch(request, limit: maxBytes, allowing: [host])
            guard let tag = try? JSONDecoder().decode(LatestRelease.self, from: data).tag_name,
                  let latest = AppVersion(tag) else { return .unreadable }
            return latest > running ? .available(latest)
                                   : .upToDate(latest: latest, running: running)
        } catch {
            return failure(for: error)
        }
    }

    static func failure(for error: Error) -> Result {
        .failed(SafeText.scrubbed(AutoEqService.describe(
            AutoEqService.mapped(error, host: host))))
    }

    static func summary(_ result: Result) -> String {
        switch result {
        case .upToDate(let latest, let running):
            return running > latest
                ? "\(running) is newer than the latest release (\(latest))."
                : "\(latest) is the latest release."
        case .available(let v): return "\(v) is available."
        case .unreadable: return "Couldn't read the latest version."
        case .failed(let why): return why
        }
    }
}
