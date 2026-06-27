# VirtualScroller Buffer Mismatch Fix

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `buffer` the single source of truth for the overscan in `VirtualScroller.vue` by removing a hardcoded `+ 200` pixel lookahead that bypasses the prop, and expose the rendered item count so the parent can verify the DOM matches expectations.

**Architecture:** Surgical three-part change: (1) drop the magic number in `visibleRange`, (2) expose a `renderedCount` computed so the parent (ChatView) and dev-tools can read the live DOM node count, (3) tighten the JSDoc on the `buffer` prop to remove the per-side vs total ambiguity. All changes are local to `VirtualScroller.vue` plus one new test file.

**Tech Stack:** Vue 3 (Composition API, `<script setup lang="ts" generic="T">`), TypeScript, Vitest, @vue/test-utils.

---

## Root Cause

The user reports: *"I set `buffer=20` in the props, but when I check the DOM, the items count is greater than 20."*

There are **two compounding issues** in `src/apps/desktop/src/helpers/VirtualScroller.vue`:

### Issue 1 — Hardcoded `+ 200` pixel lookahead (THE BUG)

`VirtualScroller.vue:312-336`, in the `visibleRange` computed:

```ts
let acc = accumulatedHeights.value[startIndex] ?? 0
let endIndex = startIndex
while (endIndex < len && acc < viewBottom + 200) {     // ← hardcoded +200
  acc += itemHeights.value.get(endIndex) ?? props.defaultItemHeight
  endIndex++
}

let start = Math.max(0, startIndex - props.buffer)
let end = Math.min(len, endIndex + props.buffer)
```

