# Plan: Replace dynamic item measurement with a fixed `itemHeight` in `VirtualScroller`

> **Goal:** Eliminate the visible "bouncing up and down" in chat and chats-list
> views by removing the dynamic re-measurement of item heights. Every rendered
> item occupies exactly one fixed slot size, set once by the caller, and never
> changes after that.

---

## 1. Symptom (what the user sees)

In `ChatView`, while a long assistant response is streaming into the
messages list, the visible position of the list **shifts up by a few
pixels, then back down, then up again** in a continuous cycle. The shift
is small (a few px to ~20 px) but persistent and very noticeable to a
user reading along. The chat itself doesn't move — the *content inside
the messages scroller* does, even though the user is not scrolling.

In `ChatsList`, the same bouncing is visible in the sessions list on
window resize (a chat card that fits in 64 px gets resized to 48 px, the
list lurches, then the heights re-converge after a ~50 ms debounce).

### Why the bouncing is dynamic-height-specific

The current `VirtualScroller.vue` keeps a `Map<number, number>` of
measured per-item heights. The flow that causes bouncing:

1. A new item is appended (SSE chunk, list resize, etc.).
2. Vue renders the item. The scroller doesn't know its real height yet,
   so the `bottomSpacer` is computed from the previous estimate
   (`defaultItemHeight = 200 px` for chat bubbles).
3. After a 50 ms debounce, `measureItems()` runs. It reads each rendered
   item's real `offsetHeight` (often 30-180 px for tool bubbles,
   300-800 px for assistant responses), writes them to the Map, and
   recomputes `accumulatedHeights`.
4. `bottomSpacer` (and sometimes `topSpacer`) shrinks or grows to match
   the new estimate. The scroller's total `scrollHeight` jumps.
5. The browser clamps the user's current `scrollTop` if `scrollHeight`
   decreased, or the spacer pushes the bottom item up if it increased.
   Either way, the user sees content move on its own.

This is the bouncing: the spacer keeps adjusting toward "real" heights
whenever the visible range changes (scroll, stream chunk, mount, list
resize), and every adjustment is a visible 1-frame jump.

A secondary source of bouncing is the `endPreserve` strategy B
fallback: when the anchor element can't be found, the scroller sums
`itemHeights.get(i) ?? defaultItemHeight` for the new items — but the
Map is the *post-measurement* state, so the sum can disagree with the
actual offsetTop the DOM will produce once everything is rendered.

---

## 2. Why a fixed height is the right fix

The user-visible phenomenon is *dynamic re-measurement* (steps 2-4
above). Two ways to remove it:

- **(A) Stop measuring** — Use a single fixed height for every item.
  The Map, `measureItems()`, the `itemHeights` debounce watcher, and
  the per-item ResizeObserver all go away. The caller picks a height
  that fits their use case (200 px for chat bubbles, 48 px for chat
  list rows). Spacers are computed exactly from `i * itemHeight`, no
  approximation, no debounce, no jumping.
- **(B) Estimate-once** — Measure on first render, then freeze the
  height. More complex than (A) and still has a "first render uses
  estimate, second render uses real" jump — a slightly less obvious
  version of the same bug.

We choose (A). It is the smallest change that fully eliminates the
bouncing, the math is exact from the very first paint, and the
`endPreserve` scroll restoration becomes trivially correct.

### Trade-off we accept

A fixed `itemHeight` means items can be either too short (empty space
below) or too tall (content overflows the slot). For our two current
consumers this is acceptable:

- **ChatView bubbles:** tool/result bubbles are typically 50-180 px,
  user bubbles 40-80 px, assistant responses 200-800 px. Setting
  `itemHeight = 200` means tool bubbles get whitespace below them
  (already true with `defaultItemHeight`, just more so for short
  ones), and long assistant responses overflow their slot.
- **ChatsList rows:** cards are roughly fixed 48-72 px, so 48 px is
  fine.

