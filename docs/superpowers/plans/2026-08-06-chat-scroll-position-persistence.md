# Chat Scroll Position Persistence — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a user opens a task from the kanban sidebar, scrolls the chat to a specific message, closes the chatview (✕), and reopens the same task, the chat should land back at the same scroll position they left — not auto-stick to the bottom every time. Per-task scroll position persists across `mount → unmount → mount` cycles (within the same browser session) and across a page reload (via `localStorage`).

**Architecture:** Add a new `useChatScrollRestore` composable (mirrors `useKanbanScrollRestore` but tracks `scrollTop` and applies chat-specific restore semantics). Add a new `scrollToPosition(value)` method to `VirtualScroller.vue` so the parent can request an arbitrary `scrollTop` without bypassing the scroller's internal state. In `ChatView.vue`, read the saved value on mount BEFORE calling `loadChatHistory`, and branch the initial-load behavior: if a saved position exists and is not "near bottom", call `scrollToPosition(saved)` instead of `scrollToBottom`. The composable handles save-on-scroll + flush-on-unmount automatically.

**Tech Stack:** Vue 3 + TypeScript (frontend, project pin), Pinia for stores, Vitest + `@vue/test-utils` for tests, `localStorage` for persistence. No new dependencies, no backend changes (chat history already supports the cursor + lazy-load), no migration.

**Worktree:** `/home/ginwa/ginwaaitoolbox/.worktrees/chat-scroll-position-persistence` on branch `worktree/chat-scroll-position-persistence`

---

## Design Decisions (for the user to review before execution begins)

| ID | Decision | Why | Alternative rejected |
|----|----------|-----|----------------------|
| D1 | **New `useChatScrollRestore` composable** (not a generalization of `useKanbanScrollRestore`) | The two composables share the same save logic (debounced scroll + scrollend + flush-on-unmount) but the restore semantics differ: chat needs to detect "near bottom → fall through to scrollToBottom" while kanban just clamps to `scrollWidth - clientWidth`. A separate composable lets each call site read its own intent; a generalized one would need a per-call config flag that nobody reads. Cost: one small file + test file. | Generalize `useKanbanScrollRestore` with an `axis: 'top' \| 'left'` + `restore: 'always' \| 'bottom-aware'` parameter — adds a configuration surface that only one caller will use. |
| D2 | **Storage key: `chat-scroll-<task_id>`** | Per-task. The codebase already has the convention `task.id === session.id` (per migration 052 comment), so a single key per task covers both the standalone chat view and the 3-column kanban+chat branch. | `chat-scroll-<session_id>` — redundant since `task_id == session_id`. Per-workspace — wrong granularity (each task has its own scroll). |
| D3 | **Restore heuristic: "near bottom" → fall through to `scrollToBottom`** | If the user was at the bottom when they closed, the rest of the chat should NOT scroll them to a stale position — they should land at the genuine bottom where any new messages have arrived. A saved position within `BOTTOM_THRESHOLD` (40px, mirrored from the existing `helpers/autoStickGate.ts`) of the current `scrollHeight - clientHeight` is treated as "still at bottom" and `scrollToBottom(true, 'restored-as-bottom')` is called instead. | Always restore saved position, even when at-bottom — leaves the user looking at a position that may be stale by a few-px (the bottom overflow). Risk: a user mid-stream who closes reopens at the bottom anyway; the guard avoids the surprise. |
| D4 | **Save on EVERY scroll event** (not gated on user vs programmatic) | The existing `handleVirtualScroll` already uses `scrollLogger.markProgrammatic()` to distinguish user vs programmatic scrolls, but for *saving* the distinction doesn't matter: the `scrollTop` value is what the user sees, regardless of whether the last move was a user gesture or an auto-stick. The debounce + scrollend coalesce a 60-Hz scroll stream into one write per scroll-stop. The kanban composable does the same. | Filter to user-only scrolls — saves nothing in practice (programmatic scrolls only happen when the user is at the bottom, which is the "near bottom" restore path anyway). |
| D5 | **New `VirtualScroller.scrollToPosition(value, behavior?)` method** (not direct `containerRef.value.scrollTop = value` from the parent) | The VirtualScroller exposes `scrollToTop`, `scrollToBottom`, `scrollToIndex`, but not an arbitrary `scrollToPosition`. Adding the method keeps the clamping + internal-state-sync logic in one place. The alternative (parent sets `containerRef.value.scrollTop` directly) works because the next `onScroll` event picks up the new value, but it bypasses the scroller's own state machine — and the project's own memory `vue-3-virtual-scroller-reactive-scrollability.md` warns against reaching into a child component's ref chain. | Bypass via `containerRef.value.scrollTop = value` — works today but couples the ChatView to internal scroller mechanics. |
| D6 | **Persist across page reload** (via `localStorage`), not just in-memory across mount/unmount | The user's example is "close + reopen" within the same session, but the same pattern (composable + `localStorage`) covers both. The kanban composable already uses `localStorage` for the same reason. | In-memory `Map<task_id, scrollTop>` only — loses the position on a reload. Worse UX. |
| D7 | **Restore timing: AFTER `loadChatHistory` completes, not in `onMounted` before the data fetch** | The initial load fills `messages.value` from the API. Until that's done, `scrollHeight` may be 0 (empty chat) or stale (if the previous session had more messages). The current code already calls `scrollToBottom(true, 'initial-load')` AFTER `loadChatHistory` resolves and one `rAF` tick has elapsed — restore must happen in the same window so the lazy-load watcher doesn't yank the user to the bottom. | Restore in `onMounted` before `loadChatHistory` — fails because `scrollHeight` is 0; the saved value clamps to 0 silently. |
| D8 | **Capture the saved value in `onMounted` BEFORE `loadChatHistory`, but apply it AFTER `loadChatHistory` + initial `scrollToBottom`** | We read the saved value early so the `scrollToBottom(true, 'initial-load')` call site can branch on "is there a saved position?". The actual write to `containerRef.value.scrollTop` happens after the messages render + one `rAF` tick. A `ref<number | null>` holds the value between the two; the initial-load branch decides which function to call. | Pass the saved value as a parameter to `loadChatHistory` — couples the persistence concern to the data-fetch function. The branch in `loadChatHistory`'s caller is cleaner. |
| D9 | **No `setActiveTask` change** | The composable attaches/detaches its own listeners via `onMounted`/`onBeforeUnmount` on the ChatView. The existing `setActiveTask(null)` → `setActiveTask(newId)` flow unmounts + remounts ChatView automatically (because `:key="task-<id>"` changes). The save fires on the FIRST unmount, the restore fires on the SECOND mount. No wiring change needed. | Add explicit "save" / "restore" calls to `setActiveTask` — couples the workspaces store to scroll-position concerns. |
| D10 | **No backend changes** | The chat history API already supports cursor-based pagination + lazy-load. The scroll position is purely a client-side ephemeral concern. The `last_human_touched_at` column (migration 065) is unrelated — it tracks "user has interacted", not "user has scrolled to msg N". | Persist `scrollTop` server-side — overkill for a UI concern, races with lazy-load cursor state. |
| D11 | **No new API method on `VirtualScroller`.** | The composable attaches its own `scroll`/`scrollend` listeners to `containerRef.value` — same pattern as `useKanbanScrollRestore`. | Have `VirtualScroller` emit a "scroll persisted" event — couples the scroller to persistence concerns. |

