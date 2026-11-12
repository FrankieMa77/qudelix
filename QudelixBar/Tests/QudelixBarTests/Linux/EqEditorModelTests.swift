import XCTest
@testable import QudelixBar

final class EqEditorModelTests: XCTestCase {
    private var directory: URL!
    private var lockURL: URL!
    private var clock: ManualClock!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("eq-model-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActiveSlotFile.directoryOverride = directory
        EqHistoryFile.directoryOverride = directory
        lockURL = directory.appendingPathComponent("qudelix.lock")
        clock = ManualClock()
    }

    override func tearDown() {
        ActiveSlotFile.directoryOverride = nil
        EqHistoryFile.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    @MainActor
    private func makeModel(_ device: EqTestDevice) -> AppModel {
        let url = lockURL
        return AppModel(makeLinks: { [device.link] },
                        acquireLock: { QxInstanceLock.acquire(at: url) },
                        probeDevice: { AppDeviceProbe(present: true) },
                        clock: clock,
                        retryInterval: 2,
                        connectTimeout: 2)
    }

    @MainActor
    private func until(_ what: String = "condition", timeout: TimeInterval = 4,
                       _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    private func open(_ device: EqTestDevice) async -> AppModel {
        let model = makeModel(device)
        model.start()
        await until("connected") { model.state.connection.isConnected && model.eq.state.ready }
        await model.eq.waitForIdle()
        device.link.clearSends()
        return model
    }

    @MainActor
    private func settle(_ model: AppModel) async {
        await model.eq.waitForIdle()
        await model.waitForIdle()
    }

    private func bandPayloads(_ link: FakeLink) -> [[UInt8]] { link.payloads(for: .setEqBandParam) }

    @MainActor
    func testOpensWithTheLiveEqOfTheActiveGroup() async {
        let bands = EqTestSupport.shaped()
        let device = EqTestDevice(bands: bands, preGain: -3.5)
        let model = await open(device)
        let state = model.eq.state
        XCTAssertEqual(state.bandCount, 10)
        XCTAssertEqual(state.bands, bands.map(EqBand.init))
        XCTAssertEqual(state.preGain, -3.5, accuracy: 0.001)
        XCTAssertTrue(state.enabled)
        XCTAssertEqual(state.groupLabel, "user (10-band)")
        XCTAssertFalse(state.canUndo)
        XCTAssertFalse(state.canRedo)
        XCTAssertNil(state.selected)
        await model.shutdown()
    }

    @MainActor
    func testABandEditSendsTheBytesTheMacSends() async {
        let device = EqTestDevice()
        let model = await open(device)
        model.eq.setBand(2, EqBand(filter: .highShelf, freq: 3150, gain: 4.5, q: 0.71))
        await settle(model)
        let expected = QxPacket.bandParamPayload(
            group: .user, band: 2,
            QxEqBandValue(filter: .highShelf, freq: 3150, gain: 4.5, q: 0.71))
        XCTAssertEqual(bandPayloads(device.link), [expected].compactMap { $0 })
        XCTAssertEqual(bandPayloads(device.link)[0],
                       [0, 1, 2, 4, 0x0C, 0x4E, 0x00, 0x2D, 0x02, 0xD7])
        XCTAssertEqual(model.eq.state.bands[2], EqBand(filter: .highShelf, freq: 3150, gain: 4.5, q: 0.71))
        XCTAssertEqual(device.link.sentCommands, [.setEqBandParam])
        await model.shutdown()
    }

    @MainActor
    func testBandValuesAreClampedLikeTheMac() async {
        let device = EqTestDevice()
        let model = await open(device)
        model.eq.setBand(0, EqBand(filter: .peak, freq: 5, gain: 40, q: 99))
        await settle(model)
        XCTAssertEqual(model.eq.state.bands[0], EqBand(filter: .peak, freq: 20, gain: 12, q: 10))
        let payload = bandPayloads(device.link)[0]
        XCTAssertEqual(Array(payload[4...5]), [0, 20])
        model.eq.setBand(0, EqBand(filter: .peak, freq: 20, gain: 12, q: 10))
        await settle(model)
        XCTAssertEqual(bandPayloads(device.link).count, 1)
        await model.shutdown()
    }

    @MainActor
    func testPreGainSendsBothChannelsAndIsClamped() async {
        let device = EqTestDevice()
        let model = await open(device)
        model.eq.setPreGain(-6.5)
        await settle(model)
        XCTAssertEqual(device.link.payloads(for: .setEqPreGain),
                       [[0, 1, 0, 0xFF, 0xBF], [0, 2, 0, 0xFF, 0xBF]])
        model.eq.setPreGain(50)
        await settle(model)
        XCTAssertEqual(model.eq.state.preGain, 12)
        XCTAssertEqual(device.link.payloads(for: .setEqPreGain).last, [0, 2, 0, 0, 0x78])
        await model.shutdown()
    }

    @MainActor
    func testRapidEditsOfOneBandCoalesceAndTheLatestWins() async {
        let device = EqTestDevice()
        let model = await open(device)
        for step in 0..<25 {
            model.eq.setBand(3, EqBand(filter: .peak, freq: 250, gain: Double(step % 12), q: 1))
        }
        model.eq.setBand(3, EqBand(filter: .peak, freq: 250, gain: -7.5, q: 1))
        await settle(model)
        let writes = bandPayloads(device.link)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(device.bands[3].gain, -7.5, accuracy: 0.001)

        device.link.clearSends()
        for step in 0..<12 {
            model.eq.setBand(3, EqBand(filter: .peak, freq: 250, gain: Double(step) / 2, q: 1))
            await Task.yield()
        }
        await settle(model)
        let spread = bandPayloads(device.link)
        XCTAssertFalse(spread.isEmpty)
        XCTAssertLessThanOrEqual(spread.count, 12)
        XCTAssertEqual(device.bands[3].gain, 5.5, accuracy: 0.001)
        await model.shutdown()
    }

    @MainActor
    func testDifferentBandsAndPreGainAreIndependentWrites() async {
        let device = EqTestDevice()
        let model = await open(device)
        model.eq.setBand(1, EqBand(filter: .peak, freq: 63, gain: 3, q: 1))
        model.eq.setBand(2, EqBand(filter: .peak, freq: 125, gain: -3, q: 1))
        model.eq.setPreGain(-2)
        model.eq.setBand(1, EqBand(filter: .peak, freq: 63, gain: 6, q: 1))
        await settle(model)
        XCTAssertEqual(bandPayloads(device.link).count, 2)
        XCTAssertEqual(device.link.payloads(for: .setEqPreGain).count, 2)
        XCTAssertEqual(device.bands[1].gain, 6, accuracy: 0.001)
        XCTAssertEqual(device.bands[2].gain, -3, accuracy: 0.001)
        XCTAssertEqual(device.preGain, -2, accuracy: 0.001)
        await model.shutdown()
    }

    @MainActor
    func testEveryEqEditArmsSaveAllOnceFiveSecondsAfterTheLastOne() async {
        let device = EqTestDevice()
        let model = await open(device)
        model.eq.setBand(0, EqBand(filter: .peak, freq: 31, gain: 2, q: 1))
        await settle(model)
        XCTAssertTrue(model.hasPendingSave)
        clock.advance(4)
        model.eq.setPreGain(-1)
        await settle(model)
        clock.advance(4)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(device.link.sentCommands.contains(.saveAll))
        clock.advance(1.1)
        await until("saveAll") { device.link.sentCommands.contains(.saveAll) }
        clock.advance(30)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(device.link.sentCommands.filter { $0 == .saveAll }.count, 1)
        XCTAssertEqual(device.link.sentCommands.last, .saveAll)
        await model.shutdown()
    }

    @MainActor
    func testFlattenResetUndoAndRedoPersistButMuteDoesNot() async {
        let device = EqTestDevice(bands: EqTestSupport.shaped())
        let model = await open(device)
        model.eq.setBandMuted(1, true)
        await settle(model)
        XCTAssertFalse(model.hasPendingSave)
        model.eq.undo()
        await settle(model)
        XCTAssertTrue(model.hasPendingSave)
        model.eq.redo()
        await settle(model)
        XCTAssertTrue(model.hasPendingSave)
        model.eq.flatten()
        await settle(model)
        XCTAssertTrue(model.hasPendingSave)
        await model.flushSave()
        XCTAssertFalse(model.hasPendingSave)
        model.eq.undo()
        await settle(model)
        XCTAssertTrue(model.hasPendingSave)
        model.eq.resetLayout()
        await settle(model)
        XCTAssertTrue(model.hasPendingSave)
        await model.shutdown()
    }

    @MainActor
    func testQueuedEqWritesAreSentBeforeTheSaveAll() async {
        let device = EqTestDevice()
        let model = await open(device)
        model.eq.setBand(4, EqBand(filter: .peak, freq: 500, gain: 5, q: 1))
        clock.advance(5.1)
        await until("saveAll") { device.link.sentCommands.contains(.saveAll) }
        let order = device.link.sentCommands
        XCTAssertEqual(order.firstIndex(of: .setEqBandParam), 0)
        XCTAssertEqual(order.last, .saveAll)
        await model.shutdown()
    }

    @MainActor
    func testAnEditBurstIsOneCheckpointAndPersistsInTheCliHistory() async {
        let device = EqTestDevice()
        let model = await open(device)
        for step in 1...10 {
            model.eq.setBand(5, EqBand(filter: .peak, freq: 1000, gain: Double(step) / 2, q: 1))
            clock.advance(0.1)
        }
        await settle(model)
        XCTAssertEqual(EqHistoryFile.load().entries.count, 1)
        XCTAssertEqual(EqHistoryFile.load().entries[0].label, "band 6")
        XCTAssertEqual(EqHistoryFile.load().entries[0].snapshot.bands[5].gain, 0)
        XCTAssertTrue(model.eq.state.canUndo)
        XCTAssertEqual(model.eq.state.undoLabel, "band 6")
        clock.advance(1)
        model.eq.setBand(5, EqBand(filter: .peak, freq: 1000, gain: 8, q: 1))
        model.eq.setBand(6, EqBand(filter: .peak, freq: 2000, gain: 2, q: 1))
        await settle(model)
        let entries = EqHistoryFile.load().entries
        XCTAssertEqual(entries.map(\.label), ["band 6", "band 6", "band 7"])
        XCTAssertEqual(entries[1].snapshot.bands[5].gain, 5, accuracy: 0.001)
        await model.shutdown()
    }

    @MainActor
    func testUndoRestoresAndWritesOnlyTheChangedBands() async {
        let device = EqTestDevice(bands: EqTestSupport.shaped(), preGain: -2)
        let before = device.bands
        let model = await open(device)
        model.eq.setBand(2, EqBand(filter: .peak, freq: 125, gain: 9, q: 2))
        clock.advance(2)
        model.eq.setPreGain(-5)
        await settle(model)
        device.link.clearSends()

        model.eq.undo()
        await settle(model)
        XCTAssertEqual(model.eq.state.preGain, -2, accuracy: 0.001)
        XCTAssertEqual(device.link.payloads(for: .setEqPreGain).count, 2)
        XCTAssertTrue(bandPayloads(device.link).isEmpty)
        XCTAssertEqual(model.eq.state.undoLabel, "band 3")
        XCTAssertTrue(model.eq.state.canRedo)
        XCTAssertEqual(model.eq.state.redoLabel, "pre-gain")

        model.eq.undo()
        await settle(model)
        XCTAssertEqual(model.eq.state.bands[2], EqBand(before[2]))
        XCTAssertEqual(bandPayloads(device.link).count, 1)
        XCTAssertEqual(device.bands, before)
        XCTAssertFalse(model.eq.state.canUndo)

        model.eq.redo()
        model.eq.redo()
        await settle(model)
        XCTAssertEqual(model.eq.state.bands[2].gain, 9, accuracy: 0.001)
        XCTAssertEqual(model.eq.state.preGain, -5, accuracy: 0.001)
        XCTAssertEqual(device.bands[2].gain, 9, accuracy: 0.001)
        XCTAssertFalse(model.eq.state.canRedo)
        XCTAssertEqual(EqHistoryFile.load().entries.count, 2)
        await model.shutdown()
    }

    @MainActor
    func testAFreshEditClearsTheRedoStackAndUndoKeepsTheFileInStep() async {
        let device = EqTestDevice()
        let model = await open(device)
        model.eq.setBand(0, EqBand(filter: .peak, freq: 31, gain: 3, q: 1))
        clock.advance(2)
        model.eq.setBand(1, EqBand(filter: .peak, freq: 63, gain: 3, q: 1))
        model.eq.undo()
        XCTAssertTrue(model.eq.state.canRedo)
        XCTAssertEqual(EqHistoryFile.load().entries.count, 1)
        clock.advance(2)
        model.eq.setBand(2, EqBand(filter: .peak, freq: 125, gain: 3, q: 1))
        XCTAssertFalse(model.eq.state.canRedo)
        XCTAssertEqual(EqHistoryFile.load().entries.map(\.label), ["band 1", "band 3"])
        await settle(model)
        await model.shutdown()
    }

    @MainActor
    func testTheUndoStackIsSeededFromTheHistoryFileOfTheSameGroup() async {
        let older = EqSnapshot(groupRaw: 0, bands: EqTestSupport.shaped(), preGain: -1, enabled: true)
        let otherGroup = EqSnapshot(groupRaw: 2, bands: EqTestSupport.shaped(.b20), preGain: 0, enabled: true)
        EqHistoryFile.append(EqHistoryEntry(recordedAt: Date(), label: "import", snapshot: older))
        EqHistoryFile.append(EqHistoryEntry(recordedAt: Date(), label: "other", snapshot: otherGroup))
        let device = EqTestDevice()
        let model = await open(device)
        XCTAssertTrue(model.eq.state.canUndo)
        XCTAssertEqual(model.eq.state.undoLabel, "import")
        model.eq.undo()
        await settle(model)
        XCTAssertEqual(model.eq.state.preGain, -1, accuracy: 0.001)
        XCTAssertEqual(device.bands, EqTestSupport.shaped())
        await model.shutdown()
    }

    @MainActor
    func testUndoCountsAreCappedAtFortyLikeTheMac() async {
        let device = EqTestDevice()
        let model = await open(device)
        for step in 1...45 {
            clock.advance(1)
            model.eq.setBand(0, EqBand(filter: .peak, freq: 31, gain: Double(step % 12) + 0.5, q: 1))
        }
        await settle(model)
        var undone = 0
        while model.eq.state.canUndo {
            model.eq.undo()
            undone += 1
        }
        XCTAssertEqual(undone, 40)
        XCTAssertLessThanOrEqual(EqHistoryFile.load().entries.count, EqHistoryFile.depth)
        await model.shutdown()
    }

    @MainActor
    func testFlattenZeroesGainsAndPreGainAndResetRestoresTheFactoryLayout() async {
        let device = EqTestDevice(bands: EqTestSupport.shaped(), preGain: -4)
        let model = await open(device)
        model.eq.flatten()
        await settle(model)
        XCTAssertEqual(model.eq.state.preGain, 0)
        XCTAssertTrue(model.eq.state.bands.allSatisfy { $0.gain == 0 })
        XCTAssertEqual(model.eq.state.bands.map(\.q), EqTestSupport.shaped().map(\.q))
        XCTAssertEqual(device.bands.map(\.gain), [Double](repeating: 0, count: 10))
        XCTAssertEqual(model.eq.state.undoLabel, "flatten")

        clock.advance(2)
        model.eq.setBand(3, EqBand(filter: .lowShelf, freq: 300, gain: 3, q: 2))
        clock.advance(2)
        model.eq.resetLayout()
        await settle(model)
        let factory = QxEqGroup.user.defaultFreqs.map { EqBand(filter: .peak, freq: $0, gain: 0, q: 1) }
        XCTAssertEqual(model.eq.state.bands, factory)
        XCTAssertEqual(device.bands.map(\.freq), QxEqGroup.user.defaultFreqs)
        XCTAssertEqual(model.eq.state.undoLabel, "reset band layout")

        model.eq.undo()
        await settle(model)
        XCTAssertEqual(model.eq.state.bands[3], EqBand(filter: .lowShelf, freq: 300, gain: 3, q: 2))
        await model.shutdown()
    }

    @MainActor
    func testZeroBandKeepsFrequencyAndTurnsFiltersWithoutGainIntoPeaks() async {
        var bands = EqTestSupport.shaped()
        bands[1] = QxEqBandValue(filter: .hpf, freq: 80, gain: 0, q: 0.7)
        bands[2] = QxEqBandValue(filter: .peak, freq: 125, gain: 6, q: 2)
        let device = EqTestDevice(bands: bands)
        let model = await open(device)
        model.eq.zeroBand(2)
        model.eq.zeroBand(1)
        await settle(model)
        XCTAssertEqual(model.eq.state.bands[2], EqBand(filter: .peak, freq: 125, gain: 0, q: 2))
        XCTAssertEqual(model.eq.state.bands[1].filter, .peak)
        XCTAssertEqual(model.eq.state.bands[1].freq, 80)
        await model.shutdown()
    }

    @MainActor
    func testMutingPublishesOneConsistentStateAndKeepsTheSelection() async {
        var bands = EqTestSupport.shaped()
        bands[3] = QxEqBandValue(filter: .lowShelf, freq: 250, gain: 5, q: 0.75)
        let device = EqTestDevice(bands: bands)
        let model = await open(device)
        model.eq.select(3)
        await settle(model)
        var seen: [EqEditorState] = []
        model.eq.addObserver { seen.append($0) }
        seen = []
        model.eq.setBandMuted(3, true)
        await settle(model)
        XCTAssertFalse(seen.isEmpty)
        for state in seen where state.bands[3].filter == .bypass {
            XCTAssertTrue(state.isMuted(3))
        }
        XCTAssertEqual(model.eq.state.selected, 3)
        XCTAssertEqual(model.eq.state.muted[3], .lowShelf)
        model.eq.setBandMuted(3, false)
        await settle(model)
        XCTAssertEqual(model.eq.state.selected, 3)
        await model.shutdown()
    }

    @MainActor
    func testMutingBypassesTheBandAndRemembersItsShape() async {
        var bands = EqTestSupport.shaped()
        bands[3] = QxEqBandValue(filter: .lowShelf, freq: 250, gain: 5, q: 0.75)
        let device = EqTestDevice(bands: bands)
        let model = await open(device)
        model.eq.setBandMuted(3, true)
        await settle(model)
        XCTAssertEqual(model.eq.state.bands[3].filter, .bypass)
        XCTAssertEqual(model.eq.state.bands[3].gain, 5)
        XCTAssertTrue(model.eq.state.isMuted(3))
        XCTAssertEqual(model.eq.state.muted[3], .lowShelf)
        XCTAssertEqual(bandPayloads(device.link)[0][3], 0)
        XCTAssertEqual(device.bands[3].filter, .bypass)

        model.eq.setBandMuted(3, false)
        await settle(model)
        XCTAssertEqual(model.eq.state.bands[3], EqBand(bands[3]))
        XCTAssertFalse(model.eq.state.isMuted(3))
        XCTAssertEqual(device.bands[3], bands[3])
        XCTAssertEqual(model.eq.state.undoLabel, "unmute band 4")

        model.eq.setBandMuted(3, true)
        model.eq.setBandMuted(3, true)
        await settle(model)
        model.eq.setBand(3, EqBand(filter: .peak, freq: 250, gain: 5, q: 0.75))
        await settle(model)
        XCTAssertFalse(model.eq.state.isMuted(3))
        XCTAssertNil(model.eq.state.muted[3])
        await model.shutdown()
    }

    @MainActor
    func testMuteUndoRestoresTheMutedMap() async {
        let device = EqTestDevice(bands: EqTestSupport.shaped())
        let model = await open(device)
        model.eq.setBandMuted(2, true)
        clock.advance(2)
        model.eq.setBandMuted(4, true)
        XCTAssertEqual(Set(model.eq.state.muted.keys), [2, 4])
        model.eq.undo()
        await settle(model)
        XCTAssertEqual(Set(model.eq.state.muted.keys), [2])
        XCTAssertEqual(model.eq.state.bands[4], EqBand(EqTestSupport.shaped()[4]))
        model.eq.redo()
        await settle(model)
        XCTAssertEqual(Set(model.eq.state.muted.keys), [2, 4])
        XCTAssertTrue(model.eq.state.isMuted(4))
        await model.shutdown()
    }

    @MainActor
    func testBypassBandsCannotBeMutedAndFilterChangesWork() async {
        var bands = EqTestSupport.shaped()
        bands[0] = QxEqBandValue(filter: .bypass, freq: 31, gain: 0, q: 1)
        let device = EqTestDevice(bands: bands)
        let model = await open(device)
        model.eq.setBandMuted(0, true)
        await settle(model)
        XCTAssertTrue(model.eq.state.muted.isEmpty)
        XCTAssertTrue(bandPayloads(device.link).isEmpty)
        model.eq.setBand(0, EqBand(filter: .lpf, freq: 31, gain: 0, q: 1))
        await settle(model)
        XCTAssertEqual(device.bands[0].filter, .lpf)
        XCTAssertFalse(EqBand(filter: .lpf).editsGain)
        XCTAssertTrue(EqBand(filter: .bypass).editsGain)
        XCTAssertTrue(EqBand(filter: .peak).editsGain)
        await model.shutdown()
    }

    @MainActor
    func testTwentyBandGroupUsesItsOwnBankAndBandCount() async {
        let bands = EqTestSupport.shaped(.b20)
        let device = EqTestDevice(group: .b20, bands: bands, preGain: -2, slot: 7)
        let model = await open(device)
        XCTAssertEqual(model.eq.state.bandCount, 20)
        XCTAssertEqual(model.eq.state.groupLabel, "b20 (20-band)")
        XCTAssertEqual(model.eq.state.bands, bands.map(EqBand.init))
        model.eq.setBand(19, EqBand(filter: .highShelf, freq: 16000, gain: -3, q: 0.7))
        model.eq.setPreGain(-4)
        await settle(model)
        XCTAssertEqual(bandPayloads(device.link)[0][0], QxEqGroup.b20.rawValue)
        XCTAssertEqual(bandPayloads(device.link)[0][2], 19)
        XCTAssertEqual(device.link.payloads(for: .setEqPreGain)[0][0], QxEqGroup.b20.rawValue)
        XCTAssertEqual(device.bands[19].filter, .highShelf)
        model.eq.setBand(20, EqBand())
        await settle(model)
        XCTAssertEqual(bandPayloads(device.link).count, 1)
        model.eq.resetLayout()
        await settle(model)
        XCTAssertEqual(model.eq.state.bands.map(\.freq), QxEqGroup.b20.defaultFreqs)
        await model.shutdown()
    }

    @MainActor
    func testAGraphicPresetIsFlaggedAndEditedLikeAnyOtherBandSet() async {
        let device = EqTestDevice(graphic: true)
        let model = await open(device)
        XCTAssertTrue(model.eq.state.isGraphic)
        XCTAssertEqual(model.state.status?.eqType, "GEQ")
        model.eq.setBand(1, EqBand(filter: .peak, freq: 63, gain: 2, q: 1))
        await settle(model)
        XCTAssertEqual(device.link.sentCommands, [.setEqBandParam])
        await model.shutdown()
        let other = await open(EqTestDevice())
        XCTAssertFalse(other.eq.state.isGraphic)
        await other.shutdown()
    }

    @MainActor
    func testTheCurveIsTheSharedResponseWithoutPreGain() async {
        let bands = EqTestSupport.shaped()
        let device = EqTestDevice(bands: bands, preGain: -6)
        let model = await open(device)
        let expected = EQCurve.response(bands: bands, preGain: 0, count: 220)
        XCTAssertEqual(model.eq.response(), expected)
        XCTAssertEqual(model.eq.response(count: 64).count, 64)
        XCTAssertEqual(EqCurveGeometry.response(bands: model.eq.state.bands, count: 220), expected)
        model.eq.setBand(4, EqBand(filter: .peak, freq: 500, gain: 8, q: 1))
        XCTAssertNotEqual(model.eq.response(), expected)
        var edited = bands
        edited[4] = QxEqBandValue(filter: .peak, freq: 500, gain: 8, q: 1)
        XCTAssertEqual(model.eq.response(), EQCurve.response(bands: edited, preGain: 0, count: 220))
        await settle(model)
        await model.shutdown()
    }

    @MainActor
    func testSelectionIsOwnedByTheModelAndStaysInRange() async {
        let model = await open(EqTestDevice())
        var seen: [Int?] = []
        model.eq.addObserver { seen.append($0.selected) }
        model.eq.select(4)
        model.eq.select(4)
        model.eq.select(99)
        model.eq.select(nil)
        XCTAssertEqual(seen, [nil, 4, nil])
        await model.shutdown()
    }

    @MainActor
    func testEqOffKeepsTheBandsEditable() async {
        let device = EqTestDevice()
        let model = await open(device)
        model.eq.setEnabled(false)
        await settle(model)
        await until("eq off") { !model.eq.state.enabled }
        XCTAssertEqual(device.link.payloads(for: .setEqEnable), [[0, 0]])
        model.eq.setBand(0, EqBand(filter: .peak, freq: 31, gain: 4, q: 1))
        await settle(model)
        XCTAssertEqual(device.bands[0].gain, 4, accuracy: 0.001)
        await model.shutdown()
    }

    @MainActor
    func testUndoRestoresTheEqEnabledStateAndArmsTheSave() async {
        let device = EqTestDevice()
        let model = await open(device)
        model.eq.setBand(0, EqBand(filter: .peak, freq: 31, gain: 4, q: 1))
        await settle(model)
        await model.flushSave()
        model.eq.setEnabled(false)
        await settle(model)
        await model.flushSave()
        clock.advance(2)
        model.eq.setBand(1, EqBand(filter: .peak, freq: 63, gain: 4, q: 1))
        await settle(model)
        await model.flushSave()
        device.link.clearSends()
        model.eq.undo()
        await settle(model)
        XCTAssertTrue(device.link.payloads(for: .setEqEnable).isEmpty)
        model.eq.undo()
        await settle(model)
        XCTAssertEqual(device.link.payloads(for: .setEqEnable), [[0, 1]])
        XCTAssertTrue(model.hasPendingSave)
        await model.shutdown()
    }

    @MainActor
    func testAnExternalPresetChangeReloadsTheCurve() async {
        let device = EqTestDevice(names: [4: "Other"])
        let model = await open(device)
        let replaced = EqTestSupport.shaped().map { band -> QxEqBandValue in
            var copy = band
            copy.gain = 3
            return copy
        }
        device.bands = replaced
        device.notifyPreset(slot: 4)
        await until("reloaded") { model.eq.state.bands.map(\.gain) == [Double](repeating: 3, count: 10) }
        XCTAssertEqual(model.presets.state.activeIndex, 4)
        await model.shutdown()
    }

    @MainActor
    func testEditsAreIgnoredWhileDisconnectedOrBeforeTheEqIsRead() async {
        let model = AppModel.noDevice(clock: clock)
        model.start()
        await Task.yield()
        model.eq.setBand(0, EqBand())
        model.eq.setPreGain(3)
        model.eq.undo()
        model.eq.flatten()
        XCTAssertFalse(model.eq.state.ready)
        XCTAssertTrue(model.eq.state.bands.isEmpty)
        XCTAssertFalse(model.hasPendingSave)
        XCTAssertTrue(EqHistoryFile.load().entries.isEmpty)
        await model.shutdown()
    }

    @MainActor
    func testALostLinkEmptiesTheModelAndAReconnectReadsItAgain() async {
        let first = EqTestDevice(bands: EqTestSupport.shaped())
        let second = EqTestDevice(bands: EqTestSupport.shaped(), preGain: -9)
        let queue = [first.link, second.link]
        var next = 0
        let url = lockURL
        let model = AppModel(makeLinks: {
            defer { next += 1 }
            return [queue[min(next, queue.count - 1)]]
        }, acquireLock: { QxInstanceLock.acquire(at: url) },
           probeDevice: { AppDeviceProbe(present: true) }, clock: clock)
        model.start()
        await until("first") { model.eq.state.ready }
        await model.eq.waitForIdle()
        model.eq.setBand(0, EqBand(filter: .peak, freq: 31, gain: 4, q: 1))
        first.link.drop()
        await until("lost") { !model.eq.state.ready }
        XCTAssertTrue(model.eq.state.bands.isEmpty)
        XCTAssertFalse(model.presets.state.ready)
        clock.advance(2)
        await until("second") { model.eq.state.ready && model.eq.state.preGain == -9 }
        XCTAssertTrue(model.eq.state.canUndo)
        XCTAssertEqual(EqHistoryFile.load().entries.count, 1)
        await model.shutdown()
    }

    @MainActor
    func testOnlyAllowedCommandsAreEverSent() async {
        let device = EqTestDevice(bands: EqTestSupport.shaped())
        let model = await open(device)
        model.eq.setBand(1, EqBand(filter: .peak, freq: 63, gain: 1, q: 1))
        model.eq.setPreGain(-1)
        model.eq.setBandMuted(2, true)
        model.eq.flatten()
        model.eq.undo()
        model.eq.redo()
        model.eq.resetLayout()
        await settle(model)
        await model.shutdown()
        XCTAssertTrue(device.link.sentCommands.allSatisfy { QxSession.allowed.contains($0) })
    }
}

final class EqCurveGeometryTests: XCTestCase {
    private let bands: [EqBand] = [
        EqBand(filter: .peak, freq: 100, gain: 6, q: 1),
        EqBand(filter: .peak, freq: 1000, gain: -4, q: 1),
        EqBand(filter: .hpf, freq: 40, gain: 0, q: 0.7),
        EqBand(filter: .bypass, freq: 5000, gain: 3, q: 1),
    ]

    func testFrequencyMappingIsLogarithmicAndInvertible() {
        XCTAssertEqual(EqCurveGeometry.fraction(of: 20), 0, accuracy: 1e-9)
        XCTAssertEqual(EqCurveGeometry.fraction(of: 20000), 1, accuracy: 1e-9)
        XCTAssertEqual(EqCurveGeometry.fraction(of: 632.455532), 0.5, accuracy: 1e-6)
        for f in [31.0, 440, 4000, 16000] {
            let fraction = EqCurveGeometry.fraction(of: f)
            XCTAssertEqual(EqCurveGeometry.frequency(atFraction: fraction), f, accuracy: 1e-6)
        }
    }

    func testPlotRangeAndGridLevelsFollowTheMac() {
        XCTAssertEqual(EqCurveGeometry.plotRange(for: [0, 1, -2]), 9)
        XCTAssertEqual(EqCurveGeometry.plotRange(for: [7]), 12)
        XCTAssertEqual(EqCurveGeometry.plotRange(for: [11]), 15)
        XCTAssertEqual(EqCurveGeometry.plotRange(for: [40]), 18)
        XCTAssertEqual(EqCurveGeometry.gridLevels(range: 9), [-6, -3, 0, 3, 6])
        XCTAssertEqual(EqCurveGeometry.gridLevels(range: 12), [-6, 0, 6])
        XCTAssertEqual(EqCurveGeometry.gridLevels(range: 18), [-12, -6, 0, 6, 12])
    }

    func testMarkersSitOnTheCurveForGainFiltersAndOnZeroOtherwise() {
        XCTAssertEqual(EqCurveGeometry.markerGain(bands[0]), 6)
        XCTAssertEqual(EqCurveGeometry.markerGain(bands[2]), 0)
        XCTAssertEqual(EqCurveGeometry.yPosition(gain: 0, range: 12, height: 200), 100)
        XCTAssertEqual(EqCurveGeometry.yPosition(gain: 12, range: 12, height: 200), 6)
        XCTAssertEqual(EqCurveGeometry.yPosition(gain: 99, range: 12, height: 200), 6)
    }

    func testNearestBandPicksTheClosestWithinTheGrabRadiusAndSkipsBypassed() {
        let width = 600.0, height = 200.0, range = 12.0
        let x0 = EqCurveGeometry.fraction(of: 100) * width
        let y0 = EqCurveGeometry.yPosition(gain: 6, range: range, height: height)
        XCTAssertEqual(EqCurveGeometry.nearestBand(x: x0 + 3, y: y0 - 2, in: bands, width: width,
                                                   height: height, range: range), 0)
        XCTAssertNil(EqCurveGeometry.nearestBand(x: x0 + 60, y: y0, in: bands, width: width,
                                                 height: height, range: range))
        let bypassed = EqCurveGeometry.fraction(of: 5000) * width
        XCTAssertNil(EqCurveGeometry.nearestBand(
            x: bypassed, y: EqCurveGeometry.yPosition(gain: 3, range: range, height: height),
            in: bands, width: width, height: height, range: range))
    }

    func testFrequencyDragStaysBetweenItsNeighbours() {
        let wide = EqCurveGeometry.clampedFrequency(20000, forBand: 0, in: bands)
        XCTAssertEqual(wide, Int((1000 / EqCurveGeometry.minNeighbourRatio).rounded()))
        let low = EqCurveGeometry.clampedFrequency(21, forBand: 0, in: bands)
        XCTAssertEqual(low, Int((40 * EqCurveGeometry.minNeighbourRatio).rounded()))
        XCTAssertEqual(EqCurveGeometry.clampedFrequency(.nan, forBand: 0, in: bands), 100)
        XCTAssertEqual(EqCurveGeometry.clampedFrequency(500, forBand: 9, in: bands), 1000)
    }

    func testDraggingMovesGainVerticallyAndFrequencySideways() {
        let width = 600.0, height = 212.0, range = 12.0
        let usable = height / 2 - 6
        let up = EqCurveGeometry.dragged(bands[1], index: 1, in: bands, dx: 0, dy: -usable / 2,
                                         width: width, height: height, range: range)
        XCTAssertEqual(up.gain, 2, accuracy: 0.001)
        XCTAssertEqual(up.freq, 1000)
        let sideways = EqCurveGeometry.dragged(bands[1], index: 1, in: bands, dx: width * 0.1, dy: 0,
                                               width: width, height: height, range: range)
        let expected = EqCurveGeometry.frequency(atFraction: EqCurveGeometry.fraction(of: 1000) + 0.1)
        XCTAssertEqual(Double(sideways.freq), expected.rounded(), accuracy: 1)
        XCTAssertEqual(sideways.gain, -4)
        let pegged = EqCurveGeometry.dragged(bands[1], index: 1, in: bands, dx: 0, dy: -10_000,
                                             width: width, height: height, range: range)
        XCTAssertEqual(pegged.gain, 12)
        let fine = EqCurveGeometry.dragged(bands[1], index: 1, in: bands, dx: 0, dy: -usable / 2,
                                           width: width, height: height, range: range, fine: true)
        XCTAssertEqual(fine.gain, -2.5, accuracy: 0.001)
        let hp = EqCurveGeometry.dragged(bands[2], index: 2, in: bands, dx: 0, dy: -50,
                                         width: width, height: height, range: range)
        XCTAssertEqual(hp.gain, 0)
    }

    func testScrollingChangesQInSmallLogSteps() {
        let start = EqBand(filter: .peak, freq: 1000, gain: 0, q: 1)
        XCTAssertGreaterThan(EqCurveGeometry.scrolledQ(start, steps: -1).q, 1)
        XCTAssertLessThan(EqCurveGeometry.scrolledQ(start, steps: 1).q, 1)
        XCTAssertEqual(EqCurveGeometry.scrolledQ(start, steps: -1).q, 1.12, accuracy: 0.001)
        XCTAssertEqual(EqCurveGeometry.scrolledQ(start, steps: -1000).q, 10)
        XCTAssertEqual(EqCurveGeometry.scrolledQ(start, steps: 1000).q, 0.1)
    }
}
