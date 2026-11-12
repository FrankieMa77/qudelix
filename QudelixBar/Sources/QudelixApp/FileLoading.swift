import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@MainActor
enum EqFileLoader {
    static let title = "Load EQ from file"

    static func present(from widget: Widget, eq: EqEditorModel) {
        let parent = Ui.parentWindow(of: widget).map { UnsafeMutableRawPointer($0) }
        FileDialog.openText(parent: parent, title: title) { path in
            onMain {
                guard let path else { return }
                eq.importFile(at: URL(fileURLWithPath: path))
            }
        }
    }

    static func presentExport(from widget: Widget, eq: EqEditorModel) {
        let parent = Ui.parentWindow(of: widget).map { UnsafeMutableRawPointer($0) }
        FileDialog.saveText(parent: parent, title: EqEditorModel.exportTitle,
                            initialName: EqEditorModel.exportFileName) { path in
            onMain {
                guard let path else { return }
                eq.exportFile(to: URL(fileURLWithPath: path))
            }
        }
    }
}
