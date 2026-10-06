import XCTest
@testable import QudelixBar

private let hostileName = "Evil\u{202E} Name\nX\u{7}"
private let hostileSource = "Src\u{200B}"
private let hostileRig = "Rig\u{202E}\nB"
private let realZeroWidthName = "Bose QuietComfort 35 II Gaming Headset\u{200B}"

@MainActor
final class CatalogueSafetyTests: XCTestCase {
    private func catalogue(_ transport: HTTPTransport = PathTransport()) throws
        -> (AutoEqService, [AutoEqModel]) {
        let data = catalogueJSON([
            hostileName: [["form": "over-ear", "rig": hostileRig, "source": hostileSource]],
            realZeroWidthName: [["form": "over-ear", "rig": "HMS II.3", "source": "Rtings"]],
            "Sennheiser HD 650": [["form": "over-ear", "rig": "GRAS 45BC-10", "source": "oratory1990"]],
        ])
        let models = try AutoEqService.parseEntries(data)
        let service = AutoEqService(transport: transport)
        service.seedForPreview(models)
        return (service, models)
    }

    private func unsafe(_ text: String) -> Bool {
        text != SafeText.scrubbed(text, limit: 10_000)
    }

    func testCatalogueNamesAreScrubbedBeforeTheyReachARow() throws {
        let (service, _) = try catalogue()
        let rows = service.search("evil")
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertFalse(unsafe(row.title), row.title)
        XCTAssertFalse(unsafe(row.source), row.source)
        XCTAssertFalse(unsafe(row.detail), row.detail)
        XCTAssertEqual(row.title, "Evil NameX")
        XCTAssertEqual(row.detail, "Src · RigB")
    }

    func testTheRigIsKeptByteForByteEvenThoughItIsShownScrubbed() throws {
        let (service, _) = try catalogue()
        XCTAssertEqual(service.search("evil").first?.rig, hostileRig)
    }

    func testARowRemembersTheCataloguesOwnSpellingOfNameAndSource() throws {
        let (service, models) = try catalogue()
        let row = try XCTUnwrap(service.search("evil").first)
        let raw = try XCTUnwrap(models.first { $0.name == hostileName })
        let identity = AutoEqService.requestIdentity(of: row)
        XCTAssertEqual(identity.model, raw.name)
        XCTAssertEqual(identity.source, raw.measurements[0].source)
    }

    func testACleanRowNeedsNoRememberedSpelling() throws {
        let (service, _) = try catalogue()
        let row = try XCTUnwrap(service.search("HD 650").first)
        XCTAssertEqual(row.token, "")
        let identity = AutoEqService.requestIdentity(of: row)
        XCTAssertEqual(identity.model, "Sennheiser HD 650")
        XCTAssertEqual(identity.source, "oratory1990")
    }

    func testARealModelNameWithAZeroWidthSpaceStillReachesTheServerUnchanged() async throws {
        let transport = PathTransport()
        transport.set("/equalize", .success(equalizeResponse()))
        let (service, _) = try catalogue(transport)
        let row = try XCTUnwrap(service.search("Gaming Headset").first)
        XCTAssertEqual(row.title, "Bose QuietComfort 35 II Gaming Headset")

        _ = try await service.correction(
            for: row, shapedFor: .qudelix(bandCount: 10),
            options: CorrectionOptions(target: "Harman over-ear 2018"))

        let body = try XCTUnwrap(transport.postedBodies.first)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(sent["name"] as? String, realZeroWidthName)
        XCTAssertEqual(sent["source"] as? String, "Rtings")
        XCTAssertEqual(sent["rig"] as? String, "HMS II.3")
    }

    func testTheProvenanceOfAHostileRowIsClean() async throws {
        let transport = PathTransport()
        transport.set("/equalize", .success(equalizeResponse()))
        let (service, _) = try catalogue(transport)
        let row = try XCTUnwrap(service.search("evil").first)
        let result = try await service.correction(
            for: row, shapedFor: .qudelix(bandCount: 10),
            options: CorrectionOptions(target: "Harman over-ear 2018"))
        XCTAssertFalse(unsafe(result.provenance), result.provenance)
    }

    func testAProvenanceBuiltFromARawCandidateIsScrubbedToo() async throws {
        let transport = PathTransport()
        transport.set("/equalize", .success(equalizeResponse()))
        let service = AutoEqService(transport: transport)
        let raw = CorrectionCandidate(title: hostileName, source: "oratory1990",
                                      form: "over-ear", rig: "GRAS 45BC-10", token: "")
        let result = try await service.correction(
            for: raw, shapedFor: .qudelix(bandCount: 10),
            options: CorrectionOptions(target: "Harman over-ear 2018"))
        XCTAssertFalse(unsafe(result.provenance), result.provenance)
        let body = try XCTUnwrap(transport.postedBodies.first)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(sent["name"] as? String, hostileName)
    }

    func testTargetLabelsWithDirectionalOrControlScalarsAreNotOffered() throws {
        let data = catalogueJSON([
            ["label": "Evil\u{202E}Target", "recommended": [], "compatible": []],
            ["label": "Line\nBreak", "recommended": [], "compatible": []],
            ["label": "Zero\u{200B}Width", "recommended": [], "compatible": []],
            ["label": "Harman over-ear 2018", "recommended": [], "compatible": []],
        ])
        let targets = try AutoEqService.parseTargets(data)
        XCTAssertEqual(targets.map(\.label), ["Harman over-ear 2018"])
    }

    func testTargetPairingFormsAreScrubbed() throws {
        let data = catalogueJSON([
            ["label": "T", "recommended": [["source": "oratory1990", "form": "over-\u{202E}ear"]],
             "compatible": []],
        ])
        let targets = try AutoEqService.parseTargets(data)
        XCTAssertEqual(targets.first?.recommended.first?.form, "over-ear")
        XCTAssertEqual(targets.first?.form, "over-ear")
    }
}
