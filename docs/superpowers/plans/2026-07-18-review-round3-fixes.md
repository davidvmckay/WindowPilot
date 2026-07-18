# Review Round 3 Fixes (post-1.4.2 external review)

All items verified against main@340f90a. Branch: `fix/review-round3`.

## Global Constraints

- Sources/Core/ must NOT import AppKit; CG calls stay behind Core wrappers.
- Focus/destructive ops never act on a non-exact target; explicit outcomes
  (truthful return values) over misleading ones.
- Build `swift build`; suites green: WindowPilotCoreTests (115+),
  TreeSelectionTests (6), CardAccessibilityTests (13), RecentHeightFitTests
  (2), RecentViewEmptyStateTests (2).
- Commit per task; message ends with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Match style; no drive-by refactors.

## Task 1: Strict ID resolution for windowID != 0 + truthful CGS-path result

**Confirmed (P1):** `resolution(policy: .focus)` (Sources/Core/WindowFocuser.swift)
returns `.matched` for ANY title match even when `windowID != 0` — so if the
selected window closed and a same/similar-titled sibling exists in the app,
`focus()`/`raiseWindow()` AXRaise the sibling. Contradicts the "closed
windows fail explicitly" contract.
**Confirmed (P2, pre-ticketed):** the cross-Space path where CGS knows the
window but AX omits it performs the CGS/SLPS switch (correct) but then
`guard let axWindow else { return false }` → spurious "Couldn't focus" toast
despite the switch having worked.

**Requirements:**
1. Rework the `.focus` policy: when `windowID != 0`, require `idMatchFound`
   (NO title fallback — title matching applies only to `windowID == 0`
   callers like the CLI convenience overloads, where any title match remains
   acceptable). Update the pure `resolution` table + its tests (the cases
   asserting title-fallback-with-ID must flip to `.failed`).
2. `focus()` becomes truthful about the CGS-only path: when
   `axWindow == nil` but `windowKnownToCGS(windowID)` is true, the CGS/SLPS/
   frontmost side effects run (unchanged) and focus() returns **true**
   (best-effort success; log `[WP] focus: CGS-only path for wid=… (AX
   omitted the window)`). The AXRaise is skipped (nothing to raise via AX).
   When both AX and CGS miss: no side effects, return false (unchanged).
   Callers' toasts then fire only on genuine failure.
3. `raiseWindow`/`reEnterFullScreen` inherit requirement 1 automatically via
   the shared policy — verify and state in the report that with a stale ID
   and a same-titled sibling they now no-op (no wrong-window raise, no
   wrong-window fullscreen).
4. Think through the CLI: `cmdSwitch` passes real IDs (windowID != 0), so a
   stale ID between enumerate and focus now fails instead of title-matching
   — correct per contract. The `focus(pid:windowTitle:)` overloads
   (windowID == 0) keep title semantics for compatibility.
5. Tests (TDD): updated resolution table cases (id-set+title-only → failed;
   id-set+id-match → matched; id-zero+title → matched); a focus()-level
   test is impossible headless (AX) — the pure table is the seam, per
   established convention.

**Files:** Sources/Core/WindowFocuser.swift, Tests/CoreTests/WindowFocuserTests.swift

## Task 2: Allocate the focus generation at selection intent, not inside performFocus

**Confirmed (P2):** two 0.15s pre-delays (Sources/App/AppDelegate.swift:285
and :644 — read both contexts; one is the carousel modifier-release path,
one the panel path) schedule `performFocus` later, but `focusGeneration`
increments only INSIDE `performFocus`. Rapid sequence: panel-select A
(T0, fires T0+150ms) → sidebar-select B (T0+50ms, gen N+1, runs) → A's
delayed call lands (T0+150ms) and takes gen N+2 — the OLD request
supersedes the NEW one and cancels B's in-flight chains.

**Requirements:**
1. Move generation allocation to selection intent: a small
   `beginFocusRequest() -> UInt64` (increments and returns
   `focusGeneration`) called SYNCHRONOUSLY at every user-initiated
   selection site that leads to performFocus — the two 0.15s-delayed sites
   call it BEFORE scheduling, capture the gen, and the delayed closure
   guards `gen == focusGeneration` before calling performFocus; immediate
   callers (sidebar click, etc.) call it inline.
