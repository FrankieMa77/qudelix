import Foundation

struct DeviceEQLimits: Equatable {
    var bandCount: Int
    var minGain: Double = -12
    var maxGain: Double = 12
    var minQ: Double = 0.1
    var maxQ: Double = 10
    var minFc: Double = 20
    var maxFc: Double = 20000
    var maxPreamp: Double = EQHeadroom.range.upperBound

    var maxFilterFc: Double = 16000

    static func qudelix(bandCount: Int) -> DeviceEQLimits {
        DeviceEQLimits(bandCount: max(1, bandCount))
    }

    func admits(_ band: QxEqBandValue) -> Bool {
        Double(band.freq) >= minFc && Double(band.freq) <= maxFc
            && band.gain >= minGain && band.gain <= maxGain
            && band.q >= minQ && band.q <= maxQ
    }
}

struct CorrectionOptions: Equatable {
    var bassBoostGain: Double = 0
    var tilt: Double = 0
    var target: String?

    var maxCorrectionHz: Double?
}

extension CorrectionOptions {
    static let minCorrectionHz: Double = 8000

    func correctionCeiling(for limits: DeviceEQLimits) -> Double? {
        guard let asked = maxCorrectionHz, asked.isFinite else { return nil }
        return min(max(asked, Self.minCorrectionHz), limits.maxFc)
    }

    static func describeCeiling(_ hz: Double) -> String {
        String(format: "%.1f kHz", hz / 1000)
    }

    static let bassRange: ClosedRange<Double> = -6...6
    static let tiltRange: ClosedRange<Double> = -1...1
    static let bassStep = 0.5
    static let tiltStep = 0.05

    func quantized() -> CorrectionOptions {
        var out = self
        out.bassBoostGain = Self.snap(bassBoostGain, step: Self.bassStep, into: Self.bassRange)
        out.tilt = Self.snap(tilt, step: Self.tiltStep, into: Self.tiltRange)
        out.maxCorrectionHz = maxCorrectionHz.flatMap { $0.isFinite ? $0.rounded() : nil }
        return out
    }

    static func snap(_ value: Double, step: Double,
                     into range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return 0 }
        let stepped = (value / step).rounded() * step
        let tidied = (stepped * 10000).rounded() / 10000
        return min(max(tidied, range.lowerBound), range.upperBound)
    }
}

struct CorrectionCandidate: Identifiable, Hashable {
    let title: String
    let source: String
    let form: String?
    let rig: String?
    let token: String

    var id: String { "\(source)\u{1}\(rig ?? "")\u{1}\(title)\u{1}\(token)" }

    var detail: String {
        let limit = AutoEqService.maxCatalogueStringLength
        let rigText = SafeText.scrubbed(rig ?? "", limit: limit)
            .trimmingCharacters(in: .whitespaces)
        let sourceText = SafeText.scrubbed(source, limit: limit)
        return rigText.isEmpty ? sourceText : "\(sourceText) · \(rigText)"
    }
}

struct CorrectionResult {
    var file: ParametricEQFile
    var provenance: String
    var warnings: [String] = []
    var preference: PreferenceScore.Reading?
}

enum CorrectionError: LocalizedError {
    case offline(host: String, why: String)
    case server(host: String, status: Int, detail: String?)
    case badResponse(String)
    case noFilters
    case nothingToDo
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .offline(let host, let why):
            return "Couldn't reach \(host) — \(why)"
        case .server(let host, let status, let detail):
            let base = status >= 500
                ? "\(host) failed to build this correction (HTTP \(status))"
                : "\(host) rejected the request (HTTP \(status))"
            guard let detail, !detail.isEmpty else { return base + "." }
            return "\(base): \(detail)"
        case .badResponse(let why):
            return "The server sent a response this app couldn't read — \(why)"
        case .noFilters:
            return "The optimizer returned no filters for that measurement."
        case .nothingToDo:
            return "The correction that came back is smaller than the smallest step "
                + "this device can take — applying it would flatten the EQ rather "
                + "than change what you hear."
        case .unavailable(let why):
            return why
        }
    }
}

