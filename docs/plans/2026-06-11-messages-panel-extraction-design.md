# Design: Extract `MessagesPanel` component from `ChatView.vue`

> **Goal:** Move the messages wrapper (flex container, empty state, load-more
> button, and `<VirtualScroller>`) out of `ChatView.vue` into a focused
> `MessagesPanel.vue` component, leaving the per-message template as a scoped
> slot. The parent keeps ownership of the scroll state machine and the
> scroll-logger wiring.

---

## 1. Context

`ChatView.vue` is 2,446 lines and is the single largest file in the desktop
app. The "messages area" — the `<div ref="messagesWrapperRef" class="…">` block
plus everything nested inside it — accounts for ~357 of those lines
(L1662-L2018), spanning:

- An empty-state panel (L1682-L1698).
- A "Load more messages" button (L1727-L1747) gated on a 4-condition expression.
- A `<VirtualScroller>` instance (L1750-L2017) with a ~250-line scoped slot
  containing the user/tool bubble markup, image attachments, and per-tool
  renderers (`<ReadFile>`, `<WriteFile>`, `<Bash>`, `<Glob>`, `<Search>`, etc.).

The wrapper div itself exists for two reasons:

1. **Layout**: `flex flex-col` lets the inner `<VirtualScroller>` resolve its
   `flex: 1 1 0` to a real height (the "no scroll, bubbles overlap input"
   bug — see the comment block at L1652-L1660).
2. **Logger diagnostics**: the parent reads `messagesWrapperRef.value` to
   pass into `buildScrollContext` so the scroll logger can distinguish
   "wrapper isn't sized" from "scroller isn't sized" (L274-L281).

Both responsibilities are stable and re-usable across the codebase (any
view that hosts a virtualized message list will want the same flex wrapper +
empty state + load-more affordance). Extracting them into a component
reduces the cognitive load of reading `ChatView.vue` and gives future
"messages panel" usages a single import to reach for.

---

## 2. Scope (what is and is not in this extraction)

**In scope — moves into `MessagesPanel.vue`:**

- The wrapper `<div ref="wrapperRef" class="relative flex-1 min-h-0 flex flex-col">`.
- The empty-state block (the 💬 panel).
- The "Load more messages" button.
- The `<VirtualScroller>` element, its config props, and the `@load-more-suppressed`
  / `@scroll` / `@scrollability-change` re-emits.

**Stays in `ChatView.vue`:**

- The per-group message template (the ~250-line `<template #default>` body
  inside the VirtualScroller). It is passed to the new component as a
  scoped slot.
- The scroll state machine: `virtualScrollerRef`, `isAtBottom`,
  `lastAutoStickAt`, `handleLoadMore`, `handleLoadMoreSuppressed`,
  `handleVirtualScroll`, `onSpacersResized`, the
  `spacerObserver`/`MutationObserver` wiring, and all 8 `buildScrollContext`
  call sites.
