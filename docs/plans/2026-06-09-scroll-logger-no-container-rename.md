# Plan: Make `handleVirtualScroll`'s container never null

> **Goal:** Eliminate the `⚠NO-CONTAINER` warn at its source. The
> container should be a *real* DOM element by the time
> `handleVirtualScroll` reads it, because it IS the element that
> fired the scroll event — we just aren't passing it through.

---

## 1. Symptom (what the user sees)

A dev-console line on an actively-rendered chat:

```
[scroll#248 chat=task_1780997145944 WARN] ⚠NO-CONTAINER 👆 ⤵ no-container top=0 bottom=0px (no-container) msgs=31 {chatId: '…', messages: 31, scrollTop: 0, scrollHeight: 0, clientHeight: 0, …}
```

The chat has 31 messages rendered. The user can see them. The
VirtualScroller **just emitted** a `scroll` event. But
`virtualScrollerRef.value?.containerRef.value` is `null`, so the
parent logs `⚠NO-CONTAINER` and skips the actual scroll handling.

This is internally contradictory: a scroll event fired, so the
DOM element that scrolled MUST exist. The container is **not** null
in the DOM — it's null in the **Vue ref chain** the parent is
walking.

---

## 2. Root cause — the ref chain is a race-prone proxy for the real element

`ChatView.vue:1005-1051`:

```ts
const handleVirtualScroll = (scrollTop: number, direction: 'up' | 'down') => {
  const container = virtualScrollerRef.value?.containerRef.value
  if (!container) { … warn('no-container') … }
  // … actual logic
}
```

This walks **two** layers of Vue refs to recover the DOM element:

1. `virtualScrollerRef.value` — the component instance
2. `.containerRef.value` — the template ref inside the component

Either layer can be `null` at the moment the handler runs, even
though the **actual DOM element** is alive and just dispatched a
scroll event. The most common races:

| When | Why the chain is null | The actual element |
|---|---|---|
| Chat switch mid-scroll | The old VirtualScroller instance is unmounting; `virtualScrollerRef.value` is the **new** instance, whose `containerRef` is null until Vue binds the template ref. | The old detached element (still in the parent's event loop). |
| Initial mount | The new VirtualScroller instance just mounted; Vue hasn't bound `containerRef` yet, but the browser already dispatched a scroll event from the freshly-attached element. | The new element, freshly inserted in the DOM. |
| After a `v-if` toggle | The parent's `v-if="isLoading \|\| messageGroups.length > 0"` briefly evaluates false during a state transition, the VirtualScroller unmounts, the browser fires a queued scroll, the new instance mounts — chain is null. | The detached old element. |

In every case the **element exists**. The ref chain just lost track
of it for a microtask.

The element itself is available right now, in the same call stack
as the scroll event, in the closure of `VirtualScroller.onScroll`:

```ts
// VirtualScroller.vue:364-385
const onScroll = (e: Event) => {
  const target = e.target as HTMLElement   // ← the real element
  …
  emit('scroll', st, dir as 'up' | 'down')  // ← but we throw it away
}
```

We're computing `target` and immediately discarding it, then asking
the parent to recover the same element through a fragile ref chain.
That's the bug.

---

## 3. The fix — pass the event target through the emit

`Event.target` is **guaranteed** by the browser to be a valid
`EventTarget` while the event is being dispatched — otherwise the
event would never have fired. For a `scroll` event from a
non-bubbling context (the VirtualScroller's root `<div>` has the
listener), `e.target` is the actual scrolling element, which is the
same element bound to `containerRef`.

Pass it through the `scroll` emit, and the parent's handler never
needs to touch the ref chain.

### 3.1 `VirtualScroller.vue` — extend the `scroll` emit signature

`src/apps/desktop/src/helpers/VirtualScroller.vue:150`

```diff
-  scroll: [scrollTop: number, direction: 'up' | 'down']
+  /**
+   * Fired on every scroll event. `target` is the actual DOM element
+   * that dispatched the event — guaranteed non-null by the browser
+   * for the lifetime of the event handler. Parents should prefer
+   * `target` over walking the component's `containerRef` ref chain:
+   * the ref chain is null during mount/remount races, but `target`
+   * is always live for the duration of the handler.
+   *
+   * The component-level `containerRef` is still exposed for the
+   * initial-load, scroll-to-bottom, and other controlled paths that
+   * don't have an event to extract the element from.
+   */
+  scroll: [scrollTop: number, direction: 'up' | 'down', target: HTMLElement]
```

`src/apps/desktop/src/helpers/VirtualScroller.vue:364-385`

```diff
 const onScroll = (e: Event) => {
   const target = e.target as HTMLElement
   containerHeight.value = target.clientHeight
   const st = target.scrollTop
   const dir = st > lastScrollTop.value ? 'down' : 'up'
   scrollTop.value = st
   lastScrollTop.value = st
-  emit('scroll', st, dir as 'up' | 'down')
+  emit('scroll', st, dir as 'up' | 'down', target)
```

That's it for the child.

### 3.2 `ChatView.vue` — use `target` as the container, ref chain as a fallback

`src/apps/desktop/src/components/ChatView.vue:1005-1006`

```diff
-const handleVirtualScroll = (scrollTop: number, direction: 'up' | 'down') => {
-  const container = virtualScrollerRef.value?.containerRef.value
-  if (!container) { … warn('no-container') … }
+const handleVirtualScroll = (
+  scrollTop: number,
+  direction: 'up' | 'down',
+  target: HTMLElement,            // ← always present, always valid
+) => {
+  // Prefer the event target — it's the element that actually fired
+  // the scroll, so the browser guarantees it exists. The ref chain
+  // is a fallback for any caller that doesn't supply a target (none
+  // today, but defensive: a future @scroll="handleVirtualScroll" on
+  // a non-VirtualScroller element shouldn't crash).
+  const container = target ?? virtualScrollerRef.value?.containerRef.value
+  if (!container) {
+    // Truly unexpected — log once and bail. With the target in
+    // hand this branch should never fire, but we keep it as a
+    // tripwire for a future regression.
+    console.warn('[scroll] handleVirtualScroll: no container (target and ref chain both null)', {
+      reportedScrollTop: scrollTop,
+      reportedDirection: direction,
+    })
+    return
+  }
```

**Effect:** the `if (!container)` branch is now effectively
unreachable. The `no-container` warn reason is dead. The 18-line
diagnostic comment at lines 1007-1034 (which enumerates the three
cases the warn used to handle) can be deleted.

### 3.3 Delete the now-impossible warn from `scrollLogger.ts`

The `ScrollReason` value `'no-container'`, the `⚠NO-CONTAINER`
marker, the `(no-container)` position label, and the `no-container`
informational block in the doc comment all exist to handle a case
that no longer happens. Remove them.

`src/apps/desktop/src/helpers/scrollLogger.ts:156`

```diff
-  // Warn-level reason: handleVirtualScroll fired but the container
-  // ref chain was null (component unmounted, inner ref not yet
-  // bound, or layout chain broke). The scrollerState/wrapperState
-  // blocks in the warn context tell you which — see the
-  // `scroller=...` / `wrapper=...` tag rendering in `emit()`.
-  | 'no-container'
```

`src/apps/desktop/src/helpers/scrollLogger.ts:480-488` (the `⚠NO-CONTAINER` branch in `emit()`)

```diff
-  if (ctx.containerInfo.null) {
-    tag += ' ⚠NO-CONTAINER'
-  } else if (ctx.scrollHeight === 0 && ctx.clientHeight === 0) {
+  if (ctx.scrollHeight === 0 && ctx.clientHeight === 0) {
```

`src/apps/desktop/src/helpers/scrollLogger.ts:494-501` (the position-label branch)

```diff
   const positionLabel =
-    ctx.containerInfo.null
-      ? 'no-container'
-      : ctx.scrollHeight === 0
-        ? 'zero-sh'
-        : ctx.scrollPercent === -1
-          ? 'short'
-          : (ctx.scrollPercent * 100).toFixed(1) + '%'
+    ctx.scrollHeight === 0
+      ? 'zero-sh'
+      : ctx.scrollPercent === -1
+        ? 'short'
+        : (ctx.scrollPercent * 100).toFixed(1) + '%'
```

The `ContainerInfo.null` field stays in the interface — `buildContainerInfo`
still produces it for the `containerInfo` block in the context, and
`buildScrollContext` still inspects it. It's just no longer used to
drive the warn.

### 3.4 Update the rest of `handleVirtualScroll` to take advantage

Now that `container` is guaranteed valid, the rest of the function
(lines 1054-1230) just works. No changes needed to the geometry
reads, the deltas, the state-transition logs, or the
`scrollToBottom` calls.

---

## 4. Why this is the right fix (and not, say, fixing the ref chain)

| Option | Pros | Cons |
|---|---|---|
| **A. Pass `target` through the emit** (this plan) | One-line emit change, one-line param add. Container guaranteed valid for the lifetime of the event. No new state, no watchers, no race-detection logic. Backwards-compatible (we add a 3rd param, not change the 1st/2nd). | Slight API surface change to the `scroll` emit. |
| B. Make `containerRef` a function that re-resolves from `document` | Self-healing. | Defeats the purpose of the Vue ref system. Hides the real bug. Adds a `getElementById`-style call on every scroll event. |
| C. Add a `nextTick` to the handler to wait for the ref | "Fixes" the race. | `handleVirtualScroll` is sync (called from `onScroll` → `emit` → handler in the same call stack). A `nextTick` would defer all the geometry reads and the loadMore logic by a frame, which **changes the observable behavior** — and breaks the "scroll-driven loadMore fires within 200ms" guarantee. |
| D. Detect the chat-switch race and downgrade to info | Makes the warn go away. | Doesn't actually fix the broken handleVirtualScroll — the geometry reads and state transitions are still skipped. The user's chat would still misbehave during the race window, just silently. |
| E. Keep the warn, just rename it to `scroller-unmounted` | Cosmetic. | Same broken handler, just better-labeled broken. The user explicitly asked to make the container NOT null, not to relabel the null. |

The user said "make container is not null". Option A is the only one
that does that, and it does it without changing any observable
behavior.

---

## 5. What stays the same (no churn)

- The other 8 call sites in `ChatView.vue` that read
  `virtualScrollerRef.value?.containerRef.value` (lines 83, 297,
  355, 710, 732, 772, 820, 858, 962). They're called from
  controlled events (`setupCodeBlockCopyButtons` watcher,
  `loadChatHistory` lifecycle, `scrollToBottom` button click, etc.)
  and the `if (!container) return` pattern they all use is
  appropriate. Only the scroll-event path is racy.
- `VirtualScroller.vue`'s `defineExpose({ containerRef, … })` at
  line 554. Still used by the controlled-path call sites.
- The `ContainerInfo`, `ScrollerState`, `WrapperState` diagnostic
  blocks in the log context. Still useful for the
  `scroller=ok(h=N)` / `wrapper=h=N` tag rendering — just the
  `null` variant of `ContainerInfo` becomes dead in practice.
- The stack-capture-on-null logic in `emit()`. Becomes dead in
  practice (no more null cases), but cheap to keep as a tripwire.
- All existing tests (no other code uses the `scroll` emit's
  exact arg list in tests — `grep` shows only the
  `VirtualScroller.vue` emit site and the `ChatView.vue` handler).

---

## 6. Regression tests

New file: `src/apps/desktop/src/helpers/__tests__/virtualScrollerScrollEmit.spec.ts`

Three tests, using `@vue/test-utils` `mount` + a stub ChatView
handler:

1. **`onScroll` passes `e.target` as the 3rd emit argument.**
   Mount the scroller, dispatch a real `Event('scroll')` on
   `wrapper.element` (the root div), assert the stub handler was
   called with `(st, dir, element)` where `element === wrapper.element`.

2. **`handleVirtualScroll` uses the 3rd argument, not the ref
   chain.** Mock the ref chain to return `null` (set
   `virtualScrollerRef.value = null`), dispatch a scroll, assert
   the handler still produced a geometry read (i.e. the loadMore
   debounce timer was scheduled, or the `scrollLogger.debug` call
   was made with non-zero `scrollHeight`). With the old ref-chain
   approach this would have hit the `if (!container)` branch and
   returned early. With the fix, it works.

3. **`VirtualScroller` unit smoke: `onScroll` still updates
   `containerHeight` and `lastScrollTop` correctly when a target
   is provided.** (Regression guard for the change to `emit`'s
   arg list — verify the rest of the function is intact.)

The existing `virtualScrollerThreshold.spec.ts` in the same
directory is the template for the mount / dispatch / assert style.

---

## 7. Verification

1. `bun run build` (strict vue-tsc — the emit type change must
   propagate to all consumers; this will catch any test or
   component that types the handler as `(st, dir) => void`).
2. `bun test` — the 3 new tests pass, all 31 existing tests stay
   green.
3. Manual: open the dev console on a chat with `>30` messages,
   scroll, then switch to a different chat in the sidebar. With
   the old code, a `[scroll#N WARN] ⚠NO-CONTAINER` line appears
   on every chat switch. With the fix, **zero** `⚠NO-CONTAINER`
   lines appear in the console — `rg "NO-CONTAINER" src/apps/desktop`
   returns nothing in the source.
4. Manual: reproduce the original 0×0-flicker scenario (open a
   fresh chat that triggers the SSE-stream layout race). The
   existing `bd9960a` fix and the new `4d5e236` fix still keep
   `containerHeight` in sync; the new fix just removes the silent
   `if (!container) return` that was masking the geometry reads
   during the race.
5. `rg "no-container" src/apps/desktop` — returns nothing
   (the dead warn reason, marker, and position label are all
   gone).

---

## 8. Out of scope

- The other 8 `virtualScrollerRef.value?.containerRef.value` reads
  in ChatView. They use the same ref-chain pattern but fire from
  controlled events where the race doesn't apply. Out of scope for
  this fix; if a future bug surfaces in one of those paths it gets
  its own plan.
- The `ScrollerState.refNull` / `containerRefNull` diagnostic
  fields. Still populated, still useful for any future "why is
  the chain null" debug. Untouched.
- The `loadMoreSuppressed` / `not-scrollable` / `no-more-items`
  guard logic in `VirtualScroller.onScroll`. Unrelated.

---

## 9. Roll-out

Single PR, two files changed + one new test file:

| File | Lines changed (approx) |
|---|---|
| `src/apps/desktop/src/helpers/VirtualScroller.vue` | ~10 (emit type + 1-line emit call + 1-line JSDoc) |
| `src/apps/desktop/src/components/ChatView.vue` | ~20 (handler param + container fallback + delete 18-line comment) |
| `src/apps/desktop/src/helpers/scrollLogger.ts` | ~10 (remove 3 dead code paths) |
| `src/apps/desktop/src/helpers/__tests__/virtualScrollerScrollEmit.spec.ts` | new, ~80 lines |

No backend changes. No migration. No new deps. Strict vue-tsc
catches any caller that uses the old `(st, dir) => void` shape.
