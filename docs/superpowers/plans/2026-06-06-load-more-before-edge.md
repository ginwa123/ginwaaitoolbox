# Pagination "Load More" Trigger Should Fire Before the Scroll Edge

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the chat's lazy-load trigger fire noticeably **before** the user reaches the scroll edge, by combining the existing 200 px absolute floor with a new viewport-relative threshold that scales with the visible area.

**Architecture:** Extract the threshold math to a pure helper `computeLoadMoreThreshold(floor, ratio, containerHeight)` so it's unit-testable without a DOM. Add a new prop `loadMoreThresholdRatio?: number` (default `0.5`) to `<VirtualScroller>`. The component computes an `effectiveLoadMoreThreshold` (reactive on `containerHeight`) and uses it in the existing `onScroll` `st < threshold` / `bottom < threshold` checks. ChatView passes the new prop explicitly and updates its `load-more-threshold-reached` log line to record both the floor and the effective value so the dev console answers "why did the load fire *here*?".

**Tech Stack:** Vue 3 (`<script setup lang="ts" generic="T">`), TypeScript, Vitest. No backend changes.

---

## Scope Check

This is one focused UX fix to a single component + its only consumer (ChatView). Not multi-subsystem — one plan is appropriate.

## File Structure

| File | Responsibility |
|---|---|
| `src/apps/desktop/src/helpers/virtualScrollerThreshold.ts` *(new)* | Pure function `computeLoadMoreThreshold(floor, ratio, containerHeight) → px`. No DOM, no Vue. |
| `src/apps/desktop/src/helpers/__tests__/virtualScrollerThreshold.spec.ts` *(new)* | Vitest unit tests for the helper. Covers normal, large, tiny, zero, and malformed inputs. |
| `src/apps/desktop/src/helpers/VirtualScroller.vue` *(modify)* | Add `loadMoreThresholdRatio` prop; add `effectiveLoadMoreThreshold` computed; use it in `onScroll`; extend `loadMoreSuppressed` payload to include the effective value; update JSDoc. |
| `src/apps/desktop/src/components/ChatView.vue` *(modify)* | Pass `:load-more-threshold-ratio="0.5"` on the `<VirtualScroller>`; update the `load-more-threshold-reached` log line's `extra` to record the effective threshold (in addition to the absolute floor). |

No backend, no DB, no other consumer touches the new prop — it's additive with a default that improves all existing call sites.

---

## Task 1: Add the pure threshold helper + unit tests

**Files:**
- Create: `src/apps/desktop/src/helpers/virtualScrollerThreshold.ts`
- Create: `src/apps/desktop/src/helpers/__tests__/virtualScrollerThreshold.spec.ts`

This is the only piece of pure logic in the change. Extracting it lets us write 6-7 fast unit tests against every edge case (large viewport, tiny viewport, 0×0, NaN, negative) without mounting a Vue component. The component just calls the helper.

- [ ] **Step 1: Write the failing tests**

Create `src/apps/desktop/src/helpers/__tests__/virtualScrollerThreshold.spec.ts`:

