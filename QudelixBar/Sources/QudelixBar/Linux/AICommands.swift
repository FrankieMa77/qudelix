import Foundation

struct AIFailure: Error, CustomStringConvertible, Equatable {
    let text: String

    var description: String { text }
}

struct AIResearchFile {
    let directory: URL

    var url: URL { directory.appendingPathComponent(AIResearchStore.fileName) }

    func entries() -> [String: HeadphoneDossier] {
        AIResearchStore.decode(SafeFile.read(url, cap: AIResearchStore.maxBytes))
    }

    func dossier(for key: String) -> HeadphoneDossier? {
        guard !key.isEmpty else { return nil }
        return entries()[key]
    }

    @discardableResult
    func store(_ dossier: HeadphoneDossier, for key: String) -> Bool {
        guard !key.isEmpty else { return false }
        var map = entries()
        map[key] = dossier.sanitized()
        guard let data = AIResearchStore.encode(
            AIResearchStore.evicted(map, limit: AIResearchStore.maxEntries)) else {
            return false
        }
        return SafeFile.writeAtomic(data, to: url)
    }
}

struct AIRuntime {
    var keychain = AIKeychain.shared
    var transport: AITransport = PinnedAITransport()
    var researchDirectory: URL?
    var measurement: (String) async -> HeadphoneDossier.Measurement?
        = AIRuntime.publishedMeasurement
    var readKey: () -> String? = AIRuntime.keyFromStandardInput

    static var current = AIRuntime()

    var research: AIResearchFile {
        AIResearchFile(directory: researchDirectory ?? StageStateFile.directory)
    }

    static func publishedMeasurement(for headphoneName: String) async
        -> HeadphoneDossier.Measurement? {
        let name = headphoneName.trimmingCharacters(in: .whitespaces)
        guard name.count >= 4 else { return nil }
        guard let index = try? await AutoEqIndex.fetch(AutoEqIndex.indexURL,
                                                       limit: AutoEqIndex.maxIndexBytes),
              let markdown = String(data: index, encoding: .utf8) else { return nil }
        let entries = AutoEqIndex.parseIndex(markdown)
        guard let entry = rankByTitle(entries, query: name, cap: 1,
                                      title: { $0.title }).first,
              let file = try? await AutoEqIndex.fetchPreset(entry),
              !file.bands.isEmpty else { return nil }
        return HeadphoneDossier.Measurement(title: entry.title, preGain: file.preamp,
                                            bands: file.bands).sanitized()
    }

    static func keyFromStandardInput() -> String? {
        var buffer = Data()
        while buffer.count <= AIKeychain.maxKeyBytes {
            let chunk = (try? FileHandle.standardInput.read(upToCount: 512)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            buffer.append(chunk)
            if chunk.contains(0x0A) { break }
        }
        let line = buffer.prefix { $0 != 0x0A }
        guard let text = String(data: Data(line), encoding: .utf8) else { return nil }
        return text
    }
}

struct AISuggestRequest: Equatable {
    var headphone: String
    var kind: AIPresetKind = .correction
    var provider: AIProvider?
    var model: String?
    var bands: Int?
    var apply = false
}

struct AIResearchRequest: Equatable {
    var headphone: String
    var provider: AIProvider?
    var model: String?
    var refresh = false
}

enum AICommand: CLIFamily {
    case providers
    case keyStatus
    case keySet(AIProvider)
    case keyClear(AIProvider)
    case research(AIResearchRequest)
    case suggest(AISuggestRequest)

    static let name = "ai"

    static let defaultBandCount = 10

    static let bandCounts = [QxEqGroup.user.bandCount, QxEqGroup.b20.bandCount]

    static let minimumHeadphoneNameLength = 2

    static let maxHeadphoneNameLength = 64

    static let usageLines = [
        row("ai providers", "every provider, its default model and its key"),
        row("ai key set <provider>", "store an API key read from standard input"),
        row("ai key clear <provider>", "forget the stored key for a provider"),
        row("ai key status", "which providers have a key stored"),
        row("ai research <headphone>", "what a provider knows about a headphone"),
        row("ai suggest <headphone>", "design a preset for a headphone"),
        "    [--kind <kind>] [--provider <p>] [--model <m>] [--bands 10|20] [--apply]",
    ]

