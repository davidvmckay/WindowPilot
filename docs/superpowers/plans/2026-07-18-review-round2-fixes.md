# Review Round 2 Fixes (post-523784b external review)

All items verified against source before planning. Branch: `fix/review-round2`.

## Global Constraints

- Sources/Core/ must NOT import AppKit. All CGWindowList calls go through
  Core wrappers (WindowEnumerator or the new snapshot API from Task 5) —
  this plan EXTENDS that rule's enforcement; do not add new raw calls.
- Focus/destructive ops must never act on a non-exact target; explicit
  failure (return false / toast) over silent wrong-window action.
- Build `swift build`; suites must stay green: WindowPilotCoreTests (94+),
  TreeSelectionTests (6), CardAccessibilityTests (13), RecentHeightFitTests (2).
- Commit per task; message ends with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Match surrounding style; no drive-by refactors beyond each task's scope.

## Task 1: Remove findWindow's arbitrary-window fallbacks; gate focus side effects

**Confirmed:** `WindowFocuser.findWindow(matching:)` (Sources/Core/WindowFocuser.swift:630)
contains `if title == "Untitled" && !windows.isEmpty { return windows[0] }` and a
final any-fullscreen-window fallback — both return windows unrelated to the
target. Post-Task-4, "Untitled" titles are common (and universal without
Screen Recording), so focus/raiseWindow/reEnterFullScreen can act on the
wrong window despite the earlier fallback removals. Additionally
`focus()` (:110-156) runs CGS switchDisplayToWindowSpace + SLPS +
kAXFrontmostAttribute BEFORE the axWindow nil-guard, so an unresolvable
target still switches Space / activates the app.

**Requirements:**
1. In `findWindow(matching:)`: DELETE the `title == "Untitled"` first-window
   branch and DELETE the trailing any-fullscreen-window loop. Keep: exact
   title match, then the bidirectional substring match (title drift for
   real titles). Additionally guard the substring pass:
   skip it entirely when `title == "Untitled"` or title is empty
   ("Untitled".contains matching would false-positive on real "Untitled"
   AX titles — exact match already handled those).
2. In `focus()`: gate the side-effect block (`switchDisplayToWindowSpace` +
   SLPS + makeKeyWindow + kAXFrontmost) on
   `axWindow != nil || windowKnownToCGS(windowID)` where
   `windowKnownToCGS` is a small private helper: windowID != 0 &&
   `CGSCopySpacesForWindows` returns a non-empty space list for it. WHY the
   OR: windows on other Spaces can be omitted from kAXWindowsAttribute (a
   documented macOS AX limitation) — for those, CGS knows the window and
   the CGS/SLPS layers are what actually focus it; gating purely on
   axWindow would break cross-Space focus. A target unknown to BOTH AX and
   CGS is dead → no side effects, return false.
3. Tests (TDD, CoreTests): findWindow is private — test through the pure
   `resolution` decision where applicable, and add a seam ONLY if cheap
   (e.g. make findWindow internal for @testable): cases — "Untitled"
   query with no exact match → nil (not first window); fullscreen window
   present but title unrelated → nil; exact match still wins; substring
   drift still matches for non-Untitled titles.

**Files:** Sources/Core/WindowFocuser.swift, Tests/CoreTests/WindowFocuserTests.swift

## Task 2: Cancellation for the focus flow (focusGeneration)

**Confirmed:** `performFocus` (Sources/App/AppDelegate.swift ~639+) spawns
asyncAfter chains and polls with no cross-invocation cancellation. Rapid
A→B clicks run both chains; A's delayed focus/raise/reEnter can fire after
B succeeded, yanking focus back or fullscreening the wrong context.

**Requirements:**
1. Add `private var focusGeneration: UInt64 = 0` (same pattern as the
   existing `previewGeneration`). `performFocus` entry: `focusGeneration &+= 1;
   let gen = focusGeneration`.
