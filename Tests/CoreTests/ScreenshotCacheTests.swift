import XCTest
import CoreGraphics
import WindowPilotCore

final class ScreenshotCacheTests: XCTestCase {

    private func makeImage(width: Int = 4, height: Int = 4) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    /// Byte cost of an image as ScreenshotCache accounts it.
    private func cost(_ image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    func testStoreAndRetrieve() {
        let cache = ScreenshotCache()
        cache.cache(image: makeImage(), forWindowID: 42)
        XCTAssertNotNil(cache.image(forWindowID: 42))
        XCTAssertNil(cache.image(forWindowID: 7))
    }

    func testRemoveAndClear() {
        let cache = ScreenshotCache()
        cache.cache(image: makeImage(), forWindowID: 1)
        cache.remove(windowID: 1)
        XCTAssertNil(cache.image(forWindowID: 1))
        cache.cache(image: makeImage(), forWindowID: 2)
        cache.clearAll()
        XCTAssertNil(cache.image(forWindowID: 2))
    }

    /// Hammers the cache from many threads at once, including a refreshAsync
    /// writing from its background queue while the caller reads. Under
    /// --sanitize=thread this fails on the unsynchronized implementation.
    func testConcurrentReadWriteDoesNotRace() {
        let cache = ScreenshotCache()
        let img = makeImage()

        DispatchQueue.concurrentPerform(iterations: 500) { i in
            let wid = UInt32(i % 16)
            switch i % 4 {
            case 0: cache.cache(image: img, forWindowID: wid)
            case 1: _ = cache.image(forWindowID: wid)
            case 2: cache.remove(windowID: wid)
            default: cache.clearAll()
            }
        }

        let done = expectation(description: "refreshAsync completes")
        cache.refreshAsync(
            windowIDs: (0..<16).map(UInt32.init),
            capture: { _ in img }
        ) { results in
            XCTAssertEqual(results.count, 16)
            done.fulfill()
        }
        // Read from the calling thread while the background refresh writes
        for i in 0..<200 { _ = cache.image(forWindowID: UInt32(i % 16)) }
        wait(for: [done], timeout: 5)
    }

    // MARK: - Downscale on store

    func testDownscalesWideImagesToMaxWidthPreservingAspect() {
        let cache = ScreenshotCache()
        cache.cache(image: makeImage(width: 2400, height: 1200), forWindowID: 1)
        let stored = cache.image(forWindowID: 1)
        XCTAssertEqual(stored?.width, 1200)
        XCTAssertEqual(stored?.height, 600) // aspect preserved: 1200 * (1200/2400)
    }

    func testDoesNotUpscaleImagesAtOrBelowMaxWidth() {
        let cache = ScreenshotCache()
        cache.cache(image: makeImage(width: 800, height: 500), forWindowID: 1)
        let stored = cache.image(forWindowID: 1)
        XCTAssertEqual(stored?.width, 800)
        XCTAssertEqual(stored?.height, 500)
    }

    func testRefreshAsyncDownscalesWideImages() {
        let cache = ScreenshotCache()
        let done = expectation(description: "refresh completes")
        cache.refreshAsync(
            windowIDs: [9],
            capture: { _ in self.makeImage(width: 2400, height: 600) }
        ) { results in
            XCTAssertEqual(results[9]?.width, 1200)
            XCTAssertEqual(results[9]?.height, 300)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(cache.image(forWindowID: 9)?.width, 1200)
    }

    // MARK: - Byte-cost accounting

    func testCostAccountingTracksStoredImages() {
        let cache = ScreenshotCache()
        let img = makeImage(width: 100, height: 100) // <= 1200, not downscaled
        cache.cache(image: img, forWindowID: 1)
        XCTAssertEqual(cache.currentCost, cost(img))

        // Re-storing the same key must not double-count.
        cache.cache(image: img, forWindowID: 1)
        XCTAssertEqual(cache.currentCost, cost(img))

        cache.remove(windowID: 1)
        XCTAssertEqual(cache.currentCost, 0)
    }

    // MARK: - LRU eviction

    func testEvictsLeastRecentlyUsedWhenOverCap() {
        let unit = cost(makeImage(width: 100, height: 100))
        let cache = ScreenshotCache(maxBytes: 3 * unit)
        cache.cache(image: makeImage(width: 100, height: 100), forWindowID: 1)
        cache.cache(image: makeImage(width: 100, height: 100), forWindowID: 2)
        cache.cache(image: makeImage(width: 100, height: 100), forWindowID: 3)
        XCTAssertEqual(cache.count, 3)

        // A READ of 1 refreshes its recency, making 2 the least-recently-used.
        _ = cache.image(forWindowID: 1)
        cache.cache(image: makeImage(width: 100, height: 100), forWindowID: 4)

        XCTAssertNotNil(cache.image(forWindowID: 1))
        XCTAssertNil(cache.image(forWindowID: 2))    // evicted
        XCTAssertNotNil(cache.image(forWindowID: 3))
        XCTAssertNotNil(cache.image(forWindowID: 4))
        XCTAssertLessThanOrEqual(cache.currentCost, 3 * unit)
    }

    func testWriteRefreshesRecency() {
        let unit = cost(makeImage(width: 100, height: 100))
        let cache = ScreenshotCache(maxBytes: 3 * unit)
        cache.cache(image: makeImage(width: 100, height: 100), forWindowID: 1)
        cache.cache(image: makeImage(width: 100, height: 100), forWindowID: 2)
        cache.cache(image: makeImage(width: 100, height: 100), forWindowID: 3)

        // Re-WRITING 1 refreshes its recency, making 2 the least-recently-used.
        cache.cache(image: makeImage(width: 100, height: 100), forWindowID: 1)
        cache.cache(image: makeImage(width: 100, height: 100), forWindowID: 4)

        XCTAssertNotNil(cache.image(forWindowID: 1))
        XCTAssertNil(cache.image(forWindowID: 2))    // evicted
        XCTAssertNotNil(cache.image(forWindowID: 3))
        XCTAssertNotNil(cache.image(forWindowID: 4))
    }

    // MARK: - Prune

    func testPruneKeepsOnlyLiveWindows() {
        let cache = ScreenshotCache()
        cache.cache(image: makeImage(width: 100, height: 100), forWindowID: 1)
        cache.cache(image: makeImage(width: 100, height: 100), forWindowID: 2)
        cache.cache(image: makeImage(width: 100, height: 100), forWindowID: 3)

        cache.prune(keeping: [1, 3])

        XCTAssertNotNil(cache.image(forWindowID: 1))
        XCTAssertNil(cache.image(forWindowID: 2))
        XCTAssertNotNil(cache.image(forWindowID: 3))
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.currentCost, 2 * cost(makeImage(width: 100, height: 100)))
    }

    // MARK: - Concurrency invariants

    /// Hammers a small-capped cache from many threads at once and asserts the
    /// cost invariant (total ≤ cap) holds afterward, with no crash. No timing
    /// assertions — only invariants.
    func testConcurrentEvictionKeepsCostUnderCap() {
        let unit = cost(makeImage(width: 100, height: 100))
        let cap = 8 * unit
        let cache = ScreenshotCache(maxBytes: cap)
        let img = makeImage(width: 100, height: 100)

        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            let wid = UInt32(i % 64)
            switch i % 4 {
            case 0: cache.cache(image: img, forWindowID: wid)
            case 1: _ = cache.image(forWindowID: wid)
            case 2: cache.prune(keeping: Set((0..<32).map(UInt32.init)))
            default: cache.remove(windowID: wid)
            }
        }

        XCTAssertLessThanOrEqual(cache.currentCost, cap)
        XCTAssertGreaterThanOrEqual(cache.currentCost, 0)
    }
}