```ts
import { describe, it, expect } from 'vitest'
import { computeLoadMoreThreshold } from '../virtualScrollerThreshold'

describe('computeLoadMoreThreshold', () => {
  it('uses the proportional value when it exceeds the absolute floor (normal viewport)', () => {
    // 1000px viewport, 0.5 ratio → 500px proportional, floor 200px → 500px wins
    expect(computeLoadMoreThreshold(200, 0.5, 1000)).toBe(500)
  })

  it('scales up on large viewports (1500px → 750px)', () => {
    // 1500 * 0.5 = 750, floor 200 → 750 wins
    expect(computeLoadMoreThreshold(200, 0.5, 1500)).toBe(750)
  })

  it('falls back to the floor on tiny viewports (300px < 200 / 0.5)', () => {
    // 300 * 0.5 = 150, floor 200 → 200 wins (the floor protects small viewports)
    expect(computeLoadMoreThreshold(200, 0.5, 300)).toBe(200)
  })

  it('falls back to the floor on a 0×0 container (initial-mount flicker)', () => {
    // Real DOM event: the container reads 0×0 for one frame after mount.
    // We must not derive a 0 threshold from that — use the floor instead.
    expect(computeLoadMoreThreshold(200, 0.5, 0)).toBe(200)
  })

  it('falls back to the floor when containerHeight is NaN', () => {
    expect(computeLoadMoreThreshold(200, 0.5, Number.NaN)).toBe(200)
  })

  it('falls back to the floor when containerHeight is negative', () => {
    // Defensive: a stale or malformed DOM read should never produce a
    // negative threshold. Use the floor.
    expect(computeLoadMoreThreshold(200, 0.5, -100)).toBe(200)
  })

  it('falls back to the floor when the ratio is 0 (prop disabled)', () => {
    // A consumer can pass 0 to opt out of the proportional mode entirely.
    expect(computeLoadMoreThreshold(200, 0, 1000)).toBe(200)
  })

  it('falls back to the floor when the ratio is NaN', () => {
    expect(computeLoadMoreThreshold(200, Number.NaN, 1000)).toBe(200)
  })

  it('honors a custom absolute floor (e.g. 400px)', () => {
    // A consumer raising the floor for slow APIs should still get the
    // proportional bonus layered on top.
    expect(computeLoadMoreThreshold(400, 0.5, 1000)).toBe(500) // max(400, 500)
    expect(computeLoadMoreThreshold(400, 0.5, 300)).toBe(400)  // max(400, 150)
  })

  it('uses a defensive default of 200px when the floor itself is NaN', () => {
    // A malformed prop value must not produce NaN downstream. The helper
    // returns a sane number so the caller can always compare to it.
    expect(computeLoadMoreThreshold(Number.NaN, 0.5, 1000)).toBe(500)
  })
})
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `timeout 30 bun run test:unit src/apps/desktop/src/helpers/__tests__/virtualScrollerThreshold.spec.ts 2>&1 | tail -n 30`

Expected: FAIL with `Failed to resolve import "../virtualScrollerThreshold"` (the module doesn't exist yet).

- [ ] **Step 3: Implement the helper**

Create `src/apps/desktop/src/helpers/virtualScrollerThreshold.ts`:

```ts
/**
 * Compute the effective `loadMore` threshold in pixels.
 *
 * The VirtualScroller fires `loadMore` when the user is within this many
 * pixels of the load edge. The threshold is the **larger** of:
 *
 *   - `absoluteFloor`  — the existing `loadMoreThreshold` prop, in px.
 *                        A safety net for small viewports and the 0×0
 *                        initial-mount flicker case.
 *   - `containerHeight * viewportRatio` — a proportion of the visible
 *                        area. Adapts to monitor size: half a screen on
 *                        a 600 px laptop viewport, half a screen on a
 *                        1200 px monitor.
 *
 * Taking `max(floor, proportional)` lets the component say "load at
 * least 200 px from the edge, but also load when the user is half a
 * screen away" — both at once, with one prop controlling the
 * proportional bit and the other keeping a sane minimum.
 *
 * Pure function (no DOM, no Vue) so the threshold math is unit-testable
 * and reusable by other scrollers.
 *
 * @param absoluteFloor    Minimum threshold in px. Default sentinel: 200.
 * @param viewportRatio    Proportion of `containerHeight`. Use 0 to opt
 *                         out of the proportional mode (floor only).
 * @param containerHeight  Current container height in px. The caller
 *                         passes the live value (e.g.
 * `containerRef.value.clientHeight` or the scroller's cached
 * `containerHeight` ref) so this stays reactive without re-mounting.
 * @returns Effective threshold in px, always a finite, positive number.
 */
