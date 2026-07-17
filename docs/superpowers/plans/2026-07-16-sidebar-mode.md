# Sidebar Mode (Optional Persistent Work Strip) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an optional, off-by-default persistent sidebar strip (pinned slots + parking-lot dynamic zone) that attacks the task→window mapping cost via spatial memory.

**Architecture:** Two new pure-Core units (`SlotAllocator` parking-lot placement, `PinStore` pin persistence+matching) drive a new non-activating `SidebarPanel` in UI/. A shared `WindowCardView`/`WindowThumbnailView` is extracted first (also de-duplicating carousel/recent cards). AppDelegate wires the mode behind a status-menu toggle; the existing 2s focus tracker is the sync heartbeat. A one-day spike validates `.canJoinAllSpaces` before any UI is built.

**Tech Stack:** Swift 5.9 / SPM, AppKit (NSPanel non-activating), existing Core services (WindowEnumerator, WindowActivityTracker, ScreenshotCache, WindowFocuser).

**Spec:** `docs/superpowers/specs/2026-07-16-sidebar-mode-design.md`

## Global Constraints

- Sidebar is an OPTIONAL mode, ships **disabled**; toggled via status menu; collapsible to an 8pt hot edge; fully closeable. Summon panel + carousel stay primary and unchanged.
- `Sources/Core/` must NOT import AppKit. `SlotAllocator` and `PinStore` are pure logic with unit tests.
- The strip never takes focus: `.nonactivatingPanel`, `canBecomeKey == false`, filtered from its own window list (own-PID filter already exists in enumeration).
- **Parking-lot invariants (dynamic zone):** a seated window keeps its position until it dies or is evicted; focus changes never reshuffle; newcomers fill empty positions first, then evict the coldest seated window IN PLACE.
- Pinned slots: fixed positions, never auto-reordered; persisted across restarts; dead pin → dimmed app icon, click activates the app.
- Thumbnail refresh: only when a window loses focus + lazily; all captures via the established `refreshAsync` background pattern. No new polling beyond the existing 2s tracker.
- Capacities v1: 3 pinned + 5 dynamic slots.
- macOS 13.0+, Swift 5.9, SPM. `swift build && swift test --filter WindowPilotCoreTests` green after every task. Work on `main`, commit per task.

## Delegation Guide (per user directive)

| Task | Worker |
|---|---|
| 1 (spike — needs live GUI judgment) | main loop (Fable) + user at GUI |
| 2 (SlotAllocator), 3 (PinStore) — complete code in plan, TDD | sonnet subagent |
| 4 (card extraction refactor), 5 (SidebarPanel), 6 (interactions) | opus subagent |
| 7 (App wiring — cross-cutting) | main loop (Fable) |
| 8 (verification) | main loop (Fable) + user at GUI |

---

### Task 1: Spike — persistent `.canJoinAllSpaces` panel vs Space switching

**Files:**
- Modify: `Sources/App/AppDelegate.swift` (temporary block in `applicationDidFinishLaunching`, removed again in Task 5)

**Interfaces:**
- Produces: a DECISION recorded in this plan file and the ledger: `SIDEBAR_COLLECTION_BEHAVIOR = canJoinAllSpaces` or `= moveToActiveSpace+reattach`. Task 5 reads this decision.

Background: the summon panel had to switch from `.canJoinAllSpaces` to `.moveToActiveSpace` because a panel considered "present" on a full-screen Space after `orderOut` broke Space-switch animations. The strip is never dismissed, so the old failure mode may not apply — but it must be proven on this macOS before building the UI.

- [ ] **Step 1: Add the spike block (temporary)**

In `applicationDidFinishLaunching`, after `setupStatusItem()`:

```swift
        // TEMPORARY SPIKE (removed in sidebar Task 5): validate persistent
        // canJoinAllSpaces panel vs Space switching. Run with --sidebar-spike.
        if ProcessInfo.processInfo.arguments.contains("--sidebar-spike") {
            let spike = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 76, height: 400),
                styleMask: [.nonactivatingPanel],
                backing: .buffered, defer: false
            )
            spike.level = .floating
            spike.isReleasedWhenClosed = false
            spike.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            spike.backgroundColor = .clear
            spike.isOpaque = false
            let effect = NSVisualEffectView(frame: spike.contentLayoutRect)
            effect.material = .hudWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 10
            let label = NSTextField(labelWithString: "SPIKE")
            label.frame = NSRect(x: 14, y: 190, width: 60, height: 20)
            effect.addSubview(label)
            spike.contentView = effect
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                spike.setFrame(NSRect(x: f.maxX - 76, y: f.midY - 200, width: 76, height: 400), display: true)
            }
            spike.orderFrontRegardless()
        }
```

- [ ] **Step 2: Build and launch with the flag**

Run: `swift build && .build/debug/WindowPilot --sidebar-spike`
Expected: strip-shaped HUD panel appears at the right edge of the main display.

- [ ] **Step 3: Human GUI checklist (user, ~10 minutes)**

With the spike panel visible, verify each:
1. Switch between normal Spaces (Ctrl+←/→): panel visible on every Space, Space-switch animation normal.
2. Enter a full-screen app: does the panel stay visible (acceptable) or vanish (also acceptable)? Any rendering artifact?
3. Exit full-screen: animation normal.
4. Use WindowPilot (Option+Space) to focus a window on ANOTHER Space: the Space-switch animation and focus must work exactly as without the spike (this is the regression that killed `.canJoinAllSpaces` before).
5. Use the carousel (Ctrl+Option+Space) across Spaces: same check.

- [ ] **Step 4: Record the decision**

If all 5 pass: record `SIDEBAR_COLLECTION_BEHAVIOR = [.canJoinAllSpaces, .fullScreenAuxiliary]` in the progress ledger and continue.
If check 4/5 regress: record `= [.moveToActiveSpace, .fullScreenAuxiliary]` + "reattach on activeSpaceDidChangeNotification" (Task 7 then adds: observe `NSWorkspace.shared.notificationCenter` `NSWorkspace.activeSpaceDidChangeNotification` → `sidebar?.orderFrontRegardless()`).

- [ ] **Step 5: Commit the spike (it is removed in Task 5)**

```bash
git add Sources/App/AppDelegate.swift
git commit -m "Add temporary --sidebar-spike flag to validate canJoinAllSpaces"
```

---

### Task 2: Core — SlotAllocator (parking-lot semantics)

**Files:**
- Create: `Sources/Core/SlotAllocator.swift`
- Test: `Tests/CoreTests/SlotAllocatorTests.swift`

**Interfaces:**
- Produces: `SlotAllocator(capacity: Int)`, `var slots: [UInt32?]` (read-only), `mutating func sync(live: Set<UInt32>, priority: [UInt32])`. Task 7 calls `sync` on every focus change and renders `slots`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CoreTests/SlotAllocatorTests.swift`:

```swift
import XCTest
import WindowPilotCore

final class SlotAllocatorTests: XCTestCase {

