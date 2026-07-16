# Auto-Update (Sparkle 2) + High-Priority Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship WindowPilot v1.3.0 with Sparkle 2 auto-update (hosted entirely on GitHub) plus fixes for the 6 high-priority defects from the 2026-07-15 review.

**Architecture:** Sparkle 2 integrates as an SPM binary dependency wrapped by a thin `UpdateManager` in App/ (Core/ untouched). The update feed (`appcast.xml`) lives on the repo `main` branch; update payloads are the existing notarized DMGs on GitHub Releases. A new `scripts/release.sh` encodes the full build→sign→notarize→appcast→upload pipeline. The 6 fixes are localized: one Core class gains a lock, the rest re-wire App/UI code onto the already-existing async capture pattern.

**Tech Stack:** Swift 5.9 / SPM, AppKit, Sparkle 2.x (sparkle-project/Sparkle), XCTest.

**Spec:** `docs/superpowers/specs/2026-07-15-auto-update-and-hotfixes-design.md`

## Global Constraints

- macOS 13.0+ (Ventura), Swift 5.9, SPM only (no Xcode project).
- `Sources/Core/` must NOT import AppKit or Sparkle. UI→Core dependency is one-way.
- Panel style must keep `.nonactivatingPanel`; never steal focus.
- Signing identity: `Developer ID Application: HONGBO ZHOU (SBU743JJ9S)`; notarization keychain profile: `notarytool` (never prompt for passwords).
- GitHub repo: `ethannortharc/WindowPilot`. Feed URL: `https://raw.githubusercontent.com/ethannortharc/WindowPilot/main/appcast.xml`.
- Work directly on `main` (repo convention). Commit after each task.
- All existing tests must stay green: `swift test` (IntegrationTests may require a real desktop session; at minimum `swift test --filter WindowPilotCoreTests` must pass).

## Delegation Guide (per user directive)

Clear/simple tasks → subagent with a smaller model; hard tasks → main-loop (Fable) or close review:

| Task | Delegate to |
|---|---|
| 1 (cache lock + test), 2 (first responder), 3 (snapshot filter) | sonnet subagent |
| 4 (async preview), 5 (focus outcome + HUD), 6 (carousel async) | opus subagent |
| 7 (Sparkle dep + UpdateManager), 8 (release script + keys), 9 (E2E test), 10 (release) | main loop (Fable), Task 10 needs explicit user go-ahead before publishing |

---

### Task 1: ScreenshotCache thread safety (F1)

**Files:**
- Modify: `Sources/Core/ScreenshotCache.swift`
- Test: `Tests/CoreTests/ScreenshotCacheTests.swift` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: same public API as today (`cache(image:forWindowID:)`, `image(forWindowID:)`, `refreshAsync(windowIDs:capture:completion:)`, `remove(windowID:)`, `clearAll()`) — now thread-safe. Later tasks (4, 6) rely on calling these from any queue.

- [ ] **Step 1: Write the failing test**

