# Plan: Preserve Kanban Horizontal Scroll Position When Opening/Closing Task Chat

## Goal

When the user opens or closes a kanban task's chat in the 3-column "kanban | chat" layout, the kanban's horizontal scroll position must be preserved. Currently, opening a task causes the kanban to scroll back to the leftmost column (scrollLeft = 0), forcing the user to manually re-scroll right to find their context after closing — a frustrating experience on a board with 8+ columns where the column of interest is often at the far right (e.g. "merged").

## Current State (verified, 2026-07-23)

### Symptom repro

1. User opens kanban board with many columns (e.g. "sprint 2" has 8 columns: `todo`, `in progress`, `in_review_planning`, `in_review_pull_request`, `on_hold`, `in_user_testing`, `done`, `merged`).
2. User scrolls the columns row right to reach the `merged` column (the 8th / rightmost). `scrollLeft` is on the order of 2500 px.
3. User clicks a task in `merged` → ChatView opens on the right (3-column layout appears).
4. **Bug**: the kanban's columns row scrolls to `scrollLeft = 0`. The user sees only `todo` and `in progress`, even though they were just looking at `merged`.
5. User clicks ✕ in ChatView header → ChatView closes, but the kanban is still at `scrollLeft = 0`. User must manually scroll right again to find their task in the kanban.

### Root cause

`AppLayout.vue` defines **two separate v-else-if branches** that mount `<KanbanView>` at **different DOM positions**:

- **3-column branch** (line ~1443, with `data-kanban-three-column`): rendered when `activeTask && activeWorkspaceItem.item_type === 'kanban' && activeTaskWorkspaceItemId === activeWorkspaceItem.id`. KanbanView is constrained to ~40% (or the persisted px width) on the left; ChatView fills the rest.
- **Standalone branch** (line ~1551): rendered when `activeWorkspaceItem.item_type === 'kanban'` and no task is selected. KanbanView fills the main area.

Both branches use the **same component with the same key** `:key="'kanban-' + activeWorkspaceItem.id"`, but Vue 3 does **not** reuse a component instance across v-else-if branches at different parents — the old DOM subtree is destroyed and a fresh one is mounted in the new parent. The fresh KanbanView's `overflow-x-auto` container starts at `scrollLeft = 0`.

Even if Vue did reuse the component, a secondary width-change effect kicks in:
- Standalone: `KanbanView` fills the main area → `overflow-x-auto` container is ~1500 px (full page width minus sidebar).
- 3-column: `KanbanView` is wrapped in a `<div :style="kanbanColumnStyle">` (40% or persisted px) → container is ~480 px.

The browser clamps `scrollLeft` to `min(currentLeft, scrollWidth - clientWidth)` whenever the content shrinks. With a saved `scrollLeft = 2500` and a new `max = scrollWidth - clientWidth ≈ 3520`, the value would actually fit, so the clamp doesn't bite. **The real culprit is the unmount/remount** that drops `scrollLeft` to 0 before any clamp.

There is currently **no preservation** of the kanban's horizontal scroll position across mounts. The columns-row `<div class="flex-1 min-h-0 overflow-x-auto overflow-y-hidden">` in `KanbanView.vue:465-470` is purely DOM-driven with no Vue state backing.

### What state IS preserved across mounts

`AppLayout.vue` and other components persist UI state to `localStorage`:
- `kanban-column-width` (resize-handle width, line 707-708)
- `session_cwd_<sessionId>` (per-session cwd, line 1271)
- `sidebar-width` (sidebar resize handle)
- Several legacy keys in `NalarSettings.vue`

This is the project's established pattern: UI state goes to `localStorage` (or Pinia, for state that needs reactivity). The kanban's horizontal scroll is the missing entry.

## Design Decisions

### D1 — Storage location: `localStorage` with per-kanban key

