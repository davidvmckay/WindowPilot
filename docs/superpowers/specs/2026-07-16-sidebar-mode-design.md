# Sidebar Mode (Optional Persistent Work Strip) — Design

**Date:** 2026-07-16
**Status:** Approved direction; sidebar is an OPTIONAL mode, off by default. Summon panel + carousel remain the primary interactions.

## Problem

The tool's own author doesn't reach for it. Diagnosis (user interview):

1. **Recall-based entry.** The product principle is "recognition over recall", but the entry point (remember a hotkey) is itself recall-based — the habit loop never forms.
2. **Interaction cost.** Hotkey → panel → find → Enter loses to a Dock click for many switches.
3. **Unaddressed mapping cost.** The expensive step in switching happens *before any key is pressed*: translating the task in your head ("that PR") into app → window → screen location. Existing switchers (ours included) only optimize the execution step.

**First principle applied:** spatial memory eliminates mapping cost. Things that stay in a fixed, visible position stop requiring lookup (keyboard keys, bookshelves). Therefore: a persistent strip with **stable positions** — and stability rules that protect it.

User context: multi-monitor setup (pixel cost affordable); work is *partially* grouped — 2–3 long-lived high-frequency windows plus task-flowing ones.

## Mode Positioning (user requirement)

- Sidebar is an **optional mode**, NOT the default. Ships **disabled**; toggled via status menu ("Show Sidebar") and Preferences. Can be collapsed (8px hot edge) or fully turned off at any time.
- The summon panel (Option+Space) and carousel remain unchanged and primary.

## Form & Layout

Vertical strip, ~70pt wide, right edge of a user-chosen display (default: main). Three zones:

1. **📌 Pinned slots** (top) — long-lived high-frequency windows. Fixed positions, never auto-reordered.
2. **Dynamic task zone** (middle) — current-task windows, cap 5.
3. **Overflow** (bottom, "⋯") — opens the existing PilotPanel for cold lookup.

Always on top (`.floating`), visible on all Spaces.

## Differentiation from the Work Area

- **Visual:** HUD blur material (same family as existing panels), rounded, translucent, small scale — reads as instrument panel, not content.
- **Behavioral:** non-activating panel; clicking a slot switches windows but the strip itself never takes focus, never appears in Cmd-Tab, and is filtered from its own window list (own-PID filter already exists).
- **Spatial:** edge-hugging overlay. macOS has no public API to reserve screen space (Dock-style); the strip overlaps. Auto-hides when the frontmost app on its display is fullscreen. Collapsible to an 8px hot edge (mouse-touch expands).

## Slot Model (spatial-stability rules)

- **Pinned slots:** pin via drag from dynamic zone or right-click. Persisted across restarts by (bundleID, title-heuristic) since windowIDs don't survive app restarts. If the window closes, the slot dims to the app icon; click activates the app. Unpin via right-click.
- **Dynamic zone — parking-lot semantics (key decision):** a window occupies a position until evicted; focus changes never reshuffle. Only insertion (into an empty position) and eviction (LRU replaced in place) change the layout. This trades "most recent on top" for the position stability that spatial memory requires.
- **Current-window highlight:** the slot of the frontmost window gets an accent border (reuses the existing 2s focus tracker).

## Interactions

- Click slot → focus window (full WindowFocuser path incl. Space switching).
- Hover → enlarged live preview tooltip (ScreenshotCache).
- Drag dynamic → pinned zone = pin. Right-click = pin/unpin, close, minimize.
- **Phase 2 (out of scope now):** per-slot global hotkeys (Hyper+1..N).

## Architecture

- `Sources/UI/SidebarPanel.swift` — non-activating NSPanel; zones + slot layout.
- `Sources/UI/WindowCardView.swift` — extracted shared card view (also de-duplicates CarouselCardView / RecentCardView, a known review finding).
- `Sources/Core/PinStore.swift` — pin persistence (JSON in Application Support); pure logic, no AppKit, unit-tested.
- `Sources/Core/SlotAllocator.swift` — parking-lot placement/eviction logic; pure, unit-tested.
- Reused untouched: WindowEnumerator, WindowActivityTracker, ScreenshotCache, WindowFocuser.
- AppDelegate: mode lifecycle (menu toggle, preference), display-change repositioning.

## Refresh Strategy (persistent UI must not be a persistent cost)

- Slot thumbnail refreshes only when its window **loses focus** (content is "final" at that moment) and lazily on strip expand; all captures background-queued via the established refreshAsync pattern.
- No polling beyond the existing 2s focus tracker.

## Risks & Spike (do first)

1. **`.canJoinAllSpaces` conflict:** persistent visibility needs it, but it previously broke Space-switch animations (why panels use `.moveToActiveSpace`). **One-day spike:** persistent non-activating panel + canJoinAllSpaces + focus/Space-switch paths on macOS 16. Fallback: re-attach the strip on active-Space-change notifications.
2. No Screen Recording permission → icon+title slots (existing placeholder pattern).
3. Display unplug/re-arrangement → reposition to surviving display, notification-driven.

## Error Handling

- Focus failures surface via the existing ToastHUD path.
- Dead pinned windows degrade to app-activation, never silent no-ops.

## Testing

- Core-tier unit tests: PinStore (persist/restore/match heuristic), SlotAllocator (insertion, eviction-in-place, no-reshuffle invariants).
- Manual checklist: focus-steal-free clicking, fullscreen auto-hide, collapse/expand, Space-switch behavior (spike criteria), mode on/off from menu.

## Out of Scope

- Per-slot global hotkeys (phase 2 after form validation).
- Secondary-display window wall (approach B — possible future complement).
- Reserving screen space Dock-style (no public API).

## Success Criteria

After two weeks of self-use with the mode enabled: sidebar clicks form a meaningful share of the author's switches, and switching to a pinned/parked window no longer involves a conscious "where is it" step. If the mode stays off, the form factor hypothesis is falsified — revisit approach C (per-slot hotkeys without UI).