    func testFillsEmptySlotsTopDownByPriority() {
        var a = SlotAllocator(capacity: 3)
        a.sync(live: [10, 20], priority: [20, 10])
        XCTAssertEqual(a.slots, [20, 10, nil])
    }

    func testFocusChangeNeverReshufflesSeatedWindows() {
        var a = SlotAllocator(capacity: 3)
        a.sync(live: [10, 20, 30], priority: [10, 20, 30])
        let before = a.slots
        // Same world, totally different priority order — nothing may move.
        a.sync(live: [10, 20, 30], priority: [30, 20, 10])
        XCTAssertEqual(a.slots, before)
    }

    func testDeadWindowFreesItsSlotOthersStay() {
        var a = SlotAllocator(capacity: 3)
        a.sync(live: [10, 20, 30], priority: [10, 20, 30])
        a.sync(live: [10, 30], priority: [10, 30])
        XCTAssertEqual(a.slots, [10, nil, 30])
    }

    func testNewcomerFillsFreedSlotInPlace() {
        var a = SlotAllocator(capacity: 3)
        a.sync(live: [10, 20, 30], priority: [10, 20, 30])
        a.sync(live: [10, 30], priority: [10, 30])           // frees middle
        a.sync(live: [10, 30, 40], priority: [40, 10, 30])   // 40 takes the freed middle slot
        XCTAssertEqual(a.slots, [10, 40, 30])
    }

    func testHotNewcomerEvictsColdestInPlace() {
        var a = SlotAllocator(capacity: 3)
        a.sync(live: [10, 20, 30], priority: [10, 20, 30])
        // Zone full. 40 is hottest; 30 is coldest → replaced in place (index 2).
        a.sync(live: [10, 20, 30, 40], priority: [40, 10, 20, 30])
        XCTAssertEqual(a.slots, [10, 20, 40])
    }

    func testColdNewcomerDoesNotEvictHotterSeated() {
        var a = SlotAllocator(capacity: 2)
        a.sync(live: [10, 20], priority: [10, 20])
        // 30 is colder than both seated windows → no change.
        a.sync(live: [10, 20, 30], priority: [10, 20, 30])
        XCTAssertEqual(a.slots, [10, 20])
    }

    func testUnrankedWindowsRankColdest() {
        var a = SlotAllocator(capacity: 2)
        a.sync(live: [10, 20], priority: [10, 20])
        // 20 vanished from priority (unranked) → coldest; 30 (ranked) evicts it in place.
        a.sync(live: [10, 20, 30], priority: [30, 10])
        XCTAssertEqual(a.slots, [10, 30])
    }

