import Foundation

struct LibraryError: Error, CustomStringConvertible, Equatable {
    var description: String
}

enum LibraryCommand: CLIFamily {
    case list
    case show(String)
    case apply(String)
    case save(name: String, replacing: Bool)
    case delete(String)
    case search(String)
    case fetch(reference: String, target: String?, saveAs: String?)

    static let name = "library"

    static let usageLines = [
        row("library list", "every preset saved on this machine"),
        row("library show <n|name>", "pre-gain and the band table of a saved preset"),
        row("library apply <n|name>", "write a saved preset to the device"),
        row("library save <name>", "save the live EQ; 'save replace <name>' overwrites"),
        row("library delete <n|name>", "forget a saved preset"),
        row("library search <query>", "find a headphone in the AutoEq catalogue"),
        row("library fetch <n|name>", "fit an AutoEq correction and apply it"),
    ]

    private static func row(_ command: String, _ description: String) -> String {
        "  " + QxFormat.pad(command, 26) + description
    }

    static var fileOverride: URL?
    static var searchFileOverride: URL?
    static var transportOverride: HTTPTransport?

    static var fileURL: URL { fileOverride ?? PresetLibraryFile.url }

    static var searchFileURL: URL {
        searchFileOverride
            ?? StageStateFile.directory.appendingPathComponent("autoeq-search.json")
    }

    static let searchLimit = 20
    static let maxSearchFileBytes = 100_000
    static let catalogueBudget: TimeInterval = 30
    private static let pollInterval: TimeInterval = 0.05

    static func parse(_ rest: [String]) throws -> LibraryCommand {
        guard let sub = rest.first else {
            throw CLIUsageError(
                message: "library needs list, show, apply, save, delete, search or fetch")
        }
        let arguments = Array(rest.dropFirst())
        switch sub {
        case "list":
            guard arguments.isEmpty else {
                throw CLIUsageError(message: "library list takes no arguments")
            }
            return .list
        case "show":
            return .show(try one(arguments, "library show needs a number or a name"))
        case "apply":
            return .apply(try one(arguments, "library apply needs a number or a name"))
        case "delete", "remove":
            return .delete(try one(arguments, "library delete needs a number or a name"))
        case "save":
            return try parseSave(arguments)
        case "search":
            guard !arguments.isEmpty else {
                throw CLIUsageError(message: "library search needs something to look for")
            }
            return .search(arguments.joined(separator: " "))
        case "fetch":
            return try parseFetch(arguments)
        default:
            throw CLIUsageError(
                message: "library needs list, show, apply, save, delete, search or fetch "
                    + "— not \(sub)")
        }
    }

    private static func one(_ arguments: [String], _ complaint: String) throws -> String {
        guard arguments.count == 1, !arguments[0].isEmpty else {
            throw CLIUsageError(message: complaint)
        }
        return arguments[0]
    }

    private static func parseSave(_ arguments: [String]) throws -> LibraryCommand {
        if arguments.count == 2, isReplaceToken(arguments[0]) {
            return .save(name: arguments[1], replacing: true)
        }
        guard arguments.count == 1, !arguments[0].isEmpty,
              !isReplaceToken(arguments[0]) else {
            throw CLIUsageError(
                message: "library save needs one name, or 'replace' and a name to "
                    + "overwrite what is already saved under it")
        }
        return .save(name: arguments[0], replacing: false)
    }

    private static func isReplaceToken(_ token: String) -> Bool {
        token == "replace" || token == "--replace"
    }

    private static func parseFetch(_ arguments: [String]) throws -> LibraryCommand {
        guard let reference = arguments.first, !reference.isEmpty else {
            throw CLIUsageError(
                message: "library fetch needs a search-result number or a headphone name")
        }
        var target: String?
        var saveAs: String?
        var index = 1
        while index < arguments.count {
            let keyword = arguments[index]
            guard index + 1 < arguments.count else {
                throw CLIUsageError(message: "library fetch: \(keyword) needs a name after it")
            }
            let value = arguments[index + 1]
            index += 2
            switch keyword {
            case "target", "--target":
                guard target == nil else {
                    throw CLIUsageError(message: "library fetch takes one target")
                }
                target = value
            case "save", "--save":
                guard saveAs == nil else {
                    throw CLIUsageError(message: "library fetch saves under one name")
                }
                saveAs = value
            default:
                throw CLIUsageError(
                    message: "library fetch takes 'target <name>' and 'save <name>' "
                        + "— not \(keyword)")
            }
        }
        return .fetch(reference: reference, target: target, saveAs: saveAs)
    }

