# Intent: windowpilot-app

## Scope
Everything outside Core/: `Sources/App/`, `Sources/UI/`, `Tests/IntegrationTests/`, plus wiring Core/ into the running application. After this intent, WindowPilot is a fully functional macOS app.

## Depends On
Intent `windowpilot-core` must be complete. All Core/ modules and their tests are already implemented and passing.

## Modules to Implement

### Sources/App/

**AppDelegate.swift**
- NSApplication delegate, no main storyboard (code-only lifecycle)
- Creates NSStatusItem (menu bar icon) with menu: "Show WindowPilot (⌥Space)", "Preferences…", "Quit"
- Holds references to HotkeyManager and PilotPanel
- On launch: check permissions, register hotkey, pre-create panel (hidden)

**HotkeyManager.swift**
- Uses `HotKey` package (soffes/HotKey)
- Default: Option+Space
- Toggle behavior: press → show panel, press again → hide panel
- Must work regardless of focused app (including full-screen)
- Store hotkey reference to prevent deallocation

**Permissions.swift**
- `checkAccessibility()`: `AXIsProcessTrusted()` — if false, show alert with "Open System Settings" button
- `checkScreenRecording()`: `CGPreflightScreenCaptureAccess()` — if false, tree still works, preview shows placeholder
- Check on launch and before first enumeration
- Do NOT block app launch if screen recording is denied — only accessibility is hard requirement

### Sources/UI/

**PilotPanel.swift**
- Subclass `NSPanel`
- Style: `.nonactivatingPanel | .titled | .fullSizeContentView | .closable | .resizable`
- Level: `.floating`
- Background: `NSVisualEffectView` with `.hudWindow` material (vibrancy)
- Default size: 880 × 560, centered on active screen
- `show()`: call `WindowEnumerator.enumerate()`, populate tree, `makeKeyAndOrderFront`
- `dismiss()`: `orderOut(nil)`, release screenshot, do NOT destroy panel
- On show: focus search bar, select first window in tree

**TreeView.swift**
- `NSOutlineView` with two levels: AppNode (group row) → WindowInfo (leaf row)
- Group row: app icon (NSRunningApplication.icon) + app name + window count badge
- Leaf row: colored dot + window title (truncated with ellipsis)
- Click/arrow-key selection triggers preview capture
- Enter key or double-click: focus selected window + dismiss panel
- Expand/collapse state preserved between show/hide cycles
- Delegate/DataSource pattern (not bindings)

**PreviewView.swift**
- Displays captured CGImage of selected window
- On new selection: immediately show blurred version (gaussian blur via CIFilter or Core Animation), then animate to clear over ~300ms
- If no window selected: show placeholder (app icon + "Select a window to preview")
- If screen recording denied: show placeholder with "Grant Screen Recording permission for previews"
- Aspect-fit scaling, centered in available space

**SearchBar.swift**
- NSTextField at top of panel, always visible
- Placeholder: "Filter windows… ⌘K"
- On text change (debounced 30ms): call `SearchFilter.filter()`, update tree
- ⌘K from anywhere in panel: focus search bar
- Escape in search bar: clear text if non-empty, dismiss panel if empty
- Tab: move focus from search bar to tree view

### Layout
```
┌─────────────────────────────────────────────────┐
│ [Search bar ·····························] [×]  │
├──────────────────┬──────────────────────────────┤
│                  │                              │
│   Tree View      │      Preview View            │
│   (280px wide)   │      (flex)                  │
│                  │                              │
│                  │                              │
│                  ├──────────────────────────────┤
│                  │  [Focus ⏎] [Close] [Min]     │
└──────────────────┴──────────────────────────────┘
```

Split via `NSSplitView` (non-resizable divider, or fixed left panel width).

---

## Invariants

### I4: Focus Correctness
Selecting a window and pressing Enter MUST bring that exact window to front and make it key.