Create `Tests/CoreTests/ScreenshotCacheTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test under TSan to verify it detects the race**

Run: `swift test --sanitize=thread --filter WindowPilotCoreTests.ScreenshotCacheTests`
Expected: FAILS (ThreadSanitizer reports a data race on the cache dictionary, from `testConcurrentReadWriteDoesNotRace`). If TSan happens not to catch it on a given run, re-run once; proceed either way after confirming the tests at least build and run.

- [ ] **Step 3: Add the lock**

In `Sources/Core/ScreenshotCache.swift`, replace the class body's storage and methods so every dictionary access is guarded by one `NSLock`:

```swift
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
```

(Keep the file's existing header comments and imports — `Foundation` provides `NSLock`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --sanitize=thread --filter WindowPilotCoreTests.ScreenshotCacheTests`
Expected: PASS, no TSan reports.
Then run: `swift test --filter WindowPilotCoreTests`
Expected: PASS (all core tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/ScreenshotCache.swift Tests/CoreTests/ScreenshotCacheTests.swift
git commit -m "Fix ScreenshotCache data race with NSLock"
```

---

### Task 2: Recent tab keyboard navigation (F2)

**Files:**
- Modify: `Sources/UI/PilotPanel.swift:104-125` (`show()`), `:266-277` (`switchToTab`)
- Modify: `Sources/UI/RecentView.swift` (add `selectInitialCard()`)

**Interfaces:**
- Consumes: `RecentView.acceptsFirstResponder` / `keyDown` (already implemented).
- Produces: `RecentView.selectInitialCard()` — public, selects index 1 when >1 windows exist (index 0 is the currently focused window, mirroring CarouselPanel's preselect logic), else index 0. Fires `onWindowSelected` like any selection.

- [ ] **Step 1: Add `selectInitialCard()` to RecentView**

In `Sources/UI/RecentView.swift`, add to the `// MARK: Public API` section after `updateThumbnails`:

```swift
    /// Select the initial card for keyboard navigation. Index 0 is the window
    /// that was focused when the panel opened, so preselect index 1 (the
    /// "previous" window) when available — same logic as CarouselPanel.
    public func selectInitialCard() {
        guard !trackedWindows.isEmpty else { return }
        selectCard(at: trackedWindows.count > 1 ? 1 : 0)
    }
```

- [ ] **Step 2: Make RecentView first responder and select initial card**

In `Sources/UI/PilotPanel.swift`, replace `switchToTab`:

```swift
    private func switchToTab(recent: Bool) {
        showingRecent = recent
        tabBar.selectedSegment = recent ? 0 : 1

        recentView.isHidden = !recent
        splitView.isHidden = recent
        searchBar.isHidden = recent

        if recent {
            makeFirstResponder(recentView)
        } else {
            searchBar.focusSearchField()
        }
    }
```

In `show()`, after `makeKeyAndOrderFront(nil)`, replace the existing `if !showingRecent { searchBar.focusSearchField() }` block with:

```swift
        if showingRecent {
            makeFirstResponder(recentView)
            recentView.selectInitialCard()
        } else {
            searchBar.focusSearchField()
        }
```

- [ ] **Step 3: Build and run existing tests**

Run: `swift build && swift test --filter WindowPilotCoreTests`
Expected: builds, tests PASS.

- [ ] **Step 4: Manual acceptance check**

Run `.build/debug/WindowPilot`, press the panel hotkey (default Option+Space) with some window history: Recent tab shows, second card is highlighted, arrow keys move the highlight, Enter focuses the selected window — no mouse needed. (If this is executed by a subagent that cannot drive the GUI, note it for the human checklist and continue.)

- [ ] **Step 5: Commit**

```bash
git add Sources/UI/PilotPanel.swift Sources/UI/RecentView.swift
git commit -m "Fix Recent tab keyboard navigation: first responder + initial selection"
```

---

### Task 3: Search filters cached snapshot instead of re-enumerating (F3)

**Files:**
- Modify: `Sources/App/AppDelegate.swift` (property list ~line 20; `showPanel()` ~line 100; `onSearchChanged` ~line 413)

**Interfaces:**
- Consumes: `SearchFilter.filter(_:query:)` (existing Core API), `panel.reloadTree(apps:)`.
- Produces: `AppDelegate.cachedApps: [AppNode]` — snapshot of the last enumeration, refreshed on every `showPanel()`. Task 6 does NOT depend on it (carousel enumerates its own list).

- [ ] **Step 1: Add the snapshot property**

In `AppDelegate`'s properties (next to `private var lastTrackedWindowID: UInt32 = 0`), add:

```swift
    private var cachedApps: [AppNode] = []
```

- [ ] **Step 2: Populate it in `showPanel()`**

In `showPanel()`, right after `let apps = enumerator.enumerate(excludingPID: ownPID)`, add:

```swift
        cachedApps = apps
```

- [ ] **Step 3: Filter the snapshot in `onSearchChanged`**

Replace the `panel.onSearchChanged` closure in `wirePanel()`:

```swift
        panel.onSearchChanged = { [weak self] query in
            guard let self else { return }
            // Filter the snapshot from showPanel() — never re-enumerate per keystroke
            let filtered = SearchFilter.filter(self.cachedApps, query: query)
            self.panel.reloadTree(apps: filtered)
        }
```

- [ ] **Step 4: Build and test**

Run: `swift build && swift test --filter WindowPilotCoreTests`
Expected: builds, tests PASS. Manual check (if GUI available): typing in the search field filters instantly with no lag; clearing the query restores the full tree.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/AppDelegate.swift
git commit -m "Filter cached window snapshot on search instead of re-enumerating"
```

---

### Task 4: Asynchronous preview capture (F4)

**Files:**
- Modify: `Sources/App/AppDelegate.swift` (`onWindowSelected` closure, ~lines 355-378; properties ~line 20)

**Interfaces:**
- Consumes: thread-safe `ScreenshotCache` (Task 1), `panel.showPreview(image:)` (main-thread only), `capture.capture(windowID:)` (safe off-main).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add a generation counter property**

In `AppDelegate`'s properties, add:

```swift
    private var previewGeneration: UInt64 = 0
```

- [ ] **Step 2: Rewrite `onWindowSelected` to capture off the main thread**

Replace the entire `panel.onWindowSelected` closure in `wirePanel()`:

```swift
        panel.onWindowSelected = { [weak self] windowInfo in
            guard let self, self.hasScreenRecording else { return }
            self.previewGeneration &+= 1
            let generation = self.previewGeneration

            // Show the best image we already have; a fresh capture lands below.
            let cached = self.screenshotCache.image(forWindowID: windowInfo.id)
            self.panel.showPreview(image: cached)

            // Minimized windows produce tiny dock thumbnails — cached is all we have
            if windowInfo.state == .minimized { return }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let image = self.capture.capture(windowID: windowInfo.id)
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.previewGeneration else { return }
                    guard let image else { return }
                    // If the fresh capture is much smaller than cached, the window is
                    // likely mid-transition (resize/space switch) — keep the cached one.
                    if let cached, image.width * image.height < (cached.width * cached.height) / 2 {
                        return
                    }
                    self.panel.showPreview(image: image)
                    self.screenshotCache.cache(image: image, forWindowID: windowInfo.id)
                }
            }
        }
