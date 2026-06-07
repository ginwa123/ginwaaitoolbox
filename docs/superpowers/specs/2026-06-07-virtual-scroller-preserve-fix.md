# VirtualScroller Preserve-Scroll Fix — Design

> **For agentic workers:** This is a design spec. After the user approves, the next step is to invoke the `superpowers:writing-plans` skill to create a bite-sized implementation plan.

**Goal:** Make `VirtualScroller.endPreserve()` correctly preserve the user's relative view position when a batch of items is prepended. Fixes the "bouncing" symptom observed with `PAGE_SIZE = 100` (and any `PAGE_SIZE` where the prepended items' summed height exceeds the loadMore threshold).

**Architecture:** Capture the user's `scrollTop` in `beginPreserve` alongside the existing anchor-offsetTop capture. Route both restore strategies in `endPreserve` (A: anchor in DOM, B: anchor not in DOM) through a new pure helper `computePreservedScrollTop()` that does the inverse-of-where-was-the-anchor math. Add a 1-character tweak to `forceRenderUpTo` so Strategy A works for medium `PAGE_SIZE` (Strategy B stays as the safety net for very large `PAGE_SIZE`). The helper gets 5 unit tests in the existing spec file. Surgical fix, single commit, worktree on `fix/chat-load-more-preserve-scroll-position`.

**Tech Stack:** Vue 3 (`<script setup lang="ts" generic="T">`), TypeScript, Vitest. No backend changes. No prop changes. No event changes.

---

## 1. Context — the bug and why it happens

### 1.1 Symptom

In a chat with `PAGE_SIZE = 100` and a long history, the user reports the message list "bounces up and down" when scrolling toward the top to paginate older messages. The pagination appears to fire rapidly in succession rather than once per page.

### 1.2 Root cause

`VirtualScroller.beginPreserve()` captures the anchor element's `offsetTop` before the prepend, but **does NOT capture the user's current `scrollTop`**. Then `endPreserve()` restores `scrollTop` to the anchor's **new** `offsetTop` (Strategy A) or the **sum of the new items' heights** (Strategy B) — both of which put the anchor at the very top of the viewport, not at the user's original relative position.

The correct restore math is:

```
newScrollTop = newAnchorOffsetTop + oldScrollTop - oldAnchorOffsetTop
```

Without the `- oldAnchorOffsetTop` term, the user is teleported to the new top, which is well within the loadMore threshold. The next scroll event fires `loadMore` again, another batch is prepended, the same broken restore runs, and the user sees the scroll position keep adjusting — visually, "bouncing".

### 1.3 A secondary issue: Strategy A never fires with `PAGE_SIZE >= ~13`

`endPreserve` sets `forceRenderUpTo.value = n - 1` (where `n` is the number of prepended items). This forces the scroller to mount items 0..n-1. The anchor element lives at `data-vs-index="${n}"` after the prepend, so it sits **right at the edge of the forced render window — not in the DOM**. Strategy A (the more accurate one, using the live `offsetTop`) therefore fails for any `PAGE_SIZE` greater than the visible-range-plus-buffer (~13 items with the current `buffer=3` and `defaultItemHeight=200`). Strategy B (sum of measured heights) is always used, which is correct in formula but uses cached measurements instead of live.

A 1-character change — `n - 1` → `n` — makes Strategy A work for medium `PAGE_SIZE`, while keeping Strategy B as the safety net for absurdly large `PAGE_SIZE` (where mounting `n` items would be too heavy).

---

## 2. Current state — the relevant code as-is

### 2.1 The capture side (`beginPreserve`, lines 445-457 of `VirtualScroller.vue`)

```ts
const beginPreserve = (newItemsCount: number) => {
  if (!containerRef.value || newItemsCount <= 0) return
  isPreservingScroll.value = true
  _pendingNewItemsCount = newItemsCount

  const content = containerRef.value.querySelector('.virtual-scroller-content')
  const anchorEl = content
    ? (content.querySelector('[data-vs-index="0"]') as HTMLElement | null)
    : null

  _anchorOffsetTopBefore = anchorEl ? anchorEl.offsetTop : 0
  console.log('[beginPreserve] anchorEl found:', !!anchorEl, 'offsetTop:', _anchorOffsetTopBefore)
}
```

`_anchorOffsetTopBefore` is a module-level `let` (line 243). The user's `scrollTop` is never captured.

### 2.2 The restore side (`endPreserve`, lines 463-505 of `VirtualScroller.vue`)