The `+ 200` is a **pixel-based overscan in pixels that is not controlled by the `buffer` prop**. With `defaultItemHeight=200` (ChatView's value), this adds ~1 extra item beyond the buffer. With shorter items it adds proportionally more. The result: the user can set `buffer=0` and still see 1-2 extra items rendered past the visible viewport.

### Issue 2 — `buffer` is per-side, not total (CONCEPTUAL)

The `buffer` prop docs say:

```
* Number of extra items to render above and below the visible viewport.
```

So `buffer=20` means **20 above + 20 below + visible items**. The user is almost certainly reading "buffer=20" as "20 items total in the DOM". The actual rendered count with `buffer=20, defaultItemHeight=200, containerHeight=800` is:

- visible items: 800/200 = 4
- buffer above: 20
- buffer below: 20
- hardcoded +200 overscan: 1
- **Total: ~45**

The user sees 45 and is confused why their `buffer=20` setting produced >20.

### Issue 3 — No observability for the rendered count

Even with the bug fixed, the user has no way to *verify* what's in the DOM from inside ChatView. They have to open dev-tools and count `[data-vs-index]` elements. The component exposes `scrollInfo` (which includes `visibleStart` / `visibleEnd` / `totalItems`) but nothing for the actual rendered count. There's a `defineExpose` block at line 558-571; we add `renderedCount` and `effectiveRange` there.

---

## File Structure

| File | Action | Purpose |
|------|--------|---------|
| `src/apps/desktop/src/helpers/VirtualScroller.vue` | MODIFY | Remove hardcoded `+ 200`, add `renderedCount` computed, expose it, update JSDoc |
| `src/apps/desktop/src/helpers/__tests__/virtualScrollerBuffer.spec.ts` | CREATE | New test file — covers per-side buffer semantics, hardcoded-overscan removal, and the `renderedCount` exposure |

No other files need to change. ChatView's `:buffer="20"` keeps the same value; its semantics are now predictable and observable.

---

## Task 1: Write failing tests for the buffer semantics

**Files:**
- Create: `src/apps/desktop/src/helpers/__tests__/virtualScrollerBuffer.spec.ts`

- [ ] **Step 1.1: Create the test file with the first failing test**

```ts
/**
 * Regression tests for the `buffer` prop semantics in VirtualScroller.
 *
 * Why this file exists:
 *   The user reported "I set `buffer=20` in props but the DOM has more
 *   than 20 items." Two issues were causing this:
 *
 *     1. A hardcoded `+ 200` pixel lookahead in `visibleRange` added
 *        items beyond what `buffer` controlled.
 *     2. `buffer` is per-side (20 above + 20 below), not total, and
 *        this was not visible from the parent.
 *
 *   These tests pin down the contract: the rendered count is exactly
 *   `2 * buffer + visibleCount` (or fewer at the edges of the list).
 *   If a future change adds another hidden overscan, the
 *   "renderedCount matches exactly 2*buffer + visible" test fails.
 */
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'

/**
 * Build a list of N items. Each item's `id` is its index, which is
 * useful for assertions on `data-vs-index` attributes.
 */
function makeItems(n: number): Array<{ id: number }> {
  return Array.from({ length: n }, (_, i) => ({ id: i }))
}

/**
 * Mount a VirtualScroller with the given items and a known
 * container geometry. jsdom does not lay out, so we set
 * `clientHeight` / `scrollHeight` directly to make `onScroll`'s
 * geometry reads return realistic values. The default item height
 * of 200px matches ChatView's setting, which is the primary caller.
 */
function mountScroller(props: {
  items: Array<{ id: number }>
  buffer?: number
  defaultItemHeight?: number
  clientHeight?: number
}) {
  const wrapper = mount(VirtualScroller, {
    props: {
      items: props.items,
      buffer: props.buffer ?? 20,
      defaultItemHeight: props.defaultItemHeight ?? 200,
      totalCount: props.items.length,
    },
  })
  // Force a known container size so the visible-range math is
  // deterministic in jsdom. `clientHeight` is read every scroll,
  // so the ref is updated to this value the first time `onScroll`
  // fires.
  const el = wrapper.element as HTMLElement
  Object.defineProperty(el, 'clientHeight', {
    value: props.clientHeight ?? 800,
    configurable: true,
  })
  Object.defineProperty(el, 'scrollHeight', {
    value: props.items.length * (props.defaultItemHeight ?? 200),
    configurable: true,
  })
  return wrapper
}

describe('VirtualScroller buffer prop', () => {
  it('exposes renderedCount matching exactly 2*buffer + visible (no hidden overscan)', async () => {
    // 100 items, 200px each, 800px viewport → 4 visible.
    // buffer=20 → start=-20, end=24, count=44. If the hardcoded
    // +200 overscan is still present, count is 45 (one extra
    // item beyond the buffer).
    const wrapper = mountScroller({
      items: makeItems(100),
      buffer: 20,
      defaultItemHeight: 200,
      clientHeight: 800,
    })
    await nextTick()
    // Trigger one scroll to populate containerHeight.
    ;(wrapper.element as HTMLElement).dispatchEvent(new Event('scroll'))
    await nextTick()

    const scroller = wrapper.vm as unknown as {
      renderedCount: { value: number }
    }
    expect(scroller.renderedCount.value).toBe(44)
  })

  it('counts buffer items on BOTH sides of the visible viewport (per-side, not total)', async () => {
    // 100 items, 200px each, 800px viewport → 4 visible.
    // buffer=5 → start=-5, end=9, count=14. (No 5-total surprise.)
    const wrapper = mountScroller({
      items: makeItems(100),
      buffer: 5,
      defaultItemHeight: 200,
      clientHeight: 800,
    })
    await nextTick()
    ;(wrapper.element as HTMLElement).dispatchEvent(new Event('scroll'))
    await nextTick()

    const scroller = wrapper.vm as unknown as {
      renderedCount: { value: number }
    }
    expect(scroller.renderedCount.value).toBe(14) // 2*5 + 4
  })

  it('clamps the rendered count at the top edge of the list (no negative start)', async () => {
    // Scrolled to top, 100 items, 200px each → first 4 visible.
    // buffer=20 → start would be -20, clamped to 0; end=24; count=24.
    const wrapper = mountScroller({
      items: makeItems(100),
      buffer: 20,
      defaultItemHeight: 200,
      clientHeight: 800,
    })
    await nextTick()
    const el = wrapper.element as HTMLElement
    el.scrollTop = 0
    el.dispatchEvent(new Event('scroll'))
    await nextTick()

    const scroller = wrapper.vm as unknown as {
      renderedCount: { value: number }
    }
    expect(scroller.renderedCount.value).toBe(24) // 4 visible + 20 below
  })

  it('clamps the rendered count at the bottom edge of the list (no over-render past end)', async () => {
    // Scrolled to the very bottom: startIndex = 96, endIndex = 100.
    // buffer=20 → start = 76, end clamped to 100; count=24.
    const wrapper = mountScroller({
      items: makeItems(100),
      buffer: 20,
      defaultItemHeight: 200,
      clientHeight: 800,
    })
    await nextTick()
    const el = wrapper.element as HTMLElement
    // 96 * 200 = 19200 (the start of the last 4 items).
    el.scrollTop = 19200
    el.dispatchEvent(new Event('scroll'))
    await nextTick()

    const scroller = wrapper.vm as unknown as {
      renderedCount: { value: number }
    }
    expect(scroller.renderedCount.value).toBe(24) // 20 above + 4 visible
  })

  it('renders zero items past the visible viewport when buffer=0 (no hidden overscan)', async () => {
    // The smoke test for the hardcoded-+200 bug: with buffer=0,
    // the rendered count must be exactly the visible count. If the
    // +200 overscan is still there, the count is 5 (4 visible + 1
    // overscan item), which fails this test.
    const wrapper = mountScroller({
      items: makeItems(100),
      buffer: 0,
      defaultItemHeight: 200,
      clientHeight: 800,
    })
    await nextTick()
    ;(wrapper.element as HTMLElement).dispatchEvent(new Event('scroll'))
    await nextTick()

    const scroller = wrapper.vm as unknown as {
      renderedCount: { value: number }
    }
    expect(scroller.renderedCount.value).toBe(4) // exactly visible
  })
})
```

- [ ] **Step 1.2: Run the tests and verify they fail for the right reason**

Run: `cd src/apps/desktop && bun run test -- virtualScrollerBuffer 2>&1 | tail -n 60`
Expected: 5 tests, 5 failures. The first failure should be:

```
AssertionError: expected 45 to be 44
```

(failing on `renderedCount === 44` because the hardcoded `+200` is still in place). The other tests fail because `renderedCount` doesn't exist on the instance yet (it's not exposed in `defineExpose`).