Use `localStorage` with key `kanban-scroll-<itemId>`. Matches the project's existing UI-state pattern (`kanban-column-width`, `session-cwd-*`, etc.). Two reasons localStorage over Pinia:
- Pattern precedent: the resize-handle width already uses `localStorage` for "ephemeral UI state that survives reload".
- localStorage survives page refresh; a Pinia store would need explicit persist-on-unload wiring.
- No need to add Map-shaped UI state to `workspaces.ts`.

Trade-off: localStorage writes are synchronous and somewhat slow (~5 ms each). Scroll events fire at 60 Hz, so we MUST debounce or write only on `scrollend` (see D5-D6).

### D2 — Restoration timing: `nextTick()` + `requestAnimationFrame()` after `onMounted`

`onMounted` fires once the component is in the DOM, but `scrollWidth`/`clientWidth` are only stable after layout has settled. Restore after `nextTick()` + `requestAnimationFrame()` so the columns have actually rendered. Restoring too early results in `scrollLeft = 0` (browser clamps before the columns have widths). Restoring too late is invisible to the user; we restore during the same paint that mounts the column row, so latency is < 50 ms.

### D3 — Clamp the restored value to the new max

Even if the saved value is valid in full-bleed, the new (narrower) container has a smaller `scrollWidth - clientWidth`. Clamp to `min(saved, scrollWidth - clientWidth)` to handle the unusual case where the kanban column width is shrunk dramatically between sessions. Clamping above 0 (never to a negative value).

### D4 — Skip restore when the saved value is 0

If `localStorage.getItem(...)` returns `null` or `0`, skip the restore. Avoids triggering a useless `scroll` event with value 0 on initial mount (which the scroll logger would otherwise log as a "user scrolled to top").

### D5 — `scroll` listener is `{ passive: true }`

