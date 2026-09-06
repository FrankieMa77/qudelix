import AudioToolbox
import CoreAudio
import Foundation

/// Owns the Mac-side capture pipeline behind the Stage and Level features:
///
///   system audio → process tap → aggregate device
///   → render callback (StageProcessor) → the default output device
///
/// Two modes, one recipe:
///
/// - `.insert` (the Stage): the tap mutes the tapped apps' direct render, the
///   callback processes the capture and writes it to the output — the only
///   thing audible is what the callback writes.
/// - `.monitor` (Level tracking on its own): the tap leaves the original
///   audio playing and the callback only meters the capture, writing nothing.
///   Level tracking alone never inserts anything into the audio path.
///
/// The tap is global, so it hears every process except this one — excluding
/// ourselves is not an optimisation, it is what stops our own output (and the
/// Tune tab's tones) from feeding back into the capture.
///
/// The aggregate clocks off the physical device; the tap sub-object runs with
/// drift compensation so capture is resampled onto that clock. That is the
/// mechanism that absorbs rate mismatch between what apps play and what the
/// output runs at.
@MainActor
final class StageEngine: ObservableObject {
    enum Mode: Equatable {
        case insert, monitor
    }

    @Published private(set) var isRunning = false
    @Published private(set) var status = "Off."
    /// Why the last start attempt failed, or nil if nothing is wrong. The
    /// status line has always carried the same sentence, but it also carries
    /// "Off." and "Metering → …", so a view cannot tell a refusal from a
    /// quiet idle by reading it. This one is set only by a failed start and
    /// cleared by the next stop or successful start, which is what lets a
    /// surface show the reason without inventing a problem when there is none.
    @Published private(set) var failure: Failure?
    @Published private(set) var callHold = false
    private(set) var mode: Mode = .insert
    private(set) var holdingDeviceUID: String?

    struct Failure: Equatable {
        /// The full sentence, including what the user can do about it.
        let message: String
        /// A few words for a row with no room for the sentence.
        let summary: String
    }

    let processor = StageProcessor()

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
    /// The device the engine is currently attached to.
    private(set) var runningDeviceUID: String?
    /// The rate the DSP was designed at, read fresh at start.
    private(set) var runningSampleRate: Double?

    struct EngineError: LocalizedError {
        let message: String
        /// The short form for surfaces that have room for a few words and
        /// not a sentence; the long one stays the actionable text.
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
            // stop() first — it clears the failure as part of tearing down,
            // so recording this one has to come after it.
            stop()
            let engineError = error as? EngineError
            failure = Failure(message: error.localizedDescription,
                              summary: engineError?.summary ?? "the engine couldn't start")
            status = error.localizedDescription
            DebugLog.shared.log("stage engine start failed: \(error.localizedDescription)")
        }
    }

    #if DEBUG
    /// Fake the running state for UI rendering. Touches no audio objects.
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
            // A tap can only exist on 14.2+, so the guard can't skip a live one.
            if #available(macOS 14.2, *) {
                for id in tapIDs { AudioHardwareDestroyProcessTap(id) }
            }
            tapIDs.removeAll()
        }
        activeAppPlan = []
        processor.applyAppChains([])
        // The mute belongs to a tone session, but sessions can die with
        // their engine (device vanished). A stopped engine must never leave
        // a mute armed for the next start.
        processor.setMuted(false)
        runningDeviceUID = nil
        runningSampleRate = nil
    }

    private func bringUp(_ device: AudioOutput, mode: Mode) throws {
        guard #available(macOS 14.2, *) else {
            throw EngineError(message: "This feature needs macOS 14.2 or newer.",
                              summary: "needs macOS 14.2 or newer")
        }

        // Excluding ourselves is what stops our own output from feeding back
        // into the capture. If the translation fails there is no safe tap to
        // make: proceeding would silently build a feedback loop through the
        // room combs. Refuse loudly instead.
        guard let own = AudioOutputs.processObject(for: getpid()) else {
            throw EngineError(message: "Couldn't identify this app to the audio "
                + "system, so the engine won't start (it would hear itself). "
                + "Try again, or relaunch the app.",
                summary: "can't exclude this app from the tap")
        }

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
        activeAppPlan = built

        // Design the stage at the rate the device is actually clocked at,
        // read fresh — the watcher's cached value can predate a rate change.
        let rate = AudioOutputs.currentNominalRate(device.id)
        runningSampleRate = rate
        processor.prepare(sampleRate: rate)
        processor.setMonitorOnly(mode == .monitor)
        processor.applyAppChains(built.map(\.chain))

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Qudelix Stage Engine",
            kAudioAggregateDeviceUIDKey: "com.qudelixbar.stage." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: device.uid]
            ],
            kAudioAggregateDeviceTapListKey: subTaps + [
                [kAudioSubTapUIDKey: desc.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey: 1]
            ],
            kAudioAggregateDeviceTapAutoStartKey: 1,
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                  "Creating the audio engine device")

        let processor = self.processor
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
            _, inputData, _, outputData, _ in
            processor.render(input: inputData, output: outputData)
        }, "Installing the render callback")

        try check(AudioDeviceStart(aggregateID, procID), "Starting audio")

        watchCallSignals(of: device)
        if followProcessList { watchProcessList() }
    }

    var onProcessListChange: (() -> Void)?

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
