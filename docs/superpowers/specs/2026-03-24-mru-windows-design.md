# MRU (Most Recently Used) Windows Feature

## Problem
WindowPilot shows all windows in a tree view, but frequent window switching requires scanning the full list every time. Users typically switch between a small set of windows. A "Recent" view surfaces the most-used windows for faster access.

## Design

### Data Layer

#### WindowActivityTracker (Core)
Session-based tracker that records window focus activity.

**Data per window:**
- `windowID: UInt32`
- `pid: Int32`
- `appName: String`
- `bundleIdentifier: String?`
- `windowTitle: String`
- `lastFocusTime: Date`
- `totalDuration: TimeInterval`

**Interface:**
- `windowDidFocus(windowID:pid:appName:bundleIdentifier:windowTitle:)` — called by App layer when focused window changes. Stops timer on previous window, starts timer on new one.
- `recordDuration()` — snapshots the current active window's elapsed time (call before reading data).
- `recentWindows(limit:) -> [TrackedWindow]` — returns windows sorted by `lastFocusTime` descending.
- `topWindows(limit:) -> [TrackedWindow]` — returns windows sorted by `totalDuration` descending.
- `combinedRanking(limit:) -> [TrackedWindow]` — mixed sort: weighted by both recency and duration.

**Architecture note:** Core module cannot import AppKit. The `NSWorkspace.didActivateApplicationNotification` listener lives in AppDelegate. AppDelegate detects focus changes and calls `tracker.windowDidFocus(...)`.

**Focus detection in AppDelegate:**
- Subscribe to `NSWorkspace.didActivateApplicationNotification`
- On notification: get frontmost app PID via `NSWorkspace.shared.frontmostApplication`
- Use AX `kAXFocusedWindowAttribute` to get the specific window
- Use `_AXUIElementGetWindow` to get the CGWindowID
- Call `tracker.windowDidFocus(...)`
- Also detect focus changes when WindowPilot itself focuses a window (in `onWindowActivated`)

#### ScreenshotCache (Core)
Persistent (session-level) cache for window thumbnails.

- `cache(image:forWindowID:)` — store a screenshot
- `image(forWindowID:) -> CGImage?` — retrieve cached screenshot
- `refreshAsync(windowIDs:capture:completion:)` — background refresh for MRU thumbnails

**Integration:**
- On every `onWindowActivated`: capture and cache the focused window's screenshot
- On panel `show()`: serve MRU thumbnails from cache, then refresh in background
- Cache is NOT cleared on panel dismiss (unlike PreviewView)

### UI Layer

#### Tab Bar (in SearchBar or new component)
Two-segment control at the top of the panel, next to the search field:
- **Recent** — MRU list view
- **All Windows** — existing tree view

Search field only active in "All Windows" mode. In "Recent" mode, search field is hidden or disabled.

Default tab: "Recent" if tracker has data, otherwise "All Windows".

#### RecentView (new NSView)
Vertical scrollable list. Default shows first 6 items, scrolls for more.

**Each row (approx 80px tall):**
```
┌─────────────────────────────────────────────┐
│ ┌──────────┐  [AppIcon] AppName             │
│ │ thumbnail│  Window Title                  │
│ │ 120x75   │  12m total  ·  2m ago          │
│ └──────────┘                                │
└─────────────────────────────────────────────┘
```

- Left: window screenshot thumbnail (120x75, rounded corners, from cache)
- Right top: app icon (16x16) + app name (secondary color)
- Right middle: window title (primary, truncated)
- Right bottom: total duration + last used time (tertiary color)

**Interactions:**
- Click row → select (triggers `onWindowSelected` for preview)
- Double-click or Enter → activate (triggers `onWindowActivated` for focus)
- Arrow keys navigate rows

**Data source:** `tracker.combinedRanking(limit: 20)` — shows up to 20, default scroll shows ~6.

### Integration Flow

1. **App launches** → `WindowActivityTracker` created, `NSWorkspace` observer registered
2. **User works** → AppDelegate tracks focus changes, calls `tracker.windowDidFocus(...)`
3. **User focuses via WindowPilot** → `onWindowActivated` also caches screenshot
4. **User opens panel** →
   - If tracker has data: show "Recent" tab with `combinedRanking(limit: 20)`
   - Thumbnails from cache; background refresh for top 6
   - If no data: show "All Windows" tab
5. **User clicks tab** → switch between RecentView and TreeView
6. **User selects in Recent** → preview shows in right pane (same as tree)
7. **User activates in Recent** → same `onWindowActivated` callback as tree

### Files to Create/Modify

**New files:**
- `Sources/Core/WindowActivityTracker.swift` — tracking logic and data
- `Sources/Core/ScreenshotCache.swift` — thumbnail cache
- `Sources/UI/RecentView.swift` — MRU list view

**Modified files:**
- `Sources/App/AppDelegate.swift` — NSWorkspace observer, tracker wiring, cache wiring
- `Sources/UI/PilotPanel.swift` — tab switching, RecentView integration
- `Sources/UI/SearchBar.swift` — add tab segment control (or separate TabBar view)

### Not in Scope
- Persistent storage across app launches
- Configurable number of recent windows
- Keyboard shortcut to switch tabs
- Drag-and-drop reordering
