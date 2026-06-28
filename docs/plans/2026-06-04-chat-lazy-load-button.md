# Plan: Restore "Load more messages" button for non-scrollable chats

> **Goal:** Let the user load older messages when the message list fits in
> the viewport (so the VirtualScroller never reaches its
> `loadMoreThreshold` and the `loadMore` event is suppressed by the
> `not-scrollable` guard).

---

## 1. Symptom (what the user sees)

In a chat where the currently-loaded messages **fit entirely in the
viewport** — the screenshot shows many short tool/result bubbles, all
visible at once — the user cannot paginate to older messages:

- There is no visible "Load more" button at the top of the messages area.
- Scrolling to the top of the messages area does **not** fire the
  `loadMore` event, because the container is not scrollable
  (`scrollHeight ≤ clientHeight`).
- The user can scroll, see the older messages they have, and send new
  messages — but they cannot see anything that was generated *before*
  the most recent page returned by the API.

The chat stays in this "stuck at the most recent page" state until the
user resizes the window (which can cause the bubble heights to change
enough that the container becomes scrollable), opens a different chat
(which may force a re-render), or reloads the page.

---

## 2. Current state (what is broken)

### 2.1 The VirtualScroller is the *only* trigger for `loadMore`

`src/apps/desktop/src/components/ChatView.vue:1433-1445`

```vue
<VirtualScroller
  v-else
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
>
```

`handleLoadMore` (lines 826-919) is only ever invoked from this
`@load-more` event. The click event is the *only* way the user can
trigger pagination. There is no other UI affordance.

### 2.2 The VirtualScroller suppresses `loadMore` when the container is not scrollable

`src/apps/desktop/src/helpers/VirtualScroller.vue:239-294`

```ts
const onScroll = (e: Event) => {
  const target = e.target as HTMLElement
  const st = target.scrollTop
  // ...
  loadMoreDebounce = setTimeout(() => {
    if (isPreservingScroll.value) return
    const hasMore = props.totalCount === 0 || props.items.length < props.totalCount
    if (!hasMore) {
      emit('loadMoreSuppressed', 'no-more-items')
      return
    }
    // Defensive guard: if the container isn't actually scrollable
    // (scrollHeight ≤ clientHeight, i.e. content fits in viewport),
    // `st < loadMoreThreshold` is trivially true because `st` is 0
    // and there's nothing to scroll. Emitting `loadMore` here would
    // cause the parent to fetch a page and prepend it, which is the
    // exact "flicker" users see when a chat's container reads as
    // 0×0 during an SSE stream. The check uses the container's
    // own dimensions — no parent layout assumptions.
    const isScrollable = target.scrollHeight > target.clientHeight
    if (!isScrollable) {
      emit('loadMoreSuppressed', 'not-scrollable')
      return
    }
    // ...
  }, 200)
}
```

When all messages fit in the viewport, the scroll event never fires
either — the container has no scrollbar, so the user *cannot* generate
the scroll event in the first place. The `not-scrollable` guard is
defensive (in case a parent somehow triggers a scroll event on a
non-scrollable container), but the *real* problem is that the
**trigger is missing entirely**.

### 2.3 A "Load more messages" button used to exist

A button matching this exact UX once existed. `git log -S "Load more
messages"` finds it in:

- `ebaa529 implment lazy scrol and virtualizer` — initial implementation
- `377898c virtual scroll` — *removed* when VirtualScroller was introduced

The diff for `377898c` shows the deletion:

```diff
-        <!-- Message List -->
-        <div v-else class="max-w-4xl mx-auto px-4 py-6 space-y-4">
-          <!-- Load More Button -->
-          <div v-if="hasMoreMessages" class="flex justify-center pb-2">
-            <button
-              @click="loadChatHistory(true)"
-              :disabled="isLoadingMore"
-              class="flex items-center gap-2 px-4 py-2 rounded-full text-sm transition-all duration-200 hover:scale-105"
-              :class="isLoadingMore ? 'opacity-50 cursor-not-allowed' : ''"
-              style="
-                background-color: var(--semantic-card-bg);
-                border: 1px solid var(--color-border);
-                color: var(--semantic-text);
-              "
-            >
-              <div
-                v-if="isLoadingMore"
-                class="w-4 h-4 border-2 rounded-full animate-spin"
-                style="border-color: var(--color-violet); border-top-color: transparent"
-              ></div>
-              <span v-else>↑</span>
-              <span>{{ isLoadingMore ? 'Loading...' : 'Load more messages' }}</span>
-            </button>
-          </div>
```

It was a sibling of the message list, rendered before any messages.
When the VirtualScroller replaced the plain scroll container, this
button was not re-introduced — the assumption was that the
VirtualScroller's scroll-to-top `loadMore` would be a sufficient
trigger. That assumption fails for the common case of short messages
that all fit in the viewport.

### 2.4 NALAR.md already documents the intended behavior

From the global memory notes:

> [ChatView.vue] Added "Load more messages" button at top for when
> message list doesn't overflow (overscroll not visible). Also fixed
> scroll position preservation when prepending messages during
> loadMore.

The intent was right; the implementation was lost in the
`377898c` refactor.

---

## 3. Root cause

The VirtualScroller-based `loadMore` path is **the only** path that
triggers pagination. That path requires the user to scroll within
`loadMoreThreshold` (200 px) of the top of the **scrollable** area.
When the loaded messages fit in the viewport:

1. The container has no scrollbar.
2. The user can produce no scroll events.
3. The VirtualScroller's `loadMore` event is never emitted.
4. `handleLoadMore` is never called.
5. Older messages are unreachable.

The "Load more messages" button that bridged this gap was removed in
`377898c` and never re-added.

---

## 4. Proposed fix

**Re-introduce a "Load more messages" button at the top of the
messages area** that calls `loadChatHistory(true)` directly, bypassing
the VirtualScroller's `loadMore` event. This restores the pre-refactor
UX and is the **minimum change** that solves the bug.

The button is **gated on the container NOT being scrollable** — i.e.
it only shows when the user has no other way to reach older messages.
When the container IS scrollable, the user can scroll to the top and
the VirtualScroller's `@load-more` event fires as designed; the button
would be UI clutter. This is a deliberate UX choice: the button is the
*escape hatch* for the specific case the VirtualScroller can't handle,
not a permanent "Load older" affordance.

### 4.1 Button placement

A sibling of `<VirtualScroller>`, rendered as the first child of the
`messagesWrapperRef` wrapper. The button is:

- **Above** the VirtualScroller (not inside it, so it isn't subject
  to the VirtualScroller's virtualization or `loadMore` event flow).
- **Visible** when `hasMoreMessages && !isLoadingMore &&
  messageGroups.length > 0 && !scrollerIsScrollable` — the last
  clause is the new one; it gates the button on the container
  having no scrollbar.
- **Replaced** by the existing floating "Loading more..." indicator
  during an in-flight pagination, so we don't show two spinners.

The wrapper is `position: relative` and a `flex flex-col` layout;
the button is the first child so it sits above the scroller and is
not subject to virtualization or the `beginPreserve`/`endPreserve`
scroll-restoration dance.

### 4.2 Button style

Mirror the pre-refactor design (round pill, subtle border, same color
tokens):

```vue
<div
  v-if="
    hasMoreMessages &&
    !isLoadingMore &&
    messageGroups.length > 0 &&
    !scrollerIsScrollable
  "
  class="flex justify-center pt-2 pb-1"
  data-testid="load-more-messages"
>
  <button
    @click="loadChatHistory(true)"
    class="flex items-center gap-2 px-4 py-1.5 rounded-full text-xs
           transition-all duration-200 hover:scale-105"
    style="background-color: var(--semantic-card-bg);
           border: 1px solid var(--color-border);
           color: var(--semantic-text);"
    :title="`Load ${PAGE_SIZE} older messages`"
  >
    <span>↑</span>
    <span>Load more messages</span>
  </button>
</div>
```

### 4.3 Tracking `scrollerIsScrollable` in the VirtualScroller

The new `!scrollerIsScrollable` clause needs a reactive value. We
expose `isScrollable: ComputedRef<boolean>` from the VirtualScroller,
derived from:

```ts
const isScrollable = computed(() => {
  const totalContentHeight = accumulatedHeights.value[props.items.length] ?? 0
  return totalContentHeight > containerHeight.value
})
```

This is **fully reactive** to both sides of the comparison:
`accumulatedHeights` changes when items are measured, added, or
removed (the source of truth for content size — it sums measured
heights and falls back to `defaultItemHeight` for unmeasured ones);
`containerHeight` changes via the existing `ResizeObserver`.

**The first implementation used a `ref<boolean>` populated by reading
`containerRef.value.scrollHeight` from a `ResizeObserver` callback
and a 100ms mount-time setTimeout.** That was wrong: `ResizeObserver`
only fires when the **observed element itself** resizes — not when
its content inside grows. During normal use (streaming, pagination,
first item measurement), the container's outer size doesn't change
but the content does, so the observer never fires, the ref stays
stuck at its initial-mount value (usually `false` from the 0×0
flicker), and the parent never sees the chat become scrollable.
The button would keep showing in long chats where the user could
have used the scroll path. The reactive `computed` fixes this
without needing any triggers at all.

**Second gotcha caught at user-testing time: the existing
`watch(() => props.items.length, updateAccumulatedHeights)` did NOT
have `{ immediate: true }`.** Without it, the watcher only fires on
*changes* to `items.length` — but on initial mount the items are
already present (the parent loads them before rendering this child),
so the length never "changes" during the watcher's lifetime.
`accumulatedHeights` stayed at its initial value `[0]`, the computed
read `accumulatedHeights[items.length]` which was `undefined`, the
`?? 0` fallback made it `0`, and `0 > containerHeight` was `false`.
Button STILL showed in scrollable chats. Fix: add `{ immediate: true }`
to the watcher so it runs synchronously during setup, populating
`accumulatedHeights` with default-height estimates (200px each)
before the first render. After ~150ms (the mount setTimeout + the
`itemHeights` deep-watch debounce), the real measurements replace
the estimates. Always pass `immediate: true` when the watcher's
effect needs to run on first render.

**Third gotcha caught at user-testing time: the parent's
`scrollerIsScrollable` was a `computed` reading
`virtualScrollerRef.value.isScrollable.value`.** This chain
`ref.value.ref.value` does NOT reliably establish reactive
dependencies in Vue 3: the component instance proxy returned by a
template ref is not a deep-reactive object, so property access on
it (`.isScrollable`) is not tracked, and the inner `.value` is on
a ref object that the parent may have lost its identity for
depending on proxying semantics. The computed could run once with
the initial value and never re-evaluate, leaving the parent stuck
on a stale `false` even when the chat became scrollable. Fix:
switch to an event-based pattern. The VirtualScroller emits
`scrollability-change` (with `immediate: true` on the watch so
the initial value is sent on mount) whenever `isScrollable`
changes. The parent maintains a plain `ref<boolean>` updated by
`@scrollability-change="scrollerIsScrollable = $event"`, which
the template can react to via standard Vue reactivity. Events
have a single, well-defined reactive contract — no proxy-chain
dependency tracking involved.

### 4.3 Why not also auto-load when the container is not scrollable?

We could silently auto-fire `loadChatHistory(true)` on initial mount
when the container is not scrollable and `hasMoreMessages` is true.
**We will not do this** in this change because:

- The user might be intentionally at the top of a short chat
  (e.g. they just opened it for the first time). Auto-loading
  silently is surprising.
- The "Load more" button gives the user **control** over how much
  history is loaded — useful for power users who want to keep a chat
  short.
- The previous UX (button click) was deliberate. Restore it as-is.

If users later want auto-load for short chats, that's a separate UX
change with its own design discussion.

### 4.4 Why not change the VirtualScroller's `not-scrollable` guard?

We could relax the guard to emit `loadMore` on a non-scrollable
container. We **will not** in this change because:

- The guard is the defense against the 0×0-container-during-SSE bug
  fixed in commit `bd9960a`. Removing it risks re-introducing that
  flicker.
- The right place to *trigger* loadMore from outside the scroll is in
  the parent (ChatView), not in the VirtualScroller. The
  VirtualScroller is a scroll-driven component; the button is a
  click-driven component. They should be orthogonal.

---

## 5. Implementation steps

### Step 1: Expose `isScrollable` from the VirtualScroller

**File:** `src/apps/desktop/src/helpers/VirtualScroller.vue`

- Add `isScrollable: Ref<boolean>` initialized to `false`.
- Add a `updateIsScrollable()` helper that reads
  `containerRef.value.scrollHeight > containerRef.value.clientHeight`.
- Call it in the existing `ResizeObserver` callback (so it fires on
  container/window resize), at the end of `measureItems` when
  measurements changed, and in the initial `onMounted` setTimeout.
- Add `isScrollable` to the `defineExpose({...})` block so the
  parent component can read it.

### Step 2: Add the button in the ChatView template

**File:** `src/apps/desktop/src/components/ChatView.vue`

- Extend the `VirtualScrollerExposed` interface to declare
  `isScrollable: { value: boolean }` (TS contract).
- Add a `scrollerIsScrollable` computed in the `<script setup>`
  block: `computed(() => virtualScrollerRef.value?.isScrollable?.value ?? false)`.
  This is reactive to the underlying ref through Vue's nested-ref
  tracking, and the `?? false` default handles the initial-render
  case where `virtualScrollerRef.value` is `null`.
- Insert the "↑ Load more messages" pill **before** the
  `<VirtualScroller>` inside the `messagesWrapperRef` wrapper, as
  a sibling of the empty-state div and the existing
  "Loading more..." indicator.
- v-if: `hasMoreMessages && !isLoadingMore && messageGroups.length
  > 0 && !scrollerIsScrollable`. The four `v-if`s (empty state,
  button, scroller) are **all independent** — see §5.4 for why
  `v-else`/`v-else-if` chains break this case.

### Step 3: No change to the VirtualScroller's `not-scrollable` guard

The `not-scrollable` guard on the scroll-driven `loadMore` event
stays. The `@load-more-suppressed` log channel stays (still useful
for diagnosing the "scrolled to top while not scrollable" case).
The `handleLoadMoreSuppressed` handler stays.

### Step 4: No backend change

The backend already returns `has_more`, `next_cursor`, and supports
`limit` + `cursor` query params (see
`src/ai_workflow/tui/http_handlers/session_message.zig:16-20`). The
default `limit` is 100. `PAGE_SIZE` in `ChatView.vue` is 10. No
backend change is required.

### 5.4 Gotcha: do NOT use `v-else`/`v-else-if` between the three blocks

Vue's `v-if`/`v-else`/`v-else-if` chain attaches to the most recent
`v-if` in consecutive siblings. If the new button is placed between
the empty-state `v-if` and the VirtualScroller `v-else-if`, the
chain becomes:

```
empty state (v-if=A) → button (v-if=B) → scroller (v-else-if=C, chains to B!)
```

When the button is visible (B=true), the VirtualScroller would be
hidden because `v-else-if` is not taken — a critical regression
that hides the message list. Fix: make all three blocks independent
`v-if`s. The chain is dropped on purpose.

### Step 4: Verification

#### 4.1 Manual smoke test (the original bug)

1. Open a chat with **more than 10 messages** in the DB but whose
   most recent 10 messages fit in the viewport (the screenshot's
   scenario).
2. **Before the fix:** the messages fit in the viewport, no
   "Load more" button, no way to load older messages.
3. **After the fix:** the "↑ Load more messages" button is visible
   at the top of the messages area. Clicking it prepends the next
   page of older messages and preserves the user's scroll position
   (verified by the existing `loadChatHistory(true)` flow with
   `beginPreserve`/`endPreserve`).

#### 4.2 Regression tests

Add a unit test in the ChatView test suite (if one exists; if not,
add to `src/apps/desktop/src/__tests__/`) that:

- Mocks `api.getChatHistory` to return `{ has_more: true,
  next_cursor: 'abc', messages: [...10 messages] }`.
- Mounts `<ChatView chat-id="..." />`.
- Asserts the "Load more messages" button is present in the DOM.
- Clicks the button.
- Asserts `api.getChatHistory` is called a second time with
  `cursor: 'abc'`.

#### 4.3 End-to-end manual regression

For a long-running chat (the one the user is showing in the
screenshot):

1. Open the chat. The "Load more messages" button appears at the top.
2. Click it once. Older messages prepend. Scroll position is
   preserved.
3. Click it again. More older messages prepend.
4. Click it until `has_more: false`. The button disappears.
5. Resize the window to make the chat longer than the viewport.
   The user can now scroll to the top and the VirtualScroller's
   `@load-more` will fire as well (the button stays hidden because
   `hasMoreMessages` is false, but the scroll path is also exercised).

#### 4.4 Stream interaction test

While an LLM is streaming a new response (so the auto-stick is
active), the user should be able to click the "Load more" button
**or** scroll to the top to load older messages. The auto-stick
guard (`isAutoStickActive`) should still suppress the scroll-driven
`loadMore` during active streaming, but the button click should
work because the click is not in the scroll path. Verify this by:

1. Start a long-running LLM task that produces multiple chunks.
2. While chunks are streaming, click the "Load more" button at
   the top. Older messages should prepend.
3. After the stream ends, verify scroll position is still
   consistent (the auto-stick gate lifts after
   `AUTO_STICK_GATE_MS`).

---

## 6. Risks & mitigations

| Risk | Mitigation |
|------|------------|
| The button interferes with the existing "Loading more..." indicator (line 1397). | The button is hidden when `isLoadingMore` is true (via the `v-if`). The indicator is the only thing shown during in-flight pagination. |
| The button is visible at the top while the user is at the bottom of a long chat, looking noisy. | Acceptable: the button is small (text-xs, subtle border), and it's the user's escape hatch when scroll-driven load is not possible. The "scroll to bottom" button is at the bottom; the "load more" button is at the top. Symmetric. |
| `beginPreserve`/`endPreserve` doesn't work for a button click on a non-scrollable container. | `beginPreserve` only needs the anchor element's `offsetTop`, which is valid for any rendered element. When the container is not scrollable, the VirtualScroller mounts all items (not just the visible window), so the anchor at index 0 is in the DOM. `endPreserve` will find it at the new index `n` and adjust `scrollTop` accordingly. This is the same code path used by the scroll-driven `loadMore`. |
| The click fires a loadMore that the user didn't intend (mis-click). | The page is small (10 messages) and the network call is fast. Worst case the user cancels by clicking the "scroll to bottom" button or just ignores the older messages. Not a serious issue. |
| Auto-stick fights the prepend during streaming. | The auto-stick guard (`isAutoStickActive`) only suppresses the *scroll-driven* `loadMore` path, not the button click path. The user is explicitly opting in to a load. The prepend's `beginPreserve`/`endPreserve` correctly preserves the user's scroll position, so even if the auto-stick fires mid-prepend, the user's view doesn't jump. (This is the same correctness property the scroll-driven path has.) |

---

## 7. Out of scope

These are **not** part of this change:

- Changing the VirtualScroller's `not-scrollable` guard.
- Changing `PAGE_SIZE`.
- Auto-loading older messages on initial mount when the container
  is not scrollable.
- Adding a "jump to oldest" button or a date-picker for navigation.
- Refactoring the grouped-message rendering (the `messageGroups`
  computed property at line 530 is unrelated to this bug).
- Changing the `next_cursor`/`has_more` API contract.

---

## 8. Acceptance checklist

- [ ] The "↑ Load more messages" button is visible at the top of
      the messages area when `hasMoreMessages && !isLoadingMore &&
      messageGroups.length > 0`.
- [ ] Clicking the button prepends the next page of older messages
      via the existing `loadChatHistory(true)` flow.
- [ ] The user's scroll position is preserved across the prepend
      (via `beginPreserve`/`endPreserve`).
- [ ] The button is hidden during in-flight pagination.
- [ ] The button disappears when `has_more: false` (i.e. all
      messages are loaded).
- [ ] `bun run build` is clean (TypeScript types check).
- [ ] Existing ChatView tests still pass; the new test for the
      button passes.
- [ ] Manual regression on a long chat confirms the user can
      paginate even when all loaded messages fit in the viewport.
- [ ] No change to the VirtualScroller component.
- [ ] No change to the backend API.
