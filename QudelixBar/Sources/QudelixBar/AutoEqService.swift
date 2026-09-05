import Foundation

// MARK: - The seam

/// What the hardware will actually accept.
///
/// This is handed to a correction source *before* it produces anything, so the
/// source can ask for a curve that already fits. The alternative — take a
/// generic curve and clamp it at the wire — silently gives the user a
/// different curve from the one they picked.
struct DeviceEQLimits: Equatable {
    var bandCount: Int
    var minGain: Double = -12
    var maxGain: Double = 12
    var minQ: Double = 0.1
    var maxQ: Double = 10
    var minFc: Double = 20
    var maxFc: Double = 20000
    /// Pre-gain range; the device takes the same ±12 dB as a band does.
    var maxPreamp: Double = EQHeadroom.range.upperBound

    /// Upper bound for a *filter centre*, as distinct from the range the
    /// correction is fitted over. A peak placed above this spends one of a
    /// handful of bands on a region where it does close to nothing audible.
    var maxFilterFc: Double = 16000

    /// Mirrors the clamps in `QudelixController.updateBand` and `setPreGain`.
    /// Change one and this must follow, or "already legal" stops being true.
    static func qudelix(bandCount: Int) -> DeviceEQLimits {
        DeviceEQLimits(bandCount: max(1, bandCount))
    }

    func admits(_ band: QxEqBandValue) -> Bool {
        Double(band.freq) >= minFc && Double(band.freq) <= maxFc
            && band.gain >= minGain && band.gain <= maxGain
            && band.q >= minQ && band.q <= maxQ
    }
}

/// Personalization applied on top of a published target.
///
/// Both boosts default to zero, which means "the target exactly as its author
/// published it".
struct CorrectionOptions: Equatable {
    /// dB of low-shelf lift added to the target's own bass.
    var bassBoostGain: Double = 0
    /// Overall spectral tilt in dB per octave; negative is darker.
    var tilt: Double = 0
    /// nil lets the source pick the target its measurement is recommended for.
    var target: String?

    /// Upper frequency the correction should be fitted over, in Hz, or nil for
    /// the device's full range.
    ///
    /// This exists because a source that stops at 16 kHz makes everything above
    /// it a bad investment: a boost up there amplifies the codec's own
    /// artefacts, and it is paid for with pre-gain across the *whole* band. It
    /// is deliberately never set automatically — a correction written to the
    /// device outlives whatever happened to be playing when the cutoff was
    /// measured, so the choice belongs to the user.
    ///
    /// It constrains the *request*: the optimizer fits inside it and returns
    /// filters that already stop there. Nothing filters the response.
    var maxCorrectionHz: Double?
}

extension CorrectionOptions {
    /// Lowest ceiling worth sending. Below this a "correction" is a tone
    /// control, and no cutoff a codec produces lands here — a figure this low
    /// means the measurement went wrong, not that the music stops at 5 kHz.
    static let minCorrectionHz: Double = 8000

    /// The requested ceiling made safe for this device, or nil for none.
    ///
    /// Non-finite is treated as absent rather than clamped: NaN has no
    /// intention behind it to honour. Everything else is pulled into
    /// [`minCorrectionHz`, device max] so a wild verdict cannot turn into a
    /// nonsense request.
    func correctionCeiling(for limits: DeviceEQLimits) -> Double? {
        guard let asked = maxCorrectionHz, asked.isFinite else { return nil }
        return min(max(asked, Self.minCorrectionHz), limits.maxFc)
    }

    /// How a ceiling is written wherever a user reads it. One decimal: the
    /// measurement is not precise enough to justify a second.
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

/// One thing a user can pick out of a correction source's catalogue.
struct CorrectionCandidate: Identifiable, Hashable {
    /// Model name, as the catalogue spells it.
    let title: String
    /// Who measured it, e.g. "oratory1990".
    let source: String
    /// "over-ear", "in-ear", "earbud" — nil when the catalogue doesn't say.
    let form: String?
    /// Measurement rig.
    ///
    /// Round-tripped verbatim and never trimmed: two rig names in AutoEq's
    /// index end in a space ("GRAS 45BC ", "GRAS 43AC "), and the server
    /// rejects the trimmed spelling.
    let rig: String?
    /// Opaque per-source locator. Each source only ever reads back its own.
    let token: String