    func testZeroCapacity() {
        var a = SlotAllocator(capacity: 0)
        a.sync(live: [10], priority: [10])
        XCTAssertEqual(a.slots, [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WindowPilotCoreTests.SlotAllocatorTests`
Expected: FAIL to compile — "cannot find 'SlotAllocator' in scope".

- [ ] **Step 3: Implement**

Create `Sources/Core/SlotAllocator.swift`:

```swift
import Foundation

// MARK: - SlotAllocator

/// Parking-lot placement for the sidebar's dynamic zone.
///
/// Invariants (spatial stability — the whole point of the sidebar):
/// - A seated window keeps its position until it dies or is evicted.
/// - Focus changes never reshuffle seated windows.
/// - Newcomers fill empty positions first, then replace the coldest
///   seated window IN PLACE.
public struct SlotAllocator: Equatable {

    public private(set) var slots: [UInt32?]

    public init(capacity: Int) {
        slots = Array(repeating: nil, count: max(0, capacity))
    }

    /// Reconcile slots with the current world.
    /// - Parameters:
    ///   - live: window IDs eligible for the dynamic zone (pinned windows
    ///     already excluded by the caller)
    ///   - priority: hottest-first ranking (e.g. MRU); windows absent from
    ///     the list rank coldest
    public mutating func sync(live: Set<UInt32>, priority: [UInt32]) {
        var rank: [UInt32: Int] = [:]
        for (i, w) in priority.enumerated() where rank[w] == nil { rank[w] = i }
        func rankOf(_ w: UInt32) -> Int { rank[w] ?? Int.max }

        // 1. Dead windows free their slots; survivors do not move.
        for i in slots.indices {
            if let w = slots[i], !live.contains(w) { slots[i] = nil }
        }

        // 2. Newcomers: live, not seated — hottest first.
        let seated = Set(slots.compactMap { $0 })
        var newcomers = priority.filter { live.contains($0) && !seated.contains($0) }

        // 2a. Fill empty positions top-down.
        for i in slots.indices where slots[i] == nil {
            guard !newcomers.isEmpty else { break }
            slots[i] = newcomers.removeFirst()
        }

        // 2b. Evict in place: a hotter newcomer replaces the coldest seated window.
        for newcomer in newcomers {
            guard let coldestIndex = slots.indices
                .filter({ slots[$0] != nil })
                .max(by: { rankOf(slots[$0]!) < rankOf(slots[$1]!) })
            else { break }
            guard rankOf(newcomer) < rankOf(slots[coldestIndex]!) else { continue }
            slots[coldestIndex] = newcomer
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WindowPilotCoreTests.SlotAllocatorTests`
Expected: 8/8 PASS. Then `swift test --filter WindowPilotCoreTests` — all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/SlotAllocator.swift Tests/CoreTests/SlotAllocatorTests.swift
git commit -m "Add SlotAllocator with parking-lot semantics for sidebar dynamic zone"
```

---

### Task 3: Core — PinStore (pin persistence + live-window matching)

**Files:**
- Create: `Sources/Core/PinStore.swift`
- Test: `Tests/CoreTests/PinStoreTests.swift`

**Interfaces:**
- Consumes: `AppNode` (`id: Int32`, `name: String`, `bundleIdentifier: String?`, `windows: [WindowInfo]`), `WindowInfo`.
- Produces: `PinnedWindow(bundleIdentifier: String?, appName: String, title: String)` (Codable, Equatable); `PinStore(capacity: Int, fileURL: URL)`, `var pins: [PinnedWindow?]`, `func pin(_:at:)`, `@discardableResult func pinFirstFree(_:) -> Int?`, `func unpin(at:)`, `func resolve(_ pin: PinnedWindow, in apps: [AppNode]) -> WindowInfo?`. Task 7 owns the production fileURL (Application Support).

- [ ] **Step 1: Write the failing tests**

Create `Tests/CoreTests/PinStoreTests.swift`:

```swift
import XCTest
import WindowPilotCore

final class PinStoreTests: XCTestCase {

    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wp-pinstore-tests-\(UUID().uuidString)")
            .appendingPathComponent("pins.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeApps() -> [AppNode] {
        [
            AppNode(id: 100, name: "Ghostty", bundleIdentifier: "com.mitchellh.ghostty", windows: [
                WindowInfo(id: 1, ownerPID: 100, title: "zsh — build", bounds: .zero),
                WindowInfo(id: 2, ownerPID: 100, title: "zsh — logs", bounds: .zero),
            ]),
            AppNode(id: 200, name: "Safari", bundleIdentifier: "com.apple.Safari", windows: [
                WindowInfo(id: 3, ownerPID: 200, title: "PR #42 — GitHub", bounds: .zero),
            ]),
        ]
    }

    func testPinUnpinAndFirstFree() {
        let store = PinStore(capacity: 3, fileURL: tempURL)
        let p = PinnedWindow(bundleIdentifier: "com.apple.Safari", appName: "Safari", title: "PR #42 — GitHub")
        XCTAssertEqual(store.pinFirstFree(p), 0)
        store.pin(PinnedWindow(bundleIdentifier: nil, appName: "Ghostty", title: "zsh — build"), at: 2)
        XCTAssertEqual(store.pins[0], p)
        XCTAssertNil(store.pins[1])
        store.unpin(at: 0)
        XCTAssertNil(store.pins[0])
    }

    func testPersistsAcrossInstances() {
        let p = PinnedWindow(bundleIdentifier: "com.apple.Safari", appName: "Safari", title: "PR #42 — GitHub")
        do {
            let store = PinStore(capacity: 3, fileURL: tempURL)
            store.pin(p, at: 1)
        }
        let reloaded = PinStore(capacity: 3, fileURL: tempURL)
        XCTAssertEqual(reloaded.pins, [nil, p, nil])
    }

    func testResolveExactTitleWins() {
        let store = PinStore(capacity: 3, fileURL: tempURL)
        let pin = PinnedWindow(bundleIdentifier: "com.mitchellh.ghostty", appName: "Ghostty", title: "zsh — logs")
        XCTAssertEqual(store.resolve(pin, in: makeApps())?.id, 2)
    }

    func testResolveFuzzyTitleFallsBack() {
        let store = PinStore(capacity: 3, fileURL: tempURL)
        // Title drifted: pin has old suffix, live window title is a prefix-match.
        let pin = PinnedWindow(bundleIdentifier: "com.apple.Safari", appName: "Safari", title: "PR #42 — GitHub — reviewing")
        XCTAssertEqual(store.resolve(pin, in: makeApps())?.id, 3)
    }

    func testResolveAppOnlyFallback() {
        let store = PinStore(capacity: 3, fileURL: tempURL)
        let pin = PinnedWindow(bundleIdentifier: "com.mitchellh.ghostty", appName: "Ghostty", title: "totally gone")
        XCTAssertEqual(store.resolve(pin, in: makeApps())?.id, 1)
    }

    func testResolveDeadAppReturnsNil() {
        let store = PinStore(capacity: 3, fileURL: tempURL)
        let pin = PinnedWindow(bundleIdentifier: "com.figma.Desktop", appName: "Figma", title: "Mockups")
        XCTAssertNil(store.resolve(pin, in: makeApps()))
    }

    func testBundleIDPreferredOverAppName() {
        let store = PinStore(capacity: 3, fileURL: tempURL)
        // Same appName, different bundleID → must NOT match.
        let pin = PinnedWindow(bundleIdentifier: "com.other.Ghostty", appName: "Ghostty", title: "zsh — build")
        XCTAssertNil(store.resolve(pin, in: makeApps()))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WindowPilotCoreTests.PinStoreTests`
Expected: FAIL to compile — "cannot find 'PinStore' in scope".

- [ ] **Step 3: Implement**

Create `Sources/Core/PinStore.swift`:

```swift
import Foundation

// MARK: - PinnedWindow

/// A pinned sidebar slot, persisted across app restarts. windowIDs don't
/// survive restarts, so pins re-resolve against live windows by
/// (bundleIdentifier/appName, title) heuristics.
public struct PinnedWindow: Codable, Equatable {
    public let bundleIdentifier: String?
    public let appName: String
    public let title: String

    public init(bundleIdentifier: String?, appName: String, title: String) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.title = title
    }
}

// MARK: - PinStore

/// Fixed pinned positions with JSON persistence. Pure logic, no AppKit.
public final class PinStore {

    public let capacity: Int
    public private(set) var pins: [PinnedWindow?]
    private let fileURL: URL

    public init(capacity: Int, fileURL: URL) {
        self.capacity = max(0, capacity)
        self.fileURL = fileURL
        self.pins = Array(repeating: nil, count: self.capacity)
        load()
    }

    public func pin(_ window: PinnedWindow, at index: Int) {
        guard pins.indices.contains(index) else { return }
        pins[index] = window
        save()
    }

    /// Pin into the first empty position. Returns the index, or nil if full.
    @discardableResult
    public func pinFirstFree(_ window: PinnedWindow) -> Int? {
        guard let i = pins.firstIndex(where: { $0 == nil }) else { return nil }
        pins[i] = window
        save()
        return i
    }

    public func unpin(at index: Int) {
        guard pins.indices.contains(index) else { return }
        pins[index] = nil
        save()
    }

    /// Resolve a pin to a live window.
    /// Match order: same app + exact title → same app + prefix/contains
    /// → same app any window → nil (dead).
    /// "Same app": bundleIdentifier equality when both sides have one,
    /// otherwise appName equality.
    public func resolve(_ pin: PinnedWindow, in apps: [AppNode]) -> WindowInfo? {
        let candidates = apps.filter { app in
            if let pinBundle = pin.bundleIdentifier, let appBundle = app.bundleIdentifier {
                return pinBundle == appBundle
            }
            return app.name == pin.appName
        }
        let windows = candidates.flatMap { $0.windows }
        if let exact = windows.first(where: { $0.title == pin.title }) { return exact }
        if let fuzzy = windows.first(where: {
            $0.title.hasPrefix(pin.title) || pin.title.hasPrefix($0.title)
                || (!pin.title.isEmpty && $0.title.contains(pin.title))
        }) { return fuzzy }
        return windows.first
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([PinnedWindow?].self, from: data) else {
            print("[WP] PinStore: corrupt pins file at \(fileURL.path) — ignoring")
            return
        }
        for (i, p) in decoded.prefix(capacity).enumerated() { pins[i] = p }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(pins)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[WP] PinStore: save failed — \(error)")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WindowPilotCoreTests.PinStoreTests`
Expected: 7/7 PASS. Then `swift test --filter WindowPilotCoreTests` — all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/PinStore.swift Tests/CoreTests/PinStoreTests.swift
git commit -m "Add PinStore with persistence and live-window matching"
```

---

### Task 4: UI — extract WindowThumbnailView + WindowCardView, de-duplicate cards

**Files:**
- Create: `Sources/UI/WindowCardView.swift`
- Modify: `Sources/UI/CarouselPanel.swift` (replace `CarouselCardView` with `WindowCardView`)
- Modify: `Sources/UI/RecentView.swift` (`RecentCardView` uses `WindowThumbnailView` for its thumbnail; keeps its own labels/layout)

**Interfaces:**
- Produces (Tasks 5/6 rely on these exact signatures):
  - `WindowThumbnailView`: `init(thumbnail: CGImage?, cornerRadius: CGFloat = 6, maskedCorners: CACornerMask? = nil)`, `func setThumbnail(_ image: CGImage?)` (nil → macwindow placeholder).
  - `WindowCardView`: `init(appName: String, pid: Int32, thumbnail: CGImage?, showsLabelRow: Bool = true)`, `var onClicked: (() -> Void)?`, `var onDoubleClicked: (() -> Void)?`, `func setSelected(_ selected: Bool)`, `func updateThumbnail(_ image: CGImage)`, `func setDimmed(_ dimmed: Bool)`.
- No behavior change to carousel or Recent tab (pure refactor; visuals identical).

- [ ] **Step 1: Create the shared views**

Create `Sources/UI/WindowCardView.swift`:

```swift
import AppKit

// MARK: - WindowThumbnailView

/// Thumbnail image view with the shared placeholder/live-image behavior
/// used by every card in the app (carousel, recent grid, sidebar slots).
public final class WindowThumbnailView: NSImageView {

    public init(thumbnail: CGImage?, cornerRadius: CGFloat = 6, maskedCorners: CACornerMask? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        if let maskedCorners { layer?.maskedCorners = maskedCorners }
        setThumbnail(thumbnail)
    }

    public required init?(coder: NSCoder) { fatalError() }

    public func setThumbnail(_ image: CGImage?) {
        if let image {
            self.image = NSImage(cgImage: image, size: .zero)
            imageScaling = .scaleProportionallyUpOrDown
        } else {
            self.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
            contentTintColor = .tertiaryLabelColor
            imageScaling = .scaleNone
        }
    }
}

// MARK: - WindowCardView

/// Shared card: thumbnail on top, optional app-icon + name row below,
/// accent selection border. Used by CarouselPanel and SidebarPanel.
public final class WindowCardView: NSView {

    public var onClicked: (() -> Void)?
    public var onDoubleClicked: (() -> Void)?

    private let thumbnailView: WindowThumbnailView
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let showsLabelRow: Bool

    public init(appName: String, pid: Int32, thumbnail: CGImage?, showsLabelRow: Bool = true) {
        self.thumbnailView = WindowThumbnailView(thumbnail: thumbnail)
        self.showsLabelRow = showsLabelRow
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.clear.cgColor

        addSubview(thumbnailView)

        iconView.imageScaling = .scaleProportionallyDown
        if pid != 0, let app = NSRunningApplication(processIdentifier: pid) {
            iconView.image = app.icon
        }
        nameLabel.stringValue = appName
        nameLabel.font = .systemFont(ofSize: 10)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        if showsLabelRow {
            addSubview(iconView)
            addSubview(nameLabel)
        }

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
    }

    public required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        let w = bounds.width
        if showsLabelRow {
            let thumbH = bounds.height - 24
            thumbnailView.frame = NSRect(x: 4, y: 4, width: w - 8, height: thumbH - 4)
            iconView.frame = NSRect(x: 6, y: thumbH + 2, width: 14, height: 14)
            nameLabel.frame = NSRect(x: 22, y: thumbH + 1, width: w - 28, height: 16)
        } else {
            thumbnailView.frame = bounds.insetBy(dx: 4, dy: 4)
        }
    }

    public func setSelected(_ selected: Bool) {
        layer?.borderColor = selected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
            : nil
    }

    public func updateThumbnail(_ image: CGImage) {
        thumbnailView.setThumbnail(image)
    }

    public func setDimmed(_ dimmed: Bool) {
        alphaValue = dimmed ? 0.35 : 1.0
    }

    @objc private func handleClick() { onClicked?() }
    @objc private func handleDoubleClick() { onDoubleClicked?() }
}
```

- [ ] **Step 2: Replace CarouselCardView with WindowCardView**

In `Sources/UI/CarouselPanel.swift`:
(a) Change `private var cardViews: [CarouselCardView] = []` → `private var cardViews: [WindowCardView] = []`.
(b) In `rebuildCards()`, replace `let card = CarouselCardView(item: item, index: index)` with:

```swift
            let card = WindowCardView(appName: item.appName, pid: item.pid, thumbnail: item.thumbnail)
```

(`index` was only used by CarouselCardView's unused click plumbing; carousel selection stays keyboard/modifier-driven — do not wire `onClicked`.)
(c) Delete the entire `CarouselCardView` class (bottom of the file, including its `updateThumbnail`). `updateThumbnails(_:)` continues to compile because `WindowCardView.updateThumbnail(_:)` has the same signature.

- [ ] **Step 3: Use WindowThumbnailView inside RecentCardView**

In `Sources/UI/RecentView.swift`, in `RecentCardView`:
(a) Replace `private let thumbnailView = NSImageView()` with `private let thumbnailView: WindowThumbnailView`.
(b) In `init`, BEFORE `super.init(frame: .zero)`, add:

```swift
        self.thumbnailView = WindowThumbnailView(
            thumbnail: thumbnail,
            cornerRadius: 8,
            maskedCorners: [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        )
```

(c) Delete the old thumbnail configuration block in `init` (the lines setting `thumbnailView.imageScaling`, `wantsLayer`, `maskedCorners`, `cornerRadius`, `masksToBounds`, and the `if let thumbnail { ... } else { ... }` placeholder block) — `WindowThumbnailView` now owns all of it. Keep `addSubview(thumbnailView)`.
(d) Replace the body of `func updateThumbnail(_ image: CGImage)` with `thumbnailView.setThumbnail(image)`.

- [ ] **Step 4: Build and test**

Run: `swift build && swift test --filter WindowPilotCoreTests`
Expected: builds with no warnings, tests green. Manual spot-check if GUI available: carousel and Recent tab look and behave exactly as before.

- [ ] **Step 5: Commit**

```bash
git add Sources/UI/WindowCardView.swift Sources/UI/CarouselPanel.swift Sources/UI/RecentView.swift
git commit -m "Extract shared WindowCardView/WindowThumbnailView, de-duplicate cards"
```

---

### Task 5: UI — SidebarPanel (strip, zones, collapse/hot-edge)

**Files:**
- Create: `Sources/UI/SidebarPanel.swift`
- Modify: `Sources/App/AppDelegate.swift` (REMOVE the Task 1 spike block — delete the whole `if ProcessInfo...--sidebar-spike` block)

**Interfaces:**
- Consumes: `WindowCardView` (Task 4), `WindowInfo`, spike decision `SIDEBAR_COLLECTION_BEHAVIOR` (from ledger — substitute the recorded value at the marked line).
- Produces (Task 6 adds interactions; Task 7 wires):
  - `SidebarSlot` struct: see code.
  - `SidebarPanel`: `init()`, `func render(pinned: [SidebarSlot], dynamic: [SidebarSlot], focusedWindowID: UInt32?)`, `func updateThumbnails(_ thumbnails: [UInt32: CGImage])`, `func show(on screen: NSScreen?)`, `func hide()`, `func setCollapsed(_ collapsed: Bool)`, `var isCollapsed: Bool { get }`, `func setHiddenForFullscreen(_ hidden: Bool)`, callbacks `onWindowSelected: ((WindowInfo) -> Void)?`, `onDeadPinActivated: ((Int) -> Void)?`, `onOverflowRequested: (() -> Void)?`, `onCollapseToggled: ((Bool) -> Void)?` (Task 6 adds `onPinRequested`/`onUnpinRequested`/hover preview).

- [ ] **Step 1: Create SidebarPanel**

Create `Sources/UI/SidebarPanel.swift`:

```swift
import AppKit
import WindowPilotCore

// MARK: - SidebarSlot

/// One rendered position in the sidebar.
public struct SidebarSlot {
    public enum Kind { case pinned, dynamic }
    public let kind: Kind
    public let index: Int                // position within its zone
    public let window: WindowInfo?       // nil = empty position or dead pin
    public let appName: String           // "" for empty positions
    public let pid: Int32                // 0 when unknown/dead
    public let thumbnail: CGImage?
    public let isDeadPin: Bool

    public init(kind: Kind, index: Int, window: WindowInfo?, appName: String,
                pid: Int32, thumbnail: CGImage?, isDeadPin: Bool = false) {
        self.kind = kind
        self.index = index
        self.window = window
        self.appName = appName
        self.pid = pid
        self.thumbnail = thumbnail
        self.isDeadPin = isDeadPin
    }
}

// MARK: - SidebarPanel

/// Optional persistent work strip. Non-activating, never key, floats on
/// the right edge of a chosen display. Pinned zone on top (fixed positions),
/// parking-lot dynamic zone below, overflow button at the bottom.
public final class SidebarPanel: NSPanel {

    public static let expandedWidth: CGFloat = 76
    public static let collapsedWidth: CGFloat = 8
    private static let slotHeight: CGFloat = 64
    private static let slotSpacing: CGFloat = 4
    private static let sectionGap: CGFloat = 8
    private static let chromeHeight: CGFloat = 60   // chevron + overflow + paddings

    // MARK: Callbacks

    public var onWindowSelected: ((WindowInfo) -> Void)?
    public var onDeadPinActivated: ((Int) -> Void)?      // pinned index
    public var onOverflowRequested: (() -> Void)?
    public var onCollapseToggled: ((Bool) -> Void)?
    // Task 6 wires these:
    public var onPinRequested: ((WindowInfo) -> Void)?
    public var onUnpinRequested: ((Int) -> Void)?

    // MARK: State

    public private(set) var isCollapsed = false
    private var isPeeking = false                        // hover-expanded while collapsed
    private var pinnedSlots: [SidebarSlot] = []
    private var dynamicSlots: [SidebarSlot] = []
    private var slotViews: [(slot: SidebarSlot, view: WindowCardView)] = []
    private var focusedWindowID: UInt32?
    private var targetScreen: NSScreen?
    private var suppressedForFullscreen = false
    private var userWantsVisible = false

    private let visualEffect = NSVisualEffectView()
    private let stack = NSStackView()
    private let chevronButton = NSButton()
    private let overflowButton = NSButton()

    // MARK: Init

    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.expandedWidth, height: 400),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isReleasedWhenClosed = false
        // SPIKE DECISION: substitute the value recorded by Task 1.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 10
        visualEffect.layer?.cornerCurve = .continuous
        visualEffect.layer?.masksToBounds = true
        contentView = visualEffect

        buildLayout()
        updateTrackingArea()
    }

    /// The strip is furniture, not a window: it must never become key.
    public override var canBecomeKey: Bool { false }

    // MARK: Public API

    public func show(on screen: NSScreen?) {
        targetScreen = screen ?? NSScreen.main
        userWantsVisible = true
        reposition()
        if !suppressedForFullscreen {
            orderFrontRegardless()
        }
    }

    public func hide() {
        userWantsVisible = false
        orderOut(nil)
    }

    public func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        isPeeking = false
        applyCollapseState()
    }

    /// Auto-hide over fullscreen on our display (driven by AppDelegate).
    public func setHiddenForFullscreen(_ hidden: Bool) {
        suppressedForFullscreen = hidden
        if hidden {
            orderOut(nil)
        } else if userWantsVisible {
            orderFrontRegardless()
        }
    }

    public func render(pinned: [SidebarSlot], dynamic: [SidebarSlot], focusedWindowID: UInt32?) {
        pinnedSlots = pinned
        dynamicSlots = dynamic
        self.focusedWindowID = focusedWindowID
        rebuildSlots()
        reposition()
    }

    public func updateThumbnails(_ thumbnails: [UInt32: CGImage]) {
        for (slot, view) in slotViews {
            guard let wid = slot.window?.id, let img = thumbnails[wid] else { continue }
            view.updateThumbnail(img)
        }
    }

    public var currentScreen: NSScreen? { targetScreen }

    // MARK: Layout

    private func buildLayout() {
        stack.orientation = .vertical
        stack.spacing = Self.slotSpacing
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(stack)

        chevronButton.bezelStyle = .inline
        chevronButton.isBordered = false
        chevronButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Collapse")
        chevronButton.target = self
        chevronButton.action = #selector(chevronTapped)

        overflowButton.bezelStyle = .inline
        overflowButton.isBordered = false
        overflowButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "All Windows")
        overflowButton.target = self
        overflowButton.action = #selector(overflowTapped)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -4),
        ])
    }

    private func rebuildSlots() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        slotViews.removeAll()
        guard !collapsedNow else { return }

        stack.addArrangedSubview(chevronButton)

        for slot in pinnedSlots {
            stack.addArrangedSubview(makeSlotView(slot))
        }
        if !pinnedSlots.isEmpty && !dynamicSlots.isEmpty {
            stack.addArrangedSubview(makeSeparator())
        }
        for slot in dynamicSlots {
            stack.addArrangedSubview(makeSlotView(slot))
        }
        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(overflowButton)
    }