    private static func row(_ command: String, _ text: String) -> String {
        "  " + QxFormat.pad(command, 26) + text
    }

    static func parse(_ rest: [String]) throws -> AICommand {
        guard let head = rest.first else {
            throw CLIUsageError(message: "ai needs providers, key, research or suggest")
        }
        let arguments = Array(rest.dropFirst())
        switch head {
        case "providers":
            try expectNothing(arguments, "ai providers")
            return .providers
        case "key":
            return try key(arguments)
        case "research":
            return .research(try researchRequest(arguments))
        case "suggest":
            return .suggest(try suggestRequest(arguments))
        default:
            throw CLIUsageError(
                message: "ai needs providers, key, research or suggest — not "
                    + SafeText.scrubbed(head, limit: 40))
        }
    }

    private static func expectNothing(_ arguments: [String], _ what: String) throws {
        guard arguments.isEmpty else {
            throw CLIUsageError(message: "\(what) takes no arguments")
        }
    }

    private static func key(_ arguments: [String]) throws -> AICommand {
        guard let sub = arguments.first else {
            throw CLIUsageError(message: "ai key needs set, clear or status")
        }
        let rest = Array(arguments.dropFirst())
        switch sub {
        case "status":
            try expectNothing(rest, "ai key status")
            return .keyStatus
        case "set":
            guard rest.count == 1 else {
                throw CLIUsageError(message: "ai key set needs one provider name")
            }
            return .keySet(try provider(rest[0]))
        case "clear", "forget":
            guard rest.count == 1 else {
                throw CLIUsageError(message: "ai key \(sub) needs one provider name")
            }
            return .keyClear(try provider(rest[0]))
        default:
            throw CLIUsageError(message: "ai key needs set, clear or status — not "
                + SafeText.scrubbed(sub, limit: 40))
        }
    }

    static func provider(_ token: String) throws -> AIProvider {
        let want = folded(token)
        guard let match = AIProvider.allCases.first(where: { folded($0.rawValue) == want })
                ?? AIProvider.allCases.first(where: { folded($0.label) == want }) else {
            throw CLIUsageError(
                message: "no AI provider called \"" + SafeText.scrubbed(token, limit: 40)
                    + "\" — try one of: " + providerNames)
        }
        return match
    }

    static func kind(_ token: String) throws -> AIPresetKind {
        let want = folded(token)
        guard let match = AIPresetKind.allCases.first(where: { folded($0.rawValue) == want })
                ?? AIPresetKind.allCases.first(where: { folded($0.label) == want }) else {
            throw CLIUsageError(
                message: "no preset kind called \"" + SafeText.scrubbed(token, limit: 40)
                    + "\" — try one of: " + kindNames)
        }
        return match
    }

    static var providerNames: String {
        AIProvider.allCases.map(\.rawValue).joined(separator: ", ")
    }

    static var kindNames: String {
        AIPresetKind.allCases.map(\.rawValue).joined(separator: ", ")
    }