```

Note: this preserves both existing behaviors (minimized→cached-only; prefer-cached-when-shrunk) while moving `CGWindowListCreateImage` off the main thread. The generation guard drops stale captures when the selection has already moved on.

- [ ] **Step 3: Build and test**

Run: `swift build && swift test --filter WindowPilotCoreTests`
Expected: builds, tests PASS. Manual check (if GUI available): arrow-key rapidly through the tree — no stutter; preview updates to the last-selected window only.

- [ ] **Step 4: Commit**

```bash
git add Sources/App/AppDelegate.swift
git commit -m "Capture preview screenshots off the main thread with stale-drop"
```

---

### Task 5: Real focus outcomes + failure HUD (F5)

**Files:**
- Modify: `Sources/Core/WindowFocuser.swift:66-120` (`focus`)
- Create: `Sources/UI/ToastHUD.swift`
- Modify: `Sources/App/AppDelegate.swift` (`performFocus` final calls; `onWindowClose`/`onWindowMinimize` closures)

**Interfaces:**
- Consumes: existing `focus/close/minimize` signatures (unchanged: `focus(pid:windowID:windowTitle:state:) -> Bool`).
- Produces: `ToastHUD.show(_ message: String, duration: TimeInterval = 1.6)` — public static, main-thread-only, in WindowPilotUI. `focus()` now returns `false` when no AX window matched or the raise action failed.

- [ ] **Step 1: Make `focus()` report a real outcome**

In `Sources/Core/WindowFocuser.swift`, the `if state == .fullScreen { ... } else { ... }` branches (lines 86-117) have byte-identical bodies — collapse them and capture the raise result. Replace everything from `if state == .fullScreen {` down to `return true` (lines 86-119) with:

```swift
        // CGS → SkyLight → AX. All three layers are needed for the system to
        // fully update (Space switch + front process + menu bar). Same sequence
        // for full-screen and normal targets.
        if windowID != 0 {
            switchDisplayToWindowSpace(windowID: windowID)
            var psn = ProcessSerialNumber()
            GetProcessForPID(pid, &psn)
            _SLPSSetFrontProcessWithOptions(&psn, windowID, 0x200)
            makeKeyWindow(&psn, windowID: windowID)
        }
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, true as CFTypeRef)

        guard let axWindow else {
            print("[WP] focus: no AX window match for wid=\(windowID) '\(windowTitle)'")
            return false
        }
        let raiseResult = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        if raiseResult != .success {
            print("[WP] focus: AXRaise failed (\(raiseResult.rawValue)) for wid=\(windowID)")
        }
        return raiseResult == .success
```

- [ ] **Step 2: Create ToastHUD**

Create `Sources/UI/ToastHUD.swift`:

```swift
import AppKit

