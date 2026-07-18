import XCTest
import AppKit
import WindowPilotCore
@testable import WindowPilotUI

/// Unit tests for TreeView's selection single-source-of-truth behavior, plus
/// PilotPanel's resync of that selection into `selectedWindow` (the state the
/// ActionBar/preview actually act on).
///
/// These are pure AppKit object tests: they instantiate `TreeView`/`PilotPanel`
/// directly with fabricated `[AppNode]` data and drive their public
/// `reloadData`/`reloadTree` and `selectedWindowInfo`/`selectedWindow` API.
/// `@testable import` is used only to read PilotPanel's `internal
/// private(set) var selectedWindow` for assertions — no test writes it.
/// They require NO Accessibility permission, NO Screen Recording permission,
/// and NO on-screen window (PilotPanel is never ordered front or made key) —
/// NSOutlineView's data-source/selection logic and NSPanel construction both
/// run headless. They must ALWAYS execute (never environment-gated).
final class TreeSelectionTests: XCTestCase {

    // MARK: - Fixtures

    private func window(_ id: UInt32, _ title: String) -> WindowInfo {
        WindowInfo(id: id, ownerPID: 100, title: title, bounds: .zero, state: .normal)
    }

    private func app(_ pid: Int32, _ name: String, _ windows: [WindowInfo]) -> AppNode {
        AppNode(id: pid, name: name, bundleIdentifier: "test.\(name)", windows: windows)
    }

    private func makeTree() -> TreeView {
        TreeView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
    }

    // MARK: - Tests

    /// A reload that shuffles row order must keep the SAME window selected,
    /// identified by its window ID — not by the row index it used to occupy.
    func test_reload_preserves_selection_by_id_not_row_index() {
        let tree = makeTree()

        let w1 = window(1, "Alpha")
        let w2 = window(2, "Bravo")
        let w3 = window(3, "Charlie")

        // First load selects the first leaf (w1) at row 1.
        tree.reloadData(apps: [app(10, "AppA", [w1, w2, w3])])
        XCTAssertEqual(tree.selectedWindowInfo?.id, w1.id, "first leaf should be selected on first load")

        // Record any selection callbacks fired by the next reload.
        var fired: [WindowInfo] = []
        tree.onWindowSelected = { fired.append($0) }

        // Reload the same windows in a different order — w1 is now the LAST leaf.
        // Row 1 (w1's old position) now holds w3. A positional-preservation bug
        // would leave w3 selected; correct behavior follows w1's ID.
        tree.reloadData(apps: [app(10, "AppA", [w3, w2, w1])])

        XCTAssertEqual(tree.selectedWindowInfo?.id, w1.id, "selection must follow the window ID across reloads")
        XCTAssertNotEqual(tree.selectedWindowInfo?.id, w3.id, "selection must NOT be preserved by row index")
        XCTAssertTrue(fired.isEmpty, "same window remaining selected must not refire onWindowSelected")
    }

    /// When the selected window disappears from the data, selection must fall to
    /// the first leaf AND onWindowSelected must fire with that new window so the
    /// preview and action bar resync.
    func test_reload_dropping_selection_falls_to_first_leaf_and_fires() {
        let tree = makeTree()

        let w1 = window(1, "Alpha")
        let w2 = window(2, "Bravo")
        let w3 = window(3, "Charlie")

        tree.reloadData(apps: [app(10, "AppA", [w1, w2, w3])])
        XCTAssertEqual(tree.selectedWindowInfo?.id, w1.id)

        var fired: [WindowInfo] = []
        tree.onWindowSelected = { fired.append($0) }

        // Filter out w1 (the selected window). Selection should fall to the new
        // first leaf, w2, and fire exactly once with w2.
        tree.reloadData(apps: [app(10, "AppA", [w2, w3])])

        XCTAssertEqual(tree.selectedWindowInfo?.id, w2.id, "selection should fall to the first leaf when the prior selection is gone")
        XCTAssertEqual(fired.map(\.id), [w2.id], "onWindowSelected must fire once with the new selection")
    }

    /// Reloading identical data must not re-fire onWindowSelected (no spurious
    /// preview reload / no flicker) and must keep the same window selected.
    func test_reload_identical_data_does_not_refire() {
        let tree = makeTree()

        let w1 = window(1, "Alpha")
        let w2 = window(2, "Bravo")

        tree.reloadData(apps: [app(10, "AppA", [w1, w2])])
        XCTAssertEqual(tree.selectedWindowInfo?.id, w1.id)

        var fired: [WindowInfo] = []
        tree.onWindowSelected = { fired.append($0) }

        tree.reloadData(apps: [app(10, "AppA", [w1, w2])])

        XCTAssertEqual(tree.selectedWindowInfo?.id, w1.id, "selection unchanged on identical reload")
        XCTAssertTrue(fired.isEmpty, "identical reload must not refire onWindowSelected")
    }

