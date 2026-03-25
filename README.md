# WindowPilot

**A macOS-native window navigator with hotkey panel, carousel switcher, and CLI.** Three ways to switch windows — see and pick, hold and slide, or type and go.

WindowPilot solves the fundamental problem of window switching on macOS: you shouldn't have to *remember* which window you want — you should be able to *see and pick* from everything that's open. Cmd+Tab only switches apps. Mission Control is slow. WindowPilot gives you window-level switching across all Spaces, with search, previews, and activity tracking.

## Installation

### DMG (recommended)
Download the latest DMG from [Releases](https://github.com/ethannortharc/WindowPilot/releases).

1. Open `WindowPilot-1.0.0.dmg`
2. Drag `WindowPilot.app` to Applications
3. Copy `windowpilot-cli` from the CLI Tool folder to `/usr/local/bin/`
4. Launch WindowPilot — grant Accessibility permission when prompted

### Build from source
```bash
git clone https://github.com/ethannortharc/WindowPilot.git
cd WindowPilot
swift build -c release

# GUI app
.build/release/WindowPilot

# CLI tool
.build/release/windowpilot-cli --help
```

## Three Ways to Switch

### 1. Panel (`Option+Space`)

Full-featured window browser with two tabs:

**Recent tab** — Grid of most-used windows with screenshot thumbnails, sorted by a combined recency + duration ranking. Single click switches instantly.

**All Windows tab** — Two-level tree (App → Windows) with search. Type to filter by app name or window title. Click a window to preview its screenshot on the right, Enter or double-click to switch.

- Non-activating panel (doesn't steal focus)
- Click outside to dismiss
- Rounded corners with vibrancy
- Window actions: Focus, Close, Minimize

### 2. Carousel (`Ctrl+Option+Space`)

Hold-to-browse window strip for rapid switching:

1. **Hold** `Ctrl+Option+Space` — carousel appears with window thumbnails
2. **Arrow keys** left/right to navigate
3. **Release** `Ctrl+Option` — switches to the selected window

Pre-selects the previous window (index 1), so a quick press-and-release is an instant Alt+Tab-style switch. Shows MRU windows first, then all remaining windows.

### 3. CLI (`windowpilot-cli`)

Standalone command-line tool for agents, scripts, and automation:

```bash
# List all windows
windowpilot-cli list

# Fuzzy search and switch (shorthand)
windowpilot-cli "chrome"

# Search with JSON output (for agents)
windowpilot-cli search "terminal"

# Focus by window ID
windowpilot-cli focus --id 257

# Capture window screenshot
windowpilot-cli capture 260 screenshot.png
```

The CLI is fully independent — it doesn't need the GUI app running. Designed for integration with Claude Code, Raycast, shell scripts, and any agent that needs programmatic window switching.

## MRU (Most Recently Used) Tracking

WindowPilot tracks window focus activity in the background:

- **Event-driven** — Listens for app activation via `NSWorkspace` notifications
- **Polling** — 2-second timer catches same-app window switches across monitors
- **Combined ranking** — 60% recency weight + 40% duration weight
- **Transient filtering** — Xcode "Build Succeeded", notifications, and popups are excluded (detected via AX close button and subrole)
- **Session-based** — Resets on app restart, no persistent storage
- **Screenshot cache** — Thumbnails cached on selection, background-refreshed when panel opens

## Requirements

- **macOS 13.0+** (Ventura or later)
- **Accessibility permission** (required — window focus/raise via AXUIElement)
- **Screen Recording permission** (optional — enables window screenshot previews)

## Architecture

```
Sources/
├── App/                        # GUI app entry point
│   ├── AppDelegate.swift       # Panel/carousel wiring, focus orchestration, MRU tracking
│   ├── HotkeyManager.swift     # Option+Space and Ctrl+Option+Space hotkeys
│   ├── main.swift              # NSApplication bootstrap
│   └── Permissions.swift       # AX + Screen Recording permission checks
├── CLI/                        # Standalone CLI tool
│   └── main.swift              # list, switch, search, focus, capture commands
├── Core/                       # Pure logic — NO AppKit imports
│   ├── WindowEnumerator.swift  # CGWindowList enumeration across all Spaces
│   ├── WindowNode.swift        # AppNode / WindowInfo / WindowState models
│   ├── WindowFocuser.swift     # CGS + SkyLight + AX focus engine
│   ├── WindowCapture.swift     # Per-window screenshot capture
│   ├── WindowActivityTracker.swift  # MRU tracking with duration + recency
│   ├── ScreenshotCache.swift   # Session-level thumbnail cache
│   └── SearchFilter.swift      # Fuzzy search across app/window names
└── UI/                         # AppKit views
    ├── PilotPanel.swift        # NSPanel with tab bar (Recent / All Windows)
    ├── CarouselPanel.swift     # Horizontal hold-to-browse switcher
    ├── RecentView.swift        # 3-column grid of MRU windows with thumbnails
    ├── TreeView.swift          # NSOutlineView two-level tree
    ├── PreviewView.swift       # Screenshot preview with blur animation
    └── SearchBar.swift         # Inline search field with Esc handling
```

**Key rule:** `Core/` has zero UI imports. All CG/AX calls are wrapped. This enables the CLI to use the same logic without any AppKit dependency.

## Full-Screen Space Switching

Full-screen Space switching is notoriously difficult on macOS 16 (Tahoe). `CGSManagedDisplaySetCurrentSpace` can switch Spaces but bypasses the Dock's animation, leaving stale menu bars and floating artifacts. macOS 16 blocks all forms of simulated Ctrl+Arrow events (CGEvent, AppleScript, postToPid).

### WindowPilot's Solution

**Normal → Full-Screen:** CGS switch → AX exit fullscreen → focus → AX re-enter fullscreen. The re-enter uses macOS's native animation which properly updates the menu bar.

**Full-Screen → Normal:** AX exit the blocking fullscreen window (with near-fullscreen size) → focus the target normal window.

**Normal → Normal:** Direct CGS + SkyLight + AX (no complications).

### What Doesn't Work on macOS 16

| Approach | Result |
|----------|--------|
| `CGSManagedDisplaySetCurrentSpace` alone | Stale menu bar, floating windows |
| `_SLPSSetFrontProcessWithOptions` | Returns success, doesn't update menu bar |
| `NSRunningApplication.activate()` | Cannot enter full-screen Spaces |
| `CGEvent` simulated Ctrl+Arrow | Dock ignores synthetic events |
| `CGEvent.postToPid(dockPID)` | Dock ignores direct-posted events |
| `NSAppleScript` → System Events | Dock ignores AppleScript-generated events |
| `NSMenu.setMenuBarVisible(false)` | No effect on full-screen Space |

### Known Limitations

- **Full-screen exit is destructive** — Switching from fullscreen to normal exits the fullscreen window (macOS provides no way to switch away while preserving fullscreen state)
- **Normal→fullscreen transition** — ~0.5s visible animation (exit + re-enter dance for correct menu bar)
- **AX is Space-dependent on macOS 16** — `_AXUIElementGetWindow` and `AXFullScreen` are inaccessible for windows on other Spaces. WindowPilot works around this by CGS-switching first.
- **Unsigned** — Not yet code-signed (Developer Program pending). First launch: right-click → Open.

## Tech Stack

| Layer | Technology | Why |
|-------|-----------|-----|
| UI | AppKit (`NSPanel`, `NSOutlineView`) | `NSPanel` with `.nonactivatingPanel` is the only way to show a floating panel without stealing focus |
| Window enumeration | Core Graphics (`CGWindowListCopyWindowInfo`) | Single call, ~1ms for 30 windows |
| Focus/raise | AX (`AXUIElement`) + SkyLight private framework | AX for window-level control, SkyLight for process-level focus |
| Space switching | CGS private API (`CGSManagedDisplaySetCurrentSpace`) | Only programmatic Space-switching mechanism on macOS |
| Screenshots | Core Graphics (`CGWindowListCreateImage`) | Per-window capture by window ID |
| Global hotkeys | [soffes/HotKey](https://github.com/soffes/HotKey) | Swift wrapper around Carbon's `RegisterEventHotKey` |

## License

MIT

## Acknowledgments

- [soffes/HotKey](https://github.com/soffes/HotKey) for the global hotkey implementation
- The macOS window management community (yabai, AltTab, Amethyst) for documenting private APIs