export function computeLoadMoreThreshold(
  absoluteFloor: number,
  viewportRatio: number,
  containerHeight: number,
): number {
  const safeFloor = Number.isFinite(absoluteFloor) ? absoluteFloor : 200
  if (!Number.isFinite(viewportRatio) || viewportRatio <= 0) {
    return safeFloor
  }
  if (!Number.isFinite(containerHeight) || containerHeight <= 0) {
    return safeFloor
  }
  const proportional = containerHeight * viewportRatio
  return Math.max(safeFloor, proportional)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `timeout 30 bun run test:unit src/apps/desktop/src/helpers/__tests__/virtualScrollerThreshold.spec.ts 2>&1 | tail -n 20`

Expected: PASS, all 10 tests green.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/helpers/virtualScrollerThreshold.ts \
        src/apps/desktop/src/helpers/__tests__/virtualScrollerThreshold.spec.ts
git commit -m "feat(virtual-scroller): add computeLoadMoreThreshold helper"
```

---

## Task 2: Wire the new prop into VirtualScroller + ChatView

**Files:**
- Modify: `src/apps/desktop/src/helpers/VirtualScroller.vue`
  - Add the `loadMoreThresholdRatio` prop (with JSDoc) to the `defineProps` block.
  - Add a top-level `import { computeLoadMoreThreshold } from './virtualScrollerThreshold'`.
  - Add a `const effectiveLoadMoreThreshold = computed(() => computeLoadMoreThreshold(props.loadMoreThreshold, props.loadMoreThresholdRatio, containerHeight.value))`.
  - Replace the four `props.loadMoreThreshold` references inside `onScroll` (lines 353, 355, 366, 368) with `effectiveLoadMoreThreshold.value`.
  - Extend the `loadMoreSuppressed` event payload to include the effective value (currently the `extra` log line in ChatView hard-codes `loadMoreThreshold: 200`).
  - Update the prop's JSDoc to describe the combined floor + ratio behavior.
- Modify: `src/apps/desktop/src/components/ChatView.vue`
  - Add `:load-more-threshold-ratio="0.5"` to the `<VirtualScroller>` (around line 1508).
  - Update the `load-more-threshold-reached` log line's `extra` (around line 936) to record the effective threshold, e.g. `extra: { hasMore, loadMoreThreshold: 200, loadMoreThresholdRatio: 0.5, effectiveLoadMoreThreshold: ??? }`. The effective value comes from `virtualScrollerRef.value.effectiveLoadMoreThreshold` (a `ComputedRef<number>`, so read `.value`).

This is the integration step. The component's `onScroll` is already the single source of truth for the `loadMore` emit — we just swap the literal it compares against.

- [ ] **Step 1: Add the prop to VirtualScroller's `defineProps`**

In `src/apps/desktop/src/helpers/VirtualScroller.vue`, the `withDefaults` block currently ends at line 104 with `loadMoreAtTop: false,`. Add the new prop declaration *before* the closing `})` so the defaults array stays alphabetically tidy. The new prop is inserted between `loadMoreThreshold` (line 82-99) and `loadMoreAtTop` (line 91-96) in the type literal, and after `loadMoreThreshold: 200,` in the defaults literal.

Replace the existing prop block:

```ts
    /**
     * Distance in pixels from the load edge at which the scroller emits
     * `loadMore`. If `loadMoreAtTop` is `true` (paginating older items
     * by prepending), this is measured from the top of the scrollable
     * area; otherwise from the bottom.
     *
     * Default 200px gives the parent a comfortable window to fetch and
     * prepend the next page before the user actually reaches the edge.
     * Lower it if your API is very fast and you want to start prepending
     * later (less wasted work); raise it if your API is slow and you
     * want to start prepending earlier (smoother scroll).
     *
     * The emit is debounced (~200ms) and is suppressed while
     * `beginPreserve`/`endPreserve` is in flight, so a single
     * scroll-to-edge gesture won't fire `loadMore` multiple times.
     */
    loadMoreThreshold?: number
    /**
     * If `true`, the scroller emits `loadMore` when the user scrolls
     * within `loadMoreThreshold` of the **top** — use this when you're
     * prepending older items (chat history, activity feeds, logs).
     * `loadMoreAtTop` should be paired with `beginPreserve`/`endPreserve`
     * in the parent so the user's scroll position doesn't jump when the
     * new items are inserted at index 0.
     *
     * If `false` (the default), the scroller emits `loadMore` when the
     * user scrolls within `loadMoreThreshold` of the **bottom** — use
     * this for "load more on demand" patterns where new content is
     * appended past the visible area.
     */
    loadMoreAtTop?: boolean
