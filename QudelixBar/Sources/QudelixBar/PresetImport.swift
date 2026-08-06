import Foundation

/// Parsing and fetching of parametric-EQ presets.
///
/// Format is the de-facto standard used by AutoEq, Equalizer APO, Peace and
/// most squig.link sites:
///
///     Preamp: -6.1 dB
///     Filter 1: ON LSC Fc 105 Hz Gain 6.4 dB Q 0.70
///     Filter 2: ON PK Fc 8800 Hz Gain 5.1 dB Q 1.42
///
/// Filter tokens seen in the wild: PK/PEQ (peaking), LSC/LS/LSQ (low shelf),
/// HSC/HS/HSQ (high shelf), LPQ/LP (low pass), HPQ/HP (high pass).
struct ParametricEQFile {
    var preamp: Double = 0
    var bands: [QxEqBandValue] = []

    /// Bands beyond what the device supports, dropped during parsing.
    var droppedBands = 0

    static func parse(_ text: String) -> ParametricEQFile? {
        var out = ParametricEQFile()
        var parsed: [QxEqBandValue] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.lowercased().hasPrefix("preamp:") {
                let p = firstDouble(after: ":", in: line) ?? 0
                out.preamp = p.isFinite ? max(-24, min(24, p)) : 0
                continue
            }
            guard line.lowercased().hasPrefix("filter") else { continue }

            // Skip disabled filters ("Filter 3: OFF ...").
            let tokens = line.split(separator: " ").map(String.init)
            guard let onIdx = tokens.firstIndex(where: { $0 == "ON" || $0 == "OFF" }),
                  tokens[onIdx] == "ON",
                  onIdx + 1 < tokens.count else { continue }

            guard let filter = filterType(tokens[onIdx + 1]) else { continue }
            // `Double("inf")`, `Double("nan")` and `Double("1e400")` all parse,
            // and `Int(inf)` traps — so every number is range-checked here, at
            // the boundary, before it can reach an Int conversion.
            guard let fc = value(after: "Fc", in: tokens), fc.isFinite,
                  fc >= 1, fc <= 100_000,
                  let gain = value(after: "Gain", in: tokens), gain.isFinite,
                  let q = value(after: "Q", in: tokens), q.isFinite else { continue }

            parsed.append(QxEqBandValue(
                filter: filter,
                freq: Int(fc.rounded()),
                gain: max(-24, min(24, gain)),
                q: max(0.05, min(20, q))
            ))
        }

        guard !parsed.isEmpty else { return nil }
        // Cap at the LARGEST band count any EQ group supports — which mode
        // the device is in isn't known here. The apply step trims to the
        // active mode's count and reports what didn't fit.
        if parsed.count > QxEq.maxBandCount {
            out.droppedBands = parsed.count - QxEq.maxBandCount
            parsed = Array(parsed.prefix(QxEq.maxBandCount))
        }
        out.bands = parsed
        return out
    }

    private static func filterType(_ token: String) -> QxFilter? {
        switch token.uppercased() {
        case "PK", "PEQ", "MODAL": return .peak
        case "LSC", "LS", "LSQ": return .lowShelf
        case "HSC", "HS", "HSQ": return .highShelf
        case "LPQ", "LP", "LPF": return .lpf
        case "HPQ", "HP", "HPF": return .hpf
        default: return nil
        }
    }

    /// The number following a keyword token, e.g. "Fc 105 Hz" → 105.
    private static func value(after keyword: String, in tokens: [String]) -> Double? {
        guard let i = tokens.firstIndex(of: keyword), i + 1 < tokens.count else { return nil }
        return Double(tokens[i + 1].replacingOccurrences(of: ",", with: "."))
    }

    private static func firstDouble(after sep: String, in line: String) -> Double? {
        guard let range = line.range(of: sep) else { return nil }
        let rest = line[range.upperBound...]
        let numeric = rest.split(separator: " ").first.map(String.init) ?? ""
        return Double(numeric)
    }
}

// MARK: - AutoEq online database

/// One headphone entry from AutoEq's recommended-results index.
struct AutoEqEntry: Identifiable, Hashable {
    let title: String      // "Sennheiser HD 650"
    let source: String     // "oratory1990"
    let path: String       // "oratory1990/over-ear/Sennheiser%20HD%20650"
    var id: String { path }

    /// AutoEq stores each preset as "<last path component> ParametricEQ.txt".
    ///
    /// The path comes out of a file fetched over the network, so the resulting
    /// URL is re-checked: it must still point at the AutoEq results root, and
    /// must not contain traversal segments.
    var presetURL: URL? {
        guard !path.contains(".."), !path.hasPrefix("/") else { return nil }
        let leaf = path.split(separator: "/").last.map(String.init) ?? ""
        guard !leaf.isEmpty else { return nil }
        guard let url = URL(string: "\(AutoEqIndex.root)/\(path)/\(leaf)%20ParametricEQ.txt"),
              url.scheme == "https",
              url.host == AutoEqIndex.host,
              url.absoluteString.hasPrefix(AutoEqIndex.root + "/") else { return nil }
        return url
    }
}

/// Fetches and searches the AutoEq recommended-results index — the same source
/// the official Qudelix app uses.
@MainActor
final class AutoEqIndex: ObservableObject {
    nonisolated static let root = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results"
    nonisolated static let indexURL = URL(string: "\(root)/README.md")!

    enum State: Equatable {
        case idle, loading, ready, failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var entries: [AutoEqEntry] = []
    @Published var query = ""

