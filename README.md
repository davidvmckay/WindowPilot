# WindowPilot

**A macOS-native hotkey-summoned window navigator.** Press `Option+Space`, see every window on your Mac organized by app, click to preview, Enter to focus. Recognition over recall.

WindowPilot solves the fundamental problem of window switching on macOS: you shouldn't have to *remember* which window you want — you should be able to *see and pick* from everything that's open. Cmd+Tab only switches apps. Mission Control is slow and visual-only. WindowPilot gives you a fast, keyboard-driven, two-level tree of every window on every Space, with instant screenshot previews.

## How It Works

1. **Summon** — Press `Option+Space` from anywhere. A floating panel appears without stealing focus from your current app.
2. **Browse** — Two-level tree: Apps on the left (expand to see windows), live screenshot preview on the right.
3. **Search** — Type to filter by app name or window title. Fuzzy, instant.
4. **Focus** — Click, Enter, or double-click any window. WindowPilot navigates to the correct Space, raises the exact window, and dismisses itself.
5. **Dismiss** — Press `Escape`, press the hotkey again, or click anywhere outside the panel.

## Features

- **Non-activating panel** — The panel doesn't steal focus. Your current app keeps running while you browse.
- **Cross-Space navigation** — Works across normal Spaces, full-screen Spaces, and multiple displays.
- **Smart full-screen handling** — Navigates into and out of full-screen Spaces using a multi-step approach that preserves correct menu bar state (see [Technical Deep Dive](#full-screen-space-switching) below).
- **Lazy screenshot preview** — Screenshots are captured only when you select a window, not eagerly. Animates from blurred placeholder to crisp preview.
- **Click-outside dismissal** — Click anywhere outside the panel to dismiss, just like Spotlight.
- **Rounded corners** — Modern macOS visual design with `NSVisualEffectView` vibrancy and continuous corner radius.
- **Window actions** — Focus, Close, or Minimize any window directly from the panel.
- **Menu bar icon** — Status bar item for quick access without remembering the hotkey.

## Requirements

- **macOS 13.0+** (Ventura or later)
- **Swift 5.9+**
- **Accessibility permission** (required — used for window focus/raise via AXUIElement)
- **Screen Recording permission** (optional — enables live window screenshot previews)

## Build & Run

```bash
# Clone and build
git clone https://github.com/ethannortharc/WindowPilot.git
cd WindowPilot
swift build

# Run
.build/debug/WindowPilot

# Release build
swift build -c release

# Run tests
swift test
```

On first launch, macOS will prompt for Accessibility permission. Grant it in **System Settings → Privacy & Security → Accessibility**.

## Architecture

```
Sources/
├── App/                    # Entry point, lifecycle, hotkey
│   ├── AppDelegate.swift   # Panel wiring, focus orchestration
│   ├── HotkeyManager.swift # Global Option+Space hotkey (soffes/HotKey)
│   ├── main.swift          # NSApplication bootstrap
│   └── Permissions.swift   # AX + Screen Recording permission checks
├── Core/                   # Pure logic — NO AppKit imports
│   ├── WindowEnumerator.swift  # CGWindowList enumeration
│   ├── WindowNode.swift        # AppNode / WindowInfo data models
│   ├── WindowFocuser.swift     # CGS + SkyLight + AX focus engine
│   ├── WindowCapture.swift     # CGWindowListCreateImage screenshots
│   └── SearchFilter.swift      # Fuzzy search across app/window names
└── UI/                     # AppKit views
    ├── PilotPanel.swift    # NSPanel (non-activating, floating, rounded)
    ├── TreeView.swift      # NSOutlineView two-level tree
    ├── PreviewView.swift   # Screenshot preview with blur animation
    └── SearchBar.swift     # Inline search field with Esc handling
```

**Key architectural rule:** `Core/` has zero UI imports. All Core Graphics and Accessibility API calls are wrapped — no raw `CGWindowListCopyWindowInfo` or `AXUIElementPerformAction` outside their respective wrappers. This enables fast, mock-based unit testing.

## Tech Stack

| Layer | Technology | Why |
|-------|-----------|-----|
| UI | AppKit (`NSPanel`, `NSOutlineView`) | `NSPanel` with `.nonactivatingPanel` is the only way to show a floating panel without stealing focus. SwiftUI cannot configure NSPanel style masks. |
| Window enumeration | Core Graphics (`CGWindowListCopyWindowInfo`) | Single call, ~1ms for 30 windows. Accessibility API would need per-app traversal. |
| Focus/raise | Accessibility API (`AXUIElement`) + SkyLight private framework | AX for window-level raise, SkyLight for process-level focus. |
| Space switching | CGS private API (`CGSManagedDisplaySetCurrentSpace`) | Only mechanism that can switch between Spaces programmatically. |
| Screenshots | Core Graphics (`CGWindowListCreateImage`) | Per-window capture by window ID. |
| Global hotkey | [soffes/HotKey](https://github.com/soffes/HotKey) | Clean Swift wrapper around Carbon's `RegisterEventHotKey`. |

## Full-Screen Space Switching

This is where WindowPilot pushes the boundaries of what's possible on macOS. Full-screen Space switching is a notoriously difficult problem because macOS 16 (Tahoe) significantly restricted programmatic Space control.

### The Problem

macOS organizes full-screen windows on dedicated Spaces. Switching between them requires the Dock's internal Space-switch animation, which handles menu bar updates, compositor transitions, and focus management. There is **no public API** to trigger this animation.

The only programmatic Space-switching mechanism — `CGSManagedDisplaySetCurrentSpace` — is a private CGS call that switches the Space metadata but **bypasses the Dock's animation entirely**. This causes:

1. **Menu bar residual** — The previous app's menu bar persists at the top of the full-screen Space
2. **Floating windows** — Normal windows overlay the full-screen window instead of properly switching
3. **Focus inconsistency** — The system doesn't update the frontmost process

### What We Tried (macOS 16)

| Approach | Result |
|----------|--------|
| `CGSManagedDisplaySetCurrentSpace` | Switches Space but stale menu bar / floating windows |
| `_SLPSSetFrontProcessWithOptions` (SkyLight) | Returns success but doesn't update menu bar on macOS 16 |
| `kAXFrontmostAttribute` / `kAXRaiseAction` (AX) | Doesn't update menu bar |
| `NSRunningApplication.activate()` | Cannot enter full-screen Spaces; unreliable for exiting |
| `NSMenu.setMenuBarVisible(false)` | No effect on full-screen Space menu bar |
| `NSApp.presentationOptions = [.autoHideMenuBar]` | No effect |
| `CGEvent` simulated Ctrl+Arrow (`.cghidEventTap`) | Dock ignores synthetic events on macOS 16 |
| `CGEvent.postToPid(dockPID)` | Dock ignores direct-posted events too |
| `NSAppleScript` → System Events `key code` | Dock ignores AppleScript-generated events |

### Our Solution

Since no mechanism can trigger the Dock's native animation, WindowPilot uses a **multi-step AX-based approach** that leverages macOS's own full-screen entry/exit animations:

**Normal → Full-Screen:**
1. `CGSManagedDisplaySetCurrentSpace` — instant switch to the full-screen Space (brief stale menu bar)
2. `AXFullScreen = false` — exit the window from full-screen (AX is now accessible since we're on the same Space)
3. `focus()` — focus the now-normal window on its Space
4. `AXFullScreen = true` — re-enter full-screen via macOS's **native animation**, which properly updates the menu bar

**Full-Screen → Normal:**
1. `AXFullScreen = false` on the blocking full-screen window (with near-fullscreen size so it doesn't shrink)
2. `focus()` + `raiseWindow()` on the target normal window

**Normal → Normal:** Direct `CGSManagedDisplaySetCurrentSpace` + SkyLight + AX (no full-screen complications).

### Known Limitations

- **Full-screen exit is destructive** — When switching from a full-screen Space to a normal window, the full-screen window must exit full-screen mode (it cannot stay in full-screen in the background). This is because `CGSManagedDisplaySetCurrentSpace` causes floating artifacts, and macOS 16 blocks all forms of simulated Ctrl+Arrow events.
- **Normal→full-screen has a visible transition** — The exit + re-enter dance takes ~0.5-0.7 seconds with visible animation. This is the trade-off for a correct menu bar.
- **AX window visibility is Space-dependent** — On macOS 16, `_AXUIElementGetWindow` and the `AXFullScreen` attribute are not accessible for windows on other Spaces. WindowPilot works around this by switching to the target Space first via CGS, then performing AX operations.
- **Screen Recording permission** — Without it, window previews show app icon + window title placeholders instead of live screenshots.

### macOS 16 Private API Notes

```
CGSMainConnectionID()              — connection to the window server
CGSCopyManagedDisplaySpaces()      — per-display Space list with types
CGSManagedDisplaySetCurrentSpace() — switch current Space (no animation)
CGSCopySpacesForWindows()          — find which Space(s) a window is on
CGSSpaceGetType()                  — 0=user/normal, 4=fullscreen
_SLPSSetFrontProcessWithOptions()  — SkyLight process focus (unreliable on macOS 16)
SLPSPostEventRecordTo()            — SkyLight key window event
_AXUIElementGetWindow()            — map AX element to CGWindowID
```

## Panel Configuration

The floating panel uses specific `NSPanel` configuration to work correctly across normal and full-screen Spaces:

```swift
styleMask: [.nonactivatingPanel, .resizable]  // NO .titled, NO .fullSizeContentView
collectionBehavior: [.moveToActiveSpace, .fullScreenAuxiliary]
```

- **No `.titled`** — Eliminates phantom title bar artifacts on full-screen Spaces
- **No `.fullSizeContentView`** — On macOS 16, this allocates a phantom title bar region even without `.titled`
- **`.moveToActiveSpace`** not `.canJoinAllSpaces` — Panel only exists on the active Space. `.canJoinAllSpaces` prevents proper Space transitions after panel dismissal.
- **`.fullScreenAuxiliary`** — Allows the panel to appear over full-screen windows

## License

MIT

## Acknowledgments

- [soffes/HotKey](https://github.com/soffes/HotKey) for the global hotkey implementation
- The macOS window management community (yabai, AltTab, Amethyst) for documenting private APIs
