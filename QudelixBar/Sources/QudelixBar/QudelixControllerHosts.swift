import Foundation

extension QudelixController: EqAutomationHost, TuneHost {
    func flushEqSendsBlockingNow() {
        flushEqSendsBlocking()
    }

    var isConnectedNow: Bool {
        if case .connected = connection { return true }
        return false
    }

    var isCompatible: Bool { compatibility == .ok }

    var isOnVoiceLink: Bool {
        (inputSource?.hasPrefix("HFP") ?? false) || sampleRate == "16 kHz"
    }
}