    var needsDevice: Bool {
        switch self {
        case .apply, .save, .fetch: return true
        case .list, .show, .delete, .search: return false
        }
    }

    var persistsToFlash: Bool {
        switch self {
        case .apply, .fetch: return true
        case .list, .show, .save, .delete, .search: return false
        }
    }

    func run(options: CLIOptions, session: QxSession?) async throws {
        switch self {
        case .list:
            try Self.runList(json: options.json)
        case .show(let reference):
            try Self.runShow(reference, json: options.json)
        case .delete(let reference):
            try Self.runDelete(reference, json: options.json)
        case .apply(let reference):
            try await Self.runApply(reference, session: try Self.device(session),
                                    json: options.json)
        case .save(let name, let replacing):
            try await Self.runSave(name: name, replacing: replacing,
                                   session: try Self.device(session), json: options.json)
        case .search(let query):
            try await Self.runSearch(query, budget: Self.budget(options), json: options.json)
        case .fetch(let reference, let target, let saveAs):
            try await Self.runFetch(reference: reference, target: target, saveAs: saveAs,
                                    session: try Self.device(session),
                                    budget: Self.budget(options), json: options.json)
        }
    }

    private static func device(_ session: QxSession?) throws -> QxSession {
        guard let session else {
            throw CLIUsageError(message: "this command needs the device")
        }
        return session
    }

    private static func budget(_ options: CLIOptions) -> TimeInterval {
        max(catalogueBudget, options.timeout)
    }

    static func document() throws -> PresetLibraryDocument {
        switch PresetLibraryFile.outcome(from: fileURL) {
        case .loaded(let document):
            return document
        case .unreadable:
            throw LibraryError(description: "could not read \(fileURL.path) — check its "
                + "permissions and its size; nothing has been changed")
        case .undecodable:
            throw LibraryError(description: "\(fileURL.path) is not a preset library this "
                + "tool wrote; a copy is kept beside it as "
                + "\(fileURL.lastPathComponent).recovered and nothing has been changed")
        }
    }

    static func persist(_ document: PresetLibraryDocument) throws {
        PresetLibraryFile.save(document, to: fileURL)
        let expected = PresetLibraryFile.sanitize(document).presets.map(\.id)
        guard let written = PresetLibraryFile.load(from: fileURL),
              written.presets.map(\.id) == expected else {
            throw LibraryError(description: "could not write \(fileURL.path)")
        }
    }

    static func resolve(_ token: String, in presets: [LibraryPreset]) throws -> Int {
        guard !presets.isEmpty else {
            throw CLIUsageError(message: "there are no saved presets yet — "
                + "'qudelix library save <name>' keeps the live EQ")
        }
        if let number = Int(token) {
            guard (1...presets.count).contains(number) else {
                throw CLIUsageError(message: "there is no saved preset \(number) — "
                    + "the library holds \(presets.count)")
            }
            return number - 1
        }
        let needle = token.lowercased()
        let exact = presets.indices.filter { presets[$0].name.lowercased() == needle }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { throw ambiguous(token, exact, presets) }
        let prefixed = presets.indices.filter { presets[$0].name.lowercased().hasPrefix(needle) }
        if prefixed.count == 1 { return prefixed[0] }
        guard !prefixed.isEmpty else {
            throw CLIUsageError(message: "no saved preset matches \"\(token)\" — "
                + "run 'qudelix library list'")
        }
        throw ambiguous(token, prefixed, presets)
    }

    private static func ambiguous(_ token: String, _ hits: [Int],
                                  _ presets: [LibraryPreset]) -> CLIUsageError {
        CLIUsageError(message: "\"\(token)\" matches \(hits.count) saved presets — "
            + hits.map { "\($0 + 1) \(presets[$0].name)" }.joined(separator: ", "))
    }

    private static func runList(json: Bool) throws {
        let presets = try document().presets
        if json {
            StdIO.out(jsonArray(presets.enumerated().map { listObject($0.offset, $0.element) }))
            return
        }
        guard !presets.isEmpty else {
            StdIO.out("no saved presets")
            return
        }
        for line in listLines(presets) { StdIO.out(line) }
    }

    static func listLines(_ presets: [LibraryPreset]) -> [String] {
        let indexWidth = "\(presets.count)".count + 2
        let nameWidth = (presets.map(\.name.count).max() ?? 4) + 2
        let scopeWidth = (presets.map(\.scopeLabel.count).max() ?? 5) + 2
        var lines = [trimmedTail(QxFormat.pad("#", indexWidth)
            + QxFormat.pad("name", nameWidth)
            + QxFormat.pad("bands", 10)
            + QxFormat.pad("scope", scopeWidth) + "source")]
        for (index, preset) in presets.enumerated() {
            lines.append(trimmedTail(QxFormat.pad("\(index + 1)", indexWidth)
                + QxFormat.pad(preset.name, nameWidth)
                + QxFormat.pad(preset.groupLabel, 10)
                + QxFormat.pad(preset.scopeLabel, scopeWidth)
                + (preset.sourceName ?? "")))
        }
        return lines
    }

