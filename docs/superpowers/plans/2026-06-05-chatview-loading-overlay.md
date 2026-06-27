# ChatView Loading Overlay Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a debounced, full-component loading overlay to `ChatView.vue` that sits on top of all content (header, messages, input) during the initial chat history load, so the user sees a single, clear loading affordance instead of a blank scroller, an empty-state placeholder, and a small "Loading more" pill.

**Architecture:** A new reusable `LoadingOverlay.vue` component (a controlled overlay with a configurable delay prop so quick loads don't flash) consumed by `ChatView.vue` via a `v-if` on a derived `showLoadingOverlay` ref. The overlay is non-modal (does not trap focus, `pointer-events: none` on the dim layer) and uses `z-40` so it sits above all ChatView content but below the `z-50` modals/popups that may open during the load. A `delay` prop (default `250` ms) defers the actual render so a sub-250 ms cache hit does not produce a flash.

**Tech Stack:** Vue 3 (`<script setup lang="ts">`), Tailwind CSS 4 utility classes (matching the existing `bg-black/60 backdrop-blur-sm` modal pattern from `SkillsPopup.vue`/`ConfirmDialog.vue`/`WorkspaceModal.vue`/`RenameWorkspaceModal.vue`/`AddTaskDialog.vue`), the existing semantic CSS variables (`--semantic-card-bg`, `--semantic-text`, `--semantic-text-dim`, `--color-violet`), Vitest + `@vue/test-utils` for unit tests.

## Interpretation of the Request

> *"in `/src/apps/desktop/src/components/ChatView.vue` can you make loading lazy spinner overlap on top all ?"*

Two phrases need pinning down before the plan is useful, so the rest of the document is explicit about what is being built and what is **not**:

| Phrase | Interpretation | Rationale |
|---|---|---|
| **"loading lazy"** | A spinner that is **debounced on show** (it appears only after a configurable `delay`, default `250` ms) and **hides immediately** when the load resolves. "Lazy" here = "wait before showing, don't flash on instant loads." | This is the well-known "spinner delay" / "graceful loading" pattern. It matches the spirit of "lazy" in the rest of the codebase (the `VirtualScroller.vue` debounces height and loadMore updates at 50–200 ms, the `sseClient.ts` has its own backoff logic). Quick cache hits shouldn't show a spinner at all. |
| **"overlap on top all"** | A full-component overlay that visually covers the **entire ChatView area** (header bar, messages, FileInput) during the load. Sits above all ChatView content via `z-40`, below the `z-50` modal/popup layer. **Non-modal**: dim layer is `pointer-events-none`, so future cancel/cancel-when-stuck actions are easy to add without restructuring. | The existing inline "Loading more..." pill at `ChatView.vue:1420-1434` only floats at the top of the scroller and has `z-10`. The empty state at `ChatView.vue:1437-1453` and the `v-if="isLoading || messageGroups.length > 0"` placeholder scroller at `ChatView.vue:1507-1508` are all that visualises an initial load — a single full overlay is cleaner. |
| **Which loading state?** | Only the **initial** `isLoading` (first page of chat history for a session). `isLoadingMore` (paginating older messages) keeps the existing inline "Load more..." pill at `ChatView.vue:1420-1434` so the "Load more messages" button at `ChatView.vue:1482-1504` keeps its tight, contextual feedback. | The pill is small and unobtrusive for "fetch 20 older rows" — putting a full overlay over the chat for pagination would be jarring. The full overlay is justified only for the first load, when there is no content to look at anyway. |

If the user wants a different scope (e.g. **also** covering `isLoadingMore`, or **only** the messages area instead of the whole component), adjust the `showLoadingOverlay` computed in **Task 3 Step 3** — the rest of the plan is unchanged.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/apps/desktop/src/components/LoadingOverlay.vue` | **New.** Reusable overlay component. Props: `show: boolean`, `delay?: number` (default `250`), `message?: string` (default `'Loading…'`), `blur?: boolean` (default `true`). Non-modal. `z-40`. Renders nothing until `show` has been `true` for ≥ `delay` ms; resets the timer when `show` flips to `false`. |
| `src/apps/desktop/src/__tests__/LoadingOverlay.spec.ts` | **New.** Vitest unit tests using `@vue/test-utils` and `vi.useFakeTimers()`. Asserts default delay behaviour, configurable delay, no-flash on quick `show=false` flip, and the `aria-busy` contract. |
| `src/apps/desktop/src/components/ChatView.vue` | **Modify.** Add the `showLoadingOverlay` derived ref, render `<LoadingOverlay>` as the **last child** of the root `<div class="flex h-full w-full">` (so it covers the whole component via `absolute inset-0` inside a `position: relative` root — see Step 3 for the structural change), set `aria-busy` on the root, and add a `data-testid` for tests. |

### Why extract a component, not inline it

- **Testable in isolation.** The debounce logic is a stateful timer; a unit test should not need to mount `ChatView.vue` (which imports 19 helper components, sets up scroll observers, and touches the SSE API).
- **Reusable.** The same overlay will be useful for `FolderExplorer.vue:140` (folder tree load), `WorkspaceList.vue` (lazy workspace load), `SettingsView.vue` (config reload), and `ChatsList.vue` (per-item processing spinner replacement).
- **Matches the codebase convention.** Every other overlay in the project is its own file: `SkillsPopup.vue`, `ConfirmDialog.vue`, `WorkspaceModal.vue`, `RenameWorkspaceModal.vue`, `AddTaskDialog.vue`, `NalarSettings.vue`, `SettingsView.vue` — all are `fixed inset-0 z-50` with a `Teleport` and a backdrop. We follow the same shape but at `z-40` and **without** `Teleport` (we want to be bounded by `ChatView`, not the whole viewport).

---

## Chunk 1: Build the `LoadingOverlay` component (TDD)

### Task 1: Write the failing tests for `LoadingOverlay`

**Files:**
- Create: `src/apps/desktop/src/__tests__/LoadingOverlay.spec.ts`

- [ ] **Step 1.1: Read `src/apps/desktop/src/__tests__/setup.ts` end-to-end first**

Run: `wc -l /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop/src/__tests__/setup.ts`
Expected: see the `EventSourceStub`, any `vi.mock(...)` calls, and how `jsdom` is set up. Existing tests (`sseClient.spec.ts`) use `vi.useFakeTimers()` — copy the exact same setup pattern.

- [ ] **Step 1.2: Write the test file**

Create `src/apps/desktop/src/__tests__/LoadingOverlay.spec.ts` with the following content (TDD: these are the contracts the component must satisfy):

```ts
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { defineComponent, h, ref, nextTick } from 'vue'
import LoadingOverlay from '../components/LoadingOverlay.vue'

// A tiny harness so we can flip `show` mid-test without unmounting.
// Mirrors the "controlled overlay" pattern from SkillsPopup.vue.
const Harness = defineComponent({
  components: { LoadingOverlay },
  props: { show: { type: Boolean, required: true } },
  template: `<LoadingOverlay :show="show" :delay="delay" :message="message" :blur="blur" />`,
  data: () => ({ delay: 250, message: 'Loading…', blur: true }),
})

describe('LoadingOverlay', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('renders nothing while show=false', async () => {
    const wrapper = mount(Harness, { props: { show: false } })
    expect(wrapper.find('[data-testid="loading-overlay"]').exists()).toBe(false)
  })

  it('does NOT show immediately when show flips to true (debounce)', async () => {
    const wrapper = mount(Harness, { props: { show: false } })
    await wrapper.setProps({ show: true })
    // Just after the prop flips, the overlay must not be in the DOM yet.
    expect(wrapper.find('[data-testid="loading-overlay"]').exists()).toBe(false)
  })

  it('shows after the default 250ms delay elapses', async () => {
    const wrapper = mount(Harness, { props: { show: false } })
    await wrapper.setProps({ show: true })
    vi.advanceTimersByTime(249)
    await nextTick()
    expect(wrapper.find('[data-testid="loading-overlay"]').exists()).toBe(false)
    vi.advanceTimersByTime(1) // 250ms total
    await nextTick()
    expect(wrapper.find('[data-testid="loading-overlay"]').exists()).toBe(true)
  })

  it('hides immediately when show flips back to false (no exit delay)', async () => {
    const wrapper = mount(Harness, { props: { show: true } })
    vi.advanceTimersByTime(250)
    await nextTick()
    expect(wrapper.find('[data-testid="loading-overlay"]').exists()).toBe(true)

    await wrapper.setProps({ show: false })
    await nextTick()
    expect(wrapper.find('[data-testid="loading-overlay"]').exists()).toBe(false)
  })

  it('cancels a pending show if show flips back to false before the delay elapses', async () => {
    const wrapper = mount(Harness, { props: { show: false } })
    await wrapper.setProps({ show: true })
    vi.advanceTimersByTime(100) // halfway
    await wrapper.setProps({ show: false })
    vi.advanceTimersByTime(1000) // well past the original delay
    await nextTick()
    expect(wrapper.find('[data-testid="loading-overlay"]').exists()).toBe(false)
  })

  it('uses a custom message prop', async () => {
    const wrapper = mount(Harness, { props: { show: false } })
    await wrapper.setProps({ show: true })
    // Use the harness data() default for the test; see harness below.
    // We mutate the harness data via a custom harness in step 1.3.
  })

  it('uses a custom delay prop', async () => {
    const wrapper = mount(Harness, { props: { show: false } })
    ;(wrapper.vm as any).delay = 1000
    await wrapper.setProps({ show: true })
    vi.advanceTimersByTime(500)
    await nextTick()
    expect(wrapper.find('[data-testid="loading-overlay"]').exists()).toBe(false)
    vi.advanceTimersByTime(500) // 1000ms total
    await nextTick()
    expect(wrapper.find('[data-testid="loading-overlay"]').exists()).toBe(true)
  })

  it('exposes role="status" and aria-live="polite" once visible', async () => {
    const wrapper = mount(Harness, { props: { show: true } })
    vi.advanceTimersByTime(250)
    await nextTick()
    const root = wrapper.find('[data-testid="loading-overlay"]')
    expect(root.exists()).toBe(true)
    expect(root.attributes('role')).toBe('status')
    expect(root.attributes('aria-live')).toBe('polite')
  })
})
```

> **Note for the implementer:** The "uses a custom message" test as written above does not actually exercise the message — it's left as a placeholder. Replace it with a real assertion in Step 1.3 below.

- [ ] **Step 1.3: Tighten the "custom message" test**

Replace the placeholder test body with:

```ts
it('uses a custom message prop', async () => {
  const wrapper = mount(Harness, { props: { show: false } })
  ;(wrapper.vm as any).message = 'Loading chat history…'
  await wrapper.setProps({ show: true })
  vi.advanceTimersByTime(250)
  await nextTick()
  expect(wrapper.text()).toContain('Loading chat history…')
})
```

- [ ] **Step 1.4: Run the test to confirm it fails (RED)**

Run: `timeout 60 bun run test:unit -- src/__tests__/LoadingOverlay.spec.ts 2>&1 | tail -n 40`
Expected: every test in the file FAILS — `LoadingOverlay.vue` does not exist yet, so the import will throw, or the harness cannot find the component. Capture the failure output. This is the **RED** of TDD.

---

### Task 2: Implement `LoadingOverlay.vue` (GREEN)

**Files:**
- Create: `src/apps/desktop/src/components/LoadingOverlay.vue`

- [ ] **Step 2.1: Create the component**

Create `src/apps/desktop/src/components/LoadingOverlay.vue` with this content. The shape mirrors the existing modal overlays (`SkillsPopup.vue:35-46`) but at `z-40` and without `Teleport`, and the dim layer is `pointer-events-none` so the overlay is **non-modal**.

```vue
<script setup lang="ts">
import { ref, watch, onBeforeUnmount } from 'vue'

