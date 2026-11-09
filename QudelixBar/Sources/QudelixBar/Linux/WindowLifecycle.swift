import Foundation

package struct WindowLifecycle: Equatable {
    package enum Effect: Equatable {
        case none
        case show
    }

    package enum Close: Equatable {
        case hide
        case quit
    }

    package static let watcherGrace: TimeInterval = 5

    package private(set) var watcherPresent: Bool?
    package private(set) var visible = false
    package private(set) var waiting = false

    package init() {}

    package mutating func launch(startHidden: Bool) -> Effect {
        guard startHidden else {
            visible = true
            return .show
        }
        waiting = true
        return .none
    }

    package mutating func watcherChanged(_ present: Bool) -> Effect {
        watcherPresent = present
        if waiting, present {
            waiting = false
            return .none
        }
        if !waiting, !present, !visible {
            visible = true
            return .show
        }
        return .none
    }

    package mutating func graceExpired() -> Effect {
        guard waiting else { return .none }
        waiting = false
        visible = true
        return .show
    }

    package mutating func closeRequested() -> Close {
        guard watcherPresent == true else { return .quit }
        visible = false
        return .hide
    }

    package mutating func present() -> Effect {
        waiting = false
        visible = true
        return .show
    }
}
