import XCTest
@testable import QudelixBar

final class EqSnapshotStoreTests: XCTestCase {
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eq-snapshot-test-\(UUID().uuidString).json")
    }

    private func bands(_ gains: [Double]) -> [QxEqBandValue] {
        gains.enumerated().map { i, g in
            QxEqBandValue(filter: .peak, freq: 100 * (i + 1), gain: g, q: 1.0)
        }
    }

    func testAFileFromBeforePerGroupSnapshotsMigratesIntact() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        {"groupRaw":2,"preGain":-3.5,"enabled":true,"name":"HD 650",
         "bands":[{"filter":5,"freq":1000,"gain":2.5,"q":1.0},
                  {"filter":0,"freq":4000,"gain":-6.0,"q":2.0}],
         "mutedBands":{"1":5}}
        """
        try? Data(json.utf8).write(to: url)

        let store = EqSnapshotFile.load(from: url)

        let snap = store[2]
        XCTAssertNotNil(snap, "an old single-snapshot file must migrate, not be discarded")
        XCTAssertEqual(snap?.groupRaw, 2)
        XCTAssertEqual(snap?.name, "HD 650")
        XCTAssertEqual(snap?.preGain, -3.5)
        XCTAssertEqual(snap?.enabled, true)
        XCTAssertEqual(snap?.bands.count, 2)
        XCTAssertEqual(snap?.bands[0].gain, 2.5)
        XCTAssertEqual(snap?.bands[1].filter, .bypass)
        XCTAssertEqual(snap?.mutedBands, [1: .peak])
        XCTAssertNil(store[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".recovered"))
    }

    func testAMigratedFileSavesAndReloadsInTheNewShape() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        {"groupRaw":0,"preGain":-2.0,"enabled":false,
         "bands":[{"filter":5,"freq":250,"gain":3.0,"q":0.7}]}
        """
        try? Data(json.utf8).write(to: url)

        let migrated = EqSnapshotFile.load(from: url)
        EqSnapshotFile.save(migrated, to: url)

        XCTAssertEqual(EqSnapshotFile.load(from: url), migrated)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("\"groups\""), "the new shape keys curves by group")
    }

    func testSwitchingGroupsLeavesTheOtherGroupsCurveAlone() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var store = EqSnapshotFile.load(from: url)
        store.set(EqSnapshot(groupRaw: 0, bands: bands([4, -2]), preGain: -4,
                             enabled: true, name: "ten band"))
        EqSnapshotFile.save(store, to: url)

        var afterSwitch = EqSnapshotFile.load(from: url)
        afterSwitch.set(EqSnapshot(groupRaw: 2, bands: bands([1, 1, 1]), preGain: -1,
                                   enabled: false, name: "twenty band"))
        EqSnapshotFile.save(afterSwitch, to: url)

        let reloaded = EqSnapshotFile.load(from: url)
        XCTAssertEqual(reloaded[0]?.name, "ten band")
        XCTAssertEqual(reloaded[0]?.bands.map(\.gain), [4, -2])
        XCTAssertEqual(reloaded[0]?.preGain, -4)
        XCTAssertEqual(reloaded[2]?.name, "twenty band")
        XCTAssertEqual(reloaded[2]?.bands.count, 3)
    }

    func testASnapshotIsFiledUnderItsOwnGroup() {
        var store = EqSnapshotStore()
        store.set(EqSnapshot(groupRaw: 2, bands: bands([1]), preGain: 0, enabled: true))
        XCTAssertNil(store[0])
        XCTAssertEqual(store[2]?.groupRaw, 2)
        store.set(EqSnapshot(groupRaw: 2, bands: bands([5]), preGain: 0, enabled: true))
        XCTAssertEqual(store[2]?.bands.first?.gain, 5)
        XCTAssertEqual(store.byGroup.count, 1)
    }

    func testAMissingFileLoadsAsAnEmptyStore() {
        XCTAssertTrue(EqSnapshotFile.load(from: tempFileURL()).isEmpty)
    }

    func testAnUndecodableFileIsParkedRatherThanDestroyed() {
        let url = tempFileURL()
        let parked = URL(fileURLWithPath: url.path + ".recovered")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: parked)
        }
        let original = "{ \"groups\": this was hand-edited badly"
        try? Data(original.utf8).write(to: url)

        XCTAssertTrue(EqSnapshotFile.load(from: url).isEmpty)

        XCTAssertTrue(FileManager.default.fileExists(atPath: parked.path),
                      "a corrupt EQ file must be recoverable, not silently dropped")
        XCTAssertEqual(try? String(contentsOf: parked, encoding: .utf8), original)
    }

    private func parkedURL(_ url: URL, _ suffix: String) -> URL {
        URL(fileURLWithPath: url.path + suffix)
    }

    func testASecondUnreadableFileIsParkedBesideTheFirstNotOverIt() {
        let url = tempFileURL()
        let suffixes = [".recovered", ".recovered-2", ".recovered-3"]
        defer {
            try? FileManager.default.removeItem(at: url)
            for suffix in suffixes { try? FileManager.default.removeItem(at: parkedURL(url, suffix)) }
        }
        let contents = ["{ first corrupt", "{ second corrupt", "{ third corrupt"]

        for text in contents {
            try? Data(text.utf8).write(to: url)
            XCTAssertTrue(EqSnapshotFile.load(from: url).isEmpty)
        }

        for (suffix, text) in zip(suffixes, contents) {
            XCTAssertEqual(try? String(contentsOf: parkedURL(url, suffix), encoding: .utf8), text,
                           "\(suffix) keeps the file that was parked into it")
        }
    }

    func testTheParkedCopiesStopAtTheCapWithoutTouchingTheOldest() {
        let url = tempFileURL()
        let cap = AIResearchStore.maxParkedCopies
        let suffixes = [".recovered"] + (2...cap).map { ".recovered-\($0)" }
        defer {
            try? FileManager.default.removeItem(at: url)
            for suffix in suffixes { try? FileManager.default.removeItem(at: parkedURL(url, suffix)) }
        }

        for n in 1...(cap + 2) {
            try? Data("{ corrupt \(n)".utf8).write(to: url)
            _ = EqSnapshotFile.load(from: url)
        }

        XCTAssertEqual(try? String(contentsOf: parkedURL(url, ".recovered"), encoding: .utf8),
                       "{ corrupt 1")
        XCTAssertEqual(try? String(contentsOf: parkedURL(url, ".recovered-2"), encoding: .utf8),
                       "{ corrupt 2")
        XCTAssertEqual(try? String(contentsOf: parkedURL(url, ".recovered-\(cap)"), encoding: .utf8),
                       "{ corrupt \(cap + 2)", "only the last slot is reused once they are full")
    }

    func testAFileClaimingMoreBandsThanAnyGroupHasIsCutToSize() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let band = "{\"filter\":5,\"freq\":1000,\"gain\":1,\"q\":1}"
        let json = """
        {"groups":{"0":{"groupRaw":0,"preGain":0,"enabled":true,
         "bands":[\(Array(repeating: band, count: 1000).joined(separator: ","))]}}}
        """
        try? Data(json.utf8).write(to: url)

        XCTAssertEqual(EqSnapshotFile.load(from: url)[0]?.bands.count, QxEq.maxBandCount)
    }

    func testAnUnknownFilterValueCostsOneBandRatherThanEveryCurve() {
        let url = tempFileURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ".recovered"))
        }
        let json = """
        {"groups":{
          "0":{"groupRaw":0,"preGain":-3.0,"enabled":true,"name":"ten band",
               "bands":[{"filter":5,"freq":1000,"gain":2.0,"q":1.0},
                        {"filter":99,"freq":4000,"gain":-3.0,"q":1.0}]},
          "2":{"groupRaw":2,"preGain":-1.0,"enabled":true,"name":"twenty band",
               "bands":[{"filter":3,"freq":105,"gain":4.0,"q":0.7}]}}}
        """
        try? Data(json.utf8).write(to: url)

        let store = EqSnapshotFile.load(from: url)
        XCTAssertEqual(store[0]?.bands.map(\.filter), [.peak, .bypass])
        XCTAssertEqual(store[0]?.bands[1].gain, -3.0, "the rest of the band survives")
        XCTAssertEqual(store[2]?.name, "twenty band",
                       "the other group's curve must not go with it")
    }

    func testAnOversizedFileIsRefusedOutright() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try? Data(String(repeating: "x", count: 200_000).utf8).write(to: url)
        XCTAssertTrue(EqSnapshotFile.load(from: url).isEmpty)
    }

    func testTheGroupKeyWinsOverAContradictoryField() {
        let json = """
        {"groups":{"2":{"groupRaw":0,"preGain":0,"enabled":true,
                        "bands":[{"filter":5,"freq":1000,"gain":1.0,"q":1.0}]}}}
        """
        let store = try? JSONDecoder().decode(EqSnapshotStore.self, from: Data(json.utf8))
        XCTAssertNil(store?[0])
        XCTAssertEqual(store?[2]?.groupRaw, 2)
    }

    func testAnUnknownGroupIdIsDropped() {
        let json = """
        {"groups":{"9":{"groupRaw":9,"preGain":0,"enabled":true,"bands":[]}}}
        """
        let store = try? JSONDecoder().decode(EqSnapshotStore.self, from: Data(json.utf8))
        XCTAssertEqual(store?.isEmpty, true)
    }

    func testValuesOffDiskAreStillClamped() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        {"groups":{"0":{"groupRaw":0,"preGain":-99,"enabled":true,
                        "bands":[{"filter":5,"freq":99999,"gain":40,"q":900}]}}}
        """
        try? Data(json.utf8).write(to: url)

        let snap = EqSnapshotFile.load(from: url)[0]
        XCTAssertEqual(snap?.preGain, EQHeadroom.clamp(-99))
        XCTAssertEqual(snap?.bands.first?.freq, 20000)
        XCTAssertEqual(snap?.bands.first?.gain, 12)
        XCTAssertEqual(snap?.bands.first?.q, 10)
    }
}

final class BLEWriteBudgetTests: XCTestCase {
    private let defaultBudget = 20

    private func nameFrame(_ name: String) -> [UInt8] {
        let payload = QxPacket.presetNamePayload(group: .user, index: 0, name: name)!
        return BLETransport.frame(.qudelix, .setEqPresetName, payload)
    }

    func testAFullLengthPresetNameDoesNotFitTheDefaultMtu() {
        let frame = nameFrame(String(repeating: "M", count: QxPacket.maxPresetNameBytes))
        XCTAssertEqual(frame.count, 36)
        XCTAssertNotNil(BLETransport.writeRefusal(frame: frame, budget: defaultBudget),
                        "a frame that cannot fit one write must be refused, not trimmed")
    }

    func testTheDefaultMtuFitsThirteenNameBytesAndNotFourteen() {
        XCTAssertNil(BLETransport.writeRefusal(frame: nameFrame(String(repeating: "a", count: 13)),
                                               budget: defaultBudget))
        XCTAssertNotNil(BLETransport.writeRefusal(frame: nameFrame(String(repeating: "a", count: 14)),
                                                  budget: defaultBudget))
    }

    func testOrdinaryCommandsFitTheDefaultMtu() {
        let commands: [(QxCmd, [UInt8])] = [
            (.setEqEnable, [0, 1]),
            (.setEqType, [0, 1]),
            (.setVolume, [1, 0x00, 0x64]),
            (.reqEqPreset, [1]),
            (.saveAll, []),
            (.setEqBandParam, [0, 1, 3, 5, 0x03, 0xE8, 0x00, 0x1E, 0x04, 0x00]),
        ]
        for (cmd, data) in commands {
            let frame = BLETransport.frame(.qudelix, cmd, data)
            XCTAssertLessThanOrEqual(frame.count, 14, "\(cmd) grew unexpectedly")
            XCTAssertNil(BLETransport.writeRefusal(frame: frame, budget: defaultBudget),
                         "\(cmd) must still be sendable")
        }
    }

    func testANegotiatedMtuAcceptsTheLongestName() {
        let frame = nameFrame(String(repeating: "M", count: QxPacket.maxPresetNameBytes))
        XCTAssertNil(BLETransport.writeRefusal(frame: frame, budget: 182))
    }
}