// MARK: - ToastHUD

/// Transient floating HUD for surfacing action failures
/// (e.g. "Couldn't focus window"). Auto-dismisses after a short delay.
/// Main-thread only.
public enum ToastHUD {

    private static var panel: NSPanel?
    private static var dismissWorkItem: DispatchWorkItem?

    /// Show a short message centered near the bottom of the cursor's screen.
    public static func show(_ message: String, duration: TimeInterval = 1.6) {
        dismissWorkItem?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.sizeToFit()

        let hPad: CGFloat = 16
        let vPad: CGFloat = 10
        let size = NSSize(
            width: label.frame.width + hPad * 2,
            height: label.frame.height + vPad * 2
        )

        let hud = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hud.level = .floating
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.ignoresMouseEvents = true
        hud.isReleasedWhenClosed = false
        hud.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        label.setFrameOrigin(NSPoint(x: hPad, y: vPad))
        effect.addSubview(label)
        hud.contentView = effect

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        hud.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 0.15
        ))

        hud.orderFrontRegardless()
        panel = hud

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                hud.animator().alphaValue = 0
            }, completionHandler: {
                hud.orderOut(nil)
                hud.alphaValue = 1
                if panel === hud { panel = nil }
            })
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
```

- [ ] **Step 3: Surface failures in AppDelegate**

In `Sources/App/AppDelegate.swift`:

(a) `onWindowClose` closure — replace `_ = self.focuser.close(...)` line with:

```swift
            if !self.focuser.close(pid: windowInfo.ownerPID, windowTitle: windowInfo.title) {
                ToastHUD.show("Couldn't close \"\(windowInfo.title)\"")
            }
```

(b) `onWindowMinimize` closure — replace `_ = self.focuser.minimize(...)` line with:

```swift
            if !self.focuser.minimize(pid: windowInfo.ownerPID, windowTitle: windowInfo.title) {
                ToastHUD.show("Couldn't minimize \"\(windowInfo.title)\"")
            }
```

(c) In `performFocus`, the *final* focus attempt of each strategy branch gets a failure toast. There are four `_ = self.focuser.focus(...)`/`_ = focuser.focus(...)` calls that are terminal (the ones at approx lines 464, 471, 486, 526 — inside the Ctrl+Arrow fallback, the Ctrl+Arrow success path, the no-nav-info path, and the normal→normal path). For each, replace the pattern:

```swift
_ = self.focuser.focus(
    pid: info.ownerPID, windowID: info.id,
    windowTitle: info.title, state: info.state
)
```

with:

```swift
if !self.focuser.focus(
    pid: info.ownerPID, windowID: info.id,
    windowTitle: info.title, state: info.state
) {
    ToastHUD.show("Couldn't focus \"\(info.title)\" — it may have closed")
}
```

Do NOT touch the two intermediate calls in the normal→fullscreen branch (lines ~497 and ~507): the first is deliberately fire-and-forget before exit-fullscreen, and the second is followed by `raiseWindow`/`reEnterFullScreen` retries — only wrap the line-~507 call (it is the final focus of that branch) and leave the line-~497 one as `_ =`.

(In total: 5 focus call sites get the toast — 464, 471, 486, 507, 526 — and 497 stays discarded.)

- [ ] **Step 4: Build and test**

Run: `swift build && swift test --filter WindowPilotCoreTests`
Expected: builds (note `FocusIntegrationTests` and any test asserting `focus` returns `true` may need updating — if `swift test` fails on an assertion that focus of a dead/fake window returns true, update that test's expectation to `false`; the new semantics are the correct ones per spec).
Manual check (if GUI available): select a window in the panel, kill that app from Terminal, press Enter → HUD "Couldn't focus …" appears and fades.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/WindowFocuser.swift Sources/UI/ToastHUD.swift Sources/App/AppDelegate.swift
git commit -m "Return real focus outcomes and surface failures via ToastHUD"
```

---

### Task 6: Carousel shows instantly, thumbnails fill in async (F6)

**Files:**
- Modify: `Sources/UI/CarouselPanel.swift` (add `updateThumbnails`; add `updateThumbnail` to `CarouselCardView`)
- Modify: `Sources/App/AppDelegate.swift:178-196` (`showCarousel` capture loop)