@MainActor
protocol CorrectionSource: AnyObject {
    var displayName: String { get }

    func prepare()

    func search(_ query: String) -> [CorrectionCandidate]

    func correction(for candidate: CorrectionCandidate,
                    shapedFor limits: DeviceEQLimits,
                    options: CorrectionOptions) async throws -> CorrectionResult
}

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, limit: Int) async throws -> Data
}

struct PinnedTransport: HTTPTransport {
    let hosts: Set<String>

    init(hosts: Set<String> = [AutoEqService.host]) { self.hosts = hosts }

    func send(_ request: URLRequest, limit: Int) async throws -> Data {
        try await PinnedHTTP.fetch(request, limit: limit, allowing: hosts)
    }
}

struct AutoEqMeasurement: Hashable {
    let source: String
    let form: String?
    let rig: String?
}

struct AutoEqModel: Hashable {
    let name: String
    let measurements: [AutoEqMeasurement]
}

struct AutoEqTarget: Hashable {
    let label: String
    let recommended: [AutoEqMeasurement]
    let compatible: [AutoEqMeasurement]

    var form: String? {
        let forms = Set((recommended + compatible).compactMap(\.form))
        return forms.count == 1 ? forms.first : nil
    }
}

struct AutoEqTargetGroup: Identifiable {
    let form: String?
    let targets: [AutoEqTarget]
    var id: String { form ?? "\u{1}other" }
}

enum AutoEqFilterType: String, Codable {
    case lowShelf = "LOW_SHELF"
    case highShelf = "HIGH_SHELF"
    case peaking = "PEAKING"

    var qxFilter: QxFilter {
        switch self {
        case .lowShelf: return .lowShelf
        case .highShelf: return .highShelf
        case .peaking: return .peak
        }
    }
}

struct EqualizeRequest: Encodable, Equatable {
    var name: String
    var source: String
    var rig: String?
    var target: String
    var parametricEq = true
    var parametricEqConfig: ParametricEQConfig
    var bassBoostGain: Double?
    var bassBoostFc: Double?
    var bassBoostQ: Double?
    var trebleBoostGain: Double?
    var tilt: Double?
    var response = ResponseRequirements()

    enum CodingKeys: String, CodingKey {
        case name, source, rig, target, tilt, response
        case parametricEq = "parametric_eq"
        case parametricEqConfig = "parametric_eq_config"
        case bassBoostGain = "bass_boost_gain"
        case bassBoostFc = "bass_boost_fc"
        case bassBoostQ = "bass_boost_q"
        case trebleBoostGain = "treble_boost_gain"
    }
}

struct ResponseRequirements: Encodable, Equatable {
    var frFStep: Double = 1.059463
    var frFields: [String] = ["frequency", "error_smoothed", "error"]
    var base64fp16 = false

    enum CodingKeys: String, CodingKey {
        case frFStep = "fr_f_step"
        case frFields = "fr_fields"
        case base64fp16
    }
}

struct ParametricEQConfig: Encodable, Equatable {
    var optimizer: OptimizerConfig
    var filterDefaults: FilterDefaults
    var filters: [FilterSpec]

    enum CodingKeys: String, CodingKey {
        case optimizer, filters
        case filterDefaults = "filter_defaults"
    }
}

struct OptimizerConfig: Encodable, Equatable {
    var minF: Double
    var maxF: Double
    var maxTime: Double
    var minStd: Double

    enum CodingKeys: String, CodingKey {
        case minF = "min_f"
        case maxF = "max_f"
        case maxTime = "max_time"
        case minStd = "min_std"
    }
}

struct FilterDefaults: Encodable, Equatable {
    var minFc: Double
    var maxFc: Double
    var minQ: Double
    var maxQ: Double
    var minGain: Double
    var maxGain: Double

    enum CodingKeys: String, CodingKey {
        case minFc = "min_fc"
        case maxFc = "max_fc"
        case minQ = "min_q"
        case maxQ = "max_q"
        case minGain = "min_gain"
        case maxGain = "max_gain"
    }
}

