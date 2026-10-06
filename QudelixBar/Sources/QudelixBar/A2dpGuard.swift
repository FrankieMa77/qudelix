import CoreAudio
import Foundation

struct A2dpGuardMemory: Equatable {
    struct Reverts: Equatable {
        var count = 0
        var last = Date.distantPast
    }

    static let ignoreWindow: TimeInterval = 3600
    static let backoffWindow: TimeInterval = 3600
    static let revertWindow: TimeInterval = 120
    static let revertLimit = 2
    static let notifyInterval: TimeInterval = 300
    static let maxNamesTracked = 64

    private(set) var ignoredAt: [String: Date] = [:]
    private(set) var reverts: [String: Reverts] = [:]
    private(set) var backedOffAt: [String: Date] = [:]
    private(set) var notifiedAt: [String: Date] = [:]
    private(set) var order: [String] = []

    mutating func touch(_ name: String) {
        guard !name.isEmpty else { return }
        order.removeAll { $0 == name }
        order.append(name)
        while order.count > Self.maxNamesTracked {
            let victim = order.removeFirst()
            ignoredAt.removeValue(forKey: victim)
            reverts.removeValue(forKey: victim)
            backedOffAt.removeValue(forKey: victim)
            notifiedAt.removeValue(forKey: victim)
        }
    }

    mutating func ignore(_ name: String, now: Date) {
        touch(name)
        ignoredAt[name] = now
    }

    mutating func isIgnored(_ name: String, now: Date) -> Bool {
        guard let since = ignoredAt[name] else { return false }
        if now.timeIntervalSince(since) < Self.ignoreWindow { return true }
        ignoredAt.removeValue(forKey: name)
        return false
    }

    mutating func backOff(_ name: String, now: Date) {
        touch(name)
        backedOffAt[name] = now
    }

    mutating func clearBackoff(_ name: String) {
        backedOffAt.removeValue(forKey: name)
    }

    mutating func isBackedOff(_ name: String, now: Date) -> Bool {
        guard let since = backedOffAt[name] else { return false }
        if now.timeIntervalSince(since) < Self.backoffWindow { return true }
        backedOffAt.removeValue(forKey: name)
        return false
    }

    mutating func recentReverts(_ name: String, now: Date) -> Int {
        guard let history = reverts[name] else { return 0 }
        if now.timeIntervalSince(history.last) > Self.revertWindow {
            reverts.removeValue(forKey: name)
            return 0
        }
        return history.count
    }

    mutating func recordRevert(_ name: String, now: Date) {
        touch(name)
        var history = reverts[name] ?? Reverts()
        if now.timeIntervalSince(history.last) > Self.revertWindow { history.count = 0 }
        history.count += 1
        history.last = now
        reverts[name] = history
    }

    mutating func allowNotification(_ name: String, now: Date) -> Bool {
        if let last = notifiedAt[name],
           now.timeIntervalSince(last) < Self.notifyInterval { return false }
        touch(name)
        notifiedAt[name] = now
        return true
    }
}