**Interfaces:**
- Consumes: thread-safe `ScreenshotCache.refreshAsync` (Task 1).
- Produces: `CarouselPanel.updateThumbnails(_ thumbnails: [UInt32: CGImage])` — public, main-thread, updates both the model items and visible cards.

- [ ] **Step 1: Add thumbnail update APIs to CarouselPanel**

In `Sources/UI/CarouselPanel.swift`, add to the `// MARK: Public API` section after `dismiss()`:

```swift
    /// Update thumbnails after a background refresh (windowID → image).
    public func updateThumbnails(_ thumbnails: [UInt32: CGImage]) {
        for (i, item) in windows.enumerated() {
            guard let img = thumbnails[item.windowID], i < cardViews.count else { continue }
            windows[i] = CarouselItem(
                windowID: item.windowID, pid: item.pid,
                appName: item.appName, windowTitle: item.windowTitle,
                thumbnail: img
            )
            cardViews[i].updateThumbnail(img)
        }
    }
```

And in `CarouselCardView` (bottom of the same file), add after `setSelected`:

```swift
    func updateThumbnail(_ image: CGImage) {
        thumbnailView.image = NSImage(cgImage: image, size: .zero)
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
    }
```

- [ ] **Step 2: Replace the synchronous capture loop in `showCarousel()`**

In `Sources/App/AppDelegate.swift`, delete the entire block:

```swift
        // Capture screenshots for items that don't have cached thumbnails
        // Skip minimized windows — they produce tiny dock thumbnails
        if hasScreenRecording {
            let minimizedIDs = Set(allApps.flatMap { $0.windows.filter { $0.state == .minimized }.map { $0.id } })
            for i in items.indices {
                if items[i].thumbnail == nil && !minimizedIDs.contains(items[i].windowID) {
                    if let img = capture.capture(windowID: items[i].windowID) {
                        screenshotCache.cache(image: img, forWindowID: items[i].windowID)
                        items[i] = CarouselItem(
                            windowID: items[i].windowID, pid: items[i].pid,
                            appName: items[i].appName, windowTitle: items[i].windowTitle,
                            thumbnail: img
                        )
                    }
                }
            }
        }

        carousel.show(items: items)
```

and replace with:

```swift
        // Show immediately with cached thumbnails/placeholders, then fill in
        // missing screenshots in the background (same pattern as showPanel).
        carousel.show(items: items)

        if hasScreenRecording {
            let minimizedIDs = Set(allApps.flatMap { $0.windows.filter { $0.state == .minimized }.map { $0.id } })
            let missingIDs = items
                .filter { $0.thumbnail == nil && !minimizedIDs.contains($0.windowID) }
                .map { $0.windowID }
            screenshotCache.refreshAsync(
                windowIDs: missingIDs,
                capture: { [weak self] wid in self?.capture.capture(windowID: wid) }
            ) { [weak self] refreshed in
                guard let self, self.carousel.isVisible else { return }
                self.carousel.updateThumbnails(refreshed)
            }
        }
```

(`var items` can stay `var`; unused mutability is fine, or change to `let` if the compiler warns.)

- [ ] **Step 3: Build and test**

Run: `swift build && swift test --filter WindowPilotCoreTests`
Expected: builds, tests PASS. Manual check (if GUI available): quit and relaunch the app (cold cache), press the carousel hotkey (Ctrl+Option+Space) — carousel appears instantly with placeholder icons, thumbnails pop in within ~a second.

- [ ] **Step 4: Commit**

```bash
git add Sources/UI/CarouselPanel.swift Sources/App/AppDelegate.swift
git commit -m "Show carousel instantly, fill thumbnails asynchronously"
```

---

### Task 7: Sparkle dependency + UpdateManager + menu item

**Files:**
- Modify: `Package.swift`
- Create: `Sources/App/UpdateManager.swift`
- Modify: `Sources/App/AppDelegate.swift` (property, init, status menu)

**Interfaces:**
- Consumes: Sparkle SPM product `Sparkle`.
- Produces: `UpdateManager` — `init()`, `var isAvailable: Bool`, `func checkForUpdates()`. Task 8's release script relies on the executable linking Sparkle with rpath `@executable_path/../Frameworks`.

- [ ] **Step 1: Add the Sparkle dependency and rpaths**

In `Package.swift`:

(a) In `dependencies`, after the HotKey line, add:

```swift
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
```

(b) In the `WindowPilot` executable target, add the product dependency and linker settings:

```swift
        .executableTarget(
            name: "WindowPilot",
            dependencies: [
                "WindowPilotCore",
                "WindowPilotUI",
                "HotKey",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/App",
            linkerSettings: [
                // Bundle layout: WindowPilot.app/Contents/Frameworks/Sparkle.framework
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    // Dev layout: .build/debug/WindowPilot finds the SPM artifact
                    "-Xlinker", "-rpath", "-Xlinker",
                    "@loader_path/../artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64",
                ]),
            ]
        ),
```

- [ ] **Step 2: Resolve and locate the Sparkle artifact**

Run: `swift package resolve && find .build/artifacts -type d -name "Sparkle.framework"`
Expected: one path, e.g. `.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework`.
If the printed path differs from the second rpath in Step 1 (relative to `.build/`), update that rpath so `@loader_path/../` + the path-under-`.build` matches reality.

- [ ] **Step 3: Create UpdateManager**

Create `Sources/App/UpdateManager.swift`:

```swift
import AppKit
import Sparkle

// MARK: - UpdateManager

/// Thin wrapper around Sparkle's standard updater. App-layer only —
/// Core/ stays free of update logic.
///
/// Sparkle needs a real .app bundle (Info.plist with SUFeedURL and
/// SUPublicEDKey). When running the bare SPM executable during development
/// there is no bundle, so the updater stays disabled.
final class UpdateManager {

    private var controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    init() {
        guard Bundle.main.bundleIdentifier != nil else {
            print("[WP] UpdateManager: no app bundle — updater disabled (dev run)")
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// User-initiated check — Sparkle shows its own UI, including errors.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
```

- [ ] **Step 4: Wire into AppDelegate**

In `Sources/App/AppDelegate.swift`:

(a) Add property next to `private var preferencesWindow: PreferencesWindow?`:

```swift
    private var updateManager: UpdateManager!
```

(b) In `applicationDidFinishLaunching`, before `setupStatusItem()`:

```swift
        updateManager = UpdateManager()
```

(c) In `setupStatusItem()`, after the `About WindowPilot` item line, add:

```swift
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "")
```

(d) Add the action method next to `showAbout`:

```swift
    @objc private func checkForUpdatesAction() {
        updateManager.checkForUpdates()
    }
```

(The existing `for item in menu.items where item.action != nil { item.target = self }` loop picks up the new item automatically.)

- [ ] **Step 5: Build, test, and verify the dev binary launches**

Run: `swift build && swift test --filter WindowPilotCoreTests`
Expected: builds cleanly, tests PASS.
Run:

```bash
.build/debug/WindowPilot & APP_PID=$!; sleep 3; kill $APP_PID 2>/dev/null; wait $APP_PID 2>/dev/null; echo "exit: $?"
```