The scroll listener is registered with `{ passive: true }` so the browser can optimize the scroll handling (no need to call `preventDefault` — and we don't). The scroll handler simply schedules a debounced write.

### D6 — Primary save trigger: `scrollend` (falls back to debounced `scroll`)

`scrollend` fires ~100 ms after the user stops scrolling and is well-supported in Chromium / Firefox / Safari (15.4+). For each user-scroll-stop:
- Register a `scrollend` listener that writes the current `scrollLeft` to `localStorage` synchronously.

For browsers without `scrollend` support (very old — and the nalar desktop is shipped via Electron 27+ which is Chromium ≥ 118, so always has `scrollend`), fall back to a 250 ms debounced `setTimeout` write on `scroll`. Belt and suspenders; the `scrollend` path is the fast path.

### D7 — Flush the pending write on `onBeforeUnmount`

If the user scrolls quickly and then clicks a task before `scrollend` fires (or before the debounce timer expires), the pending write would be lost. `onBeforeUnmount` calls `flushPendingWrite()` synchronously, performing the pending write before the component is destroyed. Combined with `scrollend`, this is robust even for fast-scrolling users.

### D8 — Restore on BOTH the standalone and 3-column mounts

The same composable is wired into `KanbanView.vue` (which is the same component in both branches). When the standalone KanbanView mounts, it restores the saved position. When the 3-column KanbanView mounts (with the same key + same composable), it also restores. **Same code path, same behavior**. No special-casing needed at the AppLayout level.

### D9 — No change to layout / no architectural refactor

We're not restructuring the layout to keep a single KanbanView mount point. The save/restore approach is purely additive — fix the symptom with the smallest possible diff. If a future refactor keeps KanbanView mounted across both layouts, the composable becomes a no-op (restoring to the same value).

## Implementation

### Task 1: Create `useKanbanScrollRestore` composable

**File (NEW)**: `src/apps/desktop/src/composables/useKanbanScrollRestore.ts`

Centralizes read-on-mount + write-on-scroll logic for any scrollable container that wants its position persisted to `localStorage`. Pure headless composable — no template, no child component.

```ts
import { onBeforeUnmount, onMounted, ref, watch, type Ref } from 'vue'

/**
 * Persists a container's horizontal scroll position to localStorage
 * across component mounts. Use for horizontally-scrolled boards
 * (e.g. the kanban columns row) where the component may unmount and
 * remount when the layout changes (standalone <-> 3-column).
 *
 * Behavior:
 *   - On mount: reads the saved scrollLeft and clamps it to the
 *     current scrollWidth - clientWidth, then applies it.
 *   - On scroll: debounces a write (250 ms) so a 60-Hz scroll
 *     stream produces one localStorage write per scroll-stop.
 *   - On scrollend: writes immediately (best-effort fast path).
 *   - On unmount: flushes any pending debounced write.
 *
 * Skips restore when the saved value is 0 (no restore needed; the
 * initial mount already starts at 0).
 */
export function useKanbanScrollRestore(
  containerRef: Ref<HTMLElement | null>,
  storageKey: Ref<string> | string,
): void {
  // Make a reactive local ref so we can update the key without
  // reassigning the listener.
  const keyRef = ref(typeof storageKey === 'string' ? storageKey : '')

  if (typeof storageKey !== 'string') {
    watch(
      storageKey,
      (v) => { keyRef.value = v },
      { immediate: true },
    )
  }

  let debounceTimer: ReturnType<typeof setTimeout> | null = null

  const readSavedScrollLeft = (): number => {
    try {
      const raw = localStorage.getItem(keyRef.value)
      if (raw === null) return 0
      const parsed = parseInt(raw, 10)
      return isNaN(parsed) || parsed < 0 ? 0 : parsed
    } catch {
      return 0
    }
  }

  const writeScrollLeft = (value: number): void => {
    try {
      localStorage.setItem(keyRef.value, String(value))
    } catch {
      // localStorage may throw in private-mode or quota-exceeded.
      // Silently ignore — the in-memory restore on the next mount
      // still works (just won't survive reload).
    }
  }

  const flushPending = (): void => {
    if (debounceTimer !== null) {
      clearTimeout(debounceTimer)
      debounceTimer = null
    }
    const el = containerRef.value
    if (el) writeScrollLeft(el.scrollLeft)
  }

  const scheduleWrite = (): void => {
    const el = containerRef.value
    if (!el) return
    if (debounceTimer !== null) clearTimeout(debounceTimer)
    debounceTimer = setTimeout(() => {
      debounceTimer = null
      const e = containerRef.value
      if (e) writeScrollLeft(e.scrollLeft)
    }, 250)
  }

  const handleScroll = (): void => scheduleWrite()
  const handleScrollEnd = (): void => {
    // scrollend is the fast path — cancel the debounced write and
    // commit immediately.
    flushPending()
    const el = containerRef.value
    if (el) writeScrollLeft(el.scrollLeft)
  }

  onMounted(async () => {
    // Wait one frame after mount so the columns have widths.
    await new Promise<void>((r) => requestAnimationFrame(() => r()))
    await new Promise<void>((r) => requestAnimationFrame(() => r()))

    const el = containerRef.value
    if (!el) return
    const saved = readSavedScrollLeft()
    if (saved <= 0) return  // D4: skip when no useful value

    const max = el.scrollWidth - el.clientWidth
    if (max <= 0) return  // nothing to scroll (column row fits)
    const clamped = Math.min(saved, max)
    el.scrollLeft = clamped

    // D5: passive scroll listener for the debounced write.
    el.addEventListener('scroll', handleScroll, { passive: true })

    // D6: scrollend for the fast-path write. Detection is at
    // runtime — feature-detect, never feature-check at parse time.
    if ('onscrollend' in window || typeof el.onscrollend === 'function') {
      el.addEventListener('scrollend', handleScrollEnd, { passive: true })
    } else {
      // Fallback: the debounced scroll handler covers this case.
      // No additional setup needed; scheduleWrite() runs on every
      // scroll event regardless.
    }
  })

  onBeforeUnmount(() => {
    flushPending()
    const el = containerRef.value
    if (!el) return
    el.removeEventListener('scroll', handleScroll)
    el.removeEventListener('scrollend', handleScrollEnd)
  })
}
```

The composable exposes nothing — it side-effects only (writes to `localStorage` + restores `container.scrollLeft`). Trivial to test (state is localStorage + DOM scrollLeft).

### Task 2: Wire `useKanbanScrollRestore` into `KanbanView.vue`

**File**: `src/apps/desktop/src/components/kanban/KanbanView.vue`

1. Add a template ref for the columns row:
   ```ts
   import { computed, onMounted, ref, watch } from 'vue'
   import { useKanbanScrollRestore } from '../../composables/useKanbanScrollRestore'

   const kanbanColumnsContainer = ref<HTMLElement | null>(null)
   ```

2. Compute the storage key (per-itemId, so navigating between kanbans preserves each independently):
   ```ts
   const kanbanScrollStorageKey = computed(
     () => `kanban-scroll-${effectiveItemId.value}`,
   )
   ```

3. Call the composable AFTER the refs are declared:
   ```ts
   useKanbanScrollRestore(kanbanColumnsContainer, kanbanScrollStorageKey)
   ```

4. Add `ref="kanbanColumnsContainer"` to the existing columns row div at `KanbanView.vue:465`:
   ```vue
   <div
     ref="kanbanColumnsContainer"
     class="flex-1 min-h-0 overflow-x-auto overflow-y-hidden"
     style="scrollbar-width: thin;"
     :data-testid="`kanban-view-${item.id}-columns`"
   >
   ```

5. Add a 2-line comment above the columns row explaining why the composable is there:
   ```vue
   <!--
     Horizontal scroll position is persisted to localStorage so the
     kanban stays where the user scrolled it across the standalone
     <-> 3-column layout transition (see useKanbanScrollRestore).
   -->
   ```

### Task 3: Unit tests for the composable

**File (NEW)**: `src/apps/desktop/src/composables/__tests__/useKanbanScrollRestore.spec.ts`

Test cases:

- **`restores saved scrollLeft on mount`** — Pre-seed `localStorage[`kanban-scroll-item_1`] = "1234"`. Mount a Vue wrapper component with an `<div ref="containerRef" style="overflow-x:auto; width:200px; height:100px;"><div style="width:5000px;"></div></div>`. After `mount()` + `nextTick()` + 2× `requestAnimationFrame`, assert `containerRef.scrollLeft === 1234`.
- **`clamps saved scrollLeft to current max`** — Same mount, but saved = 9999 (exceeds max). Assert `containerRef.scrollLeft === scrollWidth - clientWidth`.
- **`skips restore when saved value is 0`** — Pre-seed `localStorage[...] = "0"`. Mount. Assert `scrollLeft === 0` (initial), but importantly the `scroll` event handler does NOT fire (we can spy via `addEventListener`).
- **`persists scrollLeft on scroll event after debounce`** — Mount with no saved value. Set `containerRef.scrollLeft = 777`. Dispatch a synthetic `scroll` event. Advance fake timers by 300 ms. Assert `localStorage['kanban-scroll-item_1'] === '777'`.
- **`persists immediately on scrollend`** — Mount. Set `scrollLeft = 888`. Dispatch synthetic `scrollend`. Immediately (no timer advance) assert `localStorage[...] === '888'`.
- **`flushes pending debounced write on unmount`** — Mount. Set `scrollLeft = 999`. Dispatch `scroll` event (timer is pending). `wrapper.unmount()`. Assert `localStorage[...] === '999'` (the pending write fired before unmount).
- **`handles localStorage throw gracefully`** — Stub `localStorage.setItem` to throw. Set `scrollLeft = 1000`. Dispatch `scrollend`. Assert no thrown exception (caught internally).

Mock `localStorage` per the existing pattern in `useCodeEditor.spec.ts:26-27` (jsdom 29 dropped it from default globals).

### Task 4: Integration test on `AppLayout`

**File (NEW)**: `src/apps/desktop/src/__tests__/AppLayout.kanbanScrollPreservation.spec.ts`

End-to-end test for the reported bug:

1. Set up a kanban workspace item with 8+ columns (matching the user's repro). Mount `<AppLayout>` with a mock workspacesStore.
2. Find the kanban columns container via `[data-testid="kanban-view-<id>-columns"]`. Set its `scrollLeft = 2500` (simulates user scrolling right). Dispatch `scroll` and `scrollend` events to persist.
3. Call `workspacesStore.setActiveTask("task_1")` (or fire a click on a `KanbanCard`).
4. After `nextTick()` + rAFs, assert the kanban columns container's `scrollLeft` is approximately 2500 (within a ±50px tolerance for layout jitter), and the kanban is still inside the 3-column branch.
5. Close the task: `workspacesStore.setActiveTask(null)`.
6. Assert the standalone KanbanView's columns row also has `scrollLeft ≈ 2500`.

These tests must pass for the bug to be considered fixed.

Mock `localStorage` as in Task 3.

### Task 5: Update `KanbanView` spec to ensure test patterns still match

**File**: `src/apps/desktop/src/__tests__/KanbanView.spec.ts`

The existing tests mount `KanbanView` standalone (no parent AppLayout). The new `kanbanColumnsContainer` ref will be populated when mounted normally, so existing tests should be unaffected. **Verify** by running `bunx vitest run __tests__/KanbanView.spec.ts` after Task 2 lands. If existing tests start failing because:

- The composable calls `localStorage.getItem` and tests run in an environment without `localStorage`, add a one-line `Object.defineProperty(globalThis, 'localStorage', { value: localStorageMock })` stub to that spec's `beforeEach`.
- The composable tries to read DOM geometry and jsdom's layout is undefined, use `Object.defineProperty(container, 'scrollWidth', { value: 5000, configurable: true })` and similar to set up the geometry.

If test fixes are needed, they go in this file. Otherwise no edit.

### Task 6: Docs + plan

**File**: `docs/superpowers/plans/2026-07-23-preserve-kanban-horizontal-scroll.md` (this file).

**File**: `src/apps/desktop/src/composables/useKanbanScrollRestore.ts` — add a JSDoc comment block at the top describing: when to use, behavior, browser support notes (scrollend in Electron 27+ is universal).

**File**: `NALAR.md` — add a one-line entry under "Frontend UI conventions" describing the scroll-preservation pattern (`useKanbanScrollRestore` for horizontally-scrolled boards).

## Files Touched

| File                                                                | Action  | Lines |
|---------------------------------------------------------------------|---------|-------|
| `src/apps/desktop/src/composables/useKanbanScrollRestore.ts`        | NEW     | ~95   |
| `src/apps/desktop/src/composables/__tests__/useKanbanScrollRestore.spec.ts` | NEW | ~120  |
| `src/apps/desktop/src/components/kanban/KanbanView.vue`             | EDIT    | +6 −1 |
| `src/apps/desktop/src/__tests__/AppLayout.kanbanScrollPreservation.spec.ts` | NEW | ~100 |
| `src/apps/desktop/src/__tests__/KanbanView.spec.ts` (conditional)   | EDIT    | 0–10  |
| `docs/superpowers/plans/2026-07-23-preserve-kanban-horizontal-scroll.md` | NEW | this |
| `NALAR.md`                                                          | EDIT    | +3    |

Estimated total: ~325 lines (90% in NEW files, 10% in edits).

## Verification

### Manual smoke (reproducing the user's bug)

1. Run `cd src/apps/desktop && bun run build` to get a clean type-check + bundle. (`bun run build` is the project's type-check; `bunx vitest run` is just the test suite — both must be green.)
2. Boot the nalar desktop app on port 8090: `./zig-out/bin/nalar --port 8090` (after `zig build install:linux:system`).
3. Open the kanban board ("sprint 2" with 8 columns).
4. Scroll the columns row right to the `merged` column.
5. Click a task in `merged`. **Expected**: ChatView opens on the right; kanban columns row stays scrolled to the right (or a clamped-near-right position). **Current bug**: kanban snaps to scrollLeft = 0.
6. Click ✕ in ChatView header. **Expected**: ChatView closes; kanban stays where it was. **Current bug**: kanban is at scrollLeft = 0.
7. Reload the page (`F5`). **Expected**: scroll position is preserved (from localStorage).
8. Resize the kanban column to ~480 px wide. **Expected**: kanban clamps scrollLeft to the new max but doesn't jump to 0.

### Automated

```bash
cd src/apps/desktop

# 1. Type-check + bundle (project's authoritative type-check).
timeout 120 bun run build 2>&1 | tail -n 20

# 2. New composable unit tests.
timeout 120 bunx vitest run composables/__tests__/useKanbanScrollRestore.spec.ts 2>&1 | tail -n 30

# 3. New AppLayout integration test.
timeout 120 bunx vitest run __tests__/AppLayout.kanbanScrollPreservation.spec.ts 2>&1 | tail -n 30

# 4. Existing KanbanView / KanbanColumn / KanbanCard tests must still pass.
timeout 120 bunx vitest run __tests__/KanbanView.spec.ts __tests__/KanbanColumn.spec.ts __tests__/KanbanCard.spec.ts __tests__/AppLayout.kanban.spec.ts __tests__/WorkspaceItemKanban.spec.ts 2>&1 | tail -n 30

# 5. Full test suite — confirms no regression elsewhere.
timeout 240 bunx vitest run 2>&1 | tail -n 30
```

All commands must end with `+ passed` (test runner's all-green suffix). The full test baseline is ~1327/1327 + 3 skipped (per the frontend log for this project). The +3 new tests (`useKanbanScrollRestore.spec.ts` × 7 cases + `AppLayout.kanbanScrollPreservation.spec.ts` × 2 cases) bring the total to ~1336.

### Regression checks

- **Existing scroll-related tests**: `chatViewShowPreviewBubble.spec.ts`, `chatViewWorktree.spec.ts`, `VirtualScroller.vue` — no overlap with the kanban scroll container, must stay green.
- **`KanbanCard` / `KanbanColumn` click flow**: tested in `KanbanCard.spec.ts`, `KanbanColumn.spec.ts`. Verify clicking a card still triggers the task open — preservation of scroll is independent of click handling.
- **`localStorage` quota / private-mode**: the composable wraps both `getItem` and `setItem` in `try/catch` (D1). Existing tests use the stub from `useCodeEditor.spec.ts:26-27`; verify no test throws an unhandled exception.

## When To Use This Pattern Elsewhere

Any component with a horizontally-scrollable region that may unmount/remount and benefits from preserving position:

- Kanban (this fix)
- Any future horizontally-scrolling timeline (e.g. schedule view)
- Any horizontally-scrolling tab strip that survives navigation

For VERTICAL scrolling inside a `VirtualScroller`, the existing preservation logic in `VirtualScroller.vue` (`beginPreserve` / `endPreserve`) is the right tool — `useKanbanScrollRestore` is for non-virtualized scroll containers.

## Related memories / prior work

- `frontend-fixed-pos-badge-blocks-clicks.md` — separate UX bug (pointer-events on overlay). Different topic, same domain.
- `nalar-vue-async-onmount-vs-click-race.md` — testing pattern for components with async `onMounted`. Applies here: the composable's `await rAF × 2` needs the same `await new Promise(r => setTimeout(r, 0))` × N polling in AppLayout integration tests to ensure the restore has landed before assertions.
- Project memory: `nalar-frontend-task-literal-typing-rule.md` — Task interface literal-typing rule; doesn't apply here but reinforces the project pattern of "test-set-explicit-fields".
- Established pattern precedent: `AppLayout.vue:643-650` (`loadKanbanColumnWidth`), `AppLayout.vue:701-710` (resize write to localStorage), `DesignView.vue:132-145` (`SIDEBAR_WIDTH_KEY`). The new composable follows the same template.
