import SwiftUI
import XCTest
@testable import QudelixBar

final class ImportCatalogueSharingTests: XCTestCase {
    private func stored<T>(_ type: T.Type, named name: String, in view: Any) -> T? {
        Mirror(reflecting: view).children.first { $0.label == name }?.value as? T
    }

    @MainActor
    func testTheImportPaneReadsTheAppWideCataloguesInsteadOfLoadingItsOwn() {
        let view = ImportView()

        let index = stored(ObservedObject<AutoEqIndex>.self, named: "_autoEq", in: view)
        XCTAssertTrue(index?.wrappedValue === AutoEqIndex.shared,
                      "a private index would download the catalogue a second time")

        let service = stored(ObservedObject<AutoEqService>.self, named: "_optimizer", in: view)
        XCTAssertTrue(service?.wrappedValue === AutoEqService.shared,
                      "a private service would fetch the optimizer list a second time")
    }
}
