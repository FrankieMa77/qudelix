import CoreAudio
import XCTest
@testable import QudelixBar

final class A2dpGuardTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let headset = "Studio Wireless HD"

    private func decide(_ mode: A2dpGuard.Mode, _ memory: inout A2dpGuardMemory,
                        at offset: TimeInterval, hasBuiltInMic: Bool = true,
                        callActive: Bool = false,
                        name: String? = nil) -> A2dpGuard.Action {
        A2dpGuard.decide(mode: mode, name: name ?? headset,
                         hasBuiltInMic: hasBuiltInMic, callActive: callActive,
                         memory: &memory, now: epoch.addingTimeInterval(offset))
    }


    func testOffDecidesNothingAndRemembersNothing() {
        var memory = A2dpGuardMemory()
        XCTAssertEqual(decide(.off, &memory, at: 0), .doNothing)
        XCTAssertTrue(memory.order.isEmpty)
    }

    func testAskAlwaysOffersRatherThanActing() {
        var memory = A2dpGuardMemory()
        for offset in stride(from: 0.0, through: 600, by: 60) {
            XCTAssertEqual(decide(.ask, &memory, at: offset), .offer(.asking))
        }
    }

    func testFixActsOnAFreshHijack() {
        var memory = A2dpGuardMemory()
        XCTAssertEqual(decide(.fix, &memory, at: 0), .fix)
    }


    func testTwoRevertsInsideTwoMinutesStopTheThird() {
        var memory = A2dpGuardMemory()
        XCTAssertEqual(decide(.fix, &memory, at: 0), .fix)
        memory.recordRevert(headset, now: epoch)
        XCTAssertEqual(decide(.fix, &memory, at: 30), .fix)
        memory.recordRevert(headset, now: epoch.addingTimeInterval(30))
        XCTAssertEqual(decide(.fix, &memory, at: 60), .offer(.backedOff))
    }

    func testRevertsSpacedWiderThanTheWindowNeverAccumulate() {
        var memory = A2dpGuardMemory()
        for offset in stride(from: 0.0, through: 1200, by: 121) {
            XCTAssertEqual(decide(.fix, &memory, at: offset), .fix, "\(offset)")
            memory.recordRevert(headset, now: epoch.addingTimeInterval(offset))
        }
    }

    func testTheBackoffStaysInEffectForTheWholeHour() {
        var memory = A2dpGuardMemory()
        memory.recordRevert(headset, now: epoch)
        memory.recordRevert(headset, now: epoch.addingTimeInterval(10))
        XCTAssertEqual(decide(.fix, &memory, at: 20), .offer(.backedOff))
        for offset in [30.0, 600, 1800, 3599] {
            XCTAssertEqual(decide(.fix, &memory, at: offset), .offer(.backedOff),
                           "\(offset)")
        }
    }

    func testTheBackoffExpiresAnHourAfterItWasSet() {
        var memory = A2dpGuardMemory()
        memory.recordRevert(headset, now: epoch)
        memory.recordRevert(headset, now: epoch.addingTimeInterval(10))
        XCTAssertEqual(decide(.fix, &memory, at: 20), .offer(.backedOff))
        XCTAssertEqual(decide(.fix, &memory, at: 20 + 3600), .fix)
        XCTAssertNil(memory.backedOffAt[headset])
    }

    func testAskingByHandRetiresTheBackoff() {
        var memory = A2dpGuardMemory()
        memory.backOff(headset, now: epoch)
        XCTAssertTrue(memory.isBackedOff(headset, now: epoch.addingTimeInterval(5)))
        memory.clearBackoff(headset)
        XCTAssertFalse(memory.isBackedOff(headset, now: epoch.addingTimeInterval(5)))
    }


    func testAnIgnoredDeviceIsLeftAloneForAnHour() {
        var memory = A2dpGuardMemory()
        memory.ignore(headset, now: epoch)
        for offset in [1.0, 60, 1800, 3599] {
            XCTAssertEqual(decide(.fix, &memory, at: offset), .doNothing, "\(offset)")
            XCTAssertEqual(decide(.ask, &memory, at: offset), .doNothing, "\(offset)")
        }
    }

    func testTheIgnoreExpiresAndTomorrowsHijackIsHeardAgain() {
        var memory = A2dpGuardMemory()
        memory.ignore(headset, now: epoch)
        XCTAssertEqual(decide(.ask, &memory, at: 3600), .offer(.asking))
        XCTAssertNil(memory.ignoredAt[headset])
    }

    func testIgnoringOneDeviceSaysNothingAboutAnother() {
        var memory = A2dpGuardMemory()
        memory.ignore(headset, now: epoch)
        XCTAssertEqual(decide(.ask, &memory, at: 10, name: "Other Buds"),
                       .offer(.asking))
    }


    func testAnActiveCallDegradesTheAutomaticFixToAnOffer() {
        var memory = A2dpGuardMemory()
        XCTAssertEqual(decide(.fix, &memory, at: 0, callActive: true),
                       .offer(.asking))
        XCTAssertTrue(memory.reverts.isEmpty)
    }

    func testOnceTheCallEndsTheFixIsAllowedAgain() {
        var memory = A2dpGuardMemory()
        XCTAssertEqual(decide(.fix, &memory, at: 0, callActive: true),
                       .offer(.asking))
        XCTAssertEqual(decide(.fix, &memory, at: 5, callActive: false), .fix)
    }


    func testAMacWithoutAMicrophoneDegradesToAskingRatherThanFailingSilently() {
        var memory = A2dpGuardMemory()
        XCTAssertEqual(decide(.fix, &memory, at: 0, hasBuiltInMic: false),
                       .offer(.noBuiltInMic))
        XCTAssertEqual(decide(.ask, &memory, at: 1, hasBuiltInMic: false),
                       .offer(.noBuiltInMic))
    }

    func testAnIgnoredDeviceIsStillIgnoredOnAMacWithoutAMicrophone() {
        var memory = A2dpGuardMemory()
        memory.ignore(headset, now: epoch)
        XCTAssertEqual(decide(.fix, &memory, at: 10, hasBuiltInMic: false),
                       .doNothing)
    }


    func testOneNotificationPerDevicePerFiveMinutes() {
        var memory = A2dpGuardMemory()
        XCTAssertTrue(memory.allowNotification(headset, now: epoch))
        for offset in [1.0, 60, 299] {
            XCTAssertFalse(memory.allowNotification(
                headset, now: epoch.addingTimeInterval(offset)), "\(offset)")
        }
        XCTAssertTrue(memory.allowNotification(
            headset, now: epoch.addingTimeInterval(300)))
    }

    func testTheRateLimitIsPerDeviceNotGlobal() {
        var memory = A2dpGuardMemory()
        XCTAssertTrue(memory.allowNotification(headset, now: epoch))
        XCTAssertTrue(memory.allowNotification("Other Buds", now: epoch))
    }

    func testARefusedNotificationDoesNotPushTheWindowForward() {
        var memory = A2dpGuardMemory()
        XCTAssertTrue(memory.allowNotification(headset, now: epoch))
        XCTAssertFalse(memory.allowNotification(
            headset, now: epoch.addingTimeInterval(299)))
        XCTAssertTrue(memory.allowNotification(
            headset, now: epoch.addingTimeInterval(300)))
    }


    func testTheNameMapsAreCappedAndEvictTheLeastRecentlyUsed() {
        var memory = A2dpGuardMemory()
        let cap = A2dpGuardMemory.maxNamesTracked
        for i in 0..<cap {
            memory.ignore("device-\(i)", now: epoch)
        }
        XCTAssertEqual(memory.order.count, cap)
        XCTAssertNotNil(memory.ignoredAt["device-0"])

        memory.ignore("device-\(cap)", now: epoch)
        XCTAssertEqual(memory.order.count, cap)
        XCTAssertNil(memory.ignoredAt["device-0"])
        XCTAssertNotNil(memory.ignoredAt["device-1"])
        XCTAssertNotNil(memory.ignoredAt["device-\(cap)"])
    }

    func testTouchingAKeepsItAliveThroughTheNextEviction() {
        var memory = A2dpGuardMemory()
        let cap = A2dpGuardMemory.maxNamesTracked
        for i in 0..<cap { memory.ignore("device-\(i)", now: epoch) }
        memory.touch("device-0")
        memory.ignore("device-\(cap)", now: epoch)
        XCTAssertNotNil(memory.ignoredAt["device-0"])
        XCTAssertNil(memory.ignoredAt["device-1"])
    }

    func testEvictionClearsEveryMapKeyedOnTheName() {
        var memory = A2dpGuardMemory()
        memory.ignore("victim", now: epoch)
        memory.backOff("victim", now: epoch)
        memory.recordRevert("victim", now: epoch)
        _ = memory.allowNotification("victim", now: epoch)
        for i in 0..<A2dpGuardMemory.maxNamesTracked {
            memory.touch("device-\(i)")
        }
        XCTAssertFalse(memory.order.contains("victim"))
        XCTAssertNil(memory.ignoredAt["victim"])
        XCTAssertNil(memory.backedOffAt["victim"])
        XCTAssertNil(memory.reverts["victim"])
        XCTAssertNil(memory.notifiedAt["victim"])
    }

    func testAnEmptyNameIsNeverTracked() {
        var memory = A2dpGuardMemory()
        memory.touch("")
        XCTAssertTrue(memory.order.isEmpty)
    }


    func testTheBannerNamesTheCodecWhenTheHijackedMicrophoneIsTheDevice() {
        let line = A2dpGuard.bannerDetail(reason: .asking, isTheDevice: true,
                                          deviceInputSource: "HFP 1")
        XCTAssertTrue(line.contains("HFP"), line)
        XCTAssertTrue(line.contains("5K"), line)
    }

    func testAnUnknownInputSourceStillGetsADeviceSpecificLine() {
        let line = A2dpGuard.bannerDetail(reason: .asking, isTheDevice: true,
                                          deviceInputSource: nil)
        XCTAssertTrue(line.contains("5K"), line)
        XCTAssertFalse(line.contains("HFP"), line)
    }

    func testSomeOtherHeadsetGetsTheGenericLine() {
        let line = A2dpGuard.bannerDetail(reason: .asking, isTheDevice: false,
                                          deviceInputSource: "HFP 1")
        XCTAssertFalse(line.contains("5K"), line)
    }

    func testTheReasonOutranksTheDeviceInTheWording() {
        for reason in [A2dpGuard.Reason.backedOff, .noBuiltInMic] {
            let line = A2dpGuard.bannerDetail(reason: reason, isTheDevice: true,
                                              deviceInputSource: "HFP 1")
            XCTAssertFalse(line.contains("HFP"), line)
        }
    }

    func testTheDeviceIsRecognisedByNameOrByTheConnection() {
        XCTAssertTrue(A2dpGuard.isTheDevice(hijackName: "Qudelix-5K",
                                            connectedName: nil))
        XCTAssertTrue(A2dpGuard.isTheDevice(hijackName: "qudelix 5k",
                                            connectedName: nil))
        XCTAssertTrue(A2dpGuard.isTheDevice(hijackName: "Studio Wireless HD",
                                            connectedName: "Studio Wireless HD USB DAC 96KHz"))
        XCTAssertFalse(A2dpGuard.isTheDevice(hijackName: "Other Buds",
                                             connectedName: "Qudelix-5K"))
        XCTAssertFalse(A2dpGuard.isTheDevice(hijackName: "Other Buds",
                                             connectedName: nil))
    }

    func testEveryReasonHasATitleThatNamesTheDevice() {
        for reason in [A2dpGuard.Reason.asking, .backedOff, .noBuiltInMic] {
            XCTAssertTrue(
                A2dpGuard.notificationTitle(reason: reason, name: headset)
                    .contains(headset))
            XCTAssertFalse(A2dpGuard.notificationBody(reason: reason).isEmpty)
        }
    }


    func testNotificationsAreRefusedWithoutARealAppBundle() {
        XCTAssertFalse(Notifier.canPost(bundleIdentifier: nil,
                                        bundleURL: URL(fileURLWithPath: "/tmp/Qudelix.app")))
        XCTAssertFalse(Notifier.canPost(bundleIdentifier: "pro.wpmagic.qudelixbar",
                                        bundleURL: URL(fileURLWithPath: "/tmp/QudelixBar")))
        XCTAssertTrue(Notifier.canPost(bundleIdentifier: "pro.wpmagic.qudelixbar",
                                       bundleURL: URL(fileURLWithPath: "/tmp/Qudelix.app")))
    }

    func testIdentifiersAreDeterministicScrubbedAndBounded() {
        let hostile = String(repeating: "A", count: 400) + "\u{202E}\n"
        let first = Notifier.identifier("qudelix-mic-guard-", hostile)
        let second = Notifier.identifier("qudelix-mic-guard-", hostile)
        XCTAssertEqual(first, second)
        XCTAssertLessThanOrEqual(first.count, Notifier.maxIdentifierLength)
        XCTAssertFalse(first.contains("\u{202E}"))
        XCTAssertFalse(first.contains("\n"))
    }

    func testEachBatteryAlertKindKeepsItsOwnStableIdentifier() {
        let ids = [BatteryAlerts.Alert.charging(percent: 80).notificationID,
                   BatteryAlerts.Alert.low(percent: 18).notificationID,
                   BatteryAlerts.Alert.veryLow(percent: 7).notificationID]
        XCTAssertEqual(Set(ids).count, 3)
        XCTAssertEqual(BatteryAlerts.Alert.low(percent: 18).notificationID,
                       BatteryAlerts.Alert.low(percent: 4).notificationID)
        for id in ids {
            XCTAssertLessThanOrEqual(id.count, Notifier.maxIdentifierLength)
        }
    }


    func testTheModeSurvivesAJsonRoundTrip() throws {
        for mode in A2dpGuard.Mode.allCases {
            var state = PersistedStageState()
            state.a2dpGuard = mode.rawValue
            let data = try JSONEncoder().encode(state)
            let back = try JSONDecoder().decode(PersistedStageState.self, from: data)
            XCTAssertEqual(A2dpGuard.Mode(rawValue: back.a2dpGuard ?? ""), mode)
        }
    }

    func testADocumentWithoutTheFieldDecodesAndMeansAsk() throws {
        let json = Data(#"{"stageByDevice":{},"exposure":[],"levelTracking":false}"#.utf8)
        let back = try JSONDecoder().decode(PersistedStageState.self, from: json)
        XCTAssertNil(back.a2dpGuard)
        XCTAssertEqual(A2dpGuard.Mode(rawValue: back.a2dpGuard ?? "") ?? .ask, .ask)
    }

    func testAnUnknownModeInTheFileFallsBackToAsk() throws {
        let json = Data(#"{"stageByDevice":{},"exposure":[],"levelTracking":false,"a2dpGuard":"obliterate"}"#.utf8)
        let back = try JSONDecoder().decode(PersistedStageState.self, from: json)
        XCTAssertNil(A2dpGuard.Mode(rawValue: back.a2dpGuard ?? ""))
    }
}