```ts
const endPreserve = async () => {
  if (!containerRef.value || _pendingNewItemsCount <= 0) {
    isPreservingScroll.value = false
    return
  }

  const n = _pendingNewItemsCount
  forceRenderUpTo.value = n - 1   // ← BUG: anchor is at index n, outside the forced window

  await nextTick()
  await new Promise<void>((r) => requestAnimationFrame(() => r()))
  await new Promise<void>((r) => requestAnimationFrame(() => r()))

  measureItems()
  updateAccumulatedHeights()

  const content = containerRef.value!.querySelector('.virtual-scroller-content')
  const anchorEl = content
    ? (content.querySelector(`[data-vs-index="${n}"]`) as HTMLElement | null)
    : null

  if (anchorEl) {
    const newST = anchorEl.offsetTop                         // ← BUG: no relative-position math
    console.log('[endPreserve] strategy A — anchorEl.offsetTop:', newST)
    containerRef.value!.scrollTop = newST
    scrollTop.value = newST
    lastScrollTop.value = newST
  } else {
    let sum = 0
    for (let i = 0; i < n; i++) sum += itemHeights.value.get(i) ?? props.defaultItemHeight
    console.log('[endPreserve] strategy B — sum:', sum)
    containerRef.value!.scrollTop = sum                      // ← BUG: same, no relative-position math
    scrollTop.value = sum
    lastScrollTop.value = sum
  }

  forceRenderUpTo.value = -1
  isPreservingScroll.value = false
  _pendingNewItemsCount = 0
  console.log('[endPreserve] END scrollTop:', containerRef.value!.scrollTop)
}
```

Both strategies set `scrollTop` to a value that puts the anchor at the top of the viewport. The `forceRenderUpTo = n - 1` value also keeps Strategy A from working for any `PAGE_SIZE` where `n` exceeds the natural render window.

### 2.3 Test coverage today

