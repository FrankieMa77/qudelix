import CoreAudio
import Foundation

final class TimedCache<Value> {
    private let lock = NSLock()
    private var held: (value: Value, at: TimeInterval)?
    private let ttl: TimeInterval
    private let now: () -> TimeInterval

    init(ttl: TimeInterval,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.ttl = ttl
        self.now = now
    }

    func value(_ produce: () -> Value) -> Value {
        let stamp = now()
        lock.lock()
        if let held, stamp >= held.at, stamp - held.at < ttl {
            let fresh = held.value
            lock.unlock()
            return fresh
        }
        lock.unlock()
        let produced = produce()
        lock.lock()
        held = (produced, stamp)
        lock.unlock()
        return produced
    }

    func invalidate() {
        lock.lock()
        held = nil
        lock.unlock()
    }
}

final class OutputVolumeCache {
    private var held: (id: AudioDeviceID, db: Float?, at: TimeInterval)?
    private let maxAge: TimeInterval
    private let missMaxAge: TimeInterval
    private let now: () -> TimeInterval

    init(maxAge: TimeInterval = 30, missMaxAge: TimeInterval = 5,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.maxAge = maxAge
        self.missMaxAge = missMaxAge
        self.now = now
    }

    func value(for id: AudioDeviceID, read: (AudioDeviceID) -> Float?) -> Float? {
        let stamp = now()
        if let held, held.id == id, stamp >= held.at,
           stamp - held.at < (held.db == nil ? missMaxAge : maxAge) {
            return held.db
        }
        let db = read(id)
        held = (id, db, stamp)
        return db
    }

    func invalidate() {
        held = nil
    }
}

struct AudioOutput: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let sampleRate: Double
    var isBluetooth = false
}

enum AudioOutputs {
    static func outputDevices() -> [AudioOutput] {
        deviceIDs().compactMap { id in
            guard outputChannelCount(id) > 0,
                  let uid: String = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  !StageEngine.isEngineDevice(uid: uid),
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

    static func currentNominalRate(_ id: AudioDeviceID) -> Double {
        nominalRate(id)
    }

    static func nominalRateIfReadable(_ id: AudioObjectID) -> Double? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr,
              isPlausibleRate(rate) else { return nil }
        return rate
    }

    @available(macOS 14.2, *)
    static func tapFormatRate(_ tapID: AudioObjectID) -> Double? {
        var addr = address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr,
              isPlausibleRate(asbd.mSampleRate) else { return nil }
        return asbd.mSampleRate
    }

    static func availableNominalRates(_ id: AudioDeviceID) -> [Double] {
        var addr = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
              let count = elementCount(size, of: AudioValueRange.self) else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        size = UInt32(count * MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr
        else { return [] }
        var rates: [Double] = []
        for r in ranges {
            rates.append(r.mMinimum)
            if r.mMaximum != r.mMinimum { rates.append(r.mMaximum) }
        }
        return Array(Set(rates.filter(isPlausibleRate))).sorted()
    }

    @discardableResult
    static func setNominalRate(_ id: AudioDeviceID, _ rate: Double) -> Bool {
        guard isPlausibleRate(rate) else { return false }
        var rate = rate
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        return AudioObjectSetPropertyData(id, &addr, 0, nil,
                                          UInt32(MemoryLayout<Float64>.size),
                                          &rate) == noErr
    }

    static func inputStreamCount(_ id: AudioObjectID) -> Int {
        var addr = address(kAudioDevicePropertyStreams,
                           scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
              let count = elementCount(size, of: AudioStreamID.self) else { return 0 }
        return min(count, maxStreamsPerScope)
    }

    static func streamUsageBytes(ioProc: UnsafeMutableRawPointer?,
                                 usage: [UInt32]) -> [UInt8] {
        let procOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>
            .offset(of: \.mIOProc) ?? 0
        let countOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>
            .offset(of: \.mNumberStreams) ?? MemoryLayout<UnsafeMutableRawPointer>.size
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>
            .offset(of: \.mStreamIsOn) ?? countOffset + MemoryLayout<UInt32>.size
        var bytes = [UInt8](repeating: 0,
                            count: flagsOffset + usage.count * MemoryLayout<UInt32>.size)
        bytes.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: ioProc, toByteOffset: procOffset,
                           as: UnsafeMutableRawPointer?.self)
            raw.storeBytes(of: UInt32(usage.count), toByteOffset: countOffset,
                           as: UInt32.self)
            for (index, flag) in usage.enumerated() {
                raw.storeBytes(of: flag,
                               toByteOffset: flagsOffset + index * MemoryLayout<UInt32>.size,
                               as: UInt32.self)
            }
        }
        return bytes
    }

    static func setInputStreamUsage(_ device: AudioObjectID,
                                    ioProc: AudioDeviceIOProcID,
                                    usage: [UInt32]) -> OSStatus {
        guard !usage.isEmpty else { return kAudioHardwareBadPropertySizeError }
        var addr = address(kAudioDevicePropertyIOProcStreamUsage,
                           scope: kAudioObjectPropertyScopeInput)
        let bytes = streamUsageBytes(
            ioProc: unsafeBitCast(ioProc, to: UnsafeMutableRawPointer.self),
            usage: usage)
        return bytes.withUnsafeBytes {
            AudioObjectSetPropertyData(device, &addr, 0, nil,
                                       UInt32(bytes.count), $0.baseAddress!)
        }
    }

    static func inputStreamUsage(_ device: AudioObjectID,
                                 ioProc: AudioDeviceIOProcID,
                                 streams: Int) -> [UInt32]? {
        guard streams > 0 else { return nil }
        var addr = address(kAudioDevicePropertyIOProcStreamUsage,
                           scope: kAudioObjectPropertyScopeInput)
        var bytes = streamUsageBytes(
            ioProc: unsafeBitCast(ioProc, to: UnsafeMutableRawPointer.self),
            usage: [UInt32](repeating: 0, count: streams))
        var size = UInt32(bytes.count)
        let status = bytes.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return nil }
        return parseStreamUsage(bytes)
    }

