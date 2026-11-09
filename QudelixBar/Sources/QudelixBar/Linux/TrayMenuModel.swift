import Foundation

package enum TrayAction: Equatable {
    case volumeUp
    case volumeDown
    case toggleMute
    case toggleEq
    case loadPreset(Int)
    case open
    case quit
}

package struct TrayMenuItem: Equatable {
    package enum Check: Equatable {
        case none
        case checkmark(Bool)
        case radio(Bool)
    }

    package var id: Int32
    package var label: String
    package var enabled = true
    package var separator = false
    package var check: Check = .none
    package var action: TrayAction?
    package var children: [TrayMenuItem] = []

    package init(id: Int32, label: String, enabled: Bool = true, separator: Bool = false,
                 check: Check = .none, action: TrayAction? = nil, children: [TrayMenuItem] = []) {
        self.id = id
        self.label = label
        self.enabled = enabled
        self.separator = separator
        self.check = check
        self.action = action
        self.children = children
    }

    package static func separator(_ id: Int32) -> TrayMenuItem {
        TrayMenuItem(id: id, label: "", separator: true)
    }
}

package struct TrayMenu: Equatable {
    package static let rootID: Int32 = 0
    package static let statusID: Int32 = 1
    package static let volumeUpID: Int32 = 2
    package static let volumeDownID: Int32 = 3
    package static let muteID: Int32 = 4
    package static let eqID: Int32 = 5
    package static let presetsID: Int32 = 6
    package static let firstSeparatorID: Int32 = 20
    package static let secondSeparatorID: Int32 = 21
    package static let openID: Int32 = 30
    package static let quitID: Int32 = 31
    package static let presetBaseID: Int32 = 100

    package var items: [TrayMenuItem] = []

    package init(items: [TrayMenuItem] = []) {
        self.items = items
    }

    package func find(_ id: Int32) -> TrayMenuItem? {
        func search(_ list: [TrayMenuItem]) -> TrayMenuItem? {
            for item in list {
                if item.id == id { return item }
                if let hit = search(item.children) { return hit }
            }
            return nil
        }
        return search(items)
    }

    package var lines: [String] {
        func render(_ list: [TrayMenuItem], depth: Int) -> [String] {
            list.flatMap { item -> [String] in
                let pad = String(repeating: "  ", count: depth)
                if item.separator { return [pad + "----"] }
                var marker = ""
                switch item.check {
                case .none: break
                case .checkmark(let on): marker = on ? "[x] " : "[ ] "
                case .radio(let on): marker = on ? "(o) " : "( ) "
                }
                let state = item.enabled ? "" : "  (disabled)"
                return [pad + marker + item.label + state] + render(item.children, depth: depth + 1)
            }
        }
        return render(items, depth: 0)
    }
}

package struct TrayAppearance: Equatable {
    package var iconName: String
    package var title: String
    package var toolTipTitle: String
    package var toolTipText: String
    package var status: String

    package init(iconName: String, title: String, toolTipTitle: String, toolTipText: String, status: String) {
        self.iconName = iconName
        self.title = title
        self.toolTipTitle = toolTipTitle
        self.toolTipText = toolTipText
        self.status = status
    }
}

