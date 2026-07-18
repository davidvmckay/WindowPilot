import XCTest
import AppKit
@testable import WindowPilotCore
@testable import WindowPilotUI

/// Unit tests for VoiceOver semantics on the app's window cards:
/// `WindowCardView` (shared by CarouselPanel + SidebarPanel) and
/// `RecentCardView` (RecentView's grid card). Both are custom NSViews with
/// no built-in accessibility, so they must explicitly report themselves as
/// button-role accessibility elements with a descriptive label and route
/// `accessibilityPerformPress()` through the SAME closure the mouse path
/// uses (`onClicked`), so VoiceOver "activate" is indistinguishable from a
/// real click.
///
/// These are plain AppKit object tests: they instantiate the card views
/// directly with fabricated data and call the accessibility override
/// methods as plain Swift methods. No AX permission, no Screen Recording
/// permission, and no on-screen window are required — same pattern as
/// TreeSelectionTests. They must ALWAYS execute (never environment-gated).
///
/// `@testable import WindowPilotCore` is used only because `TrackedWindow`'s
/// memberwise initializer is `internal` (Swift does not auto-synthesize a
/// public one for public structs) — this test needs it to build fixtures.
/// `@testable import WindowPilotUI` is needed for `RecentCardView`, which is
/// package-internal (not `public`).
final class CardAccessibilityTests: XCTestCase {

    // MARK: - WindowCardView

    func test_windowCardView_isAccessibilityButton() {
        let card = WindowCardView(appName: "Safari", windowTitle: "Apple", pid: 0, thumbnail: nil)

        XCTAssertTrue(card.isAccessibilityElement())
        XCTAssertEqual(card.accessibilityRole(), .button)
    }

    func test_windowCardView_label_combinesAppNameAndTitle() {
        let card = WindowCardView(appName: "Safari", windowTitle: "Apple", pid: 0, thumbnail: nil)

        XCTAssertEqual(card.accessibilityLabel(), "Safari — Apple")
    }

    func test_windowCardView_label_fallsBackToAppNameWhenTitleEmpty() {
        let card = WindowCardView(appName: "Finder", windowTitle: "", pid: 0, thumbnail: nil)

        XCTAssertEqual(card.accessibilityLabel(), "Finder")
    }

    func test_windowCardView_label_fallsBackToAppNameWhenTitleOmitted() {
        // windowTitle has a default so existing call sites that don't pass
        // it (if any) still compile — confirm the fallback kicks in.
        let card = WindowCardView(appName: "Finder", pid: 0, thumbnail: nil)

        XCTAssertEqual(card.accessibilityLabel(), "Finder")
    }

    func test_windowCardView_performPress_firesOnClickedAndReturnsTrue() {
        let card = WindowCardView(appName: "Safari", windowTitle: "Apple", pid: 0, thumbnail: nil)

        var fired = false
        card.onClicked = { fired = true }

        let result = card.accessibilityPerformPress()

        XCTAssertTrue(result, "performPress should return true when a handler ran")
        XCTAssertTrue(fired, "performPress must invoke the SAME onClicked closure the mouse path uses")
    }

    func test_windowCardView_performPress_returnsFalseWithNoHandler() {
        let card = WindowCardView(appName: "Safari", windowTitle: "Apple", pid: 0, thumbnail: nil)

        XCTAssertFalse(card.accessibilityPerformPress(), "no handler attached — press must report failure, not silently no-op")
    }

    func test_windowCardView_reflectsSelectionState() {
        let card = WindowCardView(appName: "Safari", windowTitle: "Apple", pid: 0, thumbnail: nil)

        XCTAssertFalse(card.isAccessibilitySelected())

        card.setSelected(true)
        XCTAssertTrue(card.isAccessibilitySelected())

        card.setSelected(false)
        XCTAssertFalse(card.isAccessibilitySelected())
    }

    // MARK: - RecentCardView

    private func trackedWindow(appName: String, windowTitle: String) -> TrackedWindow {
        TrackedWindow(
            id: 1,
            pid: 0,
            appName: appName,
            bundleIdentifier: "test.\(appName)",
            windowTitle: windowTitle,
            lastFocusTime: Date(),
            totalDuration: 65,
            isFullScreen: false
        )
    }

    func test_recentCardView_isAccessibilityButton() {
        let tracked = trackedWindow(appName: "Mail", windowTitle: "Inbox")
        let card = RecentCardView(tracked: tracked, thumbnail: nil, index: 0)

        XCTAssertTrue(card.isAccessibilityElement())
        XCTAssertEqual(card.accessibilityRole(), .button)
    }

    func test_recentCardView_label_includesAppNameTitleAndRecency() {
        let tracked = trackedWindow(appName: "Mail", windowTitle: "Inbox")
        let card = RecentCardView(tracked: tracked, thumbnail: nil, index: 0)

        let label = card.accessibilityLabel()
        XCTAssertEqual(label, "Mail — Inbox, \(tracked.durationText)  ·  \(tracked.agoText)",
                       "label must reuse the exact recency string the meta label shows")
    }

    func test_recentCardView_label_fallsBackToAppNameWhenTitleEmpty() {
        let tracked = trackedWindow(appName: "Mail", windowTitle: "")
        let card = RecentCardView(tracked: tracked, thumbnail: nil, index: 0)

        XCTAssertEqual(card.accessibilityLabel(), "Mail, \(tracked.durationText)  ·  \(tracked.agoText)")
    }

    func test_recentCardView_performPress_firesOnClickedWithIndexAndReturnsTrue() {
        let tracked = trackedWindow(appName: "Mail", windowTitle: "Inbox")
        let card = RecentCardView(tracked: tracked, thumbnail: nil, index: 3)

        var firedIndex: Int?
        card.onClicked = { firedIndex = $0 }

        let result = card.accessibilityPerformPress()

        XCTAssertTrue(result, "performPress should return true when a handler ran")
        XCTAssertEqual(firedIndex, 3, "performPress must invoke the SAME onClicked closure the mouse path uses, with this card's index")
    }

    func test_recentCardView_performPress_returnsFalseWithNoHandler() {
        let tracked = trackedWindow(appName: "Mail", windowTitle: "Inbox")
        let card = RecentCardView(tracked: tracked, thumbnail: nil, index: 0)

        XCTAssertFalse(card.accessibilityPerformPress())
    }

    func test_recentCardView_reflectsSelectionState() {
        let tracked = trackedWindow(appName: "Mail", windowTitle: "Inbox")
        let card = RecentCardView(tracked: tracked, thumbnail: nil, index: 0)

        XCTAssertFalse(card.isAccessibilitySelected())

        card.setSelected(true)
        XCTAssertTrue(card.isAccessibilitySelected())

        card.setSelected(false)
        XCTAssertFalse(card.isAccessibilitySelected())
    }
}
