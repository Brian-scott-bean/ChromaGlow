import XCTest
@testable import HueHome

@MainActor
final class KeyboardStateTests: XCTestCase {

    /// One test covering the full transition cycle — KeyboardState.shared is a
    /// process-lifetime singleton, so a single ordered test avoids cross-test
    /// order dependence on its state.
    func testKeyboardNotificationsDriveTheFlag() {
        let state = KeyboardState.shared
        let center = NotificationCenter.default

        // Normalize (the app host has no keyboard, but never assume).
        center.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertFalse(state.isKeyboardUp, "didHide must always lower the flag")

        center.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        XCTAssertTrue(state.isKeyboardUp, "willShow (pre-animation) must raise the flag")

        // A second willShow (keyboard frame changes re-post it) stays up.
        center.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        XCTAssertTrue(state.isKeyboardUp)

        center.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertFalse(state.isKeyboardUp, "didHide must lower the flag again")
    }
}
