import XCTest
@testable import QudelixBar

@MainActor
final class ProfileRulesLinkTests: XCTestCase {
    private var sandbox: URL!

    override func setUp() {
        super.setUp()
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rules-link-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox,
                                                 withIntermediateDirectories: true)
        ProfileRulesFile.urlOverride = sandbox.appendingPathComponent("profiles.json")
    }

    override func tearDown() {
        ProfileRulesFile.urlOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
        sandbox = nil
        super.tearDown()
    }

    private func drain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func rule(group: QxEqGroup, preset: Int = 4) -> ProfileRule {
        ProfileRule(outputUID: "uid-1", outputName: "Studio Cans", presetIndex: preset,
                    eqGroupRaw: group.rawValue, confirmed: true, automatic: true)
    }

    func testTheGroupIsKnownOnlyOnceTheDeviceHasReportedItsMode() async {
        let rig = DeviceRig()
        let rules = ProfileRules()
        let link = ProfileRulesLink(controller: rig.controller, rules: rules)
        XCTAssertNil(rules.currentEqGroupRaw, "nothing is attached, so no group is known")

        await rig.attachUSB()
        rig.controller.debugIngest(Wire.initData())
        await drain()
        XCTAssertNil(rules.currentEqGroupRaw,
                     "the controller's default group is a guess until eq_mode arrives")

        rig.controller.debugIngest(Wire.deviceConfig(eqMode: 1, group: QxEqGroup.b20.rawValue,
                                                     slot: 1))
        await drain()
        XCTAssertEqual(rules.currentEqGroupRaw, QxEqGroup.b20.rawValue)
        withExtendedLifetime(link) {}
    }

    func testATenBandDeviceIsKnownAsTenBandNotLeftUnknown() async {
        let rig = DeviceRig()
        let rules = ProfileRules()
        let link = ProfileRulesLink(controller: rig.controller, rules: rules)

        await rig.connect(group: .user, slot: 1)
        await drain()

        XCTAssertEqual(rules.currentEqGroupRaw, QxEqGroup.user.rawValue)
        withExtendedLifetime(link) {}
    }

    func testALinkDropForgetsTheGroupAndAReconnectLearnsItAgain() async {
        let rig = DeviceRig()
        let rules = ProfileRules()
        let link = ProfileRulesLink(controller: rig.controller, rules: rules)

        await rig.connect(group: .b20, slot: 1)
        await drain()
        XCTAssertEqual(rules.currentEqGroupRaw, QxEqGroup.b20.rawValue)

        await rig.detachUSB()
        await drain()
        XCTAssertNil(rules.currentEqGroupRaw)

        await rig.connect(group: .user, slot: 1)
        await drain()
        XCTAssertEqual(rules.currentEqGroupRaw, QxEqGroup.user.rawValue)
        withExtendedLifetime(link) {}
    }

    func testATwentyBandRuleWaitsForTheDeviceAndThenSwitchesOnce() async {
        let rig = DeviceRig()
        let rules = ProfileRules()
        rules.previewSet(rules: [rule(group: .b20)])
        let link = ProfileRulesLink(controller: rig.controller, rules: rules)

        rules.outputChanged(uid: "uid-1", name: "Studio Cans")
        XCTAssertNotNil(rules.suggestion, "no device yet, so the automatic switch is deferred")

        await rig.connect(group: .b20, slot: 1)
        await drain()

        XCTAssertEqual(rig.controller.activePreset, 4)
        XCTAssertNil(rules.suggestion)
        withExtendedLifetime(link) {}
    }

    func testASwitchDeferredForWantOfAWritableDeviceHappensWhenItBecomesOne() async {
        let rig = DeviceRig()
        let rules = ProfileRules()
        rules.previewSet(rules: [rule(group: .b20)])
        let link = ProfileRulesLink(controller: rig.controller, rules: rules)
        rules.outputChanged(uid: "uid-1", name: "Studio Cans")

        await rig.attachUSB()
        rig.controller.debugIngest(Wire.deviceConfig(eqMode: 1, group: QxEqGroup.b20.rawValue,
                                                     slot: 1))
        await drain()
        XCTAssertEqual(rules.currentEqGroupRaw, QxEqGroup.b20.rawValue)
        XCTAssertFalse(rig.controller.canWriteNow, "the model and firmware have not been checked")
        XCTAssertEqual(rig.controller.activePreset, 1)
        XCTAssertNotNil(rules.suggestion)

        rig.controller.debugIngest(Wire.initData())
        await drain()

        XCTAssertTrue(rig.controller.canWriteNow)
        XCTAssertEqual(rig.controller.activePreset, 4)
        XCTAssertNil(rules.suggestion)
        withExtendedLifetime(link) {}
    }

    func testARuleFromTheOtherBankIsLeftAloneOnceTheRealGroupIsKnown() async {
        let rig = DeviceRig()
        let rules = ProfileRules()
        rules.previewSet(rules: [rule(group: .user)])
        let link = ProfileRulesLink(controller: rig.controller, rules: rules)

        rules.outputChanged(uid: "uid-1", name: "Studio Cans")
        await rig.connect(group: .b20, slot: 1)
        await drain()

        XCTAssertEqual(rig.controller.activePreset, 1, "slot 4 of the 10-band bank is not this bank's")
        XCTAssertNil(rules.suggestion)
        withExtendedLifetime(link) {}
    }

    func testTheKnownGroupHelperNeedsBothTheLinkAndTheReport() {
        XCTAssertNil(ProfileRulesLink.knownGroupRaw(connection: .disconnected,
                                                    modeReported: true, group: .b20))
        XCTAssertNil(ProfileRulesLink.knownGroupRaw(connection: .connected(name: "5K"),
                                                    modeReported: false, group: .b20))
        XCTAssertEqual(ProfileRulesLink.knownGroupRaw(connection: .connected(name: "5K"),
                                                      modeReported: true, group: .b20),
                       QxEqGroup.b20.rawValue)
    }
}
