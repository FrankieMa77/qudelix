import CoreAudio
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var controller: QudelixController
    @State private var pane: Pane = .equalizer
    @State private var showDiagnostics = false
    @State private var showDeviceSettings = false
    @State private var showAbout = false
    @State private var editingBand: Int?
    @State private var selectedBand: Int?
    @EnvironmentObject private var profileRules: ProfileRules
    @EnvironmentObject private var micGuard: A2dpGuard
    @EnvironmentObject private var suggestions: HeadphoneSuggestions

    enum Pane: String, CaseIterable, Identifiable {
        // "EQ", not "Equalizer": six segments share the popover's width now,
        // and the long name is what the curve above it already says.
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
        /// The Stage and Level features run on the Mac, not the 5K, so their
        /// panes work with the device away.
        var needsDevice: Bool {
            switch self {
            case .stage, .level: return false
            default: return true
            }
        }
    }

    /// Height of everything between the header and the footer, fixed so the
    /// window doesn't resize when switching panes — the jumping was the
    /// annoyance, not any one size. Sized to fit the tallest pane, the
    /// 10-band EQ table, plus the two USB-audio rows; every other pane
    /// top-aligns into the same space, and Stage/Level scroll internally if
    /// they ever exceed it.
    static let contentHeight: CGFloat = 675

    var body: some View {
        VStack(spacing: 0) {
            DeviceHeader()
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
                // The notice explains what this app will not do with *this*
                // device — but Stage and Level run on the Mac and have nothing
                // to do with which model is attached, so they stay reachable
                // for the same reason the disconnected branch below keeps them:
                // an enabled Soundstage must never need a supported device
                // present in order to be switched off.
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

                        if pane == .level {
                            ScrollView { LevelView() }
                        } else {
                            ScrollView { StageView() }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(14)
                }
                .frame(height: Self.contentHeight)
                .clipped()
                .onAppear { if pane.needsDevice { pane = .stage } }
            } else if connected {
                // No outer ScrollView on purpose: the panes that can grow
                // (presets, search results, diagnostics) scroll internally, so
                // nesting one here would trap scroll gestures.
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
                                // Straight through `updateBand`, so a drag is
                                // gated, clamped and coalesced exactly like the
                                // slider it replaces — no second write path.
                                onBandChanged: { controller.updateBand($0, $1) },
                                onDragBand: { editingBand = $0 })
                        .frame(height: 104)

                    if pane == .equalizer {
                        BandInspector(selected: $selectedBand)
                    }

                    VolumeControl()

                    UsbAudioRow()

                    Picker("", selection: $pane) {
                        ForEach(Pane.allCases) { p in
                            Label(p.rawValue, systemImage: p.icon).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch pane {
                    case .equalizer: EqEditorView(editingBand: $editingBand)
                    case .presets: ScrollView { PresetsView() }
                    case .importing: ImportView()
                    // Tune, Stage and Level can outgrow the fixed pane area
                    // (a tone result with both warnings, the geometry
                    // disclosure, a long history), so they scroll inside it
                    // rather than resizing the window.
                    case .tune: ScrollView { TuneView() }
                    case .stage: ScrollView { StageView() }
                    case .level: ScrollView { LevelView() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
                .padding(14)
                .frame(height: Self.contentHeight)
                .clipped()
            } else {
                VStack(spacing: 0) {
                    DisconnectedView()
                    // Stage and Level act on the Mac's own audio, so they stay
                    // reachable with the 5K away — an enabled stage must never
                    // need the device present to be switched off.
                    Divider()
                    VStack(spacing: 14) {
                        Picker("", selection: $pane) {
                            ForEach(Pane.allCases.filter { !$0.needsDevice }) { p in
                                Label(p.rawValue, systemImage: p.icon).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if pane == .level {
                            ScrollView { LevelView() }
                        } else {
                            ScrollView { StageView() }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(14)
                }
                .frame(height: Self.contentHeight)
                .clipped()
                .onAppear { if pane.needsDevice { pane = .stage } }
            }

            Divider()
            FooterBar(showDiagnostics: $showDiagnostics,
                      showDeviceSettings: $showDeviceSettings,
                      showAbout: $showAbout)
            if showAbout {
                Divider()
                AboutView().padding(.horizontal, 14).padding(.bottom, 10)
            }
            if showDeviceSettings {
                Divider()
                DeviceSettingsView().padding(.horizontal, 14).padding(.bottom, 10)
            }
            if showDiagnostics {
                Divider()
                DiagnosticsView().padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
        .frame(width: 400)
        .onChange(of: editingBand, initial: true) { _, band in
            profileRules.editingNow = band != nil
        }
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
                VStack(alignment: .leading, spacing: 1) {
                    (Text(verbatim: hijack.name) + Text(" took the microphone"))
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                    Text(A2dpGuard.bannerDetail(
                        reason: hijack.reason,
                        isTheDevice: A2dpGuard.isTheDevice(
                            hijackName: hijack.name, connectedName: connectedName),
                        deviceInputSource: controller.inputSource))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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
                        .lineLimit(1)
                    Text(verbatim: HeadphoneSuggestions.bannerDetail(
                        source: offered.entry.source, bandCount: controller.bandCount))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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

// MARK: - Header

struct DeviceHeader: View {
    @EnvironmentObject var controller: QudelixController
    @EnvironmentObject var stageState: StageState

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
                Text(deviceName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    if let icon = linkIcon {
                        Image(systemName: icon)
                            .accessibilityHidden(true)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .help(linkHelp)
                    }
                    Text(statusLine)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if let batt = controller.batteryPercent {
                HStack(spacing: 3) {
                    // A plain bolt, not battery.100.bolt — the bolt inside
                    // the battery glyph is a few pixels tall and unreadable.
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
                .background(.quaternary.opacity(0.5), in: Capsule())
                .help(batteryHelp(batt))
            }

            if stageState.callActive {
                Image(systemName: "phone.badge.waveform.fill")
                    .accessibilityLabel("On a call")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help("Something is using the headset's microphone, so "
                          + "Bluetooth has dropped to call mode (HFP) at voice "
                          + "quality. The muffled sound is the codec, not the EQ.")
            }

            Button { controller.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .accessibilityLabel("Re-read the device")
            }
            .buttonStyle(.borderless)
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
        // Device-supplied: the USB product string or the BLE advertised name. The
        // same sanitiser the preset names use — a 500-character or bidi-override
        // product name would otherwise distort the header.
        let cleaned = QudelixController.displayName(
            n.replacingOccurrences(of: " USB DAC 96KHz", with: ""))
        return cleaned.isEmpty ? "Qudelix" : cleaned
    }
    /// Which link is carrying the protocol. Worth surfacing: the two behave
    /// differently — USB is faster and always available, Bluetooth works away
    /// from the cable but drops when the device sleeps.
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
        guard connected else { return "Not connected" }
        var parts: [String] = []
        switch controller.link {
        case .usb: parts.append("USB")
        case .bluetooth: parts.append("Bluetooth")
        case .none: break
        }
        if let fw = controller.firmwareVersion { parts.append("FW \(fw)") }
        if let codec = controller.codecLabel, codec != "None" { parts.append(codec) }
        if let sr = controller.sampleRate, controller.inputSource != "None" { parts.append(sr) }
        if let src = controller.inputSource, src != "None" { parts.append(src) } else { parts.append("idle") }
        if let b = controller.batteryPercent {
            if controller.charging {
                parts.append("charging")
            } else if b <= BatteryAlerts.veryLowThreshold {
                parts.append("battery very low")
            } else if b <= BatteryAlerts.lowThreshold {
                parts.append("battery low")
            }
        }
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
    private func batteryHelp(_ p: Int) -> String {
        // With battery care on, a plugged-in 5K sitting well short of full is
        // the normal, healthy state — so the hover has to be able to say
        // "plugged in, not charging" rather than leave it looking broken.
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

// MARK: - Volume

struct VolumeControl: View {
    @EnvironmentObject var controller: QudelixController

    var body: some View {
        HStack(spacing: 10) {
            Button { controller.setMute(!controller.muted) } label: {
                Image(systemName: controller.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .accessibilityLabel(controller.muted ? "Unmute" : "Mute")
                    .font(.system(size: 12))
                    .foregroundStyle(controller.muted ? .orange : .secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(controller.muted ? "Unmute" : "Mute")

            Slider(value: Binding(get: { controller.volumeDb },
                                  set: { controller.setVolume($0) }),
                   in: controller.volumeRange)
                .disabled(controller.muted)

            Text(String(format: "%.1f", controller.volumeDb))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .frame(width: 34, alignment: .trailing)
            Text("dB").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - USB audio rate

/// The rate macOS runs the 5K's USB audio at. One fixed rate at a time —
/// macOS resamples everything else to it and never switches automatically —
/// so matching the library (music is usually 44.1 kHz) is what makes
/// playback bit-perfect. Hidden when the 5K's audio isn't on USB.
struct UsbAudioRow: View {
    @EnvironmentObject var stageState: StageState

    var body: some View {
        if let device = stageState.qudelixOutput {
            UsbAudioRateRow(device: device)
        }
    }
}

private struct UsbAudioRateRow: View {
    let device: AudioOutput
    @EnvironmentObject var stageState: StageState
    @EnvironmentObject var controller: QudelixController
    // Cached: both are mach round-trips into coreaudiod, and this body
    // re-evaluates on every publish (once a second with the meter running).
    // Refreshed when the row appears and when the device identity changes.
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
                // The picker above can only choose among rates the 5K's USB
                // descriptor OFFERS; the device can pin itself to a single
                // one. This menu changes the offering itself — labelled with
                // words, because an icon here reads as anything but "rates".
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
            .help("The rate macOS runs the Qudelix at — the same setting as "
                  + "Audio MIDI Setup. macOS resamples anything at a different "
                  + "rate and never switches this automatically, so match your "
                  + "library: most music is 44.1 kHz, most video 48 kHz. "
                  + "While Soundstage is on, audio is processed on the Mac and "
                  + "resampling happens regardless.")

            // The automation must never act silently: this line is its
            // on/off switch AND its running commentary — what it heard,
            // what it did about it.
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
        let rates = availableRates.isEmpty ? [device.sampleRate] : availableRates
        let binding = Binding<Double>(
            get: { device.sampleRate },
            // manual: the user's own pick is the baseline that auto rate
            // switching returns to on lossy content.
            set: { stageState.setNominalRate($0, for: device, manual: true) })
        return Picker("", selection: binding) {
            ForEach(rates, id: \.self) { r in
                Text(Self.kHz(r)).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .labelsHidden()
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
        // "Waiting for audio" was said for every reason the engine was not
        // running, including the common one on a fresh install: the system
        // audio permission has not been granted, so it never started and never
        // will until it is. Naming the real reason is the whole point of the
        // line — this is the popover's main surface, and the pane that carries
        // the full explanation is two clicks away.
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

    /// Compact form of the pinned modes for the menu label ("96 only").
    /// Wire order — descending rates, then the mic modes.
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

// MARK: - Equalizer pane

struct EqEditorView: View {
    @EnvironmentObject var controller: QudelixController
    @Binding var editingBand: Int?

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
                Text(String(format: "%+.1f", controller.preGain))
                    .font(.system(size: 10).monospacedDigit())
                    .frame(width: 30, alignment: .trailing)
            }

            headroomRow

            Divider()

            bandTable
                .opacity(controller.eqEnabled ? 1 : 0.45)
                .disabled(!controller.eqEnabled)

            HStack {
                Button("Flatten") { controller.flatten() }
                    .help("Take every band's gain to zero, keeping the "
                          + "frequencies, filter types and Q they have now.")
                Button("Reset") { controller.resetBandLayout() }
                    .help("Put the bands back to the factory layout for this mode: "
                          + "peak filters on the default frequencies, 0 dB, Q 1.")
                // Reflects the device's mode and asks it to switch; the
                // selection only moves once the device confirms, so a brief
                // lag after clicking is the round trip, not a lost click.
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
                .help("EQ bands. The two modes keep separate presets, so "
                      + "switching changes the active curve.")
                Spacer()
                if let active = controller.activePreset {
                    Button("Update") { controller.savePreset(active) }
                        .disabled(!controller.canWriteNow)
                        .help("Overwrite \(controller.presetLabel(active)) with the current EQ")
                }
                Menu("Save to…") {
                    ForEach(0..<QudelixController.presetCount, id: \.self) { i in
                        Button(controller.presetLabel(i)) { controller.savePreset(i) }
                    }
                }
                .fixedSize()
            }
            .controlSize(.small)
            .font(.system(size: 11))
        }
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
    /// Says what the curve's boosts cost in headroom, and offers the pre-gain
    /// that cancels them.
    ///
    /// Offered, never applied on its own: pre-gain is a number people set
    /// deliberately, and moving it under them would be a change to the sound
    /// they never asked for. When the curve already has the headroom the row
    /// says so and drops the button: a sentence that reports the state is
    /// worth more than a control that would change nothing.
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
        // Below a tenth of a dB there is nothing the device could store, so
        // treat it as no boost at all rather than reporting "+0.0".
        guard advice.peakBoost >= 0.05 else { return "No band boost to offset." }
        let boost = String(format: "Bands boost by up to %.1f dB", advice.peakBoost)
        if advice.shortfall >= 0.05 {
            return boost + String(format: " — %.1f dB more than pre-gain can take back.",
                                  advice.shortfall)
        }
        return advice.suggestion == nil ? boost + "; pre-gain covers it." : boost + "."
    }

    /// 10 bands fit inline; 20 would add ~250pt to the window, so the table
    /// scrolls in that case. The height is definite, not a maximum — a scroll
    /// view given only a max collapses inside this self-sizing popover.
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
        if controller.bandCount > 10 {
            ScrollView { grid.padding(.trailing, 4) }
                .frame(height: 250)
        } else {
            grid
        }
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

struct BandRow: View {
    @EnvironmentObject var controller: QudelixController
    let index: Int
    @Binding var editingBand: Int?

    var body: some View {
        // The device chooses the band count: a reported eq_mode change swaps
        // `bands` between 10 and 20 entries underneath the view. An in-flight
        // AppKit control — a slider mid-drag, a text field losing focus — can
        // fire its setter after the row it belongs to has gone, so neither the
        // read here nor the one in `set` may assume this index still exists.
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

            // No thousands separator: in a European locale `.number` renders
            // 8800 Hz as "8.800", which reads as 8.8.
            TextField("", value: Binding(get: { band.freq }, set: { set { $0.freq = $1 } ($0) }),
                      format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .controlSize(.mini)
                .font(.system(size: 10).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 50)

            Slider(value: Binding(get: { band.gain }, set: { set { $0.gain = $1 } ($0) }),
                   in: -12...12,
                   onEditingChanged: { editing in editingBand = editing ? index : nil })
                .controlSize(.mini)
                .disabled(!editsGain)

            Text(editsGain ? String(format: "%+.1f", band.gain) : "—")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(editsGain && band.gain != 0 ? .primary : .secondary)
                .frame(width: 32, alignment: .trailing)

            TextField("", value: Binding(get: { band.q }, set: { set { $0.q = $1 } ($0) }),
                      format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .controlSize(.mini)
                .font(.system(size: 10).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 42)

            // The band's gain stays on the device while it is muted, so this
            // is a straight there-and-back: no value is parked anywhere that
            // a preset load or another app's write could take away.
            Button {
                controller.setBandMuted(index, !muted)
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2")
                    .accessibilityLabel(muted ? "Unmute band \(index + 1)"
                                              : "Mute band \(index + 1)")
                    .font(.system(size: 9))
                    .foregroundStyle(muted ? Color.orange : Color.secondary)
            }
            .buttonStyle(.borderless)
            .frame(width: 16)
            .disabled(band.filter == .bypass && !muted)
            .help(muted ? "Bring this band back — its gain hasn't changed"
                        : "Silence this band, keeping its gain")
        }
        // A muted row is dimmed like any bypassed one, but less: it is a
        // state the user is actively listening against, and the gain they
        // are judging has to stay readable while it is off.
        .opacity(band.filter == .bypass ? (muted ? 0.62 : 0.45) : 1)
    }

    /// Mutate one field of this band and push it to the device.
    private func set<T>(_ apply: @escaping (inout QxEqBandValue, T) -> Void) -> (T) -> Void {
        { newValue in
            guard controller.bands.indices.contains(index) else { return }
            var b = controller.bands[index]
            apply(&b, newValue)
            controller.updateBand(index, b)
        }
    }
}

// MARK: - Presets pane

struct PresetsView: View {
    @EnvironmentObject var controller: QudelixController
    /// Which slot is being renamed, and the text so far. Held here rather than
    /// per row so only one row can be in edit mode at a time.
    @State private var renaming: Int?
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("On the 5K").font(.system(size: 11, weight: .medium))
            if controller.activePreset == nil {
                Text("Current EQ is a custom setting, not a saved slot.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(0..<QudelixController.presetCount, id: \.self) { i in
                        presetRow(i)
                    }
                }
            }
            .frame(height: 64)

            Divider()
            PresetLibraryView()

            Divider()
            AppsSection()

            Divider()
            AIPresetSection()

            Divider()
            ProfilesView()
        }
    }

    private func commitRename(_ i: Int) {
        controller.setPresetName(i, draftName)
        renaming = nil
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
                TextField("", text: $draftName)
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
                Text(controller.presetLabel(i))
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
                        .accessibilityLabel("Rename \(controller.presetLabel(i))")
                }
                .controlSize(.mini)
                .disabled(!controller.canWriteNow)
                .help("Rename this slot on the device. Clear the text to remove the name.")
                Button("Load") { controller.loadPreset(i) }
                    .controlSize(.mini)
                    .disabled(!controller.canEditEqNow)
                    .font(.system(size: 10))
                Button {
                    controller.savePreset(i)
                } label: {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 9))
                        .accessibilityLabel("Save the current EQ to \(controller.presetLabel(i))")
                }
                .controlSize(.mini)
                .help("Overwrite this slot with the current EQ")
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(isActive ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                             : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Disconnected / footer / diagnostics

/// Shown instead of the controls when the handshake identifies a device whose
/// protocol we don't implement. Nothing is written in this state.
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

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connected ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(connected ? "Connected" : "Waiting for device")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text(verbatim: AboutView.versionLine)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize()

            Spacer()

            // The Bluetooth device is remembered on first connection so nothing
            // else can be adopted later. That is the right default, but it needs
            // an escape hatch: without one, pairing to the wrong device once left
            // no way back short of editing preferences by hand.
            if controller.hasPinnedBluetoothDevice {
                Button { controller.forgetBluetoothDevice() } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 10))
                        .accessibilityLabel("Forget the remembered Bluetooth device")
                }
                .buttonStyle(.borderless)
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
                    Text("Mic \(micGuard.mode.shortLabel)")
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

            // Worded, not a bare icon: an unlabelled glyph in a row of glyphs
            // is indistinguishable from decoration, and these settings are
            // the kind you go looking for exactly once.
            Button {
                showDeviceSettings.toggle()
                if showDeviceSettings { showDiagnostics = false; showAbout = false }
            } label: {
                Label("Device", systemImage: "slider.horizontal.3")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .disabled(!connected)
            .help("Device settings — channel trim, volume limit")

            Button {
                showDiagnostics.toggle()
                if showDiagnostics { showDeviceSettings = false; showAbout = false }
            } label: {
                Image(systemName: "waveform.path.ecg").font(.system(size: 10))
                    .accessibilityLabel("Diagnostics")
            }
            .buttonStyle(.borderless)
            .help("Diagnostics")

            Button {
                showAbout.toggle()
                if showAbout { showDeviceSettings = false; showDiagnostics = false }
            } label: {
                Image(systemName: "info.circle").font(.system(size: 10))
                    .accessibilityLabel("About \(AboutView.appName)")
            }
            .buttonStyle(.borderless)
            .help("About \(AboutView.appName) \(AboutView.versionLine)")

            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 10))
                    .accessibilityLabel("Quit \(AboutView.appName)")
            }
            .buttonStyle(.borderless)
            .help("Quit Qudelix")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
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
            // What a bug report actually needs. Selecting a few hundred
            // monospaced lines out of a scroll view by dragging is a job
            // nobody should be asked to do to report a fault.
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
