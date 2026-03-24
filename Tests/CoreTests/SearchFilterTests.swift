import XCTest
@testable import WindowPilotCore

final class SearchFilterTests: XCTestCase {

    // Build the canonical three-app test fixture as [AppNode] once per test class.
    // Total: 3 apps, 7 windows (Code:3, Terminal:2, Chrome:2).
    private var threeApps: [AppNode] {
        makeAppNodes(from: TestFixtures.threeAppsScenario())
    }

    // "" → all 3 apps, all 7 windows pass through unchanged
    func test_empty_query_returns_all() {
        let result = SearchFilter.filter(threeApps, query: "")
        XCTAssertEqual(result.count, 3)
        let total = result.reduce(0) { $0 + $1.windows.count }
        XCTAssertEqual(total, 7)
    }

    // "terminal" → only Terminal with its 2 windows
    func test_match_app_name() {
        let result = SearchFilter.filter(threeApps, query: "terminal")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "Terminal")
        XCTAssertEqual(result.first?.windows.count, 2)
    }

    // "main.rs" matches a single Code window → Code with 1 window
    func test_match_window_title() {
        let result = SearchFilter.filter(threeApps, query: "main.rs")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "Code")
        XCTAssertEqual(result.first?.windows.count, 1)
        XCTAssertEqual(result.first?.windows.first?.title, "main.rs — windowpilot")
    }

    // Matching must be case-insensitive: "CHROME" → Google Chrome
    func test_case_insensitive() {
        let result = SearchFilter.filter(threeApps, query: "CHROME")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "Google Chrome")
    }

    // "zzzzz" matches nothing
    func test_no_match() {
        let result = SearchFilter.filter(threeApps, query: "zzzzz")
        XCTAssertEqual(result.count, 0)
    }

    // "code" matches the app name → Code returned with all 3 of its windows
    func test_partial_app_returns_all_windows() {
        let result = SearchFilter.filter(threeApps, query: "code")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "Code")
        XCTAssertEqual(result.first?.windows.count, 3)
    }

    // "hacker" matches only the "Hacker News" window inside Chrome
    func test_partial_window_returns_only_matching() {
        let result = SearchFilter.filter(threeApps, query: "hacker")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "Google Chrome")
        XCTAssertEqual(result.first?.windows.count, 1)
        XCTAssertEqual(result.first?.windows.first?.title, "Hacker News")
    }

    // "crates" matches the crates.io window inside Chrome (and Code's
    // "crates.io — windowpilot" window, but we at minimum expect Chrome's
    // crates.io window to be present)
    func test_query_matches_window_in_chrome() {
        let result = SearchFilter.filter(threeApps, query: "crates")
        XCTAssertFalse(result.isEmpty, "'crates' should match at least one app")
        let chromeResult = result.first { $0.name == "Google Chrome" }
        XCTAssertNotNil(chromeResult, "Google Chrome should be in results for 'crates'")
        let chromeTitles = chromeResult?.windows.map { $0.title } ?? []
        XCTAssertTrue(
            chromeTitles.contains { $0.contains("crates") },
            "Chrome's crates.io window should survive the 'crates' filter"
        )
    }

    // Leading/trailing whitespace must not block matching: "  terminal  " → Terminal
    func test_whitespace_handling() {
        let result = SearchFilter.filter(threeApps, query: "  terminal  ")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "Terminal")
    }

    // Special characters in query: "~/" matches Terminal windows whose titles
    // contain tilde-paths (e.g. "bash — ~/projects", "ssh — ~/dev/server")
    func test_special_characters() {
        let result = SearchFilter.filter(threeApps, query: "~/")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "Terminal")
        // Both Terminal windows contain "~/" in their titles
        XCTAssertEqual(result.first?.windows.count, 2)
    }
}