**Verification** (Integration test):
```swift
func test_focus_correctness() async throws {
    // Open 3 TextEdit windows with distinct titles
    let titles = await TestWindowHarness.openTextEditWindows(count: 3)
    defer { TestWindowHarness.cleanupTextEdit() }
    
    // Enumerate and find second window
    let enumerator = WindowEnumerator()
    let apps = enumerator.enumerate(excludingPID: ProcessInfo.processInfo.processIdentifier)
    let textEdit = apps.first { $0.name == "TextEdit" }!
    let target = textEdit.windows[1]
    
    // Focus it
    let focuser = WindowFocuser()
    let success = focuser.focus(pid: textEdit.id, windowTitle: target.title)
    XCTAssertTrue(success)
    
    // Verify frontmost app is TextEdit
    try await Task.sleep(nanoseconds: 500_000_000)
    let frontApp = NSWorkspace.shared.frontmostApplication
    XCTAssertEqual(frontApp?.localizedName, "TextEdit")
}
```

### I5: Panel Self-Exclusion
WindowPilot's own panel MUST NOT appear in the tree. Verified by checking that own PID is excluded.

**Verification**:
```swift
func test_panel_excludes_self() {
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let enumerator = WindowEnumerator()
    let apps = enumerator.enumerate(excludingPID: ownPID)
    let ownApp = apps.first { $0.id == ownPID }
    XCTAssertNil(ownApp, "WindowPilot should not appear in its own tree")
}
```

### I6: Hotkey Toggle
Global hotkey MUST show panel when hidden, hide panel when shown. Must work from any app.

**Verification** (manual — see checklist):
Summon from Terminal full-screen, dismiss, summon from Chrome, dismiss.

### I7: Permission Gating
Without Accessibility permission: app shows prompt, does not crash.
Without Screen Recording: tree works, preview shows placeholder.

**Verification**:
```swift
func test_capture_without_permission() {
    // CGPreflightScreenCaptureAccess() may return false in CI
    let capture = WindowCapture()
    if !capture.hasPermission() {
        let image = capture.capture(windowID: 12345)
        XCTAssertNil(image, "Should return nil without permission, not crash")
    }
}
```

---

## Quality Dimensions (minimum score: 3/5)

### Q1: Enumeration Speed
Hotkey press → full tree rendered. Target: < 200ms for 30 windows.
Measure:
```swift
let start = CFAbsoluteTimeGetCurrent()
let apps = enumerator.enumerate(excludingPID: ownPID)
// ... populate tree ...
let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
print("PERF: enumerate+render = \(ms)ms")
// HARD FAIL if > 500ms
```

### Q2: Screenshot Latency
Tree item click → preview fully clear. Target: < 500ms.

### Q3: Search Responsiveness
Keystroke → filtered tree. Target: < 50ms for 50 windows.

### Q4: Visual Polish
- Dark/light mode via NSAppearance (auto-switch)
- Vibrancy background (NSVisualEffectView)
- Smooth blur→clear preview transition
- Proper text truncation (no overflow)

### Q5: Memory Footprint
Panel hidden: < 20MB RSS. Panel shown with 30 windows: < 80MB.
Screenshots released on dismiss.

---

## Integration Test Harness

```swift
// Tests/IntegrationTests/TestWindowHarness.swift

import AppKit

enum TestWindowHarness {

    /// Open N TextEdit windows. Returns expected titles.
    static func openTextEditWindows(count: Int) async -> [String] {
        var titles: [String] = []
        for i in 1...count {
            let marker = "WPTest_\(UUID().uuidString.prefix(6))_\(i)"
            let script = """
            tell application "TextEdit"
                activate
                make new document with properties {text:"\(marker)"}
            end tell
            """
            NSAppleScript(source: script)?.executeAndReturnError(nil)
            titles.append(marker)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return titles
    }
    
    /// Cleanup: close all TextEdit docs without saving, quit
    static func cleanupTextEdit() {
        let script = """
        tell application "TextEdit"
            close every document saving no
            quit
        end tell
        """
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
    
    /// Open Calculator (single-window app)
    static func openCalculator() {
        NSWorkspace.shared.launchApplication("Calculator")
    }
    
    static func closeCalculator() {
        let script = """
        tell application "Calculator" to quit
        """
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}
```

