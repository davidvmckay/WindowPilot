# WindowPilot — CLAUDE.md

## What Is This
WindowPilot is a macOS-native hotkey-summoned window navigator. Left panel: two-level tree (App → Windows). Right panel: lazy-loaded screenshot preview. Click or Enter to focus. The core value is recognition-based browsing (see-and-pick) vs recall-based searching (think-then-type).

## Build & Run

```bash
swift build                          # debug build
swift build -c release               # release build
swift test                           # all tests
swift test --filter WindowPilotCoreTests   # core only
.build/debug/WindowPilot             # run
```

## Tech Stack
- Swift 5.9+, macOS 13.0+ (Ventura)
- AppKit for UI (NSPanel, NSOutlineView)
- Core Graphics for window enumeration & screenshots
- Accessibility API (AXUIElement) for focus/raise
- HotKey package (soffes/HotKey) for global hotkey
- Swift Package Manager

## Architecture

```
Sources/
├── App/                    # Entry point, lifecycle
│   ├── AppDelegate.swift
│   ├── HotkeyManager.swift
│   └── Permissions.swift
├── Core/                   # Pure logic, NO AppKit imports
│   ├── WindowEnumerator.swift
│   ├── WindowNode.swift
│   ├── WindowFocuser.swift
│   ├── WindowCapture.swift
│   └── SearchFilter.swift
└── UI/                     # AppKit views
    ├── PilotPanel.swift
    ├── TreeView.swift
    ├── PreviewView.swift
    └── SearchBar.swift
Tests/
├── CoreTests/              # Tier 1: pure logic, mock data
└── IntegrationTests/       # Tier 2: real macOS desktop
```

## Architecture Rules

1. **Core/ has zero UI imports.** WindowEnumerator, WindowNode, SearchFilter must not import AppKit. They operate on plain Swift types. This enables fast unit testing.

2. **UI/ depends on Core/, not vice versa.** One-way dependency graph.

3. **All CG calls are wrapped.** No raw `CGWindowListCopyWindowInfo` outside WindowEnumerator. No raw `CGWindowListCreateImage` outside WindowCapture. This enables mock-based testing.

4. **Error states are explicit.** Permission denied, capture failed, focus failed — all surface to UI as clear states, never silent failures.

## Key Technical Decisions

### Why AppKit, not SwiftUI
- `NSPanel` with `.nonactivatingPanel` is critical — panel must not steal focus
- SwiftUI cannot configure NSPanel style masks directly
- `NSOutlineView` is proven for tree structures with expand/collapse
- SwiftUI can be used for leaf views embedded via `NSHostingView` if desired

### Why CGWindowList for enumeration (not Accessibility API)
- `CGWindowListCopyWindowInfo` is fast (~1ms for 30 windows), single call
- Accessibility API needs per-app traversal — slower, more complex
- Use Accessibility ONLY for focus/raise, not enumeration

### Panel Behavior
- Type: `NSPanel` with `.nonactivatingPanel | .titled | .closable | .resizable`
- Level: `NSWindow.Level.floating`
- Dismiss via `orderOut` (not `close`) to avoid recreation cost
- Filter own PID from enumeration results

### Screenshot Capture
- `CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, .bestResolution)`
- Capture ONLY on tree item click (not eagerly)
- Show blurred placeholder, animate to clear via Core Animation
- Release CGImage when panel hides (nil out preview)
- Without Screen Recording permission: show app icon + window title placeholder

### Focus/Raise
- Resolve app via `NSRunningApplication(processIdentifier: pid)`
- `targetApp.activate(options: .activateIgnoringOtherApps)`
- Get AXUIElement → find matching window → `AXUIElementPerformAction(kAXRaiseAction)`
- Dismiss panel AFTER focus confirms (tiny delay avoids flicker)

## Known Pitfalls
- `CGWindowListCopyWindowInfo` returns `Unmanaged<CFArray>?` — handle nil, bridge to Swift carefully
- `AXUIElementPerformAction` can silently fail — always check OSStatus return
- `NSPanel` + `.nonactivatingPanel` + search bar keyboard input needs careful first-responder management
- Screen Recording permission: check with `CGPreflightScreenCaptureAccess()` (macOS 10.15+)
- Electron apps report hidden helper windows — filter by `kCGWindowIsOnscreen == true`
- Some apps set `kCGWindowName` to nil — fall back to app name + window index
