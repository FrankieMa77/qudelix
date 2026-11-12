import Foundation

package enum AudioSinkTransport: String, Equatable {
    case usb
    case bluetooth
    case other
}

package struct AudioSink: Equatable {
    package var id: UInt32
    package var name: String
    package var description: String
    package var deviceApi: String
    package var deviceBus: String
    package var vendorId: String
    package var productId: String
    package var bluezAddress: String
    package var profile: String

    package init(id: UInt32,
                 name: String,
                 description: String,
                 deviceApi: String = "",
                 deviceBus: String = "",
                 vendorId: String = "",
                 productId: String = "",
                 bluezAddress: String = "",
                 profile: String = "") {
        self.id = id
        self.name = name
        self.description = description
        self.deviceApi = deviceApi
        self.deviceBus = deviceBus
        self.vendorId = vendorId
        self.productId = productId
        self.bluezAddress = bluezAddress
        self.profile = profile
    }

    package var transport: AudioSinkTransport {
        if deviceBus == "usb" { return .usb }
        if deviceBus == "bluetooth" || deviceApi == "bluez5" || !bluezAddress.isEmpty { return .bluetooth }
        return .other
    }

    package var isBluetoothHeadsetProfile: Bool {
        guard transport == .bluetooth else { return false }
        let lowered = profile.lowercased()
        return ["headset", "hfp", "hsp", "head-unit", "handsfree"].contains { lowered.contains($0) }
    }

    package var isStageSink: Bool { name == LinuxAudioNames.stageSinkName }

    package var isQudelix5K: Bool {
        if transport == .usb {
            return Self.normalizedHex(vendorId) == "0a12" && Self.normalizedHex(productId) == "4007"
        }
        return description.lowercased().contains("qudelix")
    }

    private static func normalizedHex(_ text: String) -> String {
        let lowered = text.lowercased()
        return lowered.hasPrefix("0x") ? String(lowered.dropFirst(2)) : lowered
    }
}

package enum LinuxAudioNames {
    package static let stageSinkName = "qudelix_stage"
    package static let stageSinkDescription = "Qudelix Stage"
}

package struct AudioSinkVolume: Equatable {
    package var volume: Float
    package var channelVolume: Float
    package var muted: Bool

    package init(volume: Float, channelVolume: Float, muted: Bool) {
        self.volume = volume
        self.channelVolume = channelVolume
        self.muted = muted
    }

    package var gain: Float { volume * channelVolume }
}

package enum AudioLegState: Equatable {
    case connecting
    case ready
    case streaming
    case failed
}

package struct AudioStreamFormat: Equatable {
    package var rate: Int
    package var channels: Int

    package init(rate: Int, channels: Int) {
        self.rate = rate
        self.channels = channels
    }
}

package enum AudioBackendError: Error, Equatable {
    case unavailable(Int32)
    case streamFailed
}

package typealias AudioCaptureBlock = (UnsafePointer<Float>, Int, Int, Int) -> Void
package typealias AudioRenderBlock = (UnsafePointer<Float>, UnsafeMutablePointer<Float>, Int, Int, Int) -> Void
package typealias AudioToneBlock = (UnsafeMutablePointer<Float>, Int, Int, Int) -> Void

package protocol AudioStreamHandle: AnyObject {
    var isReady: Bool { get }
    var isStreaming: Bool { get }
    var hasFailed: Bool { get }
    var format: AudioStreamFormat? { get }
    var sinkLegFormat: AudioStreamFormat? { get }
    var sinkLegState: AudioLegState { get }
    var playbackLegState: AudioLegState { get }
    var underruns: UInt64 { get }
    var overruns: UInt64 { get }
    func stop()
}

package protocol LinuxAudioBackend: AnyObject {
    var sinks: [AudioSink] { get }
    var defaultSinkName: String? { get }
    var configuredDefaultSinkName: String? { get }
    var forceRate: Int { get }
    var connected: Bool { get }
    var changeHandler: (() -> Void)? { get set }

    func sinkVolume(named name: String) -> AudioSinkVolume?
    func scaleSinkVolume(named name: String, by factor: Float, muted: Bool?) -> Bool
    func setDefaultSink(named name: String?) -> Bool
    func setForceRate(_ rate: Int) -> Bool
    func startMonitor(sink: String, block: @escaping AudioCaptureBlock) throws -> AudioStreamHandle
    func startInsert(target: String, bluetooth: Bool, render: @escaping AudioRenderBlock) throws -> AudioStreamHandle
    func startTone(sink: String, render: @escaping AudioToneBlock) throws -> AudioStreamHandle
    func shutdown()
}

extension LinuxAudioBackend {
    package func startInsert(target: String, render: @escaping AudioRenderBlock) throws -> AudioStreamHandle {
        try startInsert(target: target, bluetooth: false, render: render)
    }
}
