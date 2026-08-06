import XCTest
@testable import QudelixBar

/// The optimizer correction source: what we ask the API for, and what we do
/// with what comes back. No test here touches the network — the transport is
/// injected, and everything else under test is a pure function.
final class AutoEqServiceTests: XCTestCase {

    // MARK: - Helpers

    private func json(_ body: EqualizeRequest) throws -> [String: Any] {
        let data = try AutoEqService.encode(body)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func body(bandCount: Int,
                      rig: String? = "GRAS 45BC ",
                      options: CorrectionOptions = CorrectionOptions()) -> EqualizeRequest {
        AutoEqService.requestBody(model: "Sennheiser HD 800", source: "oratory1990",
                                  rig: rig, target: "Harman over-ear 2018",
                                  limits: .qudelix(bandCount: bandCount),
                                  options: options)
    }

    /// A response in the documented shape: shelf, peaks, shelf.
    private func fixture(filterCount: Int, preamp: Double = -6.7) -> Data {
        var filters = [#"{"type":"LOW_SHELF","fc":105.0,"q":0.7,"gain":5.526633896855957}"#]
        for i in 1..<(filterCount - 1) {
            filters.append("""
            {"type":"PEAKING","fc":\(200 * i).5,"q":\(1.0 + Double(i) / 10),"gain":\(i.isMultiple(of: 2) ? -1.25 : 3.5)}
            """)
        }
        filters.append(#"{"type":"HIGH_SHELF","fc":10000.0,"q":0.7,"gain":-6.341877424063483}"#)
        return """
        {"fr":{"frequency":[20.0,24.0]},
         "parametric_eq":{"fs":44100,"filters":[\(filters.joined(separator: ","))],
                          "preamp":\(preamp)}}
        """.data(using: .utf8)!
    }

    // MARK: - Request construction

    func testDeviceShapedConfigHasExactlyBandCountFilters() throws {
        for n in [10, 20] {
            let root = try json(body(bandCount: n))
            let config = try XCTUnwrap(root["parametric_eq_config"] as? [String: Any])
            let filters = try XCTUnwrap(config["filters"] as? [[String: Any]])
            XCTAssertEqual(filters.count, n, "asked for \(n) bands")

            // Shelf, peaks, shelf — one filter per band the device has.
            XCTAssertEqual(filters.first?["type"] as? String, "LOW_SHELF")
            XCTAssertEqual(filters.last?["type"] as? String, "HIGH_SHELF")
            XCTAssertEqual(filters.dropFirst().dropLast().count, n - 2)
            XCTAssertTrue(filters.dropFirst().dropLast()
                .allSatisfy { $0["type"] as? String == "PEAKING" })
        }
    }

    func testFilterBoundsAreTheDevicesOwn() throws {
        let root = try json(body(bandCount: 10))
        let config = try XCTUnwrap(root["parametric_eq_config"] as? [String: Any])
        let defaults = try XCTUnwrap(config["filter_defaults"] as? [String: Any])

        XCTAssertEqual(defaults["min_gain"] as? Double, -12)
        XCTAssertEqual(defaults["max_gain"] as? Double, 12)
        let maxQ = try XCTUnwrap(defaults["max_q"] as? Double)
        XCTAssertLessThanOrEqual(maxQ, 10, "device refuses Q above 10")
        XCTAssertGreaterThan(try XCTUnwrap(defaults["min_q"] as? Double), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(defaults["min_fc"] as? Double), 20)
        XCTAssertLessThanOrEqual(try XCTUnwrap(defaults["max_fc"] as? Double), 20000)

        let optimizer = try XCTUnwrap(config["optimizer"] as? [String: Any])
        XCTAssertEqual(optimizer["min_f"] as? Double, 20)
        XCTAssertEqual(optimizer["max_f"] as? Double, 20000)
        // The API answers 422 above 0.5 s.
        XCTAssertLessThanOrEqual(try XCTUnwrap(optimizer["max_time"] as? Double), 0.5)
    }

    /// Omitting `response`, or asking for no fields, makes the server fault on
    /// its own missing `fr_f_step` and return 500.
    func testResponseRequirementsAlwaysCarryFrStep() throws {
        for n in [10, 20] {
            let root = try json(body(bandCount: n))
            let response = try XCTUnwrap(root["response"] as? [String: Any])
            XCTAssertNotNil(response["fr_f_step"] as? Double)
            let fields = try XCTUnwrap(response["fr_fields"] as? [String])
            XCTAssertFalse(fields.isEmpty)
        }
    }

    /// A pinned `fc`/`q` means "put it here"; a missing one means "you choose".
    /// An explicit null is neither.
    func testPeakingSlotsOmitFcAndQEntirely() throws {
        let root = try json(body(bandCount: 10))
        let config = try XCTUnwrap(root["parametric_eq_config"] as? [String: Any])
        let filters = try XCTUnwrap(config["filters"] as? [[String: Any]])
        let peak = try XCTUnwrap(filters.dropFirst().first)
        XCTAssertNil(peak["fc"])
        XCTAssertNil(peak["q"])
        XCTAssertEqual(filters.first?["fc"] as? Double, 105)
        XCTAssertEqual(filters.first?["q"] as? Double, 0.7)
    }

    /// Two rig names in the catalogue end in a space and the server matches on
    /// the exact string, so nothing on the way out may trim it.
    func testRigWithTrailingSpaceSurvivesByteIdentical() throws {
        let rig = "GRAS 45BC "
        let root = try json(body(bandCount: 10, rig: rig))
        XCTAssertEqual(root["rig"] as? String, rig)

        let raw = String(data: try AutoEqService.encode(body(bandCount: 10, rig: rig)),
                         encoding: .utf8) ?? ""
        XCTAssertTrue(raw.contains(#""rig":"GRAS 45BC ""#), raw)
    }

    func testRigIsOmittedWhenTheCatalogueHasNone() throws {
        let root = try json(body(bandCount: 10, rig: nil))
        XCTAssertNil(root["rig"])
    }

    func testPersonalizationIsOmittedAtItsDefaults() throws {
        let plain = try json(body(bandCount: 10))
        XCTAssertNil(plain["bass_boost_gain"])
        XCTAssertNil(plain["tilt"])

        let tuned = try json(body(bandCount: 10,
                                  options: CorrectionOptions(bassBoostGain: 4, tilt: -0.5)))
        XCTAssertEqual(tuned["bass_boost_gain"] as? Double, 4)
        XCTAssertEqual(tuned["tilt"] as? Double, -0.5)
    }

    func testTwoBandDeviceStillGetsExactlyTwoFilters() {
        // Not a shipping configuration, but the shelf/peak/shelf split must not
        // underflow into a negative repeat count.
        XCTAssertEqual(AutoEqService.deviceFilters(bandCount: 2).count, 2)
        XCTAssertEqual(AutoEqService.deviceFilters(bandCount: 1).count, 1)
    }

    // MARK: - Response mapping

    func testFixtureMapsToParametricEQFile() throws {
        let limits = DeviceEQLimits.qudelix(bandCount: 10)
        let (file, warnings) = try AutoEqService.correction(from: fixture(filterCount: 10),
                                                            limits: limits)
        XCTAssertEqual(file.bands.count, 10)
        XCTAssertEqual(file.bands.first?.filter, .lowShelf)
        XCTAssertEqual(file.bands.first?.freq, 105)
        XCTAssertEqual(file.bands.last?.filter, .highShelf)
        XCTAssertEqual(file.bands.last?.freq, 10000)
        XCTAssertTrue(file.bands.dropFirst().dropLast().allSatisfy { $0.filter == .peak })
        XCTAssertEqual(file.preamp, -6.7, accuracy: 0.001)
        XCTAssertEqual(file.droppedBands, 0)
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
        // The whole point: the device would change nothing.
        XCTAssertTrue(file.bands.allSatisfy(limits.admits))
    }

    func testTwentyFilterFixtureMapsToTwentyBands() throws {
        let (file, warnings) = try AutoEqService.correction(from: fixture(filterCount: 20),
                                                            limits: .qudelix(bandCount: 20))
        XCTAssertEqual(file.bands.count, 20)
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
    }

    func testEmptyFilterSetIsReportedNotAppliedAsFlat() {
        let data = #"{"parametric_eq":{"fs":44100,"filters":[],"preamp":0}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try AutoEqService.correction(from: data,
                                                          limits: .qudelix(bandCount: 10))) {
            guard case CorrectionError.noFilters = $0 else {
                return XCTFail("expected .noFilters, got \($0)")
            }
        }
    }

    func testGarbageResponseIsADecodeFailureNotACrash() {
        for body in ["not json at all", "{}", #"{"parametric_eq":{"preamp":0}}"#] {
            XCTAssertThrowsError(
                try AutoEqService.correction(from: body.data(using: .utf8)!,
                                             limits: .qudelix(bandCount: 10))) {
                guard case CorrectionError.badResponse = $0 else {
                    return XCTFail("expected .badResponse for \(body), got \($0)")
                }
            }
        }
    }

    func testPreampBeyondTheDeviceIsSaidOutLoud() throws {
        let (file, warnings) = try AutoEqService.correction(from: fixture(filterCount: 10,
                                                                         preamp: -14.4),
                                                            limits: .qudelix(bandCount: 10))
        XCTAssertEqual(file.preamp, -14.4, accuracy: 0.001, "the honest value survives")
        XCTAssertEqual(warnings.count, 1)
        let text = try XCTUnwrap(warnings.first)
        XCTAssertTrue(text.contains("pre-gain"), text)
        XCTAssertTrue(text.contains("12"), text)
    }

    func testUnknownFilterTypeIsSkippedAndCounted() throws {
        let data = """
        {"parametric_eq":{"fs":44100,"preamp":-1.0,"filters":[
          {"type":"PEAKING","fc":1000,"q":1.0,"gain":2.0},
          {"type":"BAND_PASS","fc":2000,"q":1.0,"gain":2.0}]}}
        """.data(using: .utf8)!
        let (file, warnings) = try AutoEqService.correction(from: data,
                                                            limits: .qudelix(bandCount: 10))
        XCTAssertEqual(file.bands.count, 1)
        XCTAssertTrue(warnings.contains { $0.contains("unrecognised") }, "\(warnings)")
    }

    func testAbsurdFrequencyNeverReachesAnIntConversion() throws {
        // 1e20 decodes fine as a Double and overflows Int, which traps.
        let data = """
        {"parametric_eq":{"fs":44100,"preamp":0,"filters":[
          {"type":"PEAKING","fc":1e20,"q":1.0,"gain":2.0},
          {"type":"PEAKING","fc":1000,"q":1.0,"gain":2.0}]}}
        """.data(using: .utf8)!
        let (file, warnings) = try AutoEqService.correction(from: data,
                                                            limits: .qudelix(bandCount: 10))
        XCTAssertEqual(file.bands.count, 1)
        XCTAssertEqual(file.bands.first?.freq, 1000)
        XCTAssertFalse(warnings.isEmpty)
    }

    /// A number JSON itself can't hold takes the whole body down; that is a
    /// decode failure, not a curve with a hole in it.
    func testNumberOutsideDoubleIsADecodeFailure() {
        let data = """
        {"parametric_eq":{"fs":44100,"preamp":0,"filters":[
          {"type":"PEAKING","fc":1e400,"q":1.0,"gain":2.0}]}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try AutoEqService.correction(from: data,
                                                          limits: .qudelix(bandCount: 10))) {
            guard case CorrectionError.badResponse = $0 else {
                return XCTFail("expected .badResponse, got \($0)")
            }
        }
    }

    // MARK: - Catalogue and target choice

    func testParseEntriesKeepsRigsVerbatimAndToleratesNull() throws {
        let data = """
        {"Sennheiser HD 800":[{"form":"over-ear","rig":"GRAS 45BC ","source":"oratory1990"}],
         "Some IEM":[{"form":"in-ear","rig":null,"source":"crinacle"}]}
        """.data(using: .utf8)!
        let models = try AutoEqService.parseEntries(data)
        XCTAssertEqual(models.count, 2)
        let hd800 = try XCTUnwrap(models.first { $0.name == "Sennheiser HD 800" })
        XCTAssertEqual(hd800.measurements.first?.rig, "GRAS 45BC ")
        let iem = try XCTUnwrap(models.first { $0.name == "Some IEM" })
        XCTAssertNil(iem.measurements.first?.rig)
    }

    func testTargetsParseAndRecommendationWins() throws {
        let data = """
        [{"label":"AutoEq in-ear","recommended":[{"source":"crinacle","form":"in-ear","rig":"711"}],
          "compatible":[{"source":"oratory1990","form":"over-ear"}],
          "bassBoost":{"fc":105,"q":0.7,"gain":8}},
         {"label":"Harman over-ear 2018",
          "recommended":[{"source":"oratory1990","form":"over-ear","rig":"GRAS 45BC "}],
          "compatible":[],"bassBoost":{"fc":105,"q":0.7,"gain":6}}]
        """.data(using: .utf8)!
        let targets = try AutoEqService.parseTargets(data)
        XCTAssertEqual(targets.count, 2)

        let hd800 = AutoEqMeasurement(source: "oratory1990", form: "over-ear", rig: "GRAS 45BC ")
        XCTAssertEqual(AutoEqService.target(for: hd800, in: targets), "Harman over-ear 2018",
                       "a recommendation beats a merely compatible pairing")

        let iem = AutoEqMeasurement(source: "crinacle", form: "in-ear", rig: "711")
        XCTAssertEqual(AutoEqService.target(for: iem, in: targets), "AutoEq in-ear")

        // A rig nobody has published a recommendation for falls back on form.
        let unknown = AutoEqMeasurement(source: "nobody", form: "in-ear", rig: nil)
        XCTAssertEqual(AutoEqService.target(for: unknown, in: targets), "Harman in-ear 2019")
    }

    /// The trimmed spelling is a different rig as far as the server is
    /// concerned, so it must not silently match a recommendation either.
    func testTargetMatchingIsRigExact() throws {
        let targets = [AutoEqTarget(
            label: "Harman over-ear 2018",
            recommended: [AutoEqMeasurement(source: "oratory1990", form: "over-ear",
                                            rig: "GRAS 45BC ")],
            compatible: [])]
        let trimmed = AutoEqMeasurement(source: "oratory1990", form: "over-ear", rig: "GRAS 45BC")
        XCTAssertEqual(AutoEqService.target(for: trimmed, in: targets), "Harman over-ear 2018",
                       "form fallback still lands here, but not via the recommendation")

        let mismatch = AutoEqTarget(
            label: "Something else",
            recommended: [AutoEqMeasurement(source: "oratory1990", form: "over-ear",
                                            rig: "GRAS 45BC ")],
            compatible: [])
        XCTAssertEqual(AutoEqService.target(for: trimmed, in: [mismatch]),
                       "Harman over-ear 2018")
    }

    func testRankingPutsPrefixMatchesFirst() {
        let names = ["Sennheiser HD 600", "HD 650", "Beyerdynamic DT 990", "HD 6XX"]
        let ranked = rankByTitle(names, query: "hd 6") { $0 }
        XCTAssertEqual(ranked.prefix(2).sorted(), ["HD 650", "HD 6XX"])
        XCTAssertEqual(ranked.count, 3)
        XCTAssertTrue(rankByTitle(names, query: "   ") { $0 }.isEmpty)
    }

    func testCandidateDetailTrimsForDisplayOnly() {
        let c = CorrectionCandidate(title: "Sennheiser HD 800", source: "oratory1990",
                                    form: "over-ear", rig: "GRAS 45BC ", token: "")
        XCTAssertEqual(c.detail, "oratory1990 · GRAS 45BC")
        XCTAssertEqual(c.rig, "GRAS 45BC ")
    }

    // MARK: - Through an injected transport

    @MainActor
    func testEqualizePostsADeviceShapedBodyAndDecodesIt() async throws {
        let stub = StubTransport()
        stub.enqueue(.success(fixture(filterCount: 20)))
        let service = AutoEqService(transport: stub)

        let file = try await service.equalize(model: "Sennheiser HD 800",
                                              source: "oratory1990", rig: "GRAS 45BC ",
                                              target: "Harman over-ear 2018",
                                              bandCount: 20, bassBoostGain: 0, tilt: 0)
        XCTAssertEqual(file.bands.count, 20)

        let sent = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.absoluteString, "https://autoeq.app/equalize")
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(sent.httpBody)) as? [String: Any])
        XCTAssertEqual(root["rig"] as? String, "GRAS 45BC ")
        let config = try XCTUnwrap(root["parametric_eq_config"] as? [String: Any])
        XCTAssertEqual((config["filters"] as? [[String: Any]])?.count, 20)
    }

    @MainActor
    func testServerFaultBecomesAnActionableMessage() async {
        let stub = StubTransport()
        stub.enqueue(.failure(HTTPStatusError(
            status: 500,
            body: #"{"detail":"Unknown rig GRAS 45BC for source oratory1990"}"#)))
        let service = AutoEqService(transport: stub)

        do {
            _ = try await service.equalize(model: "X", source: "oratory1990", rig: "GRAS 45BC",
                                           target: "Harman over-ear 2018",
                                           bandCount: 10, bassBoostGain: 0, tilt: 0)
            XCTFail("expected a server error")
        } catch {
            let text = AutoEqService.describe(error)
            XCTAssertTrue(text.contains("500"), text)
            XCTAssertTrue(text.contains("Unknown rig"), text)
        }
    }

    @MainActor
    func testOfflineIsDistinguishedFromAServerFault() async {
        let stub = StubTransport()
        stub.enqueue(.failure(URLError(.notConnectedToInternet)))
        let service = AutoEqService(transport: stub)
        do {
            _ = try await service.equalize(model: "X", source: "s", rig: nil, target: "t",
                                           bandCount: 10, bassBoostGain: 0, tilt: 0)
            XCTFail("expected an offline error")
        } catch {
            guard case CorrectionError.offline = error else {
                return XCTFail("expected .offline, got \(error)")
            }
        }
    }

    @MainActor
    func testTransientFailureFallsBackToTheLastGoodCorrection() async throws {
        let stub = StubTransport()
        stub.enqueue(.success(fixture(filterCount: 10)))
        stub.enqueue(.failure(URLError(.timedOut)))
        let service = AutoEqService(transport: stub)

        let candidate = CorrectionCandidate(title: "Sennheiser HD 800", source: "oratory1990",
                                            form: "over-ear", rig: "GRAS 45BC ", token: "")
        // An explicit target keeps the catalogue and target fetches out of it.
        let options = CorrectionOptions(target: "Harman over-ear 2018")
        let limits = DeviceEQLimits.qudelix(bandCount: 10)

        let first = try await service.correction(for: candidate, shapedFor: limits,
                                                 options: options)
        XCTAssertTrue(first.warnings.isEmpty)
        XCTAssertTrue(first.provenance.contains("Harman over-ear 2018"))
        XCTAssertTrue(first.provenance.contains("10 bands"))

        let second = try await service.correction(for: candidate, shapedFor: limits,
                                                  options: options)
        XCTAssertEqual(second.file.bands, first.file.bands)
        XCTAssertTrue(second.warnings.contains { $0.contains("reused the last correction") },
                      "\(second.warnings)")
    }

    @MainActor
    func testFallbackIsPerRequestShapeNotGlobal() async throws {
        let stub = StubTransport()
        stub.enqueue(.success(fixture(filterCount: 10)))
        stub.enqueue(.failure(URLError(.timedOut)))
        let service = AutoEqService(transport: stub)
        let candidate = CorrectionCandidate(title: "HD 800", source: "oratory1990",
                                            form: "over-ear", rig: "GRAS 45BC ", token: "")

        _ = try await service.correction(for: candidate,
                                         shapedFor: .qudelix(bandCount: 10),
                                         options: CorrectionOptions(target: "Harman over-ear 2018"))
        // A different band count is a different curve; the 10-band cache must
        // not be served as if it were a 20-band fit.
        do {
            _ = try await service.correction(for: candidate,
                                             shapedFor: .qudelix(bandCount: 20),
                                             options: CorrectionOptions(target: "Harman over-ear 2018"))
            XCTFail("expected the failure to surface")
        } catch {
            guard case CorrectionError.offline = error else {
                return XCTFail("expected .offline, got \(error)")
            }
        }
    }
}

/// Hands back queued responses in order and records what was asked for.
private final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Result<Data, Error>] = []
    private var sent: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { sent } }

    func enqueue(_ result: Result<Data, Error>) {
        lock.withLock { queued.append(result) }
    }

    func send(_ request: URLRequest, limit: Int) async throws -> Data {
        let next: Result<Data, Error>? = lock.withLock {
            sent.append(request)
            return queued.isEmpty ? nil : queued.removeFirst()
        }
        guard let next else { throw URLError(.resourceUnavailable) }
        return try next.get()
    }
}
