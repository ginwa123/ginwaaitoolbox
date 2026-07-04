# Preview Panel Resize — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the right-side `PreviewSidePanel.vue` drag-resizable via a 1px handle on its left edge, persist the chosen width in localStorage, and have no upper bound so the panel can fill the screen.

**Architecture:** Self-contained change inside `PreviewSidePanel.vue`. The component owns a `localWidth` ref clamped only on the low side (MIN 240px, no MAX). A 1px-wide handle absolutely positioned on the panel's left edge registers `mousemove` + `mouseup` on `document` (NOT on the handle itself — fast drags outrun the handle). One `localStorage` write per gesture on `mouseup`. Mirrors the proven `RightSidebar.vue` resize pattern. No parent (`ChatView.vue`) changes, no backend changes.

**Tech Stack:** Vue 3 (`<script setup lang="ts">`), TypeScript, localStorage, vitest + @vue/test-utils + jsdom.

**Reference spec:** `docs/plans/2026-07-04-preview-panel-resize-design.md` (the design doc this plan implements).

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `src/apps/desktop/src/components/PreviewSidePanel.vue` | modify | Add width state + drag handlers + handle `<div>` + inline-style width |
| `src/apps/desktop/src/__tests__/previewSidePanel.spec.ts` | modify | Add 5 tests for resize behavior |

No new files. No parent changes. No backend changes.

---

## Chunk 1: PreviewPanel resize (4 tasks)

### Task 1: Add the 5 resize tests (all should fail against current code)

**Files:**
- Modify: `src/apps/desktop/src/__tests__/previewSidePanel.spec.ts:15-19` (add `beforeEach` for localStorage cleanup)
- Modify: `src/apps/desktop/src/__tests__/previewSidePanel.spec.ts:91` (inside the `describe('PreviewSidePanel', ...)` block — add 5 new tests at the bottom of the describe, before the closing `})`)

- [ ] **Step 1: Add `beforeEach` to clear localStorage**

In `src/apps/desktop/src/__tests__/previewSidePanel.spec.ts`, find:

```ts
describe('PreviewSidePanel', () => {
  it('renders nothing when previews array is empty', () => {
```

and insert **before** the first `it(...)`:

```ts
describe('PreviewSidePanel', () => {
  // Clear localStorage before each test so the resize-persistence
  // tests don't see stale values from prior tests. The 12 tests
  // above don't touch localStorage but they aren't affected by
  // a clear (the panel doesn't read localStorage today).
  beforeEach(() => {
    localStorage.clear()
  })

  it('renders nothing when previews array is empty', () => {
```

- [ ] **Step 2: Add the 5 new tests at the bottom of the describe block**

Open `src/apps/desktop/src/__tests__/previewSidePanel.spec.ts`, scroll to the very end of the `describe('PreviewSidePanel', ...)` block (the closing `})` of describe is around line 374). Insert **before** the closing `})` of describe, **after** the last `it(...)`:

```ts
  // ─── Resize behavior (preview-panel-resize design) ─────────────────────
  //
  // These 5 tests cover the self-contained resize interaction:
  //   - Default 480px width when no localStorage value
  //   - Load from localStorage on mount
  //   - Persist to localStorage on drag release
  //   - Clamp at MIN_WIDTH = 240 when dragged past the bound
  //   - Hide the resize handle when the panel is collapsed
  //
  // Pattern follows AppLayout.kanban.spec.ts:384-468 (kanban column
  // resize persistence test). Dispatch mousemove/mouseup on
  // document.body (jsdom's closest proxy to `document`).
  //
  // The current (pre-implementation) code uses Tailwind `w-[480px]`
  // for the width, NOT an inline `style.width`, so these tests all
  // FAIL on current code:
  //   - Tests 1, 2, 4 read `style.width` which is "" on current code
  //   - Test 3 reads localStorage which is "" on current code (no persist)
  //   - Test 5 looks for `[data-testid="preview-resize-handle"]` which
  //     doesn't exist on current code

  it('uses 480px default width when no localStorage value exists', () => {
    const wrapper = mount(PreviewSidePanel, {
      props: { previews: [makePreview()] },
    })
    const panel = wrapper.find('[data-testid="preview-side-panel"]')
    expect(panel.exists()).toBe(true)
    expect((panel.element as HTMLElement).style.width).toBe('480px')
  })

  it('loads width from localStorage on mount', () => {
    localStorage.setItem('nalar-preview-panel-width', '600')
    const wrapper = mount(PreviewSidePanel, {
      props: { previews: [makePreview()] },
    })
    const panel = wrapper.find('[data-testid="preview-side-panel"]')
    expect((panel.element as HTMLElement).style.width).toBe('600px')
  })

  it('persists the new width to localStorage on drag release', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: { previews: [makePreview()] },
    })
    const handle = wrapper.find('[data-testid="preview-resize-handle"]')
    expect(handle.exists()).toBe(true)
    // mousedown at clientX=500 sets startX=500, startWidth=480 (default).
    // mousemove at clientX=700 (cursor moved RIGHT by 200px): the panel
    // is on the right, handle is on the LEFT edge, so moving the
    // cursor RIGHT shrinks the panel. delta = startX - clientX = -200,
    // newWidth = max(240, 480 + (-200)) = 280. Assert that stored
    // value is in [240, 480) — clamped and shrank from default.
    await handle.trigger('mousedown', { clientX: 500 })
    document.body.dispatchEvent(
      new MouseEvent('mousemove', { clientX: 700, bubbles: true }),
    )
    document.body.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }))
    await nextTick()
    const stored = localStorage.getItem('nalar-preview-panel-width')
    expect(stored).not.toBeNull()
    const parsed = parseInt(stored!, 10)
    expect(parsed).toBeGreaterThanOrEqual(240)
    expect(parsed).toBeLessThan(480)
  })

  it('clamps the width at MIN_WIDTH = 240 when dragged past the bound', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: { previews: [makePreview()] },
    })
    const handle = wrapper.find('[data-testid="preview-resize-handle"]')
    // Drag the cursor far right (clientX 500 -> 5000 = +4500px right).
    // The handle's drag math would produce newWidth = 480 - 4500 = -4020,
    // which must clamp to MIN_WIDTH = 240. The clamp also gets persisted.
    await handle.trigger('mousedown', { clientX: 500 })
    document.body.dispatchEvent(
      new MouseEvent('mousemove', { clientX: 5000, bubbles: true }),
    )
    document.body.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }))
    await nextTick()
    const panel = wrapper.find('[data-testid="preview-side-panel"]')
    expect((panel.element as HTMLElement).style.width).toBe('240px')
    expect(localStorage.getItem('nalar-preview-panel-width')).toBe('240')
  })

  it('hides the resize handle when the panel is collapsed', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: { previews: [makePreview()] },
    })
    expect(wrapper.find('[data-testid="preview-resize-handle"]').exists()).toBe(true)
    await wrapper.find('button[title="Collapse panel"]').trigger('click')
    await nextTick()
    expect(wrapper.find('[data-testid="preview-resize-handle"]').exists()).toBe(false)
  })
})
```

Note the closing `})` of the `describe` block is at the very end — the inserted code already includes the closing `})` for describe.

- [ ] **Step 3: Run the new tests, verify all 5 fail**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run previewSidePanel 2>&1 | tail -n 30`
Expected: 12 pass, 5 fail. The 5 failures are:
- Test 1 (`uses 480px default width...`): fails with `expected '' to be '480px'`
- Test 2 (`loads width from localStorage...`): fails with `expected '' to be '600px'`
- Test 3 (`persists the new width...`): fails with `expected null to be not null` OR `Unable to find [data-testid="preview-resize-handle"]`
- Test 4 (`clamps the width at MIN_WIDTH...`): fails with `Unable to find [data-testid="preview-resize-handle"]`
- Test 5 (`hides the resize handle...`): fails with `Unable to find [data-testid="preview-resize-handle"]`

- [ ] **Step 4: Commit the failing tests**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/preview-panel-resize
git add src/apps/desktop/src/__tests__/previewSidePanel.spec.ts
git commit -m "test(preview): add 5 failing tests for resize behavior

Red phase of TDD for the preview-panel-resize feature. All 5 tests
fail against the current (fixed w-[480px]) implementation:
  1. default width = 480px when no localStorage
  2. load width from localStorage on mount
  3. persist new width on drag release
  4. clamp at MIN_WIDTH = 240
  5. hide handle when collapsed

Pattern follows AppLayout.kanban.spec.ts:384-468."
```