```

with:

```ts
    /**
     * Distance in pixels from the load edge at which the scroller emits
     * `loadMore`. If `loadMoreAtTop` is `true` (paginating older items
     * by prepending), this is measured from the top of the scrollable
     * area; otherwise from the bottom.
     *
     * Acts as the **absolute floor** for the effective threshold. The
     * actual threshold used in the `loadMore` check is
     * `max(loadMoreThreshold, containerHeight * loadMoreThresholdRatio)`,
     * so the scroller fires `loadMore` when the user is within EITHER
     * the floor OR the proportional distance of the load edge —
     * whichever is larger.
     *
     * Default 200px keeps the trigger safe on small viewports and during
     * the 0×0 initial-mount flicker. Raise it (e.g. 400-600px) for very
     * slow APIs that need a longer fetch head-start.
     *
     * The emit is debounced (~200ms) and is suppressed while
     * `beginPreserve`/`endPreserve` is in flight, so a single
     * scroll-to-edge gesture won't fire `loadMore` multiple times.
     */
    loadMoreThreshold?: number
    /**
     * Proportion of the container's visible height (`clientHeight`) that
     * the effective threshold should track. Combined with
     * `loadMoreThreshold` as `effective = max(loadMoreThreshold,
     * containerHeight * loadMoreThresholdRatio)`.
     *
     * Default `0.5` means "fire `loadMore` when the user is within half
     * a screen of the load edge" — the same heuristic used by Slack,
     * Discord, and iMessage. On a 1000 px viewport this gives a 500 px
     * effective threshold; on a 600 px viewport, 300 px. The absolute
     * `loadMoreThreshold` floor (200 px) protects tiny viewports where
     * the proportional value would be smaller.
     *
     * Set to `0` to opt out of the proportional mode entirely
     * (floor only). The threshold is computed in
     * `computeLoadMoreThreshold` (a pure helper, unit-tested).
     */
    loadMoreThresholdRatio?: number
    /**
     * If `true`, the scroller emits `loadMore` when the user scrolls
     * within `loadMoreThreshold` of the **top** — use this when you're
     * prepending older items (chat history, activity feeds, logs).
     * `loadMoreAtTop` should be paired with `beginPreserve`/`endPreserve`
     * in the parent so the user's scroll position doesn't jump when the
     * new items are inserted at index 0.
     *
     * If `false` (the default), the scroller emits `loadMore` when the
     * user scrolls within `loadMoreThreshold` of the **bottom** — use
     * this for "load more on demand" patterns where new content is
     * appended past the visible area.
     */
    loadMoreAtTop?: boolean
```

And in the defaults literal (line 98-104), add `loadMoreThresholdRatio: 0.5,` after the `loadMoreThreshold: 200,` line:

```ts
  {
    totalCount: 0,
    buffer: 5,
    defaultItemHeight: 100,
    loadMoreThreshold: 200,
    loadMoreThresholdRatio: 0.5,
    loadMoreAtTop: false,
  },
)
```

- [ ] **Step 2: Add the import + computed threshold**

In the `<script setup lang="ts" generic="T">` block of `VirtualScroller.vue`, the imports are at the top (line 1-2):

```ts
import { ref, computed, onMounted, onUnmounted, nextTick, watch } from 'vue'
```

Add a new import line right after it (alphabetical with the existing relative import convention):

```ts
import { computeLoadMoreThreshold } from './virtualScrollerThreshold'
```

Then, right after the existing `isScrollable` computed (line 179-182) and before the watch on `isScrollable` (line ~190), add:

```ts
/**
 * Effective distance (in px) from the load edge at which the scroller
 * emits `loadMore`. Recomputed whenever the container's height changes
 * (via the `containerHeight` ref, which is updated in `onScroll`).
 *
 * Combines the absolute `loadMoreThreshold` floor (default 200 px) with
 * the proportional `loadMoreThresholdRatio` (default 0.5, i.e. half a
 * screen). Exposed on the instance so the parent can read it for
 * logging ("effective threshold was 500 px when loadMore fired") and
 * so the integration tests can assert against a single value rather
 * than duplicating the max() logic.
 */
