# Preview Side Panel — Resizable

**Date:** 2026-07-04
**Status:** Approved
**Owner:** ginwa
**Related task:** kanban `RESIZE PREVIEW` (`task_1783171580865`)

---

## Overview

The right-side preview panel in the chat (`PreviewSidePanel.vue`) is currently fixed at `w-[480px]` when expanded. Users want to drag the panel's left edge to make it wider (e.g. for wide markdown / code blocks) or narrower. The chosen width must persist across page reloads.

**Result:** the panel grows/shrinks via a 1px-wide drag handle on its left edge, with no upper bound so it can fill the screen, and the width is remembered between sessions.

---

## Decisions (2 questions, both approved)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Persistence | **Persist** to `localStorage` (`nalar-preview-panel-width`). Drag → reload keeps the new width. |
| 2 | Upper width bound | **None.** Panel can grow to the full viewport width. The main chat column (which has `flex-1 min-w-0`) shrinks to absorb the rest; user can collapse the preview via the existing chevron to bring the chat back. |

---

## Architecture

### Layout context

The panel lives at the rightmost position of the outer `<div class="flex h-full w-full">` in `ChatView.vue:2044`. Its only inline flex sibling is the main chat column (`flex-1 min-w-0` at line 2046). The `SubAgentPeekPanel` is a `position: fixed` modal overlay (`z-index: 50`) — not an inline flex sibling — so it doesn't compete for horizontal space.

When the preview panel widens, the chat column narrows. When the preview goes wider than the chat can tolerate, the chat becomes 0-wide (hidden). The user recovers by clicking the existing collapse chevron `◀` in the preview header, which sets `width: 32px` (the `w-8` collapsed state).

### Component changes — `src/apps/desktop/src/components/PreviewSidePanel.vue`

Self-contained: the component owns its width state, persistence, and drag listeners. **No parent (`ChatView.vue`) changes.** No backend changes. Pure UI.

Mirrors the `RightSidebar.vue` resize pattern (`src/apps/desktop/src/components/RightSidebar.vue:20-64` + handle at line 207-211), which is the closest analog (right-side panel → left-edge resize handle → local `localWidth` ref + clamping + `cursor-ew-resize`).

### Width bounds

| Constant | Value | Why |
|---|---|---|
| `DEFAULT_WIDTH` | `480` | Matches current behavior — no behavior change for first-time users |
| `MIN_WIDTH` | `240` | Below this the markdown / code content becomes unreadable; matches `RightSidebar`'s 200 floor with a small margin for the preview header / tab strip |
| `MAX_WIDTH` | `Infinity` (no clamp) | User explicitly requested "full screen" with no limit |

### localStorage

Key: `nalar-preview-panel-width`. Stored as a decimal string of the integer pixel width (matches `nalar-right-sidebar-width` at `stores/sidebar.ts:7`).

- **On mount** — read the key. If it's an integer ≥ `MIN_WIDTH`, use it; otherwise use `DEFAULT_WIDTH`.
- **On drag release** (`mouseup`) — write the current `localWidth` to the key. **One write per gesture** (not 60+ writes per second during the drag). Matches `AppLayout.vue:585-604` (kanban-column resize persist).
- **Errors** — wrap `localStorage.setItem` in a `try/catch` so a private-mode or quota-exceeded scenario doesn't break the in-memory drag (same pattern as `AppLayout.vue:599-603`).

### Interaction

**Handle** — 1px-wide vertical bar absolutely positioned on the **left edge** of the panel (panel is on the right; dragging left grows it):

```vue
<div
  v-if="!isCollapsed"
  data-testid="preview-resize-handle"
  class="absolute top-0 left-0 h-full w-1 cursor-ew-resize z-10 transition-colors"
  :class="isResizing ? 'bg-[var(--color-violet)]/50' : 'bg-transparent hover:bg-[var(--color-violet)]/30'"
  @mousedown="startResize"
/>
```

Colors match `RightSidebar.vue:208-211` (violet accent, transparent at rest, 30% on hover, 50% during drag).

**Drag math** — `delta = resizeStartX - clientX` (panel is on right, handle is on left edge → moving cursor left = panel grows). Same formula as `RightSidebar.vue:45`.

```ts
const newWidth = Math.max(MIN_WIDTH, resizeStartWidth.value + delta);
// no upper clamp — width grows unbounded
localWidth.value = newWidth;
```

**Document-level listeners** — the handle's `mousedown` adds `mousemove` + `mouseup` on `document` (NOT on the handle itself — the cursor can outrun the handle during a fast drag, and listening on `document` is the only way to catch every move). Pattern matches `Sidebar.vue:200-225` and `AppLayout.vue:552-604`.

During drag:
- `document.body.style.cursor = 'ew-resize'`
- `document.body.style.userSelect = 'none'`

On release, both are restored to `''`.

**Cleanup** — `onUnmounted(stopResize)` removes document listeners even if a drag is in progress. Pattern matches `Sidebar.vue:227-229`. Prevents orphan listeners (a known Vue 3 footgun — without cleanup, dragging across a route change would leave the listeners behind).

### Template change

Replace `PreviewSidePanel.vue:155`:

```vue
:class="isCollapsed ? 'w-8' : 'w-[480px]'"
```

with:

```vue
:style="isCollapsed ? undefined : { width: localWidth + 'px' }"
:class="isCollapsed ? 'w-8' : 'shrink-0'"
```

(`shrink-0` so flex doesn't try to grow the panel; the explicit `width` does the sizing. `w-8` stays for collapsed — drag handle is hidden in collapsed mode because there's nothing to drag.)

Insert the handle `<div>` at the top of the `<template v-else>` block (right after the existing header `<div>`) — only rendered when expanded.

---

## Tests

5 new tests in `src/apps/desktop/src/__tests__/previewSidePanel.spec.ts`, modeled on `src/apps/desktop/src/__tests__/AppLayout.kanban.spec.ts:384-468` (kanban-column resize persistence test pattern). Each test runs in isolation via `localStorage.clear()` in `beforeEach`.

| # | Test | What it verifies |
|---|---|---|
| 1 | Default width is 480px when no `nalar-preview-panel-width` in localStorage | The `loadPreviewPanelWidth()` helper falls back to `DEFAULT_WIDTH` |
| 2 | Width is loaded from localStorage on mount | Pre-seed `'600'` → mount → assert `style.width === '600px'` |
| 3 | Mousedown on the handle → mousemove left → mouseup persists the new width | Dispatch the events on `document.body` (jsdom convention), assert `localStorage.getItem('nalar-preview-panel-width')` matches the new width and the panel's inline `style.width` updates |
| 4 | Width clamps at `MIN_WIDTH = 240` when dragged past the bound | Drag the handle RIGHT by 5000px (would otherwise produce a negative width) → assert `style.width === '240px'` |
| 5 | The resize handle has `cursor-ew-resize` and is hidden when collapsed | After collapse toggle, `wrapper.find('[data-testid="preview-resize-handle"]').exists() === false` |

The existing 12 tests in `previewSidePanel.spec.ts` continue to pass — none of them depend on the panel's width, and the new width logic only activates when the user drags. The `class="w-[480px]"` removal is replaced by `:style="{ width: localWidth + 'px' }"` which produces `width: 480px` by default — same rendered width, different mechanism.

---

## Files touched

| File | Change |
|---|---|
| `src/apps/desktop/src/components/PreviewSidePanel.vue` | Add `localWidth` ref, MIN/MAX/DEFAULT constants, `startResize`/`handleResize`/`stopResize` handlers, `loadPreviewPanelWidth`/`savePreviewPanelWidth` helpers, replace `w-[480px]` with inline style, add resize handle `<div>`. ~40 lines added. |
| `src/apps/desktop/src/__tests__/previewSidePanel.spec.ts` | Add 5 tests + `localStorage.clear()` in `beforeEach`. ~100 lines added. |

**No other files touched.** No `ChatView.vue` change. No new files. No backend changes. No new dependencies.

---

## YAGNI — explicitly NOT doing

- **Emit `resize` event to parent** — self-contained is simpler and matches `RightSidebar`'s component-level state model. If a future feature needs the parent to know the width (e.g. layout-coordinate sharing with other panels), add the emit then.
- **Shared `useResizablePanel` composable** — would be useful if a second consumer appeared (e.g. SubAgentPeekPanel, settings drawer). No second consumer today — YAGNI.
- **Touch events** — the established `Sidebar.vue` / `RightSidebar.vue` / `AppLayout.vue` resize handlers all use mouse-only. Adding touch would require `TouchEvent` polyfills and `passive` listener handling; defer until the product explicitly targets touch.
- **Double-click to collapse** — would be a nice-to-have but is out of scope. The existing chevron button already handles collapse.
- **Snap-to-default on double-click** — same. Defer.
- **Persisting collapsed state separately** — the collapsed state is owned by the parent (`ChatView.vue`) via `v-model:collapsed` / `previewPanelCollapsed` and `previewPanelDismissed`. The component just respects `props.collapsed`. No change needed here.

---

## How to verify (after implementation)

1. `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20` — must show `vite build` success + no `vue-tsc` errors
2. `cd src/apps/desktop && timeout 120 bunx vitest run previewSidePanel 2>&1 | tail -n 20` — must show 17/17 pass (12 existing + 5 new)
3. **Manual smoke** — open the desktop app, trigger a `show_preview` tool call (e.g. ask the agent "show me a markdown preview"), drag the left edge of the preview panel left → panel grows, chat shrinks. Drag right → panel shrinks, chat grows. Drag all the way left → preview fills the screen, chat is hidden. Click the chevron → preview collapses to 32px. Reload the page → preview is back at the dragged width.

---

## Reference files

- `src/apps/desktop/src/components/RightSidebar.vue:20-64` + `:style="{ width: localWidth + 'px' }"` at line 204 + handle at line 207-211 — closest analog, proven resize pattern
- `src/apps/desktop/src/components/Sidebar.vue:192-229` — `startResize`/`handleResize`/`stopResize` template with `onUnmounted` cleanup
- `src/apps/desktop/src/components/AppLayout.vue:505-604` — kanban-column resize with persistence-on-release pattern
- `src/apps/desktop/src/stores/sidebar.ts:7, 13-15, 42-62` — localStorage + Pinia pattern for persisted width (we inline the same pattern instead of using the store, for self-containment)
- `src/apps/desktop/src/__tests__/AppLayout.kanban.spec.ts:384-468` — test pattern for the drag-persist flow