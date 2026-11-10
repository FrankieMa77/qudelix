// swift-tools-version:5.9
import PackageDescription

let appleOnlySources = [
    "A2dpGuard.swift",
    "AboutView.swift",
    "ABTuner.swift",
    "AccelerateFFT.swift",
    "AIKeychain.swift",
    "AIPresetSection.swift",
    "App.swift",
    "AppAssignments.swift",
    "AppsSection.swift",
    "AudioOutputs.swift",
    "AutomationPanel.swift",
    "AutomationReadout.swift",
    "AutoTrim.swift",
    "BatteryHistoryView.swift",
    "BLETransport.swift",
    "BlindTuner.swift",
    "Convolver.swift",
    "DeviceSettingsView.swift",
    "EqAutomation.swift",
    "EQCurveView.swift",
    "HIDTransport.swift",
    "ImportView.swift",
    "LevelView.swift",
    "Notifier.swift",
    "PopoverView.swift",
    "PresetLibraryView.swift",
    "ProfileRulesLink.swift",
    "ProfilesView.swift",
    "QudelixController.swift",
    "SignalPathView.swift",
    "StageEngine.swift",
    "StageProcessor.swift",
    "StageState.swift",
    "StageView.swift",
    "StatusIcon.swift",
    "ToneTester.swift",
    "TuneView.swift",
    "UIPreview.swift"
]

let appleOnlyTests = [
    "A2dpGuardTests.swift",
    "ABTunerHeadroomTests.swift",
    "AIPresetStudioTests.swift",
    "AntiAliasingTests.swift",
    "AudioFixTests.swift",
    "AutomationReadoutTests.swift",
    "BatteryCareTests.swift",
    "BatteryHistoryViewTests.swift",
    "BLEReconnectTests.swift",
    "BlindComparisonTests.swift",
    "CallAwarenessTests.swift",
    "CautionContrastTests.swift",
    "ControllerConfirmedChecksTests.swift",
    "ControllerEqModeTests.swift",
    "ControllerFollowTests.swift",
    "ControllerImportTests.swift",
    "ControllerMuteFlashTests.swift",
    "ControllerReadingsTests.swift",
    "ControllerRepublishTests.swift",
    "ControllerRestoreTests.swift",
    "ControllerSnapshotTimingTests.swift",
    "ControllerUnchangedWriteTests.swift",
    "ConvolverTests.swift",
    "CurveDragTests.swift",
    "DacFilterTests.swift",
    "DataSafetyFixTests.swift",
    "DeviceControlTests.swift",
    "DeviceRig.swift",
    "DeviceRigTests.swift",
    "EngineHousekeepingTests.swift",
    "EngineLifecycleTests.swift",
    "EngineRateWitnessTests.swift",
    "EqAutomationTests.swift",
    "EqBandMuteTests.swift",
    "EQCurveMathTests.swift",
    "EQHeadroomTests.swift",
    "EqSessionSafetyTests.swift",
    "EqSnapshotStoreTests.swift",
    "EqUndoTests.swift",
    "ExportWriteErrorTests.swift",
    "F5FixTests.swift",
    "ForgetKeyConfirmTests.swift",
    "ImportCatalogueSharingTests.swift",
    "ImportResultsTests.swift",
    "ImportTextTests.swift",
    "ImpulsePrimeGateTests.swift",
    "ImpulseResponseCacheTests.swift",
    "InstanceLockTests.swift",
    "LoudnessTests.swift",
    "MicrophoneStreamUsageTests.swift",
    "NumberEntryTests.swift",
    "OutputVolumeCacheTests.swift",
    "PaneLayoutTests.swift",
    "PerAppCeilingTests.swift",
    "PerAppEqTests.swift",
    "PresetLibraryTests.swift",
    "PresetNameTests.swift",
    "ProfileRulesLinkTests.swift",
    "ProtocolTests.swift",
    "QualityAnalyzerBalanceTests.swift",
    "QualityAnalyzerTests.swift",
    "QuitFlushTests.swift",
    "ReadbackRepaintTests.swift",
    "SettingsNoticeViewTests.swift",
    "SignalPathTests.swift",
    "SpectrumEquivalenceTests.swift",
    "StageBalanceTests.swift",
    "StageBassGuardTests.swift",
    "StageChannelMapTests.swift",
    "StageClipperKneeTests.swift",
    "StageLimiterTests.swift",
    "StageLoudnessTests.swift",
    "StageProcessorRenderTests.swift",
    "StageRenderEdgeTests.swift",
    "StageRobustnessTests.swift",
    "StageRoomRateTests.swift",
    "StageSettingsRecoveryTests.swift",
    "StageTrackingTests.swift",
    "StatusIconTests.swift",
    "StatusMaskTests.swift",
    "ToneTesterRateTests.swift",
    "TrimBlindTests.swift",
    "TrimControllerTests.swift",
    "TuneHonestyTests.swift",
    "TuneSlotOverwriteTests.swift",
    "UIFixTests.swift"
]