    static func listObject(_ index: Int, _ preset: LibraryPreset) -> [String: Any] {
        var object: [String: Any] = [
            "index": index + 1,
            "name": preset.name,
            "bands": preset.group.bandCount,
            "band_label": preset.groupLabel,
            "eq_group": Int(preset.group.rawValue),
            "scope": preset.scopeLabel,
            "global": preset.scope == .global,
        ]
        QxFormat.put(&object, "source", preset.sourceName)
        QxFormat.put(&object, "output_uid", preset.scope.outputUID)
        return object
    }

    private static func runShow(_ reference: String, json: Bool) throws {
        let presets = try document().presets
        let preset = presets[try resolve(reference, in: presets)]
        if json {
            var object = QxFormat.eqObject(preGain: preset.preGain, bands: preset.bands,
                                           enabled: nil, group: preset.group)
            object["name"] = preset.name
            object["scope"] = preset.scopeLabel
            QxFormat.put(&object, "source", preset.sourceName)
            StdIO.out(QxFormat.json(object))
            return
        }
        StdIO.out("name      " + preset.name)
        StdIO.out("bands     " + preset.groupLabel)
        StdIO.out("scope     " + preset.scopeLabel)
        if let source = preset.sourceName { StdIO.out("source    " + source) }
        for line in QxFormat.eqLines(preGain: preset.preGain, bands: preset.bands) {
            StdIO.out(line)
        }
    }

    private static func runDelete(_ reference: String, json: Bool) throws {
        var document = try document()
        let index = try resolve(reference, in: document.presets)
        let removed = document.presets.remove(at: index)
        try persist(document)
        if json {
            StdIO.out(QxFormat.json(["deleted": removed.name,
                                     "remaining": document.presets.count]))
        } else {
            StdIO.out("deleted \u{201C}\(removed.name)\u{201D} — "
                + "\(document.presets.count) left in the library")
        }
    }

    private static func runApply(_ reference: String, session: QxSession,
                                 json: Bool) async throws {
        let presets = try document().presets
        let preset = presets[try resolve(reference, in: presets)]
        let group = await session.snapshot().eqGroup
        guard preset.group == group else {
            throw CLIUsageError(message: "\u{201C}\(preset.name)\u{201D} was saved for the "
                + QxFormat.groupLabel(preset.group) + " EQ and the device is in "
                + QxFormat.groupLabel(group) + " mode — those are separate banks with "
                + "different band counts, so nothing has been written")
        }
        var file = ParametricEQFile()
        file.preamp = preset.preGain
        file.bands = preset.bands
        let applied = try await session.applyParametric(file, expecting: group)
        if json {
            var object = QxFormat.eqObject(preGain: applied.preGain, bands: applied.bands,
                                           enabled: true, group: group)
            object["name"] = preset.name
            StdIO.out(QxFormat.json(object))
        } else {
            StdIO.out("applied \u{201C}\(preset.name)\u{201D}")
            for line in QxFormat.eqLines(preGain: applied.preGain, bands: applied.bands) {
                StdIO.out(line)
            }
        }
    }

    private static func runSave(name: String, replacing: Bool, session: QxSession,
                                json: Bool) async throws {
        let group = await session.snapshot().eqGroup
        let live = try await session.readPreset()
        let bands = Array(live.bands.prefix(group.bandCount)).map(PresetLibraryFile.clamped)
        guard !bands.isEmpty else {
            throw LibraryError(description: "the device has not reported a curve yet")
        }
        var document = try document()
        let stored = try store(LibraryPreset(name: name, scope: .global, group: group,
                                             bands: bands,
                                             preGain: EQHeadroom.clamp(live.preGain)),
                               replacing: replacing, in: &document)
        try persist(document)
        if json {
            StdIO.out(QxFormat.json(["saved": stored.name,
                                     "index": stored.index + 1,
                                     "bands": bands.count,
                                     "path": fileURL.path]))
        } else {
            StdIO.out("saved \u{201C}\(stored.name)\u{201D} as library preset "
                + "\(stored.index + 1) in \(fileURL.path)")
        }
    }

