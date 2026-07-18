import XCTest
import AppKit
import WindowPilotCore
import WindowPilotUI

/// Unit tests for TreeView's selection single-source-of-truth behavior.
///
/// These are pure AppKit object tests: they instantiate `TreeView` directly with
/// fabricated `[AppNode]` data and drive its public `reloadData` / `selectedWindowInfo`
/// API. They require NO Accessibility permission, NO Screen Recording permission,
/// and NO on-screen window — NSOutlineView's data-source and selection logic run
/// headless. They must ALWAYS execute (never environment-gated).
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
}
