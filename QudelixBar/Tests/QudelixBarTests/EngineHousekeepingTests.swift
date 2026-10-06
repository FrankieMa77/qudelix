import Combine
import CoreAudio
import XCTest
@testable import QudelixBar

final class TapRebuildDecisionTests: XCTestCase {
    func testANewProcessOfAnAssignedAppRebuildsTheTaps() {
        let live = plan([("com.browser", [10, 20])])
        let afterSpawn = plan([("com.browser", [10, 20, 30])])
        XCTAssertFalse(StageEngine.sameTaps(live, afterSpawn),
                       "the new process would play through the catch-all")
    }

    func testALostProcessRebuildsTheTaps() {
        XCTAssertFalse(StageEngine.sameTaps(plan([("com.browser", [10, 20])]),
                                            plan([("com.browser", [10])])))
    }

    func testOnlyTheCurveChangingKeepsTheTaps() {
        var edited = plan([("com.a", [1, 2])])
        edited[0].chain = AppCurve(bundleID: "com.a", preGain: -9,
                                   bands: [QxEqBandValue(filter: .peak, freq: 100,
                                                         gain: 3, q: 1)])
        XCTAssertTrue(StageEngine.sameTaps(plan([("com.a", [1, 2])]), edited),
                      "a new curve is swapped on the running processor")
    }

    func testADifferentAppRebuildsTheTaps() {
        XCTAssertFalse(StageEngine.sameTaps(plan([("com.a", [1])]),
                                            plan([("com.b", [1])])))
        XCTAssertFalse(StageEngine.sameTaps(plan([("com.a", [1])]),
                                            plan([("com.a", [1]), ("com.b", [2])])))
        XCTAssertTrue(StageEngine.sameTaps([], []))
    }

    func testThePlannerNoticesAProcessTheOldBundleIdCheckWouldMiss() {
        let preset = LibraryPreset(name: "Warm", group: .user,
                                   bands: QxEqGroup.user.defaultFreqs.map {
                                       QxEqBandValue(filter: .peak, freq: $0,
                                                     gain: 1, q: 1)
                                   }, preGain: -3)
        let assignments = AppAssignments.resolve(
            assignments: [AppAssignment(bundleID: "com.browser", presetID: preset.id)],
            presets: [preset])
        let before = StageEngine.tapPlan(
            assignments: assignments,
            runningProcesses: [RunningAudioProcess(bundleID: "com.browser",
                                                   pid: 3, object: 11)],
            selfPID: 99)
        let after = StageEngine.tapPlan(
            assignments: assignments,
            runningProcesses: [RunningAudioProcess(bundleID: "com.browser",
                                                   pid: 3, object: 11),
                               RunningAudioProcess(bundleID: "com.browser",
                                                   pid: 4, object: 12)],
            selfPID: 99)
        XCTAssertEqual(before.map(\.bundleID), after.map(\.bundleID),
                       "the names match, which is why comparing them was not enough")
        XCTAssertFalse(StageEngine.sameTaps(before, after))
    }

    private func plan(_ entries: [(String, [AudioObjectID])])
        -> [StageEngine.AppTapEntry] {
        entries.map {
            StageEngine.AppTapEntry(
                bundleID: $0.0, objects: $0.1,
                chain: AppCurve(bundleID: $0.0, preGain: 0, bands: []))
        }
    }
}

final class ProcessListCostTests: XCTestCase {
    func testAnAnswerIsReusedWithinTheWindowAndTakenAgainAfterIt() {
        var now: TimeInterval = 100
        var walks = 0
        let cache = TimedCache<Int>(ttl: 0.5, now: { now })

        func read() -> Int {
            cache.value {
                walks += 1
                return walks
            }
        }

        XCTAssertEqual(read(), 1)
        now += 0.1
        XCTAssertEqual(read(), 1, "the same instant, asked about twice")
        now += 0.39
        XCTAssertEqual(read(), 1)
        XCTAssertEqual(walks, 1)

        now += 0.5
        XCTAssertEqual(read(), 2)
        XCTAssertEqual(walks, 2)
    }

