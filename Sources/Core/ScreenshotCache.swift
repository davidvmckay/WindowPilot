import Foundation
import CoreGraphics

// MARK: - ScreenshotCache

/// Session-level cache for window screenshot thumbnails.
/// Unlike PreviewView which clears on panel dismiss, this cache persists
/// for the MRU feature — thumbnails are served instantly and refreshed
/// in the background when the panel opens.
///
/// Bounded LRU by byte cost: entries are downscaled to at most `maxWidth`
/// pixels wide on store, and the least-recently-USED entries are evicted
/// once the total cost exceeds `maxBytes`. Both reads and writes refresh
/// recency. The full-resolution live preview does NOT transit this cache
/// (AppDelegate feeds the preview pane directly from WindowCapture), so the
/// downscale never degrades the preview.
public final class ScreenshotCache {

    private struct Entry {
        let image: CGImage
        let cost: Int   // bytesPerRow * height of the stored (post-downscale) image
    }

    private let lock = NSLock()
    private var entries: [UInt32: Entry] = [:]
    /// Recency order, front = least-recently-used, back = most-recently-used.
    private var lru: [UInt32] = []
    private var totalCost: Int = 0

    private let maxBytes: Int
    private let maxWidth: Int

    /// - Parameters:
    ///   - maxBytes: total byte-cost cap; least-recently-used entries are
    ///     evicted once exceeded (default 200 MB).
    ///   - maxWidth: images wider than this are downscaled to it on store,
    ///     aspect preserved (default 1200 px).
    public init(maxBytes: Int = 200 * 1024 * 1024, maxWidth: Int = 1200) {
        self.maxBytes = maxBytes
        self.maxWidth = maxWidth
    }

    // MARK: - Public API

    /// Store a screenshot for a window (downscaled if wider than `maxWidth`).
    public func cache(image: CGImage, forWindowID windowID: UInt32) {
        // Downscale outside the lock — it is CPU-bound and touches no shared state.
        let stored = downscaledIfNeeded(image)
        lock.lock(); defer { lock.unlock() }
        insertLocked(stored, forWindowID: windowID)
    }

    /// Retrieve a cached screenshot, refreshing its recency.
    public func image(forWindowID windowID: UInt32) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[windowID] else { return nil }
        touchLocked(windowID)
        return entry.image
    }

    /// Refresh screenshots for a list of window IDs in the background.
    /// Calls `capture` for each ID on a background queue, downscales, stores,
    /// then delivers the stored (downscaled) results on the main queue via
    /// `completion`.
    public func refreshAsync(
        windowIDs: [UInt32],
        capture: @escaping (UInt32) -> CGImage?,
        completion: @escaping ([UInt32: CGImage]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [UInt32: CGImage] = [:]
            for wid in windowIDs {
                if let image = capture(wid) {
                    let stored = self.downscaledIfNeeded(image)
                    results[wid] = stored
                    self.lock.lock()
                    self.insertLocked(stored, forWindowID: wid)
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
        removeLocked(windowID)
    }

    /// Drop entries for windows that no longer exist. `liveIDs` is the set of
    /// currently-enumerated window IDs; everything else is a dead window.
    public func prune(keeping liveIDs: Set<UInt32>) {
        lock.lock(); defer { lock.unlock() }
        for wid in entries.keys where !liveIDs.contains(wid) {
            if let entry = entries.removeValue(forKey: wid) {
                totalCost -= entry.cost
            }
        }
        lru.removeAll { !liveIDs.contains($0) }
    }

    /// Clear all cached screenshots.
    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        lru.removeAll()
        totalCost = 0
    }

    /// Current total byte cost of all cached entries. (Testing/introspection.)
    public var currentCost: Int {
        lock.lock(); defer { lock.unlock() }
        return totalCost
    }

    /// Number of cached entries. (Testing/introspection.)
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    // MARK: - Locked helpers (caller must hold `lock`)

    private func insertLocked(_ image: CGImage, forWindowID windowID: UInt32) {
        if let existing = entries[windowID] {
            totalCost -= existing.cost
        }
        let cost = image.bytesPerRow * image.height
        entries[windowID] = Entry(image: image, cost: cost)
        totalCost += cost
        touchLocked(windowID)
        evictLocked()
    }

    /// Move `windowID` to the most-recently-used position.
    private func touchLocked(_ windowID: UInt32) {
        if let idx = lru.firstIndex(of: windowID) {
            lru.remove(at: idx)
        }
        lru.append(windowID)
    }

    private func removeLocked(_ windowID: UInt32) {
        if let entry = entries.removeValue(forKey: windowID) {
            totalCost -= entry.cost
        }
        if let idx = lru.firstIndex(of: windowID) {
            lru.remove(at: idx)
        }
    }

    /// Evict from the least-recently-used end until under cap. The just-inserted
    /// entry sits at the MRU end, so it is only evicted if it alone exceeds the
    /// cap (a downscaled thumbnail never does at any sane `maxBytes`).
    private func evictLocked() {
        while totalCost > maxBytes, let lruID = lru.first {
            lru.removeFirst()
            if let entry = entries.removeValue(forKey: lruID) {
                totalCost -= entry.cost
            }
        }
    }

    // MARK: - Downscale (Core Graphics only — no AppKit)

    /// Downscale to `maxWidth` (aspect preserved) if wider; otherwise return
    /// the image unchanged. Draws the source into a fresh RGBA8 CGContext, so
    /// any source pixel format is colour-matched into a bitmap layout that
    /// CGBitmapContext always supports. If context creation fails, the original
    /// image is returned rather than dropping the capture.
    private func downscaledIfNeeded(_ image: CGImage) -> CGImage {
        guard image.width > maxWidth else { return image }

        let scale = Double(maxWidth) / Double(image.width)
        let newWidth = maxWidth
        let newHeight = max(1, Int((Double(image.height) * scale).rounded()))

        // Prefer the source colour space when it is RGB-model (keeps colours
        // faithful); otherwise fall back to device RGB. Pin to 8 bits/component
        // + premultiplied-last alpha + bytesPerRow 0 (CG-computed alignment) —
        // an always-supported CGBitmapContext configuration.
        let colorSpace: CGColorSpace = {
            if let cs = image.colorSpace, cs.model == .rgb { return cs }
            return CGColorSpaceCreateDeviceRGB()
        }()

        guard let ctx = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return ctx.makeImage() ?? image
    }
}