    static func store(_ preset: LibraryPreset, replacing: Bool,
                      in document: inout PresetLibraryDocument)
        throws -> (name: String, index: Int) {
        let clean = QudelixController.displayName(preset.name,
                                                  limit: PresetLibraryFile.maxNameLength)
        guard !clean.isEmpty else {
            throw CLIUsageError(message: "a saved preset needs a name with something in it")
        }
        var entry = preset
        entry.name = clean
        if let existing = document.presets.firstIndex(where: {
            $0.name.lowercased() == clean.lowercased()
        }) {
            guard replacing else {
                throw CLIUsageError(message: "\u{201C}\(document.presets[existing].name)"
                    + "\u{201D} is already in the library — "
                    + "'qudelix library save replace \(clean)' overwrites it")
            }
            entry.id = document.presets[existing].id
            document.presets[existing] = entry
            return (clean, existing)
        }
        guard document.presets.count < PresetLibraryFile.maxPresets else {
            throw CLIUsageError(message: "the library is full at "
                + "\(PresetLibraryFile.maxPresets) presets — delete one to make room")
        }
        document.presets.append(entry)
        return (clean, document.presets.count - 1)
    }

    private static func runSearch(_ query: String, budget: TimeInterval,
                                  json: Bool) async throws {
        let found = try await catalogueMatches(query, budget: budget)
        guard !found.isEmpty else {
            if json { StdIO.out(jsonArray([])) } else { StdIO.out("no headphone matches") }
            return
        }
        remember(query: query, found)
        if json {
            StdIO.out(jsonArray(found.enumerated().map { searchObject($0.offset, $0.element) }))
            StdIO.error("qudelix: results remembered in \(searchFileURL.path)")
            return
        }
        for line in searchLines(found) { StdIO.out(line) }
        StdIO.out("")
        StdIO.out("the AutoEq catalogue is fetched on every run and kept in memory only")
        StdIO.out("these results are remembered in \(searchFileURL.path) — "
            + "'qudelix library fetch <n>' uses them")
    }

    static func searchLines(_ found: [RememberedCandidate]) -> [String] {
        let indexWidth = "\(found.count)".count + 2
        let titleWidth = (found.map(\.title.count).max() ?? 5) + 2
        return found.enumerated().map { entry in
            trimmedTail(QxFormat.pad("\(entry.offset + 1)", indexWidth)
                + QxFormat.pad(entry.element.title, titleWidth)
                + QxFormat.pad(entry.element.detail, 34)
                + (entry.element.form ?? ""))
        }
    }

    static func searchObject(_ index: Int, _ candidate: RememberedCandidate) -> [String: Any] {
        var object: [String: Any] = [
            "index": index + 1,
            "title": candidate.title,
            "source": candidate.source,
        ]
        QxFormat.put(&object, "rig", candidate.rig)
        QxFormat.put(&object, "form", candidate.form)
        return object
    }

    private static func runFetch(reference: String, target: String?, saveAs: String?,
                                 session: QxSession, budget: TimeInterval,
                                 json: Bool) async throws {
        let group = await session.snapshot().eqGroup
        let candidate = try await candidate(for: reference, budget: budget)
        let fitted = try await fit(candidate, target: target, bandCount: group.bandCount,
                                   budget: budget)
        let applied = try await session.applyParametric(fitted.file, expecting: group)
        var saved: (name: String, index: Int)?
        if let saveAs {
            var document = try document()
            saved = try store(LibraryPreset(name: saveAs, scope: .global, group: group,
                                            bands: applied.bands.map(PresetLibraryFile.clamped),
                                            preGain: EQHeadroom.clamp(applied.preGain),
                                            sourceName: candidate.title),
                              replacing: false, in: &document)
            try persist(document)
        }
        if json {
            var object = QxFormat.eqObject(preGain: applied.preGain, bands: applied.bands,
                                           enabled: true, group: group)
            object["provenance"] = fitted.provenance
            object["warnings"] = fitted.warnings
            if let saved {
                object["saved"] = saved.name
                object["saved_index"] = saved.index + 1
            }
            StdIO.out(QxFormat.json(object))
            return
        }
        StdIO.out("applied " + fitted.provenance)
        for warning in fitted.warnings { StdIO.out("note: " + warning) }
        for line in QxFormat.eqLines(preGain: applied.preGain, bands: applied.bands) {
            StdIO.out(line)
        }
        if let saved {
            StdIO.out("saved \u{201C}\(saved.name)\u{201D} as library preset "
                + "\(saved.index + 1) in \(fileURL.path)")
        }
    }

