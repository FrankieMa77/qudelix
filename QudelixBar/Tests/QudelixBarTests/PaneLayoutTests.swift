import AppKit
import SwiftUI
import XCTest
@testable import QudelixBar

enum PaneProbe {
    static func foldedDefaults(suite: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.set(false, forKey: PresetSectionStorage.slotsOpen)
        defaults.set(false, forKey: PresetSectionStorage.libraryOpen)
        return defaults
    }

    static func openDefaults(suite: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.set(true, forKey: PresetSectionStorage.slotsOpen)
        defaults.set(true, forKey: PresetSectionStorage.libraryOpen)
        return defaults
    }
}

final class PaneLayoutTests: XCTestCase {
    static let levelPaneCeiling: CGFloat = 589

    @MainActor
    private func levelPane() -> NSHostingView<AnyView> {
        let stage = StageState()
        var settings = StageSettings.music
        settings.enabled = true
        settings.limiter = true
        settings.loudness = true
        settings.bassGuard = true
        stage.previewSet(stage: settings, exposure: [],
                         currentDb: -23, levelTracking: true,
                         verdict: .losslessLike(cutoffKHz: 21.9),
                         limiterGainReductionDb: 2.4,
                         loudnessShelfDb: 1.8,
                         bassGuardBoostDb: 6.4,
                         bassGuardCeilingDb: 6.4,
                         bassGuardGainReductionDb: 1.6,
                         earLevel: .estimated(78), earAnchor: .qudelix(-24))
        stage.engine.previewSetRunning(true, status: "Metering")
        let controller = QudelixController()
        controller.connection = .connected(name: "Qudelix-5K USB DAC")
        controller.compatibility = .ok
        let root = LevelView()
            .environmentObject(stage)
            .environmentObject(controller)
            .environmentObject(AppAssignments())
            .frame(width: 372)
        let host = NSHostingView(rootView: AnyView(root))
        host.layoutSubtreeIfNeeded()
        return host
    }

    @MainActor
    func testTheLevelPaneIsNoTallerThanItWasBeforeTheMetersBecameAGrid() {
        let wanted = levelPane().fittingSize.height
        print(String(format: "level: content %.1f pt vs %.0f pt ceiling",
                     wanted, Self.levelPaneCeiling))
        XCTAssertLessThanOrEqual(wanted, Self.levelPaneCeiling,
                                 "the Level pane grew to \(wanted) pt")
    }

    func testTheBassGuardReadingCarriesItsOwnCeiling() {
        XCTAssertEqual(LevelView.bassGuardReading(reduction: 1.6, boost: 6.4),
                       "\u{2212}1.6 of 6.4 dB")
        XCTAssertEqual(LevelView.bassGuardReading(reduction: 0, boost: 6.4),
                       "idle of 6.4 dB")
    }

    func testThePresetsPaneIsReachableWithTheDeviceAway() {
        XCTAssertFalse(PopoverView.Pane.presets.needsDevice,
                       "the Mac-side library, per-app assignments and profiles are "
                           + "all organisable without the 5K")
        XCTAssertTrue(PopoverView.Pane.equalizer.needsDevice)
        XCTAssertTrue(PopoverView.Pane.importing.needsDevice)
        XCTAssertTrue(PopoverView.Pane.tune.needsDevice)
        XCTAssertFalse(PopoverView.Pane.stage.needsDevice)
        XCTAssertFalse(PopoverView.Pane.level.needsDevice)
    }

    func testTheOfflinePresetsNoteSaysWhatStillWorks() {
        XCTAssertTrue(PresetsView.offlineNote.contains("organise presets"))
        XCTAssertTrue(PresetsView.offlineNote.contains("needs the device"))
    }

    func testTheSlotOverwriteWarningNamesTheSlotAndSaysNothingIsKept() {
        let message = PresetsView.overwriteMessage(slot: 2, name: "Alder AR-5")
        XCTAssertTrue(message.hasPrefix("Slot 3, "), message)
        XCTAssertTrue(message.contains("Alder AR-5"))
        XCTAssertTrue(message.contains("the device keeps no copy"))
    }

    func testTheSlotAndLibraryVocabularyIsSeparate() {
        XCTAssertEqual(PresetsView.saveHereLabel, "Save here")
        XCTAssertEqual(PresetLibraryView.saveButtonLabel, "Save to library\u{2026}")
        XCTAssertEqual(PresetLibraryView.applyLinkLabel, "Apply")
    }

    func testDeletingALibraryPresetIsWordedAsUnrecoverable() {
        XCTAssertEqual(PresetLibraryView.deleteTitle("Late night"),
                       "Delete \u{201C}Late night\u{201D}?")
        XCTAssertTrue(PresetLibraryView.deleteMessage.contains("only on this Mac"))
        XCTAssertTrue(PresetLibraryView.deleteMessage.contains("can\u{2019}t be recovered"))
    }

    @MainActor
    func testThePresetsPaneRendersWithTheDeviceAwayAndEveryWriteRefused() {
        let controller = QudelixController()
        controller.connection = .disconnected
        XCTAssertFalse(controller.canWriteNow)
        XCTAssertFalse(controller.canEditEqNow)

        let library = PresetLibrary()
        library.previewSet(presets: [], headphoneName: "Alder AR-5")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-presets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let studio = AIPresetStudio(
            research: AIResearchStore(directory: directory),
            defaults: UserDefaults(suiteName: "qudelixbar.tests.offline") ?? .standard)

        let root = PresetsView()
            .environmentObject(controller)
            .environmentObject(StageState())
            .environmentObject(ProfileRules())
            .environmentObject(library)
            .environmentObject(AppAssignments())
            .environmentObject(studio)
            .environmentObject(HeadphoneSuggestions(library: library))
            .environmentObject(ABTuner())
            .environmentObject(ToneTester())
            .environmentObject(BlindTuner())
            .defaultAppStorage(PaneProbe.openDefaults(
                suite: "qudelixbar.tests.offline.open"))
            .frame(width: 372)
        let host = NSHostingView(rootView: AnyView(root))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testTheMicrophoneModeReadsAsALabelledSetting() {
        XCTAssertEqual(A2dpGuard.Mode.ask.shortLabel.lowercased(), "ask")
        XCTAssertEqual(A2dpGuard.Mode.fix.shortLabel.lowercased(), "fix")
        XCTAssertEqual(A2dpGuard.Mode.off.shortLabel.lowercased(), "off")
    }
}
