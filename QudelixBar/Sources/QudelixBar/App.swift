import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

final class InstanceLock {
    static let fileName = "instance.lock"

    enum Claim {
        case held(InstanceLock)
        case taken(by: pid_t?)
        case unavailable
    }

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    static func claim(at url: URL, patience: TimeInterval = 0) -> Claim {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { return .unavailable }
        let deadline = Date().addingTimeInterval(patience)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else {
                close(descriptor)
                return .unavailable
            }
            if Date() >= deadline {
                let holder = holderPID(descriptor)
                close(descriptor)
                return .taken(by: holder)
            }
            usleep(50_000)
        }
        let mine = Array("\(getpid())\n".utf8)
        _ = ftruncate(descriptor, 0)
        _ = pwrite(descriptor, mine, mine.count, 0)
        return .held(InstanceLock(descriptor: descriptor))
    }

    private static func holderPID(_ descriptor: Int32) -> pid_t? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        let text = String(decoding: buffer.prefix(count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return pid_t(text)
    }
}

enum SingleInstance {
    private static var held: InstanceLock?
    static let patience: TimeInterval = 3

    static func admit(at url: URL, patience: TimeInterval) -> Bool {
        switch InstanceLock.claim(at: url, patience: patience) {
        case .held(let lock):
            held = lock
            return true
        case .taken(let pid):
            let who = pid.map { "process \($0)" } ?? "another process"
            DebugLog.shared.log("second copy refused: \(who) already has Qudelix running "
                + "against the same files — exiting without opening anything")
            DebugLog.shared.flush()
            return false
        case .unavailable:
            DebugLog.shared.log("instance lock unavailable — running without the "
                + "second-copy guard")
            return true
        }
    }