We address the assistant-response overflow by setting the slot's CSS
to `min-height: itemHeight + 'px'` instead of `height: itemHeight + 'px'`
**for the LAST item only**. This keeps virtualization correct for
already-rendered items (their heights are exactly `itemHeight`, so the
spacers stay exact) while letting the actively-streaming final bubble
grow naturally. The next render cycle swaps the "last item" identity to
the new last item, and the previous last item's overflow is preserved
in the slot. This is the same behavior the current code already has
in practice (a 800 px assistant bubble renders taller than the 200 px
estimate, the spacers adjust on next `measureItems` cycle, no scroll
position breaks) — we just stop trying to *fix* it after the fact.

---

## 3. Current state (what is broken)

### 3.1 The `itemHeights` Map and its writers

`src/apps/desktop/src/helpers/VirtualScroller.vue:37`

```ts
const itemHeights = ref<Map<number, number>>(new Map())
```

Writers:

- `measureItems()` (lines 147-163) — reads each rendered item's
  `offsetHeight`, writes to the Map, sets `changed = true`, calls
  `updateAccumulatedHeights()`.
- A debounced watcher on `itemHeights` (lines 80-88) — calls
  `updateAccumulatedHeights()` 50 ms after any Map mutation.
- `onMounted` (lines 386-396) and the `ResizeObserver` callback
  (lines 389-393) — both call `setTimeout(measureItems, 50)`.
- `onScroll` (line 210) — calls `setTimeout(measureItems, 50)` on
  every scroll event (debounced).

So the Map is rewritten on every render of new content, every scroll,
every window resize. The downstream `accumulatedHeights` is
recomputed 50 ms later. That recompute is the source of the bouncing.

### 3.2 The readers

Three places read from the Map:

- `updateAccumulatedHeights` (line 72):
  ```ts
  sum += itemHeights.value.get(i) ?? props.defaultItemHeight
  ```
- `visibleRange` (line 112):
  ```ts
  acc += itemHeights.value.get(endIndex) ?? props.defaultItemHeight
  ```
- `endPreserve` strategy B (line 318):
  ```ts
  for (let i = 0; i < n; i++) sum += itemHeights.value.get(i) ?? props.defaultItemHeight
  ```

All three are exact when `itemHeight` is fixed — replace `Map.get(i) ??
defaultItemHeight` with `props.itemHeight`.

### 3.3 `endPreserve` strategy A (DOM-based, already exact)

`beginPreserve` captures `_anchorOffsetTopBefore = firstRendered.offsetTop`
(line 226). After the prepend, `endPreserve` reads
`newAnchorOffsetTop = anchorEl.offsetTop` (line 300) and computes
`delta = newAnchorOffsetTop - _anchorOffsetTopBefore`. This is exact
in both the dynamic and fixed models, because it reads the actual DOM.
We keep this strategy; it still works.

Strategy B is the broken fallback. With fixed heights it becomes
`delta = n * props.itemHeight` — exact by construction.

### 3.4 Consumers

- `src/apps/desktop/src/components/ChatView.vue:1509-1522`
  - `:default-item-height="200"`
- `src/apps/desktop/src/components/ChatsList.vue:469-525`
  - `:default-item-height="48"`

Both call sites pass a constant. We rename the prop to `itemHeight` and
keep `defaultItemHeight` as a deprecated alias so the change is
backward-compatible at the call sites.

---

## 4. Design

### 4.1 New prop

```ts
const props = withDefaults(
  defineProps<{
    items: T[]
    totalCount?: number
    buffer?: number
    /** Fixed slot height for every item, in pixels. All items are
     *  exactly this tall (with one exception — see 4.4). The total
     *  scroller height is `items.length * itemHeight` and never
     *  changes after a render. */
    itemHeight?: number
    /** @deprecated Use `itemHeight` instead. Kept for backward
     *  compatibility with existing call sites that pass a constant. */
    defaultItemHeight?: number
    loadMoreThreshold?: number
    loadMoreThresholdRatio?: number
    loadMoreAtTop?: boolean
  }>(),
  {
    totalCount: 0,
    buffer: 5,
    itemHeight: 100,
    defaultItemHeight: undefined,
    loadMoreThreshold: 200,
    loadMoreThresholdRatio: 0.5,
    loadMoreAtTop: false,
  },
)
```