- The `scrollLogger` calls themselves.
- The `MessageGroup` interface definition (the new component types
  `messageGroups: any[]` — the slot scope is the parent's contract).

**Removed (cleanup):**

- The commented-out "Loading more..." indicator block (ChatView.vue
  L1665-L1679). It has been disabled for a long time and is dead code; the
  new component only ships live UI.

---

## 3. Component API

### 3.1 Props (parent → child)

```ts
const props = defineProps<{
  isLoading: boolean
  messageGroups: any[]
  hasMoreMessages: boolean
  isLoadingMore: boolean
  scrollable: boolean          // v-model:scrollable — parent owns
  pageSize: number             // required — no default; the parent must pass it
}>()
```

VirtualScroller config (buffer, default-item-height, load-more-threshold,
load-more-threshold-ratio, load-more-at-top, total-count) is baked in as
internal defaults — the parent doesn't override any of them today, and
adding a `virtualScrollerProps` pass-through object would be premature
abstraction.

### 3.2 Emits (child → parent)

| Emit | Payload | Origin |
|---|---|---|
| `update:scrollable` | `(value: boolean)` | Re-emit of VirtualScroller's `@scrollability-change` |
| `load-more` | `()` | "Load more messages" button click **AND** re-emit of VirtualScroller's `@load-more` (scroll-to-top pagination). Both event sources share the same emit so the parent has a single handler. |
| `load-more-suppressed` | `()` | Re-emit of VirtualScroller's `@load-more-suppressed` |
| `scroll` | `(payload: unknown)` | Re-emit of VirtualScroller's `@scroll` |

### 3.3 Slots

- **Default (scoped)**: `<slot :item="slotProps.item" :index="slotProps.index" />`
  — forwarded from the inner VirtualScroller's `#default` slot.

### 3.4 Exposed (via `defineExpose`)

- `wrapperRef: Ref<HTMLElement | null>` — the wrapper div. Parent reads via
  `panelRef.value?.wrapperRef` to pass to `buildScrollContext`.
- `virtualScrollerRef: Ref<VirtualScrollerExposed | null>` — the inner
  VirtualScroller. Parent reads via `panelRef.value?.virtualScrollerRef` to
  call `beginPreserve`, `endPreserve`, `containerRef`, etc.

---

## 4. Parent-side changes (8 call sites)

The parent declares a new template ref:

```ts
const messagesPanelRef = ref<InstanceType<typeof MessagesPanel> | null>(null)
```

The existing `virtualScrollerRef` and `messagesWrapperRef` local refs are
**removed** and their 8 read sites are rewritten to read through the new
panel ref:

| Old | New |
|---|---|
| `virtualScrollerRef.value?.containerRef.value` | `messagesPanelRef.value?.virtualScrollerRef?.containerRef.value` |
| `virtualScrollerRef.value?.beginPreserve(n)` | `messagesPanelRef.value?.virtualScrollerRef?.beginPreserve(n)` |
| `virtualScrollerRef.value?.endPreserve()` | `messagesPanelRef.value?.virtualScrollerRef?.endPreserve()` |
| `virtualScrollerRef.value?.isPreservingScroll.value` | `messagesPanelRef.value?.virtualScrollerRef?.isPreservingScroll.value` |
| `wrapperRef: messagesWrapperRef` (in `buildScrollContext`) | `wrapperRef: messagesPanelRef.value?.wrapperRef` |
| `virtualScrollerRef` (in `buildScrollContext`) | `virtualScrollerRef: messagesPanelRef.value?.virtualScrollerRef` |

All changes are mechanical. The null-safe chaining (`?.`) preserves the
existing defensive-read pattern used throughout ChatView's scroll code.

---

## 5. File-level changes

- **New**: `src/apps/desktop/src/components/MessagesPanel.vue` (~80 lines:
  30-line script, 50-line template).
- **Modified**: `src/apps/desktop/src/components/ChatView.vue`:
  - Remove L1662-L2018 (the wrapper div and all its children, except the
    per-message template moves into the new `<MessagesPanel>` usage).
  - Remove L272 (`const virtualScrollerRef = ref<...>`).
  - Remove L281 (`const messagesWrapperRef = ref<...>`).
  - Update the 8 call sites listed in §4.
  - Add `const messagesPanelRef = ref<...>` and a `MessagesPanel` import.
  - Add `<MessagesPanel …>` block to the template with the per-message
    `<template #default>` slot body.

---

## 6. Quality criteria

The new component should be:

1. **Short** — target ≤ 100 lines including the template. Anything longer
   means we missed an extraction.
2. **Self-contained** — no implicit dependencies on a parent ref or global
   state. The only communication with the parent is via props, emits, the
   default slot, and the exposed refs.
3. **Free of dead code** — no commented-out blocks, no `<!-- TODO -->`s.
   The disabled "Loading more..." spinner is removed, not carried over.
4. **Type-safe** — props use `defineProps<{...}>()` with `withDefaults` for
   optional values; emits are typed; `defineExpose` declares the exposed
   shape so the parent's template ref is typed.
5. **Consistent with project style** — `// ─── Section ───` separator
   comments in the script, matching the convention used throughout
   ChatView.vue (e.g. L432, L484, L623).
6. **Conservative on WHY comments** — one short block-comment above the
   load-more button explaining the 4-condition gate (mirroring the existing
   20-line WHY in ChatView L1700-L1726, condensed to ~5 lines). One short
   JSDoc on the wrapper ref explaining why the parent reads it. No
   decorative comments.

---

## 7. Risks & mitigations

| Risk | Mitigation |
|---|---|
| **Type regression** on the 8 call sites | Run `bun run build` after the change (not just `bunx vitest run`) — per project NALAR.md, the build is the authoritative TS type-check. |
| **Reactivity loss** through the `panelRef.value?.X` chain | Vue 3 auto-unwraps refs returned by `defineExpose`, so the parent reads the unwrapped `Ref<T>` (or `null`) cleanly. Verified pattern: the SseStatusBadge, SseClient, and other composables already follow the same `defineExpose` → `ref.value?.X` shape. |
| **Slot forwarding loses scoped-slot types** | Use `<template #default="slotProps">` adapter inside the new component and forward as `<slot :item="…" :index="…">`. Tested in many other components in the codebase. |
| **Commented-out spinner removal breaks someone's muscle memory** | It's a `<!-- temporary disable -->` from a long-disabled feature. None of the live behavior references it. Removal is the right call; if it's ever needed, it lives in git history. |
| **PAGE_SIZE mismatch** | `PAGE_SIZE` in ChatView is `1000` (L238); the load-more button's title today is `Load ${PAGE_SIZE} older messages`. The new component accepts `pageSize` as a **required** prop (no default), so a missing prop produces a TS error at the call site. The parent passes `:page-size="PAGE_SIZE"`. |

---

## 8. Verification

1. `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20` —
   must be clean (TS type-check + bundle).
2. `cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 20` —
   existing tests must still pass.
3. Manual smoke test in a running chat:
   - Open a chat, confirm the empty state renders correctly.
   - Send a few messages, confirm the virtualized list renders and scrolls.
   - In a non-scrollable chat, confirm the "Load more" button appears and
     works.
   - In a scrollable chat, confirm the button is hidden and scroll-to-top
     still triggers `loadMore`.
   - Stream a long response, confirm the scroll logger's `wrapperRef`
     readings match the previous shape (no "⚠NO-CONTAINER" markers).
4. `git diff --stat src/apps/desktop/src/components/` — `ChatView.vue` line
   count must drop by ~250 and `MessagesPanel.vue` must appear at ~80-100
   lines.

---

## 9. Out of scope

- Extracting the per-message template into its own component (a future
  refactor — the ~250-line slot body is its own candidate, but it has
  heavily context-dependent bindings to ChatView state and would explode
  the prop surface).
- Extracting the empty state into its own component (overkill — it's
  ~15 lines).
- Generalizing `<VirtualScroller>` config into a shared
  `chatScrollerProps` constant (premature; the new component bakes in the
  current values).