    func testAProcessListChangeThrowsTheAnswerAway() {
        var now: TimeInterval = 0
        var walks = 0
        let cache = TimedCache<Int>(ttl: 10, now: { now })
        _ = cache.value { walks += 1; return walks }
        now += 0.01
        _ = cache.value { walks += 1; return walks }
        XCTAssertEqual(walks, 1)
        cache.invalidate()
        _ = cache.value { walks += 1; return walks }
        XCTAssertEqual(walks, 2)
    }

    func testAClockThatJumpsBackwardsDoesNotFreezeTheAnswer() {
        var now: TimeInterval = 1000
        var walks = 0
        let cache = TimedCache<Int>(ttl: 0.5, now: { now })
        _ = cache.value { walks += 1; return walks }
        now -= 60
        _ = cache.value { walks += 1; return walks }
        XCTAssertEqual(walks, 2)
    }

    func testAnAbsurdPropertySizeIsRefusedRatherThanAllocated() {
        XCTAssertNil(AudioOutputs.elementCount(0, of: AudioObjectID.self))
        XCTAssertNil(AudioOutputs.elementCount(AudioOutputs.maxPropertyBytes + 1,
                                               of: AudioObjectID.self))
        XCTAssertNil(AudioOutputs.elementCount(UInt32.max, of: AudioObjectID.self))
        XCTAssertNil(AudioOutputs.elementCount(2, of: AudioObjectID.self),
                     "less than one whole element is not an answer")
    }

    func testTheCountReadIsWhatTheAllocationCanHold() {
        let stride = UInt32(MemoryLayout<AudioObjectID>.size)
        XCTAssertEqual(AudioOutputs.elementCount(stride, of: AudioObjectID.self), 1)
        XCTAssertEqual(AudioOutputs.elementCount(stride * 4 + 1,
                                                 of: AudioObjectID.self), 4,
                       "a size that is not a whole number of elements rounds down")
    }

    func testTheHalWalksAreBounded() {
        XCTAssertLessThanOrEqual(AudioOutputs.maxProcessObjects, 4096)
        XCTAssertLessThanOrEqual(AudioOutputs.maxDevices, 4096)
        XCTAssertGreaterThan(AudioOutputs.processCacheTTL, 0)
    }

    func testAHostileBundleIdIsBoundedBeforeItIsScrubbed() {
        let hostile = String(repeating: "\u{202E}", count: 500_000) + "com.evil"
        let bounded = AppAssignments.headroom(hostile,
                                              limit: AppAssignments.maxBundleIDLength)
        XCTAssertEqual(bounded.unicodeScalars.count,
                       AppAssignments.maxBundleIDLength * 4,
                       "the scrubber must never be handed a megabyte to walk")

        let clean = AppAssignments.clampedBundleID(hostile)
        XCTAssertFalse(clean.contains("\u{202E}"))
        XCTAssertLessThanOrEqual(clean.count, AppAssignments.maxBundleIDLength + 1)

        let name = AppAssignments.clampedName(String(repeating: "a", count: 200_000))
        XCTAssertLessThanOrEqual(name.count, AppAssignments.maxNameLength + 1)
    }

    func testTheHeadroomIsGenerousEnoughToKeepAFullLengthName() {
        let name = String(repeating: "é", count: AppAssignments.maxNameLength)
        XCTAssertEqual(AppAssignments.clampedName(name).count,
                       AppAssignments.maxNameLength)
    }
}

final class MeteringVisibilityGateTests: XCTestCase {
    @MainActor
    func testAMeteredValueDoesNotWakeTheUiWhileThePopoverIsShut() {
        let stage = StageState()
        stage.previewDisablePersistence()

        var wakes = 0
        let token = stage.objectWillChange.sink { _ in wakes += 1 }
        defer { token.cancel() }

        stage.previewPublishLimiter(3.5)
        XCTAssertEqual(wakes, 0, "a tick with nobody looking must publish nothing")
        XCTAssertEqual(stage.limiterGainReductionDbLive, 3.5)
        XCTAssertEqual(stage.limiterGainReductionDb, 0)

        stage.setUIVisible(true)
        XCTAssertEqual(stage.limiterGainReductionDb, 3.5,
                       "opening shows the current number, not the last published one")

        wakes = 0
        stage.previewPublishLimiter(4.5)
        XCTAssertEqual(stage.limiterGainReductionDb, 4.5)
        XCTAssertGreaterThan(wakes, 0)

        wakes = 0
        stage.previewPublishLimiter(4.5)
        XCTAssertEqual(wakes, 0, "an unchanged value is not a redraw")
    }
}

