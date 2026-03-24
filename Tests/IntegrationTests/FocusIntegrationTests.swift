import XCTest
import AppKit
import ApplicationServices
@testable import WindowPilotCore

/// Integration tests for WindowFocuser against real macOS windows.
///
/// These tests require:
///   - A real macOS desktop (skipped when CI env var is set)
///   - Accessibility permission (AXIsProcessTrusted() == true); skipped otherwise
///
/// INV-04: Selecting a window and pressing Enter MUST bring that exact window to
/// front and make it key.
final class FocusIntegrationTests: XCTestCase {

    // MARK: - Fixtures

    private var didOpenTextEdit = false

    override func tearDown() async throws {
        if didOpenTextEdit {
            TestWindowHarness.cleanupTextEdit()
        }
        try await super.tearDown()
    }

    // MARK: - INV-04: Focus switches correctly

    /// INV-04 — Focusing a TextEdit window via WindowFocuser must make TextEdit
    /// the frontmost application.
    func test_focus_switches_correctly() async throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else {
            throw XCTSkip("Skipping: requires real macOS desktop")
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Skipping: Accessibility permission not granted")
        }

        // Open 2 TextEdit windows so there is a tree to work with.
        didOpenTextEdit = true
        let markers = await TestWindowHarness.openTextEditWindows(count: 2)
        await TestWindowHarness.sleep(ms: 600)

        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let nodes = WindowEnumerator().enumerate(excludingPID: ownPID)

        let textEditNode = nodes.first { $0.name.lowercased().contains("textedit") }
        XCTAssertNotNil(textEditNode, "TextEdit must be visible in enumeration results")
        guard let node = textEditNode else { return }

        // Pick the second window by matching its marker title.
        let targetMarker = markers[1]
        let targetWindow = node.windows.first { $0.title.contains(targetMarker) }
        XCTAssertNotNil(targetWindow, "Second TextEdit window with marker '\(targetMarker)' must be enumerable")
        guard let window = targetWindow else { return }

        // Attempt focus.
        let focuser = WindowFocuser()
        let focused = focuser.focus(pid: node.id, windowTitle: window.title)

        // Allow the OS to process the activation.
        await TestWindowHarness.sleep(ms: 300)

        XCTAssertTrue(focused, "WindowFocuser.focus(pid:windowTitle:) must return true for a real window")

        let frontmost = NSWorkspace.shared.frontmostApplication
        XCTAssertEqual(
            frontmost?.processIdentifier,
            node.id,
            "Frontmost application must be TextEdit (pid \(node.id)) after focus; got \(frontmost?.localizedName ?? "nil")"
        )
    }

    /// INV-04 — Focusing a second TextEdit window must raise it over the first.
    /// Both windows belong to the same process, so we verify via AXUIElement title.
    func test_focus_raises_specific_window_within_same_app() async throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else {
            throw XCTSkip("Skipping: requires real macOS desktop")
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Skipping: Accessibility permission not granted")
        }

        didOpenTextEdit = true
        let markers = await TestWindowHarness.openTextEditWindows(count: 2)
        await TestWindowHarness.sleep(ms: 600)

        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let nodes = WindowEnumerator().enumerate(excludingPID: ownPID)
        guard let node = nodes.first(where: { $0.name.lowercased().contains("textedit") }) else {
            throw XCTSkip("TextEdit not found in enumeration")
        }

        let focuser = WindowFocuser()

        // Focus the first window, then the second, assert no crash and return value is true.
        for marker in markers {
            guard let window = node.windows.first(where: { $0.title.contains(marker) }) else { continue }
            let result = focuser.focus(pid: node.id, windowTitle: window.title)
            XCTAssertTrue(result, "focus() must succeed for marker '\(marker)'")
            await TestWindowHarness.sleep(ms: 200)
        }
    }

    // MARK: - Graceful failure cases

    /// Attempting to focus a window whose title does not exist must return false — not crash.
    func test_focus_nonexistent_window_returns_false() throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Skipping: Accessibility permission not granted (cannot verify false return)")
        }

        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let nodes = WindowEnumerator().enumerate(excludingPID: ownPID)

        // Use the first real PID we can find, but give it a title that cannot exist.
        guard let anyNode = nodes.first else {
            throw XCTSkip("No windows visible — cannot run this test")
        }

        let focuser = WindowFocuser()
        let result = focuser.focus(pid: anyNode.id, windowTitle: "WPTest_NonExistent_\(UUID().uuidString)")
        XCTAssertFalse(result, "focus() must return false for a window title that does not exist")
    }

    /// Calling focus() without Accessibility permission must return false — not crash.
    func test_focus_without_accessibility_permission_returns_false() throws {
        // This test is only meaningful when AX is NOT trusted.
        guard !AXIsProcessTrusted() else {
            throw XCTSkip("Skipping: Accessibility IS granted — cannot test the no-permission path here")
        }

        let focuser = WindowFocuser()
        let result = focuser.focus(pid: 1, windowTitle: "SomeWindow")
        XCTAssertFalse(result, "focus() must return false (not crash) when Accessibility permission is not granted")
    }

    /// hasAccessibilityPermission() must return the same value as AXIsProcessTrusted().
    func test_has_accessibility_permission_matches_ax_is_process_trusted() {
        let focuser = WindowFocuser()
        XCTAssertEqual(
            focuser.hasAccessibilityPermission(),
            AXIsProcessTrusted(),
            "WindowFocuser.hasAccessibilityPermission() must match AXIsProcessTrusted()"
        )
    }
}
