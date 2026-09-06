import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

    var notes: [String] = []

    static let defaultShelfQ = 0.71

    static let maxLineLength = 4096

    private static let preampPattern =
        #/(?i)preamp\s*:?\s*([+-]?[\d.]+)\s*dB/#
    private static let filterPattern =
        #/(?i)filter\s*\d*\s*:?\s*(ON|OFF)\s+(PK|PEQ|MODAL|LSC|LSQ|LS|HSC|HSQ|HS|LPQ|LPF|LP|HPQ|HPF|HP)\s+Fc\s+([\d.,]+)\s*Hz\s+Gain\s+([+-]?[\d.,]+)\s*dB(?:\s+Q\s+([\d.,]+))?/#
    private static let passPattern =
        #/(?i)filter\s*\d*\s*:?\s*(ON|OFF)\s+(LPQ|LPF|LP|HPQ|HPF|HP)\s+Fc\s+([\d.,]+)\s*Hz(?:\s+Q\s+([\d.,]+))?/#

    static func parse(_ text: String) -> ParametricEQFile? {
        var out = ParametricEQFile()
        var parsed: [QxEqBandValue] = []
        var unreadable = 0

        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard rawLine.count <= maxLineLength else { continue }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if let m = try? preampPattern.firstMatch(in: line),
               let p = number(m.1) {
                // Deliberately wider than the ±12 the device accepts. This is a
                // sanity bound on a parsed file, not a device bound: clamping
                // to the device range here would erase the overflow, and the
                // overflow is exactly what the caller warns the user about
                // before `apply` clamps it for the wire.
                out.preamp = max(-24, min(24, p))
                continue
            }

            if let m = try? filterPattern.firstMatch(in: line),
               m.1.uppercased() == "ON",
               let filter = filterType(String(m.2)),
               let fc = number(m.3), fc >= 1, fc <= 100_000,
               let gain = number(m.4) {
                let q = m.5.flatMap { number($0) } ?? defaultShelfQ
                parsed.append(QxEqBandValue(
                    filter: filter,
                    freq: Int(fc.rounded()),
                    gain: filter.hasGain ? max(-24, min(24, gain)) : 0,
                    q: max(0.05, min(20, q))))
                continue
            }

            if let m = try? passPattern.firstMatch(in: line),
               m.1.uppercased() == "ON",
               let filter = filterType(String(m.2)),
               let fc = number(m.3), fc >= 1, fc <= 100_000 {
                let q = m.4.flatMap { number($0) } ?? defaultShelfQ
                parsed.append(QxEqBandValue(filter: filter, freq: Int(fc.rounded()),
                                            gain: 0, q: max(0.05, min(20, q))))
                continue
            }

            if line.lowercased().hasPrefix("filter") { unreadable += 1 }
        }

        guard !parsed.isEmpty else { return nil }
        if unreadable > 0 {
            out.notes.append("skipped \(unreadable) filter line"
                + (unreadable == 1 ? "" : "s")
                + " — an unsupported type, or a missing Fc, Gain or Q")
        }
        if abs(out.preamp) > EQHeadroom.range.upperBound + 0.05 {
            out.notes.append(String(
                format: "pre-gain %+.1f dB is beyond this device's ±%.0f dB and will be "
                    + "clamped — a strong boost may clip at full volume",
                out.preamp, EQHeadroom.range.upperBound))
        }
        let clamped = parsed.filter { $0.filter.hasGain && abs($0.gain) > 12.05 }.count
        if clamped > 0 {
            out.notes.append("\(clamped) gain\(clamped == 1 ? "" : "s") beyond ±12 dB "
                + "\(clamped == 1 ? "was" : "were") clamped")
        }

        // Cap at the LARGEST band count any EQ group supports — which mode
        // the device is in isn't known here. The apply step trims to the
        // active mode's count and reports what didn't fit.
        if parsed.count > QxEq.maxBandCount {
            out.droppedBands = parsed.count - QxEq.maxBandCount
            parsed = strongest(parsed, keeping: QxEq.maxBandCount)
            out.notes.append("kept the \(QxEq.maxBandCount) filters doing the most work")
        }
        out.bands = nudgingDuplicateCentres(parsed)
        return out
    }

    static func strongest(_ bands: [QxEqBandValue], keeping count: Int) -> [QxEqBandValue] {
        guard bands.count > count else { return bands }
        func work(_ band: QxEqBandValue) -> Double {
            band.filter.hasGain ? abs(band.gain) : .infinity
        }
        return bands.enumerated()
            .sorted { a, b in
                work(a.element) == work(b.element)
                    ? a.offset < b.offset
                    : work(a.element) > work(b.element)
            }
            .prefix(count)
            .sorted { $0.offset < $1.offset }
            .map(\.element)
    }

    static func nudgingDuplicateCentres(_ bands: [QxEqBandValue]) -> [QxEqBandValue] {
        guard bands.count > 1 else { return bands }
        var out = bands
        let byFrequency = out.indices.sorted {
            out[$0].freq == out[$1].freq ? $0 < $1 : out[$0].freq < out[$1].freq
        }
        for k in 1..<byFrequency.count {
            let previous = out[byFrequency[k - 1]].freq
            guard out[byFrequency[k]].freq <= previous else { continue }
            out[byFrequency[k]].freq = max(previous + 1,
                                           Int((Double(previous) * 1.005).rounded()))
        }
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

    private static func number(_ text: Substring) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")),
              value.isFinite else { return nil }
        return value
    }
}

// MARK: - Shared HTTP

/// Non-2xx response, with enough of the body to be worth showing a user.
struct HTTPStatusError: Error {
    let status: Int
    /// First couple of KB only — APIs put their `detail` at the front.
    let body: String
}

/// The one network path every correction source uses.
///
/// Session configuration, redirect pinning and the streaming size ceiling live
/// here rather than on any single source: a second path would be a second
/// chance to forget one of the three.
enum PinnedHTTP {
    /// Hosts this app is willing to talk to, and the only places a redirect
    /// may land. Nothing sensitive travels on these requests — the session is
    /// ephemeral and carries no cookies or credentials — but a host check made
    /// when building a URL is worth nothing if a 302 can move the request
    /// afterwards.
    /// `api.github.com` is here for the manual update check only, and only
    /// because the release list is the authoritative answer to "is there a
    /// newer version" — a version file committed in the repository would drift
    /// the first time someone forgot to bump it.
    static let correctionHosts: Set<String> = ["raw.githubusercontent.com", "autoeq.app",
                                               "api.github.com"]

    static let allowedHosts: Set<String> = correctionHosts.union(AIProvider.hosts)

    private final class HostPinnedRedirects: NSObject, URLSessionTaskDelegate {
        let hosts: Set<String>

        init(hosts: Set<String>) { self.hosts = hosts }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard let host = request.url?.host, hosts.contains(host),
                  request.url?.scheme == "https" else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let redirectPolicy = HostPinnedRedirects(hosts: correctionHosts)
    private static let refuseRedirects = NoRedirects()

    /// One shared session. A computed property would build a fresh `URLSession`
    /// per fetch, and a session retains itself until it is invalidated — which
    /// never happens here — so every load would leak it along with its
    /// delegate queue.
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg, delegate: redirectPolicy, delegateQueue: nil)
    }()

    static let credentialedSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 90
        cfg.timeoutIntervalForResource = 120
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: cfg, delegate: refuseRedirects, delegateQueue: nil)
    }()

    static func request(_ url: URL, accept: String,
                        allowing hosts: Set<String>) throws -> URLRequest {
        guard url.scheme == "https", let host = url.host,
              hosts.contains(host), allowedHosts.contains(host) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.setValue(accept, forHTTPHeaderField: "Accept")
        return req
    }

    /// How much of an error body is read before giving up on it.
    static let maxErrorBodyBytes = 2048

    /// Download with a hard ceiling that is enforced *while* the body arrives.
    ///
    /// `session.data(for:)` buffers the whole response before returning, so a
    /// size check on its result only rejects a body already sitting in memory.
    /// Streaming lets us stop reading — and cancel — the moment a response runs
    /// past what the payload could plausibly be.
    static func fetch(_ request: URLRequest, limit: Int,
                      allowing hosts: Set<String>) async throws -> Data {
        try await run(request, limit: limit, allowing: hosts, session: session,
                      delegate: HostPinnedRedirects(hosts: hosts))
    }

    static func fetchRefusingRedirects(_ request: URLRequest, limit: Int,
                                       allowing hosts: Set<String>) async throws -> Data {
        try await run(request, limit: limit, allowing: hosts,
                      session: credentialedSession, delegate: refuseRedirects)
    }

#if os(Linux)
    struct BoundedBody {
        var data: Data
        var response: HTTPURLResponse?
        var exceededLimit: Bool
    }

    private final class BoundedBodyCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let limit: Int
        private let errorBodyLimit: Int
        private let redirects: URLSessionTaskDelegate
        private let lock = NSLock()
        private var body = Data()
        private var http: HTTPURLResponse?
        private var ceiling: Int
        private var ceilingIsTheLimit = true
        private var exceededLimit = false
        private var stopped = false
        private var pending: CheckedContinuation<BoundedBody, Error>?

        init(limit: Int, errorBodyLimit: Int, redirects: URLSessionTaskDelegate) {
            self.limit = limit
            self.errorBodyLimit = errorBodyLimit
            self.redirects = redirects
            self.ceiling = limit
        }

        func load(_ task: URLSessionDataTask) async throws -> BoundedBody {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                pending = continuation
                lock.unlock()
                task.resume()
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock()
            guard let http = response as? HTTPURLResponse else {
                stopped = true
                lock.unlock()
                completionHandler(.cancel)
                dataTask.cancel()
                return
            }
            self.http = http
            let succeeded = (200..<300).contains(http.statusCode)
            ceilingIsTheLimit = succeeded
            ceiling = succeeded ? limit : errorBodyLimit
            if succeeded, http.expectedContentLength > Int64(limit) {
                exceededLimit = true
                stopped = true
                lock.unlock()
                completionHandler(.cancel)
                dataTask.cancel()
                return
            }
            lock.unlock()
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            if stopped {
                lock.unlock()
                return
            }
            body.append(data)
            let over = body.count > ceiling
            if over {
                stopped = true
                exceededLimit = ceilingIsTheLimit
            }
            lock.unlock()
            if over { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            lock.lock()
            let continuation = pending
            pending = nil
            let result = BoundedBody(data: body, response: http, exceededLimit: exceededLimit)
            let wasStopped = stopped
            lock.unlock()
            guard let continuation else { return }
            if let error, !wasStopped {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: result)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            redirects.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                 newRequest: request, completionHandler: completionHandler)
        }
    }

    static func boundedLoad(_ request: URLRequest, limit: Int, session: URLSession,
                            delegate: URLSessionTaskDelegate) async throws -> BoundedBody {
        let collector = BoundedBodyCollector(limit: limit, errorBodyLimit: maxErrorBodyBytes,
                                             redirects: delegate)
        let bounded = URLSession(configuration: session.configuration,
                                 delegate: collector, delegateQueue: nil)
        defer { bounded.finishTasksAndInvalidate() }
        return try await collector.load(bounded.dataTask(with: request))
    }

    static func validated(_ bounded: BoundedBody, limit: Int) throws -> Data {
        guard let http = bounded.response else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPStatusError(status: http.statusCode,
                                  body: String(data: bounded.data.prefix(maxErrorBodyBytes),
                                               encoding: .utf8) ?? "")
        }
        guard !bounded.exceededLimit, bounded.data.count <= limit else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        return bounded.data
    }
#endif

    private static func run(_ request: URLRequest, limit: Int, allowing hosts: Set<String>,
                            session: URLSession,
                            delegate: URLSessionTaskDelegate) async throws -> Data {
        guard request.url?.scheme == "https", let host = request.url?.host,
              hosts.contains(host), allowedHosts.contains(host) else {
            throw URLError(.badURL)
        }
#if os(Linux)
        let bounded = try await boundedLoad(request, limit: limit,
                                            session: session, delegate: delegate)
        return try validated(bounded, limit: limit)
#else
        let (stream, response) = try await session.bytes(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse else {
            stream.task.cancel()
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            // The status alone is not actionable; the body usually names the
            // field the server disliked. Read a little, then stop.
            var head = Data()
            for try await byte in stream {
                head.append(byte)
                if head.count >= maxErrorBodyBytes { break }
            }
            stream.task.cancel()
            throw HTTPStatusError(status: http.statusCode,
                                  body: String(data: head, encoding: .utf8) ?? "")
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
#endif
    }
}

/// Case-insensitive substring match, with matches whose title *starts* with the
/// query sorted first, so typing "HD 6" surfaces "HD 600" before "Sennheiser
/// HD 600". Capped so filtering stays instant while typing.
///
/// Shared so every correction source ranks its catalogue the same way.
func rankByTitle<T>(_ items: [T], query: String, cap: Int = 200,
                    title: (T) -> String) -> [T] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return [] }
    let lower = q.lowercased()
    var prefixed: [T] = []
    var contained: [T] = []
    for item in items {
        let t = title(item)
        guard t.localizedCaseInsensitiveContains(q) else { continue }
        if t.lowercased().hasPrefix(lower) {
            prefixed.append(item)
        } else {
            contained.append(item)
        }
        if prefixed.count + contained.count >= cap { break }
    }
    return prefixed + contained
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
        guard !path.hasPrefix("/"), !path.contains("?"), !path.contains("#"),
              !path.contains(".."),
              let decoded = path.removingPercentEncoding,
              !decoded.contains("..") else { return nil }
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

    var results: [AutoEqEntry] { rankByTitle(entries, query: query) { $0.title } }

    /// Index is ~500 KB today; refuse a wildly larger response rather than
    /// buffering whatever the network hands us.
    nonisolated static let maxIndexBytes = 12_000_000
    nonisolated static let maxPresetBytes = 200_000

    nonisolated static let host = "raw.githubusercontent.com"

    nonisolated static func fetch(_ url: URL, limit: Int) async throws -> Data {
        try await PinnedHTTP.fetch(PinnedHTTP.request(url, accept: "text/plain", allowing: [host]),
                                   limit: limit, allowing: [host])
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
                entries = await Self.parsedIndex(text)
                state = entries.isEmpty ? .failed("Index was empty") : .ready
                DebugLog.shared.log("AutoEq index: \(entries.count) headphones")
            } catch {
                let why = SafeText.scrubbed(
                    AutoEqService.describe(AutoEqService.mapped(error, host: Self.host)))
                state = .failed(why)
                DebugLog.shared.log("AutoEq index failed: \(why)")
            }
        }
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    /// Index lines look like:
    ///   `- [Sennheiser HD 650](./oratory1990/over-ear/Sennheiser%20HD%20650)`
    nonisolated static let maxIndexEntries = 20_000
    nonisolated static let maxIndexTitleLength = 120
    nonisolated static let maxIndexPathLength = 400

    nonisolated static func parsedIndex(_ markdown: String) async -> [AutoEqEntry] {
        parseIndex(markdown)
    }

    nonisolated static func parseIndex(_ markdown: String) -> [AutoEqEntry] {
        var out: [AutoEqEntry] = []
        for line in markdown.split(whereSeparator: \.isNewline) {
            guard out.count < maxIndexEntries else { break }
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- [") || t.hasPrefix("* [") else { continue }
            guard let close = t.firstIndex(of: "]"),
                  let open = t.firstIndex(of: "("),
                  let end = t.lastIndex(of: ")"),
                  open < end else { continue }

            let rawTitle = String(t[t.index(t.startIndex, offsetBy: 3)..<close])
            var path = String(t[t.index(after: open)..<end])
            if path.hasPrefix("./") { path.removeFirst(2) }
            // Skip the doc links at the top of the README (INDEX.md, RANKING.md…).
            guard path.contains("/"), !path.hasSuffix(".md"), !path.hasPrefix("http") else { continue }
            guard rawTitle.count <= maxIndexTitleLength,
                  path.count <= maxIndexPathLength else { continue }

            let title = SafeText.scrubbed(rawTitle, limit: maxIndexTitleLength)
            guard !title.isEmpty else { continue }
            let rawSource = path.split(separator: "/").first
                .map { $0.replacingOccurrences(of: "%20", with: " ") } ?? ""
            let source = SafeText.scrubbed(rawSource, limit: maxIndexTitleLength)
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

// MARK: - Published presets as a correction source

/// The published-file path, behind the same seam as the optimizer.
///
/// It cannot honour `DeviceEQLimits`: the files were fitted for a generic
/// 10-band equalizer with no gain ceiling, and the fit is fixed at publication
/// time. What it can do is say so, instead of letting the device quietly
/// reshape the curve on the way in.
extension AutoEqIndex: CorrectionSource {
    var displayName: String { "AutoEq published preset" }

    /// Why a requested frequency ceiling went unhonoured, or nil when none was
    /// asked for.
    ///
    /// A published file was fitted once, for everyone, long before this
    /// request; there is no optimizer run here to constrain. Saying so is the
    /// only honest answer — dropping the request quietly would leave the user
    /// believing the curve stops where they asked it to. Separate from the
    /// download so the wording can be checked without one.
    nonisolated static func ceilingWarning(for options: CorrectionOptions,
                                           limits: DeviceEQLimits) -> String? {
        guard let ceiling = options.correctionCeiling(for: limits) else { return nil }
        return "the \(CorrectionOptions.describeCeiling(ceiling)) limit was not applied — "
            + "a published preset is fitted at publication time; "
            + "use “Fit to my device” to have the correction stop there"
    }

    func prepare() { loadIfNeeded() }

    func search(_ query: String) -> [CorrectionCandidate] {
        rankByTitle(entries, query: query) { $0.title }.map {
            CorrectionCandidate(title: $0.title, source: $0.source, form: nil,
                                rig: nil, token: $0.path)
        }
    }

    func correction(for candidate: CorrectionCandidate,
                    shapedFor limits: DeviceEQLimits,
                    options rawOptions: CorrectionOptions) async throws -> CorrectionResult {
        let options = rawOptions.quantized()
        let entry = AutoEqEntry(title: candidate.title, source: candidate.source,
                                path: candidate.token)
        let file: ParametricEQFile
        do {
            file = try await Self.fetchPreset(entry)
        } catch {
            throw AutoEqService.mapped(error, host: Self.host)
        }

        // Both of these are things the caller asked for that this path cannot
        // deliver, and both are reported here rather than by whoever happens to
        // be presenting the result — a caller that forgets to ask would
        // otherwise apply a correction that quietly ignored half the request.
        var warnings: [String] = []
        if let unhonoured = Self.ceilingWarning(for: options, limits: limits) {
            warnings.append(unhonoured)
        }
        if let unhonoured = AutoEqService.unhonouredTargetWarning(for: options) {
            warnings.append(unhonoured)
        }
        if let unhonoured = AutoEqService.unhonouredPersonalizationWarning(for: options) {
            warnings.append(unhonoured)
        }
        let reshaped = file.bands.prefix(limits.bandCount).filter { !limits.admits($0) }.count
        if reshaped > 0 {
            warnings.append("\(reshaped) band(s) fall outside what the device accepts and will be clamped")
        }
        if abs(file.preamp) > limits.maxPreamp {
            warnings.append(String(format: "pre-gain %.1f dB exceeds the device's ±%.0f dB",
                                   file.preamp, limits.maxPreamp))
        }
        return CorrectionResult(
            file: file,
            provenance: "\(candidate.title) · \(candidate.detail) → published preset",
            warnings: warnings)
    }
}