final class DiagHeartbeatFileTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testTheFileIsTrimmedOnlyWhenItOutgrowsItsCapAndKeepsTheNewestLines() throws {
        let url = scratch.appendingPathComponent("diag.txt")
        let log = DiagLog(url: url, maxLines: 5, maxBytes: 200)
        for i in 1...80 { log.append("line \(i)") }
        log.flush()

        let lines = try lines(of: url)
        XCTAssertEqual(lines.last, "line 80", "the newest heartbeat is always there")
        XCTAssertGreaterThanOrEqual(lines.count, 5,
                                    "at least the in-memory tail survives a trim")
        let size = try XCTUnwrap(
            url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThanOrEqual(size, 200, "the cap is what forces the trim")
    }

    func testTheFileIsRewrittenRarelyRatherThanOnEveryLine() throws {
        let url = scratch.appendingPathComponent("diag.txt")
        let log = DiagLog(url: url, maxLines: 5, maxBytes: 200)
        log.append("line 1")
        log.flush()
        var rewrites = 0
        var previous = try inode(of: url)
        for i in 2...200 {
            log.append("line \(i)")
            log.flush()
            let now = try inode(of: url)
            if now != previous { rewrites += 1 }
            previous = now
        }
        XCTAssertLessThan(rewrites, 40,
                          "a 200-byte cap holds about ten of these lines")
        XCTAssertGreaterThan(rewrites, 0, "it does trim once it fills up")
    }

    func testEachLineIsAppendedRatherThanTheWholeFileRewritten() throws {
        let url = scratch.appendingPathComponent("diag.txt")
        let log = DiagLog(url: url, maxLines: 200, maxBytes: 64 << 10)
        log.append("first")
        log.flush()

        let inode = try inode(of: url)
        for i in 2...50 { log.append("line \(i)") }
        log.flush()
        XCTAssertEqual(try self.inode(of: url), inode,
                       "an atomic rewrite would have replaced the file")
        XCTAssertEqual(try lines(of: url).count, 50)
    }

    func testTheLastRunsLinesSurviveAndAreTrimmedOnce() throws {
        let url = scratch.appendingPathComponent("diag.txt")
        let old = (1...40).map { "old \($0)" }.joined(separator: "\n") + "\n"
        XCTAssertTrue(SafeFile.writeAtomic(Data(old.utf8), to: url))

        let log = DiagLog(url: url, maxLines: 4, maxBytes: 64 << 10)
        log.append("new")
        log.flush()

        let lines = try lines(of: url)
        XCTAssertEqual(lines.suffix(5),
                       ["old 37", "old 38", "old 39", "old 40", "new"],
                       "the last run's tail is kept and this run continues it")
        XCTAssertLessThanOrEqual(lines.count, 6, "the other 36 were trimmed away")
    }

