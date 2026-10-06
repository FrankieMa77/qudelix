import AudioToolbox
import CoreAudio
import Foundation

@MainActor
final class StageEngine: ObservableObject {
    enum Mode: Equatable {
        case insert, monitor
    }

    @Published private(set) var isRunning = false
    @Published private(set) var status = "Off."
    @Published private(set) var failure: Failure?
    @Published private(set) var callHold = false
    private(set) var mode: Mode = .insert
    private(set) var holdingDeviceUID: String?

    struct Failure: Equatable {
        let message: String
        let summary: String
    }

    let processor = StageProcessor()

    nonisolated static let aggregateName = "Qudelix Stage Engine"
    nonisolated static let aggregateUIDPrefix = "com.qudelixbar.stage."

    nonisolated static func makeAggregateUID() -> String {
        aggregateUIDPrefix + UUID().uuidString
    }

    nonisolated static func isEngineDevice(uid: String) -> Bool {
        uid.hasPrefix(aggregateUIDPrefix)
    }

    struct AppTapEntry: Equatable {
        var bundleID: String
        var objects: [AudioObjectID]
        var chain: AppCurve
    }

    var appTapPlan: [AppTapEntry] = []
    var followProcessList = false

    private(set) var activeAppPlan: [AppTapEntry] = []

    var activeAppTaps: [String] { activeAppPlan.map(\.bundleID) }

    nonisolated static func sameTaps(_ a: [AppTapEntry], _ b: [AppTapEntry]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy {
            $0.bundleID == $1.bundleID && $0.objects == $1.objects
        }
    }

    private var tapIDs: [AudioObjectID] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var runningDeviceUID: String?
    private(set) var runningSampleRate: Double?
    private(set) var outputRateAtStart: Double?

    struct EngineError: LocalizedError {
        let message: String
        let summary: String
        var errorDescription: String? { message }
    }

    func start(output device: AudioOutput, mode: Mode) {
        guard !isRunning else { return }
        self.mode = mode
        if callHold {
            unwatchCallSignals()
            callHold = false
            holdingDeviceUID = nil
        }
        if AudioOutputs.callModeActive(outputID: device.id) {
            beginHold(on: device)
            return
        }
        do {
            try bringUp(device, mode: mode)
            runningDeviceUID = device.uid
            isRunning = true
            failure = nil
            status = String(format: "%@ → %@ @ %g kHz",
                            mode == .insert ? "Stage active" : "Metering",
                            device.name,
                            (runningSampleRate ?? device.sampleRate) / 1000)
        } catch {
            stop()
            let engineError = error as? EngineError
            failure = Failure(message: error.localizedDescription,
                              summary: engineError?.summary ?? "the engine couldn't start")
            status = error.localizedDescription
            DebugLog.shared.log("stage engine start failed: \(error.localizedDescription)")
        }
    }

    #if DEBUG
    func previewSetRunning(_ running: Bool, status: String, failure: Failure? = nil) {
        isRunning = running
        self.status = status
        self.failure = failure
    }
    #endif

    func stop() {
        unwatchCallSignals()
        tearDownPipeline()
        failure = nil
        let wasActive = isRunning || callHold
        isRunning = false
        callHold = false
        holdingDeviceUID = nil
        if wasActive { status = "Off." }
    }

    func holdForCall(output device: AudioOutput) {
        guard !callHold || holdingDeviceUID != device.uid else { return }
        tearDownPipeline()
        isRunning = false
        beginHold(on: device)
    }

    private func beginHold(on device: AudioOutput) {
        watchCallSignals(of: device)
        holdingDeviceUID = device.uid
        callHold = true
        failure = nil
        status = "Paused for a call — resumes when the call ends."
    }