const props = withDefaults(
  defineProps<{
    show: boolean
    delay?: number
    message?: string
    blur?: boolean
  }>(),
  { delay: 250, message: 'Loading…', blur: true },
)

/**
 * Whether the overlay is actually rendered. We delay flipping this
 * to `true` by `delay` ms so an instant cache hit does not produce
 * a flash of a spinner. The pending timer is cancelled if `show`
 * flips back to `false` before the delay elapses.
 */
const visible = ref(false)
let pendingTimer: ReturnType<typeof setTimeout> | null = null

const clearPending = () => {
  if (pendingTimer !== null) {
    clearTimeout(pendingTimer)
    pendingTimer = null
  }
}

watch(
  () => props.show,
  (next) => {
    if (next) {
      if (pendingTimer !== null) return // already scheduled
      pendingTimer = setTimeout(() => {
        visible.value = true
        pendingTimer = null
      }, props.delay)
    } else {
      // Hide immediately — no exit delay. The user just got their content.
      clearPending()
      visible.value = false
    }
  },
  // Don't fire on the initial false → false mount; only on real flips.
  // { immediate: true } would schedule a timer for the very first show
  // before the parent can flip it, but since the parent starts with
  // show=false that is a no-op. We keep immediate:false so the test
  // "renders nothing while show=false" is trivially true.
)