    func testTheFileIsPrivateToTheUser() throws {
        let url = scratch.appendingPathComponent("diag.txt")
        let log = DiagLog(url: url, maxLines: 4, maxBytes: 64 << 10)
        log.append("one")
        log.flush()

        var st = stat()
        let statted = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &st)
        }
        XCTAssertEqual(statted, 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
    }

    func testAFifoAtThePathIsReadAsEmptyInsteadOfBlockingTheQueue() throws {
        let fifo = scratch.appendingPathComponent("diag.txt")
        let made = fifo.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return mkfifo(path, 0o600)
        }
        XCTAssertEqual(made, 0)

        let returned = expectation(description: "readDiagTail returned")
        var text: String?
        DispatchQueue.global().async {
            text = StageState.readDiagTail(fifo)
            returned.fulfill()
        }
        wait(for: [returned], timeout: 2)
        XCTAssertEqual(text, "")
    }

    func testTheHeartbeatQueueSurvivesAFifoPlantedAtTheFile() throws {
        let url = scratch.appendingPathComponent("diag.txt")
        let made = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return mkfifo(path, 0o600)
        }
        XCTAssertEqual(made, 0)

        let finished = expectation(description: "the queue drained")
        DispatchQueue.global().async {
            let log = DiagLog(url: url, maxLines: 4, maxBytes: 64 << 10)
            log.append("after the fifo")
            log.flush()
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(try lines(of: url), ["after the fifo"])
    }

    func testAnOversizedFileStartsFreshAndASymlinkIsNotFollowed() throws {
        let big = scratch.appendingPathComponent("big.txt")
        XCTAssertTrue(SafeFile.writeAtomic(
            Data(repeating: 0x41, count: StageState.diagReadCap + 1), to: big))
        XCTAssertEqual(StageState.readDiagTail(big), "")

        let target = scratch.appendingPathComponent("target.txt")
        XCTAssertTrue(SafeFile.writeAtomic(Data("secret\n".utf8), to: target))
        let link = scratch.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(StageState.readDiagTail(link), "")

        let plain = scratch.appendingPathComponent("plain.txt")
        XCTAssertTrue(SafeFile.writeAtomic(Data("one\ntwo\n".utf8), to: plain))
        XCTAssertEqual(StageState.readDiagTail(plain), "one\ntwo\n")
    }

    private func lines(of url: URL) throws -> [String] {
        let data = try XCTUnwrap(SafeFile.read(url, cap: 1 << 20))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        return text.split(separator: "\n").map(String.init)
    }

    private func inode(of url: URL) throws -> UInt64 {
        var st = stat()
        let statted = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &st)
        }
        XCTAssertEqual(statted, 0)
        return UInt64(st.st_ino)
    }
}

final class PacketLogFileTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("packetlog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testTheDescriptorIsHeldAcrossLinesAndTheFileStaysTheSameOne() throws {
        let url = scratch.appendingPathComponent("packets.log")
        let log = AppendingLog(url: url, maxBytes: 1_000_000)
        log.append(Data("one\n".utf8))
        let first = try inode(of: url)
        for i in 2...200 { log.append(Data("line \(i)\n".utf8)) }

        XCTAssertEqual(try inode(of: url), first)
        XCTAssertEqual(try lines(of: url).count, 200)
        XCTAssertEqual(log.bytesWritten, try size(of: url))
    }

    func testTheLogRollsOverInsteadOfBeingWipedAndKeepsWriting() throws {
        let url = scratch.appendingPathComponent("packets.log")
        let log = AppendingLog(url: url, maxBytes: 40)
        for i in 1...20 { log.append(Data("line \(i)\n".utf8)) }
        log.close()

        let rolled = url.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rolled.path),
                      "the run that mattered is kept, not truncated away")
        let live = try lines(of: url)
        XCTAssertEqual(live.last, "line 20")
        XCTAssertFalse(live.isEmpty, "writing continues into the fresh file")
        XCTAssertFalse(try lines(of: rolled).isEmpty)
    }

    func testTheFileIsPrivateToTheUser() throws {
        let url = scratch.appendingPathComponent("packets.log")
        let log = AppendingLog(url: url, maxBytes: 1000)
        log.append(Data("one\n".utf8))
        log.close()

        var st = stat()
        _ = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &st)
        }
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
    }

    func testAFileMovedAwayUnderneathIsReopenedAtItsOwnPath() throws {
        let url = scratch.appendingPathComponent("packets.log")
        let log = AppendingLog(url: url, maxBytes: 1_000_000, verifyEvery: 0)
        log.append(Data("one\n".utf8))
        try FileManager.default.moveItem(at: url,
                                         to: scratch.appendingPathComponent("rotated-by-someone-else"))
        log.append(Data("two\n".utf8))
        log.close()

        XCTAssertEqual(try lines(of: url), ["two"])
        XCTAssertEqual(log.bytesWritten, 4)
    }

    func testAFileDeletedUnderneathIsRecreatedInsteadOfWrittenIntoTheVoid() throws {
        let url = scratch.appendingPathComponent("packets.log")
        let log = AppendingLog(url: url, maxBytes: 1_000_000, verifyEvery: 0)
        log.append(Data("one\n".utf8))
        try FileManager.default.removeItem(at: url)
        log.append(Data("two\n".utf8))
        log.append(Data("three\n".utf8))
        log.close()

        XCTAssertEqual(try lines(of: url), ["two", "three"])
        XCTAssertEqual(log.bytesWritten, 10)
    }

    func testAnUndisturbedFileKeepsItsDescriptorAcrossTheCheck() throws {
        let url = scratch.appendingPathComponent("packets.log")
        let log = AppendingLog(url: url, maxBytes: 1_000_000, verifyEvery: 0)
        log.append(Data("one\n".utf8))
        let first = try inode(of: url)
        for i in 2...50 { log.append(Data("line \(i)\n".utf8)) }
        XCTAssertEqual(try inode(of: url), first)
        XCTAssertEqual(try lines(of: url).count, 50)
    }

    func testAnInheritedLogIsMeasuredFromWhatIsAlreadyThere() throws {
        let url = scratch.appendingPathComponent("packets.log")
        XCTAssertTrue(SafeFile.writeAtomic(Data(repeating: 0x41, count: 500), to: url))
        XCTAssertEqual(AppendingLog(url: url, maxBytes: 1000).bytesWritten, 500)
    }

    private func lines(of url: URL) throws -> [String] {
        let data = try XCTUnwrap(SafeFile.read(url, cap: 1 << 20))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        return text.split(separator: "\n").map(String.init)
    }

    private func inode(of url: URL) throws -> UInt64 {
        var st = stat()
        _ = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &st)
        }
        return UInt64(st.st_ino)
    }

    private func size(of url: URL) throws -> Int {
        try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }
}

