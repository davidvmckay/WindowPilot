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
}
