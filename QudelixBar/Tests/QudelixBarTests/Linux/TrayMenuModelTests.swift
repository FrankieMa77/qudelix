import XCTest
@testable import QudelixBar

final class TrayMenuBuilderTests: XCTestCase {
    private func status(percent: Int? = 76, charging: Bool = false, charger: Bool = false,
                        muted: Bool = false, eq: Bool = true, preset: Int? = 5,
                        presetName: String? = "Harman target") -> QxStatusSnapshot {
        var snapshot = QxStatusSnapshot()
        snapshot.modelName = "Qudelix 5K"
        snapshot.batteryPercent = percent
        snapshot.charging = charging
        snapshot.chargerConnected = charger
        snapshot.volumeDb = -18
        snapshot.muted = muted
        snapshot.eqEnabled = eq
        snapshot.activePresetIndex = preset
        snapshot.activePresetName = presetName
        return snapshot
    }

    private func presets(active: Int? = 5) -> PresetSlotsState {
        var state = PresetSlotsState()
        state.ready = true
        state.activeIndex = active
        state.slots = (0..<20).map {
            PresetSlot(index: $0, name: $0 == 1 ? "Warm" : ($0 == 5 ? "Harman target" : nil), isActive: $0 == active)
        }
        return state
    }

    private func connected(_ snapshot: QxStatusSnapshot, slots: PresetSlotsState? = nil) -> TrayMenu {
        TrayMenuBuilder.menu(connection: .connected(.usb), status: snapshot, presets: slots ?? presets())
    }

    func testDisconnectedIsOneDisabledLineThenOpenAndQuit() {
        let cases: [(AppConnection, String)] = [
            (.searching, "Looking for your Qudelix 5K"),
            (.connecting, "Connecting"),
            (.busy, "The device is in use"),
            (.noTransport(nil), "No way to reach the device"),
            (.permissionDenied("x"), "Cannot open the device"),
            (.unsupported("old"), "This device is not supported"),
            (.error("boom"), "Could not connect")
        ]
        for (connection, line) in cases {
            let menu = TrayMenuBuilder.menu(connection: connection, status: nil, presets: PresetSlotsState())
            XCTAssertEqual(menu.items.map(\.label), [line, "", "Open Qudelix", "Quit"])
            XCTAssertEqual(menu.items.map(\.enabled), [false, true, true, true])
            XCTAssertEqual(menu.items.map(\.separator), [false, true, false, false])
            XCTAssertEqual(menu.items.compactMap(\.action), [.open, .quit])
        }
    }

    func testConnectedLayoutAndOrder() {
        let menu = connected(status())
        XCTAssertEqual(menu.items.map(\.label),
                       ["Battery: 76%", "", "Volume up", "Volume down", "Mute", "Equalizer", "Preset", "",
                        "Open Qudelix", "Quit"])
        XCTAssertEqual(menu.items.map(\.id), [1, 20, 2, 3, 4, 5, 6, 21, 30, 31])
        XCTAssertFalse(menu.items[0].enabled)
        XCTAssertEqual(menu.items.compactMap(\.action), [.volumeUp, .volumeDown, .toggleMute, .toggleEq, .open, .quit])
        XCTAssertEqual(Set(menu.items.map(\.id)).count, menu.items.count)
    }

    func testBatteryLineFollowsTheChargeState() {
        XCTAssertEqual(connected(status(charging: true, charger: true)).items[0].label,
                       "Battery: 76% — plugged in, charging")
        XCTAssertEqual(connected(status(charger: true)).items[0].label, "Battery: 76% — plugged in, not charging")
        XCTAssertEqual(connected(status(percent: nil)).items[0].label, "Battery: Unknown")
    }

    func testMuteAndEqualizerCarryTheirState() {
        let on = connected(status(muted: true, eq: false))
        XCTAssertEqual(on.find(TrayMenu.muteID)?.check, .checkmark(true))
        XCTAssertEqual(on.find(TrayMenu.eqID)?.check, .checkmark(false))
        let off = connected(status(muted: false, eq: true))
        XCTAssertEqual(off.find(TrayMenu.muteID)?.check, .checkmark(false))
        XCTAssertEqual(off.find(TrayMenu.eqID)?.check, .checkmark(true))
    }

