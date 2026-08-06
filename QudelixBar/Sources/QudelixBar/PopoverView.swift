import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var controller: QudelixController
    @State private var pane: Pane = .equalizer
    @State private var showDiagnostics = false
    @State private var editingBand: Int?

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
    /// 10-band EQ table, plus the USB-audio row; every other pane top-aligns
    /// into the same space, and Stage/Level scroll internally if they ever
    /// exceed it.
    private static let contentHeight: CGFloat = 592

    var body: some View {
        VStack(spacing: 0) {
            DeviceHeader()
            Divider()
                .onAppear { if let p = controller.previewPane { pane = p } }

            if case .unsupported(let title, let detail) = controller.compatibility, connected {
                UnsupportedDeviceView(title: title, detail: detail)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.contentHeight)
            } else if connected {
                // No outer ScrollView on purpose: the panes that can grow
                // (presets, search results, diagnostics) scroll internally, so
                // nesting one here would trap scroll gestures.
                VStack(spacing: 14) {
                    EQCurveView(bands: controller.bands,
                                preGain: controller.preGain,
                                highlighted: editingBand)
                        .frame(height: 104)

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
                    case .presets: PresetsView()
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
                .padding(14)
                .frame(height: Self.contentHeight)
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
                .onAppear { if pane.needsDevice { pane = .stage } }
            }

            Divider()
            FooterBar(showDiagnostics: $showDiagnostics)
            if showDiagnostics {
                Divider()
                DiagnosticsView().padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
        .frame(width: 400)
    }

    private var connected: Bool {
        if case .connected = controller.connection { return true }
        return false
    }
}

// MARK: - Header

struct DeviceHeader: View {
    @EnvironmentObject var controller: QudelixController

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

            Button { controller.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!connected)
            .help("Refresh from device")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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
            let available = AudioOutputs.availableNominalRates(device.id)
            let rates = available.isEmpty ? [44100, 48000, 88200, 96000] : available
            HStack(spacing: 8) {
                Text("USB audio")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { device.sampleRate },
                    set: { stageState.setNominalRate($0, for: device) })) {
                    ForEach(rates, id: \.self) { r in
                        Text(Self.kHz(r)).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .labelsHidden()
                Text("kHz")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                if let bits = AudioOutputs.outputBitDepth(device.id) {
                    Text("\(bits)-bit")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .onAppear { stageState.watcher.refreshNow() }
            .help("The rate macOS runs the Qudelix at — the same setting as "
                  + "Audio MIDI Setup. macOS resamples anything at a different "
                  + "rate and never switches this automatically, so match your "
                  + "library: most music is 44.1 kHz, most video 48 kHz. "
                  + "While Soundstage is on, audio is processed on the Mac and "
                  + "resampling happens regardless.")
        }
    }

    private static func kHz(_ rate: Double) -> String {
        String(format: "%g", rate / 1000)
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

                Spacer()

                Text("Pre-gain").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { controller.preGain },
                                      set: { controller.setPreGain($0) }),
                       in: -12...12, step: 0.5)
                    .frame(width: 92)
                Text(String(format: "%+.1f", controller.preGain))
                    .font(.system(size: 10).monospacedDigit())
                    .frame(width: 30, alignment: .trailing)
            }

            Divider()

            bandTable
                .opacity(controller.eqEnabled ? 1 : 0.45)
                .disabled(!controller.eqEnabled)

            HStack {
                Button("Flatten") { controller.flatten() }
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
                Text("bands")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu("Save to preset…") {
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
}

extension EqEditorView {
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

            Text(String(format: "%+.1f", band.gain))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(band.gain == 0 ? .secondary : .primary)
                .frame(width: 32, alignment: .trailing)

            TextField("", value: Binding(get: { band.q }, set: { set { $0.q = $1 } ($0) }),
                      format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .controlSize(.mini)
                .font(.system(size: 10).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 42)
        }
        .opacity(band.filter == .bypass ? 0.45 : 1)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.activePreset == nil || controller.activePreset == 255 {
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
            .frame(height: 190)
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
            Text(controller.presetLabel(i))
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(named ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if isActive {
                Text("active").font(.system(size: 9)).foregroundStyle(Color.accentColor)
            }
            Button("Load") { controller.loadPreset(i) }
                .controlSize(.mini)
                .font(.system(size: 10))
            Button {
                controller.savePreset(i)
            } label: {
                Image(systemName: "square.and.arrow.down").font(.system(size: 9))
            }
            .controlSize(.mini)
            .help("Overwrite this slot with the current EQ")
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
                Text("Reported firmware \(fw)")
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
    @Binding var showDiagnostics: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connected ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(connected ? "Connected" : "Waiting for device")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Spacer()

            // The Bluetooth device is remembered on first connection so nothing
            // else can be adopted later. That is the right default, but it needs
            // an escape hatch: without one, pairing to the wrong device once left
            // no way back short of editing preferences by hand.
            if controller.hasPinnedBluetoothDevice {
                Button { controller.forgetBluetoothDevice() } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Forget the remembered Bluetooth device and look for another")
            }

            Button { showDiagnostics.toggle() } label: {
                Image(systemName: "waveform.path.ecg").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("Diagnostics")

            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 10))
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

    var body: some View {
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