    private func makeSlotView(_ slot: SidebarSlot) -> NSView {
        // Empty position: subtle dashed placeholder that HOLDS the position
        // (spatial stability means empty positions still occupy space).
        guard slot.window != nil || slot.isDeadPin else {
            let empty = NSView()
            empty.wantsLayer = true
            empty.layer?.cornerRadius = 8
            empty.layer?.borderWidth = 1
            empty.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
            empty.widthAnchor.constraint(equalToConstant: Self.expandedWidth - 8).isActive = true
            empty.heightAnchor.constraint(equalToConstant: Self.slotHeight).isActive = true
            return empty
        }

        let card = WindowCardView(appName: slot.appName, pid: slot.pid, thumbnail: slot.thumbnail)
        card.widthAnchor.constraint(equalToConstant: Self.expandedWidth - 8).isActive = true
        card.heightAnchor.constraint(equalToConstant: Self.slotHeight).isActive = true
        if let window = slot.window {
            card.setSelected(window.id == focusedWindowID)
            card.onClicked = { [weak self] in self?.onWindowSelected?(window) }
        } else {
            card.setDimmed(true)
            let pinIndex = slot.index
            card.onClicked = { [weak self] in self?.onDeadPinActivated?(pinIndex) }
        }
        slotViews.append((slot, card))
        return card
    }

