#if DEBUG
import SwiftUI
import AppKit

/// Development aid: `Qudelix.app/Contents/MacOS/QudelixBar --render-ui <dir>`
/// renders the popover to PNGs with mock state, so the layout can be checked
/// without a device attached. Never runs during normal launch.
/// The translucent material a real menu bar popover sits on.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

enum UIPreview {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-ui") {
            let dir = i + 1 < args.count ? args[i + 1] : NSTemporaryDirectory()
            render(into: URL(fileURLWithPath: dir))
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-shots") {
            let dir = i + 1 < args.count ? args[i + 1] : NSTemporaryDirectory()
            renderShots(into: URL(fileURLWithPath: dir))
            exit(0)
        }
    }

    /// Screenshots for the README.
    ///
    /// `ImageRenderer` cannot draw AppKit-backed controls (sliders, pickers,
    /// toggles all come out as placeholders). Hosting the same views in a real
    /// offscreen NSWindow and calling `cacheDisplay` makes AppKit draw them for
    /// real, so these are genuine renderings of the shipping UI rather than
    /// mock-ups — and it needs no Screen Recording permission.
    @MainActor
    private static func renderShots(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for (name, scheme) in [("light", NSAppearance(named: .aqua)),
                               ("dark", NSAppearance(named: .darkAqua))] {
            for (pane, controller, stage) in mocks() {
                let root = PopoverView()
                    .environmentObject(controller)
                    .environmentObject(stage)
                    .environmentObject(ProfileRules())
                    .environmentObject(ABTuner())
                    .environmentObject(ToneTester())
                    .frame(width: 400)
                    .background(VisualEffectBackground())

                let hosting = NSHostingView(rootView: root)
                hosting.appearance = scheme
                let fitting = hosting.fittingSize
                hosting.frame = NSRect(origin: .zero,
                                       size: CGSize(width: 400, height: max(fitting.height, 200)))

                // A real window, parked far offscreen so nothing flashes on
                // screen; controls only draw correctly inside one.
                let window = NSWindow(contentRect: hosting.frame,
                                      styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.appearance = scheme
                window.isOpaque = false
                window.backgroundColor = .clear
                window.contentView = hosting
                window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                window.orderFrontRegardless()
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.35))

                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                    window.close(); continue
                }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("\(pane)-\(name).png"))
                }
                window.close()
            }
        }
        print("shots written to \(dir.path)")
    }

    @MainActor
    private static func render(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            for (pane, controller, stage) in mocks() {
                let view = PopoverView()
                    .environmentObject(controller)
                    .environmentObject(stage)
                    .environmentObject(ProfileRules())
                    .environmentObject(ABTuner())
                    .environmentObject(ToneTester())
                    .environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.96))

                let renderer = ImageRenderer(content: AnyView(view))
                renderer.scale = 2
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { continue }
                try? png.write(to: dir.appendingPathComponent("popover-\(pane)-\(name).png"))
            }
        }
        print("rendered to \(dir.path)")
    }

    @MainActor
    private static func mocks() -> [(String, QudelixController, StageState)] {
        [("eq", make(.equalizer), stageMock()),
         ("presets", make(.presets), stageMock()),
         ("import", make(.importing), stageMock()),
         ("tune", make(.tune), stageMock()),
         ("stage", make(.stage), stageMock(running: true)),
         ("level", make(.level), levelMock()),
         ("disconnected", disconnected(), stageMock(running: true)),
         ("unsupported", unsupported(), stageMock()),
         ("b20", twentyBand(), stageMock()),
         ("lowbatt", lowBattery(), stageMock())]
    }

    /// Header treatment at a very low battery: red glyph, warning in the
    /// status line.
    @MainActor
    private static func lowBattery() -> QudelixController {
        let c = make(.equalizer)
        c.batteryPercent = 8
        c.charging = false
        return c
    }

    /// Stage pane state: the Movie preset active on the built-in speakers,
    /// with a running engine so the pane shows its live face.
    @MainActor
    private static func stageMock(running: Bool = false) -> StageState {
        let s = StageState()
        var stage = StageSettings.movie
        stage.enabled = running
        s.previewSet(stage: stage, exposure: exposureMock(),
                     currentDb: running ? -21 : nil)
        s.watcher.previewSetDevices(
            [AudioOutput(id: 1, uid: "mock-speakers",
                         name: "MacBook Pro Speakers", sampleRate: 48000),
             AudioOutput(id: 2, uid: "mock-qudelix",
                         name: "Qudelix-5K USB DAC", sampleRate: 96000)],
            defaultUID: "mock-speakers")
        if running {
            s.engine.previewSetRunning(true, status: "Stage active → MacBook Pro Speakers @ 48 kHz")
        }
        return s
    }

    /// Level pane state: tracking on, a live meter, and a week of history.
    @MainActor
    private static func levelMock() -> StageState {
        let s = stageMock()
        var stage = StageSettings()
        stage.enabled = false
        s.previewSet(stage: stage, exposure: exposureMock(),
                     currentDb: -23, levelTracking: true,
                     verdict: .losslessLike(cutoffKHz: 21.9))
        s.engine.previewSetRunning(true, status: "Metering → MacBook Pro Speakers @ 48 kHz")
        return s
    }

    @MainActor
    private static func exposureMock() -> [DayExposure] {
        // A believable fortnight, todays entry included so the pane shows
        // both the live section and the history.
        let today = StageState.dayKey()
        let calendar = Calendar.current
        var days: [DayExposure] = (1...7).reversed().compactMap { back in
            guard let date = calendar.date(byAdding: .day, value: -back, to: Date())
            else { return nil }
            let seconds = [4100.0, 7900, 2400, 9800, 6300, 300, 5200][back - 1]
            return DayExposure(day: StageState.dayKey(date),
                               audibleSeconds: seconds,
                               loudSeconds: seconds * [0.1, 0.4, 0, 0.55, 0.2, 0, 0.15][back - 1],
                               energySum: seconds * 3e-3)
        }
        days.append(DayExposure(day: today, audibleSeconds: 4520,
                                loudSeconds: 610, energySum: 4520 * 4.2e-3))
        return days
    }

    @MainActor
    private static func make(_ pane: PopoverView.Pane) -> QudelixController {
        let c = QudelixController()
        c.connection = .connected(name: "Qudelix-5K USB DAC 96KHz")
        // Without this the Tune pane renders its "unsupported device" warning and
        // a disabled Start button, which is not what the pane looks like in use.
        c.compatibility = .ok
        c.firmwareVersion = "3.1.8"
        c.batteryPercent = 81
        c.charging = true
        c.sampleRate = "96 kHz"
        c.inputSource = "USB"
        c.volumeDb = -24
        c.volumeMax = 6
        c.eqEnabled = true
        c.usbFsMode = 0   // pinned to 96 (wire order is descending) — renders the warning state
        c.trimLeftDb = 0
        c.trimRightDb = -1.5
        c.volumeLimitDb = 0
        c.dacFilterType = 3
        c.crossfeedLevel = 0
        c.preGain = -6.1
        c.activePreset = 2
        c.presetNames = [0: "Harman", 2: "HD 650", 5: "Bass boost"]
        // A realistic AutoEq-style curve (Sennheiser HD 650, oratory1990).
        c.bands = [
            .init(filter: .lowShelf, freq: 105, gain: 6.4, q: 0.70),
            .init(filter: .peak, freq: 8800, gain: 5.1, q: 1.42),
            .init(filter: .peak, freq: 118, gain: -3.1, q: 0.50),
            .init(filter: .peak, freq: 37, gain: 0.7, q: 3.96),
            .init(filter: .peak, freq: 3169, gain: -1.7, q: 3.89),
            .init(filter: .highShelf, freq: 10000, gain: -2.1, q: 0.70),
            .init(filter: .peak, freq: 1227, gain: -1.2, q: 2.53),
            .init(filter: .peak, freq: 2055, gain: 1.2, q: 3.23),
            .init(filter: .peak, freq: 587, gain: 0.4, q: 1.19),
            .init(filter: .peak, freq: 5332, gain: -1.1, q: 5.75),
        ]
        c.previewPane = pane
        if pane == .importing {
            c.previewAutoEq = (entries: [
                AutoEqEntry(title: "Sennheiser HD 650", source: "oratory1990",
                            path: "oratory1990/over-ear/Sennheiser%20HD%20650"),
                AutoEqEntry(title: "Sennheiser HD 660S", source: "oratory1990",
                            path: "oratory1990/over-ear/Sennheiser%20HD%20660S"),
                AutoEqEntry(title: "Sennheiser HD 600", source: "crinacle",
                            path: "crinacle/harman_over-ear_2018/Sennheiser%20HD%20600"),
                AutoEqEntry(title: "Sennheiser HD 6XX", source: "oratory1990",
                            path: "oratory1990/over-ear/Sennheiser%20HD%206XX"),
                AutoEqEntry(title: "Sennheiser HD 560S", source: "oratory1990",
                            path: "oratory1990/over-ear/Sennheiser%20HD%20560S"),
                AutoEqEntry(title: "Sennheiser HD 800 S", source: "oratory1990",
                            path: "oratory1990/over-ear/Sennheiser%20HD%20800%20S"),
                AutoEqEntry(title: "Sennheiser HD 25", source: "crinacle",
                            path: "crinacle/harman_over-ear_2018/Sennheiser%20HD%2025"),
            ], query: "HD")
        }
        return c
    }

    @MainActor
    private static func twentyBand() -> QudelixController {
        let c = make(.equalizer)
        c.applyPreviewGroup(.b20)
        // A plausible 20-band curve so the table and graph have real content.
        let gains: [Double] = [5.5, 4.0, 2.5, 1.0, -0.5, -2.0, -3.0, -2.5, -1.0, 0.5,
                               1.5, 2.0, 1.0, -1.5, -3.0, -2.0, 0.5, 3.0, 1.5, -2.0]
        c.bands = zip(QxEqGroup.b20.defaultFreqs, gains).map { f, g in
            QxEqBandValue(filter: .peak, freq: f, gain: g, q: 1.0)
        }
        c.preGain = -5.5
        return c
    }

    @MainActor
    private static func unsupported() -> QudelixController {
        let c = make(.equalizer)
        c.firmwareVersion = "2.4.1"
        c.compatibility = .unsupported(
            title: "Firmware 2.4.1 uses a different protocol",
            detail: "Qudelix changed the EQ command format in firmware 3. "
                  + "Update with the official app, then reconnect.")
        return c
    }

    @MainActor
    private static func disconnected() -> QudelixController {
        let c = QudelixController()
        c.connection = .disconnected
        return c
    }
}
#endif
