import XCTest
@testable import WindowPilotCore

// MARK: - MockWindowCapture

/// Test double for WindowCapturing. Returns a 1x1 CGImage when it has
/// permission, or nil when it does not.
private final class MockWindowCapture: WindowCapturing {

    private let permissionGranted: Bool
    private let imageToReturn: CGImage?

    /// Initialise with an explicit permission flag. When `hasPermission` is
    /// true a minimal 1x1 CGImage is synthesised at init time and returned
    /// from every `capture` call.
    init(hasPermission: Bool) {
        self.permissionGranted = hasPermission

        if hasPermission {
            // Synthesise the smallest valid CGImage (1x1 ARGB) without importing AppKit.
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            let space = CGColorSpaceCreateDeviceRGB()
            // 4 bytes: A, R, G, B
            let rawBytes: [UInt8] = [255, 0, 128, 255]
            let data = Data(rawBytes)
            let provider = CGDataProvider(data: data as CFData)!
            self.imageToReturn = CGImage(
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 4,
                space: space,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        } else {
            self.imageToReturn = nil
        }
    }

    func capture(windowID: UInt32) -> CGImage? {
        guard permissionGranted else { return nil }
        return imageToReturn
    }

    func hasPermission() -> Bool {
        permissionGranted
    }
}

// MARK: - WindowCaptureTests

final class WindowCaptureTests: XCTestCase {

    // A mock with permission returns a non-nil image for any window ID.
    func test_mock_capture_returns_image() {
        let mock = MockWindowCapture(hasPermission: true)
        let image = mock.capture(windowID: 42)
        XCTAssertNotNil(image, "capture(windowID:) should return a non-nil image when permission is granted")
    }

    // A mock without permission returns nil from capture, matching the real
    // capturers behaviour when Screen Recording access is denied.
    func test_mock_capture_returns_nil_without_permission() {
        let mock = MockWindowCapture(hasPermission: false)
        XCTAssertFalse(mock.hasPermission())
        let image = mock.capture(windowID: 42)
        XCTAssertNil(image, "capture(windowID:) must return nil when permission is not granted")
    }

    // MockWindowCapture must satisfy the WindowCapturing protocol contract
    // (verified at compile time; this test makes the intent explicit at
    // runtime and guards against accidental protocol changes).
    func test_protocol_conformance() {
        let mock: WindowCapturing = MockWindowCapture(hasPermission: true)
        // If MockWindowCapture did not conform, the assignment above would not
        // compile. The runtime call below confirms the conformance is exercised.
        let result = mock.capture(windowID: 1)
        _ = mock.hasPermission()
        XCTAssertNotNil(result)
    }
}