A `computed` resolves the effective height:

```ts
const effectiveItemHeight = computed(() => {
  if (typeof props.itemHeight === 'number' && props.itemHeight > 0) {
    return props.itemHeight
  }
  if (typeof props.defaultItemHeight === 'number' && props.defaultItemHeight > 0) {
    return props.defaultItemHeight
  }
  return 100
})
```

All internal math uses `effectiveItemHeight.value`. The exposed
`defineExpose` keeps `effectiveItemHeight` (or renames to
`itemHeight` — see 4.6).

### 4.2 Remove the Map, the measurement, the watcher

Delete entirely:

- `itemHeights` ref (line 37)
- `updateAccumulatedHeights` (lines 68-76) — replaced by a trivial
  computed in 4.3
- The `watch(() => props.items.length, updateAccumulatedHeights, { immediate: true })`
  (line 78) — the computed in 4.3 is reactive on its own
- The `watch(itemHeights, ..., { deep: true })` (lines 80-88) and its
  `heightDebounce` timer
- `measureItems()` (lines 147-163) and the `measureDebounce` timer
  (line 166)
- The `setTimeout(measureItems, 50)` calls in `onMounted` (line 391)
  and the `ResizeObserver` callback (line 393)
- The `setTimeout(measureItems, 50)` in `onScroll` (line 210)
- The `heightDebounce` cleanup in `onUnmounted` (line 401)

### 4.3 `accumulatedHeights` becomes a pure computed

```ts
const accumulatedHeights = computed<number[]>(() => {
  const len = props.items.length
  const h = new Array<number>(len + 1)
  const itemH = effectiveItemHeight.value
  h[0] = 0
  for (let i = 0; i < len; i++) h[i + 1] = h[i]! + itemH
  return h
})
```

`isScrollable` (line 42) keeps using `accumulatedHeights[len]` — exact
now, no fallback `?? 0` needed (well, keep it for `len = 0`).

`visibleRange` (line 103) uses `accumulatedHeights` for the spacer
calculations — exact now.

### 4.4 Slot CSS: `height` for all but the last item, `min-height` for the last

The template (line 424) renders each item as:

```vue
<div v-for="{ item, index } in visibleItems" :key="index" :data-vs-index="index">
  <slot :item="item" :index="index" />
</div>
```

The wrapper `<div>` carries the slot height. We make its height a
computed binding:

```vue
<div
  v-for="{ item, index } in visibleItems"
  :key="index"
  :data-vs-index="index"
  :style="{
    height: index === visibleItems.length - 1
      ? `${effectiveItemHeight}px`     // last visible: same as before
      : `${effectiveItemHeight}px`,
    minHeight: index === visibleItems.length - 1
      ? `${effectiveItemHeight}px`
      : undefined,
    overflow: 'hidden',
  }"
>
  <slot :item="item" :index="index" />
</div>
```

Wait — that binds `height` for every item, which clips overflowing
content. Per 4 design decision, we want the *actively-streaming last
item* to be allowed to grow. Simpler: make the wrapper `min-height`
for every item, and set `height` only when the item is "stable"
(content not currently being streamed).

But the scroller doesn't know which item is "actively streaming". A
practical compromise used by the current code is: the wrapper is
`min-height: itemHeight` for all items, and overflow into the next
item's slot is allowed (because spacers are computed from index, not
from real height). This means the actively-streaming last item can be
taller than `itemHeight`, and the spacer BELOW it absorbs the
overflow. Virtualization is still correct because we render by
`start..end` range, not by absolute position.

