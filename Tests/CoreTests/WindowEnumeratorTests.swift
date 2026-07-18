import XCTest
import CoreGraphics
@testable import WindowPilotCore

// MARK: - MockWindowEnumerator

/// Performs the same filtering and grouping logic that the real WindowEnumerator
/// would apply to raw CGWindowList data, so these tests exercise that algorithm
/// without touching any Core Graphics APIs.
final class MockWindowEnumerator: WindowEnumerating {

    private let data: [MockWindowData]

    init(data: [MockWindowData]) {
        self.data = data
    }

    func enumerate(excludingPID: Int32?) -> [AppNode] {
        // 1. Filter: layer == 0, onscreen, not the excluded PID
        let eligible = data.filter {
            $0.layer == 0
                && $0.isOnscreen
                && $0.ownerPID != excludingPID
        }

        // 2. Group by PID
        var byPID: [Int32: (name: String, windows: [WindowInfo])] = [:]

        for entry in eligible {
            let title = (entry.windowName == nil || entry.windowName!.isEmpty)
                ? "Untitled"
                : entry.windowName!

            let info = WindowInfo(
                id: entry.windowID,
                ownerPID: entry.ownerPID,
                title: title,
                bounds: entry.bounds
            )

            if var existing = byPID[entry.ownerPID] {
                existing.windows.append(info)
                byPID[entry.ownerPID] = existing
            } else {
                byPID[entry.ownerPID] = (name: entry.ownerName, windows: [info])
            }
        }

        // 3. Build AppNodes, sort apps alphabetically, windows alphabetically
        return byPID.map { pid, value in
            let sortedWindows = value.windows.sorted { $0.title < $1.title }
            return AppNode(
                id: pid,
                name: value.name,
                bundleIdentifier: nil,
                windows: sortedWindows
            )
        }
        .sorted { $0.name < $1.name }
    }
}

// MARK: - WindowEnumeratorTests

final class WindowEnumeratorTests: XCTestCase {

    // Helpers
    private func enumerator(_ data: [MockWindowData]) -> MockWindowEnumerator {
        MockWindowEnumerator(data: data)
    }

    // threeAppsScenario (noise excluded) → 3 AppNodes
    func test_groups_into_correct_app_count() {
        let apps = enumerator(TestFixtures.threeAppsScenario()).enumerate(excludingPID: nil)
        XCTAssertEqual(apps.count, 3, "Expected 3 app nodes, got \(apps.count)")
    }

    // Code:3, Terminal:2, Chrome:2
    func test_groups_correct_window_counts() {
        let apps = enumerator(TestFixtures.threeAppsScenario()).enumerate(excludingPID: nil)

        let byName = Dictionary(uniqueKeysWithValues: apps.map { ($0.name, $0) })

        XCTAssertEqual(byName["Code"]?.windows.count, 3,
                       "Code should have 3 windows")
        XCTAssertEqual(byName["Terminal"]?.windows.count, 2,
                       "Terminal should have 2 windows")
        XCTAssertEqual(byName["Google Chrome"]?.windows.count, 2,
                       "Google Chrome should have 2 windows")
    }

    // SystemUIServer is at layer 25 → must not appear in results
    func test_filters_nonzero_layer() {
        let apps = enumerator(TestFixtures.threeAppsScenario()).enumerate(excludingPID: nil)
        let names = apps.map { $0.name }
        XCTAssertFalse(names.contains("SystemUIServer"),
                       "SystemUIServer (layer 25) must be excluded")
    }

    // Code's offscreen helper (isOnscreen: false) → not counted in Code's windows
    func test_filters_offscreen() {
        let apps = enumerator(TestFixtures.threeAppsScenario()).enumerate(excludingPID: nil)
        let code = apps.first { $0.name == "Code" }
        // Fixture has 3 onscreen + 1 offscreen for Code; only 3 should survive
        XCTAssertEqual(code?.windows.count, 3,
                       "Offscreen Code helper must be excluded; expected 3 windows")
        let titles = code?.windows.map { $0.title } ?? []
        XCTAssertFalse(titles.contains("Code Helper"),
                       "Offscreen 'Code Helper' window must not appear")
    }

    // excludingPID: 1001 removes Code entirely
    func test_self_exclusion() {
        let apps = enumerator(TestFixtures.threeAppsScenario()).enumerate(excludingPID: 1001)
        let names = apps.map { $0.name }
        XCTAssertFalse(names.contains("Code"),
                       "Code (PID 1001) should be excluded when excludingPID is 1001")
        XCTAssertEqual(apps.count, 2,
                       "Only Terminal and Google Chrome should remain")
    }

    // Apps returned in alphabetical order
    func test_apps_sorted_alphabetically() {
        let apps = enumerator(TestFixtures.threeAppsScenario()).enumerate(excludingPID: nil)
        let names = apps.map { $0.name }
        XCTAssertEqual(names, ["Code", "Google Chrome", "Terminal"])
    }

    // Code's windows returned alphabetically by title
    func test_windows_sorted_by_title() {
        let apps = enumerator(TestFixtures.threeAppsScenario()).enumerate(excludingPID: nil)
        let code = apps.first { $0.name == "Code" }
        let titles = code?.windows.map { $0.title } ?? []
        XCTAssertEqual(titles, titles.sorted(), "Code windows must be sorted alphabetically")
        XCTAssertEqual(titles, [
            "README.md — windowpilot",
            "crates.io — windowpilot",
            "main.rs — windowpilot",
        ])
    }

    // Empty input → empty output
    func test_empty_input() {
        let apps = enumerator([]).enumerate(excludingPID: nil)
        XCTAssertTrue(apps.isEmpty)
    }