    private func makeSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: Self.expandedWidth - 20).isActive = true
        return box
    }

    // MARK: Collapse / hot edge

    private var collapsedNow: Bool { isCollapsed && !isPeeking }

    private func applyCollapseState() {
        chevronButton.image = NSImage(
            systemSymbolName: isCollapsed ? "chevron.left" : "chevron.right",
            accessibilityDescription: isCollapsed ? "Expand" : "Collapse"
        )
        rebuildSlots()
        reposition()
        updateTrackingArea()
    }

    private func reposition() {
        guard let screen = targetScreen ?? NSScreen.main else { return }
        let width = collapsedNow ? Self.collapsedWidth : Self.expandedWidth
        let slotCount = CGFloat(pinnedSlots.count + dynamicSlots.count)
        let height = collapsedNow
            ? 200
            : slotCount * (Self.slotHeight + Self.slotSpacing) + Self.chromeHeight
        let f = screen.visibleFrame
        setFrame(
            NSRect(x: f.maxX - width, y: f.midY - height / 2, width: width, height: height),
            display: true
        )
    }

    private var trackingArea: NSTrackingArea?

    private func updateTrackingArea() {
        if let ta = trackingArea { visualEffect.removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: visualEffect.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        visualEffect.addTrackingArea(ta)
        trackingArea = ta
    }

    public override func mouseEntered(with event: NSEvent) {
        guard isCollapsed, !isPeeking else { return }
        isPeeking = true
        rebuildSlots()
        reposition()
    }

    public override func mouseExited(with event: NSEvent) {
        guard isCollapsed, isPeeking else { return }
        isPeeking = false
        rebuildSlots()
        reposition()
    }

    // MARK: Actions

    @objc private func chevronTapped() {
        setCollapsed(!isCollapsed)
        onCollapseToggled?(isCollapsed)
    }

    @objc private func overflowTapped() {
        onOverflowRequested?()
    }
}
```

If the Task 1 spike recorded `moveToActiveSpace`, use `collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]` at the marked line (Task 7 then adds the reattach observer).

- [ ] **Step 2: Remove the Task 1 spike block from AppDelegate**

Delete the entire `if ProcessInfo.processInfo.arguments.contains("--sidebar-spike") { ... }` block added in Task 1.

- [ ] **Step 3: Build and test**

Run: `swift build && swift test --filter WindowPilotCoreTests`
Expected: builds with no warnings (SidebarPanel is not yet instantiated anywhere — that's Task 7), tests green.

- [ ] **Step 4: Commit**

```bash
git add Sources/UI/SidebarPanel.swift Sources/App/AppDelegate.swift
git commit -m "Add SidebarPanel strip with zones and collapse/hot-edge; remove spike"
```

---

### Task 6: UI — SidebarPanel interactions (context menu, drag-to-pin, hover preview)

**Files:**
- Modify: `Sources/UI/SidebarPanel.swift`
- Modify: `Sources/UI/WindowCardView.swift` (hover forwarding + drag support, Steps 3-4)

**Interfaces:**
- Consumes: Task 5's `SidebarPanel` internals.
- Produces: right-click context menu (Pin/Unpin, Close, Minimize), drag from dynamic zone to pinned zone pins, hover shows an enlarged floating preview. New callbacks used by Task 7: `onWindowClosed: ((WindowInfo) -> Void)?`, `onWindowMinimized: ((WindowInfo) -> Void)?` (in addition to `onPinRequested`/`onUnpinRequested` declared in Task 5).

- [ ] **Step 1: Add the two new callbacks**

In the `// MARK: Callbacks` section of `SidebarPanel`, after `onUnpinRequested`, add:

```swift
    public var onWindowClosed: ((WindowInfo) -> Void)?
    public var onWindowMinimized: ((WindowInfo) -> Void)?
```

- [ ] **Step 2: Context menu on slots**

In `makeSlotView(_:)`, after `slotViews.append((slot, card))`, add:

```swift
        card.menu = makeContextMenu(for: slot)
```

And add to the class:

```swift
    // MARK: Context menu

    private func makeContextMenu(for slot: SidebarSlot) -> NSMenu {
        let menu = NSMenu()
        if slot.kind == .dynamic, let window = slot.window {
            let pinItem = NSMenuItem(title: "Pin", action: #selector(menuPin(_:)), keyEquivalent: "")
            pinItem.target = self
            pinItem.representedObject = window
            menu.addItem(pinItem)
        }
        if slot.kind == .pinned {
            let unpinItem = NSMenuItem(title: "Unpin", action: #selector(menuUnpin(_:)), keyEquivalent: "")
            unpinItem.target = self
            unpinItem.representedObject = slot.index
            menu.addItem(unpinItem)
        }
        if let window = slot.window {
            menu.addItem(.separator())
            let closeItem = NSMenuItem(title: "Close Window", action: #selector(menuClose(_:)), keyEquivalent: "")
            closeItem.target = self
            closeItem.representedObject = window
            menu.addItem(closeItem)
            let minItem = NSMenuItem(title: "Minimize", action: #selector(menuMinimize(_:)), keyEquivalent: "")
            minItem.target = self
            minItem.representedObject = window
            menu.addItem(minItem)
        }
        return menu
    }

    @objc private func menuPin(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? WindowInfo else { return }
        onPinRequested?(window)
    }

    @objc private func menuUnpin(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        onUnpinRequested?(index)
    }

    @objc private func menuClose(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? WindowInfo else { return }
        onWindowClosed?(window)
    }

    @objc private func menuMinimize(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? WindowInfo else { return }
        onWindowMinimized?(window)
    }
```

- [ ] **Step 3: Hover preview**

Add to the class:

```swift
    // MARK: Hover preview

    private var previewPanel: NSPanel?

    private func showHoverPreview(for window: WindowInfo, near view: NSView) {
        hideHoverPreview()
        guard let thumbnail = slotViews.first(where: { $0.slot.window?.id == window.id })?.slot.thumbnail
        else { return }

        let maxSize = NSSize(width: 360, height: 240)
        let aspect = CGFloat(thumbnail.width) / max(CGFloat(thumbnail.height), 1)
        let size = aspect > maxSize.width / maxSize.height
            ? NSSize(width: maxSize.width, height: maxSize.width / aspect)
            : NSSize(width: maxSize.height * aspect, height: maxSize.height)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true

        let imageView = WindowThumbnailView(thumbnail: thumbnail, cornerRadius: 8)
        imageView.frame = NSRect(origin: .zero, size: size)
        panel.contentView = imageView

        // Place to the left of the strip, vertically centered on the slot.
        let slotFrameInWindow = view.convert(view.bounds, to: nil)
        let slotFrameOnScreen = convertToScreen(slotFrameInWindow)
        panel.setFrameOrigin(NSPoint(
            x: frame.minX - size.width - 8,
            y: slotFrameOnScreen.midY - size.height / 2
        ))
        panel.orderFrontRegardless()
        previewPanel = panel
    }

    private func hideHoverPreview() {
        previewPanel?.orderOut(nil)
        previewPanel = nil
    }
```

