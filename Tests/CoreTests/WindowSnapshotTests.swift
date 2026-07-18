import XCTest
import CoreGraphics
@testable import WindowPilotCore

/// Coverage-predicate tests for `WindowSnapshot`. These exercise the pure
/// decision logic (entries + display frame in, bool out) without touching
/// CoreGraphics window APIs. All rects are in CG global coords: top-left
/// origin, Y increasing downward — the same space CGWindowList bounds and
/// CGDisplayBounds report, so the predicate never flips coordinates.
final class WindowSnapshotTests: XCTestCase {

    /// A 1000×1000 display anchored at the CG global origin (top-left).
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    private func entry(
        _ bounds: CGRect, layer: Int = 0, id: UInt32 = 1, pid: Int32 = 100
    ) -> WindowSnapshotEntry {
        WindowSnapshotEntry(id: id, pid: pid, bounds: bounds, layer: layer)
    }

    // MARK: - Required cases (task brief)

    func testCoveringLayerZeroWindowReturnsTrue() {
        // A layer-0 window filling the display → covered.
        let entries = [entry(display)]
        XCTAssertTrue(
            WindowSnapshot.hasLayerZeroWindowCovering(in: entries, displayFrame: display)
        )
    }

    func testLayerZeroWindowAtFiftyPercentReturnsFalse() {
        // Covers only the top half (50% of area) → below the 0.97 threshold.
        let half = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let entries = [entry(half)]
        XCTAssertFalse(
            WindowSnapshot.hasLayerZeroWindowCovering(in: entries, displayFrame: display)
        )
    }

    func testCoveringWindowOnOtherDisplayReturnsFalse() {
        // Full-covering window, but on a second display to the right (no overlap
        // with `display`) → this display is not covered.
        let otherDisplay = CGRect(x: 1000, y: 0, width: 1000, height: 1000)
        let entries = [entry(otherDisplay)]
        XCTAssertFalse(
            WindowSnapshot.hasLayerZeroWindowCovering(in: entries, displayFrame: display)
        )
    }

    func testEmptyListReturnsFalse() {
        XCTAssertFalse(
            WindowSnapshot.hasLayerZeroWindowCovering(in: [], displayFrame: display)
        )
    }

    // MARK: - Predicate guards

    func testCoveringNonLayerZeroWindowReturnsFalse() {
        // A window filling the display but on a system layer (menu bar / overlay)
        // must NOT count — only layer-0 application windows suppress the strip.
        let entries = [entry(display, layer: 25)]
        XCTAssertFalse(
            WindowSnapshot.hasLayerZeroWindowCovering(in: entries, displayFrame: display)
        )
    }

    func testCoverageThresholdIsHonored() {
        // A 98%-area window clears the default 0.97 gate but not a stricter one.
        let almostFull = CGRect(x: 0, y: 0, width: 1000, height: 980)
        let entries = [entry(almostFull)]
        XCTAssertTrue(
            WindowSnapshot.hasLayerZeroWindowCovering(in: entries, displayFrame: display)
        )
        XCTAssertFalse(
            WindowSnapshot.hasLayerZeroWindowCovering(
                in: entries, displayFrame: display, coverage: 0.99
            )
        )
    }

    func testZeroAreaDisplayReturnsFalse() {
        // A degenerate display frame (e.g. an unresolved screen number) must
        // not divide by zero or report coverage — the caller falls back to
        // the unconditional clear in that case.
        let entries = [entry(display)]
        XCTAssertFalse(
            WindowSnapshot.hasLayerZeroWindowCovering(in: entries, displayFrame: .zero)
        )
    }

    func testExcludedPIDWindowDoesNotCount() {
        // A full-covering layer-0 window owned by our own PID must NOT register
        // as the covering surface once excluded — the coverage guarantee is the
        // layer-0 filter PLUS the PID exclusion, not the "our windows never sit
        // at layer 0" invariant. Without the exclusion the same entry covers.
        let ownPID: Int32 = 999
        let entries = [entry(display, id: 7, pid: ownPID)]
        XCTAssertTrue(
            WindowSnapshot.hasLayerZeroWindowCovering(in: entries, displayFrame: display)
        )
        XCTAssertFalse(
            WindowSnapshot.hasLayerZeroWindowCovering(
                in: entries, displayFrame: display, excludingPID: ownPID
            )
        )
    }

    // MARK: - Snapshot lookup

    func testEntryLookupByWindowID() {
        let a = entry(display, id: 1, pid: 100)
        let b = entry(CGRect(x: 0, y: 0, width: 10, height: 10), id: 2, pid: 200)
        XCTAssertEqual(WindowSnapshot.entry(forWindowID: 2, in: [a, b]), b)
        XCTAssertNil(WindowSnapshot.entry(forWindowID: 99, in: [a, b]))
    }
}