struct FilterSpec: Encodable, Equatable {
    var type: AutoEqFilterType
    var fc: Double?
    var q: Double?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(fc, forKey: .fc)
        try c.encodeIfPresent(q, forKey: .q)
    }

    enum CodingKeys: String, CodingKey { case type, fc, q }
}

struct EqualizeResponse: Decodable {
    var parametricEq: PEQResult
    var fr: FrequencyResponse?

    enum CodingKeys: String, CodingKey {
        case parametricEq = "parametric_eq"
        case fr
    }
}

struct FrequencyResponse: Decodable {
    var frequency: [Double]?
    var error: [Double]?
    var errorSmoothed: [Double]?

    enum CodingKeys: String, CodingKey {
        case frequency, error
        case errorSmoothed = "error_smoothed"
    }
}

struct PEQResult: Decodable {
    var fs: Double?
    var filters: [PEQFilter]
    var preamp: Double?
}

struct PEQFilter: Decodable {
    var type: String
    var fc: Double
    var q: Double
    var gain: Double
}

struct CachedCorrection {
    var file: ParametricEQFile
    var warnings: [String] = []
    var preference: PreferenceScore.Reading?
}

struct LastGoodCorrections {
    static let capacity = 24

    private var byKey: [String: CachedCorrection] = [:]
    private var recency: [String] = []

    var count: Int { byKey.count }

    mutating func value(for key: String) -> CachedCorrection? {
        guard let cached = byKey[key] else { return nil }
        touch(key)
        return cached
    }

    mutating func store(_ cached: CachedCorrection, for key: String) {
        byKey[key] = cached
        touch(key)
        while recency.count > Self.capacity {
            byKey.removeValue(forKey: recency.removeFirst())
        }
    }

    private mutating func touch(_ key: String) {
        if let i = recency.firstIndex(of: key) { recency.remove(at: i) }
        recency.append(key)
    }
}

@MainActor
final class AutoEqService: ObservableObject, CorrectionSource {
    nonisolated static let host = "autoeq.app"
    nonisolated static let base = "https://autoeq.app"

    nonisolated static let maxEntriesBytes = 8_000_000
    nonisolated static let maxTargetsBytes = 1_000_000
    nonisolated static let maxEqualizeBytes = 4_000_000

    nonisolated static let optimizerMaxTime = 0.4
    nonisolated static let optimizerMinStd = 0.008

    nonisolated static let maxFittedQ = 6.0
    nonisolated static let minFittedQ = 0.2

    nonisolated static let lowShelfFc = 105.0
    nonisolated static let highShelfFc = 10000.0
    nonisolated static let shelfQ = 0.7

    nonisolated static let displayLimit = 6

    enum State: Equatable { case idle, loading, ready, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var models: [AutoEqModel] = []

    @Published private(set) var targets: [AutoEqTarget] = []
    private(set) var loadTask: Task<Void, Never>?
    private var refreshAfter: Date?
    private var refreshing = false

    static let shared = AutoEqService()
    var maxAge: TimeInterval = 6 * 3600
    var retryAfter: TimeInterval = 300

    private var lastGood = LastGoodCorrections()

    private let transport: HTTPTransport

    init(transport: HTTPTransport = PinnedTransport()) {
        self.transport = transport
    }

    nonisolated var displayName: String { "AutoEq optimizer" }

    func prepare() {
        let stale = isStale
        guard loadTask == nil || isFailed || stale else { return }
        if !stale { state = .loading }
        refreshing = stale
        loadTask = Task { [weak self] in
            guard let self else { return }
            async let entries = self.fetchEntries()
            async let targetList = self.fetchTargets()
            do {
                let models = try await entries
                self.models = models
                self.state = models.isEmpty ? .failed("Catalogue was empty") : .ready
                self.refreshAfter = Date().addingTimeInterval(self.maxAge)
                self.refreshing = false
                DebugLog.shared.log("AutoEq catalogue: \(models.count) models")
                if let fresh = try? await targetList { self.targets = fresh }
            } catch {
                _ = try? await targetList
                let why = SafeText.scrubbed(Self.describe(error))
                DebugLog.shared.log("AutoEq catalogue failed: \(why)")
                if self.refreshing {
                    self.refreshing = false
                    self.refreshAfter = Date().addingTimeInterval(self.retryAfter)
                    return
                }
                self.state = .failed(why)
                self.loadTask = nil
            }
        }
    }