Expected: launches without a dyld "Library not loaded: @rpath/Sparkle.framework" crash (exit reflects SIGTERM, not an abort at load time), and stderr shows `[WP] UpdateManager: no app bundle — updater disabled (dev run)`.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved Sources/App/UpdateManager.swift Sources/App/AppDelegate.swift
git commit -m "Add Sparkle 2 updater with Check for Updates menu item"
```

---

### Task 8: EdDSA keys + scripted release pipeline

**Files:**
- Create: `scripts/release.sh` (executable)
- Create: `scripts/sparkle_public_key.txt` (committed — public key only)
- Modify: `.gitignore` (add `release-archive/` and `*.dmg`)

**Interfaces:**
- Consumes: Task 7's bundle layout expectations (`Contents/Frameworks/Sparkle.framework`, rpath).
- Produces: `scripts/release.sh <version> [notes.html]` honoring env overrides `FEED_URL`, `DOWNLOAD_URL_PREFIX`, `SKIP_NOTARIZE=1`, `DRY_RUN=1`. Regenerates `appcast.xml` at repo root. Task 9 and 10 call this script.

- [ ] **Step 1: Generate the EdDSA keypair (one-time) and store the public key**

```bash
swift build   # ensure Package.resolved exists with the sparkle pin
SPARKLE_VERSION=$(python3 -c "import json;print([p for p in json.load(open('Package.resolved'))['pins'] if p['identity']=='sparkle'][0]['state']['version'])")
mkdir -p .build/sparkle-dist
curl -L "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" | tar -xJ -C .build/sparkle-dist
.build/sparkle-dist/bin/generate_keys
```

Expected: prints an `SUPublicEDKey` value (a base64 string) — the private key goes into the login Keychain automatically. If a key already exists, run `.build/sparkle-dist/bin/generate_keys -p` to print the existing public key instead.
Save it: `echo "<the-base64-key>" > scripts/sparkle_public_key.txt` (file contains exactly the base64 string, one line).

- [ ] **Step 2: Write `scripts/release.sh`**

```bash
#!/bin/bash
# WindowPilot release pipeline:
#   build → assemble bundle → sign (inner-first) → DMG → notarize → staple
#   → generate appcast (EdDSA) → commit appcast + upload GitHub release
#
# Usage:   scripts/release.sh <version> [release-notes.html]
# Env:     FEED_URL              override SUFeedURL (default: GitHub raw appcast)
#          DOWNLOAD_URL_PREFIX   override enclosure URL prefix (default: GitHub release)
#          SKIP_NOTARIZE=1       skip notarization+staple (local testing only)
#          DRY_RUN=1             skip git push + gh release (local testing only)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [notes.html]}"
NOTES_HTML="${2:-}"
FEED_URL="${FEED_URL:-https://raw.githubusercontent.com/ethannortharc/WindowPilot/main/appcast.xml}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/ethannortharc/WindowPilot/releases/download/v${VERSION}/}"
IDENTITY="Developer ID Application: HONGBO ZHOU (SBU743JJ9S)"
APP="WindowPilot.app"
DMG="WindowPilot-${VERSION}.dmg"
ARCHIVE_DIR="release-archive"
PUBKEY="$(cat scripts/sparkle_public_key.txt)"

# --- 0. Sparkle command-line tools (cached, version-matched to Package.resolved)
SPARKLE_VERSION=$(python3 -c "import json;print([p for p in json.load(open('Package.resolved'))['pins'] if p['identity']=='sparkle'][0]['state']['version'])")
TOOLS=".build/sparkle-dist/bin"
if [ ! -x "$TOOLS/generate_appcast" ]; then
  mkdir -p .build/sparkle-dist
  curl -L "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" | tar -xJ -C .build/sparkle-dist
fi

# --- 1. Build
swift build -c release

# --- 2. Assemble bundle (updates the existing WindowPilot.app in place;
#         Resources/ with the app icon is preserved)
cp .build/release/WindowPilot "$APP/Contents/MacOS/WindowPilot"
cp .build/release/windowpilot-cli "$APP/Contents/MacOS/windowpilot-cli"
FRAMEWORK_SRC=$(find .build/artifacts -type d -name "Sparkle.framework" | head -1)
[ -n "$FRAMEWORK_SRC" ] || { echo "Sparkle.framework not found in .build/artifacts" >&2; exit 1; }
rm -rf "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$FRAMEWORK_SRC" "$APP/Contents/Frameworks/"