Wire it: in `makeSlotView(_:)`, for card slots with a live window, add after `card.menu = ...`:

```swift
        if let window = slot.window {
            let hoverArea = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: card, userInfo: nil
            )
            card.addTrackingArea(hoverArea)
            card.onMouseEntered = { [weak self, weak card] in
                guard let self, let card else { return }
                self.showHoverPreview(for: window, near: card)
            }
            card.onMouseExited = { [weak self] in self?.hideHoverPreview() }
        }
```

And in `Sources/UI/WindowCardView.swift`, add hover forwarding to `WindowCardView`:

```swift
    public var onMouseEntered: (() -> Void)?
    public var onMouseExited: (() -> Void)?

    public override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    public override func mouseExited(with event: NSEvent) { onMouseExited?() }
```

Also call `hideHoverPreview()` at the top of `rebuildSlots()` and inside `hide()` and `setHiddenForFullscreen(true)` paths (one line each) so no orphan preview outlives its slot.

- [ ] **Step 4: Drag-to-pin (dynamic → pinned zone)**

Add to `WindowCardView`:

```swift
    public var onDragEnded: ((NSPoint) -> Void)?   // screen point where drag ended
    private var dragOrigin: NSPoint?

    public override func mouseDragged(with event: NSEvent) {
        dragOrigin = dragOrigin ?? event.locationInWindow
    }

    public override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        if let origin = dragOrigin,
           hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) > 20,
           let window = self.window {
            let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
            onDragEnded?(screenPoint)
            return
        }
        super.mouseUp(with: event)
    }
```

In `SidebarPanel.makeSlotView(_:)`, for dynamic slots with a live window, add:

```swift
        if slot.kind == .dynamic, let window = slot.window {
            card.onDragEnded = { [weak self] screenPoint in
                guard let self else { return }
                // Dropped inside the pinned zone's vertical range?
                let pinnedBottom = self.pinnedZoneBottomOnScreen()
                if screenPoint.y > pinnedBottom {
                    self.onPinRequested?(window)
                }
            }
        }
```

And add the helper:

```swift
    /// Screen-Y of the bottom of the pinned zone (top `pinnedSlots.count`
    /// slots + chevron). Drops above this line count as "into the pinned zone".
    private func pinnedZoneBottomOnScreen() -> CGFloat {
        let pinnedHeight = CGFloat(pinnedSlots.count) * (Self.slotHeight + Self.slotSpacing) + 30
        return frame.maxY - pinnedHeight
    }
```

- [ ] **Step 5: Build and test**

Run: `swift build && swift test --filter WindowPilotCoreTests`
Expected: builds with no warnings, tests green.

- [ ] **Step 6: Commit**

```bash
git add Sources/UI/SidebarPanel.swift Sources/UI/WindowCardView.swift
git commit -m "Add sidebar interactions: context menu, hover preview, drag-to-pin"
```

---

### Task 7: App wiring — mode toggle, sync loop, fullscreen hide

**Files:**
- Modify: `Sources/App/AppDelegate.swift`

**Interfaces:**
- Consumes: everything above. UserDefaults keys: `"SidebarEnabled"` (Bool), `"SidebarCollapsed"` (Bool).
- Produces: working optional sidebar mode.

- [ ] **Step 1: Properties**

Add to AppDelegate's properties (near `private var updateManager: UpdateManager!`):

```swift
    private var sidebar: SidebarPanel?
    private var sidebarMenuItem: NSMenuItem!
    private var slotAllocator = SlotAllocator(capacity: 5)
    private lazy var pinStore: PinStore = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowPilot")
        return PinStore(capacity: 3, fileURL: dir.appendingPathComponent("pins.json"))
    }()
    private var previousFocusedWindowID: UInt32 = 0
```

- [ ] **Step 2: Launch + menu**

In `applicationDidFinishLaunching`, after `setupStatusItem()`:

```swift
        if UserDefaults.standard.bool(forKey: "SidebarEnabled") {
            enableSidebar()
        }
```

In `setupStatusItem()`, before the `"Change Shortcuts…"` line:

```swift
        sidebarMenuItem = menu.addItem(
            withTitle: "Show Sidebar",
            action: #selector(toggleSidebar), keyEquivalent: ""
        )
        sidebarMenuItem.state = UserDefaults.standard.bool(forKey: "SidebarEnabled") ? .on : .off
        menu.addItem(.separator())
```

Add the action methods (next to `showPreferences`):

```swift
    @objc private func toggleSidebar() {
        let enabled = sidebar == nil
        UserDefaults.standard.set(enabled, forKey: "SidebarEnabled")
        sidebarMenuItem.state = enabled ? .on : .off
        if enabled { enableSidebar() } else { disableSidebar() }
    }

    private func enableSidebar() {
        guard sidebar == nil else { return }
        let panel = SidebarPanel()
        sidebar = panel

        panel.onWindowSelected = { [weak self] windowInfo in
            self?.performFocus(windowInfo)
        }
        panel.onDeadPinActivated = { [weak self] pinIndex in
            guard let self, let pin = self.pinStore.pins[safe: pinIndex] ?? nil,
                  let bundleID = pin.bundleIdentifier,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else {
                ToastHUD.show("Couldn't locate that app")
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
        panel.onPinRequested = { [weak self] windowInfo in
            guard let self else { return }
            let appName = NSRunningApplication(processIdentifier: windowInfo.ownerPID)?.localizedName ?? ""
            let bundleID = NSRunningApplication(processIdentifier: windowInfo.ownerPID)?.bundleIdentifier
            if self.pinStore.pinFirstFree(
                PinnedWindow(bundleIdentifier: bundleID, appName: appName, title: windowInfo.title)
            ) == nil {
                ToastHUD.show("Pinned slots are full — unpin one first")
            }
            self.syncSidebar()
        }
        panel.onUnpinRequested = { [weak self] index in
            self?.pinStore.unpin(at: index)
            self?.syncSidebar()
        }
        panel.onWindowClosed = { [weak self] windowInfo in
            guard let self else { return }
            if !self.focuser.close(pid: windowInfo.ownerPID, windowTitle: windowInfo.title) {
                ToastHUD.show("Couldn't close \"\(windowInfo.title)\"")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.syncSidebar() }
        }
        panel.onWindowMinimized = { [weak self] windowInfo in
            guard let self else { return }
            if !self.focuser.minimize(pid: windowInfo.ownerPID, windowTitle: windowInfo.title) {
                ToastHUD.show("Couldn't minimize \"\(windowInfo.title)\"")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.syncSidebar() }
        }
        panel.onOverflowRequested = { [weak self] in
            self?.showPanel()
        }
        panel.onCollapseToggled = { collapsed in
            UserDefaults.standard.set(collapsed, forKey: "SidebarCollapsed")
        }

        panel.setCollapsed(UserDefaults.standard.bool(forKey: "SidebarCollapsed"))
        syncSidebar()
        panel.show(on: NSScreen.main)
    }

    private func disableSidebar() {
        sidebar?.hide()
        sidebar = nil
    }
```

