# Review Fixes P0–P3 (post-1.4.1 external review)

Verified findings from an external review of v1.4.1. All 13 tasks below are
confirmed against source. Branch: `fix/review-p0-p3`.

## Global Constraints

- Architecture rules (CLAUDE.md): `Sources/Core/` must NOT import AppKit —
  pure Swift + CoreGraphics/ApplicationServices only. UI depends on Core,
  never the reverse. All CGWindowList calls stay wrapped in
  WindowEnumerator/WindowCapture.
- Error states are explicit: destructive or focus operations that cannot
  find their exact target must FAIL (return false / show ToastHUD), never
  silently act on a different window.
- Build: `swift build`. Tests: `swift test --filter WindowPilotCoreTests`
  (must stay green; integration tests need an AX-trusted GUI session and are
  environmental in this shell — do not chase their failures unless the task
  says so).
- Commit per task with a descriptive message ending in:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Keep comment density/idiom of surrounding code. No drive-by refactors.
- The app is an `.accessory` app; SidebarPanel is a never-key panel — cards
  there rely on `acceptsFirstMouse` + direct mouseDown/mouseUp (do not
  reintroduce gesture recognizers on WindowCardView).

## Task 1: Selection single source of truth (PilotPanel/TreeView/RecentView)

**Bug (confirmed):** `PilotPanel.switchToTab` (Sources/UI/PilotPanel.swift:266)
only toggles view visibility; `selectedWindow` keeps the previous tab's
value. ActionBar Focus/Close/Minimize read `selectedWindow`, so they can act
on a window that is NOT the one highlighted in the visible view. Same class:
`TreeView.reloadData` (Sources/UI/TreeView.swift:42) preserves selection
positionally across reloads/filtering — the highlighted row can silently
become a different window without `onWindowSelected` firing.

**Requirements:**
1. `TreeView` gains `var selectedWindowInfo: WindowInfo?` (read-only
   computed: the WindowInfo at `outlineView.selectedRow`, nil for group rows
   or no selection).
2. `RecentView` gains an equivalent `var selectedWindowInfo: WindowInfo?`
   for its currently selected card (nil when none).
3. `TreeView.reloadData` re-selects by window ID, not row position: capture
   `selectedWindowInfo?.id` before `outlineView.reloadData()`; after reload +
   expansion restore, find the row containing that window ID and re-select
   it; if the ID is gone, fall back to `selectFirstLeaf()`. If the effective
   selected window CHANGED (different ID or none), fire `onWindowSelected`
   with the new selection so PilotPanel/preview resync. Do not double-fire
   when the same window remains selected.
4. `PilotPanel.switchToTab` resyncs after toggling visibility:
   `selectedWindow = (recent ? recentView.selectedWindowInfo : treeView.selectedWindowInfo)`.
   If non-nil and different from before: call `onWindowSelected?(win)` and
   `actionBar.updateForState(win.state)`. If nil: clear the preview
   (`previewView.clearPreview()`) and leave action buttons in a safe state.
5. Tests (TDD): add `Tests/IntegrationTests/TreeSelectionTests.swift` —
   instantiate `TreeView` directly with fake `[AppNode]` data (no window
   needed; NSOutlineView data source logic works headless):
   - reload with a filtered subset → selection follows the previously
     selected window ID, not the row index;
   - selected window removed by filter → selection falls to first leaf AND
     `onWindowSelected` fires with the new window;
   - same data reloaded → no spurious `onWindowSelected` fire.
   These tests must run without AX permission (pure AppKit object tests) —
   verify they pass with `swift test --filter TreeSelectionTests`.

**Files:** Sources/UI/PilotPanel.swift, Sources/UI/TreeView.swift,
Sources/UI/RecentView.swift, Tests/IntegrationTests/TreeSelectionTests.swift

## Task 2: All actions keyed by window ID; kill the windows.first fallback

**Bug (confirmed):** `WindowFocuser.focus` (Sources/Core/WindowFocuser.swift:75-77)
resolves `findWindowByID(...) ?? findWindow(matching: title) ?? windows.first`
— a nonexistent target raises the app's FIRST window and returns true.
`minimize`/`close` (:116-139) take only pid+title; two same-titled windows →
first match wins, destructively. Sidebar close/minimize callers
(Sources/App/AppDelegate.swift:672-685) pass only pid+title.

