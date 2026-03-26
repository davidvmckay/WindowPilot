# WindowPilot

**A macOS-native window navigator.** Three ways to switch windows — see and pick, hold and slide, or type and go.

Cmd+Tab switches apps, not windows. Mission Control is slow. WindowPilot gives you instant, window-level switching across all Spaces — including full-screen.

## Install

Download the latest DMG from [Releases](https://github.com/ethannortharc/WindowPilot/releases), or build from source:

```bash
git clone https://github.com/ethannortharc/WindowPilot.git
cd WindowPilot
swift build -c release
```

On first launch, macOS will prompt for **Accessibility** permission. Grant it in System Settings → Privacy & Security → Accessibility. **Screen Recording** permission is optional (enables window screenshot previews).

> Signed with Developer ID and notarized by Apple.

## Usage

### Panel — `Option+Space`

A floating panel that shows every open window on your Mac.

| Tab | What it shows |
|-----|---------------|
| **Recent** | Grid of most-used windows with screenshot thumbnails, ranked by recency and active time. Single click to switch. |
| **All Windows** | Two-level tree (App → Windows). Type to search by app or window title. Click to preview, Enter to switch. |

The panel doesn't steal focus — your current app keeps running while you browse. Click outside or press Esc to dismiss.

### Carousel — `Ctrl+Option+Space`

Hold-to-browse switcher for rapid window switching:

1. **Hold** `Ctrl+Option+Space` — a horizontal strip of window thumbnails appears
2. **Left/Right arrows** to navigate
3. **Release** the modifier keys — instantly switches to the selected window

The previous window is pre-selected, so a quick press-and-release is a fast back-and-forth toggle.

### CLI — `windowpilot-cli`

Standalone command-line tool. Works independently from the GUI app — no daemon required.

```bash
# List all windows across all Spaces
windowpilot-cli list

# Fuzzy search and switch
windowpilot-cli "chrome"
windowpilot-cli switch "my document"

# Search with JSON output (for scripting and agents)
windowpilot-cli search "terminal"

# Switch by window ID
windowpilot-cli focus --id 257

# Capture a window screenshot
windowpilot-cli capture 260 screenshot.png
```

Designed for integration with Claude Code, Raycast, shell scripts, and any automation that needs programmatic window switching. This is the only macOS CLI that can switch at the **window** level (not just app level like `open -a`).

## How It Handles Full-Screen

Switching to and from full-screen Spaces is a known hard problem on macOS. The system provides no public API for programmatic Space switching, and macOS 16 blocks all forms of simulated keyboard shortcuts.

WindowPilot works around this:

- **Normal → Full-Screen**: Switches to the full-screen Space, exits the window from full-screen, focuses it, then re-enters full-screen via the native macOS animation (~0.5s transition).
- **Full-Screen → Normal**: Exits the blocking full-screen window (set to near-fullscreen size so it doesn't shrink), then focuses the target window.
- **Normal → Normal**: Direct switch, instant.

**Limitations:**
- Switching away from a full-screen window exits it from full-screen mode (macOS provides no way to leave a full-screen Space while keeping the window full-screen in the background).
- The normal→full-screen transition has a brief visible animation.

## Activity Tracking

WindowPilot tracks which windows you use in the background (session only, not persisted):

- Detects window focus changes across all monitors
- Filters out transient popups (notifications, "Build Succeeded", etc.)
- Ranks windows by 60% recency + 40% active duration
- Caches screenshot thumbnails for instant display

## Requirements

- macOS 13.0+ (Ventura or later)
- Accessibility permission (required)
- Screen Recording permission (optional, for previews)

## License

MIT