final class StageDeviceStoreTests: XCTestCase {
    func testTheProfileMapIsCappedLikeItsCalibrationSibling() {
        var store = StageDeviceStore()
        for i in 0..<200 {
            store.set(StageSettings(), for: "uid-\(String(format: "%03d", i))")
        }
        XCTAssertEqual(store.settings.count, StageDeviceStore.defaultLimit)
        XCTAssertNotNil(store["uid-199"])
        XCTAssertNil(store["uid-000"], "the least recently touched goes first")
    }

    func testTheDeviceInUseSurvivesAFloodOfNewOnes() {
        var store = StageDeviceStore(limit: 4)
        var mine = StageSettings()
        mine.width = 175
        store.set(mine, for: "mine")
        for i in 0..<3 { store.set(StageSettings(), for: "other-\(i)") }
        store.touch("mine")
        for i in 3..<10 { store.set(StageSettings(), for: "other-\(i)") }

        XCTAssertEqual(store.settings.count, 4)
        XCTAssertNil(store["mine"], "ten strangers later it is genuinely the oldest")

        var again = StageDeviceStore(limit: 4)
        again.set(mine, for: "mine")
        for i in 0..<3 { again.set(StageSettings(), for: "other-\(i)") }
        again.touch("mine")
        again.set(StageSettings(), for: "newcomer")
        XCTAssertEqual(again["mine"]?.width, 175,
                       "touched more recently than other-0, so other-0 goes instead")
        XCTAssertNil(again["other-0"])
    }

    func testAnOlderFileWithTooManyDevicesStillOpens() throws {
        var loaded: [String: StageSettings] = [:]
        for i in 0..<300 { loaded["uid-\(String(format: "%03d", i))"] = StageSettings() }
        let store = StageDeviceStore(loaded)
        XCTAssertEqual(store.settings.count, StageDeviceStore.defaultLimit)
        XCTAssertEqual(store.order.count, StageDeviceStore.defaultLimit)
        XCTAssertNotNil(store["uid-299"], "a document records no history, so it is "
                        + "cut in a stable order")
    }