Also add this small helper at file scope (bottom of AppDelegate.swift):

```swift
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

- [ ] **Step 3: The sync loop**

Add to AppDelegate:

```swift
    // MARK: - Sidebar sync

    /// Rebuild sidebar slots from the current world. Called on focus changes
    /// (max every 2s via the tracker) and after pin/close/minimize actions.
    private func syncSidebar() {
        guard let sidebar else { return }
        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let apps = enumerator.enumerate(excludingPID: ownPID)

        // Pinned zone: resolve stored pins against live windows.
        var pinnedSlots: [SidebarSlot] = []
        var pinnedIDs = Set<UInt32>()
        for (i, pin) in pinStore.pins.enumerated() {
            guard let pin else {
                pinnedSlots.append(SidebarSlot(
                    kind: .pinned, index: i, window: nil, appName: "", pid: 0, thumbnail: nil
                ))
                continue
            }
            if let window = pinStore.resolve(pin, in: apps) {
                pinnedIDs.insert(window.id)
                pinnedSlots.append(SidebarSlot(
                    kind: .pinned, index: i, window: window, appName: pin.appName,
                    pid: window.ownerPID, thumbnail: screenshotCache.image(forWindowID: window.id)
                ))
            } else {
                pinnedSlots.append(SidebarSlot(
                    kind: .pinned, index: i, window: nil, appName: pin.appName,
                    pid: 0, thumbnail: nil, isDeadPin: true
                ))
            }
        }

        // Dynamic zone: parking-lot over everything not pinned.
        var infoByID: [UInt32: (WindowInfo, String)] = [:]
        for app in apps {
            for w in app.windows { infoByID[w.id] = (w, app.name) }
        }
        let live = Set(infoByID.keys).subtracting(pinnedIDs)
        let priority = tracker.combinedRanking(limit: 30).map(\.id).filter { !pinnedIDs.contains($0) }
        slotAllocator.sync(live: live, priority: priority)

        let dynamicSlots: [SidebarSlot] = slotAllocator.slots.enumerated().map { i, wid in
            guard let wid, let (window, appName) = infoByID[wid] else {
                return SidebarSlot(kind: .dynamic, index: i, window: nil, appName: "", pid: 0, thumbnail: nil)
            }
            return SidebarSlot(
                kind: .dynamic, index: i, window: window, appName: appName,
                pid: window.ownerPID, thumbnail: screenshotCache.image(forWindowID: window.id)
            )
        }

        sidebar.render(pinned: pinnedSlots, dynamic: dynamicSlots, focusedWindowID: lastTrackedWindowID)
    }
```

- [ ] **Step 4: Hook into the focus tracker**

In `trackFocusedWindow()`, the existing guard reads:

```swift
        guard windowID != lastTrackedWindowID else { return }
        lastTrackedWindowID = windowID
```

Replace with:

```swift
        guard windowID != lastTrackedWindowID else { return }
        previousFocusedWindowID = lastTrackedWindowID
        lastTrackedWindowID = windowID
```

Then at the END of `trackFocusedWindow()` (after the `tracker.windowDidFocus(...)` call), add:

```swift
        // Sidebar: re-sync slots, refresh the thumbnail of the window that
        // just lost focus (its content is "final" now), and auto-hide over
        // fullscreen on the strip's display.
        if let sidebar {
            syncSidebar()

            if hasScreenRecording, previousFocusedWindowID != 0 {
                let lostID = previousFocusedWindowID
                screenshotCache.refreshAsync(
                    windowIDs: [lostID],
                    capture: { [weak self] wid in self?.capture.capture(windowID: wid) }
                ) { [weak self] refreshed in
                    self?.sidebar?.updateThumbnails(refreshed)
                    self?.panel.updateRecentThumbnails(refreshed)
                }
            }

            let stripScreenFrame = (sidebar.currentScreen ?? NSScreen.main)?.frame ?? .zero
            let hideForFullscreen = isFullScreen && focusedWindowBounds.intersects(stripScreenFrame)
            sidebar.setHiddenForFullscreen(hideForFullscreen)
        }
```

For `focusedWindowBounds`: in the existing "3. Small windows → transient" block of `trackFocusedWindow()`, the CGWindowList lookup already reads the focused window's bounds. Hoist them: declare `var focusedWindowBounds: CGRect = .zero` right before that block, and inside the loop where `w`/`h` are read, add:

```swift
                focusedWindowBounds = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: w, height: h)
```

NOTE: the small-window block currently only runs when `!isTransient` — move the `var focusedWindowBounds` declaration ABOVE that block so it's always in scope; when the block didn't run, `.zero` simply never intersects and the strip stays visible (acceptable).

- [ ] **Step 5: Display-change + Space-reattach observers**

In `applicationDidFinishLaunching`, after the sidebar-enable block:

```swift
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let sidebar = self.sidebar else { return }
            sidebar.show(on: NSScreen.main)
        }
```

ONLY if Task 1 recorded the `moveToActiveSpace` fallback, also add:

```swift
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.sidebar?.orderFrontRegardless()
        }
```

- [ ] **Step 6: Build and test**

Run: `swift build && swift test --filter WindowPilotCoreTests`
Expected: builds with no warnings, tests green.

- [ ] **Step 7: Commit**

```bash
git add Sources/App/AppDelegate.swift
git commit -m "Wire optional sidebar mode: menu toggle, sync loop, fullscreen hide"
```

---

### Task 8: Verification (build, tests, human GUI checklist)

**Files:** none.

- [ ] **Step 1: Full build + test sweep**

Run: `swift build && swift test --filter WindowPilotCoreTests`
Expected: clean build, all core tests green (34 existing + 15 new = 49).

- [ ] **Step 2: Launch and hand the checklist to the user**

Run: `.build/debug/WindowPilot`
Human checklist (user):
1. Status menu → "Show Sidebar": strip appears at right edge of main display; menu item shows ✓.
2. Click a dynamic slot: window focuses; the strip does NOT steal focus (type immediately — input goes to the focused window).
3. Switch windows a few times: slots do NOT reshuffle; the focused slot's border follows.
4. Right-click a dynamic slot → Pin: card moves to the pinned zone; restart the app (with sidebar enabled) → pin survives.
5. Drag a dynamic card up into the pinned zone: pins.
6. Right-click a pinned slot → Unpin.
7. Quit the pinned window's app: slot dims to app icon; click relaunches/activates the app.
8. Chevron: strip collapses to 8px sliver; mouse to the edge: peeks open; move away: collapses; state survives restart.
9. Fullscreen an app on the strip's display: strip hides; exit fullscreen: strip returns.
10. Switch Spaces: strip visible everywhere (or reattaches, per spike decision); Space-switch focus via the main panel still animates correctly.
11. Hover a slot: enlarged preview appears to the left; leaves no orphan preview after clicking.
12. Menu → "Show Sidebar" again: strip disappears, state persists off across restart.

- [ ] **Step 3: Fix-forward anything the checklist catches, then final commit if needed**

Any failed item: fix, re-run the affected checklist item, commit with a descriptive message.