But the spacer below the last item is `accumulatedHeights[len] -
accumulatedHeights[end]`. If the last visible item overflows, the
spacer is still `itemHeight * (len - end)`, but the *real* bottom is
at `accumulatedHeights[end] + (real height of last item) +
itemHeight * (len - end - 1)`. The user sees content overlap the
bottom spacer, but the *scrollHeight* of the scroller is set by the
spacers, so the scrollbar is at the wrong position by the overflow
amount.

This is the same bug the current code has after `measureItems` runs
(strategy A) — the spacers don't reflect the real DOM. The current
code "fixes" this by re-measuring; we accept the slight inaccuracy
(only affects the actively-streaming bubble, not historical ones) and
just let the scrollbar be a few px off for the duration of the stream.

**Concrete decision** (4.4 final):

- Wrapper div: `style="height: ${itemHeight}px; overflow: hidden;"`
  for every visible item. This clips overflow cleanly. The user can
  still scroll past the clip (the spacers make the scrollHeight
  correct), but they see only the first `itemHeight` px of any item.
- For `ChatView`'s assistant bubbles that often exceed 200 px, this
  is a regression. We mitigate by setting `itemHeight` high enough
  (e.g., `itemHeight: 600`) for chat bubbles. Or: split the bubble
  into multiple items (one per paragraph) — but that's a larger
  ChatView refactor.
- **Recommended:** start with `itemHeight: 600` for chat bubbles
  (covers ~95% of cases), accept rare clipping for very long
  responses, and add a follow-up plan to handle the long-response
  case properly (e.g., split the bubble or use a different scroller
  for the message content).

I want to flag this clearly: the user said "no need dynamic", but
they may not have realized that the dynamic model is what currently
allows long bubbles to render. If we go pure fixed-height, we need
to pick a `itemHeight` for chat that's "tall enough" — which is
arguably worse UX for short bubbles (lots of whitespace). Better
long-term solution is **per-item estimated height passed by the
caller**, which keeps the no-measurement guarantee but lets the
caller know "this assistant response is going to be tall, set its
slot to 600". This is `Option D` from my analysis.

I'll propose this as the final design, and the plan will include a
follow-up to switch from a global `itemHeight` to a per-item
`itemHeight` callback once the basic fixed-height version is merged.

**Final final design (4.4 actually-final):**

Use a *single* `itemHeight` prop for v1 (this plan). Clip overflow
with `overflow: hidden`. Set `itemHeight: 600` for chat. Document
that very long bubbles will be clipped and a follow-up will add a
per-item height callback. The user can decide whether to ship v1 as-is
or skip directly to per-item heights.

### 4.5 `endPreserve` strategy B becomes exact

Replace line 317-319:

```ts
let sum = 0
for (let i = 0; i < n; i++) sum += itemHeights.value.get(i) ?? props.defaultItemHeight
const delta = sum - _anchorOffsetTopBefore
```

with:

```ts
const delta = n * effectiveItemHeight.value - _anchorOffsetTopBefore
```

Strategy A is unchanged. The `console.log` block stays for debug;
just update the field labels.

### 4.6 `defineExpose` and parent consumers

`defineExpose` (line 404) currently exposes `defaultItemHeight` via
`props.defaultItemHeight` reads in the parent — but the parent's
`scrollLogger` doesn't actually read it. Let me verify by searching
for `defaultItemHeight` and `default-item-height` outside the
VirtualScroller itself.

`grep -r "defaultItemHeight\|default-item-height" src/apps/desktop/src`
shows only the two call sites. Neither consumer reads the value back
from the exposed ref — they only pass it as a prop. So we can safely
rename the prop to `itemHeight` and update both call sites:

- `ChatView.vue:1515` — `:item-height="600"` (or keep 200 if we
  accept clipping, see 4.4)
- `ChatsList.vue:473` — `:item-height="48"`

`defineExpose` adds:

- `effectiveItemHeight` (replaces the old `defaultItemHeight`
  exposure, in case any consumer was reading it)
