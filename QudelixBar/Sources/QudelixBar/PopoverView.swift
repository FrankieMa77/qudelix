import Combine
import CoreAudio
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var controller: QudelixController
    @State private var pane: Pane = .equalizer
    @State private var showDiagnostics = false
    @State private var showDeviceSettings = false
    @State private var showAbout = false
    @State private var showBattery = false
    @State private var editingBand: Int?
    @State private var selectedBand: Int?
    @State private var host = HostWindowRef()
    @EnvironmentObject private var profileRules: ProfileRules
    @EnvironmentObject private var micGuard: A2dpGuard
    @EnvironmentObject private var suggestions: HeadphoneSuggestions

    enum Pane: String, CaseIterable, Identifiable {
        case equalizer = "EQ"
        case presets = "Presets"
        case importing = "Import"
        case tune = "Tune"
        case stage = "Stage"
        case level = "Level"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .equalizer: return "slider.horizontal.3"
            case .presets: return "square.stack"
            case .importing: return "arrow.down.circle"
            case .tune: return "ear"
            case .stage: return "water.waves"
            case .level: return "gauge.with.needle"
            }
        }
        var needsDevice: Bool {
            switch self {
            case .presets, .stage, .level: return false
            default: return true
            }
        }
    }

    static let contentHeight: CGFloat = 675

    var body: some View {
        PopoverStackLayout(screenVisibleHeight: { [host] in
            host.window?.screen?.visibleFrame.height
                ?? NSScreen.main?.visibleFrame.height
                ?? 800
        }) {
            shell
            drawers
        }
        .frame(width: 400)
        .background(HostWindowReader(host: host))
        .onChange(of: editingBand, initial: true) { _, band in
            profileRules.editingNow = band != nil
        }
        .onChange(of: showBattery) { _, on in
            if on { showAbout = false; showDeviceSettings = false; showDiagnostics = false }
        }
    }

    private var shell: some View {
        VStack(spacing: 0) {
            DeviceHeader(showBattery: $showBattery)
            Divider()
                .onAppear { if let p = controller.previewPane { pane = p } }
                .onChange(of: controller.paneRequests) { _, _ in
                    guard let p = controller.paneRequest,
                          fullPanes || !p.needsDevice else { return }
                    pane = p
                }

            if micGuard.hijack != nil || suggestions.banner != nil {
                VStack(spacing: 8) {
                    if micGuard.hijack != nil { micGuardBanner }
                    if let offered = suggestions.banner { suggestionBanner(offered) }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
            }

            if case .unsupported(let title, let detail) = controller.compatibility, connected {
                VStack(spacing: 0) {
                    UnsupportedDeviceView(title: title, detail: detail)
                        .frame(maxWidth: .infinity)
                    Divider()
                    VStack(spacing: 14) {
                        Picker("", selection: $pane) {
                            ForEach(Pane.allCases.filter { !$0.needsDevice }) { p in
                                Label(p.rawValue, systemImage: p.icon).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        switch pane {
                        case .presets: ScrollView { PresetsView() }
                        case .level: ScrollView { LevelView() }
                        default: ScrollView { StageView() }
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .padding(14)
                }
                .frame(height: Self.contentHeight)
                .clipped()
                .onAppear { if pane.needsDevice { pane = .stage } }
            } else if connected {
                VStack(spacing: 14) {
                    EQCurveView(bands: controller.bands,
                                preGain: controller.preGain,
                                highlighted: editingBand,
                                requested: controller.requestedCorrection,
                                mutedBands: controller.mutedBands,
                                enabled: controller.eqEnabled,
                                selectedBand: selectedBand,
                                onSelectBand: { selectedBand = $0 },
                                onZeroBand: { controller.zeroBand($0) },
                                onBandChanged: { controller.updateBand($0, $1) },
                                onDragBand: { editingBand = $0 })
                        .frame(height: 104)

                    if pane == .equalizer {
                        BandInspector(selected: $selectedBand)
                    }

                    VolumeControl()

                    UsbAudioRow()

                    ViewThatFits(in: .horizontal) {
                        paneTabs
                        paneTabs.controlSize(.small)
                    }

                    switch pane {
                    case .equalizer: EqEditorView(editingBand: $editingBand)
                    case .presets: ScrollView { PresetsView() }
                    case .importing: ScrollView { ImportView() }
                    case .tune: ScrollView { TuneView() }
                    case .stage: ScrollView { StageView() }
                    case .level: ScrollView { LevelView() }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
                .padding(14)
                .frame(height: Self.contentHeight)
                .clipped()
            } else {
                VStack(spacing: 0) {
                    DisconnectedView()
                    Divider()
                    VStack(spacing: 14) {
                        Picker("", selection: $pane) {
                            ForEach(Pane.allCases.filter { !$0.needsDevice }) { p in
                                Label(p.rawValue, systemImage: p.icon).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        switch pane {
                        case .presets: ScrollView { PresetsView() }
                        case .level: ScrollView { LevelView() }
                        default: ScrollView { StageView() }
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .padding(14)
                }
                .frame(height: Self.contentHeight)
                .clipped()
                .onAppear { if pane.needsDevice { pane = .stage } }
            }

            Divider()
            FooterBar(showDiagnostics: $showDiagnostics,
                      showDeviceSettings: $showDeviceSettings,
                      showAbout: $showAbout,
                      showBattery: $showBattery)
        }
    }

    @ViewBuilder
    private var drawers: some View {
        if showAbout { DrawerPanel(content: AboutView()) }
        if showDeviceSettings { DrawerPanel(content: DeviceSettingsView()) }
        if showDiagnostics { DrawerPanel(content: DiagnosticsView()) }
        if showBattery { DrawerPanel(content: BatteryHistoryView()) }
    }

    private var paneTabs: some View {
        Picker("", selection: $pane) {
            ForEach(Pane.allCases) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var connected: Bool {
        if case .connected = controller.connection { return true }
        return false
    }

    private var fullPanes: Bool {
        if case .unsupported = controller.compatibility { return false }
        return connected
    }

    @ViewBuilder
    private var micGuardBanner: some View {
        if let hijack = micGuard.hijack {
            HStack(spacing: 8) {
                Image(systemName: "phone.badge.waveform.fill")
                    .accessibilityHidden(true)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                let isTheDevice = A2dpGuard.isTheDevice(
                    hijackName: hijack.name, connectedName: connectedName)
                VStack(alignment: .leading, spacing: 1) {
                    (isTheDevice
                     ? Text("The 5K switched to call mode")
                     : Text(verbatim: "Microphone taken by " + hijack.name))
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(A2dpGuard.bannerDetail(
                        reason: hijack.reason,
                        isTheDevice: isTheDevice,
                        deviceInputSource: controller.inputSource))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button("Use Built-in Mic") { micGuard.useBuiltInMic() }
                    .controlSize(.small)
                Button { micGuard.ignoreHijack() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Leave this microphone alone")
                }
                .buttonStyle(.plain)
                .help("Leave it — I want this microphone")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.1)))
        }
    }

    private var connectedName: String? {
        guard case .connected(let name) = controller.connection else { return nil }
        return name
    }

    @ViewBuilder
    private func suggestionBanner(_ offered: HeadphoneSuggestions.Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .accessibilityHidden(true)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: HeadphoneSuggestions.headline(offered.entry.title))
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: HeadphoneSuggestions.bannerDetail(
                        source: offered.entry.source, bandCount: controller.bandCount))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if suggestions.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Apply") { suggestions.accept(offered.entry) }
                        .controlSize(.small)
                        .disabled(!controller.canEditEqNow)
                    if offered.alternatives.count > 1 {
                        Menu {
                            ForEach(offered.alternatives) { entry in
                                Button {
                                    suggestions.accept(entry)
                                } label: {
                                    Text(verbatim: "\(entry.title) (\(entry.source))")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 11))
                                .accessibilityLabel("Other measurements for these headphones")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 18)
                        .disabled(!controller.canEditEqNow)
                    }
                }
                Button { suggestions.dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Don\u{2019}t offer this correction")
                }
                .buttonStyle(.plain)
                .help("Hide this \u{2014} it won\u{2019}t be offered again for this name")
            }
            if controller.activePreset == nil {
                Text("Your current EQ is a custom setting that isn\u{2019}t saved to a "
                    + "slot \u{2014} applying this will replace it.")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let why = suggestions.lastError {
                Text(verbatim: why)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(Color.accentColor.opacity(0.08)))
    }
}

struct DrawerPanel<Content: View>: View {
    let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ScrollView {
                content
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
    }
}

struct PopoverStackLayout: Layout {
    static let chrome: CGFloat = 30
    static let minimumDrawerHeight: CGFloat = 80

    let screenVisibleHeight: () -> CGFloat

    static func drawerHeightCap(screenVisibleHeight: CGFloat, shellHeight: CGFloat) -> CGFloat {
        max(minimumDrawerHeight, screenVisibleHeight - chrome - shellHeight)
    }

    private func heights(_ subviews: Subviews, width: CGFloat?) -> (shell: CGFloat, drawers: [CGFloat]) {
        let proposal = ProposedViewSize(width: width, height: nil)
        guard let shell = subviews.first else { return (0, []) }
        let shellHeight = shell.sizeThatFits(proposal).height
        let cap = Self.drawerHeightCap(screenVisibleHeight: screenVisibleHeight(),
                                       shellHeight: shellHeight)
        let drawers = subviews.dropFirst().map { min($0.sizeThatFits(proposal).height, cap) }
        return (shellHeight, drawers)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.first?.sizeThatFits(.unspecified).width ?? 0
        let h = heights(subviews, width: width)
        return CGSize(width: width, height: h.shell + h.drawers.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let h = heights(subviews, width: bounds.width)
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let height = index == 0 ? h.shell : h.drawers[index - 1]
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
    }
}

private struct HitTargetLayout: Layout {
    let minimumSide: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(.unspecified) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard let button = subviews.first else { return }
        let natural = button.sizeThatFits(.unspecified)
        button.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                     proposal: ProposedViewSize(width: max(natural.width, minimumSide),
                                                height: max(natural.height, minimumSide)))
    }
}

private struct GlyphButton<Label: View>: View {
    let action: () -> Void
    let label: Label

    init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    var body: some View {
        HitTargetLayout(minimumSide: 20) {
            Button(action: action) {
                label.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.borderless)
        }
    }
}

private final class HostWindowRef {
    weak var window: NSWindow?
}

private struct HostWindowReader: NSViewRepresentable {
    let host: HostWindowRef

    func makeNSView(context: Context) -> NSView {
        Anchor(host: host)
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class Anchor: NSView {
        let host: HostWindowRef
        private var shown: AnyCancellable?

        init(host: HostWindowRef) {
            self.host = host
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            host.window = window
            shown = nil
            guard window != nil else { return }
            shown = NotificationCenter.default.publisher(for: NSPopover.didShowNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] note in
                    guard let self,
                          let popover = note.object as? NSPopover,
                          popover.contentViewController?.view.window === self.window
                    else { return }
                    self.dropTextFocus()
                }
            dropTextFocus()
        }

        private func dropTextFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window, window.firstResponder is NSText else { return }
                window.makeFirstResponder(nil)
            }
        }
    }
}

struct DeviceHeader: View {
    @EnvironmentObject var controller: QudelixController
    @EnvironmentObject var stageState: StageState
    @Binding var showBattery: Bool

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(connected
                          ? AnyShapeStyle(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.65)],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.secondary.opacity(0.25)))
                    .frame(width: 34, height: 34)
                Image(systemName: "headphones")
                    .accessibilityHidden(true)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(connected ? .white : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: deviceName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    if let icon = linkIcon {
                        Image(systemName: icon)
                            .accessibilityLabel(linkHelp)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .help(linkHelp)
                    }
                    Text(verbatim: statusLine)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if let batt = controller.batteryPercent {
                Button {
                    showBattery.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: controller.charging ? "bolt.fill" : batteryIcon(batt))
                            .accessibilityHidden(true)
                            .foregroundStyle(batteryColor(batt))
                        Text("\(batt)%")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(!controller.charging
                                             && batt <= BatteryAlerts.veryLowThreshold
                                             ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(showBattery ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quaternary.opacity(0.5)),
                                in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: batteryAccessibility(batt)))
                .accessibilityHint("Shows the battery graph")
                .help(batteryHelp(batt) + "\nClick for the discharge graph")
            }

            if stageState.callActive {
                GlyphButton(action: { stageState.releaseCall() }) {
                    Image(systemName: "phone.badge.waveform.fill")
                        .accessibilityLabel("On a call — click to end call mode")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                .help(StageState.callBadgeHelp(stageState.callWitnesses))
            }

            GlyphButton(action: { controller.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .accessibilityLabel("Re-read the device")
            }
            .disabled(!connected)
            .help("Refresh from device")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .onAppear { stageState.checkCallNow() }
    }

    private var connected: Bool {
        if case .connected = controller.connection { return true }
        return false
    }
    private var deviceName: String {
        guard case .connected(let n) = controller.connection else { return "Qudelix" }
        let cleaned = QudelixController.displayName(A2dpGuard.deviceBaseName(n))
        return cleaned.isEmpty ? "Qudelix" : cleaned
    }
    private var linkIcon: String? {
        switch controller.link {
        case .usb: return "cable.connector"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        case .none: return nil
        }
    }
    private var linkHelp: String {
        switch controller.link {
        case .usb: return "Connected over USB"
        case .bluetooth: return "Connected over Bluetooth"
        case .none: return "Not connected"
        }
    }
    private var statusLine: String {
        Self.statusLine(connected: connected,
                        firmware: controller.firmwareVersion,
                        codec: controller.codecLabel,
                        sampleRate: controller.sampleRate,
                        inputSource: controller.inputSource,
                        battery: controller.batteryPercent,
                        charging: controller.charging)
    }

    static func statusLine(connected: Bool, firmware: String?, codec: String?,
                           sampleRate: String?, inputSource: String?,
                           battery: Int?, charging: Bool) -> String {
        guard connected else { return "Not connected" }
        var parts: [String] = []
        if let firmware { parts.append("FW \(firmware)") }
        if let battery {
            if charging {
                parts.append("charging")
            } else if battery <= BatteryAlerts.veryLowThreshold {
                parts.append("battery very low")
            } else if battery <= BatteryAlerts.lowThreshold {
                parts.append("battery low")
            }
        }
        if let codec, codec != "None" { parts.append(codec) }
        if let sampleRate, inputSource != "None" { parts.append(sampleRate) }
        if let inputSource, inputSource != "None" { parts.append(inputSource) } else { parts.append("idle") }
        return parts.joined(separator: " · ")
    }
    private func batteryIcon(_ p: Int) -> String {
        switch p {
        case 80...: return "battery.100"
        case 55..<80: return "battery.75"
        case 30..<55: return "battery.50"
        case 10..<30: return "battery.25"
        default: return "battery.0"
        }
    }
    private func batteryColor(_ p: Int) -> Color {
        if controller.charging { return .green }
        if p <= BatteryAlerts.veryLowThreshold { return .red }
        if p <= BatteryAlerts.lowThreshold { return .orange }
        return .secondary
    }
    private func batteryAccessibility(_ p: Int) -> String {
        var text = "Battery \(p) percent"
        if controller.charging {
            text += ", charging"
        } else if p <= BatteryAlerts.veryLowThreshold {
            text += ", very low"
        } else if p <= BatteryAlerts.lowThreshold {
            text += ", low"
        }
        return text
    }

    private func batteryHelp(_ p: Int) -> String {
        if let summary = controller.chargeSummary, !controller.charging,
           controller.chargerConnected {
            var text = "\(summary) — \(p)%"
            if controller.batteryCare == true {
                text += "\nBattery care is on, so it stops short of full."
            }
            return text
        }
        if controller.charging { return "Charging — \(p)%" }
        if p <= BatteryAlerts.veryLowThreshold {
            return "Battery very low — the 5K will shut down soon"
        }
        if p <= BatteryAlerts.lowThreshold { return "Battery low" }
        return "Battery \(p)%"
    }
}

struct VolumeControl: View {
    @EnvironmentObject var controller: QudelixController

    var body: some View {
        HStack(spacing: 10) {
            GlyphButton(action: { controller.setMute(!controller.muted) }) {
                Image(systemName: controller.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .accessibilityLabel(controller.muted ? "Unmute" : "Mute")
                    .font(.system(size: 12))
                    .foregroundStyle(controller.muted ? .orange : .secondary)
                    .frame(width: 18)
            }
            .help(controller.muted ? "Unmute" : "Mute")

            Slider(value: Binding(get: { controller.volumeDb },
                                  set: { controller.setVolume($0) }),
                   in: controller.volumeRange)
                .disabled(controller.muted)
                .accessibilityLabel("Volume in decibels")

            Text(String(format: "%.1f", controller.volumeDb))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .frame(width: 34, alignment: .trailing)
            Text("dB").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct UsbAudioRow: View {
    @EnvironmentObject var stageState: StageState

    var body: some View {
        if let device = stageState.qudelixUsbOutput {
            UsbAudioRateRow(device: device)
        }
    }
}

private struct UsbAudioRateRow: View {
    let device: AudioOutput
    @EnvironmentObject var stageState: StageState
    @EnvironmentObject var controller: QudelixController
    @State private var availableRates: [Double]
    @State private var bitDepth: Int?

    init(device: AudioOutput) {
        self.device = device
        _availableRates = State(initialValue: [device.sampleRate])
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text("USB audio")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                ratePicker(device)
                Text("kHz")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                if let bits = bitDepth {
                    Text("\(bits)-bit")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if let fsMode = controller.usbFsMode {
                    Menu {
                        Section("Rates the 5K offers over USB — changing "
                                + "restarts its USB connection") {
                            ForEach(0..<QudelixController.usbFsModeLabels.count,
                                    id: \.self) { idx in
                                Button {
                                    controller.setUsbFsMode(idx)
                                } label: {
                                    if idx == fsMode {
                                        Label(QudelixController.usbFsModeLabels[idx],
                                              systemImage: "checkmark")
                                    } else {
                                        Text(QudelixController.usbFsModeLabels[idx])
                                    }
                                }
                            }
                        }
                    } label: {
                        Text(fsMode == 4 ? "all rates" : Self.shortFsLabel(fsMode))
                            .font(.system(size: 10))
                            .foregroundStyle(fsMode == 4
                                             ? AnyShapeStyle(.secondary)
                                             : AnyShapeStyle(.orange))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(fsMode == 4
                          ? "The 5K offers all rates over USB."
                          : "The 5K is pinned to \(QudelixController.usbFsModeLabels[fsMode]) "
                            + "over USB — macOS can't offer the others until the "
                            + "device does. Change it here (its USB connection "
                            + "restarts for a moment).")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("The rate macOS runs the Qudelix at — the same setting as "
                  + "Audio MIDI Setup. macOS resamples anything at a different "
                  + "rate and never switches this automatically, so match your "
                  + "library: most music is 44.1 kHz, most video 48 kHz. "
                  + "While Soundstage is on, audio is processed on the Mac and "
                  + "resampling happens regardless.")

            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { stageState.qualityMasterOn },
                    set: { stageState.setQualityMaster($0) })) {
                    Text("Auto rate")
                        .font(.system(size: 10))
                }
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                .help("Measures whether what's playing is lossy or lossless "
                      + "and matches the USB rate: lossless → 44.1 kHz "
                      + "(bit-perfect), lossy → the rate you picked. Separate "
                      + "detection/switching toggles live in the Level pane.")
                Text(verbatim: autoStatus(current: device.sampleRate))
                    .font(.system(size: 10))
                    .foregroundStyle(stageState.qualityVerdict?.isLosslessClass == true
                                     && stageState.qualityMasterOn
                                     ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Spacer()
            }
        }
        .onAppear {
            stageState.watcher.refreshNow()
            refreshDeviceFacts(device.id)
        }
        .onChange(of: device.id) { _, id in refreshDeviceFacts(id) }
    }

    private func ratePicker(_ device: AudioOutput) -> some View {
        let playable = StageState.playbackRates(availableRates)
        let rates = playable.isEmpty ? [device.sampleRate] : playable
        let binding = Binding<Double>(
            get: { device.sampleRate },
            set: { stageState.setNominalRate($0, for: device, manual: true) })
        return Picker("", selection: binding) {
            ForEach(rates, id: \.self) { r in
                Text(Self.kHz(r)).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .labelsHidden()
        .accessibilityLabel("USB sample rate in kilohertz")
        .disabled(stageState.callActive)
        .help(stageState.callActive
              ? "Paused during your call — while the microphone is in use the "
                + "rate follows the call, and changing it here would cut the "
                + "call's audio."
              : "The rate macOS runs this output at — the same setting as "
                + "Audio MIDI Setup.")
    }

    private func refreshDeviceFacts(_ id: AudioDeviceID) {
        availableRates = AudioOutputs.availableNominalRates(id)
        bitDepth = AudioOutputs.outputBitDepth(id)
    }

    private func autoStatus(current: Double) -> String {
        if !stageState.detectQuality { return "off — the rate stays as you set it" }
        if !stageState.autoRate { return "detecting only — switching is off (Level pane)" }
        if stageState.callActive {
            return "paused for your call — detection resumes after it ends"
        }
        if let failure = stageState.engineFailure { return failure.summary }
        guard stageState.engine.isRunning else { return "waiting for audio" }
        if stageState.stage.enabled {
            return "Soundstage is on — holding the rate while the Mac processes"
        }
        guard let verdict = stageState.qualityVerdict else {
            return "listening to what's playing…"
        }
        switch verdict {
        case .tooQuiet, .noTreble: return "can't judge this material — holding"
        case .natural: return "master rolls off naturally — holding"
        case .lossy(let k):
            return String(format: "lossy (%.1f kHz) — keeping your rate", k)
        case .lossyHigh(let k):
            return String(format: "borderline cliff (%.1f kHz) — holding", k)
        case .losslessLike, .hiRes:
            guard let target = StageState.rateForVerdict(
                    verdict, availableRates: availableRates,
                    manualRateHz: stageState.manualRate, deviceRate: current) else {
                return "hi-res — holding, the 5K isn't offering a "
                     + "high-resolution rate over USB"
            }
            if current == target {
                return stageState.autoSetRate == current
                    ? "lossless — set \(Self.kHz(target)) kHz automatically"
                    : "lossless — \(Self.kHz(target)) kHz already matched"
            }
            if !availableRates.contains(target) {
                return "lossless — holding, \(Self.kHz(target)) kHz "
                     + "isn't offered over USB"
            }
            return "lossless — switching to \(Self.kHz(target)) kHz shortly…"
        }
    }

    private static func kHz(_ rate: Double) -> String {
        String(format: "%g", rate / 1000)
    }

    private static func shortFsLabel(_ idx: Int) -> String {
        switch idx {
        case 0: return "96 only"
        case 1: return "88.2 only"
        case 2: return "48 only"
        case 3: return "44.1 only"
        case 5: return "48 + mic"
        case 6: return "44.1 + mic"
        default: return "?"
        }
    }
}

struct EqEditorView: View {
    @EnvironmentObject var controller: QudelixController
    @Binding var editingBand: Int?
    @State private var confirmingSave: Int?

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Toggle(isOn: Binding(get: { controller.eqEnabled },
                                     set: { controller.setEqEnabled($0) })) {
                    Text("Equalizer").font(.system(size: 11, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                undoButton
                redoButton

                Spacer()

                Text("Pre-gain").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { controller.preGain },
                                      set: { controller.setPreGain($0) }),
                       in: EQHeadroom.range, step: 0.5)
                    .frame(width: 92)
                    .accessibilityLabel("Pre-gain in decibels")
                Text(String(format: "%+.1f", controller.preGain))
                    .font(.system(size: 10).monospacedDigit())
                    .frame(width: 30, alignment: .trailing)
            }

            headroomRow

            Divider()

            bandTable
                .frame(maxHeight: .infinity, alignment: .top)
                .opacity(controller.eqEnabled ? 1 : 0.45)
                .disabled(!controller.eqEnabled)

            Divider()

            HStack {
                Button("Flatten") { controller.flatten() }
                    .help("Take every band's gain to zero, keeping the "
                          + "frequencies, filter types and Q they have now.")
                Button("Reset") { controller.resetBandLayout() }
                    .help("Put the bands back to the factory layout for this mode: "
                          + "peak filters on the default frequencies, 0 dB, Q 1.")
                Picker("", selection: Binding(
                    get: { controller.eqGroup == .b20 },
                    set: { controller.setEqMode(twentyBand: $0) })) {
                    Text("10").tag(false)
                    Text("20").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 76)
                .accessibilityLabel("Number of EQ bands")
                .help("EQ bands. The two modes keep separate presets, so "
                      + "switching changes the active curve.")
                Spacer()
                Button("Update") {
                    guard let active = controller.activePreset else { return }
                    controller.savePreset(active)
                }
                .disabled(controller.activePreset == nil || !controller.canWriteNow)
                .help(updateHelp)
                Menu("Save to slot…") {
                    ForEach(0..<QudelixController.presetCount, id: \.self) { i in
                        Button {
                            saveToSlot(i)
                        } label: {
                            Text(verbatim: controller.presetLabel(i))
                        }
                    }
                }
                .fixedSize()
            }
            .controlSize(.small)
            .font(.system(size: 11))
        }
        .frame(maxHeight: .infinity)
        .slotOverwriteConfirmation($confirmingSave)
    }

    private func saveToSlot(_ i: Int) {
        if controller.presetNames[i] != nil {
            confirmingSave = i
        } else {
            controller.savePreset(i)
        }
    }

    private var updateHelp: Text {
        guard let active = controller.activePreset else {
            return Text("No slot is active \u{2014} load or save one first.")
        }
        return Text(verbatim: "Overwrite " + controller.presetLabel(active)
                    + " with the current EQ")
    }

    private var undoButton: some View {
        Button {
            controller.undoEqEdit()
        } label: {
            Image(systemName: "arrow.uturn.backward").font(.system(size: 9))
                .accessibilityLabel(controller.undoLabel.map { "Undo \($0)" } ?? "Undo")
        }
        .controlSize(.mini)
        .disabled(!controller.canUndo || !controller.canEditEqNow)
        .keyboardShortcut("z", modifiers: .command)
        .help(controller.undoLabel.map { "Undo \($0)" } ?? "Nothing to undo")
    }

    private var redoButton: some View {
        Button {
            controller.redoEqEdit()
        } label: {
            Image(systemName: "arrow.uturn.forward").font(.system(size: 9))
                .accessibilityLabel(controller.redoLabel.map { "Redo \($0)" } ?? "Redo")
        }
        .controlSize(.mini)
        .disabled(!controller.canRedo || !controller.canEditEqNow)
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .help(controller.redoLabel.map { "Redo \($0)" } ?? "Nothing to redo")
    }
}

extension EqEditorView {
    @ViewBuilder
    var headroomRow: some View {
        let advice = controller.eqHeadroom
        HStack(spacing: 6) {
            Text(headroomText(advice))
            Spacer()
            if let suggestion = advice.suggestion {
                Button(String(format: "Set %.1f dB", suggestion)) {
                    controller.applySuggestedPreGain()
                }
                .controlSize(.mini)
                .font(.system(size: 10))
                .help("Attenuates ahead of the filters by as much as the bands "
                      + "boost, so the equalizer passes on no more level than it "
                      + "was given. Clipping already in the source is untouched.")
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
    }

    private func headroomText(_ advice: EQHeadroom.Advice) -> String {
        guard advice.peakBoost >= 0.05 else { return "No band boost to offset." }
        let boost = String(format: "Bands boost by up to %.1f dB", advice.peakBoost)
        if advice.shortfall >= 0.05 {
            return boost + String(format: " — %.1f dB more than pre-gain can take back.",
                                  advice.shortfall)
        }
        return advice.suggestion == nil ? boost + "; pre-gain covers it." : boost + "."
    }

    @ViewBuilder
    var bandTable: some View {
        let grid = Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 5) {
            GridRow {
                Text("").frame(width: 12)
                Text("Type").font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 58)
                Text("Hz").font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                Text("Gain").font(.system(size: 9)).foregroundStyle(.secondary)
                Text("").frame(width: 32)
                Text("Q").font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                Text("").frame(width: 16)
            }
            ForEach(0..<controller.bandCount, id: \.self) { i in
                BandRow(index: i, editingBand: $editingBand)
            }
        }
        ScrollView { grid.padding(.trailing, 4) }
            .scrollIndicators(.visible)
    }
}

struct BandInspector: View {
    @EnvironmentObject var controller: QudelixController
    @Binding var selected: Int?

    static let height: CGFloat = 48
    static let qFloor = 0.25
    static let qCeiling = 10.0

    var body: some View {
        if let i = selected, controller.bands.indices.contains(i),
           i < controller.bandCount {
            detail(i, controller.bands[i])
                .frame(height: Self.height)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .opacity(controller.eqEnabled ? 1 : 0.45)
                .disabled(!controller.eqEnabled)
        }
    }

    @ViewBuilder
    private func detail(_ i: Int, _ band: QxEqBandValue) -> some View {
        let editsGain = band.filter == .bypass || band.filter.hasGain
        VStack(spacing: 3) {
            HStack(spacing: 7) {
                Text("Band " + String(i + 1))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                Picker("", selection: Binding(get: { band.filter },
                                              set: set(i) { $0.filter = $1 })) {
                    ForEach(QxFilter.allCases) { f in Text(f.shortLabel).tag(f) }
                }
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 58)
                .accessibilityLabel("Band \(i + 1) filter type")
                Text(String(band.freq) + " Hz")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Flat") { controller.zeroBand(i) }
                    .controlSize(.mini)
                    .font(.system(size: 10))
                    .help("Take this band back to nothing")
                Button { selected = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Done with band \(i + 1)")
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 7) {
                Text("Gain")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { band.gain }, set: set(i) { $0.gain = $1 }),
                       in: -12...12)
                    .controlSize(.mini)
                    .disabled(!editsGain)
                    .accessibilityLabel("Band \(i + 1) gain in decibels")
                Text(editsGain ? String(format: "%+.1f", band.gain) : "—")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(editsGain ? .primary : .secondary)
                    .frame(width: 30, alignment: .trailing)
                Text("Q")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { log10(min(max(band.q, Self.qFloor),
                                                       Self.qCeiling)) },
                                      set: set(i) { $0.q = (pow(10, $1) * 100).rounded() / 100 }),
                       in: log10(Self.qFloor)...log10(Self.qCeiling))
                    .controlSize(.mini)
                    .accessibilityLabel("Band \(i + 1) Q")
                    .accessibilityValue(String(format: "%.2f", band.q))
                Text(String(format: "%.2f", band.q))
                    .font(.system(size: 10).monospacedDigit())
                    .frame(width: 28, alignment: .trailing)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
    }

    private func set<T>(_ index: Int,
                        _ apply: @escaping (inout QxEqBandValue, T) -> Void) -> (T) -> Void {
        { newValue in
            guard controller.bands.indices.contains(index) else { return }
            var b = controller.bands[index]
            apply(&b, newValue)
            controller.updateBand(index, b)
        }
    }
}

private struct BandNumberField<Value>: View {
    let shown: String
    let width: CGFloat
    let label: String
    let parse: (String) -> Value?
    let format: (Value) -> String
    let commit: (Value) -> String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.mini)
            .font(.system(size: 10).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .focused($focused)
            .accessibilityLabel(label)
            .onAppear { text = shown }
            .onChange(of: shown) { _, new in
                if !focused { text = new }
            }
            .onChange(of: focused) { _, nowFocused in
                if !nowFocused { settle() }
            }
            .onSubmit { settle() }
    }

    private func settle() {
        let outcome = NumberEntry.resolve(typed: text, shown: shown, parse: parse, format: format)
        text = outcome.display
        if let value = outcome.change { text = commit(value) }
    }
}

struct BandRow: View {
    @EnvironmentObject var controller: QudelixController
    let index: Int
    @Binding var editingBand: Int?

    var body: some View {
        let band = controller.bands.indices.contains(index)
            ? controller.bands[index] : QxEqBandValue()
        let muted = controller.isBandMuted(index)
        let editsGain = band.filter == .bypass || band.filter.hasGain
        GridRow {
            Text("\(index + 1)")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 12)

            Picker("", selection: Binding(get: { band.filter }, set: { set { $0.filter = $1 } ($0) })) {
                ForEach(QxFilter.allCases) { f in Text(f.shortLabel).tag(f) }
            }
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 58)
            .accessibilityLabel("Band \(index + 1) filter type")

            BandNumberField(shown: NumberEntry.formatFrequency(band.freq), width: 50,
                            label: "Band \(index + 1) frequency in hertz",
                            parse: NumberEntry.parseFrequency,
                            format: NumberEntry.formatFrequency) { hz in
                set { $0.freq = $1 } (hz)
                return NumberEntry.formatFrequency(liveBand?.freq ?? band.freq)
            }

            Slider(value: Binding(get: { band.gain }, set: { set { $0.gain = $1 } ($0) }),
                   in: -12...12,
                   onEditingChanged: { editing in editingBand = editing ? index : nil })
                .controlSize(.mini)
                .disabled(!editsGain)
                .accessibilityLabel("Band \(index + 1) gain in decibels")

            Text(editsGain ? String(format: "%+.1f", band.gain) : "—")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(editsGain && band.gain != 0 ? .primary : .secondary)
                .frame(width: 32, alignment: .trailing)

            BandNumberField(shown: NumberEntry.formatQ(band.q), width: 42,
                            label: "Band \(index + 1) Q",
                            parse: NumberEntry.parseQ,
                            format: NumberEntry.formatQ) { q in
                set { $0.q = $1 } (q)
                return NumberEntry.formatQ(liveBand?.q ?? band.q)
            }

            GlyphButton(action: { controller.setBandMuted(index, !muted) }) {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2")
                    .accessibilityLabel(muted ? "Unmute band \(index + 1)"
                                              : "Mute band \(index + 1)")
                    .font(.system(size: 9))
                    .foregroundStyle(muted ? Color.orange : Color.secondary)
            }
            .frame(width: 16)
            .disabled(band.filter == .bypass && !muted)
            .help(muted ? "Bring this band back — its gain hasn't changed"
                        : "Silence this band, keeping its gain")
        }
        .opacity(band.filter == .bypass ? (muted ? 0.62 : 0.45) : 1)
    }

    private var liveBand: QxEqBandValue? {
        controller.bands.indices.contains(index) ? controller.bands[index] : nil
    }

    private func set<T>(_ apply: @escaping (inout QxEqBandValue, T) -> Void) -> (T) -> Void {
        { newValue in
            guard controller.bands.indices.contains(index) else { return }
            var b = controller.bands[index]
            apply(&b, newValue)
            controller.updateBand(index, b)
        }
    }
}

enum PresetSectionStorage {
    static let slotsOpen = "presets.section.slots.open"
    static let libraryOpen = "presets.section.library.open"
}

struct PresetsView: View {
    @EnvironmentObject var controller: QudelixController
    @State private var renaming: Int?
    @State private var draftName = ""
    @State private var confirmingSave: Int?
    @FocusState private var nameFocused: Bool
    @AppStorage(PresetSectionStorage.slotsOpen) private var slotsExpanded = false

    private var slotsSummary: String {
        guard let active = controller.activePreset else { return "custom setting" }
        return "slot " + String(active + 1) + " \u{00B7} " + controller.presetLabel(active)
    }

    static let offlineNote = "The 5K isn\u{2019}t connected. You can organise presets "
        + "here; applying one needs the device."
    static let saveHereLabel = "Save here"
    static let overwriteTitle = "Replace the preset in this slot?"

    static func overwriteMessage(slot: Int, name: String) -> String {
        "Slot \(slot + 1), \u{201C}" + name + "\u{201D}, holds a preset on the "
            + "device. Writing replaces it, and the device keeps no copy."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !connected {
                Text(verbatim: Self.offlineNote)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup(isExpanded: $slotsExpanded) {
                VStack(alignment: .leading, spacing: 3) {
                    if controller.activePreset == nil {
                        Text("Current EQ is a custom setting, not a saved slot.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(0..<QudelixController.presetCount, id: \.self) { i in
                        presetRow(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Text("On the 5K").font(.system(size: 11, weight: .medium))
                    if !slotsExpanded {
                        Text(verbatim: slotsSummary)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            Divider()
            PresetLibraryView()

            Divider()
            AppsSection()

            Divider()
            AIPresetSection()

            Divider()
            ProfilesView()
        }
        .slotOverwriteConfirmation($confirmingSave)
    }

    private var connected: Bool {
        if case .connected = controller.connection { return true }
        return false
    }

    private var eqWriteRefusal: Text {
        Text("The 5K isn\u{2019}t taking EQ writes right now.")
    }

    private func commitRename(_ i: Int) {
        controller.setPresetName(i, draftName)
        renaming = nil
    }

    private func saveToSlot(_ i: Int) {
        if controller.presetNames[i] != nil {
            confirmingSave = i
        } else {
            controller.savePreset(i)
        }
    }

    private func presetRow(_ i: Int) -> some View {
        let isActive = controller.activePreset == i
        let named = controller.presetNames[i] != nil
        return HStack(spacing: 8) {
            Text("\(i + 1)")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 16, alignment: .trailing)
            if renaming == i {
                TextField("", text: $draftName,
                          prompt: Text("Name \u{2014} leave empty to clear"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .controlSize(.small)
                    .focused($nameFocused)
                    .onSubmit { commitRename(i) }
                Button("Save") { commitRename(i) }
                    .controlSize(.mini)
                    .font(.system(size: 10))
                Button("Cancel") { renaming = nil }
                    .controlSize(.mini)
                    .font(.system(size: 10))
            } else {
                Text(verbatim: controller.presetLabel(i))
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(named ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if isActive {
                    Text("active").font(.system(size: 9)).foregroundStyle(Color.accentColor)
                }
                Button {
                    draftName = controller.presetNames[i] ?? ""
                    renaming = i
                    nameFocused = true
                } label: {
                    Image(systemName: "pencil").font(.system(size: 9))
                        .accessibilityLabel(Text(verbatim: "Rename "
                                                 + controller.presetLabel(i)))
                }
                .controlSize(.mini)
                .disabled(!controller.canWriteNow)
                .help(Text("Rename this slot on the device."))
                Button("Load") { controller.loadPreset(i) }
                    .controlSize(.mini)
                    .disabled(!controller.canEditEqNow)
                    .font(.system(size: 10))
                    .accessibilityLabel(Text(verbatim: "Load "
                                             + controller.presetLabel(i)))
                    .help(controller.canEditEqNow
                          ? Text(verbatim: "Load " + controller.presetLabel(i))
                          : eqWriteRefusal)
                Button(Self.saveHereLabel) { saveToSlot(i) }
                    .controlSize(.mini)
                    .disabled(!controller.canEditEqNow)
                    .font(.system(size: 10))
                    .accessibilityLabel(Text(verbatim: "Save the current EQ to "
                                             + controller.presetLabel(i)))
                    .help(controller.canEditEqNow
                          ? Text("Overwrite this slot with the current EQ")
                          : eqWriteRefusal)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(isActive ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                             : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 5))
    }
}

struct SlotOverwriteConfirmation: ViewModifier {
    @EnvironmentObject var controller: QudelixController
    @Binding var pending: Int?

    func body(content: Content) -> some View {
        content.confirmationDialog(Text(PresetsView.overwriteTitle),
                                   isPresented: Binding(
                                       get: { pending != nil },
                                       set: { if !$0 { pending = nil } }),
                                   titleVisibility: .visible,
                                   presenting: pending) { slot in
            Button(PresetsView.saveHereLabel, role: .destructive) {
                controller.savePreset(slot)
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { slot in
            Text(verbatim: PresetsView.overwriteMessage(
                slot: slot, name: controller.presetNames[slot] ?? ""))
        }
    }
}

extension View {
    func slotOverwriteConfirmation(_ pending: Binding<Int?>) -> some View {
        modifier(SlotOverwriteConfirmation(pending: pending))
    }
}

struct UnsupportedDeviceView: View {
    @EnvironmentObject var controller: QudelixController
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("No settings have been changed.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            if let fw = controller.firmwareVersion {
                Text(verbatim: "Reported firmware \(fw)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 26)
    }
}

struct DisconnectedView: View {
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "cable.connector")
                .accessibilityHidden(true)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No Qudelix 5K found").font(.system(size: 12, weight: .medium))
            Text("Connect the 5K by USB, or switch it on nearby for Bluetooth.\nIt will appear here automatically.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

struct FooterBar: View {
    @EnvironmentObject var controller: QudelixController
    @EnvironmentObject var micGuard: A2dpGuard
    @Binding var showDiagnostics: Bool
    @Binding var showDeviceSettings: Bool
    @Binding var showAbout: Bool
    @Binding var showBattery: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showsVersion: true)
            row(showsVersion: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func row(showsVersion: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connected ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(connected ? "Connected" : "Waiting for device")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            if showsVersion {
                Text(verbatim: AboutView.versionLine)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }

            Spacer()

            if controller.hasPinnedBluetoothDevice {
                GlyphButton(action: { controller.forgetBluetoothDevice() }) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 10))
                        .accessibilityLabel("Forget the remembered Bluetooth device")
                }
                .help("Forget the remembered Bluetooth device and look for another")
            }

            Menu {
                Picker("Mic guard", selection: Binding(
                    get: { micGuard.mode },
                    set: { micGuard.setMode($0) })) {
                    ForEach(A2dpGuard.Mode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "mic")
                        .font(.system(size: 10))
                        .accessibilityHidden(true)
                    Text(verbatim: "Mic: " + micGuard.mode.shortLabel.lowercased())
                        .font(.system(size: 10))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Microphone guard: \(micGuard.mode.label)")
            .help("When something takes over your headphones' microphone, "
                  + "Bluetooth playback drops to voice quality — this can "
                  + "leave it alone, warn you, or put the Mac's built-in "
                  + "microphone back.")

            GlyphButton(action: {
                showDeviceSettings.toggle()
                if showDeviceSettings { showDiagnostics = false; showAbout = false; showBattery = false }
            }) {
                Label("Device", systemImage: "slider.horizontal.3")
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .fixedSize()
            }
            .disabled(!connected)
            .help("Device settings — channel trim, volume limit")

            GlyphButton(action: {
                showDiagnostics.toggle()
                if showDiagnostics { showDeviceSettings = false; showAbout = false; showBattery = false }
            }) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 10))
                    .accessibilityLabel("Diagnostics")
            }
            .help("Diagnostics")

            GlyphButton(action: {
                showAbout.toggle()
                if showAbout { showDeviceSettings = false; showDiagnostics = false; showBattery = false }
            }) {
                Image(systemName: "info.circle").font(.system(size: 10))
                    .accessibilityLabel("About \(AboutView.appName)")
            }
            .help("About \(AboutView.appName) \(AboutView.versionLine)")

            GlyphButton(action: { NSApp.terminate(nil) }) {
                Image(systemName: "power").font(.system(size: 10))
                    .accessibilityLabel("Quit \(AboutView.appName)")
            }
            .help("Quit Qudelix")
        }
    }

    private var connected: Bool {
        if case .connected = controller.connection { return true }
        return false
    }
}

struct DiagnosticsView: View {
    @ObservedObject var log = DebugLog.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.lines.joined(separator: "\n"),
                                                   forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .disabled(log.lines.isEmpty)
                .help("Copy everything shown here to the clipboard")

                if let url = log.fileURL {
                    Button("Reveal log") {
                        NSApp.activate(ignoringOtherApps: true)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .help("Show the full log file in Finder. It records the names "
                          + "of your audio devices — worth a glance before sending it.")
                }
                Spacer()
                Text("\(log.lines.count) lines")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .font(.system(size: 10))

            transcript
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .id(idx)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(5)
            }
            .frame(height: 110)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: log.lines.count) { _, n in
                withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
    }
}
