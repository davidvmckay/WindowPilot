# Auto-Update (Sparkle 2) + High-Priority Fixes — Design

**Date:** 2026-07-15
**Status:** Approved scope: Sparkle 2 auto-update via GitHub + the 6 high-priority findings from the 2026-07-15 code review.
**Target release:** v1.3.0

## Context

WindowPilot is distributed as a notarized DMG via GitHub Releases (`ethannortharc/WindowPilot`). There is no in-app update mechanism; users must manually download new DMGs. A full-codebase review (2026-07-15) also surfaced six high-priority correctness/performance defects to fix in the same release.

## Part 1 — Auto-Update via Sparkle 2

### Decision

Use **Sparkle 2** (industry-standard macOS updater) with the entire update chain hosted on GitHub — no custom server.

- **Behavior:** automatic check once per day (Sparkle default interval), standard Sparkle prompt with release notes, user clicks Install → download → verify → replace → relaunch. Manual "Check for Updates…" item in the status menu.
- **Feed:** `appcast.xml` committed to the repo `main` branch, served at `https://raw.githubusercontent.com/ethannortharc/WindowPilot/main/appcast.xml`.
- **Payload:** the existing notarized DMG uploaded to GitHub Releases (Sparkle 2 supports DMG enclosures natively).
- **Integrity:** EdDSA (ed25519) signatures. One-time `generate_keys`; private key stays in the local Keychain, public key ships in `Info.plist` (`SUPublicEDKey`).

### Components

| Component | Change |
|---|---|
| `Package.swift` | Add `sparkle-project/Sparkle` (2.x, binary xcframework). Add `-rpath @executable_path/../Frameworks` linker flag to the `WindowPilot` executable target. |
| `Sources/App/UpdateManager.swift` (new) | Thin wrapper owning `SPUStandardUpdaterController`. Exposes `checkForUpdates()` for the menu item. Lives in App/ (Sparkle never enters Core/). |
| `Sources/App/AppDelegate.swift` | Instantiate `UpdateManager`; add "Check for Updates…" to the status menu. |
| `WindowPilot.app/Contents/Info.plist` | Add `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks=true`. |
| `WindowPilot.app/Contents/Frameworks/` | Embed `Sparkle.framework` (copied from `.build/artifacts/`). |
| `scripts/release.sh` (new) | Scripted release pipeline (below). Replaces the current manual pipeline. |
| `appcast.xml` (new, repo root) | Generated per release, committed to `main`. |

### Release pipeline (`scripts/release.sh <version>`)

1. `swift build -c release`
2. Assemble `WindowPilot.app` (binary, resources, updated `Info.plist` versions, embed `Sparkle.framework` into `Contents/Frameworks/`)
3. Codesign inner-first with Developer ID Application (HONGBO ZHOU SBU743JJ9S), hardened runtime: Sparkle's `XPCServices/*.xpc`, `Autoupdate`, `Updater.app`, then `Sparkle.framework`, then the main executable, then the bundle
4. `hdiutil create` → DMG
5. `notarytool submit --keychain-profile "notarytool" --wait` → `stapler staple`
6. Run Sparkle's `generate_appcast` (tools downloaded/cached from the matching Sparkle release tarball) to EdDSA-sign the DMG and regenerate `appcast.xml`; rewrite the enclosure URL to the GitHub Releases asset URL; inject the release notes (from the GitHub release body) as the item `<description>`
7. Commit + push `appcast.xml`; `gh release create/upload` the DMG

### Error handling

- Download/signature/install failures: handled by Sparkle's built-in UI.
- Scheduled check failures: silent (Sparkle default). Manual check failures: Sparkle shows an alert. Consistent with the project's "explicit error states" rule — user-initiated actions always surface errors.

### Constraints / risks

- App is un-sandboxed, Developer ID distribution → simplest Sparkle scenario (no XPC installer config needed).
- Existing v1.2.1 users do not have Sparkle; they must manually download v1.3.0 once. Auto-update applies from v1.3.0 onward.
- Signing order matters: unsigned Sparkle helpers fail notarization. The script encodes the correct order.
- `raw.githubusercontent.com` serves `text/plain`; Sparkle accepts this.

### Verification

- `swift build && swift test` clean.
- End-to-end test: build a fake v1.3.1, serve a local appcast over `http://localhost` (with `SUFeedURL` override via user defaults), confirm check → prompt → install → relaunch replaces the bundle.
- Notarize a real v1.3.0 DMG and confirm `spctl -a -t open --context context:primary-signature` passes and Sparkle accepts the EdDSA signature.

## Part 2 — High-Priority Fixes

Each fix is independently verifiable; all target the defects confirmed in the 2026-07-15 review.

### F1. `ScreenshotCache` data race
`ScreenshotCache.swift:39` writes `cache` on a background queue while the main thread reads/writes it. **Fix:** serialize all dictionary access through a private lock (`NSLock` or `os_unfair_lock`); `refreshAsync` keeps its background capture but funnels cache mutation through the lock. Unit test: concurrent read/write hammer test under TSan locally.

### F2. Recent tab keyboard navigation dead
`RecentView` implements arrow/Enter navigation but never becomes first responder. **Fix:** `PilotPanel.switchToTab(recent: true)` (and `show()` when opening on the Recent tab) calls `window?.makeFirstResponder(recentView)`. Acceptance: hotkey → arrows move selection → Enter focuses window, no mouse.

### F3. Search re-enumerates on every keystroke
`AppDelegate.swift:413-419` calls `enumerator.enumerate()` per keystroke. **Fix:** cache the `[AppNode]` snapshot taken in `showPanel()`; `onSearchChanged` filters that snapshot via `SearchFilter.filter`. Snapshot refreshes on each panel open. Acceptance: typing performs zero CGWindowList/AX calls.

### F4. Synchronous main-thread capture on selection
`AppDelegate.swift:363` captures full-resolution screenshots on the main thread whenever tree selection changes (including selection changes caused by filtering). **Fix:** show cached image (or placeholder) immediately; capture on a background queue; deliver via main queue only if the selection is still the same window. Reuses the existing `refreshAsync` pattern.

### F5. `WindowFocuser.focus()` always returns `true`; callers discard results
`WindowFocuser.swift:119` hardcodes success; `AppDelegate` uses `_ =` everywhere. **Fix:** return an actual outcome (AX window resolved + raise action succeeded). On failure, `AppDelegate` surfaces an explicit transient state (small floating HUD: "Couldn't focus window — it may have closed") instead of silently dismissing. Applies to `focus`, `close`, `minimize` call sites.

### F6. Carousel blocks the main thread capturing all thumbnails
`AppDelegate.swift:180-194` synchronously captures every uncached window before showing the carousel. **Fix:** show the carousel immediately with cached thumbnails/placeholders, then fill in via `screenshotCache.refreshAsync` with a completion that updates visible cards.

## Out of scope (follow-ups, not this release)

- ScreenshotCache eviction/LRU bound and `WindowActivityTracker` pruning (medium-priority review finding)
- ScreenCaptureKit migration (CGWindowListCreateImage deprecation)
- Routing the 3 raw `CGWindowListCopyWindowInfo` calls through `WindowEnumerator`
- Deleting `windowpilot-fixes/`, `⌘K` placeholder text, "Untitled" naming fallback

## Testing strategy

- Existing `swift test` suites must stay green.
- New Core-tier unit test for `ScreenshotCache` thread-safety (F1).
- Manual verification checklist per fix (F2–F6 are UI-behavioral) + the Sparkle end-to-end local-appcast test.