    func testASavedProfileIsFoundAgainAndReplacedInPlace() {
        var store = StageDeviceStore()
        var first = StageSettings()
        first.width = 120
        store.set(first, for: "uid")
        var second = StageSettings()
        second.width = 140
        store.set(second, for: "uid")
        XCTAssertEqual(store.settings.count, 1)
        XCTAssertEqual(store["uid"]?.width, 140)
        XCTAssertEqual(store.order, ["uid"])
    }
}

final class StageStateFileOutcomeTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("stagefile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testNoFileAtAllIsAnEmptySlate() {
        let url = scratch.appendingPathComponent("stage.json")
        guard case .absent = StageStateFile.loadOutcome(url) else {
            return XCTFail("a missing file is not a broken one")
        }
    }

    func testAGoodFileComesBackDecoded() throws {
        let url = scratch.appendingPathComponent("stage.json")
        var state = PersistedStageState()
        state.levelTracking = true
        XCTAssertTrue(SafeFile.writeAtomic(try JSONEncoder().encode(state), to: url))

        guard case .loaded(let back) = StageStateFile.loadOutcome(url) else {
            return XCTFail("a decodable document should load")
        }
        XCTAssertTrue(back.levelTracking)
    }

    func testABrokenFileIsFlaggedAsSuchAndParkedForRecovery() throws {
        let url = scratch.appendingPathComponent("stage.json")
        XCTAssertTrue(SafeFile.writeAtomic(Data("{not json".utf8), to: url))

        guard case .unreadable = StageStateFile.loadOutcome(url) else {
            return XCTFail("settings that exist but cannot be read are not absent")
        }
        let parked = scratch.appendingPathComponent("stage.json.recovered")
        XCTAssertEqual(try XCTUnwrap(SafeFile.read(parked, cap: 1 << 20)),
                       Data("{not json".utf8))
    }

    func testAFileWeRefuseToReadIsNotMistakenForNoFile() throws {
        let url = scratch.appendingPathComponent("stage.json")
        let target = scratch.appendingPathComponent("elsewhere.json")
        XCTAssertTrue(SafeFile.writeAtomic(Data("{}".utf8), to: target))
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

        guard case .unreadable = StageStateFile.loadOutcome(url) else {
            return XCTFail("something is at that path, so it is not an empty slate")
        }
    }
}

final class HeartbeatPrivacyTests: XCTestCase {
    func testTheHeartbeatNeverRecordsTheImpulseFileName() {
        let line = StageState.impulseDiag(
            .ready(name: "kitchen-of-anna-smith.wav", partitions: 4, taps: 8192,
                   hop: 256, rate: 48000),
            mix: 0.75)
        XCTAssertFalse(line.lowercased().contains("anna"))
        XCTAssertFalse(line.contains(".wav"))
        XCTAssertEqual(line, "ir=on/4x256/8192taps/mix0.75")
        XCTAssertEqual(StageState.impulseDiag(.off, mix: 1), "ir=off")
        XCTAssertEqual(StageState.impulseDiag(.refused("nope"), mix: 1), "ir=refused")
    }
}

final class BluetoothDiscoveryGateTests: XCTestCase {
    func testDiscoveryStopsWhileTheCableIsIn() {
        XCTAssertFalse(BLETransport.mayScan(suspended: true, poweredOn: true,
                                            linked: false))
    }

    func testDiscoveryRunsWhenThereIsNoCableAndNoLinkYet() {
        XCTAssertTrue(BLETransport.mayScan(suspended: false, poweredOn: true,
                                           linked: false))
    }

    func testNothingIsScannedForWithTheRadioOffOrALinkAlreadyUp() {
        XCTAssertFalse(BLETransport.mayScan(suspended: false, poweredOn: false,
                                            linked: false))
        XCTAssertFalse(BLETransport.mayScan(suspended: false, poweredOn: true,
                                            linked: true))
    }

    @MainActor
    func testSuspendingAndResumingIsRecordedOnTheTransport() {
        let transport = BLETransport()
        XCTAssertFalse(transport.scanSuspended)
        transport.setScanSuspended(true)
        XCTAssertTrue(transport.scanSuspended)
        transport.setScanSuspended(true)
        XCTAssertTrue(transport.scanSuspended)
        transport.setScanSuspended(false)
        XCTAssertFalse(transport.scanSuspended)
    }
}
