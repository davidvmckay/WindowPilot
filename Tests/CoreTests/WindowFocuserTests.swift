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
    //
    // Focus/raise is non-destructive but still must not raise the WRONG window:
    // when an explicit windowID is given it must resolve BY ID. A title match is
    // NOT an acceptable fallback for a set ID — a closed target whose app still
    // holds a same-titled sibling would otherwise AXRaise the sibling. Title
    // matching applies only to windowID == 0 callers (the CLI convenience
    // overloads), where any title match remains acceptable.

    // Focus: an ID match wins.
    func test_resolution_focus_id_match_succeeds() {
        let r = WindowFocuser.resolution(
            policy: .focus, windowID: 4242, idMatchFound: true, titleMatchCount: 0)
        XCTAssertEqual(r, .matched)
    }

    // Focus: an ID match wins even when same-titled siblings are present — the
    // ID resolves first and the title count is irrelevant once it does.
    func test_resolution_focus_id_match_wins_over_title_matches() {
        let r = WindowFocuser.resolution(
            policy: .focus, windowID: 4242, idMatchFound: true, titleMatchCount: 2)
        XCTAssertEqual(r, .matched)
    }

    // Focus: an explicit windowID that does NOT resolve by ID must fail even
    // when a same-titled window exists — NO title fallback with an ID. (FLIPPED
    // from the old title-fallback-with-ID behaviour: raising a same-titled
    // sibling of a closed target violated the "closed windows fail explicitly"
    // contract.)
    func test_resolution_focus_id_given_no_id_match_ignores_title_fails() {
        let r = WindowFocuser.resolution(
            policy: .focus, windowID: 4242, idMatchFound: false, titleMatchCount: 1)
        XCTAssertEqual(r, .failed)
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

    // …a windowID == 0 caller with several title matches still resolves (unlike
    // the destructive policy, focus is non-destructive so ambiguity is tolerated
    // and the first title match is taken).
    func test_resolution_focus_id0_multiple_title_matches_succeeds() {
        let r = WindowFocuser.resolution(
            policy: .focus, windowID: 0, idMatchFound: false, titleMatchCount: 3)
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

    // MARK: - displayDescriptorIndex — pure display-descriptor selection
    //
    // Selects which CGSCopyManagedDisplaySpaces descriptor belongs to a target
    // display. Descriptors are normally matched by "Display Identifier" — a
    // UUID string — but when "Displays have separate Spaces" is OFF, CGS
    // collapses everything into a SINGLE shared descriptor identified as
    // "Main" rather than any display's UUID. No CGS/AX access — just the
    // branching, so it is unit-testable in isolation.

    // Single descriptor, identifier "Main" (separate-Spaces OFF) → still
    // index 0: the one shared descriptor applies to every display, even
    // though its identifier is not the target's UUID.
    func test_displayDescriptorIndex_single_descriptor_main_identifier_returns_zero() {
        let index = WindowFocuser.displayDescriptorIndex(
            identifiers: ["Main"],
            targetUUID: "11111111-2222-3333-4444-555555555555"
        )
        XCTAssertEqual(index, 0)
    }

    // Single descriptor whose identifier is some OTHER display's UUID → still
    // index 0: with exactly one descriptor there is nothing else it could be
    // (single-display machine, or a stale/mismatched identifier).
    func test_displayDescriptorIndex_single_descriptor_other_display_uuid_returns_zero() {
        let index = WindowFocuser.displayDescriptorIndex(
            identifiers: ["99999999-8888-7777-6666-555555555555"],
            targetUUID: "11111111-2222-3333-4444-555555555555"
        )
        XCTAssertEqual(index, 0)
    }

    // Multiple descriptors → the index of the one matching the target UUID
    // (the match sits at index 1, not 0, to prove this isn't just "first"),
    // and the comparison is case-insensitive. The UUID must contain hex
    // LETTERS (a–f) so uppercasing actually changes it — an all-digit UUID
    // would pass even under a case-sensitive compare, testing nothing.
    func test_displayDescriptorIndex_multiple_descriptors_matches_target_case_insensitive() {
        let target = "aabbccdd-eeff-3333-4444-555555555555"
        let identifiers = [
            "99999999-8888-7777-6666-555555555555",
            target.uppercased(),
            "22222222-3333-4444-5555-666666666666",
        ]
        let index = WindowFocuser.displayDescriptorIndex(identifiers: identifiers, targetUUID: target)
        XCTAssertEqual(index, 1)
    }

    // Multiple descriptors, none matching the target UUID → nil.
    func test_displayDescriptorIndex_multiple_descriptors_no_match_returns_nil() {
        let identifiers = [
            "99999999-8888-7777-6666-555555555555",
            "22222222-3333-4444-5555-666666666666",
        ]
        let index = WindowFocuser.displayDescriptorIndex(
            identifiers: identifiers,
            targetUUID: "11111111-2222-3333-4444-555555555555"
        )
        XCTAssertNil(index)
    }

    // No descriptors at all (CGS returned an empty list) → nil.
    func test_displayDescriptorIndex_empty_array_returns_nil() {
        let index = WindowFocuser.displayDescriptorIndex(
            identifiers: [],
            targetUUID: "11111111-2222-3333-4444-555555555555"
        )
        XCTAssertNil(index)
    }

    // A nil identifier (unreadable "Display Identifier") among multiple
    // descriptors never matches — it's skipped, not treated as a wildcard.
    func test_displayDescriptorIndex_nil_identifier_never_matches() {
        let identifiers: [String?] = [nil, nil]
        let index = WindowFocuser.displayDescriptorIndex(
            identifiers: identifiers,
            targetUUID: "11111111-2222-3333-4444-555555555555"
        )
        XCTAssertNil(index)
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