    var id: String { "\(source)\u{1}\(rig ?? "")\u{1}\(title)\u{1}\(token)" }

    /// Provenance for a results row. Display trims the rig; the request does
    /// not.
    var detail: String {
        let rigText = rig?.trimmingCharacters(in: .whitespaces) ?? ""
        return rigText.isEmpty ? source : "\(source) · \(rigText)"
    }
}

struct CorrectionResult {
    var file: ParametricEQFile
    /// Where this curve came from, for the applied-correction summary.
    var provenance: String
    /// Things the user should know but that don't invalidate the result —
    /// notably anything the device will change on the way in.
    var warnings: [String] = []
    /// Predicted mean preference rating for what is left after this device's
    /// filters have done what they can. nil whenever it cannot be computed
    /// honestly: an in-ear measurement, a curve that does not span the model's
    /// band or carries more points than it will read, or a response that
    /// arrived without one.
    var preference: PreferenceScore.Reading?
}

/// Failures worth showing a user, phrased so they can be dropped straight into
/// `lastImportSummary`.
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

/// Somewhere a correction curve can come from.
///
/// Two conformers today: AutoEq's optimizer API, which is told the device's
/// limits and fits inside them, and AutoEq's published preset files, which
/// aren't and can't. The point of the protocol is that the second one is
/// replaceable — the upstream repo has been dormant for over a year — without
/// touching the view or the controller.
@MainActor
protocol CorrectionSource: AnyObject {
    /// Named in the picker and in the applied summary.
    var displayName: String { get }

    /// Start whatever catalogue load the source needs. Idempotent; safe to
    /// call on every appearance of the pane.
    func prepare()

    /// Ranked matches from the loaded catalogue. Called per keystroke, so this
    /// must not touch the network.
    func search(_ query: String) -> [CorrectionCandidate]

    func correction(for candidate: CorrectionCandidate,
                    shapedFor limits: DeviceEQLimits,
                    options: CorrectionOptions) async throws -> CorrectionResult
}

// MARK: - Transport

/// The one thing a correction source needs from the network, so tests can
/// supply it without one.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, limit: Int) async throws -> Data
}

/// Production transport: the shared, host-pinned, size-capped session.
struct PinnedTransport: HTTPTransport {
    let hosts: Set<String>

    init(hosts: Set<String> = [AutoEqService.host]) { self.hosts = hosts }

    func send(_ request: URLRequest, limit: Int) async throws -> Data {
        try await PinnedHTTP.fetch(request, limit: limit, allowing: hosts)
    }
}

// MARK: - AutoEq catalogue types

struct AutoEqMeasurement: Hashable {
    let source: String
    let form: String?
    /// Never trimmed — see `CorrectionCandidate.rig`.
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

    /// The one form every pairing this target is published against agrees on,
    /// or nil when they don't. The catalogue has no field that names a
    /// target's form directly — this is read off the measurements it
    /// endorses, and a target recommended for both over-ear and in-ear gear
    /// picks no side rather than have one guessed for it.
    var form: String? {
        let forms = Set((recommended + compatible).compactMap(\.form))
        return forms.count == 1 ? forms.first : nil
    }
}

/// One form-factor grouping of the target catalogue, for a picker meant to be
/// read by someone who doesn't already know these labels apart.
struct AutoEqTargetGroup: Identifiable {
    /// nil for whatever the catalogue doesn't pin to a single form; shown
    /// last rather than folded into a guess.
    let form: String?
    let targets: [AutoEqTarget]
    var id: String { form ?? "\u{1}other" }
}

/// The three filter shapes the API's `FilterTypeEnum` admits. They map 1:1 onto
/// the device's own filter types, which is what makes a device-shaped request
/// possible at all.
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

// MARK: - Request bodies

/// A correction request shaped like the device it is destined for.
///
/// Field names are spelled out rather than derived: `.convertToSnakeCase`
/// would mangle `base64fp16`.
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