    private var isStale: Bool {
        guard case .ready = state, !refreshing, let refreshAfter else { return false }
        return Date() >= refreshAfter
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    func search(_ query: String) -> [CorrectionCandidate] {
        let limit = Self.maxCatalogueStringLength
        return rankByTitle(models, query: query) { $0.name }.flatMap { model in
            let title = SafeText.scrubbed(model.name, limit: limit)
            return model.measurements.map { measurement in
                let source = SafeText.scrubbed(measurement.source, limit: limit)
                let exact = title == model.name && source == measurement.source
                return CorrectionCandidate(
                    title: title, source: source,
                    form: measurement.form.map { SafeText.scrubbed($0, limit: limit) },
                    rig: measurement.rig,
                    token: exact ? "" : "\(model.name)\u{1}\(measurement.source)")
            }
        }
    }

    nonisolated static func requestIdentity(of candidate: CorrectionCandidate)
        -> (model: String, source: String) {
        let parts = candidate.token.split(separator: "\u{1}", maxSplits: 1,
                                          omittingEmptySubsequences: false)
        guard parts.count == 2 else { return (candidate.title, candidate.source) }
        return (String(parts[0]), String(parts[1]))
    }

    #if DEBUG
    func seedForPreview(_ seeded: [AutoEqModel], targets: [AutoEqTarget] = []) {
        models = seeded
        self.targets = targets
        state = .ready
        loadTask = Task {}
    }
    #endif

    private func fetchEntries() async throws -> [AutoEqModel] {
        let data = try await get("/entries", limit: Self.maxEntriesBytes)
        return try await Self.parsedEntries(data)
    }

    private func fetchTargets() async throws -> [AutoEqTarget] {
        let data = try await get("/targets", limit: Self.maxTargetsBytes)
        return try Self.parseTargets(data)
    }

    nonisolated static let maxCatalogueStringLength = 120
    nonisolated static let maxCatalogueEntries = 20_000
    nonisolated static let maxCatalogueTargets = 2_000

    nonisolated static func admissible(_ s: String) -> Bool {
        !s.isEmpty && s.count <= maxCatalogueStringLength && !s.contains("\u{1}")
    }

    nonisolated static func parsedEntries(_ data: Data) async throws -> [AutoEqModel] {
        try parseEntries(data)
    }

    nonisolated static func parseEntries(_ data: Data) throws -> [AutoEqModel] {
        struct Measurement: Decodable {
            var form: String?
            var rig: String?
            var source: String
        }
        let raw: [String: [Measurement]]
        do {
            raw = try JSONDecoder().decode([String: [Measurement]].self, from: data)
        } catch {
            throw CorrectionError.badResponse("the headphone catalogue didn't parse")
        }
        var folded: [(folded: String, name: String)] = []
        folded.reserveCapacity(raw.count)
        for name in raw.keys { folded.append((folded: name.lowercased(), name: name)) }
        folded.sort { left, right in
            left.folded == right.folded ? left.name < right.name : left.folded < right.folded
        }
        let names = folded.map(\.name)
        var out: [AutoEqModel] = []
        for name in names {
            guard out.count < maxCatalogueEntries else { break }
            guard admissible(name) else { continue }
            var seen = Set<String>()
            var measurements: [AutoEqMeasurement] = []
            for m in raw[name] ?? [] {
                guard let rig = m.rig, admissible(rig), admissible(m.source) else { continue }
                if let form = m.form, !admissible(form) { continue }
                guard seen.insert("\(m.source)\u{1}\(rig)").inserted else { continue }
                measurements.append(AutoEqMeasurement(source: m.source, form: m.form,
                                                      rig: rig))
            }
            guard !measurements.isEmpty else { continue }
            out.append(AutoEqModel(name: name, measurements: measurements))
        }
        return out
    }

    nonisolated static func parseTargets(_ data: Data) throws -> [AutoEqTarget] {
        struct Ref: Decodable {
            var source: String
            var form: String?
            var rig: String?
        }
        struct Target: Decodable {
            var label: String
            var recommended: [Ref]?
            var compatible: [Ref]?
        }
        let raw: [Target]
        do {
            raw = try JSONDecoder().decode([Target].self, from: data)
        } catch {
            throw CorrectionError.badResponse("the target list didn't parse")
        }
        let toMeasurements: ([Ref]?) -> [AutoEqMeasurement] = { refs in
            (refs ?? []).compactMap { ref in
                guard admissible(ref.source) else { return nil }
                if let rig = ref.rig, !admissible(rig) { return nil }
                if let form = ref.form, !admissible(form) { return nil }
                return AutoEqMeasurement(
                    source: ref.source,
                    form: ref.form.map { SafeText.scrubbed($0, limit: maxCatalogueStringLength) },
                    rig: ref.rig)
            }
        }
        var seen = Set<String>()
        var out: [AutoEqTarget] = []
        for target in raw {
            guard out.count < maxCatalogueTargets else { break }
            guard admissible(target.label),
                  SafeText.scrubbed(target.label, limit: maxCatalogueStringLength) == target.label,
                  seen.insert(target.label).inserted else { continue }
            out.append(AutoEqTarget(label: target.label,
                                    recommended: toMeasurements(target.recommended),
                                    compatible: toMeasurements(target.compatible)))
        }
        return out
    }

    nonisolated static func target(for measurement: AutoEqMeasurement,
                       in targets: [AutoEqTarget]) -> String {
        func matches(_ ref: AutoEqMeasurement) -> Bool {
            guard ref.source == measurement.source else { return false }
            if let f = ref.form, let mf = measurement.form, f != mf { return false }
            if let r = ref.rig, r != measurement.rig { return false }
            return true
        }
        if let t = targets.first(where: { $0.recommended.contains(where: matches) }) {
            return t.label
        }
        if let t = targets.first(where: { $0.compatible.contains(where: matches) }) {
            return t.label
        }
        let form = measurement.form ?? "over-ear"
        return form == "over-ear" ? "Harman over-ear 2018" : "Harman in-ear 2019"
    }

    nonisolated static func groupedTargets(_ targets: [AutoEqTarget]) -> [AutoEqTargetGroup] {
        let byForm = Dictionary(grouping: targets, by: \.form)
        let known = ["over-ear", "in-ear", "earbud"].compactMap { form in
            byForm[form].map { AutoEqTargetGroup(form: form, targets: $0) }
        }
        let rest = byForm[nil].map { [AutoEqTargetGroup(form: nil, targets: $0)] } ?? []
        return known + rest
    }

    nonisolated static func targetSelection(_ picked: String?, pickedByUser: Bool,
                                            in targets: [AutoEqTarget]) -> String? {
        guard let picked else { return nil }
        if pickedByUser { return picked }
        return targets.contains { $0.label == picked } ? picked : nil
    }

    nonisolated static func unhonouredTargetWarning(for options: CorrectionOptions) -> String? {
        guard let target = options.target else { return nil }
        return "the “\(target)” target was not applied — a published preset is fitted to "
            + "one target at publication time; use “Fit to my device” to choose one"
    }

    nonisolated static func unhonouredPersonalizationWarning(
        for options: CorrectionOptions) -> String? {
        var asked: [String] = []
        if options.bassBoostGain != 0 {
            asked.append(String(format: "%+.1f dB bass", options.bassBoostGain))
        }
        if options.tilt != 0 {
            asked.append(String(format: "%+.2f dB/oct tilt", options.tilt))
        }
        guard !asked.isEmpty else { return nil }
        return "the \(asked.joined(separator: " and ")) "
            + (asked.count == 1 ? "was" : "were")
            + " not applied — a published preset is fitted at publication time; "
            + "use “Fit to my device” to shape the target"
    }

    nonisolated static func deviceFilters(bandCount: Int,
                                          ceiling: Double? = nil) -> [FilterSpec] {
        let n = max(1, bandCount)
        guard n >= 3 else {
            return Array(repeating: FilterSpec(type: .peaking), count: n)
        }
        let treble = min(highShelfFc, ceiling ?? highShelfFc)
        return [FilterSpec(type: .lowShelf, fc: lowShelfFc, q: shelfQ)]
            + Array(repeating: FilterSpec(type: .peaking), count: n - 2)
            + [FilterSpec(type: .highShelf, fc: treble, q: shelfQ)]
    }

    nonisolated static func config(for limits: DeviceEQLimits,
                                   ceiling: Double? = nil) -> ParametricEQConfig {
        let fitTop = min(limits.maxFc, ceiling ?? limits.maxFc)
        let centreTop = min(limits.maxFc, limits.maxFilterFc, ceiling ?? limits.maxFc)
        return ParametricEQConfig(
            optimizer: OptimizerConfig(minF: limits.minFc, maxF: fitTop,
                                       maxTime: optimizerMaxTime, minStd: optimizerMinStd),
            filterDefaults: FilterDefaults(
                minFc: limits.minFc,
                maxFc: centreTop,
                minQ: max(limits.minQ, minFittedQ),
                maxQ: min(limits.maxQ, maxFittedQ),
                minGain: limits.minGain,
                maxGain: limits.maxGain),
            filters: deviceFilters(bandCount: limits.bandCount, ceiling: centreTop))
    }

    nonisolated static func requestBody(model: String, source: String, rig: String?, target: String,
                            limits: DeviceEQLimits,
                            options: CorrectionOptions) -> EqualizeRequest {
        EqualizeRequest(
            name: model,
            source: source,
            rig: rig,
            target: target,
            parametricEqConfig: config(for: limits,
                                       ceiling: options.correctionCeiling(for: limits)),
            bassBoostGain: options.bassBoostGain == 0 ? nil : options.bassBoostGain,
            tilt: options.tilt == 0 ? nil : options.tilt)
    }

    nonisolated static func encode(_ body: EqualizeRequest) throws -> Data {
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw CorrectionError.badResponse("the request couldn't be built")
        }
    }