    func testPresetSubmenuHasTwentyRadioItemsWithOneActive() {
        let menu = connected(status())
        let submenu = menu.find(TrayMenu.presetsID)?.children ?? []
        XCTAssertEqual(submenu.count, 20)
        XCTAssertEqual(submenu[1].label, "2. Warm")
        XCTAssertEqual(submenu[0].label, "1. Preset 1")
        XCTAssertEqual(submenu[5].label, "6. Harman target")
        XCTAssertEqual(submenu.filter { $0.check == .radio(true) }.map(\.id), [105])
        XCTAssertEqual(submenu.compactMap(\.action), (0..<20).map { .loadPreset($0) })
        XCTAssertEqual(submenu.map(\.id), (100..<120).map { Int32($0) })
        XCTAssertNotNil(menu.find(105))
    }

    func testPresetSubmenuBeforeTheSlotsAreReadUsesTheStatusPreset() {
        let menu = connected(status(), slots: PresetSlotsState())
        let submenu = menu.find(TrayMenu.presetsID)?.children ?? []
        XCTAssertEqual(submenu.count, 20)
        XCTAssertEqual(submenu[5].label, "6. Harman target")
        XCTAssertEqual(submenu[5].check, .radio(true))
        XCTAssertEqual(submenu.filter { $0.check == .radio(true) }.count, 1)
        XCTAssertTrue(connected(status(preset: nil, presetName: nil), slots: PresetSlotsState())
            .find(TrayMenu.presetsID)!.children.allSatisfy { $0.check == .radio(false) })
    }

    func testTheTextDumpListsEveryItem() {
        let lines = connected(status(muted: true)).lines
        XCTAssertEqual(lines.first, "Battery: 76%  (disabled)")
        XCTAssertTrue(lines.contains("[x] Mute"))
        XCTAssertTrue(lines.contains("[x] Equalizer"))
        XCTAssertTrue(lines.contains("  (o) 6. Harman target"))
        XCTAssertTrue(lines.contains("  ( ) 1. Preset 1"))
        XCTAssertEqual(lines.last, "Quit")
        XCTAssertEqual(lines.filter { $0 == "----" }.count, 2)
    }

    func testTheAppIconIsUsedWhenGiven() {
        XCTAssertEqual(TrayMenuBuilder.appIconName, "io.github.FrankieMa77.Qudelix-symbolic")
        let named = TrayMenuBuilder.appearance(connection: .connected(.usb), status: status(),
                                               iconName: TrayMenuBuilder.appIconName)
        XCTAssertEqual(named.iconName, TrayMenuBuilder.appIconName)
        let away = TrayMenuBuilder.appearance(connection: .searching, status: nil,
                                              iconName: TrayMenuBuilder.appIconName)
        XCTAssertEqual(away.iconName, TrayMenuBuilder.appIconName)
    }

    func testTooltipShowsModelAndBattery() {
        let appearance = TrayMenuBuilder.appearance(connection: .connected(.usb), status: status())
        XCTAssertEqual(appearance.toolTipTitle, "Qudelix 5K — 76%")
        XCTAssertEqual(appearance.toolTipText, "Connected over USB")
        XCTAssertEqual(appearance.iconName, "audio-headphones-symbolic")
        XCTAssertEqual(appearance.status, "Active")
        var bluetooth = status(charging: true)
        bluetooth.linkKind = .bluetooth
        let charging = TrayMenuBuilder.appearance(connection: .connected(.bluetooth), status: bluetooth)
        XCTAssertEqual(charging.toolTipText, "Connected over Bluetooth, charging")
        XCTAssertEqual(TrayMenuBuilder.appearance(connection: .connected(.usb), status: status(percent: nil)).toolTipTitle,
                       "Qudelix 5K")
        let away = TrayMenuBuilder.appearance(connection: .searching, status: nil)
        XCTAssertEqual(away.toolTipTitle, "Qudelix")
        XCTAssertEqual(away.toolTipText, "Looking for your Qudelix 5K")
    }
}

