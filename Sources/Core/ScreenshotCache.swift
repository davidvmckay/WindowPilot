import Foundation
import CoreGraphics

// MARK: - ScreenshotCache

/// Session-level cache for window screenshot thumbnails.
/// Unlike PreviewView which clears on panel dismiss, this cache persists
/// for the MRU feature — thumbnails are served instantly and refreshed
/// in the background when the panel opens.
public final class ScreenshotCache {

    private let lock = NSLock()
    private var cache: [UInt32: CGImage] = [:]

    public init() {}

    /// Store a screenshot for a window.
    public func cache(image: CGImage, forWindowID windowID: UInt32) {
        lock.lock(); defer { lock.unlock() }
        cache[windowID] = image
    }

    /// Retrieve a cached screenshot.
    public func image(forWindowID windowID: UInt32) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return cache[windowID]
    }

    /// Refresh screenshots for a list of window IDs in the background.
    /// Calls `capture` for each ID on a background queue, then delivers
    /// results on the main queue via `completion`.
    public func refreshAsync(
        windowIDs: [UInt32],
        capture: @escaping (UInt32) -> CGImage?,
        completion: @escaping ([UInt32: CGImage]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [UInt32: CGImage] = [:]
            for wid in windowIDs {
                if let image = capture(wid) {
                    results[wid] = image
                    self.lock.lock()
                    self.cache[wid] = image
                    self.lock.unlock()
                }
            }
            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    /// Remove a specific entry (e.g., when a window is closed).
    public func remove(windowID: UInt32) {
        lock.lock(); defer { lock.unlock() }
        cache.removeValue(forKey: windowID)
    }

    /// Clear all cached screenshots.
    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
    }
}