/// Which frequency response the server should return alongside the filters.
///
/// Sending this is not optional. Omitting `response` — or asking for no fields
/// — makes the server fault on its own missing `fr_f_step` and answer 500.
///
/// The error curve is asked for so the fit can be scored against the published
/// preference model, which needs samples no more than 1/6 octave apart; 1/12
/// leaves margin without being extravagant. Measured against the live service,
/// this takes a response from roughly 3 KB to 8 KB — the cost of the feature,
/// paid on every fit rather than only when a score is shown, because the
/// alternative is a second round trip for the same curve.
struct ResponseRequirements: Encodable, Equatable {
    /// 2^(1/12): one twelfth of an octave per sample.
    var frFStep: Double = 1.059463
    /// The smoothed error is what gets scored; the raw one is asked for only
    /// as a fallback for a response that omits the smoothed field.
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
    /// Seconds of fitting. The server refuses anything above 0.5.
    var maxTime: Double
    var minStd: Double

    enum CodingKeys: String, CodingKey {
        case minF = "min_f"
        case maxF = "max_f"
        case maxTime = "max_time"
        case minStd = "min_std"
    }
}

/// Bounds every fitted filter must respect. These are the device's limits, not
/// AutoEq's defaults — that substitution is the whole feature.
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

/// One slot in the requested filter set. `fc` and `q` left nil are free for the
/// optimizer to place; given, they pin the filter.
struct FilterSpec: Encodable, Equatable {
    var type: AutoEqFilterType
    var fc: Double?
    var q: Double?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        // Must be omitted, not null: a nil fc is "you choose", and the server
        // reads an explicit null as a bad value.
        try c.encodeIfPresent(fc, forKey: .fc)
        try c.encodeIfPresent(q, forKey: .q)
    }

    enum CodingKeys: String, CodingKey { case type, fc, q }
}

// MARK: - Response bodies

struct EqualizeResponse: Decodable {
    var parametricEq: PEQResult
    /// The measured deviation from the target, before any correction. Optional
    /// because a response without it is still a perfectly good filter set —
    /// only the score is lost.
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

// MARK: - Fallback cache

/// The last correction that actually came back, per request shape.
///
/// Its whole job is to stop a dropped connection from costing someone a curve
/// they already had a minute ago, which makes it a comfort rather than a
/// store: what is worth keeping is the handful of shapes being tried in this
/// sitting. The key carries both personalization sliders and the correction
/// ceiling, so an afternoon of nudging a slider and re-fitting mints a fresh
/// entry every time — which is why there is a ceiling on it at all, and why
/// what falls out is what has gone longest untouched rather than what was
/// fetched longest ago. A shape being re-fitted repeatedly is exactly the one
/// a failure would hurt.
struct CachedCorrection {
    var file: ParametricEQFile
    var warnings: [String] = []
    var preference: PreferenceScore.Reading?
}

struct LastGoodCorrections {
    /// A session's worth of distinct fits. Small enough that the linear scan
    /// in `touch` stays cheaper than the bookkeeping a linked-list LRU would
    /// need, and large enough that nothing a person could plausibly be
    /// comparing between falls out from under them.
    static let capacity = 24

    private var byKey: [String: CachedCorrection] = [:]
    /// Keys in order of use, least recent first.
    private var recency: [String] = []

    var count: Int { byKey.count }

    /// Reading counts as using: the fallback a user keeps reaching for is the
    /// one to keep.
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

// MARK: - The service

/// Asks AutoEq's optimizer for a filter set that is already legal for this
/// device, rather than importing someone else's ten bands and clamping them.
@MainActor
final class AutoEqService: ObservableObject, CorrectionSource {
    nonisolated static let host = "autoeq.app"
    nonisolated static let base = "https://autoeq.app"

    /// The catalogue is ~660 KB and the target list ~7 KB today; an equalize
    /// response is a few KB because we ask for the coarsest frequency grid.
    /// Refuse a wildly larger body rather than buffering whatever arrives.
    nonisolated static let maxEntriesBytes = 8_000_000
    nonisolated static let maxTargetsBytes = 1_000_000
    nonisolated static let maxEqualizeBytes = 4_000_000

    /// Server-side fitting budget in seconds. The API caps this at 0.5 and
    /// answers 422 above it.
    nonisolated static let optimizerMaxTime = 0.4
    nonisolated static let optimizerMinStd = 0.008

    /// Ceiling on fitted Q, tighter than the device's own 10. A Q that high
    /// tracks a notch in one measurement of one unit, not something anyone
    /// hears on theirs.
    nonisolated static let maxFittedQ = 6.0
    nonisolated static let minFittedQ = 0.2