# --- 3. Info.plist (regenerated every release — single source of truth)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>WindowPilot</string>
    <key>CFBundleExecutable</key><string>WindowPilot</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.windowpilot.app</string>
    <key>CFBundleName</key><string>WindowPilot</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>SUFeedURL</key><string>${FEED_URL}</string>
    <key>SUPublicEDKey</key><string>${PUBKEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

# --- 4. Codesign, inner-first (Sparkle helpers must be signed or notarization fails)
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/Autoupdate"
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/Updater.app"
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE_FW"
codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/MacOS/windowpilot-cli"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

# --- 5. DMG
rm -f "$DMG"
hdiutil create -volname "WindowPilot" -srcfolder "$APP" -ov -format UDZO "$DMG"

# --- 6. Notarize + staple
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "notarytool" --wait
  xcrun stapler staple "$DMG"
fi

# --- 7. Appcast (only the newest DMG needs an entry; pre-Sparkle versions
#         can't read it anyway)
rm -rf "$ARCHIVE_DIR"
mkdir -p "$ARCHIVE_DIR"
cp "$DMG" "$ARCHIVE_DIR/"
if [ -n "$NOTES_HTML" ]; then
  cp "$NOTES_HTML" "$ARCHIVE_DIR/WindowPilot-${VERSION}.html"
fi
"$TOOLS/generate_appcast" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --maximum-deltas 0 \
  -o appcast.xml "$ARCHIVE_DIR"

# --- 8. Publish
if [ "${DRY_RUN:-0}" != "1" ]; then
  git add appcast.xml
  git commit -m "Update appcast for v${VERSION}"
  git push
  gh release create "v${VERSION}" "$DMG" --title "WindowPilot v${VERSION}" --generate-notes
  echo "Released v${VERSION}."
else
  echo "DRY_RUN: skipped appcast commit and GitHub release. Artifacts: $DMG, appcast.xml"
fi
```

Then: `chmod +x scripts/release.sh`

- [ ] **Step 3: Add ignore rules**

Append to `.gitignore`:

```
release-archive/
*.dmg
```

- [ ] **Step 4: Syntax-check the script**

Run: `bash -n scripts/release.sh && echo OK`
Expected: `OK`

- [ ] **Step 5: Commit**

```bash
git add scripts/release.sh scripts/sparkle_public_key.txt .gitignore
git commit -m "Add scripted release pipeline with Sparkle appcast generation"
```

---

### Task 9: End-to-end local update test

**Files:** none (uses `scripts/release.sh` with test overrides; artifacts in scratch dirs)

**Interfaces:**
- Consumes: `scripts/release.sh` env overrides (Task 8), Task 7's UpdateManager.

- [ ] **Step 1: Build two test versions against a localhost feed**

```bash
mkdir -p /tmp/wp-update-test/serve
FEED_URL="http://localhost:8000/appcast.xml" \
DOWNLOAD_URL_PREFIX="http://localhost:8000/" \
SKIP_NOTARIZE=1 DRY_RUN=1 scripts/release.sh 1.3.0
cp -R WindowPilot.app /tmp/wp-update-test/WindowPilot-old.app

FEED_URL="http://localhost:8000/appcast.xml" \
DOWNLOAD_URL_PREFIX="http://localhost:8000/" \
SKIP_NOTARIZE=1 DRY_RUN=1 scripts/release.sh 1.3.1
cp WindowPilot-1.3.1.dmg appcast.xml /tmp/wp-update-test/serve/
```

Expected: both runs finish; `appcast.xml` in serve/ has one `<item>` with `sparkle:version` 1.3.1, an `sparkle:edSignature` attribute, and an enclosure URL starting `http://localhost:8000/`.

- [ ] **Step 2: Serve the feed and run the old version**

```bash
(cd /tmp/wp-update-test/serve && python3 -m http.server 8000 &)
open /tmp/wp-update-test/WindowPilot-old.app
```

Then use the status menu → "Check for Updates…".
Expected: Sparkle dialog offers 1.3.1 → Install Update → app quits, replaces itself, relaunches → About WindowPilot shows Version 1.3.1. Kill the http server afterwards (`kill %1` in that shell / `pkill -f "http.server 8000"`).
This step needs a human at the GUI — if executed by an agent without GUI access, hand the checklist to the user and wait for confirmation before Task 10.

- [ ] **Step 3: Reset repo state**

```bash
git checkout -- appcast.xml 2>/dev/null || rm -f appcast.xml
rm -f WindowPilot-1.3.0.dmg WindowPilot-1.3.1.dmg
rm -rf /tmp/wp-update-test release-archive
```

(No commit — this task produces no repo changes.)

---

### Task 10: Release v1.3.0 for real  ⚠️ requires explicit user go-ahead

**Files:** `appcast.xml` (created at repo root, committed by the script)

- [ ] **Step 1: Confirm with the user** that v1.3.0 should be published (this pushes to GitHub and creates a public release).

- [ ] **Step 2: Run the pipeline**

```bash
scripts/release.sh 1.3.0
```

Expected: notarization `status: Accepted`, staple OK, appcast committed+pushed, release `v1.3.0` visible via `gh release list`.

- [ ] **Step 3: Post-release verification**

```bash
curl -s https://raw.githubusercontent.com/ethannortharc/WindowPilot/main/appcast.xml | grep -o 'sparkle:version="[^"]*"'
spctl -a -t open --context context:primary-signature -v WindowPilot-1.3.0.dmg
```

Expected: appcast shows `sparkle:version="1.3.0"`; spctl says `accepted`.
Install the released DMG locally so the user's own copy is on the Sparkle-enabled version.
