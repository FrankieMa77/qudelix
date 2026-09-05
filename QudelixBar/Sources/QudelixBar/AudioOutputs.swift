import CoreAudio
import Foundation

struct AudioOutput: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let sampleRate: Double
    var isBluetooth = false
}

/// Read-only queries against the Core Audio object tree, for the Mac-side
/// audio features (Stage, Level). The 5K protocol never comes through here —
/// as an output device the 5K is just another Core Audio device.
enum AudioOutputs {
    static func outputDevices() -> [AudioOutput] {
        deviceIDs().compactMap { id in
            guard outputChannelCount(id) > 0,
                  let uid: String = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name: String = stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            return AudioOutput(id: id, uid: uid,
                               name: QudelixController.displayName(name),
                               sampleRate: nominalRate(id),
                               isBluetooth: isBluetoothTransport(id))
        }
    }

    static func defaultOutputID() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    /// Live read of a device's nominal rate — for the moment an engine
    /// starts, when a cached value may predate a rate change.
    static func currentNominalRate(_ id: AudioDeviceID) -> Double {
        nominalRate(id)
    }

    /// The discrete sample rates the device offers. Ranges with distinct
    /// min/max (rare for USB audio) contribute their endpoints.
    static func availableNominalRates(_ id: AudioDeviceID) -> [Double] {
        var addr = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(),
                                       count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr
        else { return [] }
        var rates: [Double] = []
        for r in ranges {
            rates.append(r.mMinimum)
            if r.mMaximum != r.mMinimum { rates.append(r.mMaximum) }
        }
        return Array(Set(rates.filter(isPlausibleRate))).sorted()
    }

    /// Ask the device to run at `rate` — the same thing Audio MIDI Setup
    /// does. The change is applied asynchronously by the HAL.
    @discardableResult
    static func setNominalRate(_ id: AudioDeviceID, _ rate: Double) -> Bool {
        guard isPlausibleRate(rate) else { return false }
        var rate = rate
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        return AudioObjectSetPropertyData(id, &addr, 0, nil,
                                          UInt32(MemoryLayout<Float64>.size),
                                          &rate) == noErr
    }

    /// Bit depth of the device's first output stream's physical format —
    /// what actually travels over the wire, not the Float32 client side.
    static func outputBitDepth(_ id: AudioDeviceID) -> Int? {
        var addr = address(kAudioDevicePropertyStreams,
                           scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0,
                                      count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams) == noErr,
              let stream = streams.first else { return nil }
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &fmtAddr, 0, nil, &fmtSize, &asbd) == noErr,
              asbd.mBitsPerChannel > 0 else { return nil }
        return Int(asbd.mBitsPerChannel)
    }

    /// The Core Audio process object for a pid, needed to exclude a process
    /// from a tap.
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                         UInt32(MemoryLayout<pid_t>.size), &pid,
                                         &size, &object) == noErr,
              object != kAudioObjectUnknown else { return nil }
        return object
    }

    static let fallbackRate: Double = 48000

    static func isPlausibleRate(_ rate: Double) -> Bool {
        rate.isFinite && (8000...768_000).contains(rate)
    }

    static func plausibleRate(_ rate: Double) -> Double {
        isPlausibleRate(rate) ? rate : fallbackRate
    }

    static let callModeCeilingHz: Double = 16000

    static func defaultInputID() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    @discardableResult
    static func setDefaultInput(_ id: AudioDeviceID) -> Bool {
        var id = id
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                          &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size),
                                          &id) == noErr
    }

    static func deviceName(_ id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioObjectPropertyName)
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        isBluetoothTransport(id)
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        channelCount(id, scope: kAudioObjectPropertyScopeInput)
    }

    static func builtInMicID() -> AudioDeviceID? {
        deviceIDs().first { id in
            inputChannelCount(id) > 0
                && transportType(id) == kAudioDeviceTransportTypeBuiltIn
        }
    }

    static func isRunningSomewhere(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &running) == noErr,
              size == UInt32(MemoryLayout<UInt32>.size)
        else { return false }
        return running != 0
    }

    static func inputSiblingUID(forOutputUID uid: String) -> String? {
        let suffix = ":output"
        guard uid.hasSuffix(suffix) else { return nil }
        return String(uid.dropLast(suffix.count)) + ":input"
    }

    static func inputSibling(ofOutputUID uid: String, name: String) -> AudioDeviceID? {
        let siblingUID = inputSiblingUID(forOutputUID: uid)
        var sameName: AudioDeviceID?
        var nameIsAmbiguous = false
        for id in deviceIDs() where inputChannelCount(id) > 0 {
            guard let candidate: String = stringProperty(id, kAudioDevicePropertyDeviceUID)
            else { continue }
            if let siblingUID, candidate == siblingUID { return id }
            if isBluetoothTransport(id),
               stringProperty(id, kAudioObjectPropertyName) == name {
                nameIsAmbiguous = sameName != nil
                sameName = id
            }
        }
        return nameIsAmbiguous ? nil : sameName
    }

    static func callModeActive(outputID: AudioDeviceID) -> Bool {
        guard isBluetoothTransport(outputID) else { return false }
        if nominalRate(outputID) <= callModeCeilingHz { return true }
        guard let uid: String = stringProperty(outputID, kAudioDevicePropertyDeviceUID),
              let name: String = stringProperty(outputID, kAudioObjectPropertyName),
              let mic = inputSibling(ofOutputUID: uid, name: name)
        else { return false }
        return isRunningSomewhere(mic)
    }

    // MARK: Plumbing

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0,
                                  count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport) == noErr,
              size == UInt32(MemoryLayout<UInt32>.size)
        else { return 0 }
        return transport
    }

    private static func isBluetoothTransport(_ id: AudioDeviceID) -> Bool {
        let transport = transportType(id)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        channelCount(id, scope: kAudioObjectPropertyScopeOutput)
    }

    private static func channelCount(_ id: AudioDeviceID,
                                     scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr
        else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func nominalRate(_ id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr
        else { return fallbackRate }
        // A driver supplies this, and a virtual one can supply anything. It is
        // validated here rather than where it is used: the same number reaches
        // the DSP designer, which converts it to an Int, and the spectrum
        // analyzer, which counts cells up to it — an infinity traps the first
        // and never terminates the second.
        return plausibleRate(rate)
    }

    /// CoreAudio hands back a retained CFString, so it must go through
    /// Unmanaged.
    private static func stringProperty(_ id: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr,
              let r = ref else { return nil }
        return r.takeRetainedValue() as String
    }
}