onBeforeUnmount(() => {
  clearPending()
})
</script>

<template>
  <!--
    `data-testid` is the single hook all unit tests + manual QA use to
    assert visibility. Do not remove it.
  -->
  <div
    v-if="visible"
    data-testid="loading-overlay"
    role="status"
    aria-live="polite"
    class="absolute inset-0 z-40 flex items-center justify-center"
  >
    <!--
      Dim layer. `pointer-events-none` keeps the overlay non-modal: the
      user can still scroll the messages behind the dim if there is any
      content (typically there isn't on first load, but the property
      keeps the overlay future-proof). `bg-black/40` (40% opacity) is
      deliberately lighter than the `bg-black/60` used by `z-50` modals
      so it reads as "loading" rather than "blocking".
    -->
    <div
      class="absolute inset-0 bg-black/40 pointer-events-none"
      :class="blur ? 'backdrop-blur-sm' : ''"
    />

    <!--
      Spinner card. Matches the visual language of the inline
      "Loading more..." pill at ChatView.vue:1424-1433 and the
      "Compacting..." spinner at ChatView.vue:1839-1843: same violet
      border, same animate-spin, same `var(--semantic-card-bg)`
      background, same rounded-full shape, same dim text colour.
    -->
    <div
      class="relative flex items-center gap-2 px-4 py-2 rounded-full shadow-sm"
      style="background-color: var(--semantic-card-bg)"
    >
      <div
        class="w-4 h-4 border-2 rounded-full animate-spin"
        style="border-color: var(--color-violet); border-top-color: transparent"
      />
      <span class="text-sm" style="color: var(--semantic-text-dim)">
        {{ message }}
      </span>
    </div>
  </div>