---

### Task 2: Add width state (constants, localWidth ref, localStorage helpers)

**Files:**
- Modify: `src/apps/desktop/src/components/PreviewSidePanel.vue:2` (add `onUnmounted` to the import line)
- Modify: `src/apps/desktop/src/components/PreviewSidePanel.vue` (insert new constants + helpers + ref after the existing imports, before `interface PreviewItem`)

- [ ] **Step 1: Add the width constants and helpers**

Open `src/apps/desktop/src/components/PreviewSidePanel.vue`. The current imports are (lines 1-4):

```ts
<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { marked } from 'marked'
import { tryUnwrapToolOutput } from '@/helpers/unwrapToolOutput'
```

Change line 2 to add `onUnmounted`:

```ts
import { computed, ref, watch, onUnmounted } from 'vue'
```

Then, **before** the `interface PreviewItem` declaration (currently at line 6), insert:

```ts
// ─── Resize state (preview-panel-resize design) ─────────────────────────
//
// Self-contained resize: the component owns its width state + drag
// listeners + localStorage persistence. No parent (ChatView.vue)
// coordination needed. Mirrors the RightSidebar.vue resize pattern
// (src/apps/desktop/src/components/RightSidebar.vue:20-64).
//
// Bounds rationale:
//   - MIN 240: below this, markdown/code content becomes unreadable
//     and the tab strip / header overlap. Matches RightSidebar's 200
//     floor + a small margin for the header.
//   - NO UPPER BOUND: user explicitly requested "full screen" —
//     the panel can grow to fill the entire viewport. The chat column
//     (flex-1 min-w-0) absorbs the rest and shrinks to 0; the user
//     recovers via the existing chevron collapse button.
const MIN_PREVIEW_WIDTH = 240
const DEFAULT_PREVIEW_WIDTH = 480
const PREVIEW_WIDTH_STORAGE_KEY = 'nalar-preview-panel-width'

const loadPreviewPanelWidth = (): number => {
  if (typeof localStorage === 'undefined') return DEFAULT_PREVIEW_WIDTH
  const saved = localStorage.getItem(PREVIEW_WIDTH_STORAGE_KEY)
  if (saved === null) return DEFAULT_PREVIEW_WIDTH
  const parsed = parseInt(saved, 10)
  if (isNaN(parsed) || parsed < MIN_PREVIEW_WIDTH) return DEFAULT_PREVIEW_WIDTH
  return parsed
}

const savePreviewPanelWidth = (width: number) => {
  if (typeof localStorage === 'undefined') return
  try {
    localStorage.setItem(PREVIEW_WIDTH_STORAGE_KEY, String(width))
  } catch {
    // localStorage may throw in private-mode or quota-exceeded
    // scenarios; silently ignore so the in-memory drag still works.
    // Matches AppLayout.vue:599-603 (kanban-column resize pattern).
  }
}

```

- [ ] **Step 2: Add the `localWidth` ref and drag-handler refs**

Insert **after** the `savePreviewPanelWidth` function (just inserted) and **before** `interface PreviewItem`:

```ts
const localWidth = ref(loadPreviewPanelWidth())

// Resize interaction state. The drag math is the standard
// `startWidth + (startX - clientX)` formula — moving the cursor
// LEFT grows the panel (panel is on the right, handle on left edge).
const isResizing = ref(false)
const resizeStartX = ref(0)
const resizeStartWidth = ref(0)

const startResize = (e: MouseEvent) => {
  isResizing.value = true
  resizeStartX.value = e.clientX
  resizeStartWidth.value = localWidth.value
  // Document-level listeners — NOT on the handle — so a fast drag
  // doesn't outrun the handle. Pattern matches Sidebar.vue:200-225
  // and AppLayout.vue:552-604 (kanban-column resize).
  document.addEventListener('mousemove', handleResize)
  document.addEventListener('mouseup', stopResize)
  document.body.style.cursor = 'ew-resize'
  document.body.style.userSelect = 'none'
}

const handleResize = (e: MouseEvent) => {
  if (!isResizing.value) return
  const delta = resizeStartX.value - e.clientX
  // No upper clamp — user wants "full screen". Only floor at MIN.
  const newWidth = Math.max(MIN_PREVIEW_WIDTH, resizeStartWidth.value + delta)
  localWidth.value = newWidth
}

const stopResize = () => {
  if (!isResizing.value) return
  isResizing.value = false
  document.removeEventListener('mousemove', handleResize)
  document.removeEventListener('mouseup', stopResize)
  document.body.style.cursor = ''
  document.body.style.userSelect = ''
  // Persist on release (not during drag — dragging fires 60+ events/sec
  // and localStorage.setItem is synchronous + slow enough to noticeably
  // drag the resize interaction). One write per gesture. Matches
  // AppLayout.vue:585-604.
  savePreviewPanelWidth(localWidth.value)
}

// Cleanup: remove listeners even if a drag is mid-gesture (e.g. user
// navigates away mid-drag). Prevents orphan document listeners.
// Matches Sidebar.vue:227-229.
onUnmounted(() => {
  stopResize()
})

```

- [ ] **Step 3: Update the template to use inline style instead of `w-[480px]`**

Open `src/apps/desktop/src/components/PreviewSidePanel.vue` and find the root `<div>` of the panel (currently line 152-157):

```vue
  <div
    v-if="previews.length > 0"
    class="preview-side-panel flex flex-col border-l border-[var(--color-border)] bg-[var(--semantic-bg)] transition-all duration-200"
    :class="isCollapsed ? 'w-8' : 'w-[480px]'"
    data-testid="preview-side-panel"
  >
```

Change the `:class` line to also set the inline `width` style when expanded:

```vue
  <div
    v-if="previews.length > 0"
    class="preview-side-panel flex flex-col border-l border-[var(--color-border)] bg-[var(--semantic-bg)] transition-all duration-200"
    :class="isCollapsed ? 'w-8' : 'shrink-0'"
    :style="isCollapsed ? undefined : { width: localWidth + 'px' }"
    data-testid="preview-side-panel"
  >
```

