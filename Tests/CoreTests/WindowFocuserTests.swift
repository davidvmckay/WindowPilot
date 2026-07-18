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

    // MARK: - selectFullScreenDisplayIndex — pure display selection
    //
    // Chooses which display's full-screen Space `exitCurrentFullScreen` should
    // exit. With a target window, prefer the display whose Space list holds the
    // target's Space; otherwise fall back to the first full-screen display. No
    // CGS/AX access — just the branching, so it is unit-testable in isolation.

    // Target sits on the 2nd of two full-screen displays → pick the 2nd.
    func test_selectFullScreenDisplay_target_on_second_fullscreen_display_picks_second() {
        let displays = [
            WindowFocuser.DisplaySpaceInfo(index: 0, spaceIDs: [100, 101], currentSpaceIsFullScreen: true),
            WindowFocuser.DisplaySpaceInfo(index: 1, spaceIDs: [200, 201], currentSpaceIsFullScreen: true),
        ]
        let chosen = WindowFocuser.selectFullScreenDisplayIndex(displays: displays, targetSpaceIDs: [201])
        XCTAssertEqual(chosen, 1)
    }

    // No full-screen display contains the target's Space → fall back to the
    // first full-screen display (preserves the historic first-match behaviour).
    func test_selectFullScreenDisplay_target_not_on_any_fullscreen_falls_back_to_first() {
        let displays = [
            WindowFocuser.DisplaySpaceInfo(index: 0, spaceIDs: [100, 101], currentSpaceIsFullScreen: true),
            WindowFocuser.DisplaySpaceInfo(index: 1, spaceIDs: [200, 201], currentSpaceIsFullScreen: true),
        ]
        let chosen = WindowFocuser.selectFullScreenDisplayIndex(displays: displays, targetSpaceIDs: [999])
        XCTAssertEqual(chosen, 0)
    }

    // No target (nil ⇒ empty target Spaces) → first full-screen display, skipping
    // any leading non-full-screen displays.
    func test_selectFullScreenDisplay_nil_target_picks_first_fullscreen() {
        let displays = [
            WindowFocuser.DisplaySpaceInfo(index: 0, spaceIDs: [100], currentSpaceIsFullScreen: false),
            WindowFocuser.DisplaySpaceInfo(index: 1, spaceIDs: [200, 201], currentSpaceIsFullScreen: true),
            WindowFocuser.DisplaySpaceInfo(index: 2, spaceIDs: [300], currentSpaceIsFullScreen: true),
        ]
        let chosen = WindowFocuser.selectFullScreenDisplayIndex(displays: displays, targetSpaceIDs: [])
        XCTAssertEqual(chosen, 1)
    }

    // No display currently shows a full-screen Space → nothing to exit.
    func test_selectFullScreenDisplay_no_fullscreen_returns_nil() {
        let displays = [
            WindowFocuser.DisplaySpaceInfo(index: 0, spaceIDs: [100], currentSpaceIsFullScreen: false),
        ]
        let chosen = WindowFocuser.selectFullScreenDisplayIndex(displays: displays, targetSpaceIDs: [100])
        XCTAssertNil(chosen)
    }

    // MARK: - matchingTitleIndex — pure title-fallback decision
    //
    // findWindow(matching:in:) resolves the focus/raise title fallback over
    // `[AXUIElement]` — opaque AX handles that can't be synthesised with fake
    // titles in a unit test, so making findWindow itself internal is not a
    // testable seam. Its post-fallback-deletion logic is a pure function of the
    // windows' titles, so it delegates to this static helper (mirroring the
    // resolution / selectFullScreenDisplayIndex pure-helper pattern), which the
    // tests exercise directly. `nil` title = unreadable/untitled AX window.

    // Exact title match resolves to that window's index.
    func test_matchingTitle_exact_match_wins() {
        let idx = WindowFocuser.matchingTitleIndex(
            query: "main.rs — windowpilot",
            titles: ["Prefs", "main.rs — windowpilot", "Other"])
        XCTAssertEqual(idx, 1)
    }

    // Exact match must win even when an earlier window is a substring candidate —
    // the exact pass precedes the substring pass, never the reverse.
    func test_matchingTitle_exact_beats_substring() {
        let idx = WindowFocuser.matchingTitleIndex(
            query: "Doc",
            titles: ["Doc — draft", "Doc"])
        XCTAssertEqual(idx, 1, "exact 'Doc' at index 1 must beat substring 'Doc — draft' at index 0")
    }

    // Bidirectional substring drift still resolves for real (non-'Untitled')
    // titles — the AX title has drifted from the enumerated one (e.g. an
    // '(Edited)' suffix appeared).
    func test_matchingTitle_substring_drift_matches_for_real_titles() {
        let idx = WindowFocuser.matchingTitleIndex(
            query: "main.rs — windowpilot",
            titles: ["main.rs — windowpilot (Edited)"])
        XCTAssertEqual(idx, 0)
    }

    // Substring drift is also honoured the other way (query contains AX title).
    func test_matchingTitle_substring_reverse_direction_matches() {
        let idx = WindowFocuser.matchingTitleIndex(
            query: "Report — Q3 (Edited)",
            titles: ["Report — Q3"])
        XCTAssertEqual(idx, 0)
    }

    // 'Untitled' query with no exact match → nil. The deleted first-window
    // branch would have returned windows[0]; the fallback deletion means an
    // unresolvable 'Untitled' target now fails explicitly.
    func test_matchingTitle_untitled_no_exact_returns_nil_not_first() {
        let idx = WindowFocuser.matchingTitleIndex(
            query: "Untitled",
            titles: ["Inbox", "Calendar"])
        XCTAssertNil(idx)
    }

    // A genuine 'Untitled' AX window is still resolved by the exact pass — the
    // guard only skips the substring pass, not exact matching.
    func test_matchingTitle_untitled_exact_still_matches() {
        let idx = WindowFocuser.matchingTitleIndex(
            query: "Untitled",
            titles: ["Something", "Untitled"])
        XCTAssertEqual(idx, 1)
    }

    // The substring pass is skipped for an 'Untitled' query so it cannot
    // false-positive against a real title that merely contains 'Untitled'
    // ('Untitled'.contains would otherwise match). No exact match → nil.
    func test_matchingTitle_untitled_does_not_substring_into_real_titles() {
        let idx = WindowFocuser.matchingTitleIndex(
            query: "Untitled",
            titles: ["My Untitled Document"])
        XCTAssertNil(idx)
    }

    // An empty query resolves nothing — the substring pass is skipped (every
    // title contains "") and there is no exact "" window.
    func test_matchingTitle_empty_query_returns_nil() {
        let idx = WindowFocuser.matchingTitleIndex(
            query: "",
            titles: ["Inbox", "Calendar"])
        XCTAssertNil(idx)
    }

    // A wholly unrelated title (the case the deleted any-fullscreen fallback
    // used to salvage) now resolves to nil rather than an arbitrary window.
    func test_matchingTitle_unrelated_returns_nil() {
        let idx = WindowFocuser.matchingTitleIndex(
            query: "Terminal",
            titles: ["Safari", "Notes"])
        XCTAssertNil(idx)
    }

    // Unreadable (nil) titles are skipped by both passes; a later readable
    // window still resolves.
    func test_matchingTitle_skips_nil_titles() {
        let idx = WindowFocuser.matchingTitleIndex(
            query: "target",
            titles: [nil, "target"])
        XCTAssertEqual(idx, 1)
    }

    // All titles unreadable → nil (no exact, nothing to substring against).
    func test_matchingTitle_all_nil_returns_nil() {
        let idx = WindowFocuser.matchingTitleIndex(
            query: "target",
            titles: [nil, nil])
        XCTAssertNil(idx)
    }

    // No windows at all → nil.
    func test_matchingTitle_empty_window_list_returns_nil() {
        let idx = WindowFocuser.matchingTitleIndex(query: "anything", titles: [])
        XCTAssertNil(idx)
    }
}