---

## Global Constraints

- **Cross-platform**: every feature MUST work on Linux, macOS, AND Windows. The change is frontend-only (no Zig, no backend), so cross-platform is exercised by the existing pre-commit `bun run build` + `bunx vitest run` + manual testing on each platform.
- **No static-contract tests**: ALL tests are behavioural. No `expect(source).toContain(...)` / `indexOf(u8, source, ...)` patterns — see `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md`.
- **No port 8081**: smoke tests use port 8080 (the always-running dev nalar on 8081 is off-limits).
- **TDD discipline**: every implementation step starts with a failing test, then minimal code to make it pass, then a commit.
- **`bun run build` IS the type-check**: every frontend commit must pass `bun run build` (which runs `vue-tsc` under node); `bunx vitest run` alone does NOT catch type errors — see `.nalar/memories/nalar-frontend-patterns.md` §"`bun run build` is the type-check".
- **BehavIoUral Vue tests** use `@vue/test-utils` `mount` with `setActivePinia(createPinia())` in `beforeEach`. Mock fetch via `vi.fn()` returning `{ ok, status, json, text }` shape (see `.nalar/memories/nalar-frontend-patterns.md` §"`apiFetch` mock helpers need `text()` method").
- **Composable tests** use the same `vi.useFakeTimers()` + `localStorage` stub pattern as `useKanbanScrollRestore.spec.ts` — see `src/apps/desktop/src/composables/__tests__/useKanbanScrollRestore.spec.ts` lines 36-159 for the established setup.
- **NO new comments above `logger.infoFmt(...)` calls** (see `~/.config/nalar/memories/no-comments-on-logger-calls.md`).

---

## File Structure

```
NEW  src/apps/desktop/src/composables/useChatScrollRestore.ts                          (~120 lines, mirrors useKanbanScrollRestore)
NEW  src/apps/desktop/src/composables/__tests__/useChatScrollRestore.spec.ts         (~400 lines, 9 tests)

EDIT src/apps/desktop/src/helpers/VirtualScroller.vue                                  (+ scrollToPosition method, ~15 lines)
NEW  src/apps/desktop/src/helpers/__tests__/VirtualScroller.scrollToPosition.spec.ts  (~150 lines, 4 tests)

EDIT src/apps/desktop/src/components/views/ChatView.vue                                (~30 lines, branch in scrollToBottom call site)
NEW  src/apps/desktop/src/__tests__/views/ChatView.scrollRestore.spec.ts               (~350 lines, 7 tests)

EDIT docs/SPEC.md                                                 (+ §3.7 chat scroll-persistence entry; §10.2.1 PR index)
EDIT NALAR.md                                                     (+ Recent changes entry once shipped)
```

Total: ~10 files (3 NEW, 3 EDIT, 2 doc updates).

---

## Root Cause (read this before chunking — saves re-discovery)

```
User opens task A from the kanban sidebar (or from a kanban card click).
ChatView mounts with :key="task-A.id".
  → onMounted fires loadChatHistory(false).
  → API returns the most recent PAGE_SIZE=1000 messages (newest at the end).
  → scrollToBottom(true, 'initial-load') fires after one rAF tick.
  → Chat is pinned to the very bottom (most recent message).

User scrolls up to read older history.
  → handleVirtualScroll fires on every scroll event.
  → The user is now at, say, scrollTop = 840 (some message in the middle).
  → isAtBottom flips to false once distance > 40px from bottom.

User clicks the ✕ button in the chat header.
  → emit('close') → AppLayout.handleCloseTaskView → setActiveTask(null).
  → ChatView unmounts. NO scrollTop is captured anywhere.

User clicks task A again (or refreshes the page).
  → :key="task-A.id" still matches → ChatView remounts (fresh state).
  → onMounted fires loadChatHistory(false).
  → scrollToBottom(true, 'initial-load') fires AGAIN.
  → User is yanked back to the bottom — their reading position is GONE.
```

The bug class is "Vue 3 conditionally-mounted component loses its ephemeral DOM state across mount/unmount cycles". The codebase has an existing pattern for this (the kanban horizontal scroll case via `useKanbanScrollRestore` + `localStorage`) — we mirror it for the chat vertical scroll case, with two chat-specific wrinkles:

1. **Vertical scroll + virtualized content**: the scroll container is a `VirtualScroller`, not a plain `overflow-y-auto` div. The scroller hides its container's `scrollHeight` behind padding + spacers, so the saved value clamps to `scrollHeight - clientHeight` precisely the way the kanban case does, but the layout is driven by item measurements (50-100ms delay after mount) — restore must wait for the measurement window, not just for two `requestAnimationFrame` ticks.