- `src/apps/desktop/src/helpers/__tests__/virtualScrollerThreshold.spec.ts` exists and has 10 tests for `computeLoadMoreThreshold` (added in the previous feature, commit `c3cf79f`).
- No tests for `VirtualScroller.vue` itself (it's a complex component with DOM). The threshold math is unit-tested; the preserve/restore flow is verified manually.

---

## 3. Design — the three changes

### 3.1 Change A: capture `scrollTop` in `beginPreserve`

Add a module-level `let _oldScrollTopBefore = 0` next to the existing `_anchorOffsetTopBefore`. In `beginPreserve`, after the existing anchor capture, add:

```ts
_oldScrollTopBefore = containerRef.value.scrollTop
```

Update the existing `console.log` to include the new value for easier debugging in dev.

### 3.2 Change B: route `endPreserve` through a new pure helper

Add a new exported function to `src/apps/desktop/src/helpers/virtualScrollerThreshold.ts`:

```ts
export function computePreservedScrollTop(
  oldAnchorOffsetTop: number,
  newAnchorOffsetTop: number,
  oldScrollTop: number,
): number
```

Behavior: `oldScrollTop - oldAnchorOffsetTop` is the anchor's relative position above the viewport top before the prepend (positive = anchor is below viewport top, negative = above). To keep the same relative position after the prepend, set `newScrollTop = newAnchorOffsetTop - relativePosition = newAnchorOffsetTop + oldScrollTop - oldAnchorOffsetTop`.

Defensive defaults (matching the existing `computeLoadMoreThreshold` style):
- Negative inputs are clamped to 0 (a `offsetTop` is always ≥ 0; a negative is a stale-cache bug we want to silently recover from).
- Non-finite inputs (`NaN`, `Infinity`) return `oldScrollTop` unchanged — the safest fallback is "don't move the user", not "jump to a wrong position".

Use the helper in both Strategy A and Strategy B of `endPreserve`:

```ts
// Strategy A (anchor in DOM, live offsetTop)
const newST = computePreservedScrollTop(
  _anchorOffsetTopBefore,
  anchorEl.offsetTop,
  _oldScrollTopBefore,
)
containerRef.value!.scrollTop = newST
scrollTop.value = newST
lastScrollTop.value = newST

// Strategy B (anchor NOT in DOM, sum of measured heights as estimate)
let sum = 0
for (let i = 0; i < n; i++) sum += itemHeights.value.get(i) ?? props.defaultItemHeight
const newST = computePreservedScrollTop(
  _anchorOffsetTopBefore,
  sum,
  _oldScrollTopBefore,
)
containerRef.value!.scrollTop = newST
scrollTop.value = newST
lastScrollTop.value = newST
```

Reset `_oldScrollTopBefore = 0` at the end of `endPreserve` (defensive — `beginPreserve` overwrites it on the next call, but resetting prevents a stale value if a future refactor calls `endPreserve` without `beginPreserve`).

### 3.3 Change C: `forceRenderUpTo` from `n - 1` to `n`

One-character change. The anchor lives at `data-vs-index="${n}"` after the prepend, so the forced render window must include index `n` for Strategy A to find the anchor in the DOM.

Cost: one extra DOM node mounted during the preserve window. Negligible for `PAGE_SIZE` up to a few hundred; Strategy B stays as the fallback for absurdly large `PAGE_SIZE`.

### 3.4 Why both changes B and C, not just one

- Change C without change B: Strategy A would find the anchor and use its live `offsetTop`, but `scrollTop = anchorEl.offsetTop` still puts the user at the top. The bouncing would continue.
- Change B without change C: The formula in `endPreserve` would be correct, but Strategy A would never fire for `PAGE_SIZE >= ~13`. We'd always fall back to Strategy B with the sum estimate, which is correct in formula but uses cached measurements.

Both together: Strategy A works for medium `PAGE_SIZE` with pixel-perfect preservation; Strategy B is the safety net for very large `PAGE_SIZE` with correct-but-cached preservation. The fix is robust across all `PAGE_SIZE` values.

---

## 4. File changes (summary table)

| File | Change | LOC |
|---|---|---|
| `src/apps/desktop/src/helpers/virtualScrollerThreshold.ts` | Add `computePreservedScrollTop()` (signature + JSDoc + body) | +20 |
| `src/apps/desktop/src/helpers/__tests__/virtualScrollerThreshold.spec.ts` | Add a new `describe('computePreservedScrollTop', ...)` block with 5 tests | +30 |
| `src/apps/desktop/src/helpers/VirtualScroller.vue` | 3 edits: declare `_oldScrollTopBefore`, capture in `beginPreserve`, use helper in both `endPreserve` strategies + change `n - 1` → `n` + reset in `endPreserve` | +15 / -5 |

No new files. No prop changes. No event changes. No CSS changes. No backend changes.

---

## 5. Test cases for the new helper

In a new `describe('computePreservedScrollTop', ...)` block in the existing `virtualScrollerThreshold.spec.ts`:

| # | Case | Inputs | Expected output | Why it matters |
|---|---|---|---|---|
| 1 | Normal case | `oldAnchor=100, newAnchor=500, oldScroll=50` | `450` | Proves the math: 500 + 50 - 100 = 450. Anchor stays 50 px above the viewport top. |
| 2 | No-prepend case | `oldAnchor=200, newAnchor=200, oldScroll=75` | `75` | Defensive: if the anchor's offsetTop didn't change (somehow), the result equals `oldScrollTop`. |
| 3 | Zero anchor (first message) | `oldAnchor=0, newAnchor=600, oldScroll=30` | `630` | Common case: the first message in a fresh chat starts at offsetTop=0. |
| 4 | Negative input clamping | `oldAnchor=-10, newAnchor=500, oldScroll=50` | `540` | Guards against a stale cache that leaks a negative value; clamps to 0. |
| 5 | NaN input fallthrough | `(NaN, 500, 50)`, `(100, NaN, 50)`, `(100, 500, NaN)` | `50`, `50`, `NaN` | "Don't move the user" is the safest default for a malformed DOM read. `oldScrollTop=NaN` propagates (caller chose to pass garbage, we don't pretend). |

5 tests, ~30 lines including the `describe` block and the 5 `it` blocks. Mirrors the style of the existing `computeLoadMoreThreshold` tests.

---

## 6. Verification (run from the new worktree's `src/apps/desktop/`)

| Step | Command | Expected |
|---|---|---|
| 1 | `bun run type-check` | exit 0, no output |
| 2 | `bun run test:unit` | 93/93 pass (88 existing + 5 new) |
| 3 | `bun run build` | exit 0, built in ~1.1s |
| 4 | Manual smoke test | See below |

### 6.1 Manual smoke test (in your dev session — port 8080, do **not** touch port 8081)

1. Open a chat with ≥ 200 messages (so you can trigger at least 2 `loadMore` events).
2. Dev tools console, filter for `load-more-threshold-reached` and `[endPreserve]`.
3. Scroll up slowly. Expected: first `loadMore` fires at ~half a screen from the top (per the previous fix). `[endPreserve]` logs `strategy A` (or `B` for very large `PAGE_SIZE`), and the new `scrollTop` preserves your visible position.
4. **Critical assertion:** in the next 1-2 seconds, **no** additional `loadMore` should fire. Pre-fix, the user landed at the top of the new content (within threshold) and the next scroll event would re-fire immediately. Post-fix, the user lands at their original relative position, well below the threshold.
5. Scroll up again. Same behavior. No bouncing.
6. Negative control: temporarily set `PAGE_SIZE = 20` (`ChatView.vue:222`), repeat steps 3-5. Small prepended batches were never the bug, but the new code path also handles them.

---

## 7. Commit strategy

Single commit on `fix/chat-load-more-preserve-scroll-position`, then merge to `main` (matches the previous fix's flow):

```
fix(virtual-scroller): preserve scroll position across prepends

endPreserve jumped to the anchor's new offsetTop after a prepend, which
put the user at the very top of the viewport and well within the
loadMore threshold. With PAGE_SIZE >= ~30 the next scroll event fired
loadMore again, another batch was prepended, the scroll position
jumped again — and the user saw visible "bouncing" until messages
ran out.

Three changes:

1. Capture the user's scrollTop in beginPreserve, alongside the
   existing anchor-offsetTop capture.

2. Route both Strategy A and Strategy B in endPreserve through a new
   pure helper computePreservedScrollTop() that does
   `newScrollTop = newAnchorOffsetTop + oldScrollTop - oldAnchorOffsetTop`.
   This preserves the anchor's relative position in the viewport
   across the prepend.

3. Change forceRenderUpTo from `n - 1` to `n`. The anchor lives at
   `data-vs-index="${n}"` after the prepend, so forcing the render
   window to 0..n (instead of 0..n-1) includes the anchor in the DOM
   and lets Strategy A use the live offsetTop for exact preservation.
   Strategy B stays as the fallback for absurdly large PAGE_SIZE
   where mounting n items would be too heavy.

5 new unit tests cover the helper: normal case, no-prepend case, zero
anchor, negative input clamping, and NaN input fallthrough.

93/93 tests pass.
```

---

## 8. Out of scope (deliberately not touched)

- The 200ms loadMore debounce — unchanged. With the scrollTop restore, the user lands at their old position, which is well below the loadMore threshold, so the debounce naturally won't re-fire.
- The 50ms measurement debounce — unchanged.
- The auto-stick gate (`autoStickGate.ts`) — unchanged. Still suppresses `loadMore` during LLM streaming.
- The "Load more messages" button (non-scrollable case) — unchanged.
- The scroll logger (`scrollLogger.ts`) — unchanged. Existing log lines cover the new code path; no new log lines needed.
- The `containerHeight` fix from the previous commit (`4d5e236`) — unchanged. That's a separate concern (stale ref) and is now upstream of this fix (the threshold is computed correctly, AND the restore position lands below the threshold).
- `defaultItemHeight`, `buffer`, the `loadMoreAtTop` semantics — unchanged.
- Any backend, DB, or API changes — none.

---

## 9. Self-review

**1. Placeholder scan:** no `TBD`/`TODO`/`fill in later`. Every test case has its exact inputs and expected output. Every code change has its actual code, not "similar to the existing one".

**2. Internal consistency:** Change A (capture) and Change B (use) reference the same variable name (`_oldScrollTopBefore`). Change C is the 1-character tweak with a clear before/after. The helper signature `(oldAnchorOffsetTop, newAnchorOffsetTop, oldScrollTop)` matches both call sites.

**3. Scope check:** single subsystem (the preserve/restore flow in `VirtualScroller.vue`), one focused change, one commit, one plan. No decomposition needed.

**4. Ambiguity check:**
- "Negative inputs are clamped to 0" — explicit, single interpretation.
- "Non-finite inputs return `oldScrollTop`" — explicit, with the exception that `oldScrollTop=NaN` propagates (covered in test case 5).
- "Strategy B stays as the fallback" — explicit, no ambiguity about when to use which.
- "Worktree on `fix/chat-load-more-preserve-scroll-position`" — explicit, no ambiguity.
- "Single commit" — explicit, no ambiguity about splitting.

No two-interpretation requirements found.

---

## 10. Next step

After user review and approval, invoke the `superpowers:writing-plans` skill to convert this spec into a bite-sized TDD-style implementation plan.