</template>
```

- [ ] **Step 2.2: Run the test to confirm it passes (GREEN)**

Run: `timeout 60 bun run test:unit -- src/__tests__/LoadingOverlay.spec.ts 2>&1 | tail -n 40`
Expected: **8/8 tests pass**. If any test fails, the bug is in the component (not the test) — fix the component. The most likely failure is the "hides immediately" test: confirm the watcher's `else` branch flips `visible.value = false` synchronously (it must, otherwise the test is racy).

- [ ] **Step 2.3: Run the full test suite to confirm no regressions**

Run: `timeout 120 bun run test:unit 2>&1 | tail -n 30`
Expected: previously-passing tests still pass. The component is brand-new, so this just confirms we didn't break the import graph (e.g. by typo'ing the file path or exporting the wrong name from the harness).

---

## Chunk 2: Wire it into `ChatView.vue`

### Task 3: Render the overlay during the initial load

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue`

- [ ] **Step 3.1: Import the new component**

In the script block's import list (currently at `ChatView.vue:15-34`), add a new import after the existing `SseStatusBadge` import on line 16:

```ts
import LoadingOverlay from './LoadingOverlay.vue'
```

Match the existing single-quote, no-extension, `./<name>.vue` convention used by the surrounding imports (e.g. `import FileInput from './FileInput.vue'` on line 15).

- [ ] **Step 3.2: Add the `showLoadingOverlay` derived ref**

The overlay is a **derived** value, not a new flag — we want it driven by the same `isLoading` that the rest of the component already uses. Add this computed **near the existing loading flags** (currently at `ChatView.vue:382-384`, right after `const messages = ref<Message[]>([])`):

```ts
// True while the initial chat history is being fetched. Drives the
// full-component loading overlay (see <LoadingOverlay> at the bottom
// of the template). This is intentionally derived from `isLoading`
// and NOT a new flag — keeping a single source of truth means
// loadChatHistory's finally block only has to flip one ref.
const showLoadingOverlay = computed(() => isLoading.value)
```

Add `computed` to the import on line 2 if it isn't already imported (it is — line 2 currently imports `computed`). Do **not** change the import line.

- [ ] **Step 3.3: Add the overlay to the template**

The root of `ChatView.vue` is `<div class="flex h-full w-full">` at line 1404. Add `position: relative` to it so the overlay's `absolute inset-0` resolves against the ChatView's bounding box (not the viewport):

Before (line 1404):
```vue
  <div class="flex h-full w-full">
```