    static func candidate(for reference: String,
                          budget: TimeInterval) async throws -> RememberedCandidate {
        if let number = Int(reference) {
            let remembered = rememberedSearch()
            guard !remembered.isEmpty else {
                throw CLIUsageError(message: "no search results are remembered — "
                    + "run 'qudelix library search <query>' first")
            }
            guard (1...remembered.count).contains(number) else {
                throw CLIUsageError(message: "there is no search result \(number) — "
                    + "the last search found \(remembered.count)")
            }
            return remembered[number - 1]
        }
        let found = try await catalogueMatches(reference, budget: budget)
        let needle = reference.lowercased()
        let exact = found.filter { $0.title.lowercased() == needle }
        let hits = exact.isEmpty
            ? found.filter { $0.title.lowercased().hasPrefix(needle) }
            : exact
        if let only = hits.first, hits.count == 1 { return only }
        guard !hits.isEmpty else {
            throw CLIUsageError(message: "no headphone matches \"\(reference)\" — "
                + "run 'qudelix library search \(reference)'")
        }
        throw CLIUsageError(message: "\"\(reference)\" matches \(hits.count) measurements — "
            + hits.prefix(searchLimit).map { "\($0.title) (\($0.detail))" }
                .joined(separator: ", ")
            + " — run 'qudelix library search \(reference)' and fetch by number")
    }

    struct RememberedCandidate: Codable, Equatable {
        var title: String
        var source: String
        var form: String?
        var rig: String?
        var token: String

        var detail: String {
            let trimmed = rig?.trimmingCharacters(in: .whitespaces) ?? ""
            return trimmed.isEmpty ? source : "\(source) · \(trimmed)"
        }

        var admissible: Bool {
            AutoEqService.admissible(title) && AutoEqService.admissible(source)
                && [form, rig].allSatisfy {
                    $0 == nil || $0!.count <= AutoEqService.maxCatalogueStringLength
                }
                && token.count <= AutoEqService.maxCatalogueStringLength
        }
    }

    struct FittedCorrection {
        var file: ParametricEQFile
        var provenance: String
        var warnings: [String]
    }

    @MainActor
    static func catalogueMatches(_ query: String,
                                 budget: TimeInterval) async throws -> [RememberedCandidate] {
        let service = try await readyService(budget: budget)
        return service.search(query).prefix(searchLimit).map {
            RememberedCandidate(title: $0.title, source: $0.source, form: $0.form,
                                rig: $0.rig, token: $0.token)
        }
    }

    @MainActor
    static func fit(_ candidate: RememberedCandidate, target: String?, bandCount: Int,
                    budget: TimeInterval) async throws -> FittedCorrection {
        let service = try await readyService(budget: budget)
        var options = CorrectionOptions()
        options.target = target
        let result = try await service.correction(
            for: CorrectionCandidate(title: candidate.title, source: candidate.source,
                                     form: candidate.form, rig: candidate.rig,
                                     token: candidate.token),
            shapedFor: DeviceEQLimits.qudelix(bandCount: bandCount),
            options: options)
        return FittedCorrection(file: result.file, provenance: result.provenance,
                                warnings: result.warnings)
    }

    @MainActor
    private static func readyService(budget: TimeInterval) async throws -> AutoEqService {
        let service = AutoEqService(transport: transportOverride ?? PinnedTransport())
        service.prepare()
        let attempts = max(1, Int((budget / pollInterval).rounded()))
        for _ in 0..<attempts {
            switch service.state {
            case .ready:
                return service
            case .failed(let why):
                throw LibraryError(description: "the AutoEq catalogue could not be "
                    + "loaded — " + why)
            case .idle, .loading:
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
        throw LibraryError(description: "the AutoEq catalogue did not arrive within "
            + "\(Int(budget)) seconds")
    }

    static func remember(query: String, _ found: [RememberedCandidate]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let record = RememberedSearch(query: String(query.prefix(
            AutoEqService.maxCatalogueStringLength)),
                                      candidates: Array(found.prefix(searchLimit)))
        guard let data = try? encoder.encode(record) else { return }
        SafeFile.writeAtomic(data, to: searchFileURL)
    }

    static func rememberedSearch() -> [RememberedCandidate] {
        guard let data = SafeFile.read(searchFileURL, cap: maxSearchFileBytes),
              let record = try? JSONDecoder().decode(RememberedSearch.self, from: data) else {
            return []
        }
        return record.candidates.prefix(searchLimit).filter(\.admissible)
    }

    struct RememberedSearch: Codable {
        var query: String
        var candidates: [RememberedCandidate]
    }

    static func jsonArray(_ rows: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: rows,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    private static func trimmedTail(_ line: String) -> String {
        var out = line
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }
}