    private func tearDownPipeline() {
        unwatchProcessList()
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if !tapIDs.isEmpty {
            if #available(macOS 14.2, *) {
                for id in tapIDs { AudioHardwareDestroyProcessTap(id) }
            }
            tapIDs.removeAll()
        }
        activeAppPlan = []
        processor.applyAppChains([])
        processor.setMuted(false)
        runningDeviceUID = nil
        runningSampleRate = nil
        outputRateAtStart = nil
    }

    private func bringUp(_ device: AudioOutput, mode: Mode) throws {
        guard #available(macOS 14.2, *) else {
            throw EngineError(message: "This feature needs macOS 14.2 or newer.",
                              summary: "needs macOS 14.2 or newer")
        }

        guard let own = AudioOutputs.processObject(for: getpid()) else {
            throw EngineError(message: "Couldn't identify this app to the audio "
                + "system, so the engine won't start (it would hear itself). "
                + "Try again, or relaunch the app.",
                summary: "can't exclude this app from the tap")
        }

        let rate = AudioOutputs.currentNominalRate(device.id)
        outputRateAtStart = rate
        runningSampleRate = rate
        processor.prepare(sampleRate: rate)
        processor.setMonitorOnly(mode == .monitor)

        let set = try createTaps(mode: mode, excluding: own)
        activeAppPlan = set.built
        processor.applyAppChains(set.built.map(\.chain))

        let taps = set.tapList
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.aggregateName,
            kAudioAggregateDeviceUIDKey: Self.makeAggregateUID(),
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: taps,
            kAudioAggregateDeviceTapAutoStartKey: 1,
        ]
        var created: OSStatus = kAudioHardwareUnspecifiedError
        if mode == .monitor {
            created = AudioHardwareCreateAggregateDevice(description as CFDictionary,
                                                        &aggregateID)
            drivesOutputDevice = created != noErr
            if created != noErr {
                aggregateID = AudioObjectID(kAudioObjectUnknown)
                DebugLog.shared.log("tap-only monitor device refused (\(fourCC(created))); "
                                    + "falling back to driving the output")
            }
        }
        if created != noErr {
            description[kAudioAggregateDeviceMainSubDeviceKey] = device.uid
            description[kAudioAggregateDeviceSubDeviceListKey] = [
                [kAudioSubDeviceUIDKey: device.uid]
            ]
            created = AudioHardwareCreateAggregateDevice(description as CFDictionary,
                                                         &aggregateID)
            drivesOutputDevice = true
        }
        try check(created, "Creating the audio engine device")

        let engineRate = Self.designRate(
            output: rate,
            aggregate: AudioOutputs.nominalRateIfReadable(aggregateID),
            tap: tapIDs.last.flatMap { AudioOutputs.tapFormatRate($0) })
        if engineRate.mismatch {
            DebugLog.shared.log(String(format:
                "engine device rate differs from the output's %g kHz — designing at %g kHz",
                rate / 1000, engineRate.rate / 1000))
        }
        if engineRate.rate != rate {
            runningSampleRate = engineRate.rate
            processor.prepare(sampleRate: engineRate.rate)
        }

        let processor = self.processor
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
            _, inputData, _, outputData, _ in
            processor.render(input: inputData, output: outputData)
        }, "Installing the render callback")

        if drivesOutputDevice, let installed = procID {
            try closeOutputInputs(of: device, procID: installed)
        }

        try check(AudioDeviceStart(aggregateID, procID), "Starting audio")

        watchCallSignals(of: device)
        if followProcessList { watchProcessList() }
    }

    @available(macOS 14.2, *)
    private func createTaps(mode: Mode, excluding own: AudioObjectID) throws
        -> (built: [AppTapEntry], tapList: [[String: Any]]) {
        var excluded: [AudioObjectID] = [own]
        var subTaps: [[String: Any]] = []
        var built: [AppTapEntry] = []
        if mode == .insert {
            for (index, entry) in appTapPlan.prefix(AppAssignments.maxAssignments)
                .enumerated() where !entry.objects.isEmpty {
                let appDesc = CATapDescription(stereoMixdownOfProcesses: entry.objects)
                appDesc.name = "Qudelix app tap \(index + 1)"
                appDesc.isPrivate = true
                appDesc.muteBehavior = .mutedWhenTapped
                var id = AudioObjectID(kAudioObjectUnknown)
                guard AudioHardwareCreateProcessTap(appDesc, &id) == noErr,
                      id != kAudioObjectUnknown else { continue }
                tapIDs.append(id)
                subTaps.append([kAudioSubTapUIDKey: appDesc.uuid.uuidString,
                                kAudioSubTapDriftCompensationKey: 1])
                built.append(entry)
                excluded.append(contentsOf: entry.objects)
            }
        }

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.name = "Qudelix stage tap"
        desc.isPrivate = true
        desc.muteBehavior = mode == .insert ? .mutedWhenTapped : .unmuted

        var catchAllID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &catchAllID),
                  "Creating the system audio tap")
        tapIDs.append(catchAllID)
        let tapList = subTaps + [
            [kAudioSubTapUIDKey: desc.uuid.uuidString,
             kAudioSubTapDriftCompensationKey: 1]
        ]
        return (built, tapList)
    }

    nonisolated static func designRate(output: Double, aggregate: Double?,
                                       tap: Double?) -> (rate: Double, mismatch: Bool) {
        let tolerance = 0.5
        let witnesses = [aggregate, tap].compactMap { $0 }
            .filter(AudioOutputs.isPlausibleRate)
        guard let first = witnesses.first,
              witnesses.contains(where: { abs($0 - output) > tolerance })
        else { return (output, false) }
        let agree = witnesses.allSatisfy { abs($0 - first) <= tolerance }
        return (agree ? first : output, true)
    }

    enum InputClosePlan: Equatable {
        case nothingToClose
        case close(usage: [UInt32])
        case unmappable
    }

    nonisolated static func inputClosePlan(deviceInputStreams: Int,
                                           engineInputStreams: Int) -> InputClosePlan {
        guard deviceInputStreams > 0 else { return .nothingToClose }
        guard engineInputStreams >= deviceInputStreams else { return .unmappable }
        return .close(usage: [UInt32](repeating: 0, count: deviceInputStreams)
                      + [UInt32](repeating: 1,
                                 count: engineInputStreams - deviceInputStreams))
    }

    nonisolated static func usageHonoured(requested: [UInt32],
                                          readBack: [UInt32]?) -> Bool {
        guard let readBack else { return true }
        return readBack.map { $0 != 0 } == requested.map { $0 != 0 }
    }

    private func closeOutputInputs(of device: AudioOutput,
                                   procID installed: AudioDeviceIOProcID) throws {
        let deviceStreams = AudioOutputs.inputStreamCount(device.id)
        let engineStreams = AudioOutputs.inputStreamCount(aggregateID)
        switch Self.inputClosePlan(deviceInputStreams: deviceStreams,
                                   engineInputStreams: engineStreams) {
        case .nothingToClose:
            return
        case .unmappable:
            DebugLog.shared.log("engine device exposes \(engineStreams) input stream(s) "
                                + "but the output alone has \(deviceStreams)")
            throw Self.microphoneRefusal("the stream layout was not what the engine expected")
        case .close(let usage):
            let status = AudioOutputs.setInputStreamUsage(aggregateID, ioProc: installed,
                                                          usage: usage)
            guard status == noErr else {
                DebugLog.shared.log("input stream usage refused (\(fourCC(status)))")
                throw Self.microphoneRefusal("the system refused the stream setting")
            }
            let readBack = AudioOutputs.inputStreamUsage(aggregateID, ioProc: installed,
                                                         streams: usage.count)
            guard Self.usageHonoured(requested: usage, readBack: readBack) else {
                DebugLog.shared.log("input stream usage did not stick: asked \(usage), "
                                    + "got \(readBack ?? [])")
                throw Self.microphoneRefusal("the setting did not take effect")
            }
            DebugLog.shared.log("output's microphone kept closed: "
                                + "\(deviceStreams) input stream(s) off, "
                                + "\(engineStreams - deviceStreams) left for taps")
        }
    }

    nonisolated static func microphoneRefusal(_ detail: String) -> EngineError {
        EngineError(message: "This output has a microphone, and the engine couldn't "
            + "keep it closed (\(detail)), so it won't start rather than open one.",
            summary: "can't keep the output's microphone closed")
    }

    var onProcessListChange: (() -> Void)?

    private(set) var drivesOutputDevice = true

    static let processListQuiet: TimeInterval = 1

    private var processListener: AudioObjectPropertyListenerBlock?
    private var pendingProcessListChange: DispatchWorkItem?

    private static func processListAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func watchProcessList() {
        unwatchProcessList()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.scheduleProcessListChange() }
        }
        var addr = Self.processListAddress()
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &addr, .main, block)
        processListener = block
    }

    private func unwatchProcessList() {
        pendingProcessListChange?.cancel()
        pendingProcessListChange = nil
        guard let block = processListener else { return }
        var addr = Self.processListAddress()
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &addr, .main, block)
        processListener = nil
    }

    private func scheduleProcessListChange() {
        pendingProcessListChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingProcessListChange = nil
            self?.onProcessListChange?()
        }
        pendingProcessListChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.processListQuiet,
                                      execute: work)
    }

    nonisolated static func tapPlan(assignments: [ResolvedAssignment],
                                    runningProcesses: [RunningAudioProcess],
                                    selfPID: pid_t,
                                    limit: Int = AppAssignments.maxAssignments)
        -> [AppTapEntry] {
        var wanted: [String: LibraryPreset] = [:]
        for entry in assignments {
            guard let preset = entry.preset, wanted[entry.bundleID] == nil else { continue }
            wanted[entry.bundleID] = preset
        }
        guard !wanted.isEmpty, limit > 0 else { return [] }
        var grouped: [String: Set<AudioObjectID>] = [:]
        for process in runningProcesses {
            guard process.pid != selfPID, wanted[process.bundleID] != nil else { continue }
            grouped[process.bundleID, default: []].insert(process.object)
        }
        var out: [AppTapEntry] = []
        for bundleID in grouped.keys.sorted() {
            guard let preset = wanted[bundleID] else { continue }
            let objects = Array(grouped[bundleID, default: []].sorted()
                .prefix(AppAssignments.maxProcessObjectsPerApp))
            guard !objects.isEmpty else { continue }
            out.append(AppTapEntry(
                bundleID: bundleID, objects: objects,
                chain: AppCurve(bundleID: bundleID, preGain: preset.preGain,
                                bands: preset.bands)))
            if out.count == limit { break }
        }
        return out
    }

    var onDeviceConfigurationChange: (() -> Void)?

    private var rateListener: (device: AudioDeviceID,
                               block: AudioObjectPropertyListenerBlock)?
    private var micListener: (device: AudioDeviceID,
                              block: AudioObjectPropertyListenerBlock)?
    private var pendingConfigurationChange: DispatchWorkItem?
    private var configChangeBurstStart: Date?

    private static func rateAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func runningAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func watchCallSignals(of device: AudioOutput) {
        unwatchCallSignals()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.scheduleConfigurationChange() }
        }
        var rateAddr = Self.rateAddress()
        AudioObjectAddPropertyListenerBlock(device.id, &rateAddr, .main, block)
        rateListener = (device.id, block)

        guard device.isBluetooth,
              let mic = AudioOutputs.inputSibling(ofOutputUID: device.uid,
                                                  name: device.name)
        else { return }
        let micBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.scheduleConfigurationChange() }
        }
        var runAddr = Self.runningAddress()
        AudioObjectAddPropertyListenerBlock(mic, &runAddr, .main, micBlock)
        micListener = (mic, micBlock)
    }

    private func unwatchCallSignals() {
        pendingConfigurationChange?.cancel()
        pendingConfigurationChange = nil
        configChangeBurstStart = nil
        if let listener = rateListener {
            var addr = Self.rateAddress()
            AudioObjectRemovePropertyListenerBlock(listener.device, &addr, .main,
                                                   listener.block)
            rateListener = nil
        }
        if let listener = micListener {
            var addr = Self.runningAddress()
            AudioObjectRemovePropertyListenerBlock(listener.device, &addr, .main,
                                                   listener.block)
            micListener = nil
        }
    }

    private func scheduleConfigurationChange() {
        let now = Date()
        let burstStart = configChangeBurstStart ?? now
        configChangeBurstStart = burstStart
        let wait = Self.coalesceWait(sinceBurstStart: now.timeIntervalSince(burstStart))
        pendingConfigurationChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingConfigurationChange = nil
            self?.configChangeBurstStart = nil
            self?.onDeviceConfigurationChange?()
        }
        pendingConfigurationChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    nonisolated static func coalesceWait(sinceBurstStart: TimeInterval,
                                         quiet: TimeInterval = 0.4,
                                         burstCap: TimeInterval = 1.5) -> TimeInterval {
        min(quiet, max(burstCap - sinceBurstStart, 0))
    }

    private func check(_ err: OSStatus, _ what: String) throws {
        guard err != noErr else { return }
        throw EngineError(message: "\(what) failed (\(fourCC(err))). "
            + "If this is a permission problem, allow System Audio Recording for "
            + "Qudelix in System Settings → Privacy & Security.",
            summary: "\(what.lowercased()) failed")
    }

    private func fourCC(_ err: OSStatus) -> String {
        let n = UInt32(bitPattern: err)
        let bytes = [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF),
                     UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
           let s = String(bytes: bytes, encoding: .ascii) {
            return "'\(s)'"
        }
        return String(err)
    }
}
