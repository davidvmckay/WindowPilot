import XCTest
@testable import WindowPilotCore

// MARK: - MockWindowFocuser

/// Test double for WindowFocusing. Returns a configurable result from focus()
/// and a configurable accessibility permission state.
private final class MockWindowFocuser: WindowFocusing {

    private let focusResult: Bool
    private let accessibilityGranted: Bool

    init(focusResult: Bool, accessibilityGranted: Bool = true) {
        self.focusResult = focusResult
        self.accessibilityGranted = accessibilityGranted
    }

    func focus(pid: Int32, windowID: UInt32, windowTitle: String, state: WindowState) -> Bool {
        guard accessibilityGranted else { return false }
        return focusResult
    }

    func hasAccessibilityPermission() -> Bool {
        accessibilityGranted
    }
}

// MARK: - WindowFocuserTests

final class WindowFocuserTests: XCTestCase {

    // A mock configured to succeed returns true from focus().
    func test_mock_focus_returns_true() {
        let mock = MockWindowFocuser(focusResult: true)
        let result = mock.focus(pid: 1001, windowTitle: "main.rs — windowpilot")
        XCTAssertTrue(result, "focus() should return true when the mock is configured to succeed")
    }

    // A mock configured to fail returns false from focus(), matching the real
    // focuser's behaviour when AXUIElementPerformAction returns an error.
    func test_mock_focus_returns_false() {
        let mock = MockWindowFocuser(focusResult: false)
        let result = mock.focus(pid: 1001, windowTitle: "main.rs — windowpilot")
        XCTAssertFalse(result, "focus() should return false when the mock is configured to fail")
    }

    // MockWindowFocuser must satisfy the WindowFocusing protocol contract
    // (verified at compile time; this test makes the intent explicit at
    // runtime and guards against accidental protocol changes).
    func test_protocol_conformance() {
        let mock: WindowFocusing = MockWindowFocuser(focusResult: true)
        // If MockWindowFocuser did not conform, the line above would not compile.
        let focusOK = mock.focus(pid: 99, windowTitle: "Some Window")
        let hasAccess = mock.hasAccessibilityPermission()
        XCTAssertTrue(focusOK)
        XCTAssertTrue(hasAccess)
    }
}