final class TrayModelTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tray-model-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActiveSlotFile.directoryOverride = directory
        EqHistoryFile.directoryOverride = directory
    }

    override func tearDown() {
        ActiveSlotFile.directoryOverride = nil
        EqHistoryFile.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    @MainActor
    private func until(_ what: String, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    private func connectedDemo(opened: @escaping () -> Void = {}, quit: @escaping () -> Void = {})
        async -> (AppModel, TrayModel) {
        let model = AppModel.demo()
        let tray = TrayModel(model: model, open: opened, quit: quit)
        model.start()
        await until("connected") {
            model.state.connection.isConnected && model.presets.state.slots.count == 20
                && model.presets.state.slots[2].name != nil
        }
        return (model, tray)
    }

    @MainActor
    func testTheMenuFollowsTheModelThroughEveryStateChange() async {
        let model = AppModel.demo()
        let tray = TrayModel(model: model, open: {}, quit: {})
        var notifications = 0
        tray.addObserver { _ in notifications += 1 }
        XCTAssertEqual(tray.menu.items.map(\.label), ["Looking for your Qudelix 5K", "", "Open Qudelix", "Quit"])
        model.start()
        await until("connected") { model.state.connection.isConnected && model.presets.state.ready }
        XCTAssertEqual(tray.menu.items[0].label, "Battery: 76%")
        XCTAssertEqual(tray.menu.find(TrayMenu.muteID)?.check, .checkmark(false))
        XCTAssertEqual(tray.menu.find(105)?.check, .radio(true))
        XCTAssertEqual(tray.appearance.toolTipTitle, "Qudelix 5K — 76%")
        let seen = notifications
        model.setMute(true)
        await model.waitForIdle()
        await until("mute shown") { tray.menu.find(TrayMenu.muteID)?.check == .checkmark(true) }
        XCTAssertGreaterThan(notifications, seen)
        model.setEqEnabled(false)
        await model.waitForIdle()
        await until("eq shown") { tray.menu.find(TrayMenu.eqID)?.check == .checkmark(false) }
        await model.shutdown()
        XCTAssertEqual(tray.menu.items.map(\.label), ["Looking for your Qudelix 5K", "", "Open Qudelix", "Quit"])
    }

    @MainActor
    func testVolumeMuteEqAndPresetActionsDriveTheModel() async {
        let (model, tray) = await connectedDemo()
        let start = model.state.status?.volumeDb ?? 0
        tray.perform(.volumeDown)
        await model.waitForIdle()
        XCTAssertEqual(model.state.status?.volumeDb ?? 0, start - 1, accuracy: 0.05)
        tray.perform(.volumeUp)
        tray.perform(.volumeUp)
        await model.waitForIdle()
        XCTAssertEqual(model.state.status?.volumeDb ?? 0, start + 1, accuracy: 0.05)
        tray.perform(.toggleMute)
        await model.waitForIdle()
        XCTAssertEqual(model.state.status?.muted, true)
        tray.perform(.toggleMute)
        await model.waitForIdle()
        XCTAssertEqual(model.state.status?.muted, false)
        tray.perform(.toggleEq)
        await model.waitForIdle()
        XCTAssertEqual(model.state.status?.eqEnabled, false)
        tray.perform(itemID: TrayMenu.presetBaseID + 1)
        await until("preset loaded") { model.state.status?.activePresetIndex == 1 }
        await until("radio moved") { tray.menu.find(101)?.check == .radio(true) }
        XCTAssertEqual(tray.menu.find(105)?.check, .radio(false))
        await model.shutdown()
    }

    @MainActor
    func testOpenQuitAndDisabledItems() async {
        var opened = 0
        var quit = 0
        let (model, tray) = await connectedDemo(opened: { opened += 1 }, quit: { quit += 1 })
        tray.perform(itemID: TrayMenu.openID)
        XCTAssertEqual(opened, 1)
        tray.perform(itemID: TrayMenu.statusID)
        tray.perform(itemID: 999)
        tray.perform(itemID: TrayMenu.presetsID)
        XCTAssertEqual(quit, 0)
        tray.perform(itemID: TrayMenu.quitID)
        XCTAssertEqual(quit, 1)
        await model.shutdown()
        tray.perform(.volumeUp)
        tray.perform(.toggleMute)
        await model.waitForIdle()
        XCTAssertNil(model.state.status)
    }
}
