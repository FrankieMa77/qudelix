import Foundation

@MainActor
package protocol AudioDeviceReporting: AnyObject {
    var reportedVolumeDb: Double? { get }
    var reportedActiveCall: Bool? { get }
    var reportedInputSource: String? { get }
    func requestDeviceStatus()
}

extension AppModel: AudioDeviceReporting {
    package var reportedVolumeDb: Double? { state.status?.volumeDb }

    package var reportedActiveCall: Bool? { state.status?.activeCall }

    package var reportedInputSource: String? { state.status?.inputSource }

    package func requestDeviceStatus() {
        Task { @MainActor in await self.refreshStatus() }
    }
}