    private static func folded(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func bandCount(_ token: String) throws -> Int {
        guard let count = Int(token), bandCounts.contains(count) else {
            throw CLIUsageError(
                message: "--bands takes " + bandCounts.map(String.init).joined(separator: " or ")
                    + ", matching the bank the device is in")
        }
        return count
    }

    private static func value(_ arguments: [String], _ index: inout Int,
                              _ flag: String) throws -> String {
        guard index < arguments.count else {
            throw CLIUsageError(message: "\(flag) needs a value")
        }
        let text = arguments[index]
        index += 1
        return text
    }

    private static func headphoneName(_ words: [String], _ what: String) throws -> String {
        let joined = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let name = QudelixController.displayName(joined, limit: maxHeadphoneNameLength)
        guard name.count >= minimumHeadphoneNameLength else {
            throw CLIUsageError(
                message: "\(what) needs the name of a headphone, such as "
                    + "'qudelix \(what) \"Sennheiser HD 650\"'")
        }
        return name
    }

    private static func suggestRequest(_ arguments: [String]) throws -> AISuggestRequest {
        var request = AISuggestRequest(headphone: "")
        var words: [String] = []
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            index += 1
            switch token {
            case "--apply":
                request.apply = true
            case "--kind":
                request.kind = try kind(try value(arguments, &index, token))
            case "--provider":
                request.provider = try provider(try value(arguments, &index, token))
            case "--model":
                request.model = try modelName(try value(arguments, &index, token))
            case "--bands":
                request.bands = try bandCount(try value(arguments, &index, token))
            default:
                if let pair = split(token) {
                    switch pair.flag {
                    case "--kind": request.kind = try kind(pair.value)
                    case "--provider": request.provider = try provider(pair.value)
                    case "--model": request.model = try modelName(pair.value)
                    case "--bands": request.bands = try bandCount(pair.value)
                    default: throw unknownFlag(pair.flag, of: "ai suggest",
                                               taking: suggestFlags)
                    }
                } else if token.hasPrefix("-"), token.count > 1 {
                    throw unknownFlag(token, of: "ai suggest", taking: suggestFlags)
                } else {
                    words.append(token)
                }
            }
        }
        request.headphone = try headphoneName(words, "ai suggest")
        return request
    }

    private static func researchRequest(_ arguments: [String]) throws -> AIResearchRequest {
        var request = AIResearchRequest(headphone: "")
        var words: [String] = []
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            index += 1
            switch token {
            case "--refresh":
                request.refresh = true
            case "--provider":
                request.provider = try provider(try value(arguments, &index, token))
            case "--model":
                request.model = try modelName(try value(arguments, &index, token))
            default:
                if let pair = split(token) {
                    switch pair.flag {
                    case "--provider": request.provider = try provider(pair.value)
                    case "--model": request.model = try modelName(pair.value)
                    default: throw unknownFlag(pair.flag, of: "ai research",
                                               taking: researchFlags)
                    }
                } else if token.hasPrefix("-"), token.count > 1 {
                    throw unknownFlag(token, of: "ai research", taking: researchFlags)
                } else {
                    words.append(token)
                }
            }
        }
        request.headphone = try headphoneName(words, "ai research")
        return request
    }

    private static func split(_ token: String) -> (flag: String, value: String)? {
        guard token.hasPrefix("--"), let equals = token.firstIndex(of: "=") else {
            return nil
        }
        return (String(token[token.startIndex..<equals]),
                String(token[token.index(after: equals)...]))
    }

    static let suggestFlags = "--kind, --provider, --model, --bands and --apply"

    static let researchFlags = "--provider, --model and --refresh"

    private static func unknownFlag(_ token: String, of subcommand: String,
                                    taking flags: String) -> CLIUsageError {
        CLIUsageError(message: "unknown option " + SafeText.scrubbed(token, limit: 40)
            + " — \(subcommand) takes " + flags)
    }

    private static func modelName(_ raw: String) throws -> String {
        let clean = SafeText.scrubbed(raw, limit: HeadphoneDossier.maxModel)
            .trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else {
            throw CLIUsageError(message: "--model needs a model name")
        }
        return clean
    }

    var needsDevice: Bool {
        if case .suggest(let request) = self { return request.apply }
        return false
    }

    var persistsToFlash: Bool { needsDevice }

    func run(options: CLIOptions, session: QxSession?) async throws {
        try await run(options: options, session: session, runtime: AIRuntime.current)
    }