**Requirements:**
1. `focus(pid:windowID:windowTitle:state:)`: when `windowID != 0`, resolve
   by ID first, then title match as fallback (title drift with stale IDs is
   NOT possible — CGWindowID is stable — but title fallback covers AX
   enumeration hiccups; keep it). REMOVE the `?? windows.first` tail: if
   neither ID nor exact-title match finds the window, return false (the
   existing "no AX window match" print + return false path). When
   `windowID == 0` (title-based API), match by title only; no match →
   return false. The convenience overloads stay source-compatible.
2. `minimize(pid:windowTitle:)` → `minimize(pid:windowID:windowTitle:)`;
   `close(pid:windowTitle:)` → `close(pid:windowID:windowTitle:)`. Both:
   resolve by ID first (`findWindowByID`); if windowID != 0 and no ID match,
   return false — destructive ops NEVER fall back to title or first window.
   Title-only resolution allowed only when windowID == 0 AND exactly one
   window matches the title (count all title matches; >1 → return false).
3. Update ALL call sites (AppDelegate sidebar close/minimize, panel
   onWindowClose/onWindowMinimize wiring, any CLI use) to pass
   `windowInfo.id`. Grep for `focuser.close(` / `focuser.minimize(`.
4. CLI (`Sources/CLI/main.swift`) `cmdSwitch`: it already enumerates and
   picks a match — ensure it calls focus with the matched window's real
   `id` (not the windowID:0 overload). If the query matches only an app
   name (no window match), explicitly pick that app's first window and pass
   its real ID — "switch to app" semantics become the CALLER's explicit
   choice, not a focuser fallback.
5. Tests (TDD): extend `Tests/CoreTests` — the AX resolution itself needs a
   live session, so factor the DECISION logic into a pure, testable helper:
   `WindowFocuser.resolution(forID:titleMatches:candidateCount:)` or
   similar pure function that decides matched/failed given (idMatchFound,
   titleMatchCount, windowID). Unit-test: nonexistent ID → fail; id=0 with
   2 title matches → fail for destructive, etc. Keep the integration test
   `test_focus_nonexistent_window_returns_false` semantics intact (it will
   pass in AX-trusted runs once the fallback is gone).