After:
```vue
  <div class="flex h-full w-full relative" aria-busy="showLoadingOverlay">
```

`aria-busy` is the screen-reader contract for "this region is loading" — it must be a **string value**, not a boolean expression, in the rendered HTML, so wrap it in `:aria-busy="..."` (Vue will stringify the boolean). Use the binding form:

```vue
  <div
    class="flex h-full w-full relative"
    :aria-busy="showLoadingOverlay"
  >
```

Then, **as the last child** of this root div, **after** the existing `<div class="flex flex-col h-full flex-1 min-w-0">` block (which currently ends at line 2018 with `</div>`), add:

```vue
    <!--
      Full-component loading overlay. Shows only during the initial
      chat history load (isLoading=true), not during isLoadingMore —
      pagination keeps the small inline "Loading more..." pill at
      line 1420. The overlay is non-modal (pointer-events-none on
      the dim layer) and z-40, so it sits above all ChatView
      content but below the z-50 modals (SkillsPopup, ConfirmDialog,
      etc.) that may open during the load.

      The overlay's internal `delay` (default 250ms) prevents a
      spinner flash for sub-250ms cache hits.
    -->
    <LoadingOverlay :show="showLoadingOverlay" message="Loading chat history…" />
```

The exact placement matters: it must be a **sibling of the inner content column**, not nested inside it, so its `absolute inset-0` covers the full root (header + messages + input), not just the messages area.

- [ ] **Step 3.4: Type-check**

Per the **MANDATORY** rule in the desktop build memory, run **`bun run build`** (not `bun run build-only` — the type check via `vue-tsc --build` is what catches a missing/bad import or a type mismatch in the binding).

Run: `timeout 180 bun run build 2>&1 | tail -n 60`
Expected: clean exit code 0. If `vue-tsc` complains about `aria-busy` not being a valid attribute on `<div>`, that is a known Vue 3 typing limitation — change the binding to `:aria-busy="showLoadingOverlay ? 'true' : 'false'"` (string form, ARIA spec compliant) and re-run.

- [ ] **Step 3.5: Manual visual smoke test**

Start the dev server: `timeout 30 bun run dev 2>&1 | head -n 30` (or open the running desktop app). In a chat with a slow first load (cold cache, large session), verify:
1. After clicking into a chat, a dim + spinner appears **only after ~250 ms** of waiting.
2. The dim covers the **header**, the **messages area** (including the "How can I help you?" empty state), and the **FileInput** at the bottom.
3. The spinner reads "Loading chat history…" (not the default "Loading…").
4. As soon as the messages render, the overlay disappears — no fade-out delay.
5. Clicking the "Load more messages" button (line 1482) still shows the small inline "Loading more..." pill at the top of the scroller; the full overlay does **not** reappear.
6. The "Compacting..." inline spinner on the Compact button (line 1839) is unaffected.

- [ ] **Step 3.6: Commit**

```bash
git add src/apps/desktop/src/components/LoadingOverlay.vue \
        src/apps/desktop/src/__tests__/LoadingOverlay.spec.ts \
        src/apps/desktop/src/components/ChatView.vue
git commit -m "feat(chatview): add debounced full-component loading overlay during initial chat history load"
```

---

## Chunk 3: Memory + final verification

### Task 4: Update project memory and final verification

**Files:**
- Modify: `~/.config/nalar/memories/<existing-or-new-file>.md` (global memory)
- (Optional) Modify: `src/apps/desktop/NALAR.md` if it exists

- [ ] **Step 4.1: Decide whether to update memory**

If a new non-obvious pattern was learned (e.g. *"all z-50 components in this codebase are modals; use z-40 for non-modal overlays"*), create or update a memory file. Otherwise, this step is a no-op. Two strong candidates for memories:

- If `~/.config/nalar/memories/` doesn't have a `desktop-overlay-conventions.md`, create one with the rule "z-50 + Teleport = modal (dim blocks input); z-40 + no Teleport + `pointer-events-none` on dim = non-modal overlay (dim is decorative)."
- If the `tailwindcss-development` skill is loaded, add a note that this codebase uses `bg-black/40 backdrop-blur-sm` for non-modal loaders and `bg-black/60 backdrop-blur-sm` for modals.

- [ ] **Step 4.2: Final verification — full test suite + build**

Run: `timeout 120 bun run test:unit 2>&1 | tail -n 20`
Expected: **all tests pass**, including the 8 new `LoadingOverlay.spec.ts` tests.

