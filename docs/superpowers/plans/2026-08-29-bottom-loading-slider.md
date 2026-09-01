# Per-Session LLM Loading Slider — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the per-row yellow spinner circle that currently floats next to each chat name in the sidebar (`ChatsList.vue:467-475`) with a thin **per-session** animated slider that sits at the bottom edge of that chat's row in the sidebar. The slider shows only when the LLM worker for that session is running (`processingState[sessionId] === true`). All sessions are independent: one session processing shows its slider while every other session sits idle. **No global bottom-of-window bar** and **no duplicate slider inside `ChatView` or `SubAgentPeekPanel`** — the sidebar row IS the indicator for "this session is working", and adding the same indicator elsewhere signals the same fact twice for the same session (one of those signals is redundant by design — see the design memory at `~/.config/nalar/.../design-no-redundant-loading-indicators`).

**Architecture:**

```
                ┌────────────────────────────────────────┐
   Top of app   │  AnakMagang            Settings        │   ← chrome (unchanged)
                ├────────────────────────────────────────┤
                │  ▼ CHATS                  ↓ +          │
                │  ◐ mcp stdio has issue         now     │   ← idle (no slider)
                │  ▓▓░░░░░░░░░░░░░░░░░░░░░░░░ implement │
                │    mcp using http              4m     │   ← PROCESSING
                │    ┃ ←── per-session slider ──→ ┃     │      thin bar at the
                │    ┃ animated yellow strip      ┃     │      bottom of the row
                │  ◐ fix ci,                    11h     │   ← idle
                │  ◐ greeting-hello             11h     │   ← idle
                │  ▶ WORKSPACES                           │
                │    ▶ sprint bulan juni          —     │
                │                                        │
                │                                        │
                │                                        │
                │              ┌──────────┐              │
                │              │ chatview │              │
                │              │ messages │              │
                │              │  …       │              │
                │              │  …       │              │
                │              │          │              │   ← NO slider inside the
                │              ├──────────┤              │      chatview — the
                │              │   type   │              │      sidebar row IS the
                │              │   here   │              │      indicator (one
                │              └──────────┘              │      signal, one place)
                └────────────────────────────────────────┘
```

Three pieces, two new files:

