import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import QudelixBar

final class ScriptedAITransport: AITransport, @unchecked Sendable {
    private var replies: [Data]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Data] = []) { self.replies = replies }

    var callCount: Int { requests.count }

    func send(_ request: URLRequest, host: String, limit: Int) async throws -> Data {
        requests.append(request)
        guard !replies.isEmpty else { throw AIError.emptyReply }
        return replies.removeFirst()
    }
}

final class AICommandsTests: XCTestCase {
    private var temporaries: [URL] = []

    override func tearDown() {
        for url in temporaries { try? FileManager.default.removeItem(at: url) }
        temporaries = []
        AIRuntime.current = AIRuntime()
        super.tearDown()
    }

    private func directory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qudelix-ai-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        temporaries.append(url)
        return url
    }

    private func keychain(_ url: URL) -> AIKeychain {
        AIKeychain(directory: url, environment: [:])
    }

    private func chatReply(_ text: String) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: ["choices": [["message": ["content": text]]]])) ?? Data()
    }

    private func messagesReply(_ text: String) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: ["content": [["type": "text", "text": text]]])) ?? Data()
    }

    private func ten() -> [(Double, Double, Double, String)] {
        [(31, 4, 0.7, "lowShelf"), (63, 2, 1.0, "peak"), (125, -1, 1.0, "peak"),
         (250, -2, 1.0, "peak"), (500, 0.5, 1.0, "peak"), (1000, 1, 1.0, "peak"),
         (2000, 2, 1.0, "peak"), (4000, -3, 1.0, "peak"), (8000, 1.5, 1.0, "peak"),
         (16000, -1, 0.7, "highShelf")]
    }

    private func draftText(name: String = "Airy 650",
                           rationale: String = "Lifts the presence dip.") -> String {
        let rows = ten().map { band in
            "{\"freq\": \(band.0), \"gainDb\": \(band.1), \"q\": \(band.2), "
                + "\"kind\": \"\(band.3)\"}"
        }.joined(separator: ", ")
        return "{\"name\": \"\(name)\", \"rationale\": \"\(rationale)\", "
            + "\"bands\": [\(rows)]}"
    }

    private func dossierText(signature: String = "Neutral with a lifted top") -> String {
        "{\"signature\": \"\(signature)\", \"bass\": \"Lean below 60 Hz\", "
            + "\"mids\": \"Even\", \"treble\": \"A peak at 6 kHz\", "
            + "\"soundstage\": \"Wide\", \"knownIssues\": "
            + "[{\"where\": \"3-5 kHz\", \"issue\": \"peak\"}], "
            + "\"confidence\": \"high\"}"
    }

    private func scripted() -> ScriptedAITransport {
        ScriptedAITransport([chatReply(dossierText()), chatReply(draftText())])
    }

    private func measurement() -> HeadphoneDossier.Measurement {
        HeadphoneDossier.Measurement(
            title: "Sennheiser HD 650",
            preGain: -6.1,
            bands: [QxEqBandValue(filter: .lowShelf, freq: 105, gain: 6.4, q: 0.7),
                    QxEqBandValue(filter: .peak, freq: 400, gain: -2.5, q: 1.2),
                    QxEqBandValue(filter: .peak, freq: 3200, gain: 3.1, q: 1.4),
                    QxEqBandValue(filter: .peak, freq: 8800, gain: -5.1, q: 1.42)])
    }

    private func dossier(with measurement: HeadphoneDossier.Measurement?)
        -> HeadphoneDossier {
        HeadphoneDossier(signature: "Neutral with a lifted top",
                         bass: "Lean below 60 Hz",
                         mids: "Even",
                         treble: "A peak at 6 kHz",
                         soundstage: "Wide",
                         knownIssues: [HeadphoneDossier.Issue(region: "3-5 kHz",
                                                              issue: "peak")],
                         confidence: "high",
                         measurement: measurement,
                         researchedAt: Date(timeIntervalSince1970: 1_757_000_000),
                         provider: "mistral",
                         model: "mistral-medium-latest",
                         lastUsedAt: Date(timeIntervalSince1970: 1_757_000_000))
    }

    private func runtime(_ store: URL, transport: AITransport,
                         key: String? = nil,
                         provider: AIProvider = .mistral,
                         measurement: HeadphoneDossier.Measurement? = nil,
                         stdin: String? = nil) -> AIRuntime {
        let keys = directory()
        if let key { XCTAssertTrue(keychain(keys).save(key: key, provider: provider.rawValue)) }
        var runtime = AIRuntime()
        runtime.keychain = keychain(keys)
        runtime.transport = transport
        runtime.researchDirectory = store
        runtime.measurement = { _ in measurement }
        runtime.readKey = { stdin }
        return runtime
    }

    private func captured(_ body: () async throws -> Void) async throws -> String {
        let path = NSTemporaryDirectory() + "/qudelix-ai-out-" + UUID().uuidString
        let saved = dup(1)
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        dup2(fd, 1)
        close(fd)
        var thrown: Error?
        do { try await body() } catch { thrown = error }
        dup2(saved, 1)
        close(saved)
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: path)
        if let thrown { throw thrown }
        return text
    }

    private func usageMessage(_ rest: [String]) -> String? {
        do {
            _ = try AICommand.parse(rest)
            return nil
        } catch let error as CLIUsageError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    func testTheFamilyPlugsInUnderItsOwnName() throws {
        XCTAssertEqual(AICommand.name, "ai")
        XCTAssertEqual(try CLI.parse(["ai", "providers"]).command, .ai(.providers))
        XCTAssertTrue(CLI.usageText.contains("ai providers"))
        XCTAssertTrue(CLI.usageText.contains("ai suggest <headphone>"))
    }

    func testEveryUsageLineIsIndentedAndAlignedWithTheOtherCommands() {
        for line in AICommand.usageLines.dropLast() {
            let characters = Array(line)
            XCTAssertGreaterThan(characters.count, 28, line)
            XCTAssertEqual(characters[0], " ", line)
            XCTAssertEqual(characters[1], " ", line)
            XCTAssertNotEqual(characters[2], " ", line)
            XCTAssertEqual(characters[27], " ", line)
            XCTAssertNotEqual(characters[28], " ", line)
        }
        XCTAssertTrue(AICommand.usageLines.last?.hasPrefix("    [--kind") ?? false)
    }

    func testProvidersAndKeyStatusTakeNoArguments() throws {
        XCTAssertEqual(try AICommand.parse(["providers"]), .providers)
        XCTAssertEqual(try AICommand.parse(["key", "status"]), .keyStatus)
        XCTAssertEqual(usageMessage(["providers", "all"]), "ai providers takes no arguments")
        XCTAssertEqual(usageMessage(["key", "status", "all"]),
                       "ai key status takes no arguments")
    }

    func testKeySetAndClearNameOneProvider() throws {
        XCTAssertEqual(try AICommand.parse(["key", "set", "openai"]), .keySet(.openai))
        XCTAssertEqual(try AICommand.parse(["key", "set", "OpenAI"]), .keySet(.openai))
        XCTAssertEqual(try AICommand.parse(["key", "clear", "anthropic"]),
                       .keyClear(.anthropic))
        XCTAssertEqual(try AICommand.parse(["key", "forget", "openrouter"]),
                       .keyClear(.openrouter))
        XCTAssertNotNil(usageMessage(["key"]))
        XCTAssertNotNil(usageMessage(["key", "set"]))
        XCTAssertNotNil(usageMessage(["key", "set", "openai", "sk-oops"]))
        XCTAssertNotNil(usageMessage(["key", "sideways", "openai"]))
    }

    func testAKeyIsNeverTakenFromTheArgumentList() {
        let message = usageMessage(["key", "set", "openai", "sk-not-a-real-key"])
        XCTAssertNotNil(message)
        XCTAssertFalse(message?.contains("sk-not-a-real-key") ?? true)
    }

    func testEveryProviderAndEveryKindResolvesByNameAndByLabel() throws {
        for provider in AIProvider.allCases {
            XCTAssertEqual(try AICommand.provider(provider.rawValue), provider)
            XCTAssertEqual(try AICommand.provider(provider.label), provider)
            XCTAssertEqual(try AICommand.provider(provider.rawValue.uppercased()), provider)
        }
        for kind in AIPresetKind.allCases {
            XCTAssertEqual(try AICommand.kind(kind.rawValue), kind)
            XCTAssertEqual(try AICommand.kind(kind.label), kind)
        }
        XCTAssertEqual(try AICommand.kind("sub-bass-control"), .subBassControl)
        XCTAssertEqual(try AICommand.kind("flat_studio"), .flatStudio)
    }

    func testAnUnknownProviderOrKindListsWhatIsAvailable() {
        let provider = usageMessage(["key", "set", "skynet"])
        XCTAssertTrue(provider?.contains("mistral") ?? false)
        XCTAssertTrue(provider?.contains("openrouter") ?? false)
        let kind = usageMessage(["suggest", "HD 650", "--kind", "loud"])
        XCTAssertTrue(kind?.contains("correction") ?? false)
        XCTAssertTrue(kind?.contains("harmanOE") ?? false)
    }

    func testSuggestDefaultsToCorrectionOfTenBandsWithoutApplying() throws {
        guard case .suggest(let request) = try AICommand.parse(["suggest", "HD 650"]) else {
            return XCTFail("suggest should parse as suggest")
        }
        XCTAssertEqual(request.headphone, "HD 650")
        XCTAssertEqual(request.kind, .correction)
        XCTAssertNil(request.provider)
        XCTAssertNil(request.model)
        XCTAssertNil(request.bands)
        XCTAssertFalse(request.apply)
        XCTAssertEqual(AICommand.defaultBandCount, 10)
    }

    func testSuggestTakesEveryFlagInEitherSpelling() throws {
        let spaced = try AICommand.parse(["suggest", "Sennheiser", "HD", "650",
                                          "--kind", "clarity", "--provider", "openai",
                                          "--model", "gpt-x", "--bands", "20", "--apply"])
        let joined = try AICommand.parse(["suggest", "--kind=clarity",
                                          "--provider=openai", "--model=gpt-x",
                                          "--bands=20", "--apply",
                                          "Sennheiser HD 650"])
        XCTAssertEqual(spaced, joined)
        guard case .suggest(let request) = spaced else {
            return XCTFail("suggest should parse as suggest")
        }
        XCTAssertEqual(request.headphone, "Sennheiser HD 650")
        XCTAssertEqual(request.kind, .clarity)
        XCTAssertEqual(request.provider, .openai)
        XCTAssertEqual(request.model, "gpt-x")
        XCTAssertEqual(request.bands, 20)
        XCTAssertTrue(request.apply)
    }

    func testSuggestRefusesABandCountTheDeviceHasNoBankFor() {
        XCTAssertNotNil(usageMessage(["suggest", "HD 650", "--bands", "12"]))
        XCTAssertNotNil(usageMessage(["suggest", "HD 650", "--bands", "0"]))
        XCTAssertNotNil(usageMessage(["suggest", "HD 650", "--bands"]))
        XCTAssertNil(usageMessage(["suggest", "HD 650", "--bands", "10"]))
        XCTAssertNil(usageMessage(["suggest", "HD 650", "--bands", "20"]))
        XCTAssertEqual(AICommand.bandCounts, [10, 20])
    }

    func testSuggestAndResearchNeedAHeadphoneName() {
        XCTAssertNotNil(usageMessage(["suggest"]))
        XCTAssertNotNil(usageMessage(["suggest", "--apply"]))
        XCTAssertNotNil(usageMessage(["suggest", "x"]))
        XCTAssertNotNil(usageMessage(["research"]))
        XCTAssertNotNil(usageMessage(["research", "\u{202E}"]))
    }

    func testAnUnknownFlagNamesTheOnesTheFamilyTakes() {
        let message = usageMessage(["suggest", "HD 650", "--loud"])
        XCTAssertTrue(message?.contains("--loud") ?? false)
        XCTAssertTrue(message?.contains("--apply") ?? false)
        XCTAssertNotNil(usageMessage(["research", "HD 650", "--apply"]))
    }

    func testResearchTakesAProviderAModelAndARefresh() throws {
        guard case .research(let request) =
                try AICommand.parse(["research", "HD 650", "--provider", "anthropic",
                                     "--model", "model-x", "--refresh"]) else {
            return XCTFail("research should parse as research")
        }
        XCTAssertEqual(request.headphone, "HD 650")
        XCTAssertEqual(request.provider, .anthropic)
        XCTAssertEqual(request.model, "model-x")
        XCTAssertTrue(request.refresh)
    }

    func testAnUnknownSubcommandIsAUsageError() {
        XCTAssertNotNil(usageMessage([]))
        XCTAssertNotNil(usageMessage(["sideways"]))
    }

    func testOnlyApplyingNeedsTheDeviceAndOnlyApplyingPersists() throws {
        let apply = try AICommand.parse(["suggest", "HD 650", "--apply"])
        XCTAssertTrue(apply.needsDevice)
        XCTAssertTrue(apply.persistsToFlash)
        XCTAssertTrue(CLI.needsDevice(.ai(apply)))
        XCTAssertTrue(QudelixCLI.persistsToFlash(.ai(apply)))
        for command in [try AICommand.parse(["suggest", "HD 650"]),
                        try AICommand.parse(["research", "HD 650"]),
                        .providers, .keyStatus, .keySet(.openai), .keyClear(.openai)] {
            XCTAssertFalse(command.needsDevice, "\(command)")
            XCTAssertFalse(command.persistsToFlash, "\(command)")
            XCTAssertFalse(CLI.needsDevice(.ai(command)), "\(command)")
            XCTAssertFalse(QudelixCLI.persistsToFlash(.ai(command)), "\(command)")
        }
    }

    func testAKeyIsStoredPerProviderAtMode0600() throws {
        let store = keychain(directory())
        XCTAssertEqual(store.load(provider: "openai"), .none)
        XCTAssertTrue(store.save(key: "sk-openai", provider: "openai"))
        XCTAssertEqual(store.load(provider: "openai"), .key("sk-openai"))
        XCTAssertEqual(store.load(provider: "mistral"), .none,
                       "one provider's key is not another's")
        XCTAssertTrue(store.hasKey(provider: "openai"))
        XCTAssertFalse(store.hasKey(provider: "mistral"))

        var status = stat()
        XCTAssertEqual(stat(store.url(provider: "openai").path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o600)

        var parent = stat()
        XCTAssertEqual(stat(store.directory.path, &parent), 0)
        XCTAssertEqual(parent.st_mode & 0o077, 0)

        XCTAssertTrue(store.delete(provider: "openai"))
        XCTAssertEqual(store.load(provider: "openai"), .none)
        XCTAssertTrue(store.delete(provider: "openai"), "deleting nothing is not a failure")
    }

    func testAKeyFileOtherUsersCanReadIsRefusedRatherThanUsed() throws {
        let store = keychain(directory())
        XCTAssertTrue(store.save(key: "sk-openai", provider: "openai"))
        XCTAssertEqual(chmod(store.url(provider: "openai").path, 0o644), 0)
        XCTAssertEqual(store.load(provider: "openai"), .denied)
        XCTAssertFalse(store.hasKey(provider: "openai"))
        XCTAssertEqual(AICommand.keyState(.denied), "unsafe mode")
    }

    func testTheStoreRefusesAnEmptyKeyAndKeepsOnlyPrintableCharacters() throws {
        let store = keychain(directory())
        XCTAssertFalse(store.save(key: "  \n ", provider: "openai"))
        XCTAssertEqual(store.load(provider: "openai"), .none)
        XCTAssertTrue(store.save(key: " sk-a\u{0}b\nc\u{202E}d \n", provider: "openai"))
        XCTAssertEqual(store.load(provider: "openai"), .key("sk-abcd"))
    }

    func testAnEnvironmentKeyWinsAndIsProviderSpecific() {
        let store = AIKeychain(directory: directory(),
                               environment: ["QUDELIX_AI_KEY_OPENAI": "sk-env-openai",
                                             "QUDELIX_AI_KEY": "sk-env-any"])
        XCTAssertEqual(store.load(provider: "openai"), .key("sk-env-openai"))
        XCTAssertEqual(store.load(provider: "mistral"), .key("sk-env-any"))
        XCTAssertEqual(AIKeychain.environmentVariable(provider: "openai"),
                       "QUDELIX_AI_KEY_OPENAI")
    }

    func testAProviderNameCannotSteerTheKeyFileOutOfItsDirectory() {
        let store = keychain(directory())
        for hostile in ["../../etc/passwd", "/etc/passwd", "..", "", "a/b"] {
            let url = store.url(provider: hostile)
            XCTAssertEqual(url.deletingLastPathComponent().path, store.directory.path,
                           hostile)
            XCTAssertFalse(url.lastPathComponent.contains("/"), hostile)
        }
        XCTAssertEqual(AIKeychain.slug("OpenRouter"), "openrouter")
        XCTAssertEqual(AIKeychain.slug("../.."), "unnamed")
    }

    func testProvidersListsEveryProviderItsModelAndWhetherAKeyIsSaved() async throws {
        let store = directory()
        var runtime = self.runtime(store, transport: ScriptedAITransport())
        XCTAssertTrue(runtime.keychain.save(key: "sk-openai", provider: "openai"))
        let text = try await captured {
            try await AICommand.providers.run(options: CLIOptions(), session: nil,
                                              runtime: runtime)
        }
        for provider in AIProvider.allCases {
            XCTAssertTrue(text.contains(provider.rawValue), provider.rawValue)
            XCTAssertTrue(text.contains(provider.defaultModel), provider.defaultModel)
        }
        XCTAssertTrue(text.contains("saved"))
        XCTAssertTrue(text.contains("none"))
        XCTAssertFalse(text.contains("sk-openai"), "a key is never printed")

        runtime.transport = ScriptedAITransport()
        let json = try await captured {
            try await AICommand.providers.run(options: CLIOptions(json: true),
                                              session: nil, runtime: runtime)
        }
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let rows = ((object as? [String: Any])?["providers"] as? [[String: Any]]) ?? []
        XCTAssertEqual(rows.count, AIProvider.allCases.count)
        XCTAssertEqual(rows.first?["id"] as? String, AIProvider.allCases[0].rawValue)
        XCTAssertEqual(rows[1]["key"] as? Bool, true)
        XCTAssertFalse(json.contains("sk-openai"))
    }

    func testKeySetReadsStandardInputStoresTheKeyAndNeverEchoesIt() async throws {
        let store = directory()
        let runtime = self.runtime(store, transport: ScriptedAITransport(),
                                   stdin: "sk-from-stdin\n")
        let text = try await captured {
            try await AICommand.keySet(.openai).run(options: CLIOptions(), session: nil,
                                                    runtime: runtime)
        }
        XCTAssertEqual(runtime.keychain.load(provider: "openai"), .key("sk-from-stdin"))
        XCTAssertFalse(text.contains("sk-from-stdin"))
        XCTAssertTrue(text.contains("OpenAI"))

        let cleared = try await captured {
            try await AICommand.keyClear(.openai).run(options: CLIOptions(), session: nil,
                                                      runtime: runtime)
        }
        XCTAssertEqual(runtime.keychain.load(provider: "openai"), .none)
        XCTAssertTrue(cleared.contains("no key saved"))
    }

    func testKeySetWithNothingOnStandardInputSaysHowToPipeItIn() async throws {
        let runtime = self.runtime(directory(), transport: ScriptedAITransport(),
                                   stdin: "  \n")
        do {
            _ = try await captured {
                try await AICommand.keySet(.openai).run(options: CLIOptions(),
                                                        session: nil, runtime: runtime)
            }
            XCTFail("an empty stdin is not a key")
        } catch let error as CLIUsageError {
            XCTAssertTrue(error.message.contains("standard input"))
            XCTAssertTrue(error.message.contains("ai key set openai"))
        }
    }

    func testKeyStatusReportsPresenceAndThePathWithoutTheKey() async throws {
        let runtime = self.runtime(directory(), transport: ScriptedAITransport())
        XCTAssertTrue(runtime.keychain.save(key: "sk-mistral", provider: "mistral"))
        let text = try await captured {
            try await AICommand.keyStatus.run(options: CLIOptions(), session: nil,
                                              runtime: runtime)
        }
        XCTAssertTrue(text.contains("mistral"))
        XCTAssertTrue(text.contains("saved"))
        XCTAssertTrue(text.contains(runtime.keychain.directory.path))
        XCTAssertFalse(text.contains("sk-mistral"))
    }

    func testResearchAsksTheProviderOnceAndThenAnswersFromTheCache() async throws {
        let store = directory()
        let transport = ScriptedAITransport([chatReply(dossierText())])
        let runtime = self.runtime(store, transport: transport, key: "sk-mistral",
                                   measurement: measurement())
        let request = AIResearchRequest(headphone: "Sennheiser HD 650")
        let first = try await captured {
            try await AICommand.research(request).run(options: CLIOptions(),
                                                      session: nil, runtime: runtime)
        }
        XCTAssertEqual(transport.callCount, 1)
        XCTAssertTrue(first.contains("Sennheiser HD 650"))
        XCTAssertTrue(first.contains("Neutral with a lifted top"))
        XCTAssertTrue(first.contains("3-5 kHz"))
        XCTAssertTrue(first.contains("high"))
        XCTAssertFalse(first.contains("sk-mistral"))

        let again = try await captured {
            try await AICommand.research(request).run(options: CLIOptions(),
                                                      session: nil, runtime: runtime)
        }
        XCTAssertEqual(transport.callCount, 1, "the cached dossier needs no request")
        XCTAssertTrue(again.contains("from the cache"))
        XCTAssertTrue(again.contains("Neutral with a lifted top"))

        let refreshed = AIResearchRequest(headphone: "Sennheiser HD 650", refresh: true)
        do {
            _ = try await captured {
                try await AICommand.research(refreshed).run(options: CLIOptions(),
                                                            session: nil, runtime: runtime)
            }
            XCTFail("the scripted transport has nothing left to answer with")
        } catch let error as AIFailure {
            XCTAssertFalse(error.text.isEmpty)
        }
        XCTAssertEqual(transport.callCount, 2, "--refresh asks again")
    }

    func testResearchOnAModelWithNoKeyIsAUsageErrorNamingKeySet() async {
        let runtime = self.runtime(directory(), transport: ScriptedAITransport())
        do {
            try await AICommand.research(AIResearchRequest(headphone: "HD 650"))
                .run(options: CLIOptions(), session: nil, runtime: runtime)
            XCTFail("no key, no research")
        } catch let error as CLIUsageError {
            XCTAssertTrue(error.message.contains("ai key set mistral"))
        } catch {
            XCTFail("expected a usage error, got \(error)")
        }
    }

    func testTheDossierIsWrittenWhereTheMacAppLooksForIt() throws {
        let store = directory()
        let file = AIResearchFile(directory: store)
        let key = AIResearchStore.key(for: "Sennheiser HD 650")
        XCTAssertNil(file.dossier(for: key))
        XCTAssertTrue(file.store(dossier(with: measurement()), for: key))
        XCTAssertEqual(file.url.lastPathComponent, AIResearchStore.fileName)
        let read = try XCTUnwrap(file.dossier(for: key))
        XCTAssertEqual(read.signature, "Neutral with a lifted top")
        XCTAssertEqual(read.measurement?.title, "Sennheiser HD 650")
        XCTAssertEqual(file.dossier(for: AIResearchStore.key(for: "HD 800")), nil)
        XCTAssertFalse(file.store(dossier(with: nil), for: ""))
    }

    func testSuggestResearchesThenDesignsAndReportsTheBandsItWouldWrite() async throws {
        let store = directory()
        let transport = scripted()
        let runtime = self.runtime(store, transport: transport, key: "sk-mistral",
                                   measurement: measurement())
        let request = AISuggestRequest(headphone: "Sennheiser HD 650", kind: .clarity)
        let text = try await captured {
            try await AICommand.suggest(request).run(options: CLIOptions(), session: nil,
                                                     runtime: runtime)
        }
        XCTAssertEqual(transport.callCount, 2, "research, then design")
        XCTAssertTrue(text.contains("Airy 650"))
        XCTAssertTrue(text.contains("Clarity"))
        XCTAssertTrue(text.contains("10 bands"))
        XCTAssertTrue(text.contains("pre-gain"))
        XCTAssertTrue(text.contains("16000 Hz"))
        XCTAssertTrue(text.contains("Lifts the presence dip."))
        XCTAssertTrue(text.contains("grounded in a published measurement"))
        XCTAssertTrue(text.contains("not applied"))
        XCTAssertFalse(text.contains("sk-mistral"))

        let cached = try XCTUnwrap(
            AIResearchFile(directory: store)
                .dossier(for: AIResearchStore.key(for: "Sennheiser HD 650")))
        XCTAssertEqual(cached.provider, "mistral")
        XCTAssertEqual(cached.measurement?.title, "Sennheiser HD 650")
    }

    func testSuggestInJsonCarriesTheDraftTheProviderAndTheBands() async throws {
        let runtime = self.runtime(directory(), transport: scripted(), key: "sk-mistral",
                                   measurement: measurement())
        let request = AISuggestRequest(headphone: "Sennheiser HD 650", kind: .clarity)
        let json = try await captured {
            try await AICommand.suggest(request).run(options: CLIOptions(json: true),
                                                     session: nil, runtime: runtime)
        }
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["headphone"] as? String, "Sennheiser HD 650")
        XCTAssertEqual(object["kind"] as? String, "clarity")
        XCTAssertEqual(object["provider"] as? String, "mistral")
        XCTAssertEqual(object["model"] as? String, AIProvider.mistral.defaultModel)
        XCTAssertEqual(object["applied"] as? Bool, false)
        XCTAssertEqual(object["grounded"] as? Bool, true)
        XCTAssertEqual(object["band_count"] as? Int, 10)
        XCTAssertNotNil(object["pre_gain_db"])
        XCTAssertFalse(json.contains("sk-mistral"))
    }

    func testTheRequestedBandCountIsTheOneTheDraftHasToMatch() async {
        let runtime = self.runtime(directory(), transport: scripted(), key: "sk-mistral",
                                   measurement: measurement())
        let request = AISuggestRequest(headphone: "Sennheiser HD 650", kind: .clarity,
                                       bands: 20)
        do {
            try await AICommand.suggest(request).run(options: CLIOptions(), session: nil,
                                                     runtime: runtime)
            XCTFail("a ten-band draft is not a twenty-band preset")
        } catch let failure as AIFailure {
            XCTAssertEqual(failure.text,
                           AIError.wrongBandCount(10, 20).errorDescription ?? "")
        } catch {
            XCTFail("expected an AIFailure, got \(error)")
        }
    }

    func testSuggestOfACorrectionFromAStoredMeasurementNeedsNeitherKeyNorNetwork()
        async throws {
        let store = directory()
        let file = AIResearchFile(directory: store)
        XCTAssertTrue(file.store(dossier(with: measurement()),
                                 for: AIResearchStore.key(for: "Sennheiser HD 650")))
        let transport = ScriptedAITransport()
        let runtime = self.runtime(store, transport: transport)
        let request = AISuggestRequest(headphone: "Sennheiser HD 650", kind: .correction)
        let text = try await captured {
            try await AICommand.suggest(request).run(options: CLIOptions(), session: nil,
                                                     runtime: runtime)
        }
        XCTAssertEqual(transport.callCount, 0, "a published measurement is enough")
        XCTAssertTrue(text.contains("Sennheiser HD 650"))
        XCTAssertTrue(text.contains("105 Hz"))
        XCTAssertTrue(text.contains("grounded in a published measurement"))
    }

    func testADesignWithNoKeyIsAUsageErrorNamingKeySet() async {
        let runtime = self.runtime(directory(), transport: ScriptedAITransport(),
                                   measurement: nil)
        do {
            try await AICommand.suggest(AISuggestRequest(headphone: "HD 650",
                                                         kind: .clarity))
                .run(options: CLIOptions(), session: nil, runtime: runtime)
            XCTFail("no key, no design")
        } catch let error as CLIUsageError {
            XCTAssertTrue(error.message.contains("ai key set mistral"))
        } catch {
            XCTFail("expected a usage error, got \(error)")
        }
    }

    func testAKeyFileWithLooseModeIsAUsageErrorRatherThanASilentFailure() async {
        let keys = directory()
        var runtime = self.runtime(directory(), transport: ScriptedAITransport())
        runtime.keychain = keychain(keys)
        XCTAssertTrue(runtime.keychain.save(key: "sk-mistral", provider: "mistral"))
        XCTAssertEqual(chmod(runtime.keychain.url(provider: "mistral").path, 0o666), 0)
        do {
            try await AICommand.suggest(AISuggestRequest(headphone: "HD 650",
                                                         kind: .clarity))
                .run(options: CLIOptions(), session: nil, runtime: runtime)
            XCTFail("a world-readable key file is not usable")
        } catch let error as CLIUsageError {
            XCTAssertTrue(error.message.contains("chmod 600"))
            XCTAssertFalse(error.message.contains("sk-mistral"))
        } catch {
            XCTFail("expected a usage error, got \(error)")
        }
    }

    func testADesignThatComesBackWrongIsReportedAsTheProvidersFault() async {
        let runtime = self.runtime(directory(),
                                   transport: ScriptedAITransport([
                                       chatReply(dossierText()),
                                       chatReply("I would rather not."),
                                   ]),
                                   key: "sk-mistral")
        do {
            try await AICommand.suggest(AISuggestRequest(headphone: "HD 650",
                                                         kind: .clarity))
                .run(options: CLIOptions(), session: nil, runtime: runtime)
            XCTFail("prose is not a preset")
        } catch let failure as AIFailure {
            XCTAssertEqual(failure.text, AIError.notJSON.errorDescription ?? "")
            XCTAssertEqual(QudelixCLI.describe(failure), failure.text)
        } catch {
            XCTFail("expected an AIFailure, got \(error)")
        }
    }

    func testResearchThatFailsStillDesignsFromGeneralKnowledge() async throws {
        let runtime = self.runtime(directory(),
                                   transport: ScriptedAITransport([
                                       chatReply("not a dossier"),
                                       chatReply(draftText()),
                                   ]),
                                   key: "sk-mistral")
        let text = try await captured {
            try await AICommand.suggest(AISuggestRequest(headphone: "HD 650",
                                                         kind: .clarity))
                .run(options: CLIOptions(), session: nil, runtime: runtime)
        }
        XCTAssertTrue(text.contains("research didn't come back"))
        XCTAssertTrue(text.contains("no measurement found for this model"))
        XCTAssertTrue(text.contains("Airy 650"))
    }

    func testTheMessagesShapedProviderIsReadTheSameWay() async throws {
        let runtime = self.runtime(directory(),
                                   transport: ScriptedAITransport([
                                       messagesReply(dossierText()),
                                       messagesReply(draftText()),
                                   ]),
                                   key: "sk-anthropic", provider: .anthropic)
        let request = AISuggestRequest(headphone: "HD 650", kind: .clarity,
                                       provider: .anthropic)
        let text = try await captured {
            try await AICommand.suggest(request).run(options: CLIOptions(), session: nil,
                                                     runtime: runtime)
        }
        XCTAssertTrue(text.contains("Airy 650"))
        XCTAssertTrue(text.contains("anthropic"))
    }

    func testTheKeyTravelsOnlyInTheRequestHeaderTheTransportSees() async throws {
        let transport = scripted()
        let runtime = self.runtime(directory(), transport: transport, key: "sk-mistral")
        _ = try await captured {
            try await AICommand.suggest(AISuggestRequest(headphone: "HD 650",
                                                         kind: .clarity))
                .run(options: CLIOptions(), session: nil, runtime: runtime)
        }
        XCTAssertEqual(transport.requests.count, 2)
        for request in transport.requests {
            XCTAssertEqual(request.url?.host, AIProvider.mistral.host)
            XCTAssertEqual(request.url?.scheme, "https")
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            XCTAssertFalse(body.contains("sk-mistral"))
            let headers = request.allHTTPHeaderFields ?? [:]
            XCTAssertEqual(headers.filter { $0.value.contains("sk-mistral") }.count, 1)
        }
    }

    func testTheDefaultProviderIsTheFirstOneWithAKey() {
        let runtime = self.runtime(directory(), transport: ScriptedAITransport())
        XCTAssertEqual(AICommand.defaultProvider(runtime), AIProvider.allCases[0])
        XCTAssertTrue(runtime.keychain.save(key: "sk-anthropic", provider: "anthropic"))
        XCTAssertEqual(AICommand.defaultProvider(runtime), .anthropic)
        XCTAssertTrue(runtime.keychain.save(key: "sk-openai", provider: "openai"))
        XCTAssertEqual(AICommand.defaultProvider(runtime), .openai,
                       "declaration order decides, not the order they were saved in")
    }

    private func deviceLink() -> FakeLink {
        let link = QxFixtures.answeringLink()
        link.autoConnectOnStart = true
        return link
    }

    private func exercise(_ arguments: [String], _ link: FakeLink,
                          _ runtime: AIRuntime) async -> Int32 {
        AIRuntime.current = runtime
        defer { AIRuntime.current = AIRuntime() }
        return await QudelixCLI.run(arguments: ["--timeout", "2"] + arguments,
                                    makeLinks: { _ in [link] })
    }

    func testSuggestWithoutApplyNeverOpensTheLink() async throws {
        let link = deviceLink()
        let runtime = self.runtime(directory(), transport: scripted(), key: "sk-mistral",
                                   measurement: measurement())
        let text = try await captured {
            let code = await self.exercise(["ai", "suggest", "Sennheiser HD 650",
                                            "--", "--kind", "clarity"], link, runtime)
            XCTAssertEqual(code, CLIExit.ok)
        }
        XCTAssertTrue(text.contains("Airy 650"))
        XCTAssertFalse(link.started, "no device work, no link")
        XCTAssertTrue(link.sentCommands.isEmpty)
    }

    func testSuggestWithApplyWritesTheDraftAndOnlyAllowedCommandsReachTheLink()
        async throws {
        let link = deviceLink()
        let runtime = self.runtime(directory(), transport: scripted(), key: "sk-mistral",
                                   measurement: measurement())
        let text = try await captured {
            let code = await self.exercise(["ai", "suggest", "Sennheiser HD 650",
                                            "--", "--kind", "clarity", "--apply"],
                                           link, runtime)
            XCTAssertEqual(code, CLIExit.ok)
        }
        XCTAssertTrue(text.contains("applied to the device"))
        XCTAssertTrue(link.started)
        for command in link.sentCommands {
            XCTAssertTrue(QxSession.allowed.contains(command), "\(command)")
        }
        XCTAssertEqual(link.payloads(for: .setEqBandParam).count, 10)
        XCTAssertEqual(link.payloads(for: .setEqPreGain).count, 2)
        XCTAssertEqual(link.payload(for: .setEqType), [0, 1])
        XCTAssertEqual(link.payloads(for: .saveAll).count, 1,
                       "an applied draft is asked to survive a power cycle")
        XCTAssertEqual(link.sentCommands.last, .saveAll)
        let bandWrites = link.payloads(for: .setEqBandParam)
        XCTAssertEqual(bandWrites[0][3], QxFilter.lowShelf.rawValue)
        XCTAssertEqual(Array(bandWrites[0][4...5]), QxPacket.int16BE(31))
        XCTAssertEqual(bandWrites[9][3], QxFilter.highShelf.rawValue)
    }

    func testAFailedDesignLeavesTheDeviceAloneAndExitsOne() async throws {
        let link = deviceLink()
        let runtime = self.runtime(directory(),
                                   transport: ScriptedAITransport([
                                       chatReply(dossierText()),
                                       chatReply("no."),
                                   ]),
                                   key: "sk-mistral")
        _ = try await captured {
            let code = await self.exercise(["ai", "suggest", "HD 650",
                                            "--", "--kind", "clarity", "--apply"],
                                           link, runtime)
            XCTAssertEqual(code, CLIExit.deviceError)
        }
        XCTAssertTrue(link.payloads(for: .setEqBandParam).isEmpty)
        XCTAssertTrue(link.payloads(for: .saveAll).isEmpty)
    }

    func testAMissingKeyExitsTwoWithoutWritingAnything() async throws {
        let link = deviceLink()
        let runtime = self.runtime(directory(), transport: ScriptedAITransport())
        _ = try await captured {
            let code = await self.exercise(["ai", "suggest", "HD 650",
                                            "--", "--kind", "clarity", "--apply"],
                                           link, runtime)
            XCTAssertEqual(code, CLIExit.usageError)
        }
        XCTAssertTrue(link.payloads(for: .setEqBandParam).isEmpty)
        XCTAssertTrue(link.payloads(for: .saveAll).isEmpty)
    }

    func testAParseErrorExitsTwoBeforeAnyLinkIsMade() async {
        let link = deviceLink()
        let exit = await exercise(["ai", "suggest", "HD 650", "--", "--bands", "12"],
                                  link, AIRuntime())
        XCTAssertEqual(exit, CLIExit.usageError)
        XCTAssertFalse(link.started)
    }

    func testApplyingUsesTheBankTheDeviceIsInWhenNoBandCountIsGiven() async throws {
        let link = deviceLink()
        let runtime = self.runtime(directory(), transport: scripted(), key: "sk-mistral",
                                   measurement: measurement())
        let text = try await captured {
            let code = await self.exercise(["ai", "suggest", "Sennheiser HD 650",
                                            "--", "--kind", "clarity", "--apply"],
                                           link, runtime)
            XCTAssertEqual(code, CLIExit.ok)
        }
        XCTAssertTrue(text.contains("\(QxEqGroup.user.bandCount) bands"))
    }
}