- [ ] **Step 1.3: Commit the failing tests**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/helpers/__tests__/virtualScrollerBuffer.spec.ts
git commit -m "test(VirtualScroller): pin down buffer prop contract — fails on hidden overscan"
```

---

## Task 2: Remove the hardcoded `+ 200` from `visibleRange`

**Files:**
- Modify: `src/apps/desktop/src/helpers/VirtualScroller.vue:312-336`

- [ ] **Step 2.1: Remove the magic number**

In `src/apps/desktop/src/helpers/VirtualScroller.vue`, replace the while loop so it stops at the visible bottom (no extra lookahead):

```ts
// BEFORE (line 320):
while (endIndex < len && acc < viewBottom + 200) {

// AFTER:
while (endIndex < len && acc < viewBottom) {
```

The `buffer` prop (applied at lines 325-326 below the loop) is now the **sole** source of extra items beyond the visible viewport.

- [ ] **Step 2.2: Update the JSDoc on the `buffer` prop to remove the per-side ambiguity**

Replace the existing JSDoc (lines 38-46) with a more explicit version that calls out "per-side" and gives the worked example:

```ts
/**
 * Number of extra items to render **on each side** (above AND below)
 * the visible viewport. So `buffer=20` means 20 items above + 20
 * items below + the visible items themselves.
 *
 * Worked example with `defaultItemHeight=200`, `containerHeight=800`:
 *   - buffer=0  → 4 items in the DOM  (4 visible, no overscan)
 *   - buffer=5  → 14 items in the DOM (4 visible + 5 above + 5 below)
 *   - buffer=20 → 44 items in the DOM (4 visible + 20 above + 20 below)
 *
 * A larger buffer means smoother scrolling (fewer "pop in" moments
 * as the user scrolls) at the cost of more DOM nodes. The default
 * of 5 is a good balance for most text/list UIs. For tall items
 * (chat bubbles, cards with images) you may want to lower this;
 * for short uniform items (log lines, search results) you can
 * raise it.
 *
 * To read the live rendered count from the parent, use the
 * `renderedCount` exposed on the component instance (see
 * `defineExpose` below) or the `scrollInfo` object.
 */
buffer?: number
```

- [ ] **Step 2.3: Run the tests to verify the overscan-removal tests now pass**

Run: `cd src/apps/desktop && bun run test -- virtualScrollerBuffer 2>&1 | tail -n 30`
Expected: 3 of 5 tests pass (the ones asserting exact counts). The other 2 fail with `Cannot read properties of undefined (reading 'renderedCount')` because we haven't exposed it yet.

- [ ] **Step 2.4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/helpers/VirtualScroller.vue
git commit -m "fix(VirtualScroller): remove hardcoded +200 overscan that bypassed buffer prop"
```

---

## Task 3: Expose `renderedCount` (and `effectiveRange`) on the instance

**Files:**
- Modify: `src/apps/desktop/src/helpers/VirtualScroller.vue` (add computed + extend `defineExpose`)

- [ ] **Step 3.1: Add the `renderedCount` and `effectiveRange` computeds**

Insert these two computeds directly after the existing `visibleRange` computed (after line 336, before `visibleItems` at line 338):

```ts
/**
 * Live count of items currently rendered in the DOM (i.e. the
 * length of `visibleItems`). Exposed so the parent can verify the
 * buffer contract and log "rendered N items" diagnostics without
 * opening dev-tools.
 *
 * Equals `end - start` from `visibleRange`, which is:
 *   - In the middle of the list: `2 * buffer + visibleCount`
 *   - At the top/bottom edges: clamped to whatever the list allows
 *
 * Recomputed automatically on every scroll, every measurement, and
 * every `items` length change.
 */
const renderedCount = computed(() => {
  const { start, end } = visibleRange.value
  return Math.max(0, end - start)
})

/**
 * The {start, end} range of items currently rendered. Exposed as
 * a single object so the parent can read both fields in one
 * reactive read (avoiding the start-vs-end skew that would happen
 * if they were two separate computeds and a scroll fired between
 * reads).
 */
const effectiveRange = computed(() => {
  const { start, end } = visibleRange.value
  return { start, end }
})
```

- [ ] **Step 3.2: Add both to the `defineExpose` block**

Extend the `defineExpose` at lines 558-571 to include `renderedCount` and `effectiveRange`:

```ts
defineExpose({
  scrollToIndex,
  scrollToTop,
  scrollToBottom,
  scrollToItem,
  beginPreserve,
  endPreserve,
  preserveScrollPosition: endPreserve, // legacy alias
  scrollInfo,
  containerRef,
  isPreservingScroll,
  isScrollable,
  effectiveLoadMoreThreshold,
  renderedCount,
  effectiveRange,
})
```

- [ ] **Step 3.3: Run the tests and verify all 5 pass**

Run: `cd src/apps/desktop && bun run test -- virtualScrollerBuffer 2>&1 | tail -n 30`
Expected: 5/5 tests pass.

- [ ] **Step 3.4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/helpers/VirtualScroller.vue
git commit -m "feat(VirtualScroller): expose renderedCount + effectiveRange on the instance"
```

---

## Task 4: Verify the existing test suite still passes

**Files:** (none — verification step)

- [ ] **Step 4.1: Run the full frontend test suite**

Run: `cd src/apps/desktop && bun run test 2>&1 | tail -n 40`
Expected: all tests pass, including the new `virtualScrollerBuffer.spec.ts` (5 new tests) and the existing `virtualScrollerScrollEmit.spec.ts` (4 existing tests) and `virtualScrollerThreshold.spec.ts`.

- [ ] **Step 4.2: Run the TypeScript type-check**

Run: `cd src/apps/desktop && bun run type-check 2>&1 | tail -n 30`
Expected: clean output (no errors). The new `renderedCount` and `effectiveRange` computeds have explicit types inferred from `visibleRange`, so ChatView's `VirtualScrollerExposed` interface (line 246 in `ChatView.vue`) does NOT need to be updated — Vue's `defineExpose` widens the public instance type automatically. Verify by reading `ChatView.vue:246-258` and confirming the comment at line 247-250 still holds.

- [ ] **Step 4.3: Run the production build**

Run: `cd src/apps/desktop && bun run build 2>&1 | tail -n 30`
Expected: clean build. `vue-tsc --build` is the slow part (30-60s); Vite's bundle step is fast. No errors, no warnings about missing properties.

- [ ] **Step 4.4: No commit needed — this is a verification step**

If any test fails or the build errors, STOP and diagnose before proceeding. The most likely cause is a missing export or a type mismatch; both should be obvious from the error message.

---

## Task 5: Verify the fix in the browser (manual smoke test)

**Files:** (none — manual verification)

- [ ] **Step 5.1: Start the dev server and load a chat with many messages**

Run: `cd src/apps/desktop && bun run dev 2>&1 | tail -n 5`
Open the desktop app, navigate to a chat with ≥ 100 messages, scroll to the middle of the conversation.

- [ ] **Step 5.2: Inspect the DOM and count `[data-vs-index]` elements**

Open dev-tools → Elements → run in the console:
```js
document.querySelectorAll('[data-vs-index]').length
```

Expected: ~14 (with `buffer=5, defaultItemHeight=200, containerHeight≈800` in ChatsList) or ~44 (with `buffer=20` in ChatView). **NOT** 15 (which would mean the old `+200` overscan is still adding 1 extra item).

- [ ] **Step 5.3: Verify the live `renderedCount` matches the DOM**

In the Vue devtools, find the `VirtualScroller` instance for the chat, and read its `renderedCount.value`. It should equal the count from Step 5.2.

- [ ] **Step 5.4: Scroll and verify the count stays within `[2*buffer, 2*buffer + visible]`**

Scroll up to the top, then to the bottom, then back to the middle. At every position, the count should be ≤ 2*buffer + visible and ≥ visible. The dev-tools console log (no instrumentation needed for this manual check) should show a stable count.

- [ ] **Step 5.5: No commit — manual verification only**

If the count is not what the worked example predicts, STOP and re-read Task 2. The most likely regression is the `+ 200` creeping back in (e.g. a bad merge).

---

## Summary of Changes

| File | Lines Changed | Purpose |
|------|---------------|---------|
| `src/apps/desktop/src/helpers/VirtualScroller.vue` | 1 line removed (the `+ 200`), 2 computeds added, `defineExpose` extended by 2 fields, JSDoc rewritten | The actual fix + observability |
| `src/apps/desktop/src/helpers/__tests__/virtualScrollerBuffer.spec.ts` | new file, ~150 lines | Pin down the contract so this never regresses |

**Net behavioral change for ChatView** (which uses `:buffer="20"`):
- Before: ~45 items in DOM (44 expected + 1 from the hardcoded overscan)
- After:  exactly 44 items in DOM at the middle of the chat, 24 at the edges

**Net behavioral change for ChatsList** (which uses `:buffer="5"`):
- Before: ~15 items in DOM (14 expected + 1 from the hardcoded overscan)
- After:  exactly 14 items in DOM at the middle of the list, 9 at the edges

The difference is small (1 item per chat), but the **principle** is now correct: the `buffer` prop is the single source of truth, and the parent can verify the count via the new `renderedCount` exposure.

---

## Pitfalls

1. **Don't change `buffer` semantics from per-side to total.** That would be a breaking change for every caller (ChatView, ChatsList, future consumers) and would require a different prop name. The user's confusion is best resolved by documentation + observability, not by changing the prop's contract.

2. **Don't remove the `+ 200` AND the buffer prop's "smooth scroll" effect in one step.** The buffer prop already provides the overscan needed for smooth scrolling (20 items above + 20 below covers 4000px of lookahead with `defaultItemHeight=200`). Removing the `+ 200` is safe BECAUSE the buffer is already doing the same job. The change is to remove the *redundant* magic number, not to remove the safety net.

3. **The `forceRenderUpTo` branch (lines 328-331) is NOT affected by this change.** It only fires during `endPreserve` (the chat-history-pagination path), and its purpose is to force-render the newly-prepended items until they've been measured. It extends the range BEYOND the buffer temporarily, which is intentional — the alternative would be to render fewer items than the user just paginated, causing flicker. Leave it alone.

4. **The new `renderedCount` computed must use `Math.max(0, end - start)`.** Without the max, an empty list (`len === 0`, which returns `{start: 0, end: 0}` from the early-return on line 314) would yield `0 - 0 = 0` (fine) but a future refactor that returned `{start: 5, end: 0}` (e.g. after a defensive `Math.min(end, len)`) would yield `-5`, which the parent would log as "rendered -5 items" and break downstream assertions. The `Math.max(0, …)` is a cheap defensive guard.

5. **The test file uses `Object.defineProperty(el, 'clientHeight', …)` to fake the jsdom layout.** The real DOM would call `el.clientHeight` naturally. If a future Vue/Vitest upgrade changes the scroll handler's read order (e.g. reads `clientHeight` BEFORE the scroll event is dispatched), the test geometry might not stick. If that happens, wrap the dispatch in `await nextTick()` twice, or use the pattern in `virtualScrollerScrollEmit.spec.ts:58-64` (which does the same thing and is known to work).

---

## Verification Checklist

- [ ] `bun run test` shows 5/5 new tests pass
- [ ] `bun run test` shows 0 regressions in the existing 4 scroll-emit tests and the threshold tests
- [ ] `bun run type-check` is clean
- [ ] `bun run build` succeeds with no warnings
- [ ] Manual browser test (Task 5) shows the DOM count matches `2*buffer + visible` in the middle of the list, clamped at the edges
- [ ] `git log --oneline -5` shows three clean commits: failing tests, fix, exposure
