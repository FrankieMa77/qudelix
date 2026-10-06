import XCTest
@testable import QudelixBar

final class ForgetKeyConfirmTests: XCTestCase {
    func testTheQuestionNamesTheProviderWhoseKeyGoes() {
        for provider in AIProvider.allCases {
            XCTAssertEqual(AIPresetSection.forgetKeyTitle(provider),
                           "Forget the \(provider.label) key?")
        }
    }

    func testTheMessageSaysTheKeyHasToBePastedAgain() {
        XCTAssertTrue(AIPresetSection.forgetKeyMessage.contains("paste it again"))
        XCTAssertTrue(AIPresetSection.forgetKeyMessage.contains("Keychain"))
    }

    func testTheDestructiveButtonKeepsTheNameOnTheRowButton() {
        XCTAssertEqual(AIPresetSection.forgetKeyLabel, "Forget key")
    }
}
