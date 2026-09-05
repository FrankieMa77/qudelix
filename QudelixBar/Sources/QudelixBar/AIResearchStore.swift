import Foundation

struct HeadphoneDossier: Codable, Equatable {
    struct Issue: Codable, Equatable {
        let region: String
        let issue: String

        private enum CodingKeys: String, CodingKey {
            case region = "where"
            case issue
        }

        init(region: String, issue: String) {
            self.region = region
            self.issue = issue
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            region = (try? c.decode(String.self, forKey: .region)) ?? ""
            issue = (try? c.decode(String.self, forKey: .issue)) ?? ""
        }
    }

    struct Measurement: Codable, Equatable {
        var title: String
        var preGain: Double
        var bands: [QxEqBandValue]

        init(title: String, preGain: Double, bands: [QxEqBandValue]) {
            self.title = title
            self.preGain = preGain
            self.bands = bands
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = (try? c.decode(String.self, forKey: .title)) ?? ""
            preGain = (try? c.decode(Double.self, forKey: .preGain)) ?? 0
            bands = (try? c.decode([QxEqBandValue].self, forKey: .bands)) ?? []
        }

        func sanitized() -> Measurement {
            Measurement(
                title: HeadphoneDossier.capped(title, HeadphoneDossier.maxMeasurementTitle),
                preGain: preGain.isFinite ? min(max(preGain, -24), 24) : 0,
                bands: bands.prefix(HeadphoneDossier.maxFilters).map(PresetLibraryFile.clamped))
        }

        var isEmpty: Bool { bands.isEmpty }

        var lines: [String] {
            var out = [String(format: "preamp %.1f dB", preGain)]
            for band in bands where band.filter != .bypass {
                let kind: String
                switch band.filter {
                case .lowShelf: kind = "low shelf"
                case .highShelf: kind = "high shelf"
                case .lpf: kind = "low pass"
                case .hpf: kind = "high pass"
                default: kind = "peak"
                }
                out.append(band.filter.hasGain
                    ? String(format: "%@ %d Hz gain %+.1f dB Q %.2f",
                             kind, band.freq, band.gain, band.q)
                    : String(format: "%@ %d Hz Q %.2f", kind, band.freq, band.q))
            }
            return Array(out.prefix(HeadphoneDossier.maxFilters + 1))
                .map { String($0.prefix(HeadphoneDossier.maxFilterLine)) }
        }
    }

    var signature: String
    var bass: String
    var mids: String
    var treble: String
    var soundstage: String
    var knownIssues: [Issue]
    var confidence: String
    var measurement: Measurement?
    var researchedAt: Date
    var provider: String
    var model: String
    var lastUsedAt: Date

    static let maxDescription = 220
    static let maxWhere = 60
    static let maxIssueText = 120
    static let maxIssues = 8
    static let maxFilterLine = 80
    static let maxFilters = 32
    static let maxMeasurementTitle = 80
    static let maxProvider = 32
    static let maxModel = 64

    init(signature: String, bass: String, mids: String, treble: String,
         soundstage: String, knownIssues: [Issue], confidence: String,
         measurement: Measurement?, researchedAt: Date, provider: String,
         model: String, lastUsedAt: Date) {
        self.signature = signature
        self.bass = bass
        self.mids = mids
        self.treble = treble
        self.soundstage = soundstage
        self.knownIssues = knownIssues
        self.confidence = confidence
        self.measurement = measurement
        self.researchedAt = researchedAt
        self.provider = provider
        self.model = model
        self.lastUsedAt = lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String {
            (try? c.decode(String.self, forKey: key)) ?? ""
        }
        signature = text(.signature)
        bass = text(.bass)
        mids = text(.mids)
        treble = text(.treble)
        soundstage = text(.soundstage)
        knownIssues = (try? c.decode([Issue].self, forKey: .knownIssues)) ?? []
        confidence = text(.confidence)
        measurement = try? c.decode(Measurement.self, forKey: .measurement)
        researchedAt = (try? c.decode(Date.self, forKey: .researchedAt)) ?? Date()
        provider = text(.provider)
        model = text(.model)
        lastUsedAt = (try? c.decode(Date.self, forKey: .lastUsedAt)) ?? researchedAt
    }

    var isEmpty: Bool {
        signature.isEmpty && bass.isEmpty && mids.isEmpty && treble.isEmpty
            && soundstage.isEmpty && knownIssues.isEmpty
    }