2. **"Near bottom" detection**: if the user was at the bottom when they closed, the restore should fall through to the existing `scrollToBottom` behavior (so a fresh message that arrived during the close window doesn't get hidden behind a stale scroll position). The kanban case has no equivalent — a horizontal scroll column never has a "near the right edge" semantic.

The fix is 3 chunks:

1. **Composable** (`useChatScrollRestore`) — mirrors `useKanbanScrollRestore` but adds the "near bottom" branch to the restore logic.
2. **`VirtualScroller.scrollToPosition(value)`** — the public API for the parent to request an arbitrary scroll position without bypassing the scroller's internal state.
3. **ChatView integration** — read the saved value on mount, branch the initial-load behavior.

---

## Chunk 1 — `useChatScrollRestore` composable + tests

**Outcome:** A new composable in `src/apps/desktop/src/composables/useChatScrollRestore.ts` (and matching `__tests__/useChatScrollRestore.spec.ts`) that tracks `scrollTop` for a given container element, persists it to `localStorage` keyed by `chat-scroll-<task_id>`, and exposes a `restore()` function that returns the saved `scrollTop` (or `null` if not set). The composable mirrors `useKanbanScrollRestore`'s save logic (debounced scroll + scrollend + flush-on-unmount) but adds a "near bottom" branch in the `restore()` return value: if the saved position is within `BOTTOM_THRESHOLD` of the current `scrollHeight - clientHeight`, return `null` (so the caller falls through to `scrollToBottom`). The composable also exposes a `restorePosition(value: number)` helper that clamps the given value to the current valid range and applies it.

### Task 1.1 — Failing test: composable restores saved scrollTop on mount

**Files to create:** `src/apps/desktop/src/composables/__tests__/useChatScrollRestore.spec.ts`

The test setup mirrors `useKanbanScrollRestore.spec.ts`:
- Stub `localStorage` (jsdom 29 dropped it from default globals).
- Polyfill `requestAnimationFrame` via `setTimeout(0)` so the composable's await chain resolves.
- Mount the composable inside a test component with a known container ref.

The first failing test:

```ts
it('restores saved scrollTop on mount (clamped to scrollHeight - clientHeight)', async () => {
  localStorage.setItem('chat-scroll-task_test', '840')

  const wrapper = mountHarness()
  setScrollGeometry(wrapper.container, { scrollHeight: 5000, clientHeight: 800 })
  // max = 4200

  await waitForRestore()

  expect(wrapper.container.scrollTop).toBe(840)
  wrapper.unmount()
})
```

The composable file does NOT exist yet — the test file should have its imports commented out and the test body expect an `undefined` (`vi.fn(() => undefined)` if we mock, or just `it.skip` if we don't want to fail before the composable exists). The standard practice in this codebase is to mark the test as `#reason: "composable not yet implemented"` and skip the test until the composable is ready. After Task 1.3, un-skip the test.

**Acceptance:** `bunx vitest run src/apps/desktop/src/composables/__tests__/useChatScrollRestore.spec.ts` reports 1 skipped test (then 1 passing after Task 1.3).

- [ ] Create the test file with the harness + setup helpers (mirrors `useKanbanScrollRestore.spec.ts` lines 36-159).
- [ ] Add the first test marked as `# reason: "composable not yet implemented"` — verifies the test infrastructure (mock localStorage + harness mount) works.
- [ ] Run `bunx vitest run` → test is skipped (no compile errors).

### Task 1.2 — Failing test: composable returns saved value (the "near bottom" branch)

**Files to edit:** `src/apps/desktop/src/composables/__tests__/useChatScrollRestore.spec.ts`

Add tests for the `restore()` function:

```ts
it('restore() returns the saved scrollTop when not near bottom', async () => {
  localStorage.setItem('chat-scroll-task_test', '840')
  const harness = mountHarness()
  setScrollGeometry(harness.container, { scrollHeight: 5000, clientHeight: 800 })

  await waitForRestore()

  const restored = harness.restore()
  expect(restored).toBe(840)
})

it('restore() returns null when the saved position is "near bottom" (within BOTTOM_THRESHOLD)', async () => {
  // saved = 4200, max = 4200, distance from bottom = 0
  // → still at bottom, no restore needed
  localStorage.setItem('chat-scroll-task_test', '4200')
  const harness = mountHarness()
  setScrollGeometry(harness.container, { scrollHeight: 5000, clientHeight: 800 })

  await waitForRestore()

  expect(harness.restore()).toBeNull()
})

it('restore() returns null when the saved position is 0 (no scroll happened)', async () => {
  localStorage.setItem('chat-scroll-task_test', '0')
  const harness = mountHarness()
  setScrollGeometry(harness.container, { scrollHeight: 5000, clientHeight: 800 })

  await waitForRestore()

  expect(harness.restore()).toBeNull()
})

it('restore() returns null when no saved value exists', async () => {
  const harness = mountHarness()
  setScrollGeometry(harness.container, { scrollHeight: 5000, clientHeight: 800 })

  await waitForRestore()

  expect(harness.restore()).toBeNull()
})

it('restore() returns null when the container is not scrollable', async () => {
  localStorage.setItem('chat-scroll-task_test', '500')
  const harness = mountHarness()
  setScrollGeometry(harness.container, { scrollHeight: 800, clientHeight: 800 })
  // max = 0 → not scrollable

  await waitForRestore()

  expect(harness.restore()).toBeNull()
})
```

The harness exposes `harness.restore` by capturing the composable's return value. The composable file does not exist yet — these tests are skipped.

**Acceptance:** `bunx vitest run` → 5 skipped tests.

- [ ] Add the 5 restore() tests as `# reason: "composable not yet implemented"`.
- [ ] Run `bunx vitest run` → 6 skipped, 0 failed.

### Task 1.3 — Implement `useChatScrollRestore`

**Files to create:** `src/apps/desktop/src/composables/useChatScrollRestore.ts`

Mirror the structure of `useKanbanScrollRestore.ts` (lines 52-182) but adapted for vertical scroll. Key differences:

1. **Storage key**: caller provides `chat-scroll-<task_id>` directly (no in-composable prefix — caller composes the full key, mirroring the kanban composable).
2. **Axis**: `scrollTop` instead of `scrollLeft`.
3. **Return value**: an object with `{ restore, restorePosition }` instead of `void`. The `restore()` function reads the saved value and applies the "near bottom" branch. The `restorePosition(value)` helper clamps and applies a value.
4. **Restore timing**: wait for `scrollHeight` to be accurate (not just `requestAnimationFrame` × 2). The kanban composable's "wait 2 rAF" works because the kanban columns have static widths. The chat loads messages asynchronously, so `scrollHeight` may be 0 immediately after mount. Wait for `scrollHeight > 0` OR a 500 ms timeout, whichever comes first.

Skeleton:

```ts
import { onBeforeUnmount, onMounted, ref, watch, type Ref } from 'vue'

const BOTTOM_THRESHOLD_PX = 40  // mirrors helpers/autoStickGate.ts

export function useChatScrollRestore(
  containerRef: Ref<HTMLElement | null>,
  storageKey: Ref<string> | string,
): {
  restore: () => number | null
  restorePosition: (value: number) => void
} {
  const keyRef = ref(typeof storageKey === 'string' ? storageKey : '')

  if (typeof storageKey !== 'string') {
    watch(storageKey, (v) => { keyRef.value = v }, { immediate: true })
  }

  let debounceTimer: ReturnType<typeof setTimeout> | null = null
  let savedScrollTop: number | null = null  // captured on mount, used by restore()

  const readSaved = (): number | null => {
    try {
      const raw = localStorage.getItem(keyRef.value)
      if (raw === null) return null
      const parsed = parseInt(raw, 10)
      return Number.isNaN(parsed) || parsed < 0 ? null : parsed
    } catch {
      return null
    }
  }

  const writeSaved = (value: number): void => {
    try {
      localStorage.setItem(keyRef.value, String(value))
    } catch { /* private-mode / quota-exceeded */ }
  }

  const flushPending = (): void => {
    if (debounceTimer !== null) {
      clearTimeout(debounceTimer)
      debounceTimer = null
    }
    const el = containerRef.value
    if (el) writeSaved(el.scrollTop)
  }

  const scheduleWrite = (): void => {
    const el = containerRef.value
    if (!el) return
    if (debounceTimer !== null) clearTimeout(debounceTimer)
    debounceTimer = setTimeout(() => {
      debounceTimer = null
      const e = containerRef.value
      if (e) writeSaved(e.scrollTop)
    }, 250)
  }

  const handleScroll = (): void => scheduleWrite()
  const handleScrollEnd = (): void => {
    flushPending()
    const el = containerRef.value
    if (el) writeSaved(el.scrollTop)
  }

  onMounted(async () => {
    // Read the saved value EARLY so restore() can return it AFTER the
    // VirtualScroller has measured item heights. We wait for either
    // scrollHeight > 0 (item measurement complete) OR a 500 ms safety
    // net, whichever comes first.
    savedScrollTop = readSaved()

    const waitForScrollHeight = async (): Promise<void> => {
      const start = Date.now()
      while (Date.now() - start < 500) {
        const el = containerRef.value
        if (el && el.scrollHeight > el.clientHeight) return
        await new Promise<void>((r) => setTimeout(r, 16))
      }
    }
    await waitForScrollHeight()

    const el = containerRef.value
    if (!el) return

    // Attach listeners regardless of saved value (user might scroll from scratch).
    el.addEventListener('scroll', handleScroll, { passive: true })
    const supportsScrollEnd = 'onscrollend' in el
    if (supportsScrollEnd) {
      el.addEventListener('scrollend', handleScrollEnd, { passive: true })
    }
  })

  onBeforeUnmount(() => {
    flushPending()
    const el = containerRef.value
    if (el) {
      el.removeEventListener('scroll', handleScroll)
      el.removeEventListener('scrollend', handleScrollEnd)
    }
  })

  const restore = (): number | null => {
    if (savedScrollTop === null) return null
    if (savedScrollTop <= 0) return null
    const el = containerRef.value
    if (!el) return null
    const max = el.scrollHeight - el.clientHeight
    if (max <= 0) return null
    // "Near bottom" branch: if the saved position is within
    // BOTTOM_THRESHOLD_PX of the max, treat as "still at bottom"
    // → let the caller fall through to scrollToBottom.
    if (savedScrollTop >= max - BOTTOM_THRESHOLD_PX) return null
    return savedScrollTop
  }

  const restorePosition = (value: number): void => {
    const el = containerRef.value
    if (!el) return
    const max = el.scrollHeight - el.clientHeight
    if (max <= 0) return
    const clamped = Math.max(0, Math.min(value, max))
    el.scrollTop = clamped
  }

  return { restore, restorePosition }
}
```

**Acceptance:** `bunx vitest run src/apps/desktop/src/composables/__tests__/useChatScrollRestore.spec.ts` → 6 passing tests (the 5 restore() tests + the initial-load test).

- [ ] Create the composable file with the skeleton above.
- [ ] Un-skip the 6 tests in `useChatScrollRestore.spec.ts`.
- [ ] Run `bunx vitest run` → 6 pass, 0 fail.
- [ ] Commit `feat(chat-scroll): useChatScrollRestore composable`.

### Task 1.4 — Save-on-scroll tests (mirrors `useKanbanScrollRestore` Tests 4-9)

**Files to edit:** `src/apps/desktop/src/composables/__tests__/useChatScrollRestore.spec.ts`

Add the 5 save-behavior tests, mirroring `useKanbanScrollRestore.spec.ts` lines 224-431:

```ts
it('persists scrollTop on scrollend immediately', async () => { ... })
it('persists scrollTop on scroll after 250 ms debounce', async () => { ... })
it('debounces a rapid scroll stream into a single write', async () => { ... })
it('flushes the pending debounced write on unmount', async () => { ... })
it('handles localStorage.setItem throw gracefully', async () => { ... })
```

**Acceptance:** `bunx vitest run` → 11 passing tests.

- [ ] Add the 5 save tests.
- [ ] Run `bunx vitest run` → 11 pass, 0 fail.
- [ ] Commit `test(chat-scroll): save-on-scroll contract for useChatScrollRestore`.

---

## Chunk 2 — `VirtualScroller.scrollToPosition(value, behavior?)` method

**Outcome:** `VirtualScroller` exposes a new `scrollToPosition(scrollTop: number, behavior?: ScrollBehavior = 'auto')` method that clamps the given value to the valid range `[0, scrollHeight - clientHeight]` and applies it via `containerRef.value.scrollTo({ top: clamped, behavior })`. The internal `scrollTop` ref is synced implicitly via the next `onScroll` event (the browser fires one when `scrollTo` updates `scrollTop`). Closes a gap in the existing public API (`scrollToTop`, `scrollToBottom`, `scrollToIndex` exist but no "scroll to arbitrary position").

### Task 2.1 — Failing test: `scrollToPosition` clamps + applies

**Files to create:** `src/apps/desktop/src/helpers/__tests__/VirtualScroller.scrollToPosition.spec.ts`

Setup pattern: mirror the existing `useKanbanScrollRestore.spec.ts` jsdom setup (localStorage stub + rAF polyfill). Mount a `VirtualScroller` with a fixed-height items array, override `scrollHeight`/`clientHeight` via `Object.defineProperty`, then call the exposed method and assert the result.

```ts
it('scrollToPosition clamps the value to [0, scrollHeight - clientHeight]', async () => {
  const wrapper = mountScrollHarness({ scrollHeight: 5000, clientHeight: 800 })
  await waitForRestore()

  // value > max → clamp to max = 4200
  wrapper.vm.scrollToPosition(9999)
  expect(wrapper.container.scrollTop).toBe(4200)

  // value < 0 → clamp to 0
  wrapper.vm.scrollToPosition(-100)
  expect(wrapper.container.scrollTop).toBe(0)

  // value in range → apply verbatim
  wrapper.vm.scrollToPosition(840)
  expect(wrapper.container.scrollTop).toBe(840)
})

it('scrollToPosition is a no-op when the container is not scrollable', async () => {
  const wrapper = mountScrollHarness({ scrollHeight: 800, clientHeight: 800 })
  await waitForRestore()

  // max = 0 → no scroll needed
  wrapper.vm.scrollToPosition(500)
  expect(wrapper.container.scrollTop).toBe(0)
})

it('scrollToPosition is a no-op when containerRef is null', async () => {
  const wrapper = mountScrollHarness({ scrollHeight: 5000, clientHeight: 800 })
  await waitForRestore()

  // Force containerRef to null by unmounting the wrapper, then call
  // the method via the captured ref. Defensive: should not throw.
  wrapper.unmount()
  // ... (test harness captures the ref BEFORE unmount)
  expect(() => capturedRef.scrollToPosition(500)).not.toThrow()
})
```

The `VirtualScroller.vue` file does not yet expose `scrollToPosition` — the test fails with "scrollToPosition is not a function" (or `undefined` if accessed via `wrapper.vm`).

**Acceptance:** `bunx vitest run src/apps/desktop/src/helpers/__tests__/VirtualScroller.scrollToPosition.spec.ts` → 3 failing tests.

- [ ] Create the test file with the harness + 3 tests.
- [ ] Run `bunx vitest run` → 3 failing tests, error = "scrollToPosition is not a function".

### Task 2.2 — Implement `scrollToPosition` in `VirtualScroller.vue`

**Files to edit:** `src/apps/desktop/src/helpers/VirtualScroller.vue`

Add the method implementation near the existing `scrollToTop` / `scrollToBottom` (line 593-601):

```ts
const scrollToPosition = (scrollTop: number, behavior: ScrollBehavior = 'auto') => {
  if (!containerRef.value) return
  const max = containerRef.value.scrollHeight - containerHeight.value
  if (max <= 0) return // not scrollable
  const clamped = Math.max(0, Math.min(scrollTop, max))
  containerRef.value.scrollTo({ top: clamped, behavior })
}
```

Add to `defineExpose` (line 624-628):

```ts
defineExpose({
  scrollToIndex,
  scrollToTop,
  scrollToBottom,
  scrollToPosition,  // <-- new
  scrollToItem,
  beginPreserve,
  endPreserve,
  preserveScrollPosition,
  containerRef,
  isPreservingScroll,
  effectiveLoadMoreThreshold,
})
```

**Acceptance:** `bunx vitest run src/apps/desktop/src/helpers/__tests__/VirtualScroller.scrollToPosition.spec.ts` → 3 passing tests.

- [ ] Add the `scrollToPosition` method + `defineExpose` entry.
- [ ] Run `bunx vitest run` → 3 pass.
- [ ] Run `bunx vitest run src/apps/desktop/src/helpers/__tests__/VirtualScroller.spec.ts` (the existing test file) → all green (no regressions in the existing exposed API).
- [ ] Commit `feat(virtual-scroller): scrollToPosition(value, behavior?) public method`.

### Task 2.3 — Add to `VirtualScrollerExposed` interface in `ChatView.vue`

**Files to edit:** `src/apps/desktop/src/components/views/ChatView.vue`

The local `VirtualScrollerExposed` interface (lines 453-464) is a hand-typed mirror of the scroller's exposed methods. Add `scrollToPosition` to keep the typing in sync:

```ts
interface VirtualScrollerExposed {
  scrollToIndex: (index: number, behavior?: ScrollBehavior) => void
  scrollToTop: (behavior?: ScrollBehavior) => void
  scrollToBottom: (behavior?: ScrollBehavior) => void
  scrollToPosition: (scrollTop: number, behavior?: ScrollBehavior) => void  // <-- new
  scrollToItem: (index: number, behavior?: ScrollBehavior) => void
  beginPreserve: (newItemsCount: number) => void
  endPreserve: () => Promise<void>
  preserveScrollPosition: () => Promise<void>
  containerRef: { value: HTMLElement | null }
  isPreservingScroll: { value: boolean }
  effectiveLoadMoreThreshold: { value: number }
}
```

**Acceptance:** `bun run build` → clean (vue-tsc passes).

- [ ] Add `scrollToPosition` to the interface.
- [ ] Run `bun run build` → 0 errors.
- [ ] Commit `refactor(chat-view): declare scrollToPosition on VirtualScrollerExposed interface`.

---

## Chunk 3 — ChatView integration + tests

**Outcome:** `ChatView.vue` uses the `useChatScrollRestore` composable to save `scrollTop` per-task via `localStorage`. On mount, AFTER `loadChatHistory(false)` completes and one `rAF` tick has elapsed, the ChatView branches: if `restore()` returns a value, call `scrollToPosition(value)` instead of `scrollToBottom(true, 'initial-load')`. The existing `scrollLogger` is also updated to tag the restore path with `reason: 'scroll-position-restored'` so the log line is searchable.

### Task 3.1 — Failing test: ChatView restores scroll position on mount

**Files to create:** `src/apps/desktop/src/__tests__/views/ChatView.scrollRestore.spec.ts`

The test mounts the ChatView with a mock `api.getChatHistory` that returns 100 messages, then checks:
- Initial mount lands at the bottom (existing behavior).
- After scrolling up to `scrollTop = 400`, the ChatView is unmounted (simulating the ✕ click).
- After re-mount with the same `chatId`, the ChatView scrolls to `scrollTop = 400` (the saved position).

```ts
it('restores the saved scroll position when the same task is re-opened', async () => {
  // Pre-seed localStorage (the previous session left scrollTop = 400)
  localStorage.setItem('chat-scroll-task_test_session', '400')

  // Mount ChatView with a chatId that maps to that storage key
  const wrapper = mountChatView({ chatId: 'task_test_session' })

  // Wait for the initial load + restore window
  await flushPromises()
  await new Promise<void>((r) => requestAnimationFrame(() => r()))
  await new Promise<void>((r) => requestAnimationFrame(() => r()))
  await flushPromises()

  // Assert scrollTop is 400 (the saved value)
  const container = wrapper.find('[data-virtual-scroller]').element // or whatever selector
  expect(container.scrollTop).toBe(400)
})
```

The integration is not yet wired — the test fails because the existing ChatView always lands at the bottom.

**Acceptance:** `bunx vitest run src/apps/desktop/src/__tests__/views/ChatView.scrollRestore.spec.ts` → 1 failing test (the restored chat lands at the bottom, not at scrollTop = 400).

- [ ] Create the test file with the harness + 1 test (marked as `# reason: "ChatView not yet wired"` — skip until Task 3.3 lands).
- [ ] Run `bunx vitest run` → 1 skipped.

### Task 3.2 — Failing test: ChatView falls through to `scrollToBottom` when saved position is "near bottom"

Same file, second test:

```ts
it('falls through to scrollToBottom when the saved position is near bottom', async () => {
  // scrollHeight - clientHeight = 5000 (pre-populated geometry)
  // saved = 4980 → within BOTTOM_THRESHOLD_PX = 40 of the max (5000)
  // → "still at bottom" → restore() returns null → ChatView scrolls to bottom
  localStorage.setItem('chat-scroll-task_test_session', '4980')

  const wrapper = mountChatView({ chatId: 'task_test_session' })
  await waitForRestore()

  // The bottom is at scrollHeight - clientHeight = 5000 (after the
  // VirtualScroller's items have rendered)
  const container = wrapper.find('[data-virtual-scroller]').element
  expect(container.scrollTop).toBe(5000)  // not 4980
})
```

- [ ] Add the second test as `# reason: "ChatView not yet wired"`.
- [ ] Run `bunx vitest run` → 2 skipped.

### Task 3.3 — Wire `useChatScrollRestore` into ChatView

**Files to edit:** `src/apps/desktop/src/components/views/ChatView.vue`

Step 1 — Import the composable (top of the script, after other imports):

```ts
import { useChatScrollRestore } from '../../composables/useChatScrollRestore'
```

Step 2 — Inside the `setup` function, after the `virtualScrollerRef` declaration (line 465), wire the composable. The storage key derives from `sessionId.value` (which is `chatId.replace(/^chat-/, '')`) — the same identity as the task id, per the project's `task.id == session.id` convention:

```ts
// Persist scroll position per-task across mount/unmount. The
// composable attaches its own scroll/scrollend listeners to the
// VirtualScroller's container ref and flushes pending writes on
// unmount. The storage key is `chat-scroll-<taskId>` (the same as
// the session id, per the project's task.id == session.id
// convention).
const sessionStorageKey = computed(() => `chat-scroll-${sessionId.value}`)
const chatScrollRestore = useChatScrollRestore(
  computed(() => virtualScrollerRef.value?.containerRef.value ?? null),
  sessionStorageKey,
)
```

Step 3 — In the initial-load branch of `loadChatHistory` (line 1240-1255), branch the scroll behavior:

```ts
if (!loadMore) {
  // ... existing scrollLogger.info({...}) ...

  await nextTick()
  await new Promise<void>((r) => requestAnimationFrame(() => r()))
  await new Promise<void>((r) => requestAnimationFrame(() => r()))

  // Capture the saved scrollTop BEFORE the messages-length
  // watcher's scrollToBottom fires. The watcher would otherwise
  // yank us to the bottom immediately on the next message push.
  const savedScrollTop = chatScrollRestore.restore()

  if (savedScrollTop !== null) {
    scrollLogger.markProgrammatic()
    virtualScrollerRef.value?.scrollToPosition(savedScrollTop, 'auto')
    scrollLogger.info({
      ...,
      caller: 'loadChatHistory',
      reason: 'scroll-position-restored',
      extra: { savedScrollTop, trigger: 'initial-load' },
    })
  } else {
    // Existing default behavior: land at the bottom.
    scrollToBottom(true, 'initial-load')
  }

  setupCodeBlockCopyButtons()
}
```

Wait — the `messages-length` watcher (line 1942-1956) fires on every `messages.value` push. After `loadChatHistory` returns, `messages.value = newMessages.slice().reverse()` (line 1225) triggers the watcher. The watcher calls `scrollToBottom(false, 'messages-length')`. We need to prevent that from overriding the restored position.

Looking at the watcher:
```ts
watch(
  () => messages.value.length,
  () => {
    scrollLogger.markProgrammatic()
    lastAutoStickAt.value = Date.now()
    nextTick(() => scrollToBottom(false, 'messages-length'))
  },
)
```

The watcher fires AFTER `loadChatHistory` resolves. If we restore via `scrollToPosition` between the data push and the watcher's `nextTick`, the watcher would yank us back to the bottom.

The fix: gate the watcher's `scrollToBottom` call on a flag that we set BEFORE the data push and clear AFTER the watcher fires. OR: skip the watcher entirely for the initial load (the initial load is handled by the branch above).

Cleanest option: add a flag `isInitialLoad: boolean` that the watcher respects:

```ts
let isInitialLoad = false

// In loadChatHistory's initial-load branch:
if (!loadMore) {
  isInitialLoad = true
  await nextTick()
  await new Promise<void>((r) => requestAnimationFrame(() => r()))
  await new Promise<void>((r) => requestAnimationFrame(() => r()))

  const savedScrollTop = chatScrollRestore.restore()
  if (savedScrollTop !== null) {
    scrollLogger.markProgrammatic()
    virtualScrollerRef.value?.scrollToPosition(savedScrollTop, 'auto')
    scrollLogger.info({ ..., reason: 'scroll-position-restored', ... })
  } else {
    scrollToBottom(true, 'initial-load')
  }
  isInitialLoad = false
  setupCodeBlockCopyButtons()
}

// In the messages-length watcher:
watch(
  () => messages.value.length,
  () => {
    if (isInitialLoad) return  // <-- skip during initial load
    scrollLogger.markProgrammatic()
    lastAutoStickAt.value = Date.now()
    nextTick(() => scrollToBottom(false, 'messages-length'))
  },
)
```

Same flag protects the second `scrollToBottom` (the `loadChatHistory` initial-load branch already called `scrollToBottom(true, 'initial-load')` — the watcher re-firing on the same `messages.length` change is redundant and would just be a no-op).

Hmm wait — the `messages.length` watcher fires on the SAME `messages.value = newMessages.slice().reverse()` assignment. So the watcher fires synchronously when the assignment happens. The `nextTick` defers the actual scroll. By the time the `nextTick` callback runs, we've already returned from `loadChatHistory` and re-set `isInitialLoad = false`. The race is in the OTHER direction: the watcher fires FIRST, queues the nextTick, then `loadChatHistory` continues to its final branch.

Actually no — the watcher fires SYNCHRONOUSLY when `messages.value` is assigned. The `await nextTick()` inside the watcher fires AFTER the assignment but BEFORE the assignment's continuation. The control flow is:

1. `messages.value = newMessages.slice().reverse()` → triggers watcher synchronously
2. Watcher callback runs `if (isInitialLoad) return` → isInitialLoad is false (not yet set), so the watcher proceeds.
3. Watcher schedules `nextTick(scrollToBottom, 'messages-length')`.
4. Control returns to `loadChatHistory`, which sets `isInitialLoad = true` (too late), then awaits nextTick → the microtask runs `scrollToBottom(false, 'messages-length')` → user gets yanked to bottom.

The fix is to set `isInitialLoad = true` BEFORE the `messages.value =` assignment. We can do this in the loadChatHistory branch right before the assignment:

```ts
if (!loadMore) {
  isInitialLoad = true
  messages.value = newMessages.slice().reverse()
  await nextTick()
  // ... wait for rAF × 2 ...
  const savedScrollTop = chatScrollRestore.restore()
  if (savedScrollTop !== null) {
    virtualScrollerRef.value?.scrollToPosition(savedScrollTop, 'auto')
  } else {
    scrollToBottom(true, 'initial-load')
  }
  isInitialLoad = false
  setupCodeBlockCopyButtons()
}
```

But the `isInitialLoad` flag has a subtle race: if the user sends a message during the initial load, the message-len watcher fires, `isInitialLoad` is true → skip. The user's send would be silently lost from the scroll behavior. Mitigation: only skip the watcher when `isInitialLoad` is true AND the message count matches the initial load's count. Or: only set the flag for ~50 ms.

Actually the simplest fix: make the watcher check `isInitialLoad` AND the saved value. If both are "consumed", let it through:

```ts
// In the watcher:
if (isInitialLoad && chatScrollRestore.restore() === null) {
  // Initial load without a saved position → fall through to scrollToBottom
  // (this is the legacy 'initial-load' behavior)
  scrollLogger.markProgrammatic()
  lastAutoStickAt.value = Date.now()
  nextTick(() => scrollToBottom(false, 'messages-length'))
  return
}
if (isInitialLoad) {
  // Initial load WITH a saved position → restore handled it; skip.
  return
}
// Normal fire (user sent a message, etc.)
scrollLogger.markProgrammatic()
lastAutoStickAt.value = Date.now()
nextTick(() => scrollToBottom(false, 'messages-length'))
```

This is getting complex. Let me think about a simpler approach.

**Simpler approach**: skip the `messages-length` watcher entirely during the initial load. The initial-load branch below handles the scroll position explicitly. After the initial load, the watcher's `nextTick` is moot (the branch already set `scrollTop`). Subsequent pushes (user sends a message, etc.) fire the watcher — that's the normal auto-stick behavior.

```ts
// In loadChatHistory's initial-load branch:
if (!loadMore) {
  // Suppress the messages-length watcher's auto-stick during the
  // initial load. The branch below handles the scroll position
  // explicitly (either restore saved or scrollToBottom).
  isInitialLoad = true
  try {
    messages.value = newMessages.slice().reverse()

    await nextTick()
    await new Promise<void>((r) => requestAnimationFrame(() => r()))
    await new Promise<void>((r) => requestAnimationFrame(() => r()))

    const savedScrollTop = chatScrollRestore.restore()
    if (savedScrollTop !== null) {
      scrollLogger.markProgrammatic()
      virtualScrollerRef.value?.scrollToPosition(savedScrollTop, 'auto')
      scrollLogger.info({
        ...,
        caller: 'loadChatHistory',
        reason: 'scroll-position-restored',
        extra: { savedScrollTop, trigger: 'initial-load' },
      })
    } else {
      scrollToBottom(true, 'initial-load')
    }
    setupCodeBlockCopyButtons()
  } finally {
    isInitialLoad = false
  }
}
```

```ts
// In the messages-length watcher:
watch(
  () => messages.value.length,
  () => {
    if (isInitialLoad) return  // initial-load branch handled it
    scrollLogger.markProgrammatic()
    lastAutoStickAt.value = Date.now()
    nextTick(() => scrollToBottom(false, 'messages-length'))
  },
)
```

Simpler. The flag is set synchronously before the assignment, the watcher sees it, the entire branch completes, then the flag is cleared. The `try/finally` ensures the flag is cleared even if something throws.

Wait, there's still a race. The `messages.value =` assignment is watched by Vue. The watcher fires SYNCHRONOUSLY in the same microtask. So:

1. `isInitialLoad = true` (sync)
2. `messages.value = ...` (sync, triggers watcher synchronously)
3. Watcher callback runs: `if (isInitialLoad) return` ✓
4. Assignment returns. `await nextTick()` defers.
5. `await rAF × 2` completes.
6. Restore or scrollToBottom fires.
7. `isInitialLoad = false` (sync, in finally)

The flow is correct. Vue 3's `watch` runs synchronously when the dependency changes (unless `{ flush: 'pre' | 'post' }` is specified — the default is `'pre'` which fires synchronously when the dependency changes). The `nextTick` here is a delayed scroll, not a delayed watch.

Actually wait, I need to double-check. Vue 3 `watch` defaults to `flush: 'pre'` which is the "before render" flush — that fires synchronously when the dependency changes, BEFORE the next render. So the watcher callback runs synchronously in the same tick. The `nextTick` inside the watcher defers the actual scroll to after the render. That's correct.

So the flag pattern works. Let me move on.

**Acceptance:** `bunx vitest run src/apps/desktop/src/__tests__/views/ChatView.scrollRestore.spec.ts` → 2 passing tests.

- [ ] Edit `ChatView.vue` per the steps above.
- [ ] Un-skip the 2 tests in `ChatView.scrollRestore.spec.ts`.
- [ ] Run `bunx vitest run` → 2 pass, 0 fail.
- [ ] Run `bun run build` → 0 type errors.
- [ ] Run `bunx vitest run src/apps/desktop/src/__tests__/views/ChatView.spec.ts` (existing test file) → all green (no regressions in the existing scroll behavior).
- [ ] Commit `feat(chat-view): restore saved scroll position on mount when reopening a task`.

### Task 3.4 — Add fallback tests for edge cases

**Files to edit:** `src/apps/desktop/src/__tests__/views/ChatView.scrollRestore.spec.ts`

Add the additional integration tests:

```ts
it('saves the scroll position when the user scrolls up before closing', async () => {
  const wrapper = mountChatView({ chatId: 'task_save_test' })
  await waitForRestore()

  // Simulate user scrolling up
  const container = wrapper.find('[data-virtual-scroller]').element as HTMLElement
  Object.defineProperty(container, 'scrollHeight', { value: 5000, configurable: true })
  Object.defineProperty(container, 'clientHeight', { value: 800, configurable: true })
  container.scrollTop = 400
  container.dispatchEvent(new Event('scrollend'))

  // The composable should have persisted 400
  expect(localStorage.getItem('chat-scroll-task_save_test')).toBe('400')

  wrapper.unmount()
})

it('does not restore when the saved position is 0 (no scroll happened)', async () => {
  localStorage.setItem('chat-scroll-task_zero', '0')

  const wrapper = mountChatView({ chatId: 'task_zero' })
  await waitForRestore()

  // The composable's restore() returns null for saved = 0, so the
  // ChatView falls through to scrollToBottom. The chat should land
  // at the bottom (not at 0).
  const container = wrapper.find('[data-virtual-scroller]').element as HTMLElement
  expect(container.scrollTop).toBe(container.scrollHeight - container.clientHeight)
})

it('uses a per-task key (different tasks have different scroll positions)', async () => {
  localStorage.setItem('chat-scroll-task_A', '100')
  localStorage.setItem('chat-scroll-task_B', '500')

  const wrapperA = mountChatView({ chatId: 'task_A' })
  await waitForRestore()
  const containerA = wrapperA.find('[data-virtual-scroller]').element as HTMLElement
  // ... set scrollWidth/clientWidth, assert scrollTop = 100 ...

  const wrapperB = mountChatView({ chatId: 'task_B' })
  await waitForRestore()
  const containerB = wrapperB.find('[data-virtual-scroller]').element as HTMLElement
  // ... assert scrollTop = 500 ...
})

it('flushes the pending scroll save on unmount', async () => {
  const wrapper = mountChatView({ chatId: 'task_flush_test' })
  await waitForRestore()

  const container = wrapper.find('[data-virtual-scroller]').element as HTMLElement
  container.scrollTop = 350
  container.dispatchEvent(new Event('scroll'))  // triggers debounced write

  // Unmount WITHOUT advancing the debounce timer. The composable's
  // onBeforeUnmount should flush the pending write synchronously.
  wrapper.unmount()

  expect(localStorage.getItem('chat-scroll-task_flush_test')).toBe('350')
})
```

**Acceptance:** `bunx vitest run src/apps/desktop/src/__tests__/views/ChatView.scrollRestore.spec.ts` → 6 passing tests.

- [ ] Add the 4 fallback tests.
- [ ] Run `bunx vitest run` → 6 pass, 0 fail.
- [ ] Run `bunx vitest run` (full suite) → no regressions.
- [ ] Commit `test(chat-view): scrollRestore save + fallback contracts`.

### Task 3.5 — End-to-end smoke test

**Files:** no edit, just verification

Boot the dev server on port 8080, open a chat, scroll up, close, reopen, verify the scroll position is restored.

```bash
# 1. Start nalar on port 8080 (not 8081)
HOME=/tmp/nalar-scroll-smoke setsid -f ./zig-out/bin/nalar --port 8080 \
  > /tmp/scroll-smoke.log 2>&1 < /dev/null
sleep 6

# 2. Create a workspace + kanban + task with a chat-able task
WS=$(curl -sS -X POST http://127.0.0.1:8080/api/workspaces \
  -H 'content-type: application/json' \
  -d '{"name":"scroll-smoke"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')

ITEM=$(curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/kanban" \
  -H 'content-type: application/json' \
  -d '{"name":"board","path":"/tmp"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["item"]["id"])')

# 3. Create a task with enough messages to be scrollable. Use the
#    chat API to send 20 messages.
TASK=$(curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/tasks" \
  -H 'content-type: application/json' \
  -d '{"name":"scroll-test"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')

# 4. Open the chat in nalar-desktop, scroll up, close, reopen.
#    Verify the scroll position is preserved.

# 5. Cleanup
pkill -f "nalar --port 8080"
```

**Acceptance:** Manual smoke test confirms the feature. Document the result in the commit message.

- [ ] Run the smoke test.
- [ ] Commit `docs(chat-scroll): end-to-end smoke test verified on Linux + macOS`.

---

## Acceptance Criteria (final pass)

Before merging `worktree/chat-scroll-position-persistence` into `main`:

1. **All tests pass**: `bunx vitest run` → 0 failing, 0 skipped (or only the pre-existing demo-mode skips).
2. **Type-check clean**: `bun run build` exits 0.
3. **Cross-platform**: `bunx vitest run` on Linux + macOS both green. Windows covered by the existing CI matrix (frontend-only change, no native bindings).
4. **Manual smoke**: the smoke test in Task 3.5 documents the feature works end-to-end.
5. **No static-contract tests**: every new test is behavioural (mounts a component, calls a function, asserts on return value or DOM state).
6. **No regressions**: existing `useKanbanScrollRestore.spec.ts` and `VirtualScroller.spec.ts` tests still pass.
7. **AGENTS.md + SPEC.md** updated: `docs/SPEC.md` §3.7 gets a new "chat scroll persistence" entry; `AGENTS.md` Recent Changes section gets a new entry.

---

## Files Touched (summary)

| File | Action | Purpose |
|------|--------|---------|
| `src/apps/desktop/src/composables/useChatScrollRestore.ts` | NEW | Save + restore composable, mirrors `useKanbanScrollRestore` |
| `src/apps/desktop/src/composables/__tests__/useChatScrollRestore.spec.ts` | NEW | 11 TDD tests |
| `src/apps/desktop/src/helpers/VirtualScroller.vue` | EDIT | New `scrollToPosition` method + `defineExpose` entry |
| `src/apps/desktop/src/helpers/__tests__/VirtualScroller.scrollToPosition.spec.ts` | NEW | 3 tests for the new method |
| `src/apps/desktop/src/components/views/ChatView.vue` | EDIT | Wire composable + branch the initial-load scroll |
| `src/apps/desktop/src/__tests__/views/ChatView.scrollRestore.spec.ts` | NEW | 6 integration tests |
| `docs/SPEC.md` | EDIT | §3.7 chat scroll entry + §10.2.1 PR index |
| `AGENTS.md` | EDIT | Recent Changes entry |

---

## Out of Scope (deferred for follow-up plans)

| Item | Why deferred |
|------|--------------|
| **Cross-tab sync** of scroll position (two tabs of the same task) | The user's example is intra-tab (close + reopen in the same tab). Cross-tab sync would require a `BroadcastChannel` or `storage` event listener — out of scope for v1. The localStorage write is per-tab; opening a second tab would see the most recent write. |
| **Persist scroll position to `workspace_item_tasks` column** | The server-side approach (migration + API column) would survive a different browser / device. The user's example doesn't mention this; localStorage is the simpler UX. Adding a column would also require a cursor-style scroll API on the backend (e.g. "load messages around scrollTop = 840"). |
| **Restore position across device** | Requires backend persistence. Same as above. |
| **Scrolling by message id** (instead of pixel position) | The current API doesn't support "scroll to message id". Adding it would require the VirtualScroller to look up `accumulatedHeights` for a given message id. The pixel-based approach is sufficient for the user's use case. |
| **Save position on user-pause** (e.g. 5s idle) | The composable already saves on `scrollend` and on unmount. A "periodic save" layer would just add writes — `scrollend` covers the same UX. |
| **Restore on Chrome's Auto-Scroll-to-Text-Fragment** | The browser already does this when you scroll to a URL fragment. Not a ChatView concern. |
| **Restore on BFCache navigation** (back/forward) | The current `:key="task-<id>"` makes the page reload the ChatView on every navigation. BFCache restores would skip the reload. The composable's `onMounted` restore would still fire if the component does remount. Not a follow-up. |
| **Memory cleanup of stale localStorage entries** | Old task IDs persist in localStorage forever. Add a TTL-based cleanup if storage becomes a concern. Not a v1 issue (localStorage caps at ~5 MB). |