package enum TrayMenuBuilder {
    package static let iconName = "audio-headphones-symbolic"
    package static let appIconName = AppInfo.identifier + "-symbolic"
    package static let volumeStep = 1.0

    package static func statusLine(for connection: AppConnection) -> String {
        switch connection {
        case .searching: return "Looking for your Qudelix 5K"
        case .connecting: return "Connecting"
        case .busy: return "The device is in use"
        case .noTransport: return "No way to reach the device"
        case .permissionDenied: return "Cannot open the device"
        case .unsupported: return "This device is not supported"
        case .error: return "Could not connect"
        case .connected: return "Connected"
        }
    }

    package static func appearance(connection: AppConnection, status: QxStatusSnapshot?,
                                   iconName: String = TrayMenuBuilder.iconName) -> TrayAppearance {
        guard case .connected = connection, let status else {
            return TrayAppearance(iconName: iconName, title: AppInfo.name,
                                  toolTipTitle: AppInfo.name,
                                  toolTipText: statusLine(for: connection), status: "Active")
        }
        var title = status.modelName == "unknown" ? "Qudelix 5K" : status.modelName
        if let percent = status.batteryPercent { title += " — \(percent)%" }
        var text = "Connected over \(status.linkLabel)"
        if status.charging { text += ", charging" }
        return TrayAppearance(iconName: iconName, title: AppInfo.name, toolTipTitle: title,
                              toolTipText: text, status: "Active")
    }

    package static func menu(connection: AppConnection, status: QxStatusSnapshot?,
                             presets: PresetSlotsState) -> TrayMenu {
        let open = TrayMenuItem(id: TrayMenu.openID, label: "Open Qudelix", action: .open)
        let quit = TrayMenuItem(id: TrayMenu.quitID, label: "Quit", action: .quit)
        guard case .connected = connection, let status else {
            return TrayMenu(items: [
                TrayMenuItem(id: TrayMenu.statusID, label: statusLine(for: connection), enabled: false),
                .separator(TrayMenu.firstSeparatorID),
                open,
                quit
            ])
        }
        let battery = status.batteryPercent == nil ? "Unknown" : status.batteryLabel
        let presetItems = (0..<QudelixController.presetCount).map { index -> TrayMenuItem in
            let slot = presets.slots.first { $0.index == index }
            let name = slot?.name ?? status.activePresetIndex.flatMap { $0 == index ? status.activePresetName : nil }
            let active = slot?.isActive ?? (status.activePresetIndex == index)
            return TrayMenuItem(id: TrayMenu.presetBaseID + Int32(index),
                                label: "\(index + 1). \(QxFormat.presetLabel(index, name))",
                                check: .radio(active), action: .loadPreset(index))
        }
        return TrayMenu(items: [
            TrayMenuItem(id: TrayMenu.statusID, label: "Battery: \(battery)", enabled: false),
            .separator(TrayMenu.firstSeparatorID),
            TrayMenuItem(id: TrayMenu.volumeUpID, label: "Volume up", action: .volumeUp),
            TrayMenuItem(id: TrayMenu.volumeDownID, label: "Volume down", action: .volumeDown),
            TrayMenuItem(id: TrayMenu.muteID, label: "Mute", check: .checkmark(status.muted ?? false),
                         action: .toggleMute),
            TrayMenuItem(id: TrayMenu.eqID, label: "Equalizer", check: .checkmark(status.eqEnabled ?? false),
                         action: .toggleEq),
            TrayMenuItem(id: TrayMenu.presetsID, label: "Preset", children: presetItems),
            .separator(TrayMenu.secondSeparatorID),
            open,
            quit
        ])
    }
}

@MainActor
package final class TrayModel {
    private unowned let model: AppModel
    private let onOpen: () -> Void
    private let onQuit: () -> Void
    private var observers: [Int: (TrayModel) -> Void] = [:]
    private var nextObserverID = 0
    private let iconName: String
    private var presetState = PresetSlotsState()

    package private(set) var menu = TrayMenu()
    package private(set) var appearance = TrayAppearance(iconName: TrayMenuBuilder.iconName, title: AppInfo.name,
                                                          toolTipTitle: AppInfo.name, toolTipText: "", status: "Active")

    package init(model: AppModel, iconName: String = TrayMenuBuilder.iconName,
                 open: @escaping () -> Void, quit: @escaping () -> Void) {
        self.model = model
        self.iconName = iconName
        self.onOpen = open
        self.onQuit = quit
        rebuild()
        model.addObserver { [weak self] _ in self?.changed() }
        model.presets.addObserver { [weak self] state in
            self?.presetState = state
            self?.changed()
        }
    }

    @discardableResult
    package func addObserver(_ observer: @escaping (TrayModel) -> Void) -> Int {
        nextObserverID += 1
        observers[nextObserverID] = observer
        observer(self)
        return nextObserverID
    }

    package func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    private func rebuild() {
        let state = model.state
        menu = TrayMenuBuilder.menu(connection: state.connection, status: state.status, presets: presetState)
        appearance = TrayMenuBuilder.appearance(connection: state.connection, status: state.status, iconName: iconName)
    }

    private func changed() {
        let before = (menu, appearance)
        rebuild()
        guard before.0 != menu || before.1 != appearance else { return }
        for observer in observers.values { observer(self) }
    }

    package func perform(_ action: TrayAction) {
        let status = model.state.status
        switch action {
        case .volumeUp:
            if let volume = status?.volumeDb { model.setVolume(db: volume + TrayMenuBuilder.volumeStep) }
        case .volumeDown:
            if let volume = status?.volumeDb { model.setVolume(db: volume - TrayMenuBuilder.volumeStep) }
        case .toggleMute:
            model.setMute(!(status?.muted ?? false))
        case .toggleEq:
            model.setEqEnabled(!(status?.eqEnabled ?? false))
        case .loadPreset(let index):
            model.presets.load(slot: index)
        case .open:
            onOpen()
        case .quit:
            onQuit()
        }
    }

    package func perform(itemID: Int32) {
        guard let item = menu.find(itemID), item.enabled, let action = item.action else { return }
        perform(action)
    }
}
