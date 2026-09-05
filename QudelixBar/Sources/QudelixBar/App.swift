import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    struct Wiring {
        let content: AnyView
        let controller: QudelixController
        let stageState: StageState
        let profileRules: ProfileRules
        let presetLibrary: PresetLibrary
        let headphoneSuggestions: HeadphoneSuggestions
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
        w.stageState.saveNow()
        w.stageState.engine.stop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        guard !started, let wiring = Self.makeStatusUI?() else { return }
        started = true
        self.wiring = wiring
        startServices(wiring)
        buildStatusUI(wiring)
    }

    private func startServices(_ w: Wiring) {
        w.controller.start()
        w.stageState.deviceCallState = { [weak controller = w.controller] in
            guard let controller else { return nil }
            return (controller.activeCall, controller.inputSource)
        }
        w.stageState.guardDiagnostics = { [weak guardian = w.a2dpGuard] in
            guardian?.diagSummary ?? "guard=off hijack=none"
        }
        w.stageState.qudelixVolumeDb = { [weak controller = w.controller] in
            controller?.reportedVolumeDb
        }
        w.stageState.start()

        w.a2dpGuard.callActive = { [weak stageState = w.stageState] in
            stageState?.callActiveLive ?? false
        }
        w.a2dpGuard.onModeChange = { [weak stageState = w.stageState] mode in
            stageState?.setA2dpGuardMode(mode)
        }
        w.a2dpGuard.start(mode: w.stageState.savedA2dpGuardMode)

        w.profileRules.onApplyPreset = { [weak controller = w.controller] index in
            controller?.loadPreset(index) ?? false
        }
        w.profileRules.presetLabel = { [weak controller = w.controller] index in
            controller?.presetLabel(index) ?? "Preset \(index + 1)"
        }
        w.profileRules.canApplyNow = { [weak controller = w.controller,
                                        weak rules = w.profileRules] in
            guard let controller, controller.canWriteNow,
                  !controller.byEarSessionActive,
                  controller.activePreset != nil else { return false }
            return rules?.editingNow != true
        }
        w.profileRules.currentEqGroupRaw = w.controller.eqGroup.rawValue
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

        w.controller.$eqGroup
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak rules = w.profileRules] group in
                MainActor.assumeIsolated { rules?.currentEqGroupRaw = group.rawValue }
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
    @StateObject private var headphoneSuggestions: HeadphoneSuggestions
    @StateObject private var a2dpGuard: A2dpGuard
    @StateObject private var abTuner: ABTuner
    @StateObject private var toneTester: ToneTester
    @StateObject private var blindTuner: BlindTuner

    init() {
        #if DEBUG
        UIPreview.runIfRequested()
        #endif
        let controller = QudelixController()
        let stageState = StageState()
        let profileRules = ProfileRules()
        let presetLibrary = PresetLibrary()
        let headphoneSuggestions = HeadphoneSuggestions(library: presetLibrary)
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
                .environmentObject(headphoneSuggestions)
                .environmentObject(abTuner)
                .environmentObject(toneTester)
                .environmentObject(blindTuner)
                .environmentObject(a2dpGuard))
        AppDelegate.makeStatusUI = {
            AppDelegate.Wiring(content: content, controller: controller,
                               stageState: stageState, profileRules: profileRules,
                               presetLibrary: presetLibrary,
                               headphoneSuggestions: headphoneSuggestions,
                               abTuner: abTuner, toneTester: toneTester,
                               blindTuner: blindTuner, a2dpGuard: a2dpGuard)
        }

        _controller = StateObject(wrappedValue: controller)
        _stageState = StateObject(wrappedValue: stageState)
        _profileRules = StateObject(wrappedValue: profileRules)
        _presetLibrary = StateObject(wrappedValue: presetLibrary)
        _headphoneSuggestions = StateObject(wrappedValue: headphoneSuggestions)
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
