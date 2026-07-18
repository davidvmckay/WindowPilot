import XCTest
import AppKit
import CoreGraphics
@testable import WindowPilotCore

/// Integration tests for WindowEnumerator against a real macOS desktop.
///
/// These tests open and close actual application windows.
/// They are skipped automatically when run in CI (CI env var set) or headless environments.
final class EnumerationIntegrationTests: XCTestCase {

    // MARK: - Fixtures

    /// Track whether this test class opened any TextEdit windows.
    private var didOpenTextEdit = false

    override func tearDown() async throws {
        if didOpenTextEdit {
            TestWindowHarness.cleanupTextEdit()
        }
        try await super.tearDown()
    }

    // MARK: - INV-05: Own PID exclusion

    /// INV-05 — WindowPilot's own panel must not appear in the tree.
    /// The enumerator must never return an AppNode whose id matches the caller's PID.
    func test_panel_excludes_self() throws {
        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let enumerator = WindowEnumerator()

        let nodes = enumerator.enumerate(excludingPID: ownPID)

        let ownNode = nodes.first { $0.id == ownPID }
        XCTAssertNil(
            ownNode,
            "enumerate(excludingPID:) must not return an AppNode whose id equals the caller's PID (\(ownPID))"
        )
    }

    /// Calling enumerate(excludingPID: nil) must still return an array (never crash).
    func test_enumeration_without_pid_exclusion_does_not_crash() {
        let enumerator = WindowEnumerator()
        let nodes = enumerator.enumerate(excludingPID: nil)
        // Result may be empty in headless — we only assert no crash and valid types.
        for node in nodes {
            XCTAssertFalse(node.name.isEmpty, "AppNode name must not be empty")
            XCTAssertGreaterThan(node.id, 0, "AppNode PID must be positive")
        }
    }

    // MARK: - QD-01: Enumeration performance

    /// QD-01 — enumerate() must complete in under 500ms (hard limit).
    /// Target is under 200ms.
    func test_enumeration_performance() throws {
        let enumerator = WindowEnumerator()
        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)

        let start = Date()
        _ = enumerator.enumerate(excludingPID: ownPID)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(
            elapsed,
            0.500,
            "enumerate() took \(String(format: "%.0f", elapsed * 1000))ms — must be < 500ms (hard limit). Target is < 200ms."
        )
    }

    /// QD-01 — enumerate() must stay under 500ms even when called 10 times in a row.
    /// Verifies no accumulating state or leak causes slowdown.
    func test_enumeration_performance_repeated_calls() throws {
        let enumerator = WindowEnumerator()
        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)

        for iteration in 1...10 {
            let start = Date()
            _ = enumerator.enumerate(excludingPID: ownPID)
            let elapsed = Date().timeIntervalSince(start)

            XCTAssertLessThan(
                elapsed,
                0.500,
                "enumerate() call \(iteration)/10 took \(String(format: "%.0f", elapsed * 1000))ms — must stay < 500ms."
            )
        }
    }

    // MARK: - Real-window tests (skipped in CI)

    /// Opens 2 TextEdit windows with known marker titles, enumerates, and asserts
    /// that both windows appear under the TextEdit AppNode.
    func test_enumeration_finds_real_windows() async throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else {
            throw XCTSkip("Skipping: requires real macOS desktop")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Skipping: requires Screen Recording permission (kCGWindowName is nil without it)")
        }

        didOpenTextEdit = true
        let markers = await TestWindowHarness.openTextEditWindows(count: 2)
        // Give TextEdit a moment to fully register both windows with CGWindowList.
        await TestWindowHarness.sleep(ms: 600)

        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let nodes = WindowEnumerator().enumerate(excludingPID: ownPID)

        let textEditNode = nodes.first { $0.name.lowercased().contains("textedit") }
        XCTAssertNotNil(textEditNode, "TextEdit must appear in enumeration results")

        guard let node = textEditNode else { return }

        XCTAssertGreaterThanOrEqual(
            node.windows.count,
            2,
            "TextEdit node must have at least 2 windows; found \(node.windows.count)"
        )

        let allTitles = node.windows.map { $0.title }
        for marker in markers {
            let found = allTitles.contains { $0.contains(marker) }
            XCTAssertTrue(found, "Marker '\(marker)' not found in TextEdit window titles: \(allTitles)")
        }
    }

    /// AppNode results must be sorted alphabetically by app name.
    func test_enumeration_results_are_sorted_by_app_name() throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else {
            throw XCTSkip("Skipping: requires real macOS desktop")
        }

        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let nodes = WindowEnumerator().enumerate(excludingPID: ownPID)

        guard nodes.count >= 2 else {
            throw XCTSkip("Skipping: need at least 2 app nodes to verify sort order")
        }

        let names = nodes.map { $0.name }
        let sortedNames = names.sorted()
        XCTAssertEqual(names, sortedNames, "AppNode array must be sorted alphabetically by app name")
    }

    /// Windows inside each AppNode must be sorted alphabetically by title.
    func test_windows_within_app_node_are_sorted_by_title() async throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else {
            throw XCTSkip("Skipping: requires real macOS desktop")
        }

        // Open 3 windows so we have something multi-window to check.
        didOpenTextEdit = true
        _ = await TestWindowHarness.openTextEditWindows(count: 3)
        await TestWindowHarness.sleep(ms: 600)

        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let nodes = WindowEnumerator().enumerate(excludingPID: ownPID)

        for node in nodes where node.windows.count >= 2 {
            let titles = node.windows.map { $0.title }
            let sortedTitles = titles.sorted()
            XCTAssertEqual(
                titles,
                sortedTitles,
                "Windows for '\(node.name)' must be sorted by title. Got: \(titles)"
            )
        }
    }
}
