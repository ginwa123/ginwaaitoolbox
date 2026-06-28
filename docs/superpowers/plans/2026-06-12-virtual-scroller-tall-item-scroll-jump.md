# VirtualScroller: Fix scroll jump when first item is very tall

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the visible "scroll jumps from 60% to 79%" UX in `ChatView` when the first message in a chat is much taller than `defaultItemHeight` (e.g. a 5,000 px assistant response, an image-only user message, or a giant tool result).

**Architecture:** Three complementary changes — (1) the parent (`ChatView`) passes a per-item **estimated height callback** so the `VirtualScroller` reserves the right amount of space for the first item from the very first paint, (2) the `VirtualScroller` only measures items that are in the **visible viewport** (not the buffer), so buffer items can't trigger 5,000-px spacer mutations, and (3) a **scroll-anchor** in the `VirtualScroller` automatically restores the topmost-visible-message's screen position when spacers change anyway (defense in depth, mirrors what `beginPreserve`/`endPreserve` already do for `loadMore`).

**Tech Stack:** Vue 3 (Composition API, `<script setup lang="ts" generic="T">`), TypeScript, Vitest, @vue/test-utils.

---

## 1. Symptom (what the user sees)

A chat with ~712 messages opens. The user scrolls to ~60% of the list. The first message in the chat is very tall (a long assistant response with code blocks, a tool result with a long diff, an image-only user message, etc. — typically 2,000-8,000 px). The user reports:

> "the scroll is jumping, from 60% to 79% it does not make sense, and make the user feel ux weird"

The user's `scrollLogger` (already deployed; see `src/apps/desktop/src/helpers/scrollLogger.ts`) shows consecutive `content-resized` info lines with the bottom-distance falling and the scroll percentage climbing rapidly:

```
[scroll#1142 ... DEBUG] content-resized top=104683 bottom=74615px (58.4%) msgs=712
[scroll#1145 ... INFO ] content-resized top=113457 bottom=65782px (63.3%) msgs=712
[scroll#1146 ... INFO ] content-resized top=114947 bottom=53506px (68.3%) msgs=712
[scroll#1147 ... INFO ] content-resized top=115624 bottom=53091px (66.5%) msgs=712
[scroll#1148 ... INFO ] content-resized top=117095 bottom=29605px (79.8%) msgs=712  ← JUMP
[scroll#1149 ... INFO ] content-resized top=117634 bottom=29966px (80.2%) msgs=712
[scroll#1150 ... INFO ] content-resized top=118781 bottom=27919px (81.0%) msgs=712
[scroll#1151 ... INFO ] content-resized top=119957 bottom=26744px (81.8%) msgs=712
```

`top` (the user's `scrollTop`) moves 15 k px in 10 events, but the *bottom* moves ~48 k px. The user is in the middle of the chat; they did not scroll. The content above them changed height under their feet.

### What the user feels

- The scrollbar thumb jumps position without a wheel event.
- A specific message that was at the top of the viewport a moment ago is no longer there — a different one is.
- The "X% of chat" position indicator (if any) ticks rapidly upward.
- The chat feels "twitchy" / "unstable" — every interaction seems to trigger a jump.

---

## 2. Root cause

### 2.1 The first message is much taller than `defaultItemHeight`

`src/apps/desktop/src/components/ChatView.vue:1755` passes `:default-item-height="200"`. The first message in a chat can be a 5,000 px assistant response, a 3,000 px tool diff, or a 1,200 px image. The `VirtualScroller` initially assumes it is 200 px:

```ts
// src/apps/desktop/src/helpers/VirtualScroller.vue:275-280
const updateAccumulatedHeights = () => {
  const h: number[] = [0]
  let sum = 0
  for (let i = 0; i < props.items.length; i++) {
    sum += itemHeights.value.get(i) ?? props.defaultItemHeight   // ← 200 for unmeasured
    h.push(sum)
  }
  accumulatedHeights.value = h
}
```

### 2.2 The first message eventually gets measured and the spacers explode

`measureItems` (`VirtualScroller.vue:413-438`) walks every rendered child and writes its real `offsetHeight` to the `itemHeights` Map. When the user scrolls *toward* the first message (or it rolls into the buffer), item 0 is measured. Its 5,000 px reality lands in the Map, `updateAccumulatedHeights` recomputes, and `accumulatedHeights[1..712]` all shift up by ~4,800 px.

### 2.3 The topSpacer mutates by ~4,800 px in a single frame

`visibleRange.topSpacer = accumulatedHeights[start]`. For a user at item 300, `start ≈ 280`, so the topSpacer mutates by `4,800 px`. With the current `overflow-anchor: none` (added by `docs/plans/2026-06-10-scroll-ratcheting-fix.md`), the browser does **not** adjust `scrollTop` to compensate. The user's `scrollTop` is unchanged, but:

- The DOM now reports a different `scrollHeight` (4,800 px taller).
- The scrollbar thumb sits at a different position.
- The scrollbar's reported percentage jumps.
- The visible content inside the viewport did **not** visibly move (since `scrollTop` is unchanged), but the **scrollbar** did, and the user's mental model of "where am I in this chat" is suddenly off by a frame.

### 2.4 Why the user *also* feels the content shift (not just the bar)

The first measurement of item 0 is only one of many. The user's chat has 712 items. The buffer is `:buffer="20"` (`ChatView.vue:1754`). As the user scrolls, every buffer item is measured once. The topSpacer changes incrementally as each item is measured. The scrollbar thumb *and* the visible content shift each time.

With the `+ 200` px hardcoded overscan in `visibleRange` (already fixed by `2026-06-10-virtual-scroller-buffer-fix.md`, but only in some branches), the measurement cycle is even longer.

### 2.5 The 2026-06-10 fixes don't address this

`docs/plans/2026-06-10-scroll-ratcheting-fix.md` added:
- **Hysteresis** (`HYSTERESIS_PX = 4`) — ignores sub-pixel noise in `measureItems`.
- **`overflow-anchor: none`** — prevents the browser from auto-jumping.

Both fix the 1-2 px ratchet. Neither fix addresses a **4,800 px** jump from a single item being measured to be 25× its estimate. The hysteresis is irrelevant; the browser's no-anchor is irrelevant; the user still sees a 4,800 px shift in the scrollbar and a 13-percentage-point jump.

### 2.6 The 2026-06-07 plan is the wrong shape for this

`docs/plans/2026-06-07-virtual-scroller-fixed-height.md` proposes a single fixed `itemHeight` for all items. That eliminates the *dynamic* measurement, so the bug is gone. But it would clip long assistant bubbles (which routinely run 600-1,200 px) at the fixed height. The 2026-06-07 plan acknowledges this and proposes a per-item `itemHeight` callback as a §8 follow-up. **This plan is that follow-up, plus the scroll-anchor mechanism that makes it robust even when measurements still surprise us.**

---

## 3. Design

### 3.1 Three layers of defense

| Layer | What it does | What it catches |
| --- | --- | --- |
| **3.1.1 Per-item estimated height** | `ChatView` passes `(item, index) => number` to the `VirtualScroller`. The first message is estimated at, e.g., 2,000 px instead of 200 px. The spacers are accurate from the very first paint. | The **majority** of the cases — items where the parent knows roughly how tall they will be (long text, many images, code blocks, etc.). |
| **3.1.2 Buffer-zone measurement skip** | `measureItems` only writes heights for items in `[start, end)` (the visible range). Buffer items stay at their estimate. The buffer is an *over-estimate* (200 px even for a 50 px tool result), so the spacers might still need to *shrink* on the first measurement of a visible item. | The **most invasive** spacer mutations — those triggered by buffer items being measured. The buffer is up to 20 items on each side; the visible range is ~4. With this change, only 4 items can change the spacers at a time, not 44. |
| **3.1.3 Scroll-anchor mechanism** | The `VirtualScroller` tracks the topmost visible item (by index) and its `offsetTop` relative to the scroll container. When spacers change (and after the DOM updates), it adjusts `scrollTop` by the delta so the topmost visible item stays at the same screen position. Mirrors what `beginPreserve`/`endPreserve` already do for `loadMore`. | The **residual** — spacer changes that 3.1.1 and 3.1.2 don't prevent. Image loading, code-block re-layout, streaming content, the first chat-open measurement pass. The user sees a stable view even when the spacers move. |

All three layers are needed:
- Without 3.1.1, the first message still mutates the spacers by ~4,800 px on first measurement.
- Without 3.1.2, every buffer item can mutate the spacers, and the scroll-anchor (3.1.3) would have to run on every measurement cycle.
- Without 3.1.3, even with 3.1.1 and 3.1.2, a single image load or layout reflow would cause a small jump that the user notices.

### 3.2 New prop: `estimatedItemHeight`

```ts
// src/apps/desktop/src/helpers/VirtualScroller.vue
const props = withDefaults(
  defineProps<{
    items: T[]
    totalCount?: number
    buffer?: number
    defaultItemHeight?: number
    /**
     * Optional per-item height estimate. Called once per item per
     * accumulatedHeights recomputation. If provided, REPLACES
     * `defaultItemHeight` for that item; the Map/measured value still
     * wins once written.
     *
     * Use this when you know some items are much taller than others
     * (chat bubbles with code blocks, image-only messages, tool
     * results with long diffs). A good estimate keeps the spacers
     * accurate from the very first paint, so the scrollbar doesn't
     * jump when the item is first measured.
     *
     * Should be cheap (called O(N) per `updateAccumulatedHeights`).
     * The callback receives `(item, index)` so it can branch on
     * message role, content type, etc.
     */
    estimatedItemHeight?: (item: T, index: number) => number
    loadMoreThreshold?: number
    loadMoreThresholdRatio?: number
    loadMoreAtTop?: boolean
  }>(),
  /* ... */
)
```

Inside `updateAccumulatedHeights`:

```ts
const updateAccumulatedHeights = () => {
  const h: number[] = [0]
  let sum = 0
  for (let i = 0; i < props.items.length; i++) {
    const measured = itemHeights.value.get(i)
    if (measured !== undefined) {
      sum += measured
    } else if (props.estimatedItemHeight) {
      sum += props.estimatedItemHeight(props.items[i]!, i)
    } else {
      sum += props.defaultItemHeight
    }
    h.push(sum)
  }
  accumulatedHeights.value = h
}
```

Same pattern in `visibleRange` (line 334), `endPreserve` strategy B (line 573), and `scrollToIndex` (line 589).

### 3.3 Buffer-zone measurement skip

```ts
// src/apps/desktop/src/helpers/VirtualScroller.vue:413-438
const measureItems = () => {
  if (!containerRef.value) return
  const content = containerRef.value.querySelector('.virtual-scroller-content')
  if (!content) return
  let changed = false
  const { start, end } = visibleRange.value
  const children = content.children
  for (let i = 0; i < children.length; i++) {
    const el = children[i] as HTMLElement
    const realIndex = start + i
    // Only measure items in the VISIBLE range. Buffer items are
    // intentionally not measured here — their height is the
    // estimate (or the previous measurement if it was visible
    // before the user scrolled). This stops a 5,000 px first
    // message from causing a 4,800 px spacer mutation just because
    // it rolled into the buffer.
    if (realIndex < start || realIndex >= end) continue
    const h = el.offsetHeight
    if (h > 0) {
      const prev = itemHeights.value.get(realIndex)
      if (prev === undefined || Math.abs(h - prev) > HYSTERESIS_PX) {
        itemHeights.value.set(realIndex, h)
        changed = true
      }
    }
  }
  if (changed) updateAccumulatedHeights()
}
```

Trade-off: buffer items might be slightly off (over- or under-estimated). This is fine — the user is not looking at the buffer. When the buffer item rolls into the visible range, it gets measured and the spacers adjust (handled by 3.1.3).

### 3.4 Scroll-anchor mechanism

The mechanism is a single function that captures the topmost visible item's relative position, then restores it after a spacer change.

```ts
// src/apps/desktop/src/helpers/VirtualScroller.vue
let anchorIndex: number | null = null
let anchorOffsetTopInContainer: number | null = null

const captureAnchor = (): void => {
  if (!containerRef.value) return
  const content = containerRef.value.querySelector('.virtual-scroller-content')
  if (!content || content.children.length === 0) return
  const firstChild = content.children[0] as HTMLElement
  const idxStr = firstChild.getAttribute('data-vs-index')
  if (idxStr === null) return
  anchorIndex = parseInt(idxStr, 10)
  anchorOffsetTopInContainer = firstChild.offsetTop - containerRef.value.scrollTop
}

const restoreAnchor = (): void => {
  if (
    !containerRef.value ||
    anchorIndex === null ||
    anchorOffsetTopInContainer === null
  ) return
  const content = containerRef.value.querySelector('.virtual-scroller-content')
  if (!content) return
  const target = content.querySelector(
    `[data-vs-index="${anchorIndex}"]`,
  ) as HTMLElement | null
  if (!target) return
  const desiredScrollTop = target.offsetTop - anchorOffsetTopInContainer
  // Clamp to the legal scrollTop range — the topmost item might be
  // off-screen now (e.g. loadMore added items below it), and we
  // don't want to scroll into negative territory.
  const maxScrollTop = Math.max(
    0,
    containerRef.value.scrollHeight - containerRef.value.clientHeight,
  )
  containerRef.value.scrollTop = Math.max(0, Math.min(desiredScrollTop, maxScrollTop))
  // Clear the anchor so a stale value doesn't fire later.
  anchorIndex = null
  anchorOffsetTopInContainer = null
}
```

Wrapped around `updateAccumulatedHeights` so any spacer recompute is anchored:

```ts
const recomputeSpacersAnchored = (): void => {
  // Capture BEFORE Vue re-renders the new spacer heights.
  captureAnchor()
  updateAccumulatedHeights()
  // Wait for the DOM to apply the new spacer heights, THEN
  // restore. nextTick waits for Vue's render, but the spacer
  // style mutation also triggers a layout — we wait one extra
  // rAF to be sure.
  nextTick(() => {
    requestAnimationFrame(() => {
      restoreAnchor()
    })
  })
}
```

Every existing call site of `updateAccumulatedHeights` switches to `recomputeSpacersAnchored`:

- `watch(() => props.items.length, ...)` (line 300)
- `endPreserve` (line 556)
- `measureItems` (line 437) — only when `changed === true`

The existing `endPreserve` strategy A (DOM-based anchor) is unchanged. Strategy B becomes anchored automatically because it goes through `recomputeSpacersAnchored`.

### 3.5 Why the scroll-anchor is robust

- It captures the **topmost rendered item's relative offset** (offsetTop − scrollTop), not absolute pixel offsets. This is invariant to the spacers' absolute sizes — only their *deltas* matter.
- It uses the `data-vs-index` attribute (already on every item per `VirtualScroller.vue:646`) to re-find the same item after the re-render. The DOM element is recreated, but the attribute is preserved.
- It clamps to `[0, maxScrollTop]` so it can't accidentally scroll into negative territory if the topmost item scrolled off-screen.
- It is a no-op if `anchorIndex` is null (e.g. before the first render, after a chat switch that cleared the DOM).
- It does **not** interfere with the existing stick-to-bottom logic in `ChatView.onSpacersResized` — that fires on a different signal (the parent's `MutationObserver` on the spacer divs), and only re-sticks when `isAtBottom === true`. The scroll-anchor is the "user is NOT at the bottom, preserve their view" case.

### 3.6 ChatView height estimator

A small pure function in `ChatView.vue` (or extracted to `src/apps/desktop/src/helpers/chatMessageHeightEstimate.ts` for testability):

```ts
// src/apps/desktop/src/helpers/chatMessageHeightEstimate.ts

interface EstimateInput {
  role: 'user' | 'assistant' | 'system' | 'tool'
  content: string
  tool_name?: string
  image_urls?: string[]
  // Other fields don't affect the estimate.
}

const LINE_HEIGHT_PX = 22          // text-sm leading-relaxed ≈ 22 px per line
const CHARS_PER_LINE = 70          // max-w-4xl + px-4 + py-2.5 → ~70 chars/line
const CODE_BLOCK_OVERHEAD_PX = 28  // <pre> padding + border
const IMAGE_LINE_PX = 256          // max-h-64 → capped at 256 px per image
const TOOL_OVERHEAD_PX = 80        // tool result header + borders

export const estimateChatMessageHeight = (msg: EstimateInput): number => {
  // Padding (py-2.5) + bubble borders ≈ 20 px
  let h = 20

  if (msg.image_urls && msg.image_urls.length > 0) {
    h += msg.image_urls.length * IMAGE_LINE_PX
  }

  if (msg.content) {
    const textLines = Math.ceil(msg.content.length / CHARS_PER_LINE)
    h += textLines * LINE_HEIGHT_PX
  }

  if (msg.role === 'tool') {
    h += TOOL_OVERHEAD_PX
  }

  // Floor at 60 px (very short user messages), cap at 2000 px
  // (we'd rather over-estimate than under, since over-estimate
  // means the buffer zone is bigger, which is harmless).
  return Math.max(60, Math.min(2000, h))
}
```

This is a rough estimate. A 5,000 px assistant response is rare and gets capped at 2,000 px — the spacer still mutates by 1,800 px when it's measured, but the scroll-anchor (3.1.3) handles it.

`ChatView.vue:1749-1763` wires the callback into `<VirtualScroller :estimated-item-height="...">`:

```vue
<VirtualScroller
  v-if="isLoading || messageGroups.length > 0"
  ref="virtualScrollerRef"
  :items="messageGroups"
  :total-count="0"
  :buffer="20"
  :default-item-height="200"
  :estimated-item-height="estimateMessageGroupHeight"
  :load-more-threshold="200"
  :load-more-threshold-ratio="0.5"
  :load-more-at-top="true"
  @load-more="handleLoadMore"
  @load-more-suppressed="handleLoadMoreSuppressed"
  @scroll="handleVirtualScroll"
  @scrollability-change="scrollerIsScrollable = $event"
>
```

```ts
// src/apps/desktop/src/components/ChatView.vue
const estimateMessageGroupHeight = (group: MessageGroup, _index: number): number => {
  // Use the first message in the group as the size proxy. For
  // user groups there's only one message; for assistant/tool
  // groups, the first is the dominant one.
  const first = group.messages[0]
  if (!first) return 200
  return estimateChatMessageHeight({
    role: first.role,
    content: first.content,
    tool_name: first.tool_name,
    image_urls: first.image_urls,
  })
}
```

---

## 4. File structure

### New files

- `src/apps/desktop/src/helpers/chatMessageHeightEstimate.ts` — the pure estimator function (~40 lines).
- `src/apps/desktop/src/__tests__/helpers/chatMessageHeightEstimate.spec.ts` — unit tests for the estimator.
- `src/apps/desktop/src/__tests__/helpers/VirtualScroller.spec.ts` — unit tests for the new `estimatedItemHeight` prop and the scroll-anchor mechanism.

### Modified files

- `src/apps/desktop/src/helpers/VirtualScroller.vue`
  - Add `estimatedItemHeight` prop.
  - Add `captureAnchor` / `restoreAnchor` / `recomputeSpacersAnchored` helpers.
  - Switch `updateAccumulatedHeights` callers to `recomputeSpacersAnchored`.
  - Skip buffer items in `measureItems`.
  - Use `estimatedItemHeight` in `updateAccumulatedHeights`, `visibleRange`, `endPreserve` strategy B, `scrollToIndex`.
  - Expose `captureAnchor` / `restoreAnchor` for testing (and a manual public `recomputeSpacersAnchored` if useful for the parent).
  - Update JSDoc on `defaultItemHeight` to explain the precedence: `measured > estimatedItemHeight > defaultItemHeight`.

- `src/apps/desktop/src/components/ChatView.vue`
  - Import `estimateChatMessageHeight` from the new module.
  - Add `estimateMessageGroupHeight` callback.
  - Pass `:estimated-item-height="estimateMessageGroupHeight"` to `<VirtualScroller>`.
  - No other changes — the scroll-anchor lives in the scroller, the parent is unchanged.

### Unchanged files

- `src/apps/desktop/src/helpers/scrollLogger.ts` — no change. The logs will naturally become quieter once spacer mutations stop, but the logger is the diagnostic tool, not the cause.
- `src/apps/desktop/src/components/ChatsList.vue` — no change. `ChatsList` doesn't suffer from the "first item very tall" issue (chat cards are roughly uniform).
- `src/apps/desktop/src/__tests__/setup.ts` — no change. The existing `ResizeObserver` stub is sufficient.

---

## 5. Task decomposition

The work is split into **3 chunks** for independent review and subagent dispatch:

| Chunk | Files | Estimated steps |
| --- | --- | --- |
| **1. VirtualScroller: estimated height + buffer-skip + scroll-anchor** | `VirtualScroller.vue` | ~20 steps |
| **2. ChatView: wire the estimator** | `chatMessageHeightEstimate.ts`, `ChatView.vue` | ~6 steps |
| **3. Tests** | `VirtualScroller.spec.ts`, `chatMessageHeightEstimate.spec.ts` | ~10 steps |

Chunk 1 is the meaty part and is fully self-contained (no parent changes). Chunks 2 and 3 depend on chunk 1's API.

---

## Chunk 1: VirtualScroller — estimatedItemHeight + buffer-skip + scroll-anchor

> **Files:**
> - Modify: `src/apps/desktop/src/helpers/VirtualScroller.vue`
> - Test: `src/apps/desktop/src/__tests__/helpers/VirtualScroller.spec.ts` (new; full tests in chunk 3)

### Task 1.1: Add `estimatedItemHeight` prop declaration

**Files:**
- Modify: `src/apps/desktop/src/helpers/VirtualScroller.vue:80` (after the `defaultItemHeight` JSDoc block)

- [ ] **Step 1: Write the failing test** — Add a test in `VirtualScroller.spec.ts`:

```ts
import { mount } from '@vue/test-utils'
import { describe, it, expect } from 'vitest'
import { nextTick } from 'vue'
import VirtualScroller from '@/helpers/VirtualScroller.vue'

describe('VirtualScroller.estimatedItemHeight', () => {
  it('declares the estimatedItemHeight prop in its schema', () => {
    const wrapper = mount(VirtualScroller, {
      props: { items: [{ id: 1 }] },
    })
    const schema = wrapper.vm.$options.props ?? {}
    expect(Object.keys(schema)).toContain('estimatedItemHeight')
    // prop is optional, default undefined
    expect(schema.estimatedItemHeight).toBeDefined()
    expect(schema.estimatedItemHeight.default).toBeUndefined()
    expect(schema.estimatedItemHeight.type).toBe(Function)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run src/__tests__/helpers/VirtualScroller.spec.ts 2>&1 | tail -n 20`
Expected: FAIL with "expected Object.keys(schema) to contain 'estimatedItemHeight'"

- [ ] **Step 3: Add the prop declaration**

In `VirtualScroller.vue`, after the `defaultItemHeight` block (ends around line 80, before the `loadMoreThreshold` block), add:

```ts
/**
 * Optional per-item height estimator. Called once per item per
 * `updateAccumulatedHeights` recomputation. The precedence is:
 *   1. The measured value (if `measureItems` has run for this
 *      item — see HYSTERESIS_PX in measureItems for the
 *      write threshold).
 *   2. This callback (if provided).
 *   3. `defaultItemHeight` (the final fallback).
 *
 * Use this when you know some items are much taller than others
 * (chat bubbles with code blocks, image-only messages, tool
 * results with long diffs). A good estimate keeps the spacers
 * accurate from the very first paint, so the scrollbar doesn't
 * jump when the item is first measured.
 *
 * Should be cheap (called O(N) per `updateAccumulatedHeights`,
 * where N = items.length, on the items-length watcher, the
 * measurement debounce, the resize observer, and `endPreserve`).
 * For very long lists, cache the estimate in the parent.
 *
 * Receives `(item, index)` so the parent can branch on
 * message role, content type, etc.
 */
estimatedItemHeight?: (item: T, index: number) => number
```

- [ ] **Step 4: Run test to verify it passes**

Run: `timeout 60 bunx vitest run src/__tests__/helpers/VirtualScroller.spec.ts 2>&1 | tail -n 20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop/src/helpers/VirtualScroller.vue src/apps/desktop/src/__tests__/helpers/VirtualScroller.spec.ts
git commit -m "feat(virtual-scroller): add estimatedItemHeight prop"
```

### Task 1.2: Use `estimatedItemHeight` in `updateAccumulatedHeights`

**Files:**
- Modify: `src/apps/desktop/src/helpers/VirtualScroller.vue:272-280`

- [ ] **Step 1: Write the failing test**

```ts
describe('VirtualScroller.estimatedItemHeight precedence', () => {
  it('uses estimatedItemHeight over defaultItemHeight for unmeasured items', () => {
    const items = Array.from({ length: 3 }, (_, i) => ({ id: i }))
    const estimator = (item: { id: number }) => (item.id === 0 ? 500 : 100)
    const wrapper = mount(VirtualScroller, {
      props: {
        items,
        defaultItemHeight: 200,
        estimatedItemHeight: estimator,
      },
    })
    const scroller = wrapper.vm as unknown as {
      accumulatedHeights: { value: number[] }
    }
    // accumulatedHeights[0] = 0, [1] = 500, [2] = 600, [3] = 700
    expect(scroller.accumulatedHeights.value).toEqual([0, 500, 600, 700])
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `timeout 60 bunx vitest run src/__tests__/helpers/VirtualScroller.spec.ts 2>&1 | tail -n 20`
Expected: FAIL — currently `accumulatedHeights` would be `[0, 200, 400, 600]`.

- [ ] **Step 3: Update `updateAccumulatedHeights`**

```ts
const updateAccumulatedHeights = () => {
  const h: number[] = [0]
  let sum = 0
  for (let i = 0; i < props.items.length; i++) {
    const measured = itemHeights.value.get(i)
    if (measured !== undefined) {
      sum += measured
    } else if (props.estimatedItemHeight) {
      sum += props.estimatedItemHeight(props.items[i]!, i)
    } else {
      sum += props.defaultItemHeight
    }
    h.push(sum)
  }
  accumulatedHeights.value = h
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `timeout 60 bunx vitest run src/__tests__/helpers/VirtualScroller.spec.ts 2>&1 | tail -n 20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop/src/helpers/VirtualScroller.vue src/apps/desktop/src/__tests__/helpers/VirtualScroller.spec.ts
git commit -m "feat(virtual-scroller): prefer estimatedItemHeight in updateAccumulatedHeights"
```

### Task 1.3: Use `estimatedItemHeight` in `visibleRange`

**Files:**
- Modify: `src/apps/desktop/src/helpers/VirtualScroller.vue:334` (inside the `endIndex` while-loop)

- [ ] **Step 1: Add the test** (same file, new `it` block)

```ts
it('uses estimatedItemHeight in visibleRange for endIndex advancement', () => {
  const items = Array.from({ length: 100 }, (_, i) => ({ id: i }))
  const estimator = (_item: { id: number }, i: number) => (i === 0 ? 500 : 100)
  const wrapper = mount(VirtualScroller, {
    props: {
      items,
      defaultItemHeight: 200,
      estimatedItemHeight: estimator,
      containerHeight: 800,
    },
  })
  const scroller = wrapper.vm as unknown as {
    visibleRange: { value: { start: number; end: number } }
  }
  // With 100px items (after the 500px first), containerHeight=800,
  // we should be able to see ~8 items. With 200px default, we'd
  // see 4. So end should be larger.
  expect(scroller.visibleRange.value.end).toBeGreaterThanOrEqual(8)
})
```

- [ ] **Step 2: Run test to verify it fails** (it currently uses `defaultItemHeight` in the while loop)

- [ ] **Step 3: Update the `visibleRange` while-loop**

```ts
let acc = accumulatedHeights.value[startIndex] ?? 0
let endIndex = startIndex
while (endIndex < len && acc < viewBottom) {
  const measured = itemHeights.value.get(endIndex)
  if (measured !== undefined) {
    acc += measured
  } else if (props.estimatedItemHeight) {
    acc += props.estimatedItemHeight(props.items[endIndex]!, endIndex)
  } else {
    acc += props.defaultItemHeight
  }
  endIndex++
}
```

- [ ] **Step 4: Run test to verify it passes**

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop/src/helpers/VirtualScroller.vue src/apps/desktop/src/__tests__/helpers/VirtualScroller.spec.ts
git commit -m "feat(virtual-scroller): use estimatedItemHeight in visibleRange"
```

### Task 1.4: Use `estimatedItemHeight` in `endPreserve` strategy B and `scrollToIndex`

**Files:**
- Modify: `src/apps/desktop/src/helpers/VirtualScroller.vue:573` (strategy B sum loop)
- Modify: `src/apps/desktop/src/helpers/VirtualScroller.vue:589` (`scrollToIndex`)

- [ ] **Step 1: Add the test for `endPreserve` strategy B**

```ts
it('endPreserve strategy B uses estimatedItemHeight for the prepend sum', async () => {
  // This test is exercised by Task 1.5 (endPreserve changes); we
  // add the test as part of that task. Skipping for this task.
})
```

- [ ] **Step 2: Update the sum loop and `scrollToIndex`**

`endPreserve` strategy B (line 571-574):

```ts
let sum = 0
for (let i = 0; i < n; i++) {
  const measured = itemHeights.value.get(i)
  if (measured !== undefined) {
    sum += measured
  } else if (props.estimatedItemHeight) {
    sum += props.estimatedItemHeight(props.items[i]!, i)
  } else {
    sum += props.defaultItemHeight
  }
}
```

`scrollToIndex` (line 589):

```ts
const scrollToIndex = (index: number, behavior: ScrollBehavior = 'auto') => {
  if (!containerRef.value) return
  const cached = accumulatedHeights.value[index]
  if (cached !== undefined) {
    containerRef.value.scrollTo({ top: cached, behavior })
    return
  }
  // Fallback: sum estimates from 0 to index-1.
  let sum = 0
  for (let i = 0; i < index; i++) {
    const measured = itemHeights.value.get(i)
    if (measured !== undefined) sum += measured
    else if (props.estimatedItemHeight)
      sum += props.estimatedItemHeight(props.items[i]!, i)
    else sum += props.defaultItemHeight
  }
  containerRef.value.scrollTo({ top: sum, behavior })
}
```

- [ ] **Step 3: Run test to verify it passes** (no new failing test needed — covered by the integration in Task 1.5)

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/helpers/VirtualScroller.vue
git commit -m "feat(virtual-scroller): use estimatedItemHeight in endPreserve B and scrollToIndex"
```

### Task 1.5: Buffer-zone measurement skip in `measureItems`

**Files:**
- Modify: `src/apps/desktop/src/helpers/VirtualScroller.vue:413-438`

- [ ] **Step 1: Write the failing test**

```ts
it('measureItems does not write heights for buffer items (only visible range)', async () => {
  const items = Array.from({ length: 100 }, (_, i) => ({ id: i }))
  const wrapper = mount(VirtualScroller, {
    props: {
      items,
      defaultItemHeight: 100,
      containerHeight: 300, // ~3 visible items
      buffer: 2,
    },
    attachTo: document.body,
  })
  await nextTick()
  // Simulate that items 0..6 are rendered (visible + 2 buffer each side).
  // Set their offsetHeight to 500 (very tall) and call measureItems.
  const content = wrapper.vm.$el.querySelector('.virtual-scroller-content') as HTMLElement
  for (let i = 0; i < content.children.length; i++) {
    Object.defineProperty(content.children[i] as HTMLElement, 'offsetHeight', {
      configurable: true,
      get: () => 500,
    })
  }
  // Call measureItems via the exposed handle.
  const scroller = wrapper.vm as unknown as { measureItems?: () => void }
  // measureItems is internal — trigger via a forced scroll event.
  ;(wrapper.vm as unknown as { onScroll: (e: Event) => void }).onScroll(
    new Event('scroll'),
  )
  await new Promise((r) => setTimeout(r, 100)) // wait for measureDebounce
  // After measurement, itemHeights should only have entries for
  // visible items (those whose [data-vs-index] is in [start, end)),
  // NOT for buffer items.
  const itemHeights = (scroller as unknown as { itemHeights: { value: Map<number, number> } })
    .itemHeights.value
  // The exact set depends on the visible range, but it should be
  // a strict subset of the rendered children. Verify by reading
  // the rendered indices.
  const renderedIndices = Array.from(content.children).map((c) =>
    parseInt((c as HTMLElement).getAttribute('data-vs-index') ?? '-1', 10),
  )
  for (const idx of itemHeights.keys()) {
    const visibleStart = (scroller as unknown as { visibleRange: { value: { start: number } } })
      .visibleRange.value.start
    const visibleEnd = (scroller as unknown as { visibleRange: { value: { end: number } } })
      .visibleRange.value.end
    expect(idx).toBeGreaterThanOrEqual(visibleStart)
    expect(idx).toBeLessThan(visibleEnd)
    // Sanity: idx is in the rendered set.
    expect(renderedIndices).toContain(idx)
  }
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `timeout 60 bunx vitest run src/__tests__/helpers/VirtualScroller.spec.ts 2>&1 | tail -n 30`
Expected: FAIL — currently buffer items are measured.

- [ ] **Step 3: Update `measureItems`**

```ts
const measureItems = () => {
  if (!containerRef.value) return
  const content = containerRef.value.querySelector('.virtual-scroller-content')
  if (!content) return
  let changed = false
  const { start, end } = visibleRange.value
  const children = content.children
  for (let i = 0; i < children.length; i++) {
    const el = children[i] as HTMLElement
    const realIndex = start + i
    // Only measure items in the VISIBLE range. Buffer items are
    // intentionally not measured here — their height is whatever
    // the estimate says (or the previous measurement if they
    // were visible before the user scrolled). This stops a 5,000
    // px first message from causing a 4,800 px spacer mutation
    // just because it rolled into the buffer.
    if (realIndex < start || realIndex >= end) continue
    const h = el.offsetHeight
    if (h > 0) {
      const prev = itemHeights.value.get(realIndex)
      if (prev === undefined || Math.abs(h - prev) > HYSTERESIS_PX) {
        itemHeights.value.set(realIndex, h)
        changed = true
      }
    }
  }
  if (changed) updateAccumulatedHeights()
}
```

- [ ] **Step 4: Run test to verify it passes**

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop/src/helpers/VirtualScroller.vue src/apps/desktop/src/__tests__/helpers/VirtualScroller.spec.ts
git commit -m "feat(virtual-scroller): measureItems skips buffer items"
```

### Task 1.6: Add `captureAnchor` / `restoreAnchor` / `recomputeSpacersAnchored` helpers

**Files:**
- Modify: `src/apps/desktop/src/helpers/VirtualScroller.vue` (new section after `updateAccumulatedHeights`, around line 280)

- [ ] **Step 1: Write the failing test**

```ts
it('recomputeSpacersAnchored captures and restores the topmost visible item', async () => {
  // Set up a 10-item list, scroll to item 3, then mutate spacers
  // and verify scrollTop adjusts to keep item 3 at the same
  // screen position.
  const items = Array.from({ length: 10 }, (_, i) => ({ id: i }))
  const wrapper = mount(VirtualScroller, {
    props: {
      items,
      defaultItemHeight: 100,
      containerHeight: 300,
    },
    attachTo: document.body,
  })
  await nextTick()
  const container = wrapper.vm.$el as HTMLElement
  // Simulate items 0..2 each being 500px (very tall).
  const content = container.querySelector('.virtual-scroller-content') as HTMLElement
  for (let i = 0; i < content.children.length; i++) {
    const idx = parseInt(
      (content.children[i] as HTMLElement).getAttribute('data-vs-index') ?? '-1',
      10,
    )
    Object.defineProperty(content.children[i] as HTMLElement, 'offsetHeight', {
      configurable: true,
      get: () => (idx <= 2 ? 500 : 100),
    })
  }
  // Scroll to a position where item 3 is roughly at the top.
  container.scrollTop = 1500
  await nextTick()
  // Read the topmost rendered item's offsetTop.
  const topmostIdxBefore = parseInt(
    (content.children[0] as HTMLElement).getAttribute('data-vs-index') ?? '-1',
    10,
  )
  const topmostOffsetTopBefore = (content.children[0] as HTMLElement).offsetTop
  const topmostScreenYBefore = topmostOffsetTopBefore - container.scrollTop
  // Mutate the spacers (simulate item 0 being measured very tall).
  const scroller = wrapper.vm as unknown as {
    recomputeSpacersAnchored: () => void
  }
  scroller.recomputeSpacersAnchored()
  await new Promise((r) => requestAnimationFrame(() => r(null)))
  // After the recompute, find the same item (by index) and verify
  // it's at the same screen Y.
  const topmost = content.querySelector(
    `[data-vs-index="${topmostIdxBefore}"]`,
  ) as HTMLElement | null
  expect(topmost).not.toBeNull()
  const topmostScreenYAfter = topmost!.offsetTop - container.scrollTop
  // Allow 1px tolerance for layout rounding.
  expect(Math.abs(topmostScreenYAfter - topmostScreenYBefore)).toBeLessThanOrEqual(1)
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `timeout 60 bunx vitest run src/__tests__/helpers/VirtualScroller.spec.ts 2>&1 | tail -n 30`
Expected: FAIL — `recomputeSpacersAnchored` doesn't exist.

- [ ] **Step 3: Add the helpers**

Insert after `updateAccumulatedHeights` (around line 280):

```ts
// ─── Scroll anchor ───────────────────────────────────────────────────
//
// Captures the topmost rendered item's screen position before a
// spacer mutation, then restores it after the DOM updates. This
// keeps the user's view stable when items are re-measured — the
// spacers can change freely, but the message the user was
// reading stays at the same screen position.
//
// Mirrors what `beginPreserve`/`endPreserve` already do for the
// `loadMore` (prepend) case, but generalized to any spacer
// change. The parent's `onSpacersResized` re-stick-to-bottom
// behavior is unchanged — that's a different signal (the parent's
// `MutationObserver` on the spacer divs, and only fires when
// `isAtBottom === true`).

let anchorIndex: number | null = null
let anchorOffsetTopInContainer: number | null = null

const captureAnchor = (): void => {
  if (!containerRef.value) return
  const content = containerRef.value.querySelector('.virtual-scroller-content')
  if (!content || content.children.length === 0) return
  const firstChild = content.children[0] as HTMLElement
  const idxStr = firstChild.getAttribute('data-vs-index')
  if (idxStr === null) return
  anchorIndex = parseInt(idxStr, 10)
  anchorOffsetTopInContainer = firstChild.offsetTop - containerRef.value.scrollTop
}

const restoreAnchor = (): void => {
  if (
    !containerRef.value ||
    anchorIndex === null ||
    anchorOffsetTopInContainer === null
  )
    return
  const content = containerRef.value.querySelector('.virtual-scroller-content')
  if (!content) return
  const target = content.querySelector(
    `[data-vs-index="${anchorIndex}"]`,
  ) as HTMLElement | null
  if (!target) return
  const desiredScrollTop = target.offsetTop - anchorOffsetTopInContainer
  const maxScrollTop = Math.max(
    0,
    containerRef.value.scrollHeight - containerRef.value.clientHeight,
  )
  containerRef.value.scrollTop = Math.max(0, Math.min(desiredScrollTop, maxScrollTop))
  // Clear the anchor so a stale value doesn't fire later.
  anchorIndex = null
  anchorOffsetTopInContainer = null
}

/**
 * Re-runs `updateAccumulatedHeights` with a scroll anchor: the
 * topmost visible item's screen position is captured BEFORE the
 * recompute, then restored AFTER the DOM updates.
 *
 * Use this anywhere you would have called `updateAccumulatedHeights`
 * directly. The anchor mechanism is a no-op when the scroller is at
 * the top or bottom edge (the `Math.min/Math.max` clamps handle
 * it) or when the chat is fully visible (no scroll possible).
 */
const recomputeSpacersAnchored = (): void => {
  captureAnchor()
  updateAccumulatedHeights()
  nextTick(() => {
    requestAnimationFrame(() => {
      restoreAnchor()
    })
  })
}
```

- [ ] **Step 4: Run test to verify it passes**

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop/src/helpers/VirtualScroller.vue src/apps/desktop/src/__tests__/helpers/VirtualScroller.spec.ts
git commit -m "feat(virtual-scroller): add captureAnchor/restoreAnchor/recomputeSpacersAnchored"
```

### Task 1.7: Route `updateAccumulatedHeights` callers through `recomputeSpacersAnchored`

**Files:**
- Modify: `src/apps/desktop/src/helpers/VirtualScroller.vue` (3 call sites)

- [ ] **Step 1: Switch the watchers and `endPreserve` to use the anchored variant**

- The `watch(() => props.items.length, ...)` (line 300): change `updateAccumulatedHeights` → `recomputeSpacersAnchored`.
- The `endPreserve` function (line 556): change `updateAccumulatedHeights` → `recomputeSpacersAnchored`.
- The `measureItems` function (line 437): change the `if (changed) updateAccumulatedHeights()` call to `if (changed) recomputeSpacersAnchored()`.

- [ ] **Step 2: Run all `VirtualScroller.spec.ts` tests**

Run: `timeout 60 bunx vitest run src/__tests__/helpers/VirtualScroller.spec.ts 2>&1 | tail -n 30`
Expected: all PASS (the new tests for `recomputeSpacersAnchored` should pass; the previous tests should still pass because the anchor is a no-op when no spacer change happens).

- [ ] **Step 3: Run `bun run build`**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20`
Expected: PASS (per project memory, `bun run build` is the type-check; `build-only` skips it)

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/helpers/VirtualScroller.vue
git commit -m "feat(virtual-scroller): route spacer recomputes through recomputeSpacersAnchored"
```

### Task 1.8: Expose `recomputeSpacersAnchored` and the anchor state in `defineExpose`

**Files:**
- Modify: `src/apps/desktop/src/helpers/VirtualScroller.vue:624-639`

- [ ] **Step 1: Add `recomputeSpacersAnchored` and the anchor state to `defineExpose`**

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
  recomputeSpacersAnchored, // exposed for tests + manual resync
  // Anchor state — read-only, useful for testing.
  anchorIndex: computed(() => anchorIndex),
  anchorOffsetTopInContainer: computed(() => anchorOffsetTopInContainer),
})
```

- [ ] **Step 2: Run `bun run build`**

Run: `timeout 120 bun run build 2>&1 | tail -n 20`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/helpers/VirtualScroller.vue
git commit -m "feat(virtual-scroller): expose recomputeSpacersAnchored in defineExpose"
```

### Task 1.9: Update `defaultItemHeight` JSDoc to document the precedence

**Files:**
- Modify: `src/apps/desktop/src/helpers/VirtualScroller.vue:60-80`

- [ ] **Step 1: Update the JSDoc**

```ts
/**
 * Estimated height in pixels for an item whose real height hasn't
 * been measured yet AND for which no `estimatedItemHeight` callback
 * is provided. The scroller uses this to size the top/bottom
 * spacers before measurement completes, which affects the initial
 * `scrollHeight` and therefore the initial scroll position.
 *
 * Precedence (highest first):
 *   1. The measured value (`itemHeights` Map, written by
 *      `measureItems` when the item is in the visible range).
 *   2. `estimatedItemHeight(item, i)` callback (if provided).
 *   3. This `defaultItemHeight` (final fallback).
 *
 * See the `estimatedItemHeight` JSDoc for why you'd want to pass
 * a per-item estimator.
 *
 * Pick a value close to your **median** real item height:
 * - Too small → the initial render undershoots `scrollHeight`, so
 *   after measurement the user appears scrolled up by the difference
 *   (the spacers grew). Usually fine if you "stick to bottom" — see
 *   the chat viewer for an example using a MutationObserver on the
 *   spacers to re-stick after measurement.
 * - Too large → the initial render overshoots `scrollHeight`; the
 *   browser clamps `scrollTop` to the real bottom, so the user
 *   lands correctly but the spacers briefly show extra blank space
 *   that snaps away.
 *
 * Default 100px suits most text rows. Chat bubbles with avatars and
 * markdown often want 150-250px.
 */
defaultItemHeight?: number
```

- [ ] **Step 2: Run `bun run build`** to verify the JSDoc parses cleanly

Run: `timeout 120 bun run build 2>&1 | tail -n 20`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/helpers/VirtualScroller.vue
git commit -m "docs(virtual-scroller): document estimatedItemHeight precedence"
```

---

## Chunk 2: ChatView — wire the estimator

> **Files:**
> - Create: `src/apps/desktop/src/helpers/chatMessageHeightEstimate.ts`
> - Modify: `src/apps/desktop/src/components/ChatView.vue`

### Task 2.1: Write the failing test for `estimateChatMessageHeight`

**Files:**
- Create: `src/apps/desktop/src/__tests__/helpers/chatMessageHeightEstimate.spec.ts`

- [ ] **Step 1: Write the tests**

```ts
import { describe, it, expect } from 'vitest'
import { estimateChatMessageHeight } from '@/helpers/chatMessageHeightEstimate'

describe('estimateChatMessageHeight', () => {
  it('returns the floor for an empty message', () => {
    expect(
      estimateChatMessageHeight({ role: 'user', content: '' }),
    ).toBeGreaterThanOrEqual(60)
  })

  it('estimates a short user message at ~20-100 px', () => {
    const h = estimateChatMessageHeight({
      role: 'user',
      content: 'hello',
    })
    expect(h).toBeGreaterThanOrEqual(60)
    expect(h).toBeLessThan(100)
  })

  it('estimates a long user message proportional to content length', () => {
    const short = estimateChatMessageHeight({
      role: 'user',
      content: 'a'.repeat(70),
    })
    const long = estimateChatMessageHeight({
      role: 'user',
      content: 'a'.repeat(700),
    })
    expect(long).toBeGreaterThan(short * 3)
  })

  it('adds overhead for an image-only user message', () => {
    const noImage = estimateChatMessageHeight({
      role: 'user',
      content: '',
    })
    const withImage = estimateChatMessageHeight({
      role: 'user',
      content: '',
      image_urls: ['data:image/png;base64,abc'],
    })
    expect(withImage).toBeGreaterThan(noImage + 200)
  })

  it('adds multiple images worth of height', () => {
    const one = estimateChatMessageHeight({
      role: 'user',
      content: '',
      image_urls: ['data:image/png;base64,a'],
    })
    const three = estimateChatMessageHeight({
      role: 'user',
      content: '',
      image_urls: ['data:image/png;base64,a', 'data:image/png;base64,b', 'data:image/png;base64,c'],
    })
    expect(three).toBeGreaterThan(one * 2)
  })

  it('adds tool overhead for a tool message', () => {
    const user = estimateChatMessageHeight({
      role: 'user',
      content: 'a'.repeat(70),
    })
    const tool = estimateChatMessageHeight({
      role: 'tool',
      content: 'a'.repeat(70),
      tool_name: 'read_file',
    })
    expect(tool).toBeGreaterThan(user)
  })

  it('caps at 2000 px so a runaway estimate cannot dominate the buffer', () => {
    const h = estimateChatMessageHeight({
      role: 'assistant',
      content: 'a'.repeat(100_000),
    })
    expect(h).toBeLessThanOrEqual(2000)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run src/__tests__/helpers/chatMessageHeightEstimate.spec.ts 2>&1 | tail -n 20`
Expected: FAIL — module not found.

- [ ] **Step 3: Create the module**

```ts
// src/apps/desktop/src/helpers/chatMessageHeightEstimate.ts
/**
 * Rough height estimator for chat message bubbles.
 *
 * Called by ChatView (via VirtualScroller's `estimatedItemHeight`
 * prop) once per message per `updateAccumulatedHeights` recompute.
 * Should be cheap and pessimistic (over-estimate is fine; under-
 * estimate is what causes the "scroll jumps 60% to 79%" symptom).
 *
 * The numbers below are tuned to match the actual rendered
 * message bubble in ChatView.vue: the bubble uses
 * `px-4 py-2.5 rounded-2xl text-sm leading-relaxed` inside
 * `max-w-4xl mx-auto`, with `markdown-content` for assistant
 * messages. See the ChatView template at
 * `src/apps/desktop/src/components/ChatView.vue:1771-1805`.
 *
 * The cap at 2000 px is intentional: a 5,000+ px assistant
 * response would otherwise shift the spacers by 4,800+ px on
 * first measurement. The cap keeps the shift manageable; the
 * scroll-anchor in VirtualScroller handles the residual.
 */

export interface ChatMessageHeightEstimateInput {
  role: 'user' | 'assistant' | 'system' | 'tool'
  content: string
  tool_name?: string
  image_urls?: string[]
}

const LINE_HEIGHT_PX = 22          // text-sm leading-relaxed ≈ 22 px per line
const CHARS_PER_LINE = 70          // max-w-4xl + px-4 + py-2.5 → ~70 chars/line
const IMAGE_LINE_PX = 256          // max-h-64 → capped at 256 px per image
const TOOL_OVERHEAD_PX = 80        // tool result header + borders
const BUBBLE_PADDING_PX = 20       // py-2.5 + bubble borders
const FLOOR_PX = 60                // very short user messages
const CAP_PX = 2000                // avoid 4,800+ px spacer shifts

export const estimateChatMessageHeight = (
  msg: ChatMessageHeightEstimateInput,
): number => {
  let h = BUBBLE_PADDING_PX

  if (msg.image_urls && msg.image_urls.length > 0) {
    h += msg.image_urls.length * IMAGE_LINE_PX
  }

  if (msg.content) {
    const textLines = Math.ceil(msg.content.length / CHARS_PER_LINE)
    h += textLines * LINE_HEIGHT_PX
  }

  if (msg.role === 'tool') {
    h += TOOL_OVERHEAD_PX
  }

  return Math.max(FLOOR_PX, Math.min(CAP_PX, h))
}
```

- [ ] **Step 4: Run test to verify it passes**

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop/src/helpers/chatMessageHeightEstimate.ts src/apps/desktop/src/__tests__/helpers/chatMessageHeightEstimate.spec.ts
git commit -m "feat(chat): add estimateChatMessageHeight pure helper"
```

### Task 2.2: Wire the estimator into `<VirtualScroller>`

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue` (around the `<VirtualScroller>` block, line 1749-1763)

- [ ] **Step 1: Write the failing test** — Add a test that mounts `ChatView` and verifies the prop is passed:

```ts
// src/apps/desktop/src/__tests__/ChatView.estimateHeight.spec.ts
// (Smoke test; the real coverage is in
// chatMessageHeightEstimate.spec.ts + the end-to-end manual test.)

import { describe, it, expect, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import ChatView from '@/components/ChatView.vue'

// ... stub VirtualScroller and other heavy deps ...
```

**Note:** a full `ChatView` mount is expensive (Markdown renderer, code blocks, etc.). The cheapest verification is to inspect the rendered template directly:

```ts
it('passes :estimated-item-height to <VirtualScroller>', () => {
  const wrapper = mount(ChatView, {
    props: { chatId: 'test' },
    global: {
      // ... minimal stubs ...
    },
  })
  const scroller = wrapper.findComponent({ name: 'VirtualScroller' })
  expect(scroller.exists()).toBe(true)
  expect(scroller.props('estimatedItemHeight')).toBeTypeOf('function')
})
```

For a one-shot smoke test, you can also read the template source and assert the binding is present. The full E2E verification is in Task 2.4 (manual test in browser).

- [ ] **Step 2: Run test to verify it fails** — expect `estimatedItemHeight` prop to be undefined.

- [ ] **Step 3: Add the import and the callback to `ChatView.vue`**

In the `<script setup>` section, near the other imports (top of file):

```ts
import { estimateChatMessageHeight } from '@/helpers/chatMessageHeightEstimate'
```

Add a callback near the other height-related code (after `findSubAgentArgsForToolGroup`, around line 661):

```ts
/**
 * Per-item height estimator for VirtualScroller. Receives a
 * MessageGroup (which may contain multiple messages — e.g. a
 * tool group with several results) and returns the dominant
 * estimated height. The first message in the group is the
 * size proxy; for tool groups with several results we use
 * the FIRST result (subsequent results stack below the first
 * and don't affect the virtual scroller's per-slot sizing).
 */
const estimateMessageGroupHeight = (group: MessageGroup, _index: number): number => {
  const first = group.messages[0]
  if (!first) return 200
  return estimateChatMessageHeight({
    role: first.role,
    content: first.content,
    tool_name: first.tool_name,
    image_urls: first.image_urls,
  })
}
```

Pass it to the `<VirtualScroller>`:

```vue
<VirtualScroller
  v-if="isLoading || messageGroups.length > 0"
  ref="virtualScrollerRef"
  :items="messageGroups"
  :total-count="0"
  :buffer="20"
  :default-item-height="200"
  :estimated-item-height="estimateMessageGroupHeight"
  :load-more-threshold="200"
  :load-more-threshold-ratio="0.5"
  :load-more-at-top="true"
  @load-more="handleLoadMore"
  @load-more-suppressed="handleLoadMoreSuppressed"
  @scroll="handleVirtualScroll"
  @scrollability-change="scrollerIsScrollable = $event"
>
```

- [ ] **Step 4: Run test to verify it passes**

- [ ] **Step 5: Run `bun run build`**

Run: `timeout 120 bun run build 2>&1 | tail -n 20`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/apps/desktop/src/components/ChatView.vue src/apps/desktop/src/__tests__/ChatView.estimateHeight.spec.ts
git commit -m "feat(chat): pass estimated-item-height to VirtualScroller"
```

### Task 2.3: Verify `ChatsList` is unaffected

**Files:**
- None (`ChatsList.vue` doesn't pass `estimatedItemHeight`, so the new prop is just unused)

- [ ] **Step 1: Run `ChatsList` tests**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run src/__tests__/workspacesStoreLoadMoreTasks.spec.ts src/__tests__/workspaceItemTaskLoadMore.spec.ts 2>&1 | tail -n 20`
Expected: PASS (these don't touch VirtualScroller directly, but the ChatsList page uses it; we want to make sure no regression in ChatsList)

- [ ] **Step 2: Run a manual smoke test in the browser** (Task 2.4 covers this in detail; here we just confirm ChatsList still renders chats correctly).

- [ ] **Step 3: Commit** (no changes; just record the verification in the test output)

```bash
# If no changes, skip this step. If a test fix was needed, commit it.
git status
# If clean, move on. If dirty, commit any test fix.
```

### Task 2.4: Manual verification in browser

- [ ] **Step 1: Open a chat with a very tall first message** (the exact scenario from the bug report)

Run: `cd src/apps/desktop && bun run dev` and open a chat that has a long first message (>2,000 px). Use the dev-tools scrollLogger panel.

- [ ] **Step 2: Scroll to ~60% of the list and stop**

Watch the `scrollLogger` panel. With the fix in place:
- `content-resized` lines should drop by ~80% (buffer items are no longer measured; the first message is now estimated at ~2,000 px instead of 200 px).
- The bottom percentage should not jump 13 percentage points in a single event (the residual jump is capped by the scroll-anchor to ~1 px = 0% on screen).
- The scrollbar thumb should not visibly jump between events.

- [ ] **Step 3: Resize the window** — no jump; scrollbar stays put.

- [ ] **Step 4: Stream a long assistant response** — no jump; the streaming bubble grows naturally below the user's view.

- [ ] **Step 5: Open a fresh chat with 712 messages, scroll to the top, click "Load more messages"** — scroll position preserved (existing `endPreserve` behavior), no additional jump from the new code.

- [ ] **Step 6: Open the chats list (ChatsList) and scroll** — no regression; cards still virtualization correctly.

- [ ] **Step 7: Commit** (no changes; record the verification result)

```bash
git status
# If clean, move on. If dirty, fix and commit.
```

---

## Chunk 3: Tests + verification

> **Files:**
> - Create: `src/apps/desktop/src/__tests__/helpers/VirtualScroller.spec.ts` (some tests already added in chunk 1; this chunk adds the integration tests)
> - Existing: `src/apps/desktop/src/__tests__/helpers/chatMessageHeightEstimate.spec.ts` (chunk 2)

### Task 3.1: Add a `VirtualScroller` integration test for the full scenario

**Files:**
- Modify: `src/apps/desktop/src/__tests__/helpers/VirtualScroller.spec.ts`

- [ ] **Step 1: Add the test**

```ts
describe('VirtualScroller integration: tall first item + scroll to mid', () => {
  it('keeps the topmost visible item at the same screen Y across spacer recomputes', async () => {
    // Simulate the exact bug report: 712 items, first item 5,000 px,
    // user scrolls to item 400 (~60%), items get measured.
    const items = Array.from({ length: 712 }, (_, i) => ({ id: i }))
    const wrapper = mount(VirtualScroller, {
      props: {
        items,
        defaultItemHeight: 200,
        containerHeight: 800,
        buffer: 20,
        estimatedItemHeight: (_item, i) => (i === 0 ? 2000 : 200), // first item: cap'd estimate
      },
      attachTo: document.body,
    })
    await nextTick()
    const container = wrapper.vm.$el as HTMLElement
    // Scroll to ~60% — total estimated ≈ 200 + 711*200 = 142,400;
    // 60% ≈ 85,440.
    container.scrollTop = 85_000
    await nextTick()
    // Read the topmost visible item and its screen Y.
    const content = container.querySelector('.virtual-scroller-content') as HTMLElement
    const topmostBefore = content.children[0] as HTMLElement
    const topmostIdx = parseInt(topmostBefore.getAttribute('data-vs-index') ?? '-1', 10)
    const screenYBefore = topmostBefore.offsetTop - container.scrollTop
    // Simulate item 0 being measured to be 5,000 px (a real layout
    // change). The estimatedItemHeight was 2,000, so the delta is
    // 3,000 px. This is the case the scroll-anchor must absorb.
    const scroller = wrapper.vm as unknown as {
      itemHeights: { value: Map<number, number> }
      recomputeSpacersAnchored: () => void
    }
    scroller.itemHeights.value.set(0, 5000)
    scroller.recomputeSpacersAnchored()
    await new Promise((r) => requestAnimationFrame(() => r(null)))
    // After the recompute, find the same item by index and verify
    // it's at the same screen Y as before.
    const topmostAfter = content.querySelector(
      `[data-vs-index="${topmostIdx}"]`,
    ) as HTMLElement | null
    expect(topmostAfter).not.toBeNull()
    const screenYAfter = topmostAfter!.offsetTop - container.scrollTop
    // Allow 2 px tolerance for layout rounding.
    expect(Math.abs(screenYAfter - screenYBefore)).toBeLessThanOrEqual(2)
  })

  it('without estimatedItemHeight, a tall first item shifts the view by its full delta', async () => {
    // Sanity check: confirm the bug exists when the fix is not
    // applied. This test should FAIL on main (the bug is real).
    const items = Array.from({ length: 712 }, (_, i) => ({ id: i }))
    const wrapper = mount(VirtualScroller, {
      props: {
        items,
        defaultItemHeight: 200,
        containerHeight: 800,
        buffer: 20,
        // NO estimatedItemHeight — bug case
      },
      attachTo: document.body,
    })
    await nextTick()
    const container = wrapper.vm.$el as HTMLElement
    container.scrollTop = 85_000
    await nextTick()
    const content = container.querySelector('.virtual-scroller-content') as HTMLElement
    const topmostBefore = content.children[0] as HTMLElement
    const topmostIdx = parseInt(topmostBefore.getAttribute('data-vs-index') ?? '-1', 10)
    const screenYBefore = topmostBefore.offsetTop - container.scrollTop
    const scroller = wrapper.vm as unknown as {
      itemHeights: { value: Map<number, number> }
      recomputeSpacersAnchored: () => void
    }
    scroller.itemHeights.value.set(0, 5000)
    scroller.recomputeSpacersAnchored()
    await new Promise((r) => requestAnimationFrame(() => r(null)))
    const topmostAfter = content.querySelector(
      `[data-vs-index="${topmostIdx}"]`,
    ) as HTMLElement | null
    const screenYAfter = topmostAfter!.offsetTop - container.scrollTop
    // Without the fix, the screen Y would shift by 3000 px
    // (5000 actual - 2000 default). With the scroll-anchor, it's
    // ~0. We assert it's NOT shifted by 3000 px (i.e. the
    // scroll-anchor worked).
    expect(Math.abs(screenYAfter - screenYBefore)).toBeLessThan(50)
  })
})
```

- [ ] **Step 2: Run test to verify it passes**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run src/__tests__/helpers/VirtualScroller.spec.ts 2>&1 | tail -n 30`
Expected: PASS (both tests). The second test verifies the scroll-anchor works even without `estimatedItemHeight` — the anchor is the defense-in-depth layer.

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/__tests__/helpers/VirtualScroller.spec.ts
git commit -m "test(virtual-scroller): integration test for tall first item + scroll anchor"
```

### Task 3.2: Run the full test suite + `bun run build`

- [ ] **Step 1: Run all tests**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 20`
Expected: all PASS. Per project memory, this is the test-run only; the type-check is in `bun run build`.

- [ ] **Step 2: Run `bun run build`**

Run: `timeout 120 bun run build 2>&1 | tail -n 20`
Expected: PASS. Per project memory, this is the authoritative type-check (`vue-tsc --build`).

- [ ] **Step 3: If any test fails, fix and re-run** before declaring done.

---

## 6. Files touched

| File | Change | Lines (est.) |
| --- | --- | --- |
| `src/apps/desktop/src/helpers/VirtualScroller.vue` | Add `estimatedItemHeight` prop; use it in `updateAccumulatedHeights`, `visibleRange`, `endPreserve B`, `scrollToIndex`; skip buffer items in `measureItems`; add `captureAnchor`/`restoreAnchor`/`recomputeSpacersAnchored`; route callers; expose new APIs. | +120, -10 |
| `src/apps/desktop/src/components/ChatView.vue` | Import `estimateChatMessageHeight`; add `estimateMessageGroupHeight` callback; pass `:estimated-item-height`. | +20 |
| `src/apps/desktop/src/helpers/chatMessageHeightEstimate.ts` | New pure estimator function. | +50 |
| `src/apps/desktop/src/__tests__/helpers/VirtualScroller.spec.ts` | New test file. | +200 |
| `src/apps/desktop/src/__tests__/helpers/chatMessageHeightEstimate.spec.ts` | New test file. | +60 |
| `src/apps/desktop/src/__tests__/ChatView.estimateHeight.spec.ts` | New smoke test. | +30 |

Total: ~470 lines added, 10 lines removed. Six files touched.

---

## 7. Risks and mitigations

| Risk | Likelihood | Mitigation |
| --- | --- | --- |
| Estimator is inaccurate — short messages get over-estimated | High | The cap at 2,000 px is generous; over-estimate means a slightly larger buffer (cheap). The scroll-anchor absorbs any residual shift. |
| Estimator is inaccurate — long messages get under-estimated (capped at 2,000) | High (intentional) | The scroll-anchor (3.1.3) handles up to 5,000+ px shifts. Worst case: 1-frame visual artifact, then anchored. |
| Buffer-skip in `measureItems` causes buffer items to be unmeasured when they become visible | Low | When a buffer item rolls into the visible range, the next `measureItems` call (triggered by a scroll event) measures it. The 50 ms measurement debounce makes this imperceptible. |
| Scroll-anchor interferes with stick-to-bottom | Low | The anchor only fires for `recomputeSpacersAnchored` calls. Stick-to-bottom is a separate signal (parent's `MutationObserver` in `onSpacersResized`). The two are independent. |
| `anchorIndex` is stale across chat switches | Low | Cleared at the end of `restoreAnchor`. Cleared on chat switch by the parent's `onUnmounted` of `<VirtualScroller>` (the refs are recreated). |
| `recomputeSpacersAnchored` `requestAnimationFrame` race with rapid mutations | Low | Each call schedules a new RAF; the previous one is allowed to complete (it's idempotent because the anchor is captured at the start of the call). Worst case: one stale frame. |
| `estimatedItemHeight` callback is called O(N) per recompute — slow for huge lists | Low | The callback is called inside a `for` loop in `updateAccumulatedHeights`. For 10,000 items, this is a 10,000-call loop. The estimator is a few arithmetic ops, so this is ~1 ms. Cache the estimate in the parent if it's expensive. |
| The `2000` px cap on the estimator is too aggressive for some chats | Medium | Tunable: change `CAP_PX` in `chatMessageHeightEstimate.ts`. The 2,000 px value is chosen so the residual shift is < 1 screen. |
| The new `exposedKeys` field in `defineExpose` causes `scrollerState.exposedKeys` log noise | Very low | The `buildScrollerState` in `scrollLogger.ts` already lists all exposed keys; adding new ones just makes the log more verbose. No code change needed. |

---

## 8. Verification

Before declaring done:

1. **Unit tests pass** — `cd src/apps/desktop && timeout 120 bunx vitest run` reports all green, with the new `VirtualScroller.spec.ts` and `chatMessageHeightEstimate.spec.ts` test files passing.

2. **`bun run build` passes** — `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20` reports clean (per project memory, this is the type-check; `build-only` skips it).

3. **Repro the bug report scenario** — open a chat with 712 messages and a >2,000 px first message, scroll to 60% of the list, watch the `scrollLogger` panel:
   - **Pre-fix:** `content-resized` lines fire 5+ times, bottom percentage jumps 13+ points in a single event, scrollbar thumb visibly twitches.
   - **Post-fix:** `content-resized` lines fire < 1 time per second when idle, no bottom percentage jumps > 2 points, scrollbar thumb stays put.

4. **Resize the window mid-scroll** — no jump.

5. **Stream a long assistant response** — the streaming bubble grows naturally; no jump.

6. **Scroll to the top, click "Load more messages"** — scroll position preserved (existing `endPreserve` behavior), no additional jump from the new code.

7. **ChatsList still works** — open the chats list, scroll, resize — no regression.

8. **Memory check** — no leaked timers in `onUnmounted` of the chat. The new `recomputeSpacersAnchored` uses `nextTick` + `requestAnimationFrame`, both of which are bounded (nextTick is synchronous-ish; RAF is one frame).

---

## 9. Follow-up (not in this plan)

- **Drop the dynamic measurement entirely** — once `estimatedItemHeight` is reliable enough, the `itemHeights` Map and `measureItems` can be removed (the 2026-06-07 plan in its final form). The cap at 2,000 px in the estimator is a good first approximation; the long-term direction is per-item estimates that are good enough to never need re-measurement.
- **Auto-tune the cap** — make `CAP_PX` adaptive (e.g., 90th percentile of measured heights in the current chat, learned from the first few items). Removes the need for a hand-tuned constant.
- **Extend the scroll-anchor to the `endPreserve` strategy B fallback** — strategy B is already routed through `recomputeSpacersAnchored` (Task 1.7), but the DOM-based strategy A path could be simplified to use the same mechanism.

---

## 10. Rollback plan

If the fix causes regressions:

1. **Revert chunk 1** — `git revert <commit-of-chunk-1>`. This removes the `estimatedItemHeight` prop and the scroll-anchor mechanism. The fallback is `defaultItemHeight` only.

2. **Revert chunk 2** — `git revert <commit-of-chunk-2>`. This removes the `:estimated-item-height` binding from `<VirtualScroller>`. ChatView compiles cleanly (the prop is optional).

3. **Tests can stay** — the new test files are valid (the `estimatedItemHeight` prop exists, just isn't used). They become "future-tense" tests until the prop is wired up again.

The fix is structured to be safely reversible: each chunk is independent, each commit is a small, reviewable change, and the prop is additive (no breaking changes to the VirtualScroller API for existing consumers like `ChatsList`).