**Files:** Sources/Core/WindowFocuser.swift, Sources/App/AppDelegate.swift,
Sources/CLI/main.swift, Tests/CoreTests/*

## Task 3: CLI installer — safe quoting for the privileged shell

**Bug (confirmed):** `offerCLIInstallation` (Sources/App/AppDelegate.swift:112-114)
interpolates the bundle path into a double-quoted `sh` command inside
`do shell script ... with administrator privileges`. A path containing
`$( )`, backticks, or `"` executes arbitrary commands as admin.

**Requirements:**
1. Add a pure helper in Core (no AppKit):
   `public enum ShellQuoting { public static func appleScriptStringLiteral(_ s: String) -> String }`
   — escapes `\` and `"` for embedding in an AppleScript string literal.
2. Rebuild the script using AppleScript `quoted form of` so the SHELL never
   sees an unquoted path:
   ```
   set p to "<escaped bundlePath>"
   set d to "<escaped cliDest>"
   do shell script "mkdir -p /usr/local/bin && ln -sf " & quoted form of p & " " & quoted form of d with administrator privileges
   ```
3. Reject paths containing ASCII control characters (0x00–0x1F) before
   building the script (silently return; nothing sane lives at such paths).
4. Tests (TDD, CoreTests): escaping of quote, backslash, `$(...)`,
   backtick, unicode path; control-char rejection helper if factored pure.

**Files:** Sources/Core/ShellQuoting.swift (new),
Sources/App/AppDelegate.swift, Tests/CoreTests/ShellQuotingTests.swift (new)

## Task 4: Enumerate untitled off-screen windows (cross-Space without Screen Recording)

**Bug (confirmed):** Q2 pass guard (Sources/Core/WindowEnumerator.swift:71)
`guard let name = ..., !name.isEmpty else { continue }` drops every
untitled off-screen window. Without Screen Recording permission,
kCGWindowName is absent for ALL other apps, so the entire off-screen pass
(other Spaces, minimized) yields nothing — the product's core cross-Space
promise silently degrades.

**Requirements:**
1. Remove the non-empty-name guard from the Q2 loop. Untitled off-screen
   windows continue into `allEntries` (title falls back to "Untitled" in
   `buildAppNodes`, which already handles nil/empty).
2. Junk filtering moves to the AX layer that already exists:
   `detectMinimized` already tags entries with no AX representation as `✕`
   (ghost) and `buildAppNodes` already excludes `✕`. That is the correct
   filter for Electron helper surfaces. Verify this path covers the
   previously-guarded junk: off-screen entries with NO AX window are
   excluded; off-screen entries WITH an AX window are legitimate.
3. Watch minDimension/layer/alpha filters stay as-is (isEligible unchanged).
4. Tests: `buildAppNodes` and the Q1/Q2 merge logic are private statics —
   make the minimal seam needed (e.g. `internal static func` +
   `@testable import`) to unit-test: an off-screen entry with empty name
   and no AX presence is excluded; with AX presence is included titled
   "Untitled". AX itself can be injected as a closure parameter or covered
   at the integration tier — choose the smallest honest seam, do not build
   a mocking framework.
5. Manual sanity note in the report: run `.build/debug/windowpilot-cli list`
   and confirm no obvious junk windows appear (helper processes, tooltips).

**Files:** Sources/Core/WindowEnumerator.swift, Tests/CoreTests/*

## Task 5: Full-screen exit targets the right display

**Bug (confirmed):** `exitCurrentFullScreen()` (Sources/Core/WindowFocuser.swift:306)
iterates displays and exits fullscreen on the FIRST display whose current
Space is fullscreen — the caller cannot say which display the target is on.
Worse, it sets the exiting window's AXPosition to global `(5, 30)`
(:357), teleporting a secondary-display window onto the primary display.

**Requirements:**
1. Signature: `exitCurrentFullScreen(preferDisplayOfWindowID: UInt32? = nil)`.
   When a target window ID is given: among displays whose current Space is
   fullscreen, prefer the one whose space list (`displayInfo["Spaces"]`)
   contains the TARGET window's space (via `CGSCopySpacesForWindows` on the
   target). Fall back to the current first-match behavior when no display
   matches or the parameter is nil.
2. Fix the position: the exiting fullscreen window's own CG bounds origin IS
   its display's origin (fullscreen covers the display). Set
   AXPosition = (windowBounds.origin.x + 5, windowBounds.origin.y + 30) and
   size = (width - 10, height - 10), using the full bounds dict already
   fetched (X/Y keys exist alongside Width/Height). The window must stay on
   its own display.
3. `performFocus` (AppDelegate) passes the target window ID at both
   `exitCurrentFullScreen()` call sites.
4. Tests: extract the display-selection decision into a pure function
   (input: array of (displayIndex, spaceIDs, currentSpaceIsFullscreen),
   target's spaceIDs → chosen index) in Core and unit-test it: target on
   2nd fullscreen display → picks 2nd; no fullscreen display containing
   target → falls back to first fullscreen; nil target → first fullscreen.

**Files:** Sources/Core/WindowFocuser.swift, Sources/App/AppDelegate.swift,
Tests/CoreTests/*

## Task 6: Replace fixed fullscreen-transition delays with condition polling

**Issue (confirmed factual):** performFocus fullscreen paths use fixed
50/280/350ms (and 0.7s/press Ctrl+Arrow cadence) delays
(Sources/App/AppDelegate.swift:530-608). On slow machines/animations these
race; on fast ones they waste time.

**Requirements:**
1. Add a small main-queue poll helper (App layer, near performFocus or a
   tiny utility): `poll(every: 0.05, timeout: TimeInterval, until: @escaping () -> Bool, then: @escaping (Bool) -> Void)`
   — repeatedly checks `until` on the main queue, calls `then(true)` when
   the condition holds or `then(false)` at timeout. No Timer retain cycles.
2. Replace in the normal→fullscreen path: the 0.28s wait before re-focus
   becomes "poll until `focuser.calculateSpaceNavigation(targetWindowID:) == nil`
   (space switch landed) OR 1.0s timeout"; the 0.35s re-enter wait becomes
   a follow-on step after the focus completes (+0.1s settle).
   In the fullscreen→normal fallback path: the 0.55s wait after
   `exitCurrentFullScreen` becomes "poll until the exited window's Space is
   no longer type-4 fullscreen (use `isWindowOnFullScreenSpace(windowID:)`
   on the EXITED window id from ExitedFullScreenInfo) OR 1.5s timeout".
   The timeout branch proceeds exactly as today (best-effort), so behavior
   can only get more reliable, never less.
3. Keep the Ctrl+Arrow per-press 0.7s cadence as-is (Dock animation pacing,
   not a readiness wait).
4. This is timing-sensitive glue with no honest unit-test seam — no new
   tests required; the deliverable is the helper + call-site conversion +
   a clean build and unchanged core tests. Manual verification note in the
   report: describe which paths you converted and the timeout values.

**Files:** Sources/App/AppDelegate.swift, Sources/Core/WindowFocuser.swift
(only if a readiness predicate needs exposing), Tests unchanged.

## Task 7: VoiceOver semantics for all window cards

**Gap (confirmed):** zero accessibility API usage in Sources/UI. Cards in
Recent grid, Carousel, and Sidebar expose no role/label/press action —
VoiceOver users cannot activate them.

**Requirements:**
1. `WindowCardView` (shared by Carousel + Sidebar): override
   `isAccessibilityElement() -> true`, `accessibilityRole() -> .button`,
   `accessibilityLabel()` -> "AppName — WindowTitle" (fall back to just app
   name when title empty), `accessibilityPerformPress() -> Bool` invoking
   `onClicked` (return true when a handler ran), and reflect selection via
   `isAccessibilitySelected()`. Store appName/title at init for the label;
   add a `setAccessibilityWindowTitle(_:)`-style update only if the card
   already receives title updates (it does not today — label from init is
   fine).
2. `RecentView`'s card class (`RecentCardView` or equivalent — read the
   file): same treatment; label includes relative recency if the card
   already displays it (reuse the same string the meta label shows).
3. Keyboard focus ring: RecentView already implements arrow-key selection;
   ensure the selected card draws a visible focus indicator when the view
   has keyboard focus (the existing accent border qualifies IF it is
   distinguishable — if selection border already exists, confirm and note
   it; do not invent a second ring).
4. Verification: build + a small unit test in IntegrationTests
   instantiating a card and asserting `isAccessibilityElement()`,
   `accessibilityRole() == .button`, label content, and that
   `accessibilityPerformPress()` fires `onClicked`. (These are plain object
   tests, no AX permission needed.)

**Files:** Sources/UI/WindowCardView.swift, Sources/UI/RecentView.swift,
Tests/IntegrationTests/CardAccessibilityTests.swift (new)

## Task 8: Adaptive panel layout + ⌘K

**Gaps (confirmed):** resizable panel with no `minSize`; left column fixed
280pt; search placeholder says "⌘K" (Sources/UI/SearchBar.swift:49) but no
handler exists; Recent tab leaves a large blank area with few cards.

**Requirements:**
1. `PilotPanel.configurePanel`: `minSize = NSSize(width: 640, height: 400)`.
2. ⌘K: `PilotPanel.performKeyEquivalent(with:)` — on Cmd+K, switch to the
   All Windows tab (if on Recent) and focus the search field; return true.
   Keep Esc behavior untouched.
3. Left column: replace the fixed 280pt width constraint with
   min 220 / preferred 280 (priority < required) so the split can compress;
   give the preview side a 300pt minimum via holding priorities or split
   view delegate minimums — whichever matches the existing splitView setup
   (read it first).
4. Recent mode blank space: when switching to Recent, size the panel height
   to fit the actual rows: RecentView exposes
   `func preferredHeight(forWidth:) -> CGFloat` (rows × card height +
   spacing + insets, computed from its layout constants), and
   `switchToTab(recent: true)` animates `setContentSize` to
   min(preferredHeight + chrome, current height), never below minSize.
   Switching back to All restores the previous size (store it).
5. Verification: build; report a manual checklist line (resize floor works,
   ⌘K focuses search from both tabs, Recent with 3 cards has no dead half-
   panel). No automated UI test required.

**Files:** Sources/UI/PilotPanel.swift, Sources/UI/RecentView.swift,
Sources/UI/SearchBar.swift (only if focus helper needed)

## Task 9: First-run permission flow

**Issue (confirmed):** applicationDidFinishLaunching runs
`Permissions.checkAccessibility()` (:45, prompts), screen-recording check
(:46), and `offerCLIInstallation()` (:65 modal) — up to three dialogs
before the user has done anything.

**Requirements (read Sources/App/Permissions.swift first):**
1. Launch keeps: Accessibility prompt (the app is nonfunctional without it)
   and the PASSIVE screen-recording preflight (`CGPreflightScreenCaptureAccess`,
   no prompt). If `checkScreenRecording` currently triggers the system
   prompt (CGRequestScreenCaptureAccess), split it: `preflight()` (passive)
   at launch, `request()` (prompting) on demand.
2. Screen-recording request moves to first actual need: the first time the
   user opens the panel/preview without permission
   (`hasScreenRecording == false`), call `request()` once per app run
   (guard with a flag), then re-preflight and update
   `panel.updateScreenRecordingPermission` + `hasScreenRecording`.
   The existing placeholder UI for missing permission stays.
3. CLI installer offer moves out of launch: trigger after the FIRST
   successful window activation via the panel (once per install lifetime —
   keep the existing "already installed" check plus a UserDefaults flag
   `CLIOfferShown` so declining is remembered). Also add a "Install CLI
   Tool…" item to the status-bar menu so it stays discoverable.
4. Verification: build; report the new launch sequence and where each
   prompt now fires. Manual test note acceptable.

**Files:** Sources/App/AppDelegate.swift, Sources/App/Permissions.swift

## Task 10: ScreenshotCache — bounded LRU, downscale, prune

**Issue (confirmed):** Sources/Core/ScreenshotCache.swift is an unbounded
`[UInt32: CGImage]` of full-resolution captures; `remove(windowID:)` exists
but no caller ever invokes it. Long sessions grow unbounded.

**Requirements:**
1. LRU by byte cost inside ScreenshotCache (keep NSLock; no actor rewrite):
   track per-entry cost (`bytesPerRow * height`), total cap 200 MB default
   (init parameter), evict least-recently-USED (reads AND writes refresh
   recency) until under cap.
2. Downscale on store: cache() and refreshAsync() downscale images whose
   width exceeds 1200px to 1200px wide (aspect preserved) via CG (no
   AppKit — use CGContext). Full-resolution images are for the live preview
   pane only, which does NOT go through this cache (verify and state where
   preview images flow; if they do transit the cache, exempt the preview
   path by capturing fresh instead).
3. Prune: `func prune(keeping liveIDs: Set<UInt32>)` removes dead-window
   entries. Call it where enumeration results are fresh: `showPanel` and
   `syncSidebar` in AppDelegate (cheap set diff).
4. Wire `remove(windowID:)` when a window is closed via WindowPilot
   (sidebar/panel close paths).
5. Tests (TDD, CoreTests): LRU eviction order, cost accounting, downscale
   dimensions (CGImage creatable headless via CGContext), prune, and
   thread-safety smoke (concurrent cache/read loop with DispatchQueue
   .concurrentPerform — assertions on invariants, not timing).

**Files:** Sources/Core/ScreenshotCache.swift, Sources/App/AppDelegate.swift,
Tests/CoreTests/ScreenshotCacheTests.swift

## Task 11: bundleIdentifier enrichment + CLI polish + drag-pin X bound

**Issues (confirmed):** AppNode.bundleIdentifier is always nil
(Sources/Core/WindowEnumerator.swift:242) so pins resolve by localized app
name; CLI help claims "Fuzzy search" for a substring match and hardcodes
version "1.0.0"; sidebar drag-pin fires on Y alone (SidebarPanel
onDragEnded → pinnedZoneBottomOnScreen), so releasing high anywhere on
screen pins.

**Requirements:**
1. bundleIdentifier: Core stays AppKit-free, so enrich at the boundary —
   in WindowEnumerator, populate `bundleIdentifier` per PID via
   `proc_pidpath`+Bundle? NO — simplest honest source is
   `NSRunningApplication`, which is AppKit. Therefore: add
   `AppNode.withBundleIdentifier(_:)` (Core, pure copy helper) and enrich in
   the App layer: AppDelegate wraps `enumerator.enumerate(...)` in a small
   `enrichedApps()` helper mapping PID → bundleID via
   `NSRunningApplication(processIdentifier:)`. All AppDelegate call sites
   use it. PinStore.resolve already prefers bundleIdentifier when present —
   verify (read it) and fix if it doesn't.
2. CLI: new `Sources/CLI/Version.swift` with `let cliVersion = "1.4.1"`;
   `version` command prints it. Extend `scripts/release.sh` (right before
   `swift build -c release`) to stamp it:
   `sed -i '' "s/let cliVersion = \".*\"/let cliVersion = \"${VERSION}\"/" Sources/CLI/Version.swift`
   and include the file in the release commit if changed. Help text: change
   "Fuzzy search and switch to first match" → "Search (case-insensitive
   substring) and switch to first match".
3. Drag-pin X bound: in SidebarPanel's `onDragEnded` handling, require the
   release point to be horizontally within the strip frame ±8pt
   (`frame.minX - 8 ... frame.maxX + 8`) in addition to the Y check.
4. Tests: CoreTests for `AppNode.withBundleIdentifier` copy semantics and
   (if PinStore.resolve needed fixing) a resolve-prefers-bundleID test.
   CLI/script changes verified by build + `.build/debug/windowpilot-cli
   version`.

**Files:** Sources/Core/WindowNode.swift (AppNode helper),
Sources/App/AppDelegate.swift, Sources/Core/PinStore.swift (verify),
Sources/CLI/Version.swift (new), Sources/CLI/main.swift,
scripts/release.sh, Sources/UI/SidebarPanel.swift, Tests/CoreTests/*

## Task 12: Fix the TextEdit enumeration test fixture

**Bug (confirmed):** `test_enumeration_finds_real_windows`
(Tests/IntegrationTests/EnumerationIntegrationTests.swift) types marker text
into the document BODY and asserts the marker appears in window TITLES —
titles stay "Untitled", so 3 assertions fail in every GUI run.

**Requirements:**
1. Rework the fixture: create temp .txt files NAMED with the marker
   (e.g. `WPTest_<hex>_1.txt`) in a temp dir, `open -a TextEdit <file>` —
   the window title becomes the filename, which the existing assertions
   then find. Clean up: close windows/quit TextEdit as the test already
   does, plus delete temp files in defer/tearDown.
2. Keep the skip-guard behavior for non-GUI environments exactly as-is.
3. Verification: the test still SKIPS (not fails) in a non-AX shell — run
   `swift test --filter test_enumeration_finds_real_windows` and confirm
   skip-or-pass, never the 3 marker failures. (In this shell TextEdit
   scripting may be blocked — a skip is an acceptable outcome; say which
   you observed.)

**Files:** Tests/IntegrationTests/EnumerationIntegrationTests.swift

## Task 13: Visual pass — semantic window-state indicators + legible fonts

**Issues (confirmed, design):** tree leaf rows use per-window colored dots
with no semantic meaning (six-ish hashed colors — read TreeView leaf cell
code first); five labels use 10pt (RecentView:270,282, TreeView:373,392
badges are fine at 10pt semibold — leave badges, WindowCardView:67).

**Requirements:**
1. TreeView leaf dot → ONE semantic indicator, monochrome by state:
   - normal: `circle.fill` SF Symbol, `.tertiaryLabelColor`, 6pt
   - minimized: `minus.circle` symbol, `.secondaryLabelColor`
   - fullscreen: `arrow.up.left.and.arrow.down.right.circle` (or
     `rectangle.fill` if the arrow reads poorly at 12pt), `.controlAccentColor`
   Remove the color-hash logic entirely.
2. Fonts: RecentView appNameLabel and metaLabel 10 → 11pt;
   WindowCardView nameLabel 10 → 11pt. TreeView badge fonts stay.
   Verify card layout still fits (label row heights in WindowCardView.layout
   use fixed 24pt region — bump to fit 11pt if needed).
3. No other visual changes. Build + report before/after description.

**Files:** Sources/UI/TreeView.swift, Sources/UI/RecentView.swift,
Sources/UI/WindowCardView.swift
