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

    // MARK: - resolution(policy:) — pure decision helper
    //
    // These exercise the pure matched/failed decision that both focus() and the
    // destructive minimize()/close() paths delegate to. No AX access, no live
    // session — just the branching that decides whether it is safe to act.

    // MARK: destructive policy

    // An explicit windowID that resolves to no AX window must fail — a
    // destructive op never falls back to title or the first window.
    func test_resolution_destructive_nonexistent_id_fails() {
        let r = WindowFocuser.resolution(
            policy: .destructive, windowID: 4242, idMatchFound: false, titleMatchCount: 0)
        XCTAssertEqual(r, .failed)
    }

    // Even when a title match exists, an explicit windowID that does not
    // resolve must fail for destructive ops (no title fallback with an ID).
    func test_resolution_destructive_id_given_no_id_match_ignores_title() {
        let r = WindowFocuser.resolution(
            policy: .destructive, windowID: 4242, idMatchFound: false, titleMatchCount: 1)
        XCTAssertEqual(r, .failed)
    }

    // An explicit windowID that resolves succeeds regardless of title count.
    func test_resolution_destructive_id_match_succeeds() {
        let r = WindowFocuser.resolution(
            policy: .destructive, windowID: 4242, idMatchFound: true, titleMatchCount: 0)
        XCTAssertEqual(r, .matched)
    }

    // windowID == 0 with two title matches is ambiguous → must fail.
    func test_resolution_destructive_id0_two_title_matches_fails() {
        let r = WindowFocuser.resolution(
            policy: .destructive, windowID: 0, idMatchFound: false, titleMatchCount: 2)
        XCTAssertEqual(r, .failed)
    }

    // windowID == 0 with exactly one title match is unambiguous → matched.
    func test_resolution_destructive_id0_one_title_match_succeeds() {
        let r = WindowFocuser.resolution(
            policy: .destructive, windowID: 0, idMatchFound: false, titleMatchCount: 1)
        XCTAssertEqual(r, .matched)
    }

    // windowID == 0 with no title match → failed.
    func test_resolution_destructive_id0_no_title_match_fails() {
        let r = WindowFocuser.resolution(
            policy: .destructive, windowID: 0, idMatchFound: false, titleMatchCount: 0)
        XCTAssertEqual(r, .failed)
    }

    // MARK: focus policy

    // Focus: an ID match wins.
    func test_resolution_focus_id_match_succeeds() {
        let r = WindowFocuser.resolution(
            policy: .focus, windowID: 4242, idMatchFound: true, titleMatchCount: 0)
        XCTAssertEqual(r, .matched)
    }

    // Focus: no ID match but a title match is an acceptable fallback (covers
    // AX enumeration hiccups) even when an ID was requested.
    func test_resolution_focus_title_fallback_succeeds() {
        let r = WindowFocuser.resolution(
            policy: .focus, windowID: 4242, idMatchFound: false, titleMatchCount: 1)
        XCTAssertEqual(r, .matched)
    }

    // Focus: neither ID nor title resolves → failed (no windows.first tail).
    func test_resolution_focus_no_match_fails() {
        let r = WindowFocuser.resolution(
            policy: .focus, windowID: 4242, idMatchFound: false, titleMatchCount: 0)
        XCTAssertEqual(r, .failed)
    }

    // Focus by title only (windowID == 0): a match succeeds…
    func test_resolution_focus_id0_title_match_succeeds() {
        let r = WindowFocuser.resolution(
            policy: .focus, windowID: 0, idMatchFound: false, titleMatchCount: 1)
        XCTAssertEqual(r, .matched)
    }

    // …and no match fails.
    func test_resolution_focus_id0_no_title_match_fails() {
        let r = WindowFocuser.resolution(
            policy: .focus, windowID: 0, idMatchFound: false, titleMatchCount: 0)
        XCTAssertEqual(r, .failed)
    }
}
