import XCTest
import AppKit
import CoreGraphics
@testable import WindowPilotCore

/// Integration tests for WindowCapture against real macOS windows.
///
/// INV-07: Without Screen Recording permission, capture must return nil — not crash.
/// The positive path (real capture) requires Screen Recording permission and a real window.
final class CaptureIntegrationTests: XCTestCase {

    // MARK: - Fixtures

    private var didOpenCalculator = false

    override func setUp() async throws {
        try await super.setUp()
    }

    override func tearDown() async throws {
        if didOpenCalculator {
            TestWindowHarness.closeCalculator()
        }
        try await super.tearDown()
    }

    // MARK: - INV-07: Capture without permission must not crash

    /// INV-07 — If Screen Recording permission is not granted, capture(windowID:) must
    /// return nil for any window ID, including a fabricated one.
    func test_capture_without_permission() {
        guard !CGPreflightScreenCaptureAccess() else {
            // Permission IS granted — the no-permission path is not reachable in this run.
            // We still verify that hasPermission() is consistent.
            let capture = WindowCapture()
            XCTAssertTrue(capture.hasPermission(), "hasPermission() must return true when CGPreflightScreenCaptureAccess() is true")
            return
        }

        let capture = WindowCapture()
        XCTAssertFalse(capture.hasPermission(), "hasPermission() must return false when screen recording is not granted")

        // Must return nil, not crash.
        let result = capture.capture(windowID: 12345)
        XCTAssertNil(result, "capture(windowID:) must return nil when Screen Recording permission is not granted")
    }

    /// INV-07 — capture(windowID: 0) must return nil (window 0 is invalid on macOS).
    func test_capture_invalid_window_id_returns_nil() throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Skipping positive path: Screen Recording permission not granted")
        }
        let capture = WindowCapture()
        // windowID 0 is kCGNullWindowID — CGWindowListCreateImage returns nil for it.
        let result = capture.capture(windowID: 0)
        XCTAssertNil(result, "capture(windowID: 0) must return nil (kCGNullWindowID is not capturable)")
    }

    // MARK: - Positive path (requires Screen Recording permission)

    /// Capturing a real Calculator window must return a non-nil CGImage with positive dimensions.
    func test_capture_returns_image() async throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else {
            throw XCTSkip("Skipping: requires real macOS desktop")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Skipping: Screen Recording permission not granted")
        }

        didOpenCalculator = true
        TestWindowHarness.openCalculator()
        // Give Calculator time to appear on screen.
        await TestWindowHarness.sleep(ms: 1500)

        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let nodes = WindowEnumerator().enumerate(excludingPID: ownPID)

        let calculatorNode = nodes.first { $0.name.lowercased().contains("calculator") }
        XCTAssertNotNil(calculatorNode, "Calculator must appear in enumeration after launch")
        guard let node = calculatorNode, let window = node.windows.first else { return }

        let capture = WindowCapture()
        let image = capture.capture(windowID: window.id)

        XCTAssertNotNil(image, "capture(windowID:) must return a non-nil CGImage for a real window")
        if let img = image {
            XCTAssertGreaterThan(img.width, 0, "Captured image width must be > 0")
            XCTAssertGreaterThan(img.height, 0, "Captured image height must be > 0")
        }
    }

    /// Capturing the same window twice in quick succession must not crash and must
    /// return a non-nil image both times (no resource leak between calls).
    func test_capture_repeated_calls_are_stable() async throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else {
            throw XCTSkip("Skipping: requires real macOS desktop")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Skipping: Screen Recording permission not granted")
        }

        didOpenCalculator = true
        TestWindowHarness.openCalculator()
        await TestWindowHarness.sleep(ms: 1500)

        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let nodes = WindowEnumerator().enumerate(excludingPID: ownPID)

        guard let node = nodes.first(where: { $0.name.lowercased().contains("calculator") }),
              let window = node.windows.first else {
            throw XCTSkip("Calculator window not found")
        }

        let capture = WindowCapture()
        for i in 1...5 {
            let image = capture.capture(windowID: window.id)
            XCTAssertNotNil(image, "Repeated capture call \(i)/5 must return non-nil image")
        }
    }

    // MARK: - hasPermission consistency

    /// hasPermission() must return the same value as CGPreflightScreenCaptureAccess().
    func test_has_permission_matches_cg_preflight() {
        let capture = WindowCapture()
        XCTAssertEqual(
            capture.hasPermission(),
            CGPreflightScreenCaptureAccess(),
            "WindowCapture.hasPermission() must match CGPreflightScreenCaptureAccess()"
        )
    }
}