    /// How many matches the popover shows at once. Kept small so the window
    /// height stays sane — the rest is surfaced as a "refine your search" hint.
    static let displayLimit = 6

    /// Case-insensitive substring match. Matches whose title *starts* with the
    /// query sort first, so typing "HD 6" surfaces "HD 600" before
    /// "Sennheiser HD 600". Capped so filtering stays instant while typing.
    var results: [AutoEqEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var prefixed: [AutoEqEntry] = []
        var contained: [AutoEqEntry] = []
        for e in entries {
            guard e.title.localizedCaseInsensitiveContains(q) else { continue }
            if e.title.lowercased().hasPrefix(q.lowercased()) {
                prefixed.append(e)
            } else {
                contained.append(e)
            }
            if prefixed.count + contained.count >= 200 { break }
        }
        return prefixed + contained
    }

    /// Index is ~500 KB today; refuse a wildly larger response rather than
    /// buffering whatever the network hands us.
    nonisolated static let maxIndexBytes = 12_000_000
    nonisolated static let maxPresetBytes = 200_000

    /// Refuses to follow a redirect off the one host we trust.
    ///
    /// Nothing sensitive travels with these requests — the session is ephemeral
    /// and carries no cookies or credentials — but the host check in
    /// `presetURL` is worth nothing if a 302 can move the request afterwards.
    private final class HostPinnedRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard request.url?.host == AutoEqIndex.host, request.url?.scheme == "https" else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    nonisolated static let host = "raw.githubusercontent.com"
    private nonisolated static let redirectPolicy = HostPinnedRedirects()

    /// One shared session. A computed property would build a fresh `URLSession`
    /// per fetch, and a session retains itself until it is invalidated — which
    /// never happens here — so every index load and preset import would leak it
    /// along with its delegate queue.
    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.httpAdditionalHeaders = ["Accept": "text/plain"]
        return URLSession(configuration: cfg, delegate: redirectPolicy, delegateQueue: nil)
    }()

    /// Download with a hard ceiling that is enforced *while* the body arrives.
    ///
    /// `session.data(from:)` buffers the whole response before returning, so a
    /// size check on its result only rejects a body already sitting in memory.
    /// Streaming lets us stop reading — and cancel — the moment a response runs
    /// past what a preset or the index could plausibly be.
    nonisolated static func fetch(_ url: URL, limit: Int) async throws -> Data {
        let (stream, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            stream.task.cancel()
            throw URLError(.badServerResponse)
        }
        if http.expectedContentLength > Int64(limit) {
            stream.task.cancel()
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        data.reserveCapacity(min(limit, 1 << 16))
        for try await byte in stream {
            data.append(byte)
            if data.count > limit {
                stream.task.cancel()
                throw URLError(.dataLengthExceedsMaximum)
            }
        }
        return data
    }

    #if DEBUG
    /// Used by UIPreview to render the results list without a network fetch.
    func seedForPreview(_ seeded: [AutoEqEntry], query: String) {
        entries = seeded
        state = .ready
        self.query = query
    }
    #endif

    func loadIfNeeded() {
        guard state == .idle || isFailed else { return }
        state = .loading
        Task {
            do {
                let data = try await Self.fetch(Self.indexURL, limit: Self.maxIndexBytes)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw URLError(.cannotDecodeContentData)
                }
                entries = Self.parseIndex(text)
                state = entries.isEmpty ? .failed("Index was empty") : .ready
                DebugLog.shared.log("AutoEq index: \(entries.count) headphones")
            } catch {
                state = .failed(error.localizedDescription)
                DebugLog.shared.log("AutoEq index failed: \(error.localizedDescription)")
            }
        }
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    /// Index lines look like:
    ///   `- [Sennheiser HD 650](./oratory1990/over-ear/Sennheiser%20HD%20650)`
    static let maxIndexEntries = 20_000

    static func parseIndex(_ markdown: String) -> [AutoEqEntry] {
        var out: [AutoEqEntry] = []
        for line in markdown.split(whereSeparator: \.isNewline) {
            guard out.count < maxIndexEntries else { break }
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- [") || t.hasPrefix("* [") else { continue }
            guard let close = t.firstIndex(of: "]"),
                  let open = t.firstIndex(of: "("),
                  let end = t.lastIndex(of: ")"),
                  open < end else { continue }

            let title = String(t[t.index(t.startIndex, offsetBy: 3)..<close])
            var path = String(t[t.index(after: open)..<end])
            if path.hasPrefix("./") { path.removeFirst(2) }
            // Skip the doc links at the top of the README (INDEX.md, RANKING.md…).
            guard path.contains("/"), !path.hasSuffix(".md"), !path.hasPrefix("http") else { continue }

            let source = path.split(separator: "/").first
                .map { $0.replacingOccurrences(of: "%20", with: " ") } ?? ""
            out.append(AutoEqEntry(title: title, source: source, path: path))
        }
        return out
    }

    /// Download and parse one entry's parametric EQ.
    nonisolated static func fetchPreset(_ entry: AutoEqEntry) async throws -> ParametricEQFile {
        guard let url = entry.presetURL else { throw URLError(.badURL) }
        let data = try await fetch(url, limit: maxPresetBytes)
        guard let text = String(data: data, encoding: .utf8),
              let parsed = ParametricEQFile.parse(text) else {
            throw URLError(.cannotParseResponse)
        }
        return parsed
    }
}
