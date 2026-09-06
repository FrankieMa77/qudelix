// swift-tools-version:5.9
import PackageDescription

let appleOnlySources = [
    "A2dpGuard.swift",
    "AboutView.swift",
    "ABTuner.swift",
    "AIKeychain.swift",
    "AIPresetSection.swift",
    "App.swift",
    "AppAssignments.swift",
    "AppsSection.swift",
    "AudioOutputs.swift",
    "BLETransport.swift",
    "BlindTuner.swift",
    "Convolver.swift",
    "DeviceSettingsView.swift",
    "EQCurveView.swift",
    "HIDTransport.swift",
    "ImportView.swift",
    "LevelView.swift",
    "Notifier.swift",
    "PopoverView.swift",
    "PresetLibraryView.swift",
    "ProfilesView.swift",
    "QualityAnalyzer.swift",
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
    "BatteryCareTests.swift",
    "BlindComparisonTests.swift",
    "CallAwarenessTests.swift",
    "ConvolverTests.swift",
    "CurveDragTests.swift",
    "DacFilterTests.swift",
    "DeviceControlTests.swift",
    "EngineHousekeepingTests.swift",
    "EqBandMuteTests.swift",
    "EQCurveMathTests.swift",
    "EQDivergenceTests.swift",
    "EQHeadroomTests.swift",
    "EqSnapshotStoreTests.swift",
    "EqUndoTests.swift",
    "ImportResultsTests.swift",
    "ImportTextTests.swift",
    "PaneLayoutTests.swift",
    "PerAppEqTests.swift",
    "PreGainChannelTests.swift",
    "QualityAnalyzerTests.swift",
    "ReadbackRepaintTests.swift",
    "SignalPathTests.swift",
    "StageBalanceTests.swift",
    "StageBassGuardTests.swift",
    "StageLimiterTests.swift",
    "StageLoudnessTests.swift",
    "StageProcessorRenderTests.swift",
    "StageRenderEdgeTests.swift",
    "StageTrackingTests.swift",
    "StatusIconTests.swift",
    "TuneHonestyTests.swift"
]

#if os(Linux)
let package = Package(
    name: "QudelixBar",
    products: [
        .executable(name: "qudelix", targets: ["QudelixBar"])
    ],
    targets: [
        .systemLibrary(
            name: "CDBus",
            path: "Sources/CDBus",
            pkgConfig: "dbus-1",
            providers: [.apt(["libdbus-1-dev"])]
        ),
        .executableTarget(
            name: "QudelixBar",
            dependencies: ["CDBus"],
            path: "Sources/QudelixBar",
            exclude: appleOnlySources
        ),
        .testTarget(
            name: "QudelixBarTests",
            dependencies: ["QudelixBar", "CDBus"],
            path: "Tests/QudelixBarTests",
            exclude: appleOnlyTests
        )
    ]
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
        .executableTarget(
            name: "qxprobe",
            path: "Sources/qxprobe"
        ),
        .executableTarget(
            name: "qxusb",
            path: "Sources/qxusb"
        ),
        .testTarget(
            name: "QudelixBarTests",
            dependencies: ["QudelixBar"],
            exclude: ["Linux"]
        )
    ]
)
#endif
