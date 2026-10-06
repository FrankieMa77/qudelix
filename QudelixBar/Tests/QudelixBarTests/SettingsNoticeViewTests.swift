import AppKit
import SwiftUI
import XCTest
@testable import QudelixBar

@MainActor
final class SettingsNoticeViewTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("notice-view-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func state(damaged: Bool) -> StageState {
        let url = scratch.appendingPathComponent(damaged ? "bad.json" : "good.json")
        if damaged { _ = SafeFile.writeAtomic(Data("{\"stageByDevice\": 7".utf8), to: url) }
        return StageState(settingsURL: url)
    }

    private func height<V: View>(of view: V) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: 372))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func stagePane(_ stage: StageState) -> some View {
        StageView().environmentObject(stage).environmentObject(QudelixController())
    }

    private func levelPane(_ stage: StageState) -> some View {
        LevelView()
            .environmentObject(stage)
            .environmentObject(QudelixController())
            .environmentObject(AppAssignments())
    }

    func testTheFixtureRaisesANoticeOnlyWhenTheFileIsDamaged() {
        XCTAssertNotNil(state(damaged: true).settingsNotice)
        XCTAssertNil(state(damaged: false).settingsNotice)
    }

    func testTheStagePaneShowsTheNoticeAboveItsControls() {
        let clean = height(of: stagePane(state(damaged: false)))
        let noticed = height(of: stagePane(state(damaged: true)))
        XCTAssertGreaterThan(noticed, clean + 10,
                             "a recovered stage.json must be visible on the Stage pane")
    }

    func testTheLevelPaneShowsTheNoticeAboveItsControls() {
        let clean = height(of: levelPane(state(damaged: false)))
        let noticed = height(of: levelPane(state(damaged: true)))
        XCTAssertGreaterThan(noticed, clean + 10,
                             "a recovered stage.json must be visible on the Level pane")
    }
}