    /// Fixed shelf placement, matching the shape AutoEq itself publishes.
    nonisolated static let lowShelfFc = 105.0
    nonisolated static let highShelfFc = 10000.0
    nonisolated static let shelfQ = 0.7

    /// How many matches the popover shows at once.
    nonisolated static let displayLimit = 6

    enum State: Equatable { case idle, loading, ready, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var models: [AutoEqModel] = []

    /// Read by the target picker as well as resolved internally, so it needs
    /// to be visible outside the class rather than just cached for this file.
    @Published private(set) var targets: [AutoEqTarget] = []
    private var loadTask: Task<Void, Never>?

    /// A transient failure costs the user a staleness note rather than the
    /// curve.
    private var lastGood = LastGoodCorrections()

    private let transport: HTTPTransport

    init(transport: HTTPTransport = PinnedTransport()) {
        self.transport = transport
    }

    nonisolated var displayName: String { "AutoEq optimizer" }

    // MARK: Catalogue

    func prepare() {
        guard loadTask == nil || isFailed else { return }
        state = .loading
        loadTask = Task { [weak self] in
            guard let self else { return }
            async let entries = self.fetchEntries()
            async let targetList = self.fetchTargets()
            do {
                let models = try await entries
                self.models = models
                self.state = models.isEmpty ? .failed("Catalogue was empty") : .ready
                DebugLog.shared.log("AutoEq catalogue: \(models.count) models")
                self.targets = (try? await targetList) ?? []
            } catch {
                _ = try? await targetList
                let why = SafeText.scrubbed(Self.describe(error))
                self.state = .failed(why)
                self.loadTask = nil
                DebugLog.shared.log("AutoEq catalogue failed: \(why)")
            }
        }
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    func search(_ query: String) -> [CorrectionCandidate] {
        rankByTitle(models, query: query) { $0.name }.flatMap { model in
            // One row per measurement: the rig changes the curve materially, so
            // collapsing them would be picking for the user without saying so.
            model.measurements.map {
                CorrectionCandidate(title: model.name, source: $0.source, form: $0.form,
                                    rig: $0.rig, token: "")
            }
        }
    }

    #if DEBUG
    /// Used by UIPreview to render the results list without a network fetch.
    func seedForPreview(_ seeded: [AutoEqModel], targets: [AutoEqTarget] = []) {
        models = seeded
        self.targets = targets
        state = .ready
        loadTask = Task {}
    }
    #endif

    private func fetchEntries() async throws -> [AutoEqModel] {
        let data = try await get("/entries", limit: Self.maxEntriesBytes)
        return try Self.parseEntries(data)
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

    /// `{"Model Name": [{"form": …, "rig": …, "source": …}, …], …}`. `rig` can
    /// be explicitly null for sources that publish only one rig.
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
        let names = raw.keys.sorted {
            let order = $0.localizedCaseInsensitiveCompare($1)
            return order == .orderedAscending || (order == .orderedSame && $0 < $1)
        }
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
                return AutoEqMeasurement(source: ref.source, form: ref.form, rig: ref.rig)
            }
        }
        var seen = Set<String>()
        var out: [AutoEqTarget] = []
        for target in raw {
            guard out.count < maxCatalogueTargets else { break }
            guard admissible(target.label), seen.insert(target.label).inserted else { continue }
            out.append(AutoEqTarget(label: target.label,
                                    recommended: toMeasurements(target.recommended),
                                    compatible: toMeasurements(target.compatible)))
        }
        return out
    }

    // MARK: Target choice