    // Single-window app produces exactly 1 node with 1 window
    func test_single_window_app() {
        let apps = enumerator(TestFixtures.singleWindowApp()).enumerate(excludingPID: nil)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.windows.count, 1)
        XCTAssertEqual(apps.first?.name, "Calculator")
    }

    // nil and empty window names must become "Untitled"
    func test_nil_window_names_use_fallback() {
        let apps = enumerator(TestFixtures.nilWindowNames()).enumerate(excludingPID: nil)
        let someApp = apps.first { $0.name == "SomeApp" }
        XCTAssertNotNil(someApp)
        let titles = someApp?.windows.map { $0.title } ?? []
        XCTAssertEqual(titles.count, 2, "Both nil and empty-string windows should survive")
        for title in titles {
            XCTAssertEqual(title, "Untitled", "Expected 'Untitled', got '\(title)'")
        }
    }

    // All window IDs across all apps must be globally unique
    func test_no_duplicate_window_ids() {
        let apps = enumerator(TestFixtures.threeAppsScenario()).enumerate(excludingPID: nil)
        let ids = apps.flatMap { $0.windows }.map { $0.id }
        let uniqueIDs = Set(ids)
        XCTAssertEqual(ids.count, uniqueIDs.count,
                       "Duplicate window IDs detected: \(ids.count) total, \(uniqueIDs.count) unique")
    }

    // 50 windows enumerated well within 100 ms
    func test_many_windows_performance() {
        let data = TestFixtures.manyWindows(count: 50)
        let enumerator = MockWindowEnumerator(data: data)

        let start = Date()
        let apps = enumerator.enumerate(excludingPID: nil)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(apps.isEmpty)
        XCTAssertLessThan(elapsed, 0.1,
                          "Enumeration of 50 windows took \(elapsed)s — must be < 100ms")
    }
}

// MARK: - OffScreenEnumerationTests

/// Exercises the REAL WindowEnumerator merge/build statics (not MockWindowEnumerator)
/// around untitled off-screen windows. Entries are CG-shaped dictionaries so the
/// production filters run unmodified. AX presence is modeled by the tag passed to
/// buildAppNodes ("✕" = no AX representation), so no live Accessibility session is
/// needed — the AX call itself is covered at the integration tier.
final class OffScreenEnumerationTests: XCTestCase {

    /// Build a CGWindowList-shaped entry the way CGWindowListCopyWindowInfo would.
    private func cgEntry(
        id: UInt32,
        pid: Int32,
        ownerName: String,
        name: String?,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
        layer: Int = 0,
        alpha: Double = 1.0
    ) -> [String: Any] {
        var entry: [String: Any] = [
            kCGWindowNumber as String: id,
            kCGWindowOwnerPID as String: pid,
            kCGWindowOwnerName as String: ownerName,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
        ]
        if let name = name {
            entry[kCGWindowName as String] = name
        }
        return entry
    }

    // Q2 merge must admit an untitled off-screen window. Without Screen Recording
    // permission macOS returns NO kCGWindowName for other apps, so a name guard would
    // silently drop the entire cross-Space pass. (This is the core bug fix.)
    func test_appendOffScreen_admitsUntitledWindow() {
        let entry = cgEntry(id: 700, pid: 7001, ownerName: "Ghostty", name: nil)
        var seen = Set<UInt32>()
        var all: [(entry: [String: Any], tag: String)] = []

        WindowEnumerator.appendOffScreenEntries(
            from: [entry], displays: [], excludingPID: nil,
            seenIDs: &seen, into: &all)

        XCTAssertEqual(all.count, 1, "Untitled off-screen window must be admitted")
        XCTAssertEqual(all.first?.tag, "", "No display match → untagged; AX decides later")
        XCTAssertTrue(seen.contains(700), "Admitted window ID must be recorded as seen")
    }

    // Some apps set kCGWindowName to "" — empty-named off-screen windows must survive too.
    func test_appendOffScreen_admitsEmptyNamedWindow() {
        let entry = cgEntry(id: 701, pid: 7001, ownerName: "Ghostty", name: "")
        var seen = Set<UInt32>()
        var all: [(entry: [String: Any], tag: String)] = []

        WindowEnumerator.appendOffScreenEntries(
            from: [entry], displays: [], excludingPID: nil,
            seenIDs: &seen, into: &all)

        XCTAssertEqual(all.count, 1, "Empty-named off-screen window must be admitted")
    }

    // Junk filter now lives in AX: a ghost entry (CG window with no AX representation,
    // tagged "✕") must be excluded by buildAppNodes. This replaces the old name guard.
    func test_buildAppNodes_excludesGhostWindows() {
        let entry = cgEntry(id: 800, pid: 8001, ownerName: "Ghostty", name: nil)
        let nodes = WindowEnumerator.buildAppNodes(from: [(entry, "✕")])
        XCTAssertTrue(nodes.isEmpty, "Ghost windows (no AX presence) must be excluded")
    }

    // An untitled off-screen entry WITH AX presence (untagged) is kept and titled "Untitled".
    func test_buildAppNodes_keepsUntitledOffScreenWithAX() {
        let entry = cgEntry(id: 801, pid: 8001, ownerName: "Ghostty", name: nil)
        let nodes = WindowEnumerator.buildAppNodes(from: [(entry, "")])
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes.first?.name, "Ghostty")
        XCTAssertEqual(nodes.first?.windows.count, 1)
        XCTAssertEqual(nodes.first?.windows.first?.title, "Untitled",
                       "Off-screen window with AX presence but no name → 'Untitled'")
        XCTAssertEqual(nodes.first?.windows.first?.state, .normal)
    }
}