    static func enforce() {
        let url = StageStateFile.directory.appendingPathComponent(InstanceLock.fileName)
        if !admit(at: url, patience: patience) { exit(0) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    struct Wiring {
        let content: AnyView
        let controller: QudelixController
        let stageState: StageState
        let profileRules: ProfileRules
        let presetLibrary: PresetLibrary
        let appAssignments: AppAssignments
        let headphoneSuggestions: HeadphoneSuggestions
        let aiStudio: AIPresetStudio
        let abTuner: ABTuner
        let toneTester: ToneTester
        let blindTuner: BlindTuner
        let a2dpGuard: A2dpGuard
    }

    static var makeStatusUI: (() -> Wiring)?
    private static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var wiring: Wiring?
    private let iconModel = StatusIconModel()
    private var sources: Set<AnyCancellable> = []
    private var profileRulesLink: ProfileRulesLink?
    private var started = false
    private var lastDeviceOnCall: Bool?

    func applicationWillTerminate(_ notification: Notification) {
        guard let w = wiring else { return }
        w.a2dpGuard.stop()
        if w.abTuner.phase == .running || w.abTuner.phase == .finished {
            w.abTuner.cancel(w.controller)
        }
        if w.toneTester.phase == .running {
            w.toneTester.stop(w.controller)
        }
        if w.blindTuner.phase != .idle {
            w.blindTuner.cancel(w.controller)
        }
        w.controller.flushEqSnapshot()
        Self.flushPendingWrites(batteryLog: w.controller.batteryLog,
                                presetLibrary: w.presetLibrary)
        w.stageState.saveNow()
        w.stageState.engine.stop()
    }

    static func flushPendingWrites(batteryLog: BatteryLog, presetLibrary: PresetLibrary) {
        batteryLog.appWillTerminate()
        presetLibrary.flushPendingWrites()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        guard !started, let wiring = Self.makeStatusUI?() else { return }
        started = true
        self.wiring = wiring
        buildStatusUI(wiring)
        startServices(wiring)
    }

    private func startServices(_ w: Wiring) {
        w.controller.start()
        w.stageState.deviceCallState = { [weak controller = w.controller] in
            guard let controller else { return nil }
            return (controller.activeCall, controller.inputSource)
        }
        w.stageState.requestDeviceStatus = { [weak controller = w.controller] in
            controller?.refreshStatus()
        }
        w.stageState.releaseHeadsetMicrophone = { [weak guardian = w.a2dpGuard] in
            guard let id = AudioOutputs.defaultInputID(), AudioOutputs.isBluetooth(id)
            else { return false }
            return guardian?.useBuiltInMic() ?? false
        }
        w.stageState.guardDiagnostics = { [weak guardian = w.a2dpGuard] in
            guardian?.diagSummary ?? "guard=off hijack=none"
        }
        w.stageState.aiDiagnostics = { [weak studio = w.aiStudio] in
            studio?.diagSummary ?? "ai=idle"
        }
        w.stageState.qudelixVolumeDb = { [weak controller = w.controller] in
            controller?.reportedVolumeDb
        }
        w.stageState.deviceEqCurve = { [weak controller = w.controller] in
            guard let controller, controller.eqEnabled else { return nil }
            guard case .connected = controller.connection else { return nil }
            return controller.bands
        }
        w.stageState.start()

        w.a2dpGuard.callActive = { [weak stageState = w.stageState] in
            stageState?.callActiveLive ?? false
        }
        w.a2dpGuard.onModeChange = { [weak stageState = w.stageState] mode in
            stageState?.setA2dpGuardMode(mode)
        }
        w.a2dpGuard.start(mode: w.stageState.savedA2dpGuardMode)

        profileRulesLink = ProfileRulesLink(controller: w.controller, rules: w.profileRules)
        w.profileRules.start()

        w.presetLibrary.currentCurve = { [weak controller = w.controller] in
            guard let controller, controller.canWriteNow, !controller.bands.isEmpty
            else { return nil }
            return PresetLibrary.LiveCurve(bands: controller.bands,
                                           preGain: controller.preGain,
                                           group: controller.eqGroup,
                                           sourceName: controller.currentSourceName)
        }
        w.presetLibrary.onApply = { [weak controller = w.controller] preset in
            controller?.applyLibraryPreset(preset) ?? false
        }
        w.presetLibrary.start()

        w.appAssignments.libraryPresets = { [weak library = w.presetLibrary] in
            library?.presets ?? []
        }
        w.appAssignments.persistAssignments = { [weak library = w.presetLibrary] next in
            library?.setAppAssignments(next)
        }
        w.appAssignments.persistEnabled = { [weak stageState = w.stageState] on in
            stageState?.setPerAppEQ(on)
        }
        w.appAssignments.onChange = { [weak stageState = w.stageState] in
            stageState?.appAssignmentsChanged()
        }
        w.stageState.activeAssignments = { [weak assignments = w.appAssignments] in
            assignments?.activeAssignments ?? []
        }
        w.stageState.onProcessListRefresh = { [weak assignments = w.appAssignments] in
            assignments?.refreshRunning()
        }
        w.appAssignments.start(assignments: w.presetLibrary.appAssignments,
                               enabled: w.stageState.perAppEQ)
        w.stageState.appAssignmentsChanged()

        w.headphoneSuggestions.limits = { [weak controller = w.controller] in
            .qudelix(bandCount: controller?.bandCount ?? QxEqGroup.user.bandCount)
        }
        w.headphoneSuggestions.applyCorrection = { [weak controller = w.controller]
            result, name in
            guard let controller, controller.canWriteNow,
                  controller.apply(result.file, named: name,
                                   undoLabel: "correction for \(name)") else { return false }
            var parts = [result.provenance]
            if let applied = controller.lastImportSummary { parts.append(applied) }
            parts.append(contentsOf: result.warnings)
            controller.lastImportSummary = parts.joined(separator: " · ")
            controller.requestPane(.importing)
            return true
        }
        w.headphoneSuggestions.popoverIsOpen = { [weak self] in
            self?.popover?.isShown ?? false
        }
        w.stageState.suggestionDiagnostics = { [weak s = w.headphoneSuggestions] in
            s?.diagSummary ?? "suggest=none"
        }
        w.headphoneSuggestions.start()

        w.presetLibrary.$presets
            .removeDuplicates { $0.map(\.id) == $1.map(\.id) }
            .receive(on: DispatchQueue.main)
            .sink { [weak assignments = w.appAssignments] _ in
                MainActor.assumeIsolated { assignments?.onChange() }
            }
            .store(in: &sources)

        Publishers.Merge(w.controller.$activeCall.map { _ in () },
                         w.controller.$inputSource.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.deviceCallStateMayHaveChanged() }
            }
            .store(in: &sources)
    }

    private func deviceCallStateMayHaveChanged() {
        guard let w = wiring else { return }
        let onCall = StageState.callIsActive(outputOnCall: false,
                                             deviceActiveCall: w.controller.activeCall,
                                             deviceInputSource: w.controller.inputSource)
        guard onCall != lastDeviceOnCall else { return }
        lastDeviceOnCall = onCall
        w.stageState.checkCallNow()
    }

    private func buildStatusUI(_ w: Wiring) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: w.content)
        popover.delegate = self
        self.popover = popover

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusItem = item

        iconModel.follow(controller: w.controller, stage: w.stageState)
        show(iconModel.presentation)

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.layoutSubtreeIfNeeded()