const effectiveLoadMoreThreshold = computed(() =>
  computeLoadMoreThreshold(
    props.loadMoreThreshold,
    props.loadMoreThresholdRatio,
    containerHeight.value,
  ),
)
```

Then update the `defineExpose(...)` block near the end of the file (the one that currently exposes `isScrollable`, `containerRef`, etc.) to also expose `effectiveLoadMoreThreshold` so the parent can read it.

Find the existing `defineExpose({` line and add `effectiveLoadMoreThreshold,` to the exposed object (one line per exposed ref, alphabetical with its neighbors).

- [ ] **Step 3: Use the effective threshold in `onScroll`**

In the same file, the `onScroll` callback (lines 318-377) uses `props.loadMoreThreshold` four times. Replace each occurrence with `effectiveLoadMoreThreshold.value`.

The current block (lines 352-371):

```ts
    if (props.loadMoreAtTop) {
      if (st < props.loadMoreThreshold && props.items.length > 0) {
        emit('loadMore')
      } else if (st < props.loadMoreThreshold && props.items.length === 0) {
        // User is near the top but there are no items yet — nothing
        // to "load more of". This is the "empty list, scrolled to
        // top" case (rare; usually we wouldn't be at the top of
        // an empty list, but guard it).
        emit('loadMoreSuppressed', 'no-items')
      }
      // else: user is just not near the top yet — normal scrolling,
      // not a suppression. Don't emit.
    } else {
      const bottom = target.scrollHeight - st - target.clientHeight
      if (bottom < props.loadMoreThreshold && props.items.length > 0) {
        emit('loadMore')
      } else if (bottom < props.loadMoreThreshold && props.items.length === 0) {
        emit('loadMoreSuppressed', 'no-items')
      }
      // else: user is just not near the bottom yet
    }
```

becomes:

```ts
    const threshold = effectiveLoadMoreThreshold.value
    if (props.loadMoreAtTop) {
      if (st < threshold && props.items.length > 0) {
        emit('loadMore')
      } else if (st < threshold && props.items.length === 0) {
        // User is near the top but there are no items yet — nothing
        // to "load more of". This is the "empty list, scrolled to
        // top" case (rare; usually we wouldn't be at the top of
        // an empty list, but guard it).
        emit('loadMoreSuppressed', 'no-items')
      }
      // else: user is just not near the top yet — normal scrolling,
      // not a suppression. Don't emit.
    } else {
      const bottom = target.scrollHeight - st - target.clientHeight
      if (bottom < threshold && props.items.length > 0) {
        emit('loadMore')
      } else if (bottom < threshold && props.items.length === 0) {
        emit('loadMoreSuppressed', 'no-items')
      }
      // else: user is just not near the bottom yet
    }
```

The single `const threshold = effectiveLoadMoreThreshold.value` line avoids re-reading the computed four times in the same synchronous block (and keeps the diff minimal — the four conditionals are unchanged).

- [ ] **Step 4: Pass the prop from ChatView**

In `src/apps/desktop/src/components/ChatView.vue`, find the `<VirtualScroller>` block (around line 1508-1520):

```vue
        <VirtualScroller
          v-if="isLoading || messageGroups.length > 0"
          ref="virtualScrollerRef"
          :items="messageGroups"
          :total-count="0"
          :buffer="3"
          :default-item-height="200"
          :load-more-threshold="200"
          :load-more-at-top="true"
          @load-more="handleLoadMore"
          @load-more-suppressed="handleLoadMoreSuppressed"
          @scroll="handleVirtualScroll"
          @scrollability-change="scrollerIsScrollable = $event"
        >
```

Add `:load-more-threshold-ratio="0.5"` right after `:load-more-threshold="200"` and before `:load-more-at-top="true"` so the three lazy-load props are visually grouped:

```vue
        <VirtualScroller
          v-if="isLoading || messageGroups.length > 0"
          ref="virtualScrollerRef"
          :items="messageGroups"
          :total-count="0"
          :buffer="3"
          :default-item-height="200"
          :load-more-threshold="200"
          :load-more-threshold-ratio="0.5"
          :load-more-at-top="true"
          @load-more="handleLoadMore"
          @load-more-suppressed="handleLoadMoreSuppressed"
          @scroll="handleVirtualScroll"
          @scrollability-change="scrollerIsScrollable = $event"
        >
```

(The default is also 0.5, so this is technically redundant — but making it explicit on the only consumer pins the UX choice to the call site and survives any future change to the scroller's default. Comment in the plan: "explicit at the call site so future default changes don't accidentally alter chat behavior.")

- [ ] **Step 5: Update the `load-more-threshold-reached` log line**

In `src/apps/desktop/src/components/ChatView.vue`, find the `handleLoadMore` function (around line 849). The `load-more-threshold-reached` log line (around line 930-940) currently records a hard-coded `loadMoreThreshold: 200` in `extra`. Update it to record the effective threshold so the dev console answers "why did the load fire *here*?" — the floor alone is misleading once the effective threshold is much larger:

Replace:

```ts
  scrollLogger.info({
    ...ctx,
    caller: 'handleLoadMore',
    reason: 'load-more-threshold-reached',
    extra: {
      hasMore: hasMoreMessages.value,
      loadMoreThreshold: 200, // mirrors the prop on <VirtualScroller>
      isLLMProcessing: isLLMProcessing.value,
      isAtBottom: isAtBottom.value,
    },
  })
```

with:

```ts
  const effectiveThreshold =
    virtualScrollerRef.value?.effectiveLoadMoreThreshold.value ?? 200
  scrollLogger.info({
    ...ctx,
    caller: 'handleLoadMore',
    reason: 'load-more-threshold-reached',
    extra: {
      hasMore: hasMoreMessages.value,
      loadMoreThreshold: 200, // absolute floor, mirrors the prop on <VirtualScroller>
      loadMoreThresholdRatio: 0.5, // mirrors the prop on <VirtualScroller>
      effectiveLoadMoreThreshold: effectiveThreshold, // max(floor, containerHeight * ratio)
      isLLMProcessing: isLLMProcessing.value,
      isAtBottom: isAtBottom.value,
    },
  })
```

The `?? 200` fallback is the same defensive default the helper uses (in case the VirtualScroller ref is unbound, e.g. the user navigated away during the scroll debounce).

- [ ] **Step 6: Type-check the change**

Run: `timeout 60 bun run type-check 2>&1 | tail -n 30`

Expected: clean exit. Specifically, the `defineExpose` change in Step 2 must surface `effectiveLoadMoreThreshold` as a `ComputedRef<number>` on the `VirtualScrollerExposed` interface in ChatView (lines ~244-254). The `?.value` read in Step 5 already implies that — if `vue-tsc` complains about a missing field on `VirtualScrollerExposed`, add `effectiveLoadMoreThreshold: ComputedRef<number>` to that interface.

If the `VirtualScrollerExposed` interface needs updating, the change is:

```ts
interface VirtualScrollerExposed {
  isScrollable: ComputedRef<boolean>
  containerRef: Ref<HTMLElement | null>
  scrollToBottom: (behavior?: ScrollBehavior) => void
  beginPreserve: (newItemsCount: number) => void
  endPreserve: () => Promise<void>
  effectiveLoadMoreThreshold: ComputedRef<number>  // ← new line
}
```

(Add the `ComputedRef` and `Ref` imports from `vue` if not already present — they almost certainly are, since `isScrollable` and `containerRef` are already typed that way.)

- [ ] **Step 7: Run the full test suite + build**

Run: `timeout 120 bun run test:unit 2>&1 | tail -n 30`

Expected: all 10 new tests in `virtualScrollerThreshold.spec.ts` pass; all pre-existing tests (autoStickGate, sseClient, sidebarActiveState, App, etc.) continue to pass.

Then: `timeout 120 bun run build 2>&1 | tail -n 30`

Expected: clean exit. **Per project convention, use `bun run build` (not `bun run build-only`) so `vue-tsc --build` runs and catches the type errors** that Step 6 surfaced.

- [ ] **Step 8: Manual smoke test**

In a dev session (`bun run dev`), open a chat with a long history (≥ 100 messages), then:

1. Open the browser dev tools console.
2. Filter for the `load-more-threshold-reached` info line in `scrollLogger`.
3. Slowly scroll the chat upward toward the top.
4. **Expected:** the line fires when `distanceFromTop` is roughly `max(200, containerHeight * 0.5)` — i.e. noticeably before reaching scrollTop=0. On a typical 800-1000 px chat panel, that should be around 400-500 px from the top.
5. **Negative control:** open a chat with ≤ 5 messages (the "container not scrollable" case). The "Load more messages" button should still appear (this fix does NOT touch the non-scrollable path — see ChatView lines 1483-1505).
6. **Negative control:** start an LLM stream, then try to scroll to the top during streaming. The `auto-stick-active` guard should still suppress the load (per `autoStickGate.ts`) — confirm via the `load-more-suppressed` log line, which should now carry `guard: 'auto-stick-active', source: 'ChatView'`.

- [ ] **Step 9: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/helpers/VirtualScroller.vue \
        src/apps/desktop/src/components/ChatView.vue
git commit -m "feat(chat): loadMore fires half a screen before the scroll edge"
```

---

## Self-Review

**1. Spec coverage**

The user's request was: "I have to scroll until the edge; load should happen *before* the edge."

- ✅ "Load before the edge" — Task 2 Step 3 swaps the literal 200 px comparison for `max(200, containerHeight * 0.5)`, which on a normal viewport means the trigger fires ~half a screen before the user reaches the edge.
- ✅ Adapts to viewport — the proportional bit scales with `containerHeight`; a 600 px laptop and a 1200 px monitor both get "half a screen".
- ✅ Doesn't break small viewports — the 200 px absolute floor (Step 1's unit test for 300 px viewport) keeps the trigger from disappearing on tiny panels.
- ✅ Doesn't break the non-scrollable button — the "Load more messages" button path is untouched (Step 8's negative control covers it).
- ✅ Doesn't break the streaming-time suppression — the auto-stick gate is upstream of the threshold check; the new threshold only changes *when* `loadMore` *can* fire, not whether the parent *acts* on it. Covered by Step 8's negative control.