    /// The target this measurement is published against, rather than one
    /// hardcoded guess. Recommended pairings win over merely compatible ones;
    /// only if neither knows about this rig does form decide.
    nonisolated static func target(for measurement: AutoEqMeasurement,
                       in targets: [AutoEqTarget]) -> String {
        func matches(_ ref: AutoEqMeasurement) -> Bool {
            guard ref.source == measurement.source else { return false }
            if let f = ref.form, let mf = measurement.form, f != mf { return false }
            // A target that names no rig endorses every rig from that source.
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

    /// Targets sorted into the shapes a non-expert already thinks in, rather
    /// than handed over as one flat list of labels nothing tells apart. Over-
    /// ear and in-ear targets are fitted for different acoustics and are not
    /// interchangeable, so the form they were published for is what the
    /// grouping is built on.
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

    /// Why a target the user picked goes unhonoured on the published-preset
    /// path, or nil when the default (the measurement's own recommendation)
    /// was left in place.
    ///
    /// A published file is fitted to one target at the moment it's
    /// published; there is no refit here to redirect at request time. Saying
    /// so is the only honest answer — dropping the choice silently would
    /// leave the user believing the file matches a target it never saw.
    nonisolated static func unhonouredTargetWarning(for options: CorrectionOptions) -> String? {
        guard let target = options.target else { return nil }
        return "the “\(target)” target was not applied — a published preset is fitted to "
            + "one target at publication time; use “Fit to my device” to choose one"
    }

    /// Why a bass or tilt setting goes unhonoured on the published-preset
    /// path, or nil when both were left at the target as published.
    ///
    /// Same reasoning as the target and the ceiling: both boosts are layered
    /// on during a fit, and the published path does not fit. The sliders are
    /// hidden in that mode but their values survive a switch into it, so
    /// somebody who set them, switched, and downloaded a preset would
    /// otherwise be given a curve with none of their shaping in it and nothing
    /// said about it.
    ///
    /// Worded the way the provenance line words the same two numbers, so the
    /// setting a user recognises from one is the setting they read in the
    /// other.
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

    // MARK: Request construction

    /// Exactly `bandCount` filters, shaped the way AutoEq's own presets are: a
    /// bass shelf, a treble shelf, and peaks in between. Asking for the device's
    /// band count is what removes the clamping step later.
    /// `ceiling`, when given, moves the pinned treble shelf down with it: the
    /// shelf's `fc` has to stay inside `filter_defaults`, and a shelf pinned
    /// above the bound the same request declares is a rejected request.
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

    /// A ceiling can only ever tighten this config. `maxFilterFc` already keeps
    /// filter centres below the range the fit covers, and a ceiling asking for
    /// something *higher* than an existing bound is not a reason to relax it.
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
            // Passed through byte for byte: several rig names end in a space
            // and the server matches on the exact string.
            rig: rig,
            target: target,
            parametricEqConfig: config(for: limits,
                                       ceiling: options.correctionCeiling(for: limits)),
            // Zero means "the target as published"; sending an explicit zero
            // would still be a request to flatten the target's own bass.
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

    // MARK: Response mapping

    /// Decode an `/equalize` response into the type the whole import path
    /// already speaks, and report anything the device would have to change.
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
            // Non-finite values parse happily out of JSON and `Int(inf)` traps,
            // so the range check happens here, before the conversion.
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
            // The device would clamp this without a word, and a pre-gain that
            // is 2 dB short is 2 dB of clipping headroom the user didn't get.
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

    /// What the preference model makes of the curve this device will actually
    /// produce, rather than of the ideal correction.
    ///
    /// The interesting number is the error that survives. The server's `error`
    /// is the headphone against the target before anything is done; adding the
    /// response of the filters the device will really run leaves what a
    /// listener would still be hearing, and that is what gets scored.
    ///
    /// Every band the active mode can hold counts, including any that came
    /// back outside the device's range. Those are clamped on the way in, not
    /// discarded — see `QudelixController.apply` — so dropping them here would
    /// score a curve the device never produces. Only the bands past the mode's
    /// count are left out, because those really do go nowhere. Nothing has had
    /// to be clamped so far: the request carries the device's own bounds as
    /// its `filter_defaults`, so the fit comes back already legal.
    ///
    /// The pre-gain is deliberately left out. It shifts the whole curve, and
    /// both of the model's predictors ignore a constant offset, so including
    /// it could only introduce a difference the model does not see.
    nonisolated static func residualScore(_ decoded: EqualizeResponse,
                                          file: ParametricEQFile,
                                          limits: DeviceEQLimits) -> PreferenceScore.Reading? {
        // The smoothed curve, not the raw one.
        //
        // The model's spread predictor is an unweighted standard deviation, so
        // every wrinkle of the measurement rig lands in it directly — scoring
        // the raw error made the number partly a measure of who took the
        // measurement. Worse than the offset, it reordered corrections:
        // measured against the live service, one headphone scored 95.1 raw
        // against another's 105.3, and 110.4 against 107.2 smoothed. Two
        // people comparing the same pair would have been told opposite things.
        guard let freqs = decoded.fr?.frequency,
              let error = decoded.fr?.errorSmoothed ?? decoded.fr?.error,
              freqs.count == error.count, !freqs.isEmpty else { return nil }
        // Sized by what the model can read, not by what arrived. Every point
        // below costs one biquad evaluation per band, on the thread drawing
        // the window, over a body whose only ceiling is four megabytes. Past
        // the bound the honest answer is no score: that costs the user a line
        // of text, where working through a response nobody asked for would
        // cost them the window.
        guard freqs.count <= PreferenceScore.maxInputPoints else { return nil }
        let applied = Array(file.bands.prefix(limits.bandCount))
        let correction = EQCurve.response(bands: applied, preGain: 0, at: freqs)
        guard correction.count == error.count else { return nil }
        let residual = zip(error, correction).map(+)
        return PreferenceScore.reading(frequencies: freqs, errorDb: residual)
    }

    // MARK: Equalize

    /// Ask the optimizer for a correction already legal for a `bandCount`-band
    /// device. Throws on failure — the cached fallback lives in
    /// `correction(for:shapedFor:options:)`, so callers that want a curve at
    /// any cost and callers that want the truth are both served.
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
        // The ceiling belongs in the key: a curve fitted to 16 kHz is a
        // different curve, and serving it back for an unrestricted request
        // would be handing over a fit the caller didn't ask for.
        let options = rawOptions.quantized()
        return [model, source, rig ?? "", target, String(limits.bandCount),
                String(options.bassBoostGain), String(options.tilt),
                options.correctionCeiling(for: limits).map { String($0) } ?? ""]
            .joined(separator: "\u{1}")
    }

    // MARK: CorrectionSource

    func correction(for candidate: CorrectionCandidate,
                    shapedFor limits: DeviceEQLimits,
                    options rawOptions: CorrectionOptions) async throws -> CorrectionResult {
        let options = rawOptions.quantized()
        let measurement = AutoEqMeasurement(source: candidate.source, form: candidate.form,
                                            rig: candidate.rig)
        var target = options.target
        if target == nil {
            if targets.isEmpty { targets = (try? await fetchTargets()) ?? [] }
            target = Self.target(for: measurement, in: targets)
        }
        let chosen = target ?? "Harman over-ear 2018"
        var resolved = options
        resolved.target = chosen

        // A target the user picked is worth flagging as a deliberate choice;
        // the measurement's own recommendation speaks for itself and needs no
        // extra words, or a correction that has always used the default
        // would start reading as if something had changed about it.
        let targetWasChosen = options.target != nil
        var personalized: [String] = []
        if options.bassBoostGain != 0 {
            personalized.append(String(format: "%+.1f dB bass", options.bassBoostGain))
        }
        if options.tilt != 0 {
            personalized.append(String(format: "%+.2f dB/oct tilt", options.tilt))
        }

        // Say the ceiling out loud, and say the one that was actually sent
        // rather than the one that was asked for. Months later, a curve that
        // stops at 16 kHz must not look like a defect.
        let ceiling = resolved.correctionCeiling(for: limits)
        let provenance = "\(candidate.title) · \(candidate.detail) → \(chosen)"
            + (targetWasChosen ? " (your choice)" : "")
            + " · \(limits.bandCount) bands"
            + personalized.map { " · \($0)" }.joined()
            + (ceiling.map { " · fitted up to \(CorrectionOptions.describeCeiling($0))" } ?? "")

        let key = Self.cacheKey(model: candidate.title, source: candidate.source,
                                rig: candidate.rig, target: chosen,
                                limits: limits, options: resolved)
        if let cached = lastGood.value(for: key) {
            return CorrectionResult(file: cached.file, provenance: provenance,
                                    warnings: cached.warnings,
                                    preference: cached.preference)
        }
        do {
            let (file, warnings, preference) = try await equalize(
                model: candidate.title, source: candidate.source,
                rig: candidate.rig, target: chosen,
                limits: limits, options: resolved)
            // The model is fitted on around-ear and on-ear headphones only.
            // An in-ear measurement gets no score rather than the wrong one.
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

    // MARK: Plumbing

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

    /// Turn a transport failure into something a user can act on: reachability
    /// and a server fault are different problems with different remedies.
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

    /// The API reports the field it disliked in a `detail` member — a string on
    /// a 500, a list of validation objects on a 422. Either is worth surfacing;
    /// the raw body is not.
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
