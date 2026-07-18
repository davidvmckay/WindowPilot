import XCTest
import AppKit
@testable import WindowPilotCore
@testable import WindowPilotUI

/// Regression tests for the review finding on `RecentView.rebuildGrid`: the
/// "No recent windows yet" empty-state label was added as a subview on every
/// empty reload but never removed — `rebuildGrid` only cleared `cardViews`,
/// leaving the label to (a) survive behind the cards once data arrives, and
/// (b) stack a duplicate copy on each repeated empty reload. The fix tracks
/// the label in a private `emptyStateLabel` and removes it
/// (removeFromSuperview + nil) at the top of `rebuildGrid`, before deciding
/// whether to re-add it.
///
/// These are plain AppKit object tests, same pattern as `TreeSelectionTests`:
/// `RecentView` is constructed directly and driven via its public
/// `reloadData(windows:thumbnails:)`. The label lives inside the
/// `NSScrollView`'s `documentView` (RecentView's private `containerView`) —
/// both reached via standard AppKit API, no `@testable` access to RecentView's
/// private storage needed. No Accessibility or Screen Recording permission is
/// required, and no window is ever ordered on screen. Must ALWAYS execute
/// (never environment-gated).
///
/// `@testable import WindowPilotCore` is used only because `TrackedWindow`'s
/// memberwise initializer is `internal` (same reasoning as
/// `CardAccessibilityTests`/`RecentHeightFitTests`) — needed here to build
/// fixtures.
final class RecentViewEmptyStateTests: XCTestCase {

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

    /// RecentView's document view (its private `containerView`), reached via
    /// the standard AppKit `NSScrollView.documentView` — no `@testable`
    /// access to RecentView's private storage needed.
    private func documentView(of recentView: RecentView) -> NSView? {
        recentView.subviews.compactMap { $0 as? NSScrollView }.first?.documentView
    }

    private func emptyStateLabels(in recentView: RecentView) -> [NSTextField] {
        (documentView(of: recentView)?.subviews ?? [])
            .compactMap { $0 as? NSTextField }
            .filter { $0.stringValue == "No recent windows yet" }
    }

    // MARK: - Tests

    /// Landing on data after an empty reload must remove the empty-state
    /// label entirely — before the fix it stayed in the view hierarchy,
    /// hidden behind the newly added cards.
    func test_reloadWithData_afterEmpty_removesEmptyStateLabel() {
        let recentView = RecentView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))

        recentView.reloadData(windows: [], thumbnails: [:])
        XCTAssertEqual(
            emptyStateLabels(in: recentView).count, 1,
            "empty reload should show exactly one empty-state label"
        )

        recentView.reloadData(windows: [tracked(1), tracked(2)], thumbnails: [:])
        XCTAssertEqual(
            emptyStateLabels(in: recentView).count, 0,
            "empty-state label must be removed once data arrives"
        )
    }

    /// Repeated empty reloads (e.g. back-to-back background refreshes that
    /// both land on zero tracked windows) must never stack more than one
    /// copy of the label.
    func test_repeatedEmptyReloads_neverStackMoreThanOneLabel() {
        let recentView = RecentView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))

        recentView.reloadData(windows: [], thumbnails: [:])
        recentView.reloadData(windows: [], thumbnails: [:])
        recentView.reloadData(windows: [], thumbnails: [:])

        XCTAssertEqual(
            emptyStateLabels(in: recentView).count, 1,
            "repeated empty reloads must not stack duplicate empty-state labels"
        )
    }
}