**2. Placeholder scan**

- ❌ "TBD" / "TODO" / "implement later" / "fill in details" — none.
- ❌ "Add appropriate error handling" / "add validation" / "handle edge cases" — the only defensive logic is in `computeLoadMoreThreshold` (NaN/negative/zero), and it's spelled out in Step 1 with full test code.
- ❌ "Write tests for the above" (without code) — all tests are spelled out in full in Task 1 Step 1.
- ❌ "Similar to Task N" (without repeating the code) — every code block is fully written out, no cross-references.
- ❌ Steps that describe what to do without showing how — every prop edit, every `onScroll` change, every Vue type signature has its actual code in the plan.
- ❌ References to types, functions, or methods not defined in any task — `computeLoadMoreThreshold` is defined in Task 1, used in Task 2. `effectiveLoadMoreThreshold` is defined in Task 2 Step 2, used in Task 2 Step 3 and Step 5. `VirtualScrollerExposed` is referenced in Step 6 with the exact one-line addition.

**3. Type consistency**

- `computeLoadMoreThreshold(floor: number, ratio: number, containerHeight: number): number` — used the same way in Task 1's tests, Task 1's implementation, and Task 2 Step 2's computed.
- `effectiveLoadMoreThreshold: ComputedRef<number>` — declared in Task 2 Step 2's `defineExpose`, read in Task 2 Step 5 as `?.value ?? 200`, typed in the `VirtualScrollerExposed` interface in Task 2 Step 6.
- `loadMoreThresholdRatio: 0.5` — used as the prop default (Task 2 Step 1), passed from ChatView (Task 2 Step 4), logged (Task 2 Step 5). Same value in all three places.
- `loadMoreThreshold: 200` (the floor) — kept identical to the previous behavior. Test in Task 1 Step 1 explicitly covers the "floor wins on tiny viewports" case so a future refactor can't silently lower the floor.

No type or naming drift found.

---

## Out of Scope

- **"Infinite scroll" (auto-fire without user action)** — out of scope. The trigger remains scroll-driven.
- **Lowering the threshold for power scrollers** — the new prop is symmetric (top and bottom). If the chat needs asymmetric tuning later, add a second prop; don't add it speculatively now.
- **Persisting the threshold across sessions** — the default is 0.5 and ChatView hard-passes 0.5. No need to persist; the value is a UX choice, not a user preference (yet).
- **A visual "loading" indicator at the trigger distance** — the existing "Load more messages" button and the `isLoadingMore` spinner cover the in-flight feedback. No new UI.
- **Backend / API changes** — `loadChatHistory(true)` is unchanged. PAGE_SIZE is unchanged. The trigger fires earlier; that's the whole change.