2. EVERY asynchronous continuation inside performFocus — each
   `DispatchQueue.main.asyncAfter` body, each `poll` `until:` closure's
   companion `then:` body, the Ctrl+Arrow press loop bodies, and the
   deferred `onSuccess` dispatch — begins with
   `guard gen == self.focusGeneration else { return }` (for the press loop:
   also stop scheduling further presses). The synchronous prefix before the
   first async hop needs no guard.
3. Behavior: a newer performFocus invalidates ALL older pending work. No
   other logic changes; keep `[WP]` logs (add one `[WP] focus gen=N
   superseded` style log on guard trips if it fits the idiom).
4. No honest headless test seam (GUI/timing) — deliverable is the guard
   discipline + clean build + green suites; report lists every guarded
   continuation site (there should be ~9-12; enumerate them).

**Files:** Sources/App/AppDelegate.swift

## Task 3: release.sh hardening

**Confirmed:** the stamp block seds + commits Version.swift before any
build/sign success; a mid-release failure leaves a version commit with no
release. DRY_RUN's `git checkout --` restore would also discard
PRE-EXISTING uncommitted user edits to Version.swift. (The "two version
sources" claim was adjudicated NOT a defect — both files derive from the
single ${VERSION} argument — do not "fix" that.)

**Requirements:**
1. Upfront validation (immediately after VERSION is bound): abort with a
   clear message unless (a) `VERSION` matches `^[0-9]+\.[0-9]+\.[0-9]+$`,
   (b) `Sources/CLI/Version.swift` has no uncommitted changes
   (`git diff --quiet -- Sources/CLI/Version.swift` AND
   `git diff --cached --quiet -- Sources/CLI/Version.swift`), else the
   stamp/restore logic could commit or destroy user edits.
2. Restore-on-failure: capture the file's original content once
   (`cp` to a mktemp path), install a `trap` that restores it on ERR/EXIT
   for DRY_RUN runs and on ERR (abort) for real runs BEFORE the commit has
   happened; after the stamp COMMIT succeeds in a real run, disarm the
   restore (the commit is now the source of truth).
3. Move the stamp COMMIT from before-build to after notarize+staple
   succeed and BEFORE the `git push origin HEAD:main` (the pushed/tagged
   commit must still carry the stamp — that invariant from the prior fix
   MUST survive). sed still runs before build (binary needs the stamp).
   Keep the `git diff --quiet` no-change guard and the
   `-- Sources/CLI/Version.swift` pathspec.
4. Verification: `bash -n`; full local DRY_RUN pipeline run
   (`FEED_URL=… DOWNLOAD_URL_PREFIX=… SKIP_NOTARIZE=1 DRY_RUN=1
   scripts/release.sh 9.9.9`) → completes, no commits created, tree clean
   after; plus a deliberate mid-run failure simulation (e.g. run with an
   invalid version, and simulate a build failure by temporarily breaking a
   source file in a scratch check — restore everything) demonstrating the
   trap restores the file. NEVER push, tag, or run gh.

**Files:** scripts/release.sh

## Task 4: RecentView empty-state cleanup + dead code removal

**Confirmed:** `rebuildGrid` (Sources/UI/RecentView.swift:160) removes only
`cardViews`; the "No recent windows yet" label is added per empty reload
and never removed — it survives behind cards after data arrives and stacks
on repeated empty reloads. Dead members confirmed declaration-only:
`infoStack`/`appLine` (RecentView:265-266) and the
`CGSMoveWindowsToManagedSpace` @_silgen_name declaration
(WindowFocuser.swift:33-34).

**Requirements:**
1. Track the empty-state label in a `private var emptyStateLabel: NSTextField?`;
   `rebuildGrid` removes it (removeFromSuperview + nil) at the top alongside
   card removal, before deciding whether to re-add.
2. Delete `infoStack`, `appLine`, and the `CGSMoveWindowsToManagedSpace`
   declaration.