(`shrink-0` so flex doesn't try to grow the panel beyond its `width`; the explicit `width` style does the sizing.)

- [ ] **Step 4: Run tests, verify tests 1, 2, 4 partially pass**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run previewSidePanel 2>&1 | tail -n 30`
Expected: 14 pass (12 existing + test 1 + test 2), 3 fail (test 3 — no handle yet, test 4 — no handle yet, test 5 — no handle yet).

Why tests 1 and 2 pass now: the `localWidth` ref loads from localStorage correctly, and the template's inline style applies it.

Why tests 3, 4, 5 still fail: there's no resize handle `<div>` in the template yet, so `wrapper.find('[data-testid="preview-resize-handle"]')` returns empty.

- [ ] **Step 5: Commit the width state + template change**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/preview-panel-resize
git add src/apps/desktop/src/components/PreviewSidePanel.vue
git commit -m "feat(preview): add resize state, drag handlers, and localStorage persistence

Green phase for tests 1-2 (default width + load from localStorage).
Tests 3-5 still fail — the resize handle <div> lands in Task 3.

- localWidth ref initialized from loadPreviewPanelWidth() (defaults to 480)
- startResize / handleResize / stopResize use document-level mousemove
  + mouseup listeners (Sidebar.vue / AppLayout.vue pattern)
- No upper clamp on width — user requested 'full screen' capability
- onUnmounted(stopResize) cleans up listeners on unmount
- Template swaps Tailwind w-[480px] for inline style.width with shrink-0
  so flex doesn't try to grow the panel beyond its width"
```

---

### Task 3: Add the resize handle `<div>` to the template

**Files:**
- Modify: `src/apps/desktop/src/components/PreviewSidePanel.vue` template (insert handle `<div>` after the header `<div>`, only when not collapsed)

- [ ] **Step 1: Find the header `<div>` inside `<template v-else>`**

The relevant section is around line 165-170. The header looks like:

```vue
    <template v-else>
      <div class="flex items-center gap-1 px-2 py-1 border-b border-[var(--color-border)]">
        <button class="px-1 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] hover:text-[var(--color-violet)] text-sm" title="Collapse panel" @click="toggleCollapse">&#9664;</button>
        <span class="text-[var(--color-violet)] font-semibold text-xs flex-1 truncate">Preview</span>
        <span class="text-[0.65rem] text-[var(--semantic-text-muted)]">{{ activeIndex + 1 }} of {{ previews.length }}</span>
        <button class="px-1 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] hover:text-red-500" title="Dismiss panel" @click="toggleCollapse">&#10005;</button>
      </div>
```

- [ ] **Step 2: Insert the resize handle `<div>` right after the header**

Add this directly after the closing `</div>` of the header (and before the `<div v-if="previews.length > 1">` tab strip block):

```vue
      <!--
        Resize handle: 1px-wide vertical bar on the LEFT edge of the
        panel (panel is on the right; handle on left → dragging left
        grows the panel). Colors match RightSidebar.vue:208-211:
        transparent at rest, violet @ 30% on hover, violet @ 50%
        during active drag. Hidden when collapsed (nothing to drag).
      -->
      <div
        v-if="!isCollapsed"
        data-testid="preview-resize-handle"
        class="absolute top-0 left-0 h-full w-1 cursor-ew-resize z-10 transition-colors"
        :class="isResizing ? 'bg-[var(--color-violet)]/50' : 'bg-transparent hover:bg-[var(--color-violet)]/30'"
        @mousedown="startResize"
      />
```

- [ ] **Step 3: Run all 17 tests, verify all pass**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run previewSidePanel 2>&1 | tail -n 20`
Expected: 17/17 pass (12 existing + 5 new). Zero failures.

- [ ] **Step 4: Run type-check + full build to catch any TypeScript errors**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20`
Expected: build completes, `vue-tsc` reports 0 errors, `vite build` produces the bundle. No new errors vs the baseline.

If there are TS errors, fix them by editing the component (e.g. missing type imports, incorrect type annotation). Common issues: `onUnmounted` not imported (Task 2 step 1 adds it); the `loadPreviewPanelWidth`/`savePreviewPanelWidth` helpers need no explicit return type since they're inferred.

- [ ] **Step 5: Commit the resize handle**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/preview-panel-resize
git add src/apps/desktop/src/components/PreviewSidePanel.vue
git commit -m "feat(preview): add left-edge resize handle to PreviewSidePanel

1px-wide handle absolutely positioned on the panel's left edge,
matching RightSidebar.vue:208-211 colors:
  - transparent at rest
  - violet/30 on hover
  - violet/50 during active drag
  - cursor-ew-resize

Hidden via v-if when collapsed (nothing to drag). Green phase for
the remaining 3 tests (drag persist, MIN clamp, handle visibility).
All 17 tests pass."
```

---

### Task 4: Manual smoke verification + cleanup

- [ ] **Step 1: Clean up any stray `*.vue.js` files emitted by vue-tsc**

The project's `vue-tsc --build` step is known to emit `.js` files alongside `.ts/.vue` source files (per local memory `vue-tsc-build-emits-js-files`). These pollute `git status`. Run:

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/preview-panel-resize
git status -s
```

If you see any `.vue.js` or `.vue.d.ts` files, delete them:

```bash
find src/apps/desktop/src -name '*.vue.js' -o -name '*.vue.d.ts' | xargs rm -fv
```

Then re-check `git status -s` — should be clean (no `.vue.js` files).

- [ ] **Step 2: Final test + build pass**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5 && cd - && cd src/apps/desktop && timeout 120 bunx vitest run previewSidePanel 2>&1 | tail -n 10`
Expected: build succeeds, tests pass 17/17.

- [ ] **Step 3: Manual smoke test (optional, recommended)**

Open the desktop app, trigger a `show_preview` tool call from the agent (e.g. ask "show me a markdown preview"), and verify:
- Drag the LEFT edge of the preview panel LEFT → panel grows, chat shrinks.
- Drag RIGHT → panel shrinks.
- Drag far LEFT (e.g. all the way to the left of the screen) → preview fills the screen, chat is hidden.
- Click the existing `◀` chevron → preview collapses to `w-8`.
- Reload the page → preview width is preserved (matches the dragged value).
- `localStorage.getItem('nalar-preview-panel-width')` in DevTools shows the new integer.

If any step fails, fix and re-test before moving on.

- [ ] **Step 4: Final commit (if any cleanup was needed)**

If step 1 removed files that needed committing (none — they were build artifacts, ignored by git), no commit needed. Otherwise:

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/preview-panel-resize
git status -s
# Should be clean. If not, investigate.
```

---

## Verification

After all 4 tasks land:

1. `cd src/apps/desktop && timeout 120 bunx vitest run previewSidePanel` → 17/17 pass
2. `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20` → build succeeds, 0 vue-tsc errors
3. `git log --oneline main..HEAD` → 4 commits (test scaffolding, width state, handle, optional cleanup), each with a focused message
4. `git diff main..HEAD --stat` → only `src/apps/desktop/src/components/PreviewSidePanel.vue` (+~80 lines, -2 lines) and `src/apps/desktop/src/__tests__/previewSidePanel.spec.ts` (+~110 lines). No other files touched.
5. Manual smoke test (Task 4 step 3) passes: drag → persists → reload keeps width.

## Reference files (for the implementer)

- **Design doc** — `docs/plans/2026-07-04-preview-panel-resize-design.md` (the spec this plan implements)
- **Closest analog (right-side resize pattern)** — `src/apps/desktop/src/components/RightSidebar.vue:20-64` + handle at 207-211 + `:style="{ width: localWidth + 'px' }"` at line 204
- **Document-level listener + cleanup pattern** — `src/apps/desktop/src/components/Sidebar.vue:192-229`
- **localStorage persistence on release pattern** — `src/apps/desktop/src/components/AppLayout.vue:505-604` (kanban-column resize)
- **Test pattern for drag persist** — `src/apps/desktop/src/__tests__/AppLayout.kanban.spec.ts:384-468`

## Pitfalls (read before implementing)

- **Drag math direction** — panel is on right, handle on LEFT edge. `delta = startX - clientX` (NOT `clientX - startX`). Dragging cursor LEFT grows the panel; dragging cursor RIGHT shrinks it. See `RightSidebar.vue:45` for the proven formula.
- **Document listeners, not handle listeners** — `mousedown` on the handle adds `mousemove` + `mouseup` on `document`. Otherwise a fast drag outruns the handle and the cursor escapes the listener zone.
- **One persist per gesture** — `savePreviewPanelWidth` only fires on `mouseup`, not during `mousemove`. Dragging fires 60+ mousemove events/sec; persisting each one would noticeably lag the UI.
- **`onUnmounted` cleanup is mandatory** — without it, a route change mid-drag leaves orphan document listeners. Pattern from `Sidebar.vue:227-229`.
- **Mousemove handler must check `isResizing`** — `if (!isResizing.value) return;` at the top of `handleResize` prevents stale calls if the listener is somehow not removed.
- **Vue Test Utils + jsdom** — `wrapper.find` looks at the rendered DOM. Use `data-testid="preview-resize-handle"` selectors (not classes) for stability.
- **Dispatch events on `document.body`** — in jsdom, the document's mouse events are caught by `document.body.dispatchEvent(new MouseEvent('mousemove', { bubbles: true }))` (the closest proxy). Matches `AppLayout.kanban.spec.ts:421-424`.