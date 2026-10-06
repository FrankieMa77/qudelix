import Foundation

struct ParametricEQFile {
    var preamp: Double = 0
    var bands: [QxEqBandValue] = []

    var droppedBands = 0

    var notes: [String] = []

    static let defaultShelfQ = 0.71

    static let maxLineLength = 4096

    private static let preampPattern =
        #/(?i)preamp\s*(?::\s*)?([+-]?[\d.,]+)\s*dB/#
    private static let offPattern =
        #/(?i)filter\s*(?:\d+\s*)?(?::\s*)?OFF(?:\s|$)/#
    private static let filterPattern =
        #/(?i)filter\s*(?:\d+\s*)?(?::\s*)?(ON|OFF)\s+(PK|PEQ|MODAL|LSC|LSQ|LS|HSC|HSQ|HS|LPQ|LPF|LP|HPQ|HPF|HP)\s+Fc\s+([\d.,]+)\s*Hz\s+Gain\s+([+-]?[\d.,]+)\s*dB(?:\s+(?:Q\s+([\d.,]+)|BW\s+Oct\s+([\d.,]+)))?/#
    private static let passPattern =
        #/(?i)filter\s*(?:\d+\s*)?(?::\s*)?(ON|OFF)\s+(LPQ|LPF|LP|HPQ|HPF|HP)\s+Fc\s+([\d.,]+)\s*Hz(?:\s+Q\s+([\d.,]+))?/#