    // MARK: - PilotPanel resync (regression: stale selection after empty reload)

    /// Regression test for the review finding: when a search filter reduces the
    /// tree to zero matches, `TreeView.reloadData(apps: [])` selects nothing and
    /// does NOT fire `onWindowSelected` (see the callback guard in
    /// `TreeView.reloadData` above — it only fires when the reload lands on a
    /// real window). Before the fix, `PilotPanel.reloadTree` never resynced
    /// after that no-op reload, so `PilotPanel.selectedWindow` kept pointing at
    /// the previously selected (now invisible) window — the ActionBar's
    /// Focus/Close/Minimize buttons would then act on a window the user could
    /// no longer see.
    func test_pilotPanel_reloadTreeToEmpty_clearsStaleSelection() {
        let panel = PilotPanel()

        let w1 = window(1, "Alpha")
        let w2 = window(2, "Bravo")

        // Initial load auto-selects the first leaf (w1); TreeView's first-load
        // selection callback wires through to PilotPanel.selectedWindow.
        panel.reloadTree(apps: [app(10, "AppA", [w1, w2])])
        XCTAssertEqual(panel.selectedWindow?.id, w1.id, "initial load should select the first leaf")

        // Search filter matches nothing: tree reloads to empty.
        panel.reloadTree(apps: [])

        XCTAssertNil(
            panel.selectedWindow,
            "no window should remain selected once the tree is empty — the ActionBar must not act on an invisible window"
        )
    }

    /// A reload that still has matches must keep tracking the surviving window
    /// (guards against an over-eager fix that always nils out selection on any
    /// reload, rather than only when the visible tab's selection actually went
    /// nil).
    func test_pilotPanel_reloadTreeToNonEmpty_tracksSurvivingSelection() {
        let panel = PilotPanel()

        let w1 = window(1, "Alpha")
        let w2 = window(2, "Bravo")

        panel.reloadTree(apps: [app(10, "AppA", [w1, w2])])
        XCTAssertEqual(panel.selectedWindow?.id, w1.id)

        // Filter narrows to just w2 (w1 dropped) — selection should follow to
        // the new first leaf, not go stale or nil.
        panel.reloadTree(apps: [app(10, "AppA", [w2])])

        XCTAssertEqual(panel.selectedWindow?.id, w2.id, "selection should follow to the surviving window")
    }

    // MARK: - Visible-tab gating (regression: debounced tree reload clobbers Recent-tab selection)

    /// Regression test for the review finding on `wireCallbacks()`:
    /// `TreeView.reloadData`'s ID-reselect logic can synchronously refire
    /// `onWindowSelected` even when the tree is NOT the visible tab. Reachable
    /// race: the user types a filter on the All tab (SearchBar debounces
    /// 30ms), switches to Recent within that window, and the debounced
    /// `reloadTree` then lands — `PilotPanel.reloadTree` runs
    /// `treeView.reloadData` unconditionally, BEFORE its `!showingRecent`
    /// guard. Before the fix, `treeView.onWindowSelected` was wired
    /// unconditionally in `wireCallbacks()`, so that synchronous refire
    /// clobbered `selectedWindow`/ActionBar with a tree window while Recent
    /// was on screen — stale until the next tab switch. The fix gates the
    /// handler on `!showingRecent`.
    func test_reloadTree_whileRecentTabVisible_doesNotClobberSelectionWithTreeWindow() {
        let panel = PilotPanel()

        let w1 = window(1, "Alpha")
        let w2 = window(2, "Bravo")

        // All Windows tab: first leaf (w1) auto-selected.
        panel.reloadTree(apps: [app(10, "AppA", [w1, w2])])
        XCTAssertEqual(panel.selectedWindow?.id, w1.id, "initial load should select the first leaf")

        // Switch to the Recent tab. `switchToTab` is internal (not private)
        // specifically so this test can simulate the switch directly without
        // going through `show()`, which orders the panel front — this suite
        // must stay headless-safe and never do that. Recent has no data
        // loaded, so its selection is nil; resyncSelectionToVisibleTab
        // correctly clears `selectedWindow` to match.
        panel.switchToTab(recent: true)
        XCTAssertNil(panel.selectedWindow, "switching to an empty Recent tab should clear selectedWindow")

        // Simulate the debounced search-filter reload landing on the tree
        // while Recent is still visible. Dropping w1 (the tree's previously
        // selected window) from the data forces TreeView's ID-reselect to
        // fall back to the new first leaf (w2) and fire onWindowSelected(w2)
        // synchronously from inside treeView.reloadData — exactly the
        // reload side-door the finding describes.
        panel.reloadTree(apps: [app(10, "AppA", [w2])])

        XCTAssertNil(
            panel.selectedWindow,
            "a tree reload landing while Recent is visible must not clobber selectedWindow with a tree window"
        )
    }
}
