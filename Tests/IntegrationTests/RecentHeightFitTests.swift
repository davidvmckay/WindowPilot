import XCTest
import AppKit
@testable import WindowPilotCore
@testable import WindowPilotUI

/// Regression tests for the review finding on `PilotPanel.switchToTab` /
/// `fitHeightToRecentContent`: the Recent-mode height fit only ran on a
/// genuine All→Recent transition (`recent && !wasRecent`), but `showingRecent`
/// survives `dismiss()`. Common flow: open → activate a Recent card →
/// dismiss() (still on Recent) → reopen straight into Recent (`show()` sees
/// non-empty recentWindows and calls `switchToTab(recent: true)` again) — the
/// old gate saw `wasRecent == true` and skipped the fit entirely, so a
/// changed row count (e.g. a background Recent-data reload while dismissed)
/// never resized the panel.
///
/// The fix decouples two responsibilities that used to be bundled into one
/// gate:
///   - RE-FIT (`fitHeightToRecentContent`): now runs every time the panel
///     LANDS on Recent, including repeat landings.
///   - CAPTURE (`restoreHeight = frame.height`): still gated on the genuine
///     `!wasRecent` transition, so a repeat landing never overwrites the
///     "restore to All Windows" height with an already-shrunk value.
///
/// These are plain AppKit object tests, same pattern as `TreeSelectionTests`:
/// `PilotPanel` is constructed directly and driven via its internal
/// `switchToTab(recent:)` and `reloadRecent(windows:thumbnails:)` — both
/// `internal` (not `private`) specifically so tests can simulate a tab
/// switch / a Recent-data reload without ever calling `show()`, which orders
/// the panel front via `makeKeyAndOrderFront` and requires an on-screen
/// session. `setFrame` (used internally by `setHeightAnimated`) works
/// headless per Apple's docs — it behaves like the non-animated variant when
/// the window isn't visible, which is exactly this path. No Accessibility or
/// Screen Recording permission is required, and no window is ever ordered on
/// screen. Must ALWAYS execute (never environment-gated).
///
/// `@testable import WindowPilotCore` is used only because `TrackedWindow`'s
/// memberwise initializer is `internal` (same reasoning as
/// `CardAccessibilityTests`) — needed here to build fixtures.
final class RecentHeightFitTests: XCTestCase {

    // MARK: - Fixtures

    private func tracked(_ id: UInt32) -> TrackedWindow {
        TrackedWindow(
            id: id,
            pid: 100,
            appName: "TestApp",
            bundleIdentifier: "test.app",
            windowTitle: "Window \(id)",
            lastFocusTime: Date(),
            totalDuration: 30,
            isFullScreen: false
        )
    }

    // MARK: - Tests

    /// Reproduces the exact review scenario: land on Recent with a few rows,
    /// dismiss while still on Recent (showingRecent untouched by `dismiss()`),
    /// reload Recent with more rows, then re-land on Recent exactly as
    /// `show()` would — data reload BEFORE `switchToTab(recent: true)` (see
    /// `show()`'s body: `recentView.reloadData` runs, then `switchToTab`).
    /// Asserts the height actually changes to fit the new row count instead
    /// of going stale, and that the eventual restore-to-All-Windows height
    /// is NOT corrupted by the repeat landing.
    func test_recentHeightFit_refitsOnRepeatLanding_withoutCorruptingRestoreHeight() {
        let panel = PilotPanel()
        let initialHeight = panel.frame.height

        // --- First landing: 6 windows (2 rows at 3 columns/row). ---
        panel.reloadRecent(windows: (1...6).map(tracked))
        panel.switchToTab(recent: true)
        let heightAfterFirstFit = panel.frame.height

        XCTAssertLessThan(
            heightAfterFirstFit, initialHeight,
            "landing on Recent with only 2 rows should shrink the panel below its All-Windows height"
        )

        // --- Dismiss while still on Recent. `dismiss()` must NOT reset
        //     `showingRecent` — that's what makes the reopen below a
        //     recent→recent call instead of a fresh All→Recent transition,
        //     exactly like the real dismiss()-then-show()-into-Recent flow. ---
        panel.dismiss()

        // --- Background refresh while dismissed adds more rows (12 windows,
        //     4 rows) — mirrors the app reloading Recent data before the next
        //     `show()`. ---
        panel.reloadRecent(windows: (1...12).map(tracked))

        // --- Re-land on Recent exactly as `show()` would when recentWindows
        //     is non-empty: `switchToTab(recent: true)` again. `showingRecent`
        //     was never flipped by `dismiss()`, so this is a recent→recent
        //     call — the repeat-landing path the bug lived in. ---
        panel.switchToTab(recent: true)
        let heightAfterSecondFit = panel.frame.height

        XCTAssertNotEqual(
            heightAfterSecondFit, heightAfterFirstFit,
            "re-landing on Recent with more rows must re-fit the height, not go stale"
        )
        XCTAssertGreaterThan(
            heightAfterSecondFit, heightAfterFirstFit,
            "4 rows need more height than 2 rows fit to"
        )
        XCTAssertLessThanOrEqual(
            heightAfterSecondFit, initialHeight,
            "the fit must never exceed the original All-Windows height (the restore ceiling)"
        )

        // --- Leaving Recent must restore the ORIGINAL All-Windows height,
        //     not something corrupted by the repeat landing having
        //     re-captured `restoreHeight` from an already-shrunk value. ---
        panel.switchToTab(recent: false)
        XCTAssertEqual(
            panel.frame.height, initialHeight, accuracy: 0.5,
            "restoreHeight must still be the pre-Recent height — the repeat landing must not have corrupted it"
        )
    }

    /// Guards the other half of the decoupling: a redundant recent→recent
    /// call with an UNCHANGED row count must not perturb the height (no
    /// flicker on e.g. a spurious duplicate tab-change event), and must
    /// still leave `restoreHeight` intact for an eventual restore.
    func test_recentHeightFit_redundantLandingWithSameRowCount_isStable() {
        let panel = PilotPanel()
        let initialHeight = panel.frame.height

        panel.reloadRecent(windows: (1...6).map(tracked))
        panel.switchToTab(recent: true)
        let heightAfterFirstFit = panel.frame.height

        // Redundant landing, identical data, no dismiss in between.
        panel.switchToTab(recent: true)

        XCTAssertEqual(
            panel.frame.height, heightAfterFirstFit, accuracy: 0.5,
            "a redundant recent→recent call with unchanged data must not change the height"
        )

        panel.switchToTab(recent: false)
        XCTAssertEqual(
            panel.frame.height, initialHeight, accuracy: 0.5,
            "restoreHeight must be unaffected by the redundant landing"
        )
    }
}
