# `MessagesPanel` Component Extraction — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:subagent-driven-development to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the messages wrapper, empty state, load-more button, and `<VirtualScroller>` from `ChatView.vue` into a focused `MessagesPanel.vue` component, leaving the per-message template as a scoped slot. ChatView keeps ownership of the scroll state machine and scroll-logger wiring.

**Architecture:** New `src/apps/desktop/src/components/MessagesPanel.vue` (~80 lines) owns the wrapper div, empty state, load-more button, and VirtualScroller instance. Communication with the parent is via 6 props (`isLoading`, `messageGroups`, `hasMoreMessages`, `isLoadingMore`, `scrollable`, `pageSize`), 4 emits (`update:scrollable`, `load-more`, `load-more-suppressed`, `scroll`), 1 scoped default slot (the per-message template), and 2 exposed refs (`wrapperRef`, `virtualScrollerRef`). ChatView reads through `messagesPanelRef.value?.X` to replace the 8 direct `virtualScrollerRef`/`messagesWrapperRef` call sites.

**Tech Stack:** Vue 3 (`<script setup lang="ts">`), TypeScript, Tailwind CSS (utility classes), existing `helpers/VirtualScroller.vue`, existing `scrollLogger.ts` (parent-owned).

**Worktree:** **Recommended.** Other workers are active in the same `main` checkout (per the orchestrator's "Active Workers" section), and parallel file edits on the same files have caused reverts in the past (see `~/.config/nalar/memories/multi-agent-file-reverts.md`). Create a worktree before starting Task 1:

```bash
cd /home/ginwa/agentic_coding_zig
git worktree add ginwaaitoolbox-feature-messages-panel -b feature/messages-panel main
cd ginwaaitoolbox-feature-messages-panel
```

(If you choose to run on `main` instead, accept the risk: another worker could revert your changes between commits.)

**Reference design doc:** `docs/plans/2026-06-11-messages-panel-extraction-design.md` (read this first if any design decision is unclear).

**Out of scope:** extracting the per-message template into its own component; generalizing VirtualScroller config into a shared constant; removing the `MessageGroup` interface from ChatView (it stays).

---

## File Structure

This plan creates/modifies exactly these files:

```
src/apps/desktop/src/components/MessagesPanel.vue   ← NEW: the extracted component (~80 lines)
src/apps/desktop/src/components/ChatView.vue        ← MODIFY: replace wrapper div with <MessagesPanel>, update 8 call sites
docs/plans/2026-06-11-messages-panel-extraction-design.md  ← UNCHANGED (reference only)
```

No build changes, no new dependencies, no schema migrations.

---

## Decisions locked in by this plan

These were decided during brainstorming and are **not up for re-litigation during implementation**:

- **`v-model:scrollable` for the scrollability state** — the parent owns `scrollerIsScrollable` (it's a top-level ref in ChatView today, used in the load-more button's `v-if` and the logger's `containerInfo` block). The new component re-emits `update:scrollable` and the parent binds via `v-model:scrollable="scrollerIsScrollable"`.
- **VirtualScroller config is baked in as internal defaults** — `buffer: 20`, `default-item-height: 200`, `load-more-threshold: 200`, `load-more-threshold-ratio: 0.5`, `load-more-at-top: true`, `total-count: 0`. The parent doesn't override any of them today, and a `virtualScrollerProps` pass-through would be premature abstraction.
- **`pageSize` is required (no default)** — the parent (`ChatView.vue`) defines `PAGE_SIZE = 1000` (L238) and passes `:page-size="PAGE_SIZE"` explicitly. Making the prop required surfaces a missing prop as a type error instead of a silent UI bug (the load-more button's title would show the wrong number).
- **Drop the commented-out "Loading more..." spinner block** (ChatView L1665-L1679). It's been disabled for a long time and is dead code.
- **Expose `wrapperRef` and `virtualScrollerRef` via `defineExpose`** — parent reads via `messagesPanelRef.value?.wrapperRef` and `messagesPanelRef.value?.virtualScrollerRef`. The old `messagesWrapperRef` and `virtualScrollerRef` local refs in ChatView are deleted.
- **Slot forwarding pattern** — use a `<template #default="slotProps">` adapter inside the new component that wraps `<slot :item="slotProps.item" :index="slotProps.index" />`. This preserves the parent's `<template #default="{ item: group, index: groupIndex }">` syntax without TS type loss.
- **`MessageGroup` type stays in ChatView.vue** (L567). The new component types `messageGroups: any[]` — the slot scope is the parent's contract.

---

## Chunk 1: All Changes (single chunk, ~400 lines)

### Task 1: Create `MessagesPanel.vue`

**Files:**
- Create: `src/apps/desktop/src/components/MessagesPanel.vue`

- [ ] **Step 1.1: Write the file with the full content**

Create `src/apps/desktop/src/components/MessagesPanel.vue` with the content below. The script is ~30 lines, the template is ~50 lines, all of it surgical.

```vue
<script setup lang="ts">
import { ref } from 'vue'

// ─── Types ───────────────────────────────────────────────────────
// `VirtualScrollerExposed` is the shape of the inner VirtualScroller's
// `defineExpose` output (see helpers/VirtualScroller.vue L624). It's
// duplicated here from ChatView.vue's local declaration rather than
// moved to the helper, to keep the refactor surface minimal — the
// canonical interface can be promoted to helpers/ in a follow-up.
interface VirtualScrollerExposed {
  scrollToIndex: (index: number, behavior?: ScrollBehavior) => void
  scrollToTop: (behavior?: ScrollBehavior) => void
  scrollToBottom: (behavior?: ScrollBehavior) => void
  scrollToItem: (index: number, behavior?: ScrollBehavior) => void
  beginPreserve: (newItemsCount: number) => void
  endPreserve: () => Promise<void>
  preserveScrollPosition: () => Promise<void>
  containerRef: { value: HTMLElement | null }
  isPreservingScroll: { value: boolean }
  effectiveLoadMoreThreshold: { value: number }
}

// ─── Refs ────────────────────────────────────────────────────────
const wrapperRef = ref<HTMLElement | null>(null)
const virtualScrollerRef = ref<VirtualScrollerExposed | null>(null)

// ─── Props / emits / expose ──────────────────────────────────────
const props = defineProps<{
  isLoading: boolean
  messageGroups: any[]
  hasMoreMessages: boolean
  isLoadingMore: boolean
  scrollable: boolean
  pageSize: number
}>()

const emit = defineEmits<{
  (e: 'update:scrollable', value: boolean): void
  (e: 'load-more'): void
  (e: 'load-more-suppressed'): void
  (e: 'scroll', payload: unknown): void
}>()

defineExpose({ wrapperRef, virtualScrollerRef })

// ─── Event adapters ──────────────────────────────────────────────
const onScrollabilityChange = (value: boolean) => emit('update:scrollable', value)
const onScroll = (payload: unknown) => emit('scroll', payload)
const onLoadMoreSuppressed = () => emit('load-more-suppressed')
const onLoadMoreClick = () => emit('load-more')
</script>

<template>
  <div ref="wrapperRef" class="relative flex-1 min-h-0 flex flex-col">
    <!-- Empty state — visible only when no messages and not loading -->
    <div
      v-if="!isLoading && messageGroups.length === 0"
      class="flex flex-col items-center justify-center h-full px-4"
    >
      <div
        class="w-16 h-16 rounded-2xl mb-4 flex items-center justify-center text-3xl"
        style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue))"
      >
        💬
      </div>
      <h3 class="text-lg font-medium mb-2" style="color: var(--semantic-text)">
        How can I help you?
      </h3>
      <p class="text-sm text-center" style="color: var(--semantic-text-dim)">
        Start a conversation by typing a message below
      </p>
    </div>

    <!--
      Load-more button.

      Gated on: hasMoreMessages (server says more) AND not already loading
      a page AND there are messages to show AND the container isn't
      scrollable. The last condition matters: when the container IS
      scrollable, the user can scroll to the top of the VirtualScroller
      to trigger its own @load-more event. The button exists to bridge
      the non-scrollable case (short chats that fit in the viewport) so
      the user is never permanently stuck on the most recent page.
    -->
    <div
      v-if="hasMoreMessages && !isLoadingMore && messageGroups.length > 0 && !scrollable"
      class="flex justify-center pt-2 pb-1"
      data-testid="load-more-messages"
    >
      <button
        @click="onLoadMoreClick"
        class="flex items-center gap-2 px-4 py-1.5 rounded-full text-xs transition-all duration-200 hover:scale-105"
        style="
          background-color: var(--semantic-card-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text);
        "
        :title="`Load ${pageSize} older messages`"
      >
        <span>↑</span>
        <span>Load more messages</span>
      </button>
    </div>

    <!-- Virtualized message list — per-group template comes from the parent's slot -->
    <VirtualScroller
      v-if="isLoading || messageGroups.length > 0"
      ref="virtualScrollerRef"
      :items="messageGroups"
      :total-count="0"
      :buffer="20"
      :default-item-height="200"
      :load-more-threshold="200"
      :load-more-threshold-ratio="0.5"
      :load-more-at-top="true"
      @load-more="onLoadMoreClick"
      @load-more-suppressed="onLoadMoreSuppressed"
      @scroll="onScroll"
      @scrollability-change="onScrollabilityChange"
    >
      <template #default="slotProps">
        <slot :item="slotProps.item" :index="slotProps.index" />
      </template>
    </VirtualScroller>
  </div>
</template>
```

Notes on the script:
- **`import { ref } from 'vue'`** — Vue APIs are manually imported in this project (see ChatView.vue L2: `import { ref, watch, onMounted, ... } from 'vue'`). There is no `unplugin-auto-import` or `unplugin-vue-components` configured.
- **`VirtualScrollerExposed` is duplicated** from ChatView.vue L260-271. Moving it to a shared location is a follow-up — keeping it duplicated for now minimizes the refactor's surface area. The two declarations must stay in sync if the helper's `defineExpose` shape changes.
- **`pageSize` is required** (no `?`, no `withDefaults`). The parent (`ChatView.vue`) defines `PAGE_SIZE = 1000` (L238) and passes `:page-size="PAGE_SIZE"` explicitly. Making it required surfaces a missing prop as a type error instead of a silent UI bug (the load-more button's title would show the wrong number).
- **The four event-adapter functions** (`onScrollabilityChange`, etc.) are present so the template reads as inline handlers without arrow functions on every line. They're 1-line wrappers and add no real cost.

- [ ] **Step 1.2: Run `bun run build` to confirm the new file compiles**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: clean build. At this point the component is **not yet imported anywhere**, so its existence is purely additive. The `props` variable is technically unused in the script (we destructure implicitly via the template) — `vue-tsc` may or may not warn; both are acceptable.

- [ ] **Step 1.3: Commit the new file**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/MessagesPanel.vue
git commit -m "feat(desktop): add MessagesPanel component (initial scaffold)"
```

This is a separate "additive" commit. The project still works exactly as before because nothing imports the new component yet.

---

### Task 2: Update `ChatView.vue` script — replace refs and call sites

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue:272` (remove `virtualScrollerRef` declaration)
- Modify: `src/apps/desktop/src/components/ChatView.vue:281` (remove `messagesWrapperRef` declaration)
- Modify: `src/apps/desktop/src/components/ChatView.vue` — replace the 8 call sites listed in §4 of the design doc

- [ ] **Step 2.1: Replace the old ref declarations with the new `messagesPanelRef`**

Find the line that declares `messagesWrapperRef` (around L281, marked with a comment block explaining the scroll logger). Replace the entire comment + declaration with:

```ts
// Ref to the MessagesPanel component. The panel exposes
// `wrapperRef` (the flex container) and `virtualScrollerRef` (the
// inner VirtualScroller); both are forwarded into `buildScrollContext`
// so the scroll logger can report container geometry. See
// `src/apps/desktop/src/components/MessagesPanel.vue` for the
// forwarding pattern.
const messagesPanelRef = ref<InstanceType<typeof MessagesPanel> | null>(null)
```

Also remove the `virtualScrollerRef` declaration at L272 and the 7-line comment block above it (L274-L280) — the comment is now inaccurate (it explains the wrapper ref, which has moved into the panel).

Add a manual `import MessagesPanel from './MessagesPanel.vue'` to the top of ChatView.vue's `<script setup>` block (right after the existing `import { ... } from 'vue'` line at L2). This makes the `typeof MessagesPanel` expression in the ref declaration type-check correctly — `unplugin-vue-components` is not configured in this project, so the auto-resolver won't pick up the new file for `typeof` expressions.

- [ ] **Step 2.2: Update the 16 call sites across 3 patterns**

The 8 `virtualScrollerRef` and 8 `messagesWrapperRef` references split into 3 distinct patterns. **`text_replace` requires unique match**, so each pattern's substitution must be applied per-occurrence with disambiguating context (e.g., a multi-line anchor that includes the surrounding `buildScrollContext` invocation). Below, each pattern lists the search-and-replace strings to use; apply them in order, anchoring on the surrounding context where needed.

**Pattern A — `virtualScrollerRef.value?.X()` method/ref reads (4 occurrences, at L87, L867, L869, L1184 or similar):**

`defineExpose({ virtualScrollerRef })` in MessagesPanel exposes the **Ref object**, not its unwrapped value. So accessing the scroller instance requires **one extra `.value` unwrap** vs the current code: `messagesPanelRef.value?.virtualScrollerRef?.value?.X`.

For each of the 4 search strings below, do one `text_replace` (each is unique in the file):

1. Search: `virtualScrollerRef.value?.beginPreserve(`
   Replace: `messagesPanelRef.value?.virtualScrollerRef?.value?.beginPreserve(`

2. Search: `virtualScrollerRef.value?.endPreserve()`
   Replace: `messagesPanelRef.value?.virtualScrollerRef?.value?.endPreserve()`

3. Search: `virtualScrollerRef.value?.isPreservingScroll.value`
   Replace: `messagesPanelRef.value?.virtualScrollerRef?.value?.isPreservingScroll.value`

4. Search: `virtualScrollerRef.value?.containerRef.value`
   Replace: `messagesPanelRef.value?.virtualScrollerRef?.value?.containerRef.value`

**Pattern B — `wrapperRef: messagesWrapperRef,` in `buildScrollContext` calls (8 occurrences, at L330, L786, L808, L848, L896, L934, L1038, L1134):**

`buildScrollContext` expects the Ref object (`{ value: unknown } | null`, see scrollLogger.ts L686-700), NOT the unwrapped scroller instance. So passing `messagesPanelRef.value?.wrapperRef` (the Ref itself) is structurally correct.

`text_replace` requires unique match — repeat the substitution 8 times, anchoring each on a few lines of surrounding `buildScrollContext` context to disambiguate. Example for the first one (L330):

```
Search:
  const ctx = buildScrollContext(container, {
    chatId: sessionId.value || props.chatId,
    messages: messages.value.length,
    isAtBottom: isAtBottom.value,
    virtualScrollerRef,
    wrapperRef: messagesWrapperRef,
  })

Replace:
  const ctx = buildScrollContext(container, {
    chatId: sessionId.value || props.chatId,
    messages: messages.value.length,
    isAtBottom: isAtBottom.value,
    virtualScrollerRef,
    wrapperRef: messagesPanelRef.value?.wrapperRef,
  })
```

For the other 7 occurrences, use a similar multi-line anchor that includes the call site context.

**Pattern C — `virtualScrollerRef,` (the last arg in each `buildScrollContext` call, 8 occurrences, at L329, L785, L807, L847, L895, L933, L1037, L1133):**

`buildScrollContext` expects the Ref object for `virtualScrollerRef` too — same shape as Pattern B. Substitution: pass the Ref itself, no extra `.value`.

For each occurrence, anchor on a few lines of surrounding `buildScrollContext` context. Example for the first one (L329):

```
Search:
  const ctx = buildScrollContext(container, {
    chatId: sessionId.value || props.chatId,
    messages: messages.value.length,
    isAtBottom: isAtBottom.value,
    virtualScrollerRef,
    wrapperRef: messagesWrapperRef,

Replace:
  const ctx = buildScrollContext(container, {
    chatId: sessionId.value || props.chatId,
    messages: messages.value.length,
    isAtBottom: isAtBottom.value,
    messagesPanelRef.value?.virtualScrollerRef,
    wrapperRef: messagesPanelRef.value?.wrapperRef,
```

(Notice: Patterns B and C are applied in the same `text_replace` per occurrence — both lines change in the same call site. The example above combines them.)

**After all 16 substitutions**, verify with:

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git grep -n "virtualScrollerRef\b\|messagesWrapperRef\b" src/apps/desktop/src/components/ChatView.vue
```

Expected: no output (zero matches — note the `\b` word boundary, which avoids matching the new `messagesPanelRef` references that contain `virtualScrollerRef` as a substring).

- [ ] **Step 2.3: Run `bun run build` — expect clean build (TypeScript can't see template bindings)**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 40
```

Expected at this stage: **the type-check passes**, but the runtime is broken. `vue-tsc` can't see that ChatView's template still references `<VirtualScroller ref="virtualScrollerRef">` and the wrapper div — template bindings aren't part of the type-checker's input. So the build will succeed, but the moment Vue mounts the template, `virtualScrollerRef` is gone (deleted in Step 2.1), and any code path that touches the scroll machinery will throw `TypeError: cannot read properties of undefined` at runtime.

The build at this point is therefore **not a useful regression net** — it just confirms the script-side type changes are syntactically valid. The template fix in Task 3 is what restores the runtime path.

**Common error recovery (if the build fails here, the cause is one of these):**

| Error | Cause | Fix |
|---|---|---|
| `TS2305: Module '"vue"' has no exported member 'ref'` or `Cannot find name 'ref'` | Forgot `import { ref } from 'vue'` in MessagesPanel.vue (Step 1.1) | Add the import — Vue APIs are manually imported in this project, not auto-imported. |
| `TS2304: Cannot find name 'VirtualScrollerExposed'` | Forgot the interface definition in MessagesPanel.vue (Step 1.1) | Add the interface — it's duplicated from ChatView.vue L260-271. |
| `TS2322: Type '...' is not assignable to type '...'` on the `messagesPanelRef` line | `InstanceType<typeof MessagesPanel>` isn't resolving (auto-import not picking up the new file) | Add a manual `import MessagesPanel from './MessagesPanel.vue'` at the top of ChatView.vue's `<script setup>`. |
| `Property 'virtualScrollerRef' does not exist on type '...'` on the substituted call sites | `messagesPanelRef` is typed too narrowly | Type as `messagesPanelRef = ref<any>(null)` for now and add a TODO — the type-checker will catch real issues when the template-side wiring in Task 3 unblocks. |
| `Property 'wrapperRef' does not exist on type '...'` | Same as above | Same fix. |

If the build fails for any other reason, **stop and surface to the human** — the plan's lock-in is that the only valid intermediate failures are listed in this table.

- [ ] **Step 2.4: Don't commit yet**

The script changes alone are a broken intermediate state. They will be committed together with Task 3's template changes in Task 4.

---

### Task 3: Update `ChatView.vue` template — replace wrapper div with `<MessagesPanel>`

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue:1662-L2018` (the wrapper div and all its children)

- [ ] **Step 3.1: Replace the wrapper div block with `<MessagesPanel>`**

Find the line:
```html
      <!-- Messages (Virtual Scroll) -->
      <!-- ...long comment... -->
      <div ref="messagesWrapperRef" class="relative flex-1 min-h-0 flex flex-col">
```

and replace the entire block from that line through the matching `</div>` on L2018 with:

```html
      <!-- Messages (Virtual Scroll) -->
      <!--
        The wrapper MUST be a flex container (`flex flex-col`) so the
        VirtualScroller's own `flex: 1 1 0` (defined in helpers/
        VirtualScroller.vue) can resolve to a real height. The flex
        container and the empty-state / load-more button / VirtualScroller
        instances are all encapsulated in MessagesPanel.vue — see
        `src/apps/desktop/src/components/MessagesPanel.vue` for the
        layout contract. The per-group message template is provided
        below as a scoped default slot.
      -->
      <MessagesPanel
        ref="messagesPanelRef"
        :is-loading="isLoading"
        :message-groups="messageGroups"
        :has-more-messages="hasMoreMessages"
        :is-loading-more="isLoadingMore"
        v-model:scrollable="scrollerIsScrollable"
        :page-size="PAGE_SIZE"
        @load-more-suppressed="handleLoadMoreSuppressed"
        @scroll="handleVirtualScroll"
        @load-more="handleLoadMore"
      >
        <template #default="{ item: group, index: groupIndex }">
```

Then close the `<MessagesPanel>` and `<template #default>` after the per-message template body. The current per-message template (L1765-L2016) starts with `<template #default="{ item: group, index: groupIndex }">` and ends just before `</VirtualScroller>` on L2017. The replacement keeps the entire body of that template verbatim, but the surrounding `<VirtualScroller>` wrapper is now inside `MessagesPanel`, and the per-message template's `</template>` is the inner closing.

**IMPORTANT — `@load-more="handleLoadMore"`, NOT `@load-more="loadChatHistory(true)"`.** The `handleLoadMore` function (ChatView.vue L923) is a wrapper around `loadChatHistory(true)` that contains critical guard logic:
- the `isAutoStickActive` gate (prevents jitter during active streaming)
- the `hasMoreMessages` check
- the `isLoadingMore` "already loading" check
- the empty-list guard
- diagnostic logging with `load-more-suppressed` reason codes

Bypassing `handleLoadMore` and calling `loadChatHistory(true)` directly would re-introduce the "scroll-prepend-jitter" bug that this function was specifically designed to prevent. The MessagesPanel's `load-more` emit is forwarded as-is; the parent must decide which handler to bind.

Concretely: at the bottom of the per-message template block, where the original code reads:
```html
        </template>
      </VirtualScroller>
      </div>
```
(closing the `<template #default>`, the `<VirtualScroller>`, and the wrapper div respectively), the replacement reads:
```html
        </template>
      </MessagesPanel>
```
(closing the `<template #default>` and the `<MessagesPanel>`).

The `</div>` that closed the wrapper div is removed entirely (the panel owns its own root `<div>`).

**Slot scope note:** the per-message template body (L1765-L2016) references many local-scope values from ChatView's `<script setup>` — `openImagePreview`, `toggleToolExpanded`, `expandedToolIds`, `innerToolData`, `hasBubbleContent`, `cwd`, etc. All of these continue to work because slot content is compiled in the **parent's scope** (ChatView.vue's `<script setup>`), not in the panel's. The `<template #default="slotProps">` adapter inside the panel binds the inner VirtualScroller's `v-for` variables to `slotProps.item` and `slotProps.index`, and the destructure `<template #default="{ item: group, index: groupIndex }">` in ChatView maps them back to the names the existing code uses. The `MessageGroup` interface (L567) is also in the parent's scope, so the slot body's `group.role`, `group.messages`, etc. are type-checked correctly even though the panel itself types the prop as `any[]`.

- [ ] **Step 3.2: Run `bun run build` — expect success**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: clean build. `vue-tsc` should pass (the 8 call sites are correctly typed, the new component is correctly typed, the slot is correctly forwarded). If there are errors, they will be one of:
- A `VirtualScrollerExposed` import missing in `MessagesPanel.vue` — fix per Step 1.2.
- A `MessagesPanel` not auto-resolved by `unplugin-vue-components` — add a manual `import MessagesPanel from './MessagesPanel.vue'` to `ChatView.vue`.
- A `messagesPanelRef` type mismatch — the `InstanceType<typeof MessagesPanel>` should work; if not, switch to `ComponentRef<typeof MessagesPanel>` from `@vue/composition-api` or just type as `any` and add a TODO.

- [ ] **Step 3.3: Run `bunx vitest run` — expect success**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 20
```

Expected: same pass count as before the refactor — **179 tests passed across 22 test files** (verified baseline at plan time). **No new tests are added** — this is a refactor with no behavior change.

- [ ] **Step 3.4: Commit the refactor**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/ChatView.vue
git commit -m "refactor(desktop): use MessagesPanel in ChatView (extraction complete)"
```

---

### Task 4: Final verification

- [ ] **Step 4.1: Confirm line-count delta**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git diff --stat HEAD~2 -- src/apps/desktop/src/components/
```

Expected:
- `ChatView.vue`: line count drops by ~250-300 (the wrapper + empty state + load-more + VirtualScroller config are gone; the per-message template stays).
- `MessagesPanel.vue`: ~80-100 new lines.

- [ ] **Step 4.2: Confirm zero residual references**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git grep -n "messagesWrapperRef\|virtualScrollerRef" src/apps/desktop/src/components/ChatView.vue
```

Expected: no output.

- [ ] **Step 4.3: Manual smoke test (described, not automated)**

Open the desktop app in a running chat. Walk through the four cases from the design doc §8:

1. **Empty state**: open a fresh chat, confirm the "How can I help you? 💬" panel renders.
2. **Virtualized list**: send 3-5 messages, confirm they render with correct bubble styling and the list scrolls to the bottom.
3. **Load-more in non-scrollable chat**: in a short chat (all messages fit in the viewport), confirm the "↑ Load more messages" button is visible and clicking it paginates correctly. Open the browser devtools console and verify the `scrollLogger` shows `wrapperRef` readings (not `⚠NO-CONTAINER`).
4. **Scrollable chat, no button**: in a long chat, scroll to the top. Confirm the button is hidden and the VirtualScroller's own `@load-more` event still fires when scrolling within `loadMoreThreshold` of the top.
5. **Stream a long response**: send a message that triggers a long assistant response. During the stream, watch the scroll logger — the `wrapperRef` block should read sensibly (not 0×0, not `⚠ZERO-SIZE`).

If any of the five checks fails, the refactor introduced a regression — the most likely cause is a missed call site or a wrong field name. The fix is mechanical; the verification is the regression net.

- [ ] **Step 4.4: Update NALAR.md (optional but recommended)**

Add a brief entry under the "Bug Fixes (Development Notes)" or "Lessons Learned" section:

```markdown
- [MessagesPanel.vue] Extracted the messages wrapper (flex container,
  empty state, load-more button, <VirtualScroller>) from ChatView.vue
  into a focused `MessagesPanel.vue` component. ChatView's
  per-message template stays as a scoped default slot. The parent
  reads through `messagesPanelRef.value?.wrapperRef` and
  `messagesPanelRef.value?.virtualScrollerRef` to replace 8 direct
  ref call sites. See `docs/plans/2026-06-11-messages-panel-extraction-design.md`
  for the design rationale.
```

(This isn't a bug fix or a lesson — it's a refactor note. Skip if the maintainer prefers the changelog in commit messages only.)

- [ ] **Step 4.5: Final commit (if NALAR.md was updated)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add NALAR.md
git commit -m "docs(nalar): note MessagesPanel extraction in NALAR.md"
```

---

## Verification summary

| Check | Command | Pass criterion |
|---|---|---|
| Type-check + bundle | `cd src/apps/desktop && bun run build` | Clean, no errors |
| Unit tests | `cd src/apps/desktop && bunx vitest run` | 179 passed across 22 test files (no change vs baseline) |
| Line count | `git diff --stat HEAD~2 -- src/apps/desktop/src/components/` | ChatView drops ~250 lines; MessagesPanel gains ~80-100 |
| No residual refs | `git grep -n "virtualScrollerRef\b\|messagesWrapperRef\b" src/apps/desktop/src/components/ChatView.vue` | Zero matches (word-boundary match — `messagesPanelRef.value?.virtualScrollerRef` is fine) |
| Manual smoke | 5-case walk-through in a running chat | All 5 cases pass |

---

## Out of scope (do not do)

- Extracting the per-message template into its own component.
- Generalizing VirtualScroller config into a shared `chatScrollerProps` constant.
- Removing the `MessageGroup` interface from ChatView.vue.
- Renaming `scrollerIsScrollable` to something else.
- Touching any other file in `src/apps/desktop/`.

If any of these feels necessary during implementation, stop and surface to the human — the design is locked, and any deviation needs a re-design pass.