    static func parseStreamUsage(_ bytes: [UInt8]) -> [UInt32]? {
        let countOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>
            .offset(of: \.mNumberStreams) ?? MemoryLayout<UnsafeMutableRawPointer>.size
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>
            .offset(of: \.mStreamIsOn) ?? countOffset + MemoryLayout<UInt32>.size
        guard bytes.count >= flagsOffset else { return nil }
        let count = bytes.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: countOffset, as: UInt32.self)
        }
        guard count <= UInt32(maxStreamsPerScope),
              bytes.count >= flagsOffset + Int(count) * MemoryLayout<UInt32>.size
        else { return nil }
        return bytes.withUnsafeBytes { raw in
            (0..<Int(count)).map {
                raw.loadUnaligned(
                    fromByteOffset: flagsOffset + $0 * MemoryLayout<UInt32>.size,
                    as: UInt32.self)
            }
        }
    }

    static let maxStreamsPerScope = 4096

    static func outputBitDepth(_ id: AudioDeviceID) -> Int? {
        var addr = address(kAudioDevicePropertyStreams,
                           scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
              let count = elementCount(size, of: AudioStreamID.self) else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: count)
        size = UInt32(count * MemoryLayout<AudioStreamID>.size)
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

    static let processCacheTTL: TimeInterval = 0.5

    static let processCache = TimedCache<[RunningAudioProcess]>(ttl: processCacheTTL)

    static func invalidateProcessCache() { processCache.invalidate() }

    static func audioProcesses() -> [RunningAudioProcess] {
        processCache.value { readAudioProcesses() }
    }

    private static func readAudioProcesses() -> [RunningAudioProcess] {
        guard #available(macOS 14.2, *) else { return [] }
        var out: [RunningAudioProcess] = []
        for object in processObjectList() {
            guard let bundle: String = stringProperty(object, kAudioProcessPropertyBundleID),
                  !bundle.isEmpty else { continue }
            out.append(RunningAudioProcess(
                bundleID: AppAssignments.clampedBundleID(bundle),
                pid: processPID(object),
                object: object,
                playing: isRunningOutput(object)))
        }
        return out
    }

    private static func processPID(_ object: AudioObjectID) -> pid_t {
        var addr = address(kAudioProcessPropertyPID)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &pid) == noErr
        else { return -1 }
        return pid
    }

    private static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var addr = address(kAudioProcessPropertyIsRunningOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }

    private static func processObjectList() -> [AudioObjectID] {
        objectList(kAudioHardwarePropertyProcessObjectList, cap: maxProcessObjects)
    }

    static func outputVolume(_ id: AudioDeviceID) -> Float? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &addr) == false { addr.mElement = 1 }
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &volume) == noErr
        else { return nil }
        return volume
    }

    static func outputVolumeDbRaw(_ id: AudioDeviceID) -> Float? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeDecibels,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &addr) == false { addr.mElement = 1 }
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var db: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &db) == noErr
        else { return nil }
        return db
    }

    static func outputVolumeDb(_ id: AudioDeviceID) -> Float? {
        trustedVolumeDb(db: outputVolumeDbRaw(id), scalar: outputVolume(id))
    }

    static let fullVolumeScalar: Float = 0.995

    static func trustedVolumeDb(db: Float?, scalar: @autoclosure () -> Float?) -> Float? {
        guard let db, EarLevel.plausibleVolumeDb.contains(Double(db)) else { return nil }
        guard db == 0, let scalar = scalar(),
              scalar.isFinite, scalar >= 0, scalar < fullVolumeScalar else { return db }
        return max(20 * log10f(scalar), Float(EarLevel.plausibleVolumeDb.lowerBound))
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

    static func outputAtCallRate(_ outputID: AudioDeviceID) -> Bool {
        isBluetoothTransport(outputID) && nominalRate(outputID) <= callModeCeilingHz
    }

    static func headsetMicID(forOutput outputID: AudioDeviceID) -> AudioDeviceID? {
        guard isBluetoothTransport(outputID),
              let uid: String = stringProperty(outputID, kAudioDevicePropertyDeviceUID),
              let name: String = stringProperty(outputID, kAudioObjectPropertyName)
        else { return nil }
        return inputSibling(ofOutputUID: uid, name: name)
    }

    static func headsetMicRunning(outputID: AudioDeviceID) -> Bool {
        headsetMicID(forOutput: outputID).map(isRunningSomewhere) ?? false
    }

    static func callModeActive(outputID: AudioDeviceID) -> Bool {
        outputAtCallRate(outputID) || headsetMicRunning(outputID: outputID)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        objectList(kAudioHardwarePropertyDevices, cap: maxDevices)
    }

    private static func objectList(_ selector: AudioObjectPropertySelector,
                                   cap: Int) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr,
              let count = elementCount(size, of: AudioObjectID.self) else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: count)
        size = UInt32(count * MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr
        else { return [] }
        return Array(objects.prefix(cap))
    }

    static let maxPropertyBytes: UInt32 = 1 << 20

    static let maxProcessObjects = 512
    static let maxDevices = 512

    static func elementCount<T>(_ size: UInt32, of type: T.Type) -> Int? {
        guard size > 0, size <= maxPropertyBytes else { return nil }
        let count = Int(size) / MemoryLayout<T>.size
        return count > 0 ? count : nil
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
        return plausibleRate(rate)
    }

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

@MainActor
final class OutputWatcher: ObservableObject {
    @Published private(set) var devices: [AudioOutput] = []
    @Published private(set) var defaultOutput: AudioOutput?

    var onChange: (() -> Void)?

    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var debounce: DispatchWorkItem?
    private let volumeCache = OutputVolumeCache()
    var watchesVolume = false
    private var volumeDevice: AudioDeviceID?
    private var volumeListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    func systemVolumeDb(of output: AudioOutput) -> Float? {
        volumeCache.value(for: output.id) { AudioOutputs.outputVolumeDb($0) }
    }

    private func watchVolume(of device: AudioOutput?) {
        guard device?.id != volumeDevice else { return }
        unwatchVolume()
        volumeCache.invalidate()
        volumeDevice = device?.id
        guard let device else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.volumeCache.invalidate() }
        }
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyVolumeDecibels] {
            for element in [kAudioObjectPropertyElementMain, 1, 2] {
                var addr = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeOutput,
                    mElement: element)
                guard AudioObjectHasProperty(device.id, &addr),
                      AudioObjectAddPropertyListenerBlock(device.id, &addr, .main, block)
                        == noErr else { continue }
                volumeListeners.append((addr, block))
            }
        }
    }

    private func unwatchVolume() {
        guard let device = volumeDevice else { return }
        for (addr, block) in volumeListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(device, &a, .main, block)
        }
        volumeListeners.removeAll()
        volumeDevice = nil
    }

    func start() {
        guard listeners.isEmpty else { return }
        refresh()

        for (selector, immediate) in [(kAudioHardwarePropertyDevices, false),
                                      (kAudioHardwarePropertyDefaultOutputDevice, true)] {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
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

    func stop() {
        for (addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &a, .main, block)
        }
        listeners.removeAll()
        unwatchVolume()
        debounce?.cancel()
        debounce = nil
    }

    deinit {
        for (addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &a, .main, block)
        }
        if let device = volumeDevice {
            for (addr, block) in volumeListeners {
                var a = addr
                AudioObjectRemovePropertyListenerBlock(device, &a, .main, block)
            }
        }
    }

    func refreshNow() {
        debounce?.cancel()
        debounce = nil
        refresh()
    }

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
        if watchesVolume { watchVolume(of: newDefault) }
        onChange?()
    }
}