            let drop = StatusDropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.onMouseDown = { [weak self] event in
                self?.lastStatusMouseDown = event.timestamp
            }
            drop.onDrop = { [weak self] url in
                self?.importDropped(url)
            }
            button.addSubview(drop)
        }

        iconModel.$presentation
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] presentation in
                MainActor.assumeIsolated { self?.show(presentation) }
            }
            .store(in: &sources)
    }

    private func show(_ presentation: StatusIconModel.Presentation) {
        guard let button = statusItem?.button else { return }
        button.image = StatusIcon.image(for: presentation.icon)
        button.title = presentation.title ?? ""
        button.imagePosition = presentation.title == nil ? .imageOnly : .imageLeading
        button.toolTip = presentation.tooltip
        button.setAccessibilityLabel(presentation.accessibility)
    }

    private var closeEventTimestamp: TimeInterval = -1
    fileprivate var lastStatusMouseDown: TimeInterval = -2

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else if closeEventTimestamp != lastStatusMouseDown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverWillShow(_ notification: Notification) {
        wiring?.stageState.setUIVisible(true)
        wiring?.headphoneSuggestions.uiShown()
    }

    func popoverDidClose(_ notification: Notification) {
        closeEventTimestamp = NSApp.currentEvent?.timestamp ?? -1
        wiring?.stageState.setUIVisible(false)
    }

    static func runFilePanel(_ panel: NSSavePanel,
                             completion: @escaping (NSApplication.ModalResponse) -> Void) {
        let delegate = shared
        if let popover = delegate?.popover, popover.isShown {
            popover.performClose(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            completion(response)
            delegate?.showPopover()
        }
    }

    private func showPopover() {
        guard let popover, !popover.isShown, let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private static let maxDroppedBytes = 64 * 1024

    private func importDropped(_ url: URL) {
        guard let controller = wiring?.controller else { return }
        let name = SafeText.scrubbed(url.lastPathComponent, limit: 64)
        defer {
            controller.requestPane(.importing)
            showPopover()
        }
        guard let data = SafeFile.read(url, cap: Self.maxDroppedBytes) else {
            controller.lastImportSummary = "Couldn't read \(name) — an EQ preset is a "
                + "plain text file, and not a large one."
            return
        }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            controller.lastImportSummary = "Could not read \(name) as text."
            return
        }
        controller.importText(text, named: name)
    }
}

private final class StatusDropView: NSView {
    var onDrop: ((URL) -> Void)?
    var onMouseDown: ((NSEvent) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    private static let readOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.plainText.identifier],
    ]

    private func url(from sender: NSDraggingInfo) -> URL? {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: Self.readOptions) as? [URL]
        guard let urls, urls.count == 1 else { return nil }
        return urls.first
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard url(from: sender) != nil else { return [] }
        (superview as? NSButton)?.highlight(true)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        (superview as? NSButton)?.highlight(false)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        (superview as? NSButton)?.highlight(false)
        guard let dropped = url(from: sender) else { return false }
        onDrop?(dropped)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
        superview?.mouseDown(with: event)
    }
    override func rightMouseDown(with event: NSEvent) {
        onMouseDown?(event)
        superview?.rightMouseDown(with: event)
    }
}

@main
struct QudelixBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller: QudelixController
    @StateObject private var stageState: StageState
    @StateObject private var profileRules: ProfileRules
    @StateObject private var presetLibrary: PresetLibrary
    @StateObject private var appAssignments: AppAssignments
    @StateObject private var headphoneSuggestions: HeadphoneSuggestions
    @StateObject private var aiStudio: AIPresetStudio
    @StateObject private var a2dpGuard: A2dpGuard
    @StateObject private var abTuner: ABTuner
    @StateObject private var toneTester: ToneTester
    @StateObject private var blindTuner: BlindTuner

    init() {
        #if DEBUG
        UIPreview.runIfRequested()
        #endif
        SingleInstance.enforce()
        let controller = QudelixController()
        let stageState = StageState()
        let profileRules = ProfileRules()
        let presetLibrary = PresetLibrary()
        let appAssignments = AppAssignments()
        let headphoneSuggestions = HeadphoneSuggestions(library: presetLibrary)
        let aiStudio = AIPresetStudio()
        let a2dpGuard = A2dpGuard()
        let abTuner = ABTuner()
        let toneTester = ToneTester()
        let blindTuner = BlindTuner()

        let content = AnyView(
            PopoverView()
                .environmentObject(controller)
                .environmentObject(stageState)
                .environmentObject(profileRules)
                .environmentObject(presetLibrary)
                .environmentObject(appAssignments)
                .environmentObject(headphoneSuggestions)
                .environmentObject(aiStudio)
                .environmentObject(abTuner)
                .environmentObject(toneTester)
                .environmentObject(blindTuner)
                .environmentObject(a2dpGuard))
        AppDelegate.makeStatusUI = {
            AppDelegate.Wiring(content: content, controller: controller,
                               stageState: stageState, profileRules: profileRules,
                               presetLibrary: presetLibrary,
                               appAssignments: appAssignments,
                               headphoneSuggestions: headphoneSuggestions,
                               aiStudio: aiStudio,
                               abTuner: abTuner, toneTester: toneTester,
                               blindTuner: blindTuner, a2dpGuard: a2dpGuard)
        }

        _controller = StateObject(wrappedValue: controller)
        _stageState = StateObject(wrappedValue: stageState)
        _profileRules = StateObject(wrappedValue: profileRules)
        _presetLibrary = StateObject(wrappedValue: presetLibrary)
        _appAssignments = StateObject(wrappedValue: appAssignments)
        _headphoneSuggestions = StateObject(wrappedValue: headphoneSuggestions)
        _aiStudio = StateObject(wrappedValue: aiStudio)
        _a2dpGuard = StateObject(wrappedValue: a2dpGuard)
        _abTuner = StateObject(wrappedValue: abTuner)
        _toneTester = StateObject(wrappedValue: toneTester)
        _blindTuner = StateObject(wrappedValue: blindTuner)
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