    func sanitized() -> HeadphoneDossier {
        let issues = knownIssues.prefix(Self.maxIssues).map {
            Issue(region: Self.capped($0.region, Self.maxWhere),
                  issue: Self.capped($0.issue, Self.maxIssueText))
        }
        let fit = measurement?.sanitized()
        return HeadphoneDossier(
            signature: Self.capped(signature, Self.maxDescription),
            bass: Self.capped(bass, Self.maxDescription),
            mids: Self.capped(mids, Self.maxDescription),
            treble: Self.capped(treble, Self.maxDescription),
            soundstage: Self.capped(soundstage, Self.maxDescription),
            knownIssues: issues.filter { !$0.region.isEmpty || !$0.issue.isEmpty },
            confidence: Self.confidenceValue(confidence),
            measurement: (fit?.isEmpty ?? true) ? nil : fit,
            researchedAt: Self.plausible(researchedAt),
            provider: Self.capped(provider, Self.maxProvider),
            model: Self.capped(model, Self.maxModel),
            lastUsedAt: Self.plausible(lastUsedAt))
    }

    static func capped(_ raw: String, _ limit: Int) -> String {
        String(SafeText.scrubbed(raw, limit: limit).prefix(limit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func confidenceValue(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "high": return "high"
        case "medium": return "medium"
        default: return "low"
        }
    }

    static func plausible(_ date: Date) -> Date {
        let now = Date()
        if date > now { return now }
        let floor = Date(timeIntervalSince1970: 0)
        return date < floor ? floor : date
    }
}

@MainActor
final class AIResearchStore {
    nonisolated static let fileName = "ai-research.json"
    nonisolated static let maxBytes = 1 << 20
    nonisolated static let maxEntries = 64

    private let directoryOverride: URL?
    private var entries: [String: HeadphoneDossier]?
    private var saveWork: DispatchWorkItem?

    init(directory: URL? = nil) { self.directoryOverride = directory }

    private var directory: URL { directoryOverride ?? StageStateFile.directory }
    private var url: URL { directory.appendingPathComponent(Self.fileName) }

    nonisolated static func key(for name: String) -> String {
        let collapsed = name.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        return String(SafeText.scrubbed(collapsed, limit: 128).prefix(64))
    }

    func dossier(for key: String, touch: Bool = true) -> HeadphoneDossier? {
        guard !key.isEmpty else { return nil }
        loadIfNeeded()
        guard var found = entries?[key] else { return nil }
        guard touch else { return found }
        found.lastUsedAt = Date()
        entries?[key] = found
        scheduleSave()
        return found
    }

    func store(_ dossier: HeadphoneDossier, for key: String) {
        guard !key.isEmpty else { return }
        loadIfNeeded()
        var map = entries ?? [:]
        map[key] = dossier.sanitized()
        entries = Self.evicted(map)
        saveNow()
    }

    func forget(_ key: String) {
        guard !key.isEmpty else { return }
        loadIfNeeded()
        guard entries?.removeValue(forKey: key) != nil else { return }
        saveNow()
    }

    private func loadIfNeeded() {
        guard entries == nil else { return }
        entries = Self.decode(SafeFile.read(url, cap: Self.maxBytes))
    }

    nonisolated static func decode(_ data: Data?) -> [String: HeadphoneDossier] {
        guard let data,
              let raw = try? JSONDecoder().decode([String: HeadphoneDossier].self, from: data)
        else { return [:] }
        var out: [String: HeadphoneDossier] = [:]
        for (rawKey, dossier) in raw {
            let key = key(for: rawKey)
            guard !key.isEmpty else { continue }
            let clean = dossier.sanitized()
            if let existing = out[key], existing.lastUsedAt >= clean.lastUsedAt { continue }
            out[key] = clean
        }
        return evicted(out)
    }

    nonisolated static func evicted(_ map: [String: HeadphoneDossier])
        -> [String: HeadphoneDossier] {
        guard map.count > maxEntries else { return map }
        let ordered = map.sorted {
            $0.value.lastUsedAt == $1.value.lastUsedAt
                ? $0.key < $1.key
                : $0.value.lastUsedAt < $1.value.lastUsedAt
        }
        var out = map
        for (key, _) in ordered.prefix(map.count - maxEntries) {
            out.removeValue(forKey: key)
        }
        return out
    }

    nonisolated static func encode(_ map: [String: HeadphoneDossier]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(map)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard let entries, let data = Self.encode(entries) else { return }
        SafeFile.writeAtomic(data, to: url)
    }

    #if DEBUG
    func previewSeed(_ map: [String: HeadphoneDossier]) { entries = map }
    #endif
}