3. Test: extend an existing headless suite (RecentHeightFitTests file or
   TreeSelectionTests style) — reload empty → reload with data → assert no
   empty-label in containerView subview tree; reload empty twice → exactly
   one label.

**Files:** Sources/UI/RecentView.swift, Sources/Core/WindowFocuser.swift,
Tests/IntegrationTests/*

## Task 5: CG-confirmed windowless suppression clear

**Confirmed:** the windowless early-return paths in `trackFocusedWindow`
now clear `suppressedForFullscreen` unconditionally. For apps with NO AX
surface at all (games, some Metal fullscreen apps), kAXFocusedWindowAttribute
fails EVERY tick while a fullscreen window is genuinely covering the
display → the strip un-hides and overlays fullscreen content persistently.

**Requirements:**
1. Add to Core a wrapped snapshot query (this becomes the shared wrapper
   Task 6 extends): `public enum WindowSnapshot` in a new
   Sources/Core/WindowSnapshot.swift with
   `static func onScreenWindows() -> [WindowSnapshotEntry]` (one
   CGWindowListCopyWindowInfo(.optionOnScreenOnly + excludeDesktopElements)
   fetch; entry: id, pid, bounds CGRect, layer) and a convenience
   `static func hasLayerZeroWindowCovering(displayFrame: CGRect,
   coverage: CGFloat = 0.97) -> Bool` (CG top-left coords; caller passes a
   CG-space display frame). No AppKit.
2. In the three windowless clear sites: replace the unconditional
   `sidebar?.setHiddenForFullscreen(false)` with: clear ONLY if
   `!WindowSnapshot.hasLayerZeroWindowCovering(displayFrame: stripDisplayCGFrame)`;
   otherwise HOLD the current state (do nothing). Compute the strip's
   display frame in CG coordinates (flip from the NSScreen frame the same
   way the existing suppression helper flips the other direction — factor
   or mirror carefully; comment the coordinate convention).
3. Tests (CoreTests): `hasLayerZeroWindowCovering` decision logic — factor
   the coverage predicate pure (entries + display frame in, bool out) and
   test: covering layer-0 window → true; layer-0 at 50% → false; covering
   window on OTHER display → false; empty list → false.

**Files:** Sources/Core/WindowSnapshot.swift (new),
Sources/App/AppDelegate.swift, Tests/CoreTests/WindowSnapshotTests.swift (new)

## Task 6: Route remaining raw CG calls through the wrapper; dedupe per-tick fetches

**Confirmed:** raw `CGWindowListCopyWindowInfo` outside WindowEnumerator/
WindowCapture at: WindowFocuser.swift:445 (exitCurrentFullScreen),
AppDelegate.swift:436 (transient small-window check), AppDelegate.swift:504
(suppression helper). CLAUDE.md architecture rule 3 requires wrapping. The
focus-change tick also fetches the window list twice (suppression helper +
transient check).

**Requirements:**
1. Extend `WindowSnapshot` (from Task 5) as needed:
   `static func entry(forWindowID:) -> WindowSnapshotEntry?` and an
   all-windows variant for the transient check (`.optionAll` fetch). Keep
   the API minimal — only what these three sites need.
2. Convert all three raw call sites to the wrapper. In
   `trackFocusedWindow`, fetch ONE all-windows snapshot per invocation and
   share it between the suppression helper and the transient check (pass
   it as a parameter) — eliminating the double fetch on focus-change ticks.
3. exitCurrentFullScreen keeps its exact semantics (on-screen fetch, layer-0,
   space membership check) — only the raw CG call moves behind the wrapper.
4. No new tests required beyond keeping suites green (pure plumbing), but
   the WindowSnapshot pure predicates from Task 5 must still pass.
5. Sweep check in report: `grep -rn CGWindowListCopyWindowInfo Sources/ |
   grep -v "WindowEnumerator\|WindowCapture\|WindowSnapshot"` returns empty.

**Files:** Sources/Core/WindowSnapshot.swift, Sources/Core/WindowFocuser.swift,
Sources/App/AppDelegate.swift