    nonisolated static func correction(from data: Data,
                           limits: DeviceEQLimits) throws -> (file: ParametricEQFile,
                                                              warnings: [String],
                                                              preference: PreferenceScore.Reading?) {
        let decoded: EqualizeResponse
        do {
            decoded = try JSONDecoder().decode(EqualizeResponse.self, from: data)
        } catch {
            throw CorrectionError.badResponse("no usable filter set in it")
        }
        guard !decoded.parametricEq.filters.isEmpty else { throw CorrectionError.noFilters }

        var file = ParametricEQFile()
        var unknownTypes = 0
        var outOfRange = 0

        let returned = decoded.parametricEq.filters
        for f in returned.prefix(limits.bandCount) {
            guard let type = AutoEqFilterType(rawValue: f.type.uppercased()) else {
                unknownTypes += 1
                continue
            }
            guard f.fc.isFinite, f.fc >= 1, f.fc <= 100_000,
                  f.gain.isFinite, f.q.isFinite, f.q > 0 else {
                outOfRange += 1
                continue
            }
            let band = QxEqBandValue(filter: type.qxFilter, freq: Int(f.fc.rounded()),
                                     gain: f.gain, q: f.q)
            if !limits.admits(band) { outOfRange += 1 }
            file.bands.append(band)
        }
        guard !file.bands.isEmpty else { throw CorrectionError.noFilters }
        guard changesAnything(file.bands) else { throw CorrectionError.nothingToDo }

        let preamp = decoded.parametricEq.preamp ?? 0
        file.preamp = preamp.isFinite ? preamp : 0

        var warnings: [String] = []
        if abs(file.preamp) > limits.maxPreamp {
            let capped = max(-limits.maxPreamp, min(limits.maxPreamp, file.preamp))
            warnings.append(String(
                format: "pre-gain %.1f dB exceeds the device's ±%.0f dB — it will be set to %.1f dB, leaving %.1f dB less headroom than the fit assumes",
                file.preamp, limits.maxPreamp, capped, abs(file.preamp) - limits.maxPreamp))
        }
        if unknownTypes > 0 {
            warnings.append("\(unknownTypes) filter(s) of an unrecognised type were skipped")
        }
        if outOfRange > 0 {
            warnings.append("\(outOfRange) filter(s) came back outside the device's range")
        }
        let beyondMode = returned.count - limits.bandCount
        if beyondMode > 0 {
            warnings.append("\(beyondMode) filter(s) beyond the \(limits.bandCount)-band mode were dropped")
        }
        if askedForShelves(bandCount: limits.bandCount) {
            if !file.bands.contains(where: { $0.filter == .lowShelf }) {
                warnings.append("the fit used no low shelf — the deepest bass is left as measured")
            }
            if !file.bands.contains(where: { $0.filter == .highShelf }) {
                warnings.append("the fit used no high shelf — the top octave is left as measured")
            }
        }
        return (file, warnings, residualScore(decoded, file: file, limits: limits))
    }