    func run(options: CLIOptions, session: QxSession?, runtime: AIRuntime) async throws {
        do {
            switch self {
            case .providers:
                Self.printProviders(json: options.json, runtime: runtime)
            case .keyStatus:
                Self.printKeyStatus(json: options.json, runtime: runtime)
            case .keySet(let provider):
                try Self.setKey(provider, json: options.json, runtime: runtime)
            case .keyClear(let provider):
                try Self.clearKey(provider, json: options.json, runtime: runtime)
            case .research(let request):
                try await Self.research(request, json: options.json, runtime: runtime)
            case .suggest(let request):
                try await Self.suggest(request, json: options.json, session: session,
                                       runtime: runtime)
            }
        } catch let usage as CLIUsageError {
            throw usage
        } catch let failure as AIFailure {
            throw failure
        } catch {
            throw AIFailure(text: Self.message(for: error))
        }
    }

    static func message(for error: Error) -> String {
        SafeText.scrubbed((error as? LocalizedError)?.errorDescription
            ?? "\(error)", limit: 160)
    }

    static func hasKey(_ reading: AIKeychain.Reading) -> Bool {
        if case .key = reading { return true }
        return false
    }

    static func keyState(_ reading: AIKeychain.Reading) -> String {
        switch reading {
        case .key: return "saved"
        case .none: return "none"
        case .denied: return "unsafe mode"
        }
    }

    private static func printProviders(json: Bool, runtime: AIRuntime) {
        let readings = AIProvider.allCases.map {
            ($0, runtime.keychain.load(provider: $0.rawValue))
        }
        if json {
            StdIO.out(QxFormat.json([
                "providers": readings.map { provider, reading -> [String: Any] in
                    ["id": provider.rawValue,
                     "label": provider.label,
                     "host": provider.host,
                     "default_model": provider.defaultModel,
                     "key": hasKey(reading),
                     "key_state": keyState(reading)]
                },
            ]))
            return
        }
        let width = AIProvider.allCases.map(\.rawValue.count).max() ?? 0
        let modelWidth = AIProvider.allCases.map(\.defaultModel.count).max() ?? 0
        StdIO.out(QxFormat.pad("provider", width + 2) + QxFormat.pad("default model",
                                                                     modelWidth + 2) + "key")
        for (provider, reading) in readings {
            StdIO.out(QxFormat.pad(provider.rawValue, width + 2)
                + QxFormat.pad(provider.defaultModel, modelWidth + 2)
                + keyState(reading))
        }
    }

    private static func printKeyStatus(json: Bool, runtime: AIRuntime) {
        let readings = AIProvider.allCases.map {
            ($0, runtime.keychain.load(provider: $0.rawValue))
        }
        if json {
            var object: [String: Any] = [
                "directory": runtime.keychain.directory.path,
                "keys": readings.map { provider, reading -> [String: Any] in
                    ["id": provider.rawValue,
                     "key": hasKey(reading),
                     "key_state": keyState(reading),
                     "environment_variable":
                        AIKeychain.environmentVariable(provider: provider.rawValue),
                     "path": runtime.keychain.url(provider: provider.rawValue).path]
                },
            ]
            object["shared_environment_variable"] = AIKeychain.environmentVariable
            StdIO.out(QxFormat.json(object))
            return
        }
        let width = AIProvider.allCases.map(\.rawValue.count).max() ?? 0
        for (provider, reading) in readings {
            var line = QxFormat.pad(provider.rawValue, width + 2) + keyState(reading)
            if case .denied = reading {
                line += " — " + runtime.keychain.url(provider: provider.rawValue).path
                    + " is readable by other users; chmod 600 it"
            }
            StdIO.out(line)
        }
        StdIO.out("keys live in " + runtime.keychain.directory.path + ", one file per "
            + "provider at mode 0600")
    }

    private static func setKey(_ provider: AIProvider, json: Bool,
                               runtime: AIRuntime) throws {
        guard let typed = runtime.readKey() else {
            throw CLIUsageError(message: stdinAdvice(provider))
        }
        let clean = AIKeychain.printable(typed)
        guard !clean.isEmpty else {
            throw CLIUsageError(message: stdinAdvice(provider))
        }
        guard runtime.keychain.save(key: clean, provider: provider.rawValue) else {
            throw AIFailure(text: "could not write "
                + runtime.keychain.url(provider: provider.rawValue).path)
        }
        report(json, text: "saved a key for " + provider.label,
               object: ["provider": provider.rawValue,
                        "saved": true,
                        "path": runtime.keychain.url(provider: provider.rawValue).path])
    }