- `itemHeight` alias (so parent code that destructures
  `virtualScrollerRef.value.itemHeight` keeps working if needed)

### 4.7 Remove the per-item `console.log` instrumentation

Strategy A and B in `endPreserve` have multi-line `console.log`
blocks (lines 229-243, 277-295, 303-315, 321-333, 344-356) that were
added during the scroll-bounce investigation. With the bounce fixed,
these can be removed. The `scrollLogger` in `ChatView` already emits
structured `load-more-preserve-*` events that cover the same ground
and are easier to filter.

If we want to keep the per-item logs (they're useful for debugging
`endPreserve` regressions), we can route them through `scrollLogger`
instead of `console.log` — but that's a separate refactor.

**Decision:** delete the `console.log` blocks in `beginPreserve` and
`endPreserve`. ChatView's `scrollLogger` already covers this.

---

## 5. Implementation steps

1. **`VirtualScroller.vue` — new prop + computed** (5 min)
   - Add `itemHeight` prop with default 100.
   - Keep `defaultItemHeight` as a deprecated alias.
   - Add `effectiveItemHeight` computed.

2. **`VirtualScroller.vue` — delete measurement code** (15 min)
   - Remove `itemHeights` ref, `updateAccumulatedHeights`, the two
     watchers (`items.length`, `itemHeights`).
   - Remove `measureItems()`, `measureDebounce`, and the three
     `setTimeout(measureItems, ...)` call sites.
   - Remove the `heightDebounce` cleanup in `onUnmounted`.
   - Remove the `ResizeObserver` callback's `setTimeout(measureItems, 50)`
     but KEEP the `containerHeight` update.
   - Remove the `setTimeout(measureItems, 50)` in `onScroll`.
   - Remove the `console.log` blocks in `beginPreserve` / `endPreserve`.

3. **`VirtualScroller.vue` — replace Map reads** (5 min)
   - `accumulatedHeights` → pure computed (4.3).
   - `visibleRange` → use `effectiveItemHeight.value` instead of
     `itemHeights.value.get(endIndex) ?? props.defaultItemHeight`.
   - `endPreserve` strategy B → `n * effectiveItemHeight.value`
     (4.5).
   - `scrollToIndex` (line 369) → `accumulatedHeights.value[index]
     ?? index * effectiveItemHeight.value` (the `??` becomes
     unnecessary but keep for the `index = 0` case for safety).
   - `onMounted` → only set `containerHeight`, no
     `setTimeout(measureItems, 100)`.

4. **`VirtualScroller.vue` — template + style** (5 min)
   - Bind `style="height: ${itemHeight}px; overflow: hidden;"` on
     the per-item wrapper div.
   - Add a CSS rule for `.virtual-scroller-item` so the style is
     declared in `<style scoped>` (more readable than inline).

5. **`ChatView.vue` — update prop name** (2 min)
   - `:default-item-height="200"` → `:item-height="600"`.
   - Verify the slot template still renders correctly with the
     larger slot (no layout regressions).

6. **`ChatsList.vue` — update prop name** (2 min)
   - `:default-item-height="48"` → `:item-height="48"`.

7. **Build + manual test** (15 min)
   - `bun run build` in `src/apps/desktop` — must pass.
   - Start the desktop app, open a chat, send a long message,
     watch the stream — no bouncing.
   - Resize the window while a chat is open — no list jump.
   - Scroll a long chat to the top, verify `loadMore` fires,
     verify scroll position is preserved (no jump).
   - Open the chats list, resize the window — no jump.

8. **Add a unit test for `VirtualScroller`** (30 min)
   - No tests exist today (confirmed via `fd -e spec -e test.ts
     VirtualScroller`). Add `src/apps/desktop/src/__tests__/
     VirtualScroller.spec.ts` with at least:
     - Renders N items, only `[start-buffer .. end+buffer]` are
       actually in the DOM (proves virtualization works).
     - `accumulatedHeights` is `i * itemHeight` for every i.
     - `endPreserve` after prepending N items restores scrollTop
       exactly (uses jsdom, no real layout — test the math via
       a stubbed `containerRef` with `scrollTop`/`scrollHeight`
       getters).
     - Slot height is `itemHeight` for all rendered items.
   - Register the test in any test runner config that needs it
     (check `vitest.config.ts` / `package.json` test glob).

