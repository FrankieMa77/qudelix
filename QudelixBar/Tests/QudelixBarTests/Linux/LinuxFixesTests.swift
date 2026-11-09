#if os(Linux)
import XCTest
import Glibc
@testable import QudelixBar

final class LinuxFixesTests: XCTestCase {
    private var directory: URL!
    private let capture = StdIOCapture()

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qx-fixes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        EqHistoryFile.directoryOverride = directory
        ActiveSlotFile.directoryOverride = directory
        StdIO.outSink = { [capture] in capture.append($0) }
        StdIO.errorSink = { _ in }
    }

    override func tearDown() {
        StdIO.outSink = nil
        StdIO.errorSink = nil
        EqHistoryFile.directoryOverride = nil
        ActiveSlotFile.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func connected(_ link: FakeLink) async throws -> QxSession {
        let session = QxSession(link: link, timeout: 2)
        link.autoConnectOnStart = true
        try await session.connect(timeout: 2)
        return session
    }

    private func status(_ arguments: [String], presetIndex: Int) async -> Int32 {
        let link = QxFixtures.answeringLink(presetIndex: presetIndex)
        link.autoConnectOnStart = true
        return await QudelixCLI.run(arguments: ["--timeout", "2"] + arguments,
                                    makeLinks: { _ in [link] })
    }

    func testNoSlotSentinelReadsAsNoneInText() async {
        let exit = await status(["status"], presetIndex: 255)
        XCTAssertEqual(exit, CLIExit.ok)
        XCTAssertTrue(capture.text.contains("none (live EQ)"))
        XCTAssertFalse(capture.text.contains("256"))
    }

    func testNoSlotSentinelIsNullInJSONAndKeepsTheKey() async throws {
        _ = await status(["status", "--json"], presetIndex: 255)
        let object = capture.object
        XCTAssertTrue(object.keys.contains("preset_slot"))
        XCTAssertTrue(object["preset_slot"] is NSNull)
    }

    func testARealSlotStillPrints() async {
        _ = await status(["status"], presetIndex: 2)
        XCTAssertTrue(capture.text.contains("3 — "))
    }

    func testStatusAsksForTheActiveGroupsPresetAndShowsTheEqType() async {
        let link = QxFixtures.answeringLink()
        link.autoConnectOnStart = true
        _ = await QudelixCLI.run(arguments: ["--timeout", "2", "status"], makeLinks: { _ in [link] })
        XCTAssertGreaterThanOrEqual(link.payloads(for: .reqEqPreset).count, 2)
        XCTAssertTrue(capture.text.contains("eq type"))
        XCTAssertFalse(capture.text.contains("unknown"))
    }

    func testEqTypeLineIsOmittedWhenUnknown() {
        var snapshot = QxStatusSnapshot()
        snapshot.eqType = nil
        XCTAssertFalse(QxFormat.statusLines(snapshot).contains { $0.hasPrefix("eq type") })
    }

    func testChargingTextMatchesTheJSONFlags() {
        var snapshot = QxStatusSnapshot()
        snapshot.chargerConnected = true
        snapshot.charging = false
        let idle = QxFormat.statusLines(snapshot).first { $0.hasPrefix("charging") } ?? ""
        XCTAssertTrue(idle.hasSuffix("no (charger connected)"))
        XCTAssertEqual(QxFormat.statusObject(snapshot)["charging"] as? Bool, false)
        snapshot.charging = true
        let on = QxFormat.statusLines(snapshot).first { $0.hasPrefix("charging") } ?? ""
        XCTAssertTrue(on.hasSuffix("yes"))
        snapshot.chargerConnected = false
        snapshot.charging = false
        let off = QxFormat.statusLines(snapshot).first { $0.hasPrefix("charging") } ?? ""
        XCTAssertTrue(off.hasSuffix("no"))
    }

    func testLoadedSlotShowsInTheSameSessionAndInTheNextOne() async throws {
        let first = try await connected(QxFixtures.answeringLink(presetIndex: 255))
        _ = try await first.loadPreset(index: 5)
        let loaded = await first.snapshot()
        XCTAssertEqual(loaded.activePresetIndex, 5)
        first.close()

        let second = try await connected(QxFixtures.answeringLink(presetIndex: 255))
        _ = try await second.readPreset()
        let again = await second.snapshot()
        XCTAssertEqual(again.activePresetIndex, 5)
        second.close()
    }

    func testLoadedSlotIsForgottenWhenTheLiveEqDiffers() async throws {
        let first = try await connected(QxFixtures.answeringLink(presetIndex: 255))
        _ = try await first.loadPreset(index: 5)
        first.close()
        let other = try await connected(QxFixtures.answeringLink(presetIndex: 255, preGain: -6))
        _ = try await other.readPreset()
        let snapshot = await other.snapshot()
        XCTAssertNil(snapshot.activePresetIndex)
        other.close()
    }

    private func nextStateLine(_ iterator: inout AsyncStream<String>.AsyncIterator) async -> String {
        while let line = await iterator.next() {
            if line.contains("group=") { return line }
        }
        return ""
    }

    private func rememberSlotSix() async throws {
        let first = try await connected(QxFixtures.answeringLink(presetIndex: 255))
        _ = try await first.loadPreset(index: 5)
        first.close()
    }

    func testStatusObjectNamesTheSlotOneBased() {
        var snapshot = QxStatusSnapshot()
        snapshot.activePresetIndex = 0
        XCTAssertEqual(QxFormat.statusObject(snapshot)["preset_slot"] as? Int, 1)
        snapshot.activePresetIndex = 19
        XCTAssertEqual(QxFormat.statusObject(snapshot)["preset_slot"] as? Int, 20)
        snapshot.activePresetIndex = nil
        XCTAssertTrue(QxFormat.statusObject(snapshot)["preset_slot"] is NSNull)
        XCTAssertNil(QxFormat.statusObject(snapshot)["preset_index"])
    }

    func testWatchLineShowsTheRememberedSlotWhenTheLiveEqMatches() async throws {
        try await rememberSlotSix()
        let session = try await connected(QxFixtures.answeringLink(presetIndex: 255))
        defer { session.close() }
        var iterator = session.notifications().makeAsyncIterator()
        _ = try await session.readPreset()
        let line = await nextStateLine(&iterator)
        XCTAssertTrue(line.contains("preset=6"), line)
    }

    func testWatchLineShowsNoneWhenTheLiveEqDiffers() async throws {
        try await rememberSlotSix()
        let session = try await connected(QxFixtures.answeringLink(presetIndex: 255, preGain: -6))
        defer { session.close() }
        var iterator = session.notifications().makeAsyncIterator()
        _ = try await session.readPreset()
        let line = await nextStateLine(&iterator)
        XCTAssertTrue(line.contains("preset=none"), line)
    }

    func testPresetNotificationWithNoSlotStopsClaimingTheRememberedSlot() async throws {
        try await rememberSlotSix()
        let link = QxFixtures.answeringLink(presetIndex: 255)
        let session = try await connected(link)
        defer { session.close() }
        _ = try await session.readPreset()
        var iterator = session.notifications().makeAsyncIterator()
        link.deliver(.rspDevConfig, QxFixtures.eqConfig(presetIndex: 255, enabled: true, nameMask: 0))
        let before = await nextStateLine(&iterator)
        XCTAssertTrue(before.contains("preset=6"), before)
        link.deliver(.notification, [129, 0, 255])
        let notice = await iterator.next()
        XCTAssertEqual(notice, "no preset slot is active")
        link.deliver(.rspDevConfig, QxFixtures.eqConfig(presetIndex: 255, enabled: true, nameMask: 0))
        let after = await nextStateLine(&iterator)
        XCTAssertTrue(after.contains("preset=none"), after)
        let snapshot = await session.snapshot()
        XCTAssertNil(snapshot.activePresetIndex)
    }

    func testFreshPresetAfterANotificationClaimsTheRememberedSlotAgain() async throws {
        try await rememberSlotSix()
        let link = QxFixtures.answeringLink(presetIndex: 255)
        let session = try await connected(link)
        defer { session.close() }
        var iterator = session.notifications().makeAsyncIterator()
        link.deliver(.notification, [129, 0, 255])
        _ = await iterator.next()
        _ = try await session.readPreset()
        let line = await nextStateLine(&iterator)
        XCTAssertTrue(line.contains("preset=6"), line)
    }

    func testPresetNotificationKeepsTheCachedEqForReads() async throws {
        let link = QxFixtures.answeringLink(presetIndex: 255)
        let session = try await connected(link)
        defer { session.close() }
        let before = try await session.readPreset()
        var iterator = session.notifications().makeAsyncIterator()
        link.deliver(.notification, [129, 0, 255])
        _ = await iterator.next()
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.eqType, "PEQ")
        let after = try await session.readPreset()
        XCTAssertEqual(after.preGain, before.preGain)
        XCTAssertEqual(after.bands.count, before.bands.count)
    }

    func testWatchReadsTheLiveEqBeforeStreaming() async throws {
        try await rememberSlotSix()
        let link = QxFixtures.answeringLink(presetIndex: 255)
        link.autoConnectOnStart = true
        let task = Task {
            await QudelixCLI.run(arguments: ["--timeout", "2", "watch"], makeLinks: { _ in [link] })
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        task.cancel()
        XCTAssertGreaterThanOrEqual(link.payloads(for: .reqEqPreset).count, 1)
        XCTAssertTrue(capture.text.contains("preset=6"), capture.text)
    }

    func testLinkDropClearsTheIdentityTheGateJudges() async throws {
        let link = QxFixtures.answeringLink()
        let session = try await connected(link)
        let before = await session.snapshot()
        XCTAssertNotEqual(before.deviceId, 0)
        link.drop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let after = await session.snapshot()
        XCTAssertEqual(after.deviceId, 0)
        do {
            try await session.setVolume(db: -20)
            XCTFail("a dropped link must not be written")
        } catch is QxSessionError {
        }
        session.close()
    }

    func testRefusedWriteLeavesTheCachedStateAlone() async throws {
        var other = QxFixtures.initData
        other[1] = UInt8(QxDeviceModel.qudelix5KPlus)
        let session = try await connected(QxFixtures.answeringLink(initData: other, volumeDb: -12))
        _ = try? await session.setVolume(db: -30)
        _ = try? await session.setMute(true)
        _ = try? await session.setDacFilter(index: 1)
        _ = try? await session.setEqEnabled(false)
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.volumeDb, -12)
        XCTAssertEqual(snapshot.muted, false)
        XCTAssertEqual(snapshot.dacFilterIndex, 3)
        XCTAssertEqual(snapshot.eqEnabled, true)
        session.close()
    }

    func testInstanceLockIsExclusiveUntilReleased() {
        let url = directory.appendingPathComponent("qudelix.lock")
        let first = QxInstanceLock.acquire(at: url)
        XCTAssertNotNil(first)
        XCTAssertNil(QxInstanceLock.acquire(at: url))
        first?.release()
        let again = QxInstanceLock.acquire(at: url)
        XCTAssertNotNil(again)
        again?.release()
    }

    func testAnUnopenableLockFileIsReportedNotIgnored() throws {
        let missing = directory.appendingPathComponent("no-such-dir/qudelix.lock")
        guard case .unavailable(let message) = QxInstanceLock.attempt(at: missing) else {
            return XCTFail("expected unavailable")
        }
        XCTAssertTrue(message.contains(missing.path), message)
        XCTAssertNil(QxInstanceLock.acquire(at: missing))
        XCTAssertEqual(QxInstanceLock.unavailability(at: missing), message)

        let target = directory.appendingPathComponent("target")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent("linked.lock")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        XCTAssertNotNil(QxInstanceLock.unavailability(at: link))

        let free = directory.appendingPathComponent("free.lock")
        XCTAssertNil(QxInstanceLock.unavailability(at: free))
        let held = QxInstanceLock.acquire(at: free)
        XCTAssertNotNil(held)
        guard case .busy = QxInstanceLock.attempt(at: free) else { return XCTFail("expected busy") }
        XCTAssertNil(QxInstanceLock.unavailability(at: free))
        held?.release()
        guard case .acquired(let dummy) = QxInstanceLock.attempt(at: nil) else { return XCTFail() }
        dummy.release()
    }

    func testTheCommandLineExitsWithAnErrorNamingTheLockPathWhenItCannotBeOpened() async throws {
        defer { StdIO.errorSink = nil }
        let lockURL = try XCTUnwrap(QxInstanceLock.defaultURL)
        let target = directory.appendingPathComponent("lock-target")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createSymbolicLink(atPath: lockURL.path, withDestinationPath: target.path)
        defer { try? FileManager.default.removeItem(at: lockURL) }
        let captured = StdIOCapture()
        StdIO.errorSink = { captured.append($0) }
        let link = QxFixtures.answeringLink()
        link.autoConnectOnStart = true
        let exit = await QudelixCLI.run(arguments: ["status"], makeLinks: { _ in [link] })
        XCTAssertEqual(exit, CLIExit.deviceError)
        XCTAssertTrue(captured.text.contains(lockURL.path), captured.text)
        XCTAssertFalse(captured.text.contains("is using the device"))
        XCTAssertFalse(link.started)
    }

    func testASecondInstanceFailsFastWithTheBusyExitCode() async {
        let held = QxInstanceLock.acquire(at: QxInstanceLock.defaultURL)
        XCTAssertNotNil(held)
        defer { held?.release() }
        let link = QxFixtures.answeringLink()
        link.autoConnectOnStart = true
        let exit = await QudelixCLI.run(arguments: ["--timeout", "2", "status"],
                                        makeLinks: { _ in [link] })
        XCTAssertEqual(exit, CLIExit.deviceBusy)
        XCTAssertFalse(link.started)
    }

    func testTheBusyMessageNamesTheApp() async {
        defer { StdIO.errorSink = nil }
        let held = QxInstanceLock.acquire(at: QxInstanceLock.defaultURL)
        XCTAssertNotNil(held)
        defer { held?.release() }
        let captured = StdIOCapture()
        StdIO.errorSink = { captured.append($0) }
        let link = QxFixtures.answeringLink()
        let exit = await QudelixCLI.run(arguments: ["status"], makeLinks: { _ in [link] })
        XCTAssertEqual(exit, CLIExit.deviceBusy)
        XCTAssertTrue(captured.text.contains("another qudelix or the Qudelix app is using the device"))
        XCTAssertTrue(captured.text.contains("close it or wait for it to finish"))
    }

    func testTheLockIsReleasedAfterACommand() async {
        _ = await status(["status"], presetIndex: 2)
        let lock = QxInstanceLock.acquire(at: QxInstanceLock.defaultURL)
        XCTAssertNotNil(lock)
        lock?.release()
    }

    func testTheClosingLogLineIsOnDiskWhenTheCommandReturnsItsStatus() throws {
        let marker = "closing-line-\(UUID().uuidString)"
        DebugLog.shared.log(marker)
        XCTAssertEqual(QudelixCLI.finish(0), 0)
        let url = try XCTUnwrap(DebugLog.shared.fileURL)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(text.contains(marker))
    }

    func testStateDirectoryIsCreatedPrivate() throws {
        let home = directory.appendingPathComponent("state", isDirectory: true).path
        setenv("XDG_STATE_HOME", home, 1)
        defer { unsetenv("XDG_STATE_HOME") }
        let url = try XCTUnwrap(DebugLog.logURL(underTests: false))
        var info = stat()
        XCTAssertEqual(stat(url.deletingLastPathComponent().path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
    }
}
#endif