/// Keeps the output-device list and the system default output current.
/// CoreAudio fires the listeners on any change; the debounce matters because
/// a single Bluetooth connect surfaces as a burst of change events while the
/// device's streams come up one by one.
@MainActor
final class OutputWatcher: ObservableObject {
    @Published private(set) var devices: [AudioOutput] = []
    @Published private(set) var defaultOutput: AudioOutput?

    var onChange: (() -> Void)?

    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var debounce: DispatchWorkItem?

    func start() {
        guard listeners.isEmpty else { return }
        refresh()

        // Device-list events come in bursts (a Bluetooth connect fires one
        // per stream coming up) and are throttled. A default-output change
        // is a single decisive event and refreshes IMMEDIATELY: anything
        // keyed off the default device (per-device stage settings, the
        // engine's target) must not act on the old default for the length
        // of a throttle window.
        for (selector, immediate) in [(kAudioHardwarePropertyDevices, false),
                                      (kAudioHardwarePropertyDefaultOutputDevice, true)] {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                // Already on the main queue (registered below); hop through
                // the actor to satisfy isolation.
                Task { @MainActor in
                    if immediate { self?.refreshNow() } else { self?.scheduleRefresh() }
                }
            }
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, .main, block)
            listeners.append((addr, block))
        }
    }

    /// Unregister. `listeners` was recorded from the start but never read,
    /// so every watcher left its blocks on the system object for the life of
    /// the process. The two app-scoped watchers live as long as the app so
    /// nothing leaked in practice, but any watcher created and dropped would
    /// have left a permanent registration firing into a dead object.
    func stop() {
        for (addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &a, .main, block)
        }
        listeners.removeAll()
        debounce?.cancel()
        debounce = nil
    }

    deinit {
        // Same removal, without hopping to the actor: the block itself holds
        // `self` weakly, and CoreAudio needs the registration gone now.
        for (addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &a, .main, block)
        }
    }

    /// Re-enumerate immediately, publish, and notify — for events that must
    /// not wait out the throttle.
    func refreshNow() {
        debounce?.cancel()
        debounce = nil
        refresh()
    }

    /// Throttle, not debounce: re-arming on every event would let a flapping
    /// device starve the refresh forever. One pending refresh at a time,
    /// fired a beat after the first event of a burst.
    private func scheduleRefresh() {
        guard debounce == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.debounce = nil
            self?.refresh()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    #if DEBUG
    /// Mock state must survive later refresh calls (a row's onAppear may
    /// ask for fresh rates), or the render harness would show the build
    /// machine's real devices.
    private var previewFrozen = false
    func previewSetDevices(_ list: [AudioOutput], defaultUID: String?) {
        previewFrozen = true
        devices = list
        defaultOutput = list.first { $0.uid == defaultUID } ?? list.first
    }
    #endif

    private func refresh() {
        #if DEBUG
        guard !previewFrozen else { return }
        #endif
        let fresh = AudioOutputs.outputDevices()
        if fresh != devices { devices = fresh }
        let defaultID = AudioOutputs.defaultOutputID()
        let newDefault = fresh.first { $0.id == defaultID }
        if newDefault != defaultOutput { defaultOutput = newDefault }
        // Fire even when everything compares equal: a disconnect-reconnect
        // that settles on identical entries still killed our aggregate, and
        // the state machine needs the event to notice and recover.
        onChange?()
    }
}