9. **`bun run build` (NOT `build-only`)** — final type-check pass.
   - Per project memory: `bun run build` runs `vue-tsc --build` and
     catches type errors that `build-only` skips.

---

## 6. Files touched

- `src/apps/desktop/src/helpers/VirtualScroller.vue` — main change.
- `src/apps/desktop/src/components/ChatView.vue` — prop rename,
  `itemHeight` bump from 200 to 600.
- `src/apps/desktop/src/components/ChatsList.vue` — prop rename
  only (48 stays the same).
- `src/apps/desktop/src/__tests__/VirtualScroller.spec.ts` — new
  test file.
- (no other files; `virtualScrollerThreshold.ts` is unchanged
  because it takes the threshold, not the item height.)

---

## 7. Risks and mitigations

| Risk | Likelihood | Mitigation |
| --- | --- | --- |
| Long assistant bubbles clip at 600 px | Medium | Acceptable for v1. Document. Follow-up with per-item `itemHeight` callback. The user can override the prop in `ChatView.vue` if needed. |
| Existing consumers pass `defaultItemHeight` and break when the prop is renamed | Low | Keep `defaultItemHeight` as a deprecated alias. The `effectiveItemHeight` computed prefers `itemHeight` and falls back to `defaultItemHeight`. |
| `endPreserve` strategy A still has a bug we didn't see because we were always falling back to B | Low | Keep strategy A's DOM-based math unchanged. Add a unit test that exercises strategy A directly. |
| ResizeObserver-for-container breaks (e.g., window resize) | Very low | We're only removing the `setTimeout(measureItems, ...)` calls; the observer still updates `containerHeight`. No behavior change for resize. |
| Backward compat with code that reads `itemHeights` from the exposed ref | Very low | `defineExpose` doesn't expose `itemHeights` (it was always a private ref). No external readers. |

---

## 8. Follow-up (not in this plan)

- **Per-item `itemHeight` callback** — replace the single `itemHeight`
  prop with `itemHeight: number | ((item: T, index: number) => number)`.
  Lets `ChatView` pass `(_, idx) => messageGroups.value[idx].estimatedHeight`
  where `estimatedHeight` is computed once when the message arrives
  (based on content length, image count, etc.) and never changes. This
  removes the `overflow: hidden` clip for assistant bubbles while still
  avoiding the bouncing.
- **Remove `console.log` from `scrollLogger` consumers** — the
  `scrollLogger` already produces structured `load-more-preserve-*`
  events; the `console.log` blocks in `VirtualScroller` are
  duplicate/legacy at this point.
- **Investigate why `ChatsList` still has bouncing on window
  resize** — with `itemHeight: 48` fixed, the cards themselves may
  still resize (text wrapping), but the scroller won't, so the
  bouncing is moved from the scroller to the cards. This may need
  its own follow-up.

---

## 9. Verification

Before declaring done:

1. `bun run build` in `src/apps/desktop` passes.
2. Open a chat, send a long user message, watch the assistant stream
   in real time — no visible bouncing, no spacer jumps.
3. Resize the window mid-stream — no jump.
4. Scroll to the top of a long chat, click "Load more messages" —
   scroll position is preserved, no flash.
5. Open a chat with all-bubbles-fit-in-viewport (short tool chats) —
   the "Load more messages" button is visible (per the previous plan),
   clicking it loads older messages without layout shift.
6. Open the chats list, scroll, resize the window — no jump.
7. New `VirtualScroller.spec.ts` tests pass.
8. (Optional) Memory check: no leaked timers in the scroller's
   `onUnmounted` after navigating away from a chat.