### Integration Test Cases

```
test_enumeration_finds_real_windows
    1. openTextEditWindows(3)
    2. enumerate()
    3. Assert TextEdit node exists with >= 3 windows
    4. Assert our marker strings appear in window titles
    5. cleanup

test_focus_switches_correctly
    1. openTextEditWindows(2)
    2. Focus window[1] via WindowFocuser
    3. Verify NSWorkspace.frontmostApplication is TextEdit
    4. cleanup

test_capture_returns_image
    1. Skip if !CGPreflightScreenCaptureAccess()
    2. openCalculator()
    3. enumerate(), find Calculator's windowID
    4. capture(windowID) → assert non-nil CGImage with width > 0
    5. cleanup

test_full_flow
    1. Open TextEdit(2) + Calculator
    2. enumerate() → assert >= 2 app nodes
    3. capture Calculator window → assert image
    4. focus TextEdit window[0] → assert frontmost is TextEdit
    5. cleanup all
```

---

## Human Review Checklist (/ratchet:review)

### Visual
```
[ ] Panel has vibrancy/blur background (not opaque)
[ ] Tree hover states visible (subtle highlight)
[ ] Tree selection state clear (accent color left border + highlight)
[ ] Preview blur→clear transition smooth (~300ms, no pop)
[ ] App icons resolve correctly (not generic placeholder)
[ ] Window count badges visible per app
[ ] Dark mode: all text readable, good contrast
[ ] Light mode: all text readable, no washed-out elements
[ ] Panel corners rounded (macOS native radius)
[ ] Panel shadow appropriate
```

### Interaction
```
[ ] ⌥Space summons panel from any app
[ ] ⌥Space again dismisses panel
[ ] ⌥Space works from full-screen app
[ ] Clicking tree item shows preview
[ ] Enter/double-click focuses correct window AND dismisses panel
[ ] Esc dismisses panel (no focus switch)
[ ] Typing in search bar filters tree in real-time
[ ] Clearing search restores full tree
[ ] Arrow keys navigate tree (up/down between items, left/right collapse/expand)
[ ] Tab moves focus: search bar → tree
[ ] ⌘K focuses search bar from anywhere
[ ] Action bar buttons work: Focus, Close, Minimize
```

### Edge Cases
```
[ ] App with no titled windows: shows "Untitled" or app name
[ ] App with 10+ windows: tree scrolls, no layout break
[ ] Very long window title: truncated with "…"
[ ] App quits while panel open: no crash (stale data OK, refreshes next open)
[ ] Screen Recording denied: tree works, preview shows placeholder message
[ ] Accessibility denied: setup prompt shown, no crash
[ ] Rapid hotkey spam (5x in 1 second): no crash, no duplicate panels
[ ] 30+ windows open: panel still responsive
```

### Performance (measure and report)
```
[ ] Hotkey → tree rendered:    ___ms  (target < 200ms, fail > 500ms)
[ ] Click → preview clear:    ___ms  (target < 500ms, fail > 1000ms)
[ ] Search keystroke → filter: ___ms  (target < 50ms,  fail > 200ms)
[ ] Idle RSS (panel hidden):  ___MB  (target < 20MB,  fail > 50MB)
[ ] Active RSS (panel shown): ___MB  (target < 80MB,  fail > 150MB)
```

---

## Completion Criteria

1. `swift build` — compiles without errors
2. `swift test` — all Core tests + Integration tests pass (screen-recording tests skip gracefully if no permission)
3. App launches, hotkey summons panel, tree populates with real windows
4. Click a window → preview appears → Enter → that window is focused
5. Human review checklist: zero failures in "Interaction" section, no more than 2 minor issues in "Visual" section