2. `performFocus(_ windowInfo:, generation:, onSuccess:)` — takes the gen
   as a parameter instead of self-incrementing. All internal guards
   (`focusSuperseded(gen)`) work unchanged against the passed gen. Map
   EVERY performFocus call site (grep) and route each through
   beginFocusRequest exactly once — no site may call performFocus without a
   fresh intent gen, and none may bump twice (double-bump would
   self-supersede).
3. Net behavior: B (newer intent) always supersedes A (older intent)
   regardless of scheduling delays; a delayed A whose gen is stale no-ops
   before performFocus even runs.
4. No headless seam for the timing itself; the report enumerates every
   call site with its intent-allocation point. Suites stay green.

**Files:** Sources/App/AppDelegate.swift

## Task 3: Actively hide the sidebar when a coverer is confirmed on windowless ticks

**Confirmed (P1):** `clearFullscreenSuppressionIfUncovered` (AppDelegate,
windowless ticks) clears suppression when the strip's display is uncovered
but does NOTHING when covered — it can only prevent wrong re-shows. A
VISIBLE strip stays visible when the user enters an AX-less fullscreen app
(games, Metal): every tick is windowless (no AX focused window), covered →
hold → strip overlays the game indefinitely.

**Requirements:**
1. Rename/extend the helper to a symmetric
   `syncFullscreenSuppressionFromSnapshot()`: on windowless ticks (same
   three call sites), fetch the on-screen snapshot (own PID excluded, as
   now) and:
   - covered (layer-0 window covering the strip's display) →
     `sidebar.setHiddenForFullscreen(true)`;
   - uncovered → `setHiddenForFullscreen(false)` (existing behavior).
   setHiddenForFullscreen is idempotent/cheap in both directions (orderOut
   when hidden; the wasSuppressed||!isVisible gate prevents z-order churn on
   repeated clears) — verify no oscillation: covered ticks repeat
   `setHiddenForFullscreen(true)` → orderOut on an already-ordered-out
   panel is a no-op; state converges.
2. The own-PID exclusion stays (the strip itself must never count as the
   coverer). The focused-window path (AX available) is untouched.
3. Update the site comments: the windowless path is now a full mirror of
   the AX path, driven by CG evidence.
4. Tests: the pure predicate is already covered; no new headless seam —
   report documents the state table (visible+game-launch → hidden ≤2s;
   hidden+game-quit → visible ≤2s; both directions).

**Files:** Sources/App/AppDelegate.swift

## Task 4: release.sh — full preflight before build

**Confirmed (P1):** upfront validation covers only VERSION format and
Version.swift cleanliness; the branch==main check runs at push time (after
build/sign/notarize). A dirty tracked file (e.g. AppDelegate.swift) compiles
into the shipped DMG while the tag's source lacks it — reproducibility break.

**Requirements:**
1. Extend the upfront block (before anything builds or stamps):
   - current branch must be `main` (`git rev-parse --abbrev-ref HEAD`);
     clear abort message otherwise.
   - the ENTIRE tracked tree must be clean: `git diff --quiet` AND
     `git diff --cached --quiet` (this supersedes the Version.swift-only
     check — keep the specific error message for the Version.swift case if
     cheap, else one general message). Untracked files are deliberately
     ignored (WindowPilot.app/ bundle skeleton and docs drafts are
     untracked by design).
2. The late wrong-branch check (push stage) becomes redundant — keep it as
   belt-and-suspenders (it guards against branch switches mid-run); add a
   one-line comment saying so.
3. Verification (NEVER push/tag/gh): `bash -n`; DRY_RUN from this branch →
   must now abort UPFRONT with the branch message (observe it); dirty-tree
   simulation (touch a tracked file with a real edit, run, expect abort,
   restore); full DRY_RUN happy path must be deferred to a note (it can't
   run from this branch anymore — state that explicitly and verify the
   upfront logic by temporarily simulating branch name if feasible, e.g.
   via a scratch clone/worktree on a local main).
4. `swift test --filter WindowPilotCoreTests` untouched-green.

**Files:** scripts/release.sh
