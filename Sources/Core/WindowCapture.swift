import CoreGraphics

/// Abstracts screenshot capture so callers (and tests) are not coupled to CGWindowListCreateImage.
public protocol WindowCapturing {
    /// Capture a screenshot of the given window. Returns nil if permission denied or capture fails.
    func capture(windowID: UInt32) -> CGImage?

    /// Check if screen recording permission is available.
    func hasPermission() -> Bool
}

/// Production implementation using CGWindowListCreateImage.
public final class WindowCapture: WindowCapturing {

    public init() {}

    public func capture(windowID: UInt32) -> CGImage? {
        guard hasPermission() else { return nil }

        return CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(windowID),
            .bestResolution
        )
    }

    public func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }
}
