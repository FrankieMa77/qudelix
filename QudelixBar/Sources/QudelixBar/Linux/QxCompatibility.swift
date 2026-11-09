import Foundation

enum QxCompatibility {
    static func refusal(for state: QxDeviceState) -> String? {
        if let format = state.initFormat, format != 3 {
            return "this firmware reports an unknown data format, so nothing will be written"
        }
        guard state.deviceId != 0, let major = state.fwMajor else {
            return "the device has not identified itself yet, so nothing will be written"
        }
        if state.deviceId != QxDeviceModel.qudelix5K {
            return "\(QxDeviceModel.name(for: state.deviceId)) is not supported, so nothing will be written"
        }
        if major < 2 {
            return "firmware \(state.fwVersion ?? "?") is too old, so nothing will be written"
        }
        if major == 2 {
            return "firmware \(state.fwVersion ?? "2.x") uses a different protocol, so nothing will be written"
        }
        return nil
    }

    static func isRequest(_ cmd: QxCmd) -> Bool {
        switch cmd {
        case .reqInitData, .reqDevConfig, .reqDevStatus, .reqEqPreset, .reqEqPresetName:
            return true
        default:
            return false
        }
    }
}