    nonisolated static func askedForShelves(bandCount: Int) -> Bool {
        max(1, bandCount) >= 3
    }

    nonisolated static func changesAnything(_ bands: [QxEqBandValue]) -> Bool {
        bands.contains { band in
            guard band.filter != .bypass else { return false }
            guard band.filter.hasGain else { return true }
            return band.gain.isFinite && (band.gain * QxScale.gain).rounded() != 0
        }
    }

    nonisolated static func residualScore(_ decoded: EqualizeResponse,
                                          file: ParametricEQFile,
                                          limits: DeviceEQLimits) -> PreferenceScore.Reading? {
        guard let freqs = decoded.fr?.frequency,
              let error = decoded.fr?.errorSmoothed ?? decoded.fr?.error,
              freqs.count == error.count, !freqs.isEmpty else { return nil }
        guard freqs.count <= PreferenceScore.maxInputPoints else { return nil }
        let applied = Array(file.bands.prefix(limits.bandCount))
        let correction = EQCurve.response(bands: applied, preGain: 0, at: freqs)
        guard correction.count == error.count else { return nil }
        let residual = zip(error, correction).map(+)
        return PreferenceScore.reading(frequencies: freqs, errorDb: residual)
    }

    func equalize(model: String, source: String, rig: String?, target: String,
                  bandCount: Int, bassBoostGain: Double, tilt: Double) async throws -> ParametricEQFile {
        try await equalize(model: model, source: source, rig: rig, target: target,
                           limits: .qudelix(bandCount: bandCount),
                           options: CorrectionOptions(bassBoostGain: bassBoostGain,
                                                      tilt: tilt, target: target)).0
    }

