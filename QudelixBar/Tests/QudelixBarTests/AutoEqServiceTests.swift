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

    /// Two request bodies compared as JSON rather than as bytes: `JSONEncoder`
    /// does not promise a stable key order between calls, and it is the request
    /// that has to be identical, not the byte stream carrying it.
    private func assertSameRequest(_ a: EqualizeRequest, _ b: EqualizeRequest,
                                   _ why: String,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) throws {
        XCTAssertEqual(try json(a) as NSDictionary, try json(b) as NSDictionary, why,
                       file: file, line: line)
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

    // MARK: - Frequency ceiling

    /// The ceiling is a request parameter: the optimizer fits inside it and
    /// returns filters that already stop there. Nothing edits the response.
    func testCeilingConstrainsTheOptimizerRequest() throws {
        let root = try json(body(bandCount: 10,
                                 options: CorrectionOptions(maxCorrectionHz: 12000)))
        let config = try XCTUnwrap(root["parametric_eq_config"] as? [String: Any])
        XCTAssertEqual((config["optimizer"] as? [String: Any])?["max_f"] as? Double, 12000)
        XCTAssertEqual((config["filter_defaults"] as? [String: Any])?["max_fc"] as? Double, 12000)

        // The pinned treble shelf has to stay inside the bound the same request
        // declares, so it comes down with it.
        let filters = try XCTUnwrap(config["filters"] as? [[String: Any]])
        XCTAssertEqual(filters.last?["type"] as? String, "HIGH_SHELF")
        XCTAssertEqual(filters.last?["fc"] as? Double, 10000, "10 kHz is already under 12 kHz")

        let low = try json(body(bandCount: 10,
                                options: CorrectionOptions(maxCorrectionHz: 9000)))
        let lowFilters = try XCTUnwrap(
            (low["parametric_eq_config"] as? [String: Any])?["filters"] as? [[String: Any]])
        XCTAssertEqual(lowFilters.last?["fc"] as? Double, 9000)
    }

    /// Everything that isn't a real ceiling must leave the request exactly as
    /// it has always been sent.
    func testRequestWithoutACeilingIsUnchanged() throws {
        let root = try json(body(bandCount: 10))
        let config = try XCTUnwrap(root["parametric_eq_config"] as? [String: Any])
        XCTAssertEqual((config["optimizer"] as? [String: Any])?["max_f"] as? Double, 20000)
        XCTAssertEqual((config["filter_defaults"] as? [String: Any])?["max_fc"] as? Double, 16000)
        let filters = try XCTUnwrap(config["filters"] as? [[String: Any]])
        XCTAssertEqual(filters.last?["fc"] as? Double, 10000)

        for absent: Double? in [nil, .nan, .infinity, -.infinity] {
            try assertSameRequest(body(bandCount: 10,
                                       options: CorrectionOptions(maxCorrectionHz: absent)),
                                  body(bandCount: 10),
                                  "\(String(describing: absent)) is not a ceiling")
        }
    }

    func testCeilingIsClampedIntoSomethingSendable() {
        let limits = DeviceEQLimits.qudelix(bandCount: 10)
        func ceiling(_ hz: Double?) -> Double? {
            CorrectionOptions(maxCorrectionHz: hz).correctionCeiling(for: limits)
        }
        XCTAssertEqual(ceiling(16400), 16400)
        // Never above what the device can even address.
        XCTAssertEqual(ceiling(25000), limits.maxFc)
        XCTAssertEqual(ceiling(.greatestFiniteMagnitude), limits.maxFc)
        // A wild verdict must not produce a nonsense request.
        XCTAssertEqual(ceiling(500), CorrectionOptions.minCorrectionHz)
        XCTAssertEqual(ceiling(0), CorrectionOptions.minCorrectionHz)
        XCTAssertEqual(ceiling(-1000), CorrectionOptions.minCorrectionHz)
        // Non-finite has no intention behind it to honour.
        XCTAssertNil(ceiling(.nan))
        XCTAssertNil(ceiling(.infinity))
        XCTAssertNil(ceiling(nil))
    }

    /// A ceiling above the device's own top is the same request as no ceiling —
    /// not a licence to raise any other bound.
    func testCeilingAboveTheDeviceMaxSendsTheUnrestrictedRequest() throws {
        try assertSameRequest(body(bandCount: 10,
                                   options: CorrectionOptions(maxCorrectionHz: 48000)),
                              body(bandCount: 10),
                              "clamped to the device's own 20 kHz")
    }

    func testAbsurdlyLowCeilingLandsOnTheFloor() throws {
        let root = try json(body(bandCount: 10,
                                 options: CorrectionOptions(maxCorrectionHz: 200)))
        let config = try XCTUnwrap(root["parametric_eq_config"] as? [String: Any])
        XCTAssertEqual((config["optimizer"] as? [String: Any])?["max_f"] as? Double,
                       CorrectionOptions.minCorrectionHz)
        XCTAssertEqual((config["filter_defaults"] as? [String: Any])?["max_fc"] as? Double,
                       CorrectionOptions.minCorrectionHz)
        // The fit still starts where it always did.
        XCTAssertEqual((config["optimizer"] as? [String: Any])?["min_f"] as? Double, 20)
    }

    /// Two curves fitted to different ceilings are different curves, so the
    /// stale-fallback cache must not hand one back for the other.
    @MainActor
    func testCeilingedRequestDoesNotReuseAnUnrestrictedFit() async throws {
        let stub = StubTransport()
        stub.enqueue(.success(fixture(filterCount: 10)))
        stub.enqueue(.failure(URLError(.timedOut)))
        let service = AutoEqService(transport: stub)
        let candidate = CorrectionCandidate(title: "HD 800", source: "oratory1990",
                                            form: "over-ear", rig: "GRAS 45BC ", token: "")
        let limits = DeviceEQLimits.qudelix(bandCount: 10)

        _ = try await service.correction(
            for: candidate, shapedFor: limits,
            options: CorrectionOptions(target: "Harman over-ear 2018"))
        do {
            _ = try await service.correction(
                for: candidate, shapedFor: limits,
                options: CorrectionOptions(target: "Harman over-ear 2018",
                                           maxCorrectionHz: 16400))
            XCTFail("expected the failure to surface")
        } catch {
            guard case CorrectionError.offline = error else {
                return XCTFail("expected .offline, got \(error)")
            }
        }
    }

    /// A curve that stops at 16 kHz must never look like a mystery later.
    @MainActor
    func testAppliedCeilingIsNamedInTheProvenance() async throws {
        let stub = StubTransport()
        stub.enqueue(.success(fixture(filterCount: 10)))
        let service = AutoEqService(transport: stub)
        let candidate = CorrectionCandidate(title: "HD 800", source: "oratory1990",
                                            form: "over-ear", rig: "GRAS 45BC ", token: "")
        let result = try await service.correction(
            for: candidate, shapedFor: .qudelix(bandCount: 10),
            options: CorrectionOptions(target: "Harman over-ear 2018",
                                       maxCorrectionHz: 16400))
        XCTAssertTrue(result.provenance.contains("16.4 kHz"), result.provenance)

        stub.enqueue(.success(fixture(filterCount: 10)))
        let plain = try await service.correction(
            for: candidate, shapedFor: .qudelix(bandCount: 10),
            options: CorrectionOptions(target: "Harman over-ear 2018"))
        XCTAssertFalse(plain.provenance.contains("kHz"), plain.provenance)
    }

    /// A target the user picked is a deliberate choice and is said out loud,
    /// same as the ceiling; the measurement's own recommendation is not
    /// treated as news.
    @MainActor
    func testChosenTargetIsNamedInTheProvenanceAndTheDefaultIsNot() async throws {
        let stub = StubTransport()
        stub.enqueue(.success(fixture(filterCount: 10)))
        let service = AutoEqService(transport: stub)
        let candidate = CorrectionCandidate(title: "HD 800", source: "oratory1990",
                                            form: "over-ear", rig: "GRAS 45BC ", token: "")

        let chosen = try await service.correction(
            for: candidate, shapedFor: .qudelix(bandCount: 10),
            options: CorrectionOptions(target: "AutoEq in-ear"))
        XCTAssertTrue(chosen.provenance.contains("your choice"), chosen.provenance)

        stub.enqueue(.success(fixture(filterCount: 10)))
        service.seedForPreview([], targets: [
            AutoEqTarget(label: "Harman over-ear 2018",
                        recommended: [AutoEqMeasurement(source: "oratory1990", form: "over-ear",
                                                        rig: "GRAS 45BC ")],
                        compatible: [])
        ])
        let byDefault = try await service.correction(
            for: candidate, shapedFor: .qudelix(bandCount: 10), options: CorrectionOptions())
        XCTAssertFalse(byDefault.provenance.contains("your choice"), byDefault.provenance)
        XCTAssertTrue(byDefault.provenance.contains("Harman over-ear 2018"), byDefault.provenance)
    }

    /// Bass and tilt are named only when they actually moved the curve —
    /// otherwise the provenance would claim a personalization that never
    /// happened.
    @MainActor
    func testPersonalizationIsNamedInTheProvenanceOnlyWhenNonZero() async throws {
        let stub = StubTransport()
        stub.enqueue(.success(fixture(filterCount: 10)))
        let service = AutoEqService(transport: stub)
        let candidate = CorrectionCandidate(title: "HD 800", source: "oratory1990",
                                            form: "over-ear", rig: "GRAS 45BC ", token: "")

        let tuned = try await service.correction(
            for: candidate, shapedFor: .qudelix(bandCount: 10),
            options: CorrectionOptions(bassBoostGain: 3, tilt: -0.2,
                                       target: "Harman over-ear 2018"))
        XCTAssertTrue(tuned.provenance.contains("+3.0 dB bass"), tuned.provenance)
        XCTAssertTrue(tuned.provenance.contains("-0.20 dB/oct tilt"), tuned.provenance)

        stub.enqueue(.success(fixture(filterCount: 10)))
        let plain = try await service.correction(
            for: candidate, shapedFor: .qudelix(bandCount: 10),
            options: CorrectionOptions(target: "Harman over-ear 2018"))
        XCTAssertFalse(plain.provenance.contains("bass"), plain.provenance)
        XCTAssertFalse(plain.provenance.contains("tilt"), plain.provenance)
    }

    /// A different target is a different curve. Serving the first request's
    /// cached fallback for the second would hand back a fit for a target the
    /// caller never asked for.
    @MainActor
    func testCacheDoesNotCrossTargets() async throws {
        let stub = StubTransport()
        stub.enqueue(.success(fixture(filterCount: 10)))
        stub.enqueue(.failure(URLError(.timedOut)))
        let service = AutoEqService(transport: stub)
        let candidate = CorrectionCandidate(title: "HD 800", source: "oratory1990",
                                            form: "over-ear", rig: "GRAS 45BC ", token: "")
        let limits = DeviceEQLimits.qudelix(bandCount: 10)

        _ = try await service.correction(
            for: candidate, shapedFor: limits,
            options: CorrectionOptions(target: "Harman over-ear 2018"))
        do {
            _ = try await service.correction(
                for: candidate, shapedFor: limits,
                options: CorrectionOptions(target: "AutoEq in-ear"))
            XCTFail("expected the failure to surface rather than a fit for the other target")
        } catch {
            guard case CorrectionError.offline = error else {
                return XCTFail("expected .offline, got \(error)")
            }
        }
    }

    /// Bass and tilt are already part of the cache key; a personalized fit
    /// must not be handed back for a request that asked for none.
    @MainActor
    func testCacheDoesNotCrossPersonalization() async throws {
        let stub = StubTransport()
        stub.enqueue(.success(fixture(filterCount: 10)))
        stub.enqueue(.failure(URLError(.timedOut)))
        let service = AutoEqService(transport: stub)
        let candidate = CorrectionCandidate(title: "HD 800", source: "oratory1990",
                                            form: "over-ear", rig: "GRAS 45BC ", token: "")
        let limits = DeviceEQLimits.qudelix(bandCount: 10)

        _ = try await service.correction(
            for: candidate, shapedFor: limits,
            options: CorrectionOptions(target: "Harman over-ear 2018"))
        do {
            _ = try await service.correction(
                for: candidate, shapedFor: limits,
                options: CorrectionOptions(bassBoostGain: 3, tilt: -0.2,
                                           target: "Harman over-ear 2018"))
            XCTFail("expected the failure to surface rather than the flat fit")
        } catch {
            guard case CorrectionError.offline = error else {
                return XCTFail("expected .offline, got \(error)")
            }
        }
    }

    /// A target picked in the UI has to reach the wire, not just the
    /// provenance line — this is what the server actually fits against.
    @MainActor
    func testChosenTargetReachesTheEqualizeRequest() async throws {
        let stub = StubTransport()
        stub.enqueue(.success(fixture(filterCount: 10)))
        let service = AutoEqService(transport: stub)
        let candidate = CorrectionCandidate(title: "HD 800", source: "oratory1990",
                                            form: "over-ear", rig: "GRAS 45BC ", token: "")

        // Seeded with a target that would recommend something else, so a
        // pass here can only be explained by the explicit choice winning.
        service.seedForPreview([], targets: [
            AutoEqTarget(label: "Harman over-ear 2018",
                        recommended: [AutoEqMeasurement(source: "oratory1990", form: "over-ear",
                                                        rig: "GRAS 45BC ")],
                        compatible: [])
        ])
        _ = try await service.correction(
            for: candidate, shapedFor: .qudelix(bandCount: 10),
            options: CorrectionOptions(target: "AutoEq in-ear"))

        let sent = try XCTUnwrap(stub.requests.first)
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(sent.httpBody)) as? [String: Any])
        XCTAssertEqual(root["target"] as? String, "AutoEq in-ear")
    }

    /// Leaving the picker on its default must resolve exactly as it always
    /// has: the measurement's own recommendation, fetched from the service's
    /// own target list rather than a hardcoded guess.
    @MainActor
    func testDefaultTargetStillResolvesToTheMeasurementsRecommendation() async throws {
        let stub = StubTransport()
        stub.enqueue(.success(fixture(filterCount: 10)))
        let service = AutoEqService(transport: stub)
        let candidate = CorrectionCandidate(title: "HD 800", source: "oratory1990",
                                            form: "over-ear", rig: "GRAS 45BC ", token: "")
        service.seedForPreview([], targets: [
            AutoEqTarget(label: "Harman over-ear 2018",
                        recommended: [AutoEqMeasurement(source: "oratory1990", form: "over-ear",
                                                        rig: "GRAS 45BC ")],
                        compatible: [])
        ])

        _ = try await service.correction(for: candidate, shapedFor: .qudelix(bandCount: 10),
                                         options: CorrectionOptions())

        let sent = try XCTUnwrap(stub.requests.first)
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(sent.httpBody)) as? [String: Any])
        XCTAssertEqual(root["target"] as? String, "Harman over-ear 2018")
    }

    /// The published-preset path can't honour a ceiling — the fit happened at
    /// publication time — so it has to say so rather than drop it silently.
    /// The wording is checked without a download; `correction(for:…)` appends
    /// exactly this string.
    func testPublishedPresetReportsAnUnhonouredCeiling() throws {
        let limits = DeviceEQLimits.qudelix(bandCount: 10)
        let warning = try XCTUnwrap(AutoEqIndex.ceilingWarning(
            for: CorrectionOptions(maxCorrectionHz: 16400), limits: limits))
        XCTAssertTrue(warning.contains("16.4 kHz"), warning)
        XCTAssertTrue(warning.contains("not applied"), warning)

        XCTAssertNil(AutoEqIndex.ceilingWarning(for: CorrectionOptions(), limits: limits))
        XCTAssertNil(AutoEqIndex.ceilingWarning(
            for: CorrectionOptions(maxCorrectionHz: .nan), limits: limits))
        // Reported as what was actually sent, not as what was asked for.
        let clamped = try XCTUnwrap(AutoEqIndex.ceilingWarning(
            for: CorrectionOptions(maxCorrectionHz: 100), limits: limits))
        XCTAssertTrue(clamped.contains("8.0 kHz"), clamped)
    }

    /// The published-preset path can't honour a target choice either — the
    /// file was fitted to one target at publication time — so it has to say
    /// so exactly as it does for an unhonoured ceiling.
    func testUnhonouredTargetWarningNamesTheTargetAndOnlyFiresWhenOneWasChosen() throws {
        XCTAssertNil(AutoEqService.unhonouredTargetWarning(for: CorrectionOptions()),
                     "the recommended default needs no warning")

        let warning = try XCTUnwrap(AutoEqService.unhonouredTargetWarning(
            for: CorrectionOptions(target: "AutoEq in-ear")))
        XCTAssertTrue(warning.contains("AutoEq in-ear"), warning)
        XCTAssertTrue(warning.contains("not applied"), warning)
    }

    /// The published path can't layer bass or tilt on either — the fit is over
    /// by the time the file is downloaded — so the two sliders are reported
    /// exactly the way an unhonoured ceiling or target is. They are hidden in
    /// that mode but keep their values across the switch into it, which is how
    /// a request carrying shaping nobody can see gets made.
    func testUnhonouredPersonalizationNamesBothBoostsAndOnlyFiresWhenSet() throws {
        XCTAssertNil(AutoEqService.unhonouredPersonalizationWarning(for: CorrectionOptions()),
                     "the target as published needs no warning")

        let bass = try XCTUnwrap(AutoEqService.unhonouredPersonalizationWarning(
            for: CorrectionOptions(bassBoostGain: 3)))
        XCTAssertTrue(bass.contains("+3.0 dB bass"), bass)
        XCTAssertTrue(bass.contains("was not applied"), bass)
        XCTAssertFalse(bass.contains("tilt"), bass)

        let tilt = try XCTUnwrap(AutoEqService.unhonouredPersonalizationWarning(
            for: CorrectionOptions(tilt: -0.25)))
        XCTAssertTrue(tilt.contains("-0.25 dB/oct tilt"), tilt)
        XCTAssertTrue(tilt.contains("was not applied"), tilt)
        XCTAssertFalse(tilt.contains("bass"), tilt)

        let both = try XCTUnwrap(AutoEqService.unhonouredPersonalizationWarning(
            for: CorrectionOptions(bassBoostGain: 3, tilt: -0.25)))
        XCTAssertTrue(both.contains("+3.0 dB bass and -0.25 dB/oct tilt"), both)
        XCTAssertTrue(both.contains("were not applied"), both)
    }

    func testCeilingIsSpelledWithOneDecimal() {
        XCTAssertEqual(CorrectionOptions.describeCeiling(16400), "16.4 kHz")
        XCTAssertEqual(CorrectionOptions.describeCeiling(16000), "16.0 kHz")
        XCTAssertEqual(CorrectionOptions.describeCeiling(19_512.7), "19.5 kHz")
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
        let (file, warnings, _) = try AutoEqService.correction(from: fixture(filterCount: 10),
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
        let (file, warnings, _) = try AutoEqService.correction(from: fixture(filterCount: 20),
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
        let (file, warnings, _) = try AutoEqService.correction(from: fixture(filterCount: 10,
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
        let (file, warnings, _) = try AutoEqService.correction(from: data,
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
        let (file, warnings, _) = try AutoEqService.correction(from: data,
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

    func testFarMoreFiltersThanTheModeHoldsAreCappedAndCounted() throws {
        let limits = DeviceEQLimits.qudelix(bandCount: 10)
        let (file, warnings, _) = try AutoEqService.correction(from: fixture(filterCount: 400),
                                                               limits: limits)
        XCTAssertEqual(file.bands.count, 10)
        XCTAssertTrue(warnings.contains { $0.contains("390 filter(s) beyond the 10-band mode") },
                      "\(warnings)")
    }

    func testAResponseInsideTheModeIsNotReportedAsDropped() throws {
        let limits = DeviceEQLimits.qudelix(bandCount: 20)
        let (file, warnings, _) = try AutoEqService.correction(from: fixture(filterCount: 20),
                                                               limits: limits)
        XCTAssertEqual(file.bands.count, 20)
        XCTAssertFalse(warnings.contains { $0.contains("beyond the") }, "\(warnings)")
    }

    func testServerDetailIsSanitizedBeforeItIsShown() {
        let body = #"{"detail":"bad rig\nQudelixBar: everything is fine‮"}"#
        let detail = try? XCTUnwrap(AutoEqService.detail(from: body, status: 422))
        XCTAssertEqual(detail, "bad rigQudelixBar: everything is fine")
    }

    func testDetailIsCappedRatherThanShownWhole() throws {
        let body = "{\"detail\":\"\(String(repeating: "A", count: 4000))\"}"
        let detail = try XCTUnwrap(AutoEqService.detail(from: body, status: 500))
        XCTAssertLessThanOrEqual(detail.count, SafeText.defaultLimit + 1)
    }

    func testANonJsonBodyBecomesTheStatusCodeAndNothingElse() {
        for body in ["<html><body>502 Bad Gateway</body></html>", "", "not json at all"] {
            XCTAssertEqual(AutoEqService.detail(from: body, status: 502),
                           "the service answered 502", "for \(body.prefix(20))")
        }
    }

    func testCatalogueStringsCarryingTheKeySeparatorAreRefused() throws {
        let data = #"""
        {"Good":[{"form":"over-ear","rig":"GRAS 45BC ","source":"oratory1990"}],
         "Bad\u0001Name":[{"form":"over-ear","rig":"r","source":"s"}],
         "Bad Rig":[{"form":"over-ear","rig":"r\u0001x","source":"s"}],
         "Bad Source":[{"form":"over-ear","rig":"r","source":"s\u0001x"}]}
        """#.data(using: .utf8)!
        let models = try AutoEqService.parseEntries(data)
        XCTAssertEqual(models.map(\.name), ["Good"])
    }

    func testCatalogueStringsAreLengthCapped() throws {
        let long = String(repeating: "A", count: AutoEqService.maxCatalogueStringLength + 1)
        let data = """
        {"\(long)":[{"form":"over-ear","rig":"r","source":"s"}],
         "Keep":[{"form":"over-ear","rig":"\(long)","source":"s"},
                 {"form":"over-ear","rig":"r","source":"s"}]}
        """.data(using: .utf8)!
        let models = try AutoEqService.parseEntries(data)
        XCTAssertEqual(models.map(\.name), ["Keep"])
        XCTAssertEqual(models.first?.measurements.map(\.rig), ["r"])
    }

    func testAModelLeftWithNoUsableMeasurementIsDropped() throws {
        let data = """
        {"Ghost":[{"form":"over-ear","rig":"r","source":""}]}
        """.data(using: .utf8)!
        XCTAssertTrue(try AutoEqService.parseEntries(data).isEmpty)
    }

    func testCatalogueOrderingIsStableAcrossCaseTies() throws {
        let data = """
        {"hd 650":[{"form":"over-ear","rig":"r","source":"s"}],
         "HD 650":[{"form":"over-ear","rig":"r","source":"s"}],
         "HD 600":[{"form":"over-ear","rig":"r","source":"s"}]}
        """.data(using: .utf8)!
        let first = try AutoEqService.parseEntries(data).map(\.name)
        for _ in 0..<20 {
            XCTAssertEqual(try AutoEqService.parseEntries(data).map(\.name), first)
        }
        XCTAssertEqual(first.first, "HD 600")
    }

    func testDuplicateTargetLabelsAreCollapsed() throws {
        let data = """
        [{"label":"Harman over-ear 2018","recommended":[],"compatible":[]},
         {"label":"Harman over-ear 2018","recommended":[],"compatible":[]},
         {"label":"","recommended":[],"compatible":[]}]
        """.data(using: .utf8)!
        XCTAssertEqual(try AutoEqService.parseTargets(data).map(\.label),
                       ["Harman over-ear 2018"])
    }

    func testAPublishedPresetPathCannotEscapeTheResultsRoot() {
        for path in ["../../etc/passwd", "oratory1990/%2e%2e/%2e%2e/secret",
                     "/absolute/path", "oratory1990/x?a=b", "oratory1990/x#frag"] {
            let entry = AutoEqEntry(title: "t", source: "s", path: path)
            XCTAssertNil(entry.presetURL, "accepted \(path)")
        }
    }

    func testAnOrdinaryPublishedPresetPathStillResolves() throws {
        let entry = AutoEqEntry(title: "Sennheiser HD 650", source: "oratory1990",
                                path: "oratory1990/over-ear/Sennheiser%20HD%20650")
        let url = try XCTUnwrap(entry.presetURL)
        XCTAssertTrue(url.absoluteString.hasPrefix(AutoEqIndex.root + "/"), url.absoluteString)
        XCTAssertTrue(url.absoluteString.hasSuffix("Sennheiser%20HD%20650%20ParametricEQ.txt"))
    }

    @MainActor
    func testIndexEntriesWithAbsurdTitlesOrPathsAreSkipped() {
        let long = String(repeating: "A", count: 500)
        let markdown = """
        - [Sennheiser HD 650](./oratory1990/over-ear/Sennheiser%20HD%20650)
        - [\(long)](./oratory1990/over-ear/x)
        - [Fine](./oratory1990/over-ear/\(long))
        """
        XCTAssertEqual(AutoEqIndex.parseIndex(markdown).map(\.title), ["Sennheiser HD 650"])
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

    /// Over-ear and in-ear targets are fitted for different acoustics, so the
    /// grouping is what makes the picker legible to someone who can't tell
    /// the labels apart on sight.
    func testTargetFormIsReadOffItsOwnMeasurementsNotInvented() {
        let overEar = AutoEqTarget(label: "Harman over-ear 2018",
                                   recommended: [AutoEqMeasurement(source: "oratory1990",
                                                                   form: "over-ear", rig: nil)],
                                   compatible: [])
        XCTAssertEqual(overEar.form, "over-ear")

        let mixed = AutoEqTarget(
            label: "AutoEq generic",
            recommended: [AutoEqMeasurement(source: "a", form: "over-ear", rig: nil)],
            compatible: [AutoEqMeasurement(source: "b", form: "in-ear", rig: nil)])
        XCTAssertNil(mixed.form, "endorsing both forms picks neither")

        let unknown = AutoEqTarget(label: "Mystery",
                                   recommended: [AutoEqMeasurement(source: "a", form: nil, rig: nil)],
                                   compatible: [])
        XCTAssertNil(unknown.form, "the catalogue doesn't say, so nothing is guessed")
    }

    func testGroupedTargetsSortsByFormAndKeepsTheUnknownsTogether() {
        let overEar = AutoEqTarget(label: "Harman over-ear 2018",
                                   recommended: [AutoEqMeasurement(source: "a", form: "over-ear", rig: nil)],
                                   compatible: [])
        let inEar = AutoEqTarget(label: "Harman in-ear 2019",
                                 recommended: [AutoEqMeasurement(source: "b", form: "in-ear", rig: nil)],
                                 compatible: [])
        let unknown = AutoEqTarget(label: "Mystery target", recommended: [], compatible: [])

        let groups = AutoEqService.groupedTargets([unknown, inEar, overEar])
        XCTAssertEqual(groups.map(\.form), ["over-ear", "in-ear", nil])
        XCTAssertEqual(groups.first?.targets.map(\.label), ["Harman over-ear 2018"])
        XCTAssertEqual(groups.last?.targets.map(\.label), ["Mystery target"])
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

    // MARK: - The fallback cache

    private func marked(_ preamp: Double) -> ParametricEQFile {
        var file = ParametricEQFile()
        file.preamp = preamp
        return file
    }

    /// Two of the things in a cache key are continuous sliders, so distinct
    /// shapes arrive faster than anyone would guess and the cache has to be
    /// able to forget.
    func testCacheStopsAtItsCapacityAndDropsTheOldest() {
        var cache = LastGoodCorrections()
        let overflow = 5
        for i in 0..<(LastGoodCorrections.capacity + overflow) {
            cache.store(marked(Double(i)), for: "key\(i)")
        }
        XCTAssertEqual(cache.count, LastGoodCorrections.capacity)
        for i in 0..<overflow {
            XCTAssertNil(cache.value(for: "key\(i)"), "key\(i) should be gone")
        }
        let newest = LastGoodCorrections.capacity + overflow - 1
        XCTAssertEqual(cache.value(for: "key\(newest)")?.preamp, Double(newest))
    }

    /// Least recently *used*, not oldest: the shape someone keeps coming back
    /// to is the one a dropped connection would hurt.
    func testUsingAnEntryKeepsItFromBeingEvicted() {
        var cache = LastGoodCorrections()
        for i in 0..<LastGoodCorrections.capacity {
            cache.store(marked(Double(i)), for: "key\(i)")
        }
        XCTAssertNotNil(cache.value(for: "key0"))
        cache.store(marked(-1), for: "newcomer")

        XCTAssertNil(cache.value(for: "key1"), "the oldest untouched entry is the one to go")
        XCTAssertEqual(cache.value(for: "key0")?.preamp, 0, "reading key0 renewed it")
        XCTAssertEqual(cache.count, LastGoodCorrections.capacity)
    }

    /// Re-fitting the same shape replaces its entry rather than adding one.
    func testStoringTheSameShapeTwiceDoesNotAccumulate() {
        var cache = LastGoodCorrections()
        cache.store(marked(1), for: "same")
        cache.store(marked(2), for: "same")
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.value(for: "same")?.preamp, 2)
    }

    /// The service holds that same bounded cache, so a fit far enough back is
    /// gone and its failure surfaces instead of a curve from another shape.
    @MainActor
    func testTheServiceForgetsFitsBeyondTheCap() async throws {
        let stub = StubTransport()
        let service = AutoEqService(transport: stub)
        let candidate = CorrectionCandidate(title: "HD 800", source: "oratory1990",
                                            form: "over-ear", rig: "GRAS 45BC ", token: "")
        let limits = DeviceEQLimits.qudelix(bandCount: 10)
        func options(bass: Double) -> CorrectionOptions {
            CorrectionOptions(bassBoostGain: bass, target: "Harman over-ear 2018")
        }

        // One request shape per slider position, which is exactly how the
        // collection used to grow without end.
        for i in 0...LastGoodCorrections.capacity {
            stub.enqueue(.success(fixture(filterCount: 10)))
            _ = try await service.correction(for: candidate, shapedFor: limits,
                                             options: options(bass: Double(i)))
        }
        stub.enqueue(.failure(URLError(.timedOut)))
        do {
            _ = try await service.correction(for: candidate, shapedFor: limits,
                                             options: options(bass: 0))
            XCTFail("the first fit should have been evicted, not served back")
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
