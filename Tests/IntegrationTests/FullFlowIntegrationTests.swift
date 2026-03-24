import XCTest
import AppKit
import ApplicationServices
import CoreGraphics
@testable import WindowPilotCore

/// End-to-end integration test: enumerate → (optionally) capture → focus → cleanup.
///
/// This test exercises the full Core pipeline on a real macOS desktop.
/// Individual steps are skipped gracefully when the required permissions are absent.
///
/// Permissions required for full coverage:
///   - Screen Recording: capture step
///   - Accessibility: focus step
final class FullFlowIntegrationTests: XCTestCase {

    // MARK: - Fixtures

    private var didOpenApps = false

    override func tearDown() async throws {
        if didOpenApps {
            TestWindowHarness.cleanupTextEdit()
            TestWindowHarness.closeCalculator()
        }
        try await super.tearDown()
    }

    // MARK: - Full pipeline

    /// Opens TextEdit (2 windows) and Calculator, then runs the complete Core pipeline:
    ///   1. Enumerate — assert >= 2 distinct app nodes
    ///   2. Capture   — assert non-nil image (skipped if no Screen Recording permission)
    ///   3. Focus     — assert TextEdit becomes frontmost (skipped if no AX permission)
    func test_full_flow() async throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else {
            throw XCTSkip("Skipping: requires real macOS desktop")
        }

        // --- Setup ---
        didOpenApps = true
        _ = await TestWindowHarness.openTextEditWindows(count: 2)
        TestWindowHarness.openCalculator()
        await TestWindowHarness.sleep(ms: 1500)

        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)

        // --- Step 1: Enumerate ---
        let nodes = WindowEnumerator().enumerate(excludingPID: ownPID)

        XCTAssertGreaterThanOrEqual(
            nodes.count,
            2,
            "Full flow: enumeration must find at least 2 app nodes (TextEdit + Calculator)"
        )

        let textEditNode = nodes.first { $0.name.lowercased().contains("textedit") }
        let calculatorNode = nodes.first { $0.name.lowercased().contains("calculator") }

        XCTAssertNotNil(textEditNode, "Full flow: TextEdit must appear in enumeration")
        XCTAssertNotNil(calculatorNode, "Full flow: Calculator must appear in enumeration")

        // --- Step 2: Capture (conditional on Screen Recording permission) ---
        if CGPreflightScreenCaptureAccess(), let calcNode = calculatorNode, let calcWindow = calcNode.windows.first {
            let capture = WindowCapture()
            let image = capture.capture(windowID: calcWindow.id)
            XCTAssertNotNil(image, "Full flow: capture of Calculator window must return a non-nil CGImage")
            if let img = image {
                XCTAssertGreaterThan(img.width, 0, "Full flow: captured image must have positive width")
            }
        } else {
            // Screen Recording not available — log but do not fail.
            XCTAssertTrue(true, "Full flow: capture step skipped (Screen Recording permission not granted)")
        }

        // --- Step 3: Focus (conditional on Accessibility permission) ---
        if AXIsProcessTrusted(), let textEdit = textEditNode, let targetWindow = textEdit.windows.first {
            let focuser = WindowFocuser()
            let focusResult = focuser.focus(pid: textEdit.id, windowTitle: targetWindow.title)

            // Allow the OS to process the activation.
            await TestWindowHarness.sleep(ms: 300)

            XCTAssertTrue(focusResult, "Full flow: WindowFocuser.focus() must return true for a real TextEdit window")

            let frontmost = NSWorkspace.shared.frontmostApplication
            XCTAssertEqual(
                frontmost?.processIdentifier,
                textEdit.id,
                "Full flow: frontmost app must be TextEdit after focus; got '\(frontmost?.localizedName ?? "nil")'"
            )
        } else {
            XCTAssertTrue(true, "Full flow: focus step skipped (Accessibility permission not granted)")
        }
    }

    /// Verifies that Core modules tolerate being called on a quiet desktop
    /// (e.g. a newly booted machine with few windows open) without crashing.
    func test_full_flow_tolerates_sparse_desktop() throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else {
            throw XCTSkip("Skipping: requires real macOS desktop")
        }

        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let nodes = WindowEnumerator().enumerate(excludingPID: ownPID)

        // Search on whatever is present — must not crash for any query.
        let queries = ["", "a", "zzz_no_match_xyz", "App"]
        for query in queries {
            let filtered = SearchFilter.filter(nodes, query: query)
            // Empty result is fine; we only require no crash and valid types.
            for node in filtered {
                XCTAssertFalse(node.name.isEmpty)
            }
        }
    }

    /// Verifies that enumerate → filter → focus forms a coherent pipeline:
    /// the window IDs and PIDs returned by the enumerator are accepted by the focuser.
    func test_enumerate_to_focus_pipeline_type_compatibility() async throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else {
            throw XCTSkip("Skipping: requires real macOS desktop")
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Skipping: Accessibility permission not granted")
        }

        didOpenApps = true
        _ = await TestWindowHarness.openTextEditWindows(count: 1)
        await TestWindowHarness.sleep(ms: 600)

        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let nodes = WindowEnumerator().enumerate(excludingPID: ownPID)
        let filtered = SearchFilter.filter(nodes, query: "textedit")

        guard let node = filtered.first, let window = node.windows.first else {
            throw XCTSkip("TextEdit not found after filter")
        }

        // The PID and title from enumerator must be usable by focuser without type conversion.
        let focuser = WindowFocuser()
        _ = focuser.focus(pid: node.id, windowTitle: window.title)
        // We only assert no crash — the return value depends on window state.
    }
}