    private static func stdinAdvice(_ provider: AIProvider) -> String {
        "no key on standard input — pipe it in, as in "
            + "'printf %s \"$KEY\" | qudelix ai key set \(provider.rawValue)'"
    }

    private static func clearKey(_ provider: AIProvider, json: Bool,
                                 runtime: AIRuntime) throws {
        guard runtime.keychain.delete(provider: provider.rawValue) else {
            throw AIFailure(text: "could not remove "
                + runtime.keychain.url(provider: provider.rawValue).path)
        }
        report(json, text: "no key saved for " + provider.label,
               object: ["provider": provider.rawValue, "saved": false])
    }

    private static func report(_ json: Bool, text: String, object: [String: Any]) {
        StdIO.out(json ? QxFormat.json(object) : text)
    }

    static func defaultProvider(_ runtime: AIRuntime) -> AIProvider {
        AIProvider.allCases.first { runtime.keychain.hasKey(provider: $0.rawValue) }
            ?? AIProvider.allCases[0]
    }

    static func storedKey(_ provider: AIProvider, runtime: AIRuntime) throws -> String? {
        switch runtime.keychain.load(provider: provider.rawValue) {
        case .key(let key):
            return key
        case .none:
            return nil
        case .denied:
            throw CLIUsageError(
                message: "the saved \(provider.label) key is readable by other users — "
                    + "run 'chmod 600 "
                    + runtime.keychain.url(provider: provider.rawValue).path
                    + "', or store it again with 'qudelix ai key set \(provider.rawValue)'")
        }
    }

    static func missingKey(_ provider: AIProvider) -> CLIUsageError {
        CLIUsageError(message: "no \(provider.label) API key saved — run "
            + "'qudelix ai key set \(provider.rawValue)', or export "
            + AIKeychain.environmentVariable(provider: provider.rawValue))
    }