    static func parse(_ text: String) -> ParametricEQFile? {
        var out = ParametricEQFile()
        var parsed: [QxEqBandValue] = []
        var unreadable = 0
        var preampTotal = 0.0
        var preampLines = 0
        var unreadablePreamps = 0
        var assumedQ = 0

        let body = text.unicodeScalars.first == "\u{FEFF}"
            ? String(text.unicodeScalars.dropFirst()) : text

        for rawLine in body.split(whereSeparator: \.isNewline) {
            guard rawLine.count <= maxLineLength else { continue }
            let line = rawLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if line.isEmpty || line.hasPrefix("#") { continue }

            if let m = try? preampPattern.firstMatch(in: line),
               let p = number(m.1) {
                preampTotal += p
                preampLines += 1
                out.preamp = max(-24, min(24, preampTotal))
                continue
            }

            if (try? offPattern.firstMatch(in: line)) != nil { continue }

            if let m = try? filterPattern.firstMatch(in: line),
               m.1.uppercased() == "ON",
               let filter = filterType(String(m.2)),
               let fc = frequency(m.3), fc >= 1, fc <= 100_000,
               let gain = number(m.4) {
                var q = defaultShelfQ
                if let given = m.5 {
                    guard let value = number(given) else { unreadable += 1; continue }
                    q = value
                } else if let octaves = m.6 {
                    guard let value = number(octaves).flatMap(q(fromOctaves:)) else {
                        unreadable += 1
                        continue
                    }
                    q = value
                } else if filter == .peak {
                    assumedQ += 1
                }
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
               let fc = frequency(m.3), fc >= 1, fc <= 100_000 {
                let q = m.4.flatMap { number($0) } ?? defaultShelfQ
                parsed.append(QxEqBandValue(filter: filter, freq: Int(fc.rounded()),
                                            gain: 0, q: max(0.05, min(20, q))))
                continue
            }

            let lowered = line.lowercased()
            if lowered.hasPrefix("filter") {
                unreadable += 1
            } else if lowered.hasPrefix("preamp") {
                unreadablePreamps += 1
            }
        }

        guard !parsed.isEmpty else { return nil }
        if unreadable > 0 {
            out.notes.append("skipped \(unreadable) filter line"
                + (unreadable == 1 ? "" : "s")
                + " — an unsupported type, or a missing Fc, Gain or Q")
        }
        if unreadablePreamps > 0 {
            out.notes.append("skipped \(unreadablePreamps) Preamp line"
                + (unreadablePreamps == 1 ? "" : "s")
                + " that could not be read")
        }
        if preampLines > 1 {
            out.notes.append("\(preampLines) Preamp lines were added together")
        }
        if assumedQ > 0 {
            out.notes.append("\(assumedQ) peak filter\(assumedQ == 1 ? " has" : "s have") "
                + "no Q or bandwidth — Q \(String(format: "%.2f", defaultShelfQ)) assumed")
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

        if parsed.count > QxEq.maxBandCount {
            out.droppedBands = parsed.count - QxEq.maxBandCount
            parsed = strongest(parsed, keeping: QxEq.maxBandCount)
            out.notes.append("kept the \(QxEq.maxBandCount) filters doing the most work")
        }
        out.bands = nudgingDuplicateCentres(parsed)
        return out
    }

    static let audibleShelfGain = 0.5

    static func strongest(_ bands: [QxEqBandValue], keeping count: Int) -> [QxEqBandValue] {
        guard bands.count > count else { return bands }
        func work(_ band: QxEqBandValue) -> Double {
            switch band.filter {
            case .bypass: return -1
            case .lowShelf, .highShelf:
                return abs(band.gain) >= audibleShelfGain ? .infinity : abs(band.gain)
            default: return band.filter.hasGain ? abs(band.gain) : .infinity
            }
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

    func fitted(toBandCount count: Int) -> ParametricEQFile {
        guard count > 0, bands.count > count else { return self }
        var out = self
        out.bands = Self.strongest(bands, keeping: count)
        out.droppedBands = droppedBands + (bands.count - out.bands.count)
        let needed = EQHeadroom.suggestedPreGain(for: out.bands)
        if needed < preamp - 0.05 {
            out.preamp = needed
            out.notes.append(String(format: "pre-gain lowered to %+.1f dB for the bands that fit",
                                    needed))
        }
        return out
    }

    static func decodeText(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(64))
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        let pairs = bytes.count / 2
        if pairs >= 2 {
            let evenZeros = stride(from: 0, to: pairs * 2, by: 2).filter { bytes[$0] == 0 }.count
            let oddZeros = stride(from: 1, to: pairs * 2, by: 2).filter { bytes[$0] == 0 }.count
            if oddZeros * 2 >= pairs, evenZeros == 0 {
                return String(data: data, encoding: .utf16LittleEndian)
            }
            if evenZeros * 2 >= pairs, oddZeros == 0 {
                return String(data: data, encoding: .utf16BigEndian)
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
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

    private static func frequency(_ text: Substring) -> Double? {
        let groups = text.split(separator: ",", omittingEmptySubsequences: false)
        let grouped = groups.count >= 2
            && (1...3).contains(groups[0].count) && groups[0].first != "0"
            && groups.dropFirst().allSatisfy { $0.count == 3 }
            && text.allSatisfy { ("0"..."9").contains($0) || $0 == "," }
        guard grouped else { return number(text) }
        guard let value = Double(text.replacingOccurrences(of: ",", with: "")),
              value.isFinite else { return nil }
        return value
    }

    private static func q(fromOctaves octaves: Double) -> Double? {
        guard octaves.isFinite, octaves > 0 else { return nil }
        let span = pow(2, octaves)
        let q = span.squareRoot() / (span - 1)
        return q.isFinite && q > 0 ? q : nil
    }
}

struct HTTPStatusError: Error {
    let status: Int
    let body: String
}

enum PinnedHTTP {
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

    static let maxErrorBodyBytes = 2048

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

    private static func run(_ request: URLRequest, limit: Int, allowing hosts: Set<String>,
                            session: URLSession,
                            delegate: URLSessionTaskDelegate) async throws -> Data {
        guard request.url?.scheme == "https", let host = request.url?.host,
              hosts.contains(host), allowedHosts.contains(host) else {
            throw URLError(.badURL)
        }
        let (stream, response) = try await session.bytes(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse else {
            stream.task.cancel()
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
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
    }
}

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

struct AutoEqEntry: Identifiable, Hashable {
    let title: String
    let source: String
    let path: String
    var id: String { path }

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

    static let shared = AutoEqIndex()
    var maxAge: TimeInterval = 6 * 3600
    var retryAfter: TimeInterval = 300
    private var refreshAfter: Date?
    private var refreshing = false
    private(set) var loadTask: Task<Void, Never>?
    private let fetcher: @Sendable (URL, Int) async throws -> Data

    init(fetcher: @escaping @Sendable (URL, Int) async throws -> Data = { url, limit in
        try await AutoEqIndex.fetch(url, limit: limit)
    }) {
        self.fetcher = fetcher
    }

    static let displayLimit = 6

    var results: [AutoEqEntry] { rankByTitle(entries, query: query) { $0.title } }

    nonisolated static let maxIndexBytes = 12_000_000
    nonisolated static let maxPresetBytes = 200_000

    nonisolated static let host = "raw.githubusercontent.com"

    nonisolated static func fetch(_ url: URL, limit: Int) async throws -> Data {
        try await PinnedHTTP.fetch(PinnedHTTP.request(url, accept: "text/plain", allowing: [host]),
                                   limit: limit, allowing: [host])
    }

    #if DEBUG
    func seedForPreview(_ seeded: [AutoEqEntry], query: String) {
        entries = seeded
        state = .ready
        self.query = query
    }
    #endif

    func loadIfNeeded() {
        let stale = isStale
        guard state == .idle || isFailed || stale else { return }
        if !stale { state = .loading }
        refreshing = stale
        loadTask = Task {
            do {
                let data = try await fetcher(Self.indexURL, Self.maxIndexBytes)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw URLError(.cannotDecodeContentData)
                }
                let fresh = await Self.parsedIndex(text)
                refreshing = false
                if fresh.isEmpty && !entries.isEmpty {
                    refreshAfter = Date().addingTimeInterval(retryAfter)
                    return
                }
                entries = fresh
                state = entries.isEmpty ? .failed("Index was empty") : .ready
                refreshAfter = Date().addingTimeInterval(maxAge)
                DebugLog.shared.log("AutoEq index: \(entries.count) headphones")
            } catch {
                let why = SafeText.scrubbed(
                    AutoEqService.describe(AutoEqService.mapped(error, host: Self.host)))
                DebugLog.shared.log("AutoEq index failed: \(why)")
                if refreshing {
                    refreshing = false
                    refreshAfter = Date().addingTimeInterval(retryAfter)
                    return
                }
                state = .failed(why)
            }
        }
    }

    private var isStale: Bool {
        guard state == .ready, !refreshing, let refreshAfter else { return false }
        return Date() >= refreshAfter
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }

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
            let titleStart = t.index(t.startIndex, offsetBy: 3)
            guard let link = t.range(of: "](", range: titleStart..<t.endIndex),
                  let end = closingParenthesis(in: t, after: link.upperBound) else { continue }

            let rawTitle = String(t[titleStart..<link.lowerBound])
            var path = String(t[link.upperBound..<end])
            if path.hasPrefix("./") { path.removeFirst(2) }
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

    nonisolated private static func closingParenthesis(in text: String,
                                                       after start: String.Index) -> String.Index? {
        var depth = 1
        var index = start
        while index < text.endIndex {
            switch text[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index = text.index(after: index)
        }
        return text.lastIndex(of: ")").flatMap { $0 >= start ? $0 : nil }
    }

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

extension AutoEqIndex: CorrectionSource {
    var displayName: String { "AutoEq published preset" }

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
