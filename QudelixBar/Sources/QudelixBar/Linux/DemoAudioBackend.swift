import Foundation

package final class DemoAudioBackend: LinuxAudioBackend {
    package static let fiveK = AudioSink(id: 1, name: "qx_demo_5k", description: "Qudelix-5K USB DAC",
                                         deviceApi: "alsa", deviceBus: "usb",
                                         vendorId: "0x0a12", productId: "0x4007")
    package static let speakers = AudioSink(id: 2, name: "qx_demo_speakers", description: "Built-in Audio",
                                            deviceApi: "alsa", deviceBus: "pci")

    package private(set) var sinks: [AudioSink] = [DemoAudioBackend.fiveK, DemoAudioBackend.speakers]
    package private(set) var defaultSinkName: String? = DemoAudioBackend.fiveK.name
    package private(set) var configuredDefaultSinkName: String? = DemoAudioBackend.fiveK.name
    package private(set) var forceRate = 0
    package var connected: Bool { true }
    package var changeHandler: (() -> Void)?

    package init() {}

    package func sinkVolume(named name: String) -> AudioSinkVolume? {
        AudioSinkVolume(volume: 0.5, channelVolume: 1, muted: false)
    }

    package func scaleSinkVolume(named name: String, by factor: Float, muted: Bool?) -> Bool { false }

    package func setDefaultSink(named name: String?) -> Bool { false }

    package func setForceRate(_ rate: Int) -> Bool { false }

    package func startMonitor(sink: String, block: @escaping AudioCaptureBlock) throws -> AudioStreamHandle {
        throw AudioBackendError.streamFailed
    }

    package func startInsert(target: String, render: @escaping AudioRenderBlock) throws -> AudioStreamHandle {
        throw AudioBackendError.streamFailed
    }

    package func startTone(sink: String, render: @escaping AudioToneBlock) throws -> AudioStreamHandle {
        throw AudioBackendError.streamFailed
    }

    package func shutdown() {
        changeHandler = nil
    }
}