    private static func research(_ request: AIResearchRequest, json: Bool,
                                 runtime: AIRuntime) async throws {
        let provider = request.provider ?? defaultProvider(runtime)
        let model = request.model ?? provider.defaultModel
        let cacheKey = AIResearchStore.key(for: request.headphone)
        let file = runtime.research
        if !request.refresh, let cached = file.dossier(for: cacheKey) {
            emit(cached, headphone: request.headphone, cached: true, json: json)
            return
        }
        guard let key = try storedKey(provider, runtime: runtime) else {
            throw missingKey(provider)
        }
        let measurement = await runtime.measurement(request.headphone)
        let reply = try await AIPresetService.complete(
            provider: provider, model: model, key: key,
            system: AIPresetService.researchSystemPrompt,
            user: AIPresetService.researchUserPrompt(
                headphoneName: request.headphone,
                measurement: AIPresetService.measurementBlock(measurement)),
            transport: runtime.transport)
        let dossier = try AIPresetService.parseDossier(reply, provider: provider,
                                                       model: model,
                                                       measurement: measurement)
        file.store(dossier, for: cacheKey)
        emit(dossier, headphone: request.headphone, cached: false, json: json)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func dossierLines(_ dossier: HeadphoneDossier, headphone: String,
                             cached: Bool) -> [String] {
        var rows: [(String, String)] = [("headphone", headphone)]
        rows.append(("researched", stamp.string(from: dossier.researchedAt)
            + (cached ? " (from the cache)" : "")))
        rows.append(("by", [dossier.provider, dossier.model]
            .filter { !$0.isEmpty }.joined(separator: " · ")))
        rows.append(("confidence", dossier.confidence))
        for (label, text) in [("signature", dossier.signature), ("bass", dossier.bass),
                              ("mids", dossier.mids), ("treble", dossier.treble),
                              ("soundstage", dossier.soundstage)]
        where !text.isEmpty {
            rows.append((label, text))
        }
        if let measurement = dossier.measurement {
            rows.append(("measurement", measurement.title.isEmpty
                ? "\(measurement.bands.count) published filters"
                : "\(measurement.title) — \(measurement.bands.count) published filters"))
        }
        let width = rows.map { $0.0.count }.max() ?? 0
        var lines = rows.map { QxFormat.pad($0.0, width + 2) + $0.1 }
        guard !dossier.knownIssues.isEmpty else { return lines }
        lines.append("")
        lines.append("known issues")
        let region = dossier.knownIssues.map(\.region.count).max() ?? 0
        for issue in dossier.knownIssues {
            lines.append("  " + QxFormat.pad(issue.region, region + 2) + issue.issue)
        }
        return lines
    }

    static func dossierObject(_ dossier: HeadphoneDossier, headphone: String,
                              cached: Bool) -> [String: Any] {
        var object: [String: Any] = [
            "headphone": headphone,
            "cached": cached,
            "researched_at": stamp.string(from: dossier.researchedAt),
            "provider": dossier.provider,
            "model": dossier.model,
            "confidence": dossier.confidence,
            "signature": dossier.signature,
            "bass": dossier.bass,
            "mids": dossier.mids,
            "treble": dossier.treble,
            "soundstage": dossier.soundstage,
            "known_issues": dossier.knownIssues.map {
                ["where": $0.region, "issue": $0.issue]
            },
        ]
        if let measurement = dossier.measurement {
            object["measurement"] = ["title": measurement.title,
                                     "pre_gain_db": measurement.preGain,
                                     "filters": measurement.bands.count]
        }
        return object
    }

    private static func emit(_ dossier: HeadphoneDossier, headphone: String,
                             cached: Bool, json: Bool) {
        if json {
            StdIO.out(QxFormat.json(dossierObject(dossier, headphone: headphone,
                                                   cached: cached)))
        } else {
            for line in dossierLines(dossier, headphone: headphone, cached: cached) {
                StdIO.out(line)
            }
        }
    }

    struct Outcome {
        var draft: AIDraft
        var grounded: Bool
        var researchFallback: Bool
        var fromMeasurement: Bool
    }

    private static func suggest(_ request: AISuggestRequest, json: Bool,
                                session: QxSession?, runtime: AIRuntime) async throws {
        if request.apply, session == nil {
            throw CLIUsageError(message: "ai suggest --apply needs the device")
        }
        var group: QxEqGroup?
        if let session { group = await session.snapshot().eqGroup }
        if request.apply, let group, let asked = request.bands,
           asked != group.bandCount {
            throw CLIUsageError(
                message: "--bands \(asked) does not match the device, which is in "
                    + QxFormat.groupLabel(group) + " mode and takes "
                    + "\(group.bandCount) bands — drop --bands, or leave "
                    + "--apply off")
        }
        let bandCount = request.bands ?? group?.bandCount ?? defaultBandCount
        let provider = request.provider ?? defaultProvider(runtime)
        let model = request.model ?? provider.defaultModel
        let outcome = try await draft(request, bandCount: bandCount, provider: provider,
                                       model: model, runtime: runtime)

        var notes: [String] = []
        if let rationale = outcome.draft.rationale { notes.append(rationale) }
        notes.append(outcome.grounded
            ? "grounded in a published measurement of this model"
            : "no measurement found for this model — designed from general knowledge")
        if outcome.researchFallback {
            notes.append("research didn't come back — designed from general knowledge")
        }
        if let quantisation = outcome.draft.quantisationNote {
            notes.append(quantisation)
        }
        notes.append("pre-gain worked out here from the bands, not by the model")

        var applied: QxUserEqPreset?
        if request.apply, let session, let group {
            guard outcome.draft.bands.count <= group.bandCount else {
                throw CLIUsageError(
                    message: "this draft has \(outcome.draft.bands.count) bands and the "
                        + "device is in " + QxFormat.groupLabel(group) + " mode, which "
                        + "takes \(group.bandCount)")
            }
            var file = ParametricEQFile()
            file.preamp = outcome.draft.preGain
            file.bands = outcome.draft.bands
            applied = try await session.applyParametric(
                file, expecting: group, recording: "ai " + request.headphone)
        }

        let preGain = applied?.preGain ?? outcome.draft.preGain
        let bands = applied?.bands ?? outcome.draft.bands
        if json {
            var object = QxFormat.eqObject(preGain: preGain, bands: bands,
                                           enabled: applied == nil ? nil : true,
                                           group: group ?? .user)
            object["headphone"] = request.headphone
            object["kind"] = request.kind.rawValue
            object["kind_label"] = request.kind.label
            object["name"] = outcome.draft.name
            object["provider"] = provider.rawValue
            object["model"] = model
            object["band_count"] = bandCount
            object["grounded"] = outcome.grounded
            object["research_fallback"] = outcome.researchFallback
            object["from_measurement"] = outcome.fromMeasurement
            object["applied"] = applied != nil
            object["notes"] = notes
            if let rationale = outcome.draft.rationale { object["rationale"] = rationale }
            StdIO.out(QxFormat.json(object))
            return
        }
        StdIO.out(outcome.draft.name)
        StdIO.out(request.headphone + " · " + request.kind.label
            + " · \(bandCount) bands · " + provider.rawValue + " " + model)
        StdIO.out("")
        for line in QxFormat.eqLines(preGain: preGain, bands: bands) { StdIO.out(line) }
        StdIO.out("")
        for note in notes { StdIO.out("note: " + note) }
        StdIO.out(applied == nil
            ? "not applied — add --apply to write it to the device"
            : "applied to the device")
    }

    static func draft(_ request: AISuggestRequest, bandCount: Int,
                      provider: AIProvider, model: String,
                      runtime: AIRuntime) async throws -> Outcome {
        let cacheKey = AIResearchStore.key(for: request.headphone)
        let file = runtime.research
        var dossier = file.dossier(for: cacheKey)
        var measurement = dossier?.measurement

        if request.kind == .correction, let known = measurement,
           let local = AIPresetService.correctionDraft(from: known,
                                                        bandCount: bandCount) {
            return Outcome(draft: local, grounded: true, researchFallback: false,
                           fromMeasurement: true)
        }

        let stored = try storedKey(provider, runtime: runtime)
        if measurement == nil {
            measurement = await runtime.measurement(request.headphone)
        }
        if request.kind == .correction, let known = measurement,
           let local = AIPresetService.correctionDraft(from: known,
                                                        bandCount: bandCount) {
            return Outcome(draft: local, grounded: true, researchFallback: false,
                           fromMeasurement: true)
        }
        guard let key = stored else { throw missingKey(provider) }

        let block = AIPresetService.measurementBlock(measurement)
        var fellBack = false
        if dossier == nil {
            do {
                let reply = try await AIPresetService.complete(
                    provider: provider, model: model, key: key,
                    system: AIPresetService.researchSystemPrompt,
                    user: AIPresetService.researchUserPrompt(
                        headphoneName: request.headphone, measurement: block),
                    transport: runtime.transport)
                let fresh = try AIPresetService.parseDossier(reply, provider: provider,
                                                             model: model,
                                                             measurement: measurement)
                file.store(fresh, for: cacheKey)
                dossier = fresh
            } catch let error as URLError {
                throw AIFailure(text: message(for: error))
            } catch {
                fellBack = true
            }
        }

        let reply = try await AIPresetService.complete(
            provider: provider, model: model, key: key,
            system: AIPresetService.systemPrompt(bandCount: bandCount),
            user: AIPresetService.userPrompt(kind: request.kind, bandCount: bandCount,
                                             headphoneName: request.headphone,
                                             note: "", measurement: block,
                                             dossier: dossier),
            transport: runtime.transport)
        let parsed = try AIPresetService.parseDraft(reply, bandCount: bandCount,
                                                     kind: request.kind)
        return Outcome(draft: parsed, grounded: block != nil,
                       researchFallback: fellBack, fromMeasurement: false)
    }
}