    func equalize(model: String, source: String, rig: String?, target: String,
                  limits: DeviceEQLimits,
                  options rawOptions: CorrectionOptions) async throws
        -> (ParametricEQFile, [String], PreferenceScore.Reading?) {
        let options = rawOptions.quantized()
        let body = Self.requestBody(model: model, source: source, rig: rig, target: target,
                                    limits: limits, options: options)
        guard let url = URL(string: Self.base + "/equalize") else {
            throw CorrectionError.unavailable("Bad API URL.")
        }
        var request = try PinnedHTTP.request(url, accept: "application/json",
                                             allowing: [Self.host])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encode(body)

        let data: Data
        do {
            data = try await transport.send(request, limit: Self.maxEqualizeBytes)
        } catch {
            throw Self.mapped(error)
        }
        return try Self.correction(from: data, limits: limits)
    }

    nonisolated static func cacheKey(model: String, source: String, rig: String?,
                                     target: String, limits: DeviceEQLimits,
                                     options rawOptions: CorrectionOptions) -> String {
        let options = rawOptions.quantized()
        return [model, source, rig ?? "", target, String(limits.bandCount),
                String(options.bassBoostGain), String(options.tilt),
                options.correctionCeiling(for: limits).map { String($0) } ?? ""]
            .joined(separator: "\u{1}")
    }