1. **`components/SessionSlider.vue`** (NEW) — Reusable thin sliding bar. Takes one prop: `sessionId: string`. Reads `processingState` (already injected by `App.vue:11`) and shows iff `processingState[sessionId] === true`. The animation is the same `translateX(-100% → 100%)` keyframe as before, just scoped to the component's bounding box. The bar uses `var(--color-yellow)` to match the existing yellow spinner (so the visual continuity is preserved — replace the spinner with the slider, not the color).
2. **`stores/sessionSliderState.ts`** — **NOT NEEDED**. We piggyback on the existing `processingState: Ref<Record<string, boolean>>` provided by `App.vue:10-11` via Vue's `provide` / `inject`. SSE worker events already drive this map (`App.vue:22-43`) so the slider is reactive for free — no new store, no SSE wiring change.
3. **Mount `SessionSlider` in ONE place** — wire it into the existing chat-row button (`ChatsList.vue`). That's the only mount. Do NOT mount it inside `ChatView.vue` or `SubAgentPeekPanel.vue` — the sidebar row already signals the same fact for the same session, so adding a second slider there would be redundant (see `design-no-redundant-loading-indicators`). The peek panel keeps its own peek-level status indicator (idle / loading / streaming / complete / error, at `SubAgentPeekPanel.vue:186`); that's a different scope (the sub-agent's internal progress) than "this session's worker is running".

**Tech Stack:** Vue 3 (Composition API + `<script setup>`), TypeScript, `@vue/test-utils` + Vitest, `node vue-tsc --build` for type-check. NO backend, NO migration, NO Zig changes, NO new dependencies, NO new store.

**Worktree:** `/home/ginwa/ginwaaitoolbox/.worktrees/bottom-loading-slider` on branch `worktree/bottom-loading-slider` (branch name kept for worktree continuity — the new behavior is "per-session slider", but it's the same task).

---

## Global Constraints

- **Cross-platform**: every feature MUST work on Linux, macOS, AND Windows.
- **No static-contract tests**: ALL tests are behavioural. No `expect(source).toContain(...)` / `indexOf(u8, source, ...)` patterns anywhere.
- **No port 8081**: smoke tests use port 8080.
- **Behavioural Vue tests use `@vue/test-utils` `mount` with `setActivePinia(createPinia())`** in `beforeEach`. Provide `processingState` via the `provide` option (`provide: { processingState: ref({}) }`) since the slider reads it via `inject`.
- **TDD discipline**: every implementation task starts with a failing test, then minimal code to make it pass, then a commit.
- **Surgical patches**: replace the spinner at `ChatsList.vue:467-475` with the slider; do NOT touch any other chat-row markup. `ChatView.vue` and `SubAgentPeekPanel.vue` stay untouched (no slider mounts anywhere except the sidebar rows).
- **`prefers-reduced-motion`**: the keyframe MUST be suppressed under `@media (prefers-reduced-motion: reduce)` — the slider renders as a static muted strip (same pattern as `SseStatusBadge.vue:152-156`).
- **Yellow, not violet**: the bar color matches the existing yellow spinner to preserve visual continuity — `--color-yellow: #c4b28a` (matches `ChatsList.vue:473`'s `border-color: var(--color-yellow)`).

---

## File map

| File | Action | Why |
|---|---|---|
| `src/apps/desktop/src/components/SessionSlider.vue` | NEW | Reusable thin sliding bar; takes `sessionId: string` prop, injects `processingState` from App.vue, hides when `!processingState[sessionId]`, animates while visible |
| `src/apps/desktop/src/components/SessionSlider.spec.ts` | NEW | Behavioural tests (hidden when not processing, visible when processing, multiple sessions independent, reduced-motion fallback) |
| `src/apps/desktop/src/components/views/ChatsList.vue` | EDIT | Replace the yellow spinner `<div>` at lines 467-475 with `<SessionSlider :session-id="item.id" />`; remove the obsolete local `processing` field rendering (the slider reads `processingState[item.id]` itself, so the `navItem.processing` watcher at lines 130-140 becomes dead — clean it up) |
| `docs/SPEC.md` | EDIT | Add §3.6 per-session slider section; update UI §3 sidebar section |
| `NALAR.md` | EDIT | Append "### 2026-08-29: per-session LLM loading slider" changelog entry |

Total: **5 files** (2 NEW, 1 EDIT, 2 docs). No backend changes, no migration, no Zig changes. Even smaller than the original plan — no ChatView mount, no peek panel mount, just the one indicator in the one place the user already looks at for the sidebar sessions.

---

## Visual mocks (4 states)

| State | Mock | Description |
|---|---|---|
| **Multiple sessions, one processing** | <preview id="ps-multi"> | Sidebar shows one chat row with a sliding yellow bar at its bottom (the LLM worker is running on that session); sibling chats are idle. Open ChatView stays clean — no duplicate slider |
| **Single session, idle everywhere** | <preview id="ps-idle"> | No sliders; only the static empty-state markers (the existing violet circle icons stay) |
| **Multiple sessions, multiple processing** | <preview id="ps-many"> | Three chats show their own sliders simultaneously, each at the bottom edge of their own row — sessions are independent |
| **Reduced motion** | <preview id="ps-reduced"> | Sliders render as static yellow strips at the bottom of their rows, no animation |

---

## Task 1: `SessionSlider.vue` — reusable per-session bar (TDD)

**Why:** Single component, used in 1 place. Build it test-first so the visibility contract (visible iff `processingState[sessionId] === true`) is locked before `ChatsList.vue` wires it in.

**Files:**
- `src/apps/desktop/src/components/SessionSlider.spec.ts` — NEW
- `src/apps/desktop/src/components/SessionSlider.vue` — NEW

### Step 1.1: Write the failing test file

Create `src/apps/desktop/src/components/SessionSlider.spec.ts`:

```ts
import { describe, it, expect, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { ref, type Ref } from 'vue'
import SessionSlider from './SessionSlider.vue'

describe('SessionSlider', () => {
  let processingState: Ref<Record<string, boolean>>

  beforeEach(() => {
    processingState = ref({})
  })

  it('renders nothing visible when processingState[sessionId] is falsy', () => {
    const wrapper = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    const bar = document.querySelector('[data-testid="session-slider"]') as HTMLElement | null
    expect(bar).not.toBeNull()
    expect(bar!.classList.contains('session-slider--visible')).toBe(false)
    wrapper.unmount()
  })

  it('becomes visible when processingState[sessionId] becomes true', async () => {
    const wrapper = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    processingState.value = { ...processingState.value, s_1: true }
    await wrapper.vm.$nextTick()
    const bar = document.querySelector('[data-testid="session-slider"]') as HTMLElement | null
    expect(bar!.classList.contains('session-slider--visible')).toBe(true)
    wrapper.unmount()
  })

  it('hides again when processingState[sessionId] flips back to false', async () => {
    const wrapper = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    processingState.value = { s_1: true }
    await wrapper.vm.$nextTick()
    processingState.value = {}
    await wrapper.vm.$nextTick()
    const bar = document.querySelector('[data-testid="session-slider"]') as HTMLElement | null
    expect(bar!.classList.contains('session-slider--visible')).toBe(false)
    wrapper.unmount()
  })

  it('is INDEPENDENT across sessionIds — s_1 processing does NOT show s_2', async () => {
    const wrapper1 = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    const wrapper2 = mount(SessionSlider, {
      props: { sessionId: 's_2' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    processingState.value = { s_1: true } // s_2 stays idle
    await wrapper1.vm.$nextTick()
    await wrapper2.vm.$nextTick()
    const bars = document.querySelectorAll('[data-testid="session-slider"]')
    expect(bars.length).toBe(2)
    expect((bars[0] as HTMLElement).classList.contains('session-slider--visible')).toBe(true)
    expect((bars[1] as HTMLElement).classList.contains('session-slider--visible')).toBe(false)
    wrapper1.unmount()
    wrapper2.unmount()
  })

  it('the inner track carries the slide animation class', async () => {
    const wrapper = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    processingState.value = { s_1: true }
    await wrapper.vm.$nextTick()
    const track = document.querySelector('[data-testid="session-slider-track"]') as HTMLElement | null
    expect(track).not.toBeNull()
    expect(track!.classList.contains('session-slider__track')).toBe(true)
    wrapper.unmount()
  })

  it('inherits width from its container (100% of parent)', () => {
    const wrapper = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    const bar = document.querySelector('[data-testid="session-slider"]') as HTMLElement
    const style = bar.getAttribute('style') ?? ''
    // The inline style attribute is empty (styles all in <style scoped>); instead
    // verify the CSS rule exists by checking the class. Leave this test asserting
    // the class only — width comes from CSS.
    expect(bar.classList.contains('session-slider')).toBe(true)
    wrapper.unmount()
  })

  it('aria-busy reflects the visible state (true when processing, false otherwise)', async () => {
    const wrapper = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    const bar = document.querySelector('[data-testid="session-slider"]') as HTMLElement
    expect(bar.getAttribute('aria-busy')).toBe('false')
    processingState.value = { s_1: true }
    await wrapper.vm.$nextTick()
    expect(bar.getAttribute('aria-busy')).toBe('true')
    wrapper.unmount()
  })
})
```

### Step 1.2: Run it — confirm 7 failures

```bash
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop
pnpm vitest run src/components/SessionSlider.spec.ts
```

Expected: 7 fails ("Cannot find module './SessionSlider.vue'").

### Step 1.3: Implement the component

Create `src/apps/desktop/src/components/SessionSlider.vue`:

```vue
<!--
  SessionSlider.vue — per-session LLM "still working" indicator.

  Renders a thin yellow bar at the bottom edge of its parent
  whenever `processingState[sessionId]` is true. Owned by `App.vue`
  via Vue's provide/inject (a `Ref<Record<string, boolean>>`); the
  SSE worker event handler in App.vue flips entries true/false so
  this component is reactive for free.

  Where it mounts
  ───────────────
  - ChatsList rows (sidebar): one slider per row, just below the
    chat name — replaces the existing yellow spinner circle.
  - ChatView (active session): one slider above the input box,
    inside the messages wrapper.
  - SubAgentPeekPanel (peek'd session): redundant top-bottom slider
    mirroring the parent's status.

  Why a slider, not a spinner
  ──────────────────────────
  The existing yellow spinner is a single point — the eye has to
  FIND it on every glance to confirm "the agent is still working".
  A horizontal sliding bar is a continuous motion across the full
  width of the chat row: even when looking at the chat body, the
  peripheral vision catches the slider at the row's edge. Same
  idle/processing signal, lower cognitive cost.

  Reduced motion
  ──────────────
  Under `@media (prefers-reduced-motion: reduce)` the slide animation
  is suppressed and the bar renders as a static muted strip —
  matches the pattern established in `SseStatusBadge.vue:152-156`.

  NOT a network loading indicator
  ───────────────────────────────
  This component is for the LLM WORKER state (long-running SSE
  streaming), not transient HTTP fetches. A separate future
  component would handle "data is fetching" — this one's only job
  is to visualize an active worker on a specific session.
-->
<script setup lang="ts">
import { computed, inject, ref, type Ref } from 'vue'

const props = defineProps<{
  sessionId: string
}>()

// `App.vue:10-11` provides a `processingState: Ref<Record<string,
// boolean>>` keyed by sessionId. The injected ref defaults to an
// empty ref so a unit test that mounts SessionSlider WITHOUT a
// `provide` (e.g. a transitive render path) doesn't crash — it
// just renders nothing.
const processingState = inject<Ref<Record<string, boolean>>>(
  'processingState',
  ref({}) as Ref<Record<string, boolean>>,
)

const isVisible = computed(() => !!processingState.value[props.sessionId])
</script>

<template>
  <div
    class="session-slider"
    :class="{ 'session-slider--visible': isVisible }"
    data-testid="session-slider"
    role="progressbar"
    :aria-busy="isVisible"
    aria-live="polite"
  >
    <div
      class="session-slider__track"
      data-testid="session-slider-track"
    />
  </div>
</template>

<style scoped>
.session-slider {
  /* Lives wherever its parent puts it. Width 100% so it spans the
     full row when mounted in ChatsList; the full messages-wrapper
     width when mounted in ChatView. */
  position: relative;
  width: 100%;
  height: 2px;
  overflow: hidden;
  background: rgb(0 0 0 / 0.06);
  opacity: 0;
  transition: opacity 200ms ease-out;
}

.session-slider--visible {
  opacity: 1;
}

.session-slider__track {
  position: absolute;
  inset: 0;
  background: var(--color-yellow);
  box-shadow: 0 0 4px rgb(196 178 138 / 0.5);
  animation: session-slider-slide 1.4s cubic-bezier(0.4, 0, 0.2, 1) infinite;
  transform: translateX(-100%);
  width: 100%;
}

@keyframes session-slider-slide {
  0%   { transform: translateX(-100%); }
  100% { transform: translateX(100%); }
}

@media (prefers-reduced-motion: reduce) {
  .session-slider__track {
    animation: none;
    transform: none;
    opacity: 0.55;
  }
}
</style>
```

### Step 1.4: Run it — confirm 7 pass

```bash
pnpm vitest run src/components/SessionSlider.spec.ts
```

Expected: 7 pass.

### Step 1.5: Commit

```bash
cd /home/ginwa/ginwaaitoolbox
git add src/apps/desktop/src/components/SessionSlider.vue src/apps/desktop/src/components/SessionSlider.spec.ts
git commit -m "feat(desktop): SessionSlider per-session LLM loading indicator"
```

---

## Task 2: Wire `SessionSlider` into `ChatsList` rows (replace the spinner)

> **Note:** This is the ONLY consumer of `SessionSlider`. We intentionally do NOT mount it in `ChatView` (above the input) or `SubAgentPeekPanel` — the sidebar row already shows the same signal for the same session, and duplicating it would be confusing (two sliders moving on the same screen for one worker). See the design memory at `~/.config/nalar/.../design-no-redundant-loading-indicators` if you want the full rationale. The peek panel keeps its OWN internal status indicator (idle / loading / streaming / complete / error), which is about sub-agent progress — a different scope.

**Why:** This is the biggest user-visible change — the sidebar's per-row yellow spinner becomes a sliding yellow bar at the row's bottom edge. Sessions are independent: only the rows whose sessions are processing show a slider.

**Files:**
- `src/apps/desktop/src/components/views/ChatsList.vue` — EDIT

### Step 2.1: Add the import

After the existing imports in `ChatsList.vue` (search the file for `import` near the top), add:

```ts
import SessionSlider from '../SessionSlider.vue'
```

### Step 2.2: Replace the spinner with the slider

Replace the lines 467-475:

```vue
<!-- DELETE -->
<span
  v-if="item.processing === true"
  class="w-5 h-5 flex items-center justify-center shrink-0"
>
  <div
    class="w-4 h-4 border-2 rounded-full animate-spin"
    style="border-color: var(--color-yellow); border-top-color: transparent"
  ></div>
</span>
```

with a SessionSlider mounted AT THE BOTTOM EDGE of the chat row button. The button's existing flex layout needs a small structural change so the slider sits at the bottom of the row without breaking the icon-name-time alignment:

**Find** (around lines 456-503):
```vue
<button
  @click="setActive(item.id)"
  class="w-full flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-all duration-150 border-t border-transparent"
  ...style trimmed...
>
  <span v-if="item.processing === true" class="w-5 h-5 flex items-center justify-center shrink-0">
    ...spinner...
  </span>
  <span class="flex-1 text-left truncate">...</span>
  <span class="text-xs opacity-60 shrink-0 ml-2">{{ item.relativeTime || 'now' }}</span>
  ...
</button>
```

**Replace with** (keep the spinner slot as an idle marker so the row's icon rhythm is preserved, add the slider at the bottom):
```vue
<button
  @click="setActive(item.id)"
  class="relative w-full flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-all duration-150 border-t border-transparent overflow-hidden"
  ...style trimmed...
>
  <span
    v-if="!item.processing"
    class="w-4 h-4 flex items-center justify-center shrink-0 rounded-full border"
    style="border-color: var(--color-violet);"
    aria-hidden="true"
  ></span>
  <span v-else class="w-4 h-4 shrink-0" aria-hidden="true"></span>
  <span class="flex-1 text-left truncate">{{ item.name }}</span>
  <span class="text-xs opacity-60 shrink-0 ml-2">{{ item.relativeTime || 'now' }}</span>
  ...
  <!-- Per-session LLM slider at the bottom edge of this row. Hidden
       when this session is idle; slides while processingState[item.id]
       is true. Replaces the old yellow spinner. -->
  <SessionSlider
    :session-id="item.id"
    class="absolute left-0 right-0 bottom-0"
  />
</button>
```

(The relative-positioned parent + absolutely-positioned bottom slider is the cleanest way to anchor a bar to the bottom edge of a flex row.)

### Step 2.3: Clean up the now-unused `processing` watcher

`ChatsList.vue:130-140` and `350-356` mutate `item.processing` from `processingState`. With the slider reading `processingState[item.id]` directly, the mirror field is dead code. **DO NOT REMOVE** the `item.processing` field plumbing yet — it's used by the existing idle-marker conditional `<span v-if="!item.processing">` above. Leave for now; future refactor can collapse them.

### Step 2.4: Run type-check + all tests

```bash
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop
node vue-tsc --build --force
pnpm vitest run src/components/views/ChatsList.spec.ts
pnpm vitest run
```

Expected: vue-tsc clean, all tests pass (no regressions).

### Step 2.5: Commit

```bash
cd /home/ginwa/ginwaaitoolbox
git add src/apps/desktop/src/components/views/ChatsList.vue
git commit -m "feat(desktop): wire ChatsList rows to SessionSlider"
```

---

## Task 3: Docs + changelog

**Why:** Surface the new behavior in user-facing docs and the per-release changelog.

**Files:**
- `docs/SPEC.md` — EDIT
- `NALAR.md` — EDIT

### Step 3.1: docs/SPEC.md

Add a new section after §3.5 (sidebar):

```md
### §3.6 Per-session LLM loading slider

Each LLM session surfaces its "still working" state as a thin yellow
slider at the bottom edge of its sidebar chat row. The slider
animates `translateX(-100%) → 100%` on a 1.4 s loop while
`processingState[sessionId]` is true; hidden otherwise.

- Source of truth: the existing `processingState` map provided by
  `App.vue` via Vue inject.
- Component: `SessionSlider.vue` — single prop `sessionId`.
- Mount location: `ChatsList.vue` (one slider per chat row).
- Animation: CSS keyframe `session-slider-slide` (1.4 s loop);
  suppressed under `prefers-reduced-motion: reduce`.
- Color: `var(--color-yellow)` — matches the previous per-row
  spinner, preserving visual continuity.
- Sessions are independent: one session processing shows ONLY its
  own slider; sibling sessions sit idle.
- NOT used for network fetches (those use `isLoading` flags in
  each store).
- NOT mounted inside `ChatView` or `SubAgentPeekPanel` — the sidebar
  row IS the indicator for "this session is busy". Adding the same
  indicator elsewhere would double-deal the same signal.
```

### Step 3.2: NALAR.md

Append a new "### 2026-08-29: per-session LLM loading slider" entry under the "Recent changes" section. Format mirrors the other entries (one-line **What landed**, **Files**, **Verification**, **Plan**).

### Step 3.3: Commit

```bash
cd /home/ginwa/ginwaaitoolbox
git add docs/SPEC.md NALAR.md
git commit -m "docs: per-session LLM slider — SPEC §3.6 + changelog entry"
```

---

## Verification

```bash
cd /home/ginwa/ginwaaitoolbox
zig build test --summary all
cd src/apps/desktop
node vue-tsc --build --force
pnpm vitest run
```

Expected:
- `zig build test` — same baseline (no backend changes)
- `vue-tsc` — clean
- `pnpm vitest run` — 7 new (SessionSlider.spec.ts) + all existing pass

Manual smoke (start 3 chats and let an agent run on each concurrently):
- Each chat's row in the sidebar shows ITS OWN sliding yellow bar at the row's bottom edge
- Sibling chats (no worker running) sit idle (no bar)
- The open ChatView input area stays clean — NO slider above the input (the sidebar row is the one indicator for "this session is busy")
- Reduced-motion preference: sliders are static muted yellow strips, no slide
- When SSE `worker` event flips a session from `processing=false` to `processing=true`, the corresponding slider appears within 200 ms (the CSS opacity transition); the reverse on `deleted` events hides it