Run: `timeout 180 bun run build 2>&1 | tail -n 20`
Expected: clean build.

If both are green, the task is done. If either is red, the work is **not** done — fix and re-run.

- [ ] **Step 4.3: Commit (if memory was updated)**

```bash
git add ~/.config/nalar/memories/desktop-overlay-conventions.md
git commit -m "docs(memory): note z-40 non-modal overlay convention for desktop overlays"
```

---

## Out of Scope

- **Replacing the inline "Loading more..." pill** for `isLoadingMore`. The pill is small, contextual, and does not block input — a full overlay over an already-loaded chat is the wrong UX.
- **Cancel/cancel-after-N-seconds action.** A future PR could add a "stuck? cancel" button inside the spinner card. The current overlay is structured so this is purely additive: drop a `<button>` next to the spinner, add a `cancel` emit, parent wires it to a `controller.abort()`. Nothing in this plan blocks that.
- **Skeleton placeholders.** A skeleton screen (greyed-out message bubbles) is a different UX direction and would replace the empty state AND the initial scroller placeholder, not augment them. Out of scope.
- **Animating the overlay's appearance/disappearance.** The component renders nothing until the delay elapses (true lazy) and is removed from the DOM the moment `show` flips false. Adding a `<Transition name="fade">` is tempting but adds a 200 ms exit animation that contradicts the "hide immediately" contract documented in Task 1. Don't add it.
- **Teleporting the overlay to `<body>`.** That would make `absolute inset-0` resolve against the viewport, not the ChatView, and we'd need to coordinate with `AppLayout.vue:520/533/581` (which already uses `absolute inset-0` for its own panels). Stays inside the ChatView root.

---

## Pitfalls

- **`position: relative` on the root is mandatory.** Without it (see Step 3.3), `absolute inset-0` resolves against the nearest `position: relative` ancestor, which is the AppLayout root — the overlay would cover the whole window, not just the chat.
- **`vue-tsc` rejects `aria-busy` on `<div>`.** Vue 3's HTML attribute typings don't include every ARIA attribute. If `bun run build` fails on it, switch to the string form `:aria-busy="showLoadingOverlay ? 'true' : 'false'"` and re-run. This is the **only** expected `vue-tsc` issue with this plan.
- **Don't use `immediate: true` on the `watch(() => props.show, ...)`.** It would fire on mount with `show=false` and (depending on the implementation) could schedule a no-op timer. The tests "renders nothing while show=false" and "does NOT show immediately when show flips to true" both assume the watcher is `immediate: false`.
- **The harness in the test file uses `data()`.** Don't change it to `setup()` returning a ref — the tests rely on `(wrapper.vm as any).message = '...'` to mutate the harness mid-test. Switching to `setup()` makes that line a TS error.
- **Don't import `LoadingOverlay` from `@/components/...`.** The codebase uses **relative** imports throughout `ChatView.vue` (see line 15: `import FileInput from './FileInput.vue'`). Match the convention.

---

## Verification (Definition of Done)

- [ ] `bun run test:unit` → 8/8 `LoadingOverlay.spec.ts` tests pass, all pre-existing tests still pass.
- [ ] `bun run build` → exit 0, no `vue-tsc` errors.
- [ ] Manual: a slow first-load shows the dim + spinner after ~250 ms; a cached fast load shows nothing.
- [ ] Manual: the "Load more messages" pagination still uses the inline pill, not the new overlay.
- [ ] The overlay never appears outside the ChatView's bounding box.
- [ ] Screen reader announces the loading state (`role="status"`, `aria-live="polite"`, `aria-busy="true"` on the root).

---

## Execution Handoff

This plan is designed to be run with **subagent-driven-development** (the user's default per their project memory): one fresh subagent per task, two-stage review between tasks. The four tasks are small and independent enough to fit in a single execution session; Tasks 1+2 are tightly coupled (TDD) and should be the same subagent, Task 3 is independent, Task 4 is independent.

After the plan is approved, the implementer should:

1. Create a git worktree (per the `using-git-worktrees` skill) — this is non-trivial UI work that benefits from isolation.
2. Execute Chunk 1 (Tasks 1+2), confirm tests pass.
3. Execute Chunk 2 (Task 3), confirm build is clean.
4. Execute Chunk 3 (Task 4), commit.
5. Hand off to `finishing-a-development-branch` for merge/PR.