    func correction(for candidate: CorrectionCandidate,
                    shapedFor limits: DeviceEQLimits,
                    options rawOptions: CorrectionOptions) async throws -> CorrectionResult {
        let options = rawOptions.quantized()
        let identity = Self.requestIdentity(of: candidate)
        let measurement = AutoEqMeasurement(source: identity.source, form: candidate.form,
                                            rig: candidate.rig)
        var target = options.target
        if target == nil {
            if targets.isEmpty { targets = (try? await fetchTargets()) ?? [] }
            target = Self.target(for: measurement, in: targets)
        }
        let chosen = target ?? "Harman over-ear 2018"
        var resolved = options
        resolved.target = chosen

        let targetWasChosen = options.target != nil
        var personalized: [String] = []
        if options.bassBoostGain != 0 {
            personalized.append(String(format: "%+.1f dB bass", options.bassBoostGain))
        }
        if options.tilt != 0 {
            personalized.append(String(format: "%+.2f dB/oct tilt", options.tilt))
        }

        let ceiling = resolved.correctionCeiling(for: limits)
        let provenance = "\(SafeText.scrubbed(candidate.title, limit: Self.maxCatalogueStringLength))"
            + " · \(candidate.detail) → \(chosen)"
            + (targetWasChosen ? " (your choice)" : "")
            + " · \(limits.bandCount) bands"
            + personalized.map { " · \($0)" }.joined()
            + (ceiling.map { " · fitted up to \(CorrectionOptions.describeCeiling($0))" } ?? "")

        let key = Self.cacheKey(model: identity.model, source: identity.source,
                                rig: candidate.rig, target: chosen,
                                limits: limits, options: resolved)
        if let cached = lastGood.value(for: key) {
            return CorrectionResult(file: cached.file, provenance: provenance,
                                    warnings: cached.warnings,
                                    preference: cached.preference)
        }
        do {
            let (file, warnings, preference) = try await equalize(
                model: identity.model, source: identity.source,
                rig: candidate.rig, target: chosen,
                limits: limits, options: resolved)
            let scored = PreferenceScore.appliesTo(form: candidate.form) ? preference : nil
            lastGood.store(CachedCorrection(file: file, warnings: warnings,
                                            preference: scored), for: key)
            return CorrectionResult(file: file, provenance: provenance,
                                    warnings: warnings, preference: scored)
        } catch {
            guard let cached = lastGood.value(for: key) else { throw error }
            return CorrectionResult(
                file: cached.file, provenance: provenance,
                warnings: cached.warnings
                    + ["reused the last correction that worked — \(Self.describe(error))"],
                preference: cached.preference)
        }
    }

    private func get(_ path: String, limit: Int) async throws -> Data {
        guard let url = URL(string: Self.base + path) else {
            throw CorrectionError.unavailable("Bad API URL.")
        }
        do {
            return try await transport.send(
                try PinnedHTTP.request(url, accept: "application/json",
                                       allowing: [Self.host]),
                limit: limit)
        } catch {
            throw Self.mapped(error)
        }
    }

    nonisolated static func mapped(_ error: Error, host: String = AutoEqService.host) -> Error {
        if let c = error as? CorrectionError { return c }
        if let http = error as? HTTPStatusError {
            return CorrectionError.server(host: host, status: http.status,
                                          detail: detail(from: http.body,
                                                         status: http.status))
        }
        guard let url = error as? URLError else { return error }
        switch url.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed:
            return CorrectionError.offline(host: host, why: "no network connection.")
        case .timedOut:
            return CorrectionError.offline(host: host, why: "it didn't answer in time.")
        case .dataLengthExceedsMaximum:
            return CorrectionError.badResponse("it was far larger than expected")
        default:
            return CorrectionError.offline(host: host, why: url.localizedDescription)
        }
    }

    nonisolated static func detail(from body: String, status: Int) -> String? {
        let fallback = "the service answered \(status)"
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] else {
            return fallback
        }
        if let text = detail as? String { return SafeText.scrubbed(text) }
        if let items = detail as? [[String: Any]] {
            let messages = items.compactMap { $0["msg"] as? String }
            return messages.isEmpty ? fallback
                : SafeText.scrubbed(messages.joined(separator: "; "))
        }
        return fallback
    }

    nonisolated static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