@MainActor
final class A2dpGuard: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case off, ask, fix
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Off"
            case .ask: return "Ask first"
            case .fix: return "Fix automatically"
            }
        }
        var shortLabel: String {
            switch self {
            case .off: return "Off"
            case .ask: return "Ask"
            case .fix: return "Fix"
            }
        }
    }

    enum Reason: Equatable {
        case asking
        case backedOff
        case noBuiltInMic
    }

    struct Hijack: Equatable {
        var id: AudioDeviceID
        var name: String
        var reason: Reason
    }

    enum Action: Equatable {
        case doNothing
        case offer(Reason)
        case fix
    }

    @Published private(set) var mode: Mode = .ask
    @Published private(set) var hijack: Hijack?

    var onModeChange: ((Mode) -> Void)?
    var callActive: () -> Bool = { false }

    private var memory = A2dpGuardMemory()
    private var listener: (AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)?

    func start(mode: Mode) {
        guard listener == nil else { return }
        self.mode = mode

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.check() }
        }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &addr, .main, block)
        listener = (addr, block)

        check()
    }

    func stop() {
        guard let (addr, block) = listener else { return }
        var a = addr
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &a, .main, block)
        listener = nil
    }

    deinit {
        guard let (addr, block) = listener else { return }
        var a = addr
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &a, .main, block)
    }

    nonisolated static func decide(mode: Mode, name: String, hasBuiltInMic: Bool,
                                   callActive: Bool,
                                   memory: inout A2dpGuardMemory,
                                   now: Date) -> Action {
        guard mode != .off else { return .doNothing }
        memory.touch(name)
        if memory.isIgnored(name, now: now) { return .doNothing }
        guard hasBuiltInMic else { return .offer(.noBuiltInMic) }
        guard mode == .fix else { return .offer(.asking) }
        guard !callActive else { return .offer(.asking) }
        if memory.isBackedOff(name, now: now) { return .offer(.backedOff) }
        if memory.recentReverts(name, now: now) >= A2dpGuardMemory.revertLimit {
            memory.backOff(name, now: now)
            return .offer(.backedOff)
        }
        return .fix
    }

    nonisolated static func notificationTitle(reason: Reason, name: String) -> String {
        switch reason {
        case .backedOff: return "Microphone keeps switching to \(name)"
        case .asking, .noBuiltInMic: return "Microphone switched to \(name)"
        }
    }

    nonisolated static func notificationBody(reason: Reason) -> String {
        switch reason {
        case .asking:
            return "Bluetooth playback drops to voice quality while its "
                + "microphone is in use. Open Qudelix to switch back."
        case .backedOff:
            return "Probably a call. Qudelix has stopped switching it back — "
                + "open the app if you want the built-in microphone."
        case .noBuiltInMic:
            return "Playback drops to voice quality, and this Mac has no "
                + "built-in microphone to switch to. Pick another input in "
                + "System Settings."
        }
    }

    nonisolated static func fixedNotificationBody(name: String) -> String {
        "Something switched the microphone to \(name); Qudelix put the "
            + "built-in microphone back so playback stays hi-fi."
    }

    nonisolated static func bannerDetail(reason: Reason, isTheDevice: Bool,
                                         deviceInputSource: String?) -> String {
        switch reason {
        case .noBuiltInMic:
            return "This Mac has no built-in microphone to switch to — pick "
                + "another input in System Settings."
        case .backedOff:
            return "It keeps coming back, so it is being left alone. Switch "
                + "it by hand if you want the built-in microphone."
        case .asking:
            break
        }
        guard isTheDevice else {
            return "Playback drops to voice quality while a Bluetooth "
                + "microphone is in use."
        }
        if let source = deviceInputSource, source.hasPrefix("HFP") {
            return "The 5K dropped to HFP for the microphone — that's why it "
                + "sounds thin."
        }
        return "The 5K's own microphone is in use, so its Bluetooth link "
            + "drops to voice quality."
    }

    nonisolated static func deviceBaseName(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: #"\s+USB DAC(\s+[0-9]+(\.[0-9]+)?\s*KHz)?\s*$"#, with: "",
            options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func isTheDevice(hijackName: String,
                                        connectedName: String?) -> Bool {
        if hijackName.localizedCaseInsensitiveContains("qudelix") { return true }
        guard let connectedName else { return false }
        let trimmed = deviceBaseName(connectedName)
        guard !trimmed.isEmpty else { return false }
        return hijackName.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
    }

    func setMode(_ new: Mode) {
        guard new != mode else { return }
        mode = new
        onModeChange?(new)
        if new == .off {
            hijack = nil
        } else {
            check()
        }
    }

    func check(now: Date = Date()) {
        guard mode != .off,
              let id = AudioOutputs.defaultInputID(),
              AudioOutputs.isBluetooth(id) else {
            if hijack != nil { hijack = nil }
            return
        }
        let scrubbed = SafeText.scrubbed(AudioOutputs.deviceName(id) ?? "", limit: 48)
        let name = scrubbed.isEmpty ? "a Bluetooth microphone" : scrubbed
        let hasMic = AudioOutputs.builtInMicID() != nil

        switch Self.decide(mode: mode, name: name, hasBuiltInMic: hasMic,
                           callActive: callActive(), memory: &memory, now: now) {
        case .doNothing:
            return
        case .offer(let reason):
            offer(id: id, name: name, reason: reason, now: now)
        case .fix:
            if useBuiltInMic() {
                memory.recordRevert(name, now: now)
                notify(name: name, title: "Kept your audio quality",
                       body: Self.fixedNotificationBody(name: name), now: now)
            } else {
                offer(id: id, name: name, reason: .noBuiltInMic, now: now)
            }
        }
    }

    @discardableResult
    func useBuiltInMic() -> Bool {
        guard let builtIn = AudioOutputs.builtInMicID(),
              AudioOutputs.setDefaultInput(builtIn) else { return false }
        if let name = hijack?.name { memory.clearBackoff(name) }
        hijack = nil
        return true
    }

    func ignoreHijack(now: Date = Date()) {
        if let name = hijack?.name { memory.ignore(name, now: now) }
        hijack = nil
    }

    var diagSummary: String {
        let state: String
        switch hijack?.reason {
        case .none: state = "none"
        case .asking: state = "asking"
        case .backedOff: state = "backed-off"
        case .noBuiltInMic: state = "no-built-in-mic"
        }
        return "guard=\(mode.rawValue) hijack=\(state)"
    }

    private func offer(id: AudioDeviceID, name: String, reason: Reason, now: Date) {
        let next = Hijack(id: id, name: name, reason: reason)
        if hijack != next { hijack = next }
        notify(name: name, title: Self.notificationTitle(reason: reason, name: name),
               body: Self.notificationBody(reason: reason), now: now)
    }

    private func notify(name: String, title: String, body: String, now: Date) {
        guard memory.allowNotification(name, now: now) else { return }
        Notifier.shared.post(id: Notifier.identifier("qudelix-mic-guard-", name),
                             title: title, body: body)
    }

    #if DEBUG
    func previewSetHijack(id: AudioDeviceID, name: String, reason: Reason) {
        hijack = Hijack(id: id, name: name, reason: reason)
    }

    func previewSetMode(_ mode: Mode) {
        self.mode = mode
    }
    #endif
}