#if os(Linux)
import Foundation

let includesApp = ProcessInfo.processInfo.environment["QUDELIX_APP"] == "1"

func pipewireIncludeFlags() -> [String] {
    let fallback = ["-I/usr/include/pipewire-0.3", "-I/usr/include/spa-0.2"]
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["pkg-config", "--cflags", "libpipewire-0.3"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return fallback
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let text = String(data: data, encoding: .utf8) else { return fallback }
    let flags = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    return flags.isEmpty ? fallback : flags
}

var products: [Product] = [
    .executable(name: "qudelix", targets: ["QudelixCLI"])
]

var targets: [Target] = [
    .systemLibrary(
        name: "CDBus",
        path: "Sources/CDBus",
        pkgConfig: "dbus-1",
        providers: [.apt(["libdbus-1-dev"])]
    ),
    .target(
        name: "QudelixBar",
        dependencies: ["CDBus"],
        path: "Sources/QudelixBar",
        exclude: appleOnlySources
    ),
    .executableTarget(
        name: "QudelixCLI",
        dependencies: ["QudelixBar"],
        path: "Sources/QudelixCLI"
    )
]

if includesApp {
    products.append(.executable(name: "qudelix-app", targets: ["QudelixApp"]))
    targets += [
        .systemLibrary(
            name: "CGtk",
            path: "Sources/CGtk",
            pkgConfig: "gtk4 libadwaita-1",
            providers: [.apt(["libgtk-4-dev", "libadwaita-1-dev"])]
        ),
        .target(
            name: "QudelixGtk",
            dependencies: ["CGtk", "QudelixBar"],
            path: "Sources/QudelixGtk"
        ),
        .executableTarget(
            name: "QudelixApp",
            dependencies: ["QudelixBar", "QudelixGtk", "CGtk"],
            path: "Sources/QudelixApp"
        ),
        .testTarget(
            name: "QudelixGtkTests",
            dependencies: ["QudelixGtk", "QudelixBar", "CGtk"],
            path: "Tests/QudelixGtkTests"
        ),
        .target(
            name: "CQxAudio",
            path: "Sources/CQxAudio",
            cSettings: [.unsafeFlags(pipewireIncludeFlags())],
            linkerSettings: [.linkedLibrary("pipewire-0.3")]
        ),
        .target(
            name: "QudelixAudio",
            dependencies: ["CQxAudio", "QudelixBar"],
            path: "Sources/QudelixAudio"
        ),
        .testTarget(
            name: "QudelixAudioTests",
            dependencies: ["QudelixAudio", "QudelixBar"],
            path: "Tests/QudelixAudioTests"
        )
    ]
}

targets.append(
    .testTarget(
        name: "QudelixBarTests",
        dependencies: ["QudelixBar", "CDBus"],
        path: "Tests/QudelixBarTests",
        exclude: appleOnlyTests
    )
)

let package = Package(
    name: "QudelixBar",
    products: products,
    targets: targets
)
#else
let package = Package(
    name: "QudelixBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QudelixBar",
            path: "Sources/QudelixBar",
            exclude: ["Linux"]
        ),
        .testTarget(
            name: "QudelixBarTests",
            dependencies: ["QudelixBar"],
            exclude: ["Linux"]
        )
    ]
)
#endif
