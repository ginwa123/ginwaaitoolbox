# Plan: Fix scroll ratcheting (59% ↔ 57% oscillation) in `ChatView`

> **Goal:** Stop the `scrollTop`/`scrollHeight` lockstep oscillation that
> bounces the scroll position between two stable states (e.g., 59% ↔ 57%)
> when the user is reading history or after a window resize. The position
> should stay still while the user is not actively scrolling.

---

## 1. Symptom (what the user sees)

With a long, fully-loaded chat (~270 messages), the user scrolls up to
read history and stops. While the chat sits at rest, the scroll position
**bounces between two values** — e.g. 59.0% and 57.7% in the user's log —
roughly every few hundred ms. The content itself doesn't visibly move
much (the user is reading one bubble), but the position indicator and
`scrollHeight` oscillate.

A window resize triggers the same bouncing during/after the resize
debounce settles.

The user provided the following excerpt from `scrollLogger`:

```
[scroll#2195 ... INFO] 👆 ↑ direction-change top=24740 bottom=17227px (59.0%) msgs=269
[scroll#2196 ... INFO] 👆 ↑ content-resized  top=24740 bottom=17227px (59.0%) msgs=269
[scroll#2197 ... INFO] 👆 ↑ direction-change top=23475 bottom=17227px (57.7%) msgs=269
[scroll#2198 ... INFO] 👆 ↑ direction-change top=24740 bottom=17227px (59.0%) msgs=269
[scroll#2199 ... DEBUG] 👆 ↑ scroll-sample   top=24740 bottom=17227px (59.0%) msgs=269
[scroll#2200 ... INFO] 👆 ↑ direction-change top=23475 bottom=17227px (57.7%) msgs=269
[scroll#2201 ... INFO] 👆 ↑ direction-change top=24740 bottom=17227px (59.0%) msgs=269
```

Two values for `scrollTop` (24740 and 23475), two for `scrollHeight`
(42729 and 41464), but `distanceFromBottom` is **constant at 17227 px**
and `messages.length` is constant at 269.

### The signature is diagnostic

| field              | state A      | state B      | delta  |
| ------------------ | ------------ | ------------ | ------ |
| `scrollTop`        | 24740        | 23475        | **−1265** |
| `scrollHeight`     | 42729        | 41464        | **−1265** |
| `clientHeight`     | 762          | 762          | 0      |
| `distanceFromBottom` | 17227      | 17227        | 0      |
| `messages.length`  | 269          | 269          | 0      |

Both `scrollTop` and `scrollHeight` change by the **exact same amount**
(1265 px ≈ 6.3 items at `defaultItemHeight = 200`), and the
`distanceFromBottom` (= `scrollHeight - scrollTop - clientHeight`) is
**preserved**. This is the textbook signature of the browser's
**CSS scroll-anchoring** behavior (see §2): when the content above the
viewport changes height, the browser adjusts `scrollTop` by the same
delta so the visible content stays put.

If the user is not actively scrolling, the only way `scrollTop` can
change is via this browser-side anchoring adjustment. (The browser
fires a `scroll` event for the adjustment, which is why every line
reads `👆` — `markProgrammatic` was never called, so the logger has no
way to distinguish "browser anchored" from "user wheeled".)

---

## 2. Root cause

### 2.1 `VirtualScroller` re-measures items in the buffer, and the spacers follow

`src/apps/desktop/src/helpers/VirtualScroller.vue:399-415`

```ts
const measureItems = () => {
  if (!containerRef.value) return
  const content = containerRef.value.querySelector('.virtual-scroller-content')
  if (!content) return
  let changed = false
  const children = content.children
  for (let i = 0; i < children.length; i++) {
    const el = children[i] as HTMLElement
    const realIndex = visibleRange.value.start + i
    const h = el.offsetHeight
    if (h > 0 && itemHeights.value.get(realIndex) !== h) {
      itemHeights.value.set(realIndex, h)   // ← can update an item we already measured
      changed = true
    }
  }
  if (changed) updateAccumulatedHeights()
}
```

`measureItems` is called (50 ms debounce) on every:

- `onScroll` (line 493-494)
- `ResizeObserver` callback (line 587-589)
- Initial mount (line 592)
- Items-length change (via the `itemHeights` deep-watch, lines 302-310)

It walks **every currently-rendered child** and writes the new
`offsetHeight` to the `itemHeights` Map. The check
`itemHeights.value.get(realIndex) !== h` skips the write **only when
the height is identical to the last measurement** — a 1 px rounding
fluctuation or a fresh Vue mount with a slightly different layout will
write a new value and trigger `updateAccumulatedHeights()`.

`updateAccumulatedHeights()` recomputes the array (line 272-280). The
`topSpacer` derived in `visibleRange` (line 346) shrinks or grows by
the accumulated delta. The browser observes the spacer style mutation
and applies scroll-anchoring: it adjusts `scrollTop` by the same
delta to keep the topmost visible element in view.

### 2.2 The browser's scroll-anchoring is enabled by default

`src/apps/desktop/src/helpers/VirtualScroller.vue:632-654`

```css
.virtual-scroller {
  overflow-y: auto;
  flex: 1 1 0;
  min-height: 0;
  min-height: 100px;
}
```

`overflow-anchor` is **not** declared, so it defaults to `auto`
(CSS Scroll Anchoring Module Level 1, §3.1). The browser is supposed
to keep the visible content stable when the content above changes
height — and it does. That's exactly what produces the
`scrollTop -= spacerDelta` half of the bounce.

The result: **every spacer mutation is a 1-frame bounce**.

### 2.3 The 1265 px magnitude is "a few items in the buffer"

The buffer is 20 items per side (`:buffer="20"` on `<VirtualScroller>`).
When the user scrolls, the buffer zone rolls: items at the top of the
buffer get unmounted, new items at the top get mounted. The
`measureItems` pass measures these newly-mounted items. If 6 of them
have a real height that differs from the previous `defaultItemHeight =
200` estimate (e.g. a long user message that lays out at ~300 px, or a
tool result that lays out at ~80 px), the spacer deltas sum to 1265.

This is consistent with the data: 1265 / 200 ≈ 6.3 items, well within
the 20-item buffer.

### 2.4 The `direction-change` log is the browser's scroll event

When the browser adjusts `scrollTop` to apply scroll-anchoring, it
fires a `scroll` event. Our `onScroll` reads the new `scrollTop` and
computes `dir = st > lastScrollTop ? 'down' : 'up'`. If the
adjustment happens to invert the previous direction (or even
oscillates by 0 — handled as 'up' by the ternary's else branch), the
parent's `handleVirtualScroll` logs `direction-change`. That's why the
log shows `direction-change` on almost every line.

The `content-resized` lines are the spacer mutation that *caused* the
anchoring. The `scroll-sample` line is a normal in-between scroll
event (probably the user moving the mouse wheel a tiny amount, or a
debounced scroll event from a previous gesture).

### 2.5 This is a *follow-on* of the same bug in the existing 2026-06-07 plan

`docs/plans/2026-06-07-virtual-scroller-fixed-height.md` is a more
aggressive fix: drop the `itemHeights` Map and use a single fixed
`itemHeight` for every item. That eliminates the measurement cycle
entirely, so the spacers never change, so the browser never
re-anchors, so the user never sees the bounce.

That plan has a real cost: bubbles taller than `itemHeight` (likely
all long assistant responses, which routinely run 600-1200 px) will
overflow their slot. The plan acknowledges this and proposes a
follow-up with per-item heights.

This plan is a **smaller, more targeted fix** that preserves the
dynamic measurement model but **stops the spacers from oscillating
in the first place**. It does not clip long bubbles. The trade-off is
that the spacers are slightly less accurate in the (rare) case where
real heights differ from the estimates by a lot — but they were
already inaccurate (and oscillating) before.

---

## 3. Design

### 3.1 Hysteresis on item measurements

The fix lives in `measureItems`. Today it writes a new height whenever
`h !== stored`. We add a **dead-band**: only update the stored height
when the new value differs from the stored value by more than
`hysteresisPx` (default 4 px) — small enough to ignore layout
flicker, large enough to admit real changes (font swap, image load,
streaming content).

```ts
const HYSTERESIS_PX = 4

const measureItems = () => {
  if (!containerRef.value) return
  const content = containerRef.value.querySelector('.virtual-scroller-content')
  if (!content) return
  let changed = false
  const children = content.children
  for (let i = 0; i < children.length; i++) {
    const el = children[i] as HTMLElement
    const realIndex = visibleRange.value.start + i
    const h = el.offsetHeight
    if (h > 0) {
      const prev = itemHeights.value.get(realIndex)
      // Hysteresis: skip the write unless the change is significant.
      // Without this, 1-2 px fluctuations in the same item (e.g. font
      // swap, sub-pixel rounding, container re-layout) cycle through
      // updateAccumulatedHeights → spacer mutation → browser
      // scroll-anchoring → scrollTop ratchet. With it, the spacers
      // only update on real changes (image load, content expansion,
      // window resize beyond the dead-band).
      if (prev === undefined || Math.abs(h - prev) > HYSTERESIS_PX) {
        itemHeights.value.set(realIndex, h)
        changed = true
      }
    }
  }
  if (changed) updateAccumulatedHeights()
}
```

Why 4 px? Smaller (1-2 px) is the rounding noise floor — Chromium
rounds sub-pixel offsets. Larger (>8 px) starts to miss real content
shifts (e.g. an image at 32 px becoming 256 px after layout). 4 px
absorbs the noise and admits the signal.

### 3.2 Disable scroll anchoring as a defense-in-depth

Even with hysteresis, real content changes (image loads, streaming
text, container resize) still cause spacer mutations and the browser
will still try to anchor. The visible bounce reappears in those cases
(more rarely than today). To prevent the bounce entirely, disable
scroll anchoring on the scroller — the user is in control of the
scroll position, the browser should not silently move it.

```css
.virtual-scroller {
  overflow-y: auto;
  /* Disable CSS scroll anchoring. When the spacers above the viewport
     resize (because the buffer items get re-measured), the browser
     would otherwise adjust scrollTop by the spacer delta to keep the
     visible content stable. That adjustment is the "ratchet" — the
     scroll position bouncing 1-2 px per spacer mutation. Disabling
     anchoring means spacers can resize freely; the user's scrollTop
     is preserved, and the only visible effect is the bottom edge
     moving by the spacer delta (which the user can choose to
     re-anchor by scrolling a hair). */
  overflow-anchor: none;
  flex: 1 1 0;
  min-height: 0;
  min-height: 100px;
}
```

This is a one-line CSS change. Combined with hysteresis, the bounce
is eliminated in all but the most extreme cases (a brand-new image
loading, or a long stream chunk landing).

### 3.3 What this plan does *not* change

- `itemHeights` Map stays — bubbles can still be dynamic-height.
- `measureItems` stays — the system still learns real heights.
- `accumulatedHeights` stays reactive — the spacers still track reality.
- `endPreserve` strategy A/B is untouched.
- `updateAccumulatedHeights` is untouched.
- The existing 2026-06-07 plan is **not** invalidated — it's still the
  right long-term direction. This plan is the small fix that gets the
  bounce under control without committing to fixed `itemHeight`.

---

## 4. Implementation steps

1. **`VirtualScroller.vue` — add hysteresis to `measureItems`** (5 min)
   - Add the `HYSTERESIS_PX` constant above the function.
   - Replace the `prev !== h` check with the `prev === undefined || Math.abs(h - prev) > HYSTERESIS_PX` check.
   - Add a comment explaining the ratchet (link to this plan).

2. **`VirtualScroller.vue` — disable scroll anchoring** (1 min)
   - Add `overflow-anchor: none;` to the `.virtual-scroller` rule.

3. **No-op change verification (5 min)**
   - `bun run build` in `src/apps/desktop` — must pass. (Per project
     memory: `bun run build` is the type-check; `bun run build-only`
     skips `vue-tsc` and is not authoritative.)

4. **Manual test in browser (15 min)**
   - Open a long chat (>200 messages).
   - Scroll to the middle of the chat, stop scrolling.
   - Watch the scrollLogger for 5 seconds — should see at most 1-2
     `content-resized` lines and **zero** `direction-change` lines
     while the user is not actively scrolling.
   - Resize the window — same expectation: no `direction-change` for
     the new geometry.
   - Stream a long assistant response — no bouncing during the stream.

5. **Add a unit test for the hysteresis** (30 min, optional but
   recommended)
   - File: `src/apps/desktop/src/__tests__/helpers/VirtualScroller.spec.ts`
   - Test: stub a container with N children, each with a settable
     `offsetHeight`. Call `measureItems` once with heights `[100, 200, 100]`,
     then again with `[101, 200, 105]`. Assert: `itemHeights` is
     unchanged (deltas < 4 px). Call a third time with `[110, 200, 105]`
     (index 0 changed by 10). Assert: `itemHeights[0]` is now 110,
     index 2 unchanged (delta 4, not strictly greater).
   - Register in any test-runner config that needs it (check
     `vitest.config.ts` / `package.json` test glob).
   - Note: this is a non-trivial test because `VirtualScroller` is a
     Vue SFC. Two options: (a) extract `measureItems` into a pure
     function in a `.ts` file and test it; (b) mount the SFC in jsdom
     and stub the DOM. Option (a) is cleaner. The refactor is one
     `function measureItems(container, start, itemHeights, hysteresis)`
     extract. Do it as part of this step.

6. **`bun run build` final pass** — must be clean.

---

## 5. Files touched

- `src/apps/desktop/src/helpers/VirtualScroller.vue` — hysteresis
  constant, two-line check change, one CSS line.
- `src/apps/desktop/src/__tests__/helpers/VirtualScroller.spec.ts` —
  new test file (optional but recommended).
- (No other files; `ChatView.vue` and `ChatsList.vue` are unchanged.)

---

## 6. Risks and mitigations

| Risk | Likelihood | Mitigation |
| --- | --- | --- |
| Hysteresis is too large — real image loads don't propagate | Low | 4 px is small enough to admit any real layout change. Worst case: a 1-3 px undercount. The spacer is approximate anyway. |
| Hysteresis is too small — bounce persists in some scenarios | Low | If 4 px is not enough, raise to 8 px. The test in step 5 is parameterized so we can A/B the threshold. |
| `overflow-anchor: none` introduces a new glitch (user scrolls, spacers change, user's reference frame shifts by the spacer delta) | Medium | The user is in control of the scroll wheel; if a spacer delta moves the bottom edge visibly, the user just scrolls a hair to compensate. Today's behavior is the opposite — the chat auto-jumps. The new behavior is a strict improvement. |
| `measureItems` becomes slow because we re-measure every item on every scroll | Low | The Map is local; the deep watch is debounced 50 ms. No new loops or work. The hysteresis check is one extra `Math.abs` per item. |
| Real content shift (streaming assistant message) is masked by hysteresis for one cycle | Low | Streaming content changes by much more than 4 px per chunk — typically 50-200 px. The dead-band is well below that. |

---

## 7. Verification

Before declaring done:

1. `bun run build` in `src/apps/desktop` passes.
2. Reproduce the user's setup: open a chat with >200 messages, scroll
   to the middle, stop. The scrollLogger should show **no
   `direction-change` lines** while the user is at rest for 5+
   seconds. Pre-fix: 5+ `direction-change` lines per second.
3. Resize the window mid-scroll — no bounce.
4. Stream a long assistant response — no bounce during the stream.
5. Scroll to the top, trigger `loadMore` — scroll position is
   preserved (existing `endPreserve` behavior, untouched by this
   plan), no bounce during the prepend.
6. The new `VirtualScroller.spec.ts` test passes (if step 5 of
   implementation was done).

---

## 8. Follow-up (not in this plan)

- **Long-term: switch to fixed `itemHeight` per the 2026-06-07 plan.**
  This is the right structural fix; the hysteresis + `overflow-anchor:
  none` combo is the surgical fix. If a future task needs the
  fixed-height version (e.g. for a ChatsList that needs pixel-perfect
  row alignment), port the 2026-06-07 plan.
- **Per-item estimated height callback** (2026-06-07 §8 follow-up) —
  lets the caller pass `(item) => height` so tall assistant bubbles
  reserve their space upfront. No measurement needed at all. Best
  long-term solution but a bigger refactor.
- **Investigate why `ChatsList` still has bouncing on window resize.**
  The same fix applies, but the ChatsList test (resize 64→48 px card)
  may behave differently. Verify after merging this plan.

---

## 9. Quick diagnosis script

To confirm the scroll-anchoring hypothesis on the live page, paste
this into the browser devtools console while the chat is at rest:

```js
const el = document.querySelector('.virtual-scroller')
const log = () => console.log({
  scrollTop: el.scrollTop,
  scrollHeight: el.scrollHeight,
  clientHeight: el.clientHeight,
  distanceFromBottom: el.scrollHeight - el.scrollTop - el.clientHeight,
  overflowAnchor: getComputedStyle(el).overflowAnchor,
})
log()
const ro = new ResizeObserver(() => log())
ro.observe(el)
new MutationObserver(() => log()).observe(el, {
  attributes: true, attributeFilter: ['style'], subtree: true,
})
// Resize the window — watch the values bounce
```

You should see:
- `overflowAnchor: 'auto'` (confirming scroll-anchoring is on)
- A 1:1 lockstep between `scrollTop` and `scrollHeight` deltas (confirming the ratchet)
- `distanceFromBottom` constant (confirming the user-visible position is preserved)

After the fix, `overflowAnchor` should be `'none'` and the lockstep
should disappear (the values stay still unless the user scrolls).
