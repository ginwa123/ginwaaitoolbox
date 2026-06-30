# Change Workspace Item Task to Card (Kanban-Only)

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render workspace-item tasks as **discrete "cards"** when they appear inside a kanban column, while preserving the existing compact **row** rendering for tasks in the sidebar's per-item expanded list. The change must affect **only kanban-type items** — folder/chat/memory items keep the row UX unchanged.

**Architecture:** Frontend-only. Introduce a `variant: 'row' | 'card'` prop on `WorkspaceItemTask.vue`. The default ('row') keeps the current behavior byte-for-byte so every other test, store action, and consumer is unaffected. The 'card' variant swaps in card-specific styling (more padding, bordered background, optional description preview) and re-lays-out the action icons. The single consumer of the 'card' variant is `KanbanCard.vue`, which already wraps `WorkspaceItemTask` for kanban tasks — it gains a `:variant="'card'"` binding. All other call sites (the sidebar `WorkspaceItem.vue`, the `WorkspaceList.vue` pinned/unpinned regions) keep the implicit 'row' default.

**Tech Stack:** Vue 3 + TypeScript + Pinia + Vitest (frontend only). No backend changes. No new dependencies. No API shape changes. No new files.

---

## Context

### Current state

- `WorkspaceItemTask.vue` is the per-task row component used in **two** distinct contexts today:
  1. **Sidebar list** — rendered inside the expanded workspace-item panel by `WorkspaceItem.vue:472` and `WorkspaceItem.vue:491` (pinned + unpinned regions). Inherited from a pre-2026-06 split; the row uses `class="flex items-center gap-2 px-3 py-1 rounded text-xs"` — a single-line, button-based compact row with hover-revealed action icons on the right.
  2. **Kanban column** — rendered inside each column by way of `KanbanCard.vue:84`, which wraps `<WorkspaceItemTask>` with a draggable div carrying the kanban-specific MIME type. Visually, the row's styling leaks through unchanged because `KanbanCard.vue` does not override any class — the same `px-3 py-1 text-xs` row appears as a "card" inside the column.

- The kanban board UX expects **cards** (Trello/Linear) — visually distinct, boxed, with title + optional body. Today's row-style rendering inside kanban columns reads as a "list of items in a box", which is technically functional but visually inconsistent with the column headers (which ARE card-like) and the well-known kanban idiom.

- `Task` already has an optional `description?: string` field (declared in both `stores/workspaces.ts:100` and `api/index.ts:174`). The backend already returns it for tasks created with a description (see `tasks_create.zig` request body via `api/index.ts:380`). It's currently unused by the UI — neither row nor card renders it. The card variant is the natural place to surface it.

### What's already in place

- Existing tests for `WorkspaceItemTask` (`workspaceItemTask*.spec.ts`, 7 files) cover the row variant exhaustively.
- Existing tests for `KanbanCard` (`KanbanCard.spec.ts:100` lines) cover the drag-MIME wiring.
- Existing tests for `KanbanView` and `KanbanColumn` cover the column layout, header, count badge, drop zones.
- `WorkspaceItemTask` already injects `processingState` (worker activity) — the card variant reuses the same ref.
- The `'row'` default makes the change additive and non-breaking: if the prop isn't passed (sidebar consumers), behavior is byte-identical to today.

### Out of scope

- Backend changes — no schema, no API, no migration.
- Inline editing of card description (would require a new dialog); we only **display** `description` if present.
- Re-ordering cards inside a column — separate feature (plan `2026-06-30-fix-kanban-drop-position.md` adds gap-based drop indicators; out of scope here).
- Per-card color / cover image / assignee avatars — different design decision; later.
- Pinning cards within a kanban column — same kanban_card_does not currently support a separate pinned subset; not in scope for this task.

---

## Design

### Decision 1 — variant prop, not CSS-only escape hatch

We add a `variant: 'row' | 'card'` prop with default `'row'`. The alternative — passing CSS via slot class — is harder to test (card-specific features like description rendering would need their own controlled visibility, and you'd duplicate "if card then render description" logic in 2+ files).

The variant prop **drives three independent concerns**:
1. **Outer container class** — `px-3 py-1 rounded text-xs` (row) vs `p-2.5 rounded-md bg-card-bg border` (card).
2. **Inner layout** — single flex row (row) vs column-stacked: name row above, description preview below (card).
3. **Description rendering** — hidden (row) vs rendered if non-empty (card).

### Decision 2 — when description is empty, fall back gracefully

Today `Task.description` is `string | undefined`. The kanban `createTask` (via `tasks_create.zig`) accepts it but it's NOT populated for `addTask` callers in the kanban context (verified in `AppLayout.vue:xxx`'s `handleKanbanAddTask` path — it doesn't pass a description). So most cards will have no description, and "card" rendering must look correct without one.

### Decision 3 — action icons stay right-aligned in both variants

In the **row**, the order is `[bullet] [pin indicator] [name] [pin-toggle] [rename] [delete/routine-icon]` — single line. In the **card**, the order is `[bullet/icon] [name] ---- [action stack]` — top row, then optional description preview, then either visible-on-hover bottom-right action stack OR keep hover-revealed on top row. For minimal churn, the card variant moves the action icons from the right of the name to a small stacked group inside the top-right of the card, and exposes them on hover via the same `group-hover/task` pattern.

### Visual mock (card variant, with and without description)

```
Without description:                    With description:
┌──────────────────────────────────┐    ┌──────────────────────────────────┐
│ ●  Task name             ⋮ ☰ ✕   │    │ ●  Task name             ⋮ ☰ ✕   │
│                                  │    │ A short note about the task.    │
└──────────────────────────────────┘    │                                  │
                                        └──────────────────────────────────┘
```

(Grey border, card-bg background, 6px corner radius, 10px/10px padding, hover raises to a slightly violet outline.)

---

## File Structure

### Modified frontend files (Vue / TS)

| File | Change |
|---|---|
| `src/apps/desktop/src/components/WorkspaceItemTask.vue` | Add `variant` prop with `'row' \| 'card'`; branch the outer class + inner layout + optional description; add `data-task-card` and `data-task-row` attributes for test selectors |
| `src/apps/desktop/src/components/KanbanCard.vue` | Pass `:variant="'card'"` to the wrapped `<WorkspaceItemTask>` |
| `src/apps/desktop/src/__tests__/workspaceItemTaskVariant.spec.ts` | NEW — tests for both variants and description rendering |
| `src/apps/desktop/src/__tests__/KanbanCard.spec.ts` | Add one test asserting the wrapped WorkspaceItemTask receives `variant="card"` |
| `src/apps/desktop/src/__tests__/workspaceItemTask.spec.ts` | Add ONE assertion (`data-task-row` on existing row test) to lock in the row testid |

### Files NOT modified (intentional)

- `src/apps/desktop/src/components/WorkspaceItem.vue` — keeps implicit `'row'` default; no edit needed.
- `src/apps/desktop/src/components/WorkspaceList.vue` — same.
- `src/apps/desktop/src/components/AppLayout.vue` — same.
- `src/apps/desktop/src/stores/workspaces.ts` — `Task` already has `description?: string`.
- `src/apps/desktop/src/api/index.ts` — `Task` already has `description?: string`.

---

## Chunk 1: Add the `variant` prop to `WorkspaceItemTask.vue`

### Task 1.1 — Declare the prop and branch the outer container

**File:** `src/apps/desktop/src/components/WorkspaceItemTask.vue`

Add `variant: 'row' | 'card'` to `defineProps<{...}>()` (default `'row'`). Add a `computed` that picks the outer container class string from the variant.

The existing root button (line 162) is currently:

```ts
class="flex items-center gap-2 px-3 py-1 rounded text-xs group/task cursor-pointer transition-all duration-200"
```

Replace with a `computed` that selects between two class strings:

- **`row`** (unchanged — bit-exact to today):
  ```
  "flex items-center gap-2 px-3 py-1 rounded text-xs group/task cursor-pointer transition-all duration-200"
  ```
- **`card`** (new — visually distinct, kanban-only):
  ```
  "flex flex-col gap-1 p-2.5 rounded-md text-xs group/task cursor-pointer transition-all duration-200 bg-[--semantic-card-bg] border border-[--color-border] hover:border-[--color-violet] shadow-sm hover:shadow-md"
  ```

Wrap with `:class="containerClass"` on the root `<button>`. Add `data-task-card` when variant is 'card' and `data-task-row` when variant is 'row' for test selectors.

### Task 1.2 — Branch the inner layout

The current template (lines 161-331) renders a single flex row. For the card variant, replace the top row's flex layout with a card-specific structure:

**Top row (always rendered):** bullet/spinner on the left, name (flex-1 truncate), action icons on the right.

**Description row (only when `variant === 'card' && task.description`):** a 2nd inner row with `class="text-[11px] text-[--semantic-text-dim] truncate"` containing `{{ task.description }}`. Wrap with `v-if="variant === 'card' && task.description"`. Add `data-testid="task-description"` on the rendered `<p>`.

**Subtle refactor:** lift the existing top-level `<template v-if="isRoutine">` ... `<template v-else>` branch into a child computed or a small inline `v-if` chain. Both variants render the SAME action icons (spinner / bullet / pin-indicator / name / pin-toggle / rename-or-editRoutine / run-now / delete) — only the outer container class + the description line differ. So the body can be a single tree that uses `variant`-driven class strings for container + `v-if` for description.

DO NOT rename or restructure the existing `<template v-if="isRoutine">` branches — they pass tests today and the variant change is pure additive.

### Task 1.3 — Add data-testid attributes for both variants

- On the root button: `:data-task-row="variant === 'row' ? '' : null"` and `:data-task-card="variant === 'card' ? '' : null"` (Vue converts `''` to presence, `null` to absence — same pattern as the existing `dropIndicator` binding at line 165).
- On the description line: `:data-testid="'task-description'"` so tests can find it via `wrapper.find('[data-testid="task-description"]')`.

### Task 1.4 — Add tests for the variant prop

**File (NEW):** `src/apps/desktop/src/__tests__/workspaceItemTaskVariant.spec.ts`

#### Step 1.4.1 — Test file skeleton

```ts
/**
 * Tests for WorkspaceItemTask's variant prop. Verifies:
 *   - default variant is 'row' (data-task-row present, data-task-card absent)
 *   - variant='card' renders card styling + description
 *   - variant='row' (explicit) hides description
 *   - card variant renders description only when non-empty
 *
 * Plan: docs/plans/2026-07-01-change-task-to-card-kanban.md
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, type VueWrapper } from '@vue/test-utils'
import { ref, type Ref } from 'vue'

import WorkspaceItemTask from '../components/WorkspaceItemTask.vue'
import type { Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

function mountTask(
  task: Task,
  props: Partial<{ variant: 'row' | 'card' }> = {},
) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  const wrapper = mount(WorkspaceItemTask, {
    props: {
      task,
      workspaceId: 'ws_1',
      itemId: 'item_1',
      ...props,
    },
    global: { provide: { processingState } },
  })
  return wrapper
}

describe('WorkspaceItemTask variant prop', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })
  // ... tests below ...
})
```

#### Step 1.4.2 — Default is row

```ts
it('defaults to variant="row" when no prop is passed', () => {
  wrapper = mountTask({ id: 't1', name: 'Alpha' })
  // data-task-row present (truthy attribute)
  expect(wrapper.find('[data-task-row]').exists()).toBe(true)
  // data-task-card absent
  expect(wrapper.find('[data-task-card]').exists()).toBe(false)
})
```

#### Step 1.4.3 — Card variant flips both selectors

```ts
it('renders data-task-card and hides data-task-row when variant="card"', () => {
  wrapper = mountTask({ id: 't1', name: 'Alpha' }, { variant: 'card' })
  expect(wrapper.find('[data-task-card]').exists()).toBe(true)
  expect(wrapper.find('[data-task-row]').exists()).toBe(false)
})
```

#### Step 1.4.4 — Description only renders in card variant

```ts
it('renders description when variant="card" and description is non-empty', () => {
  wrapper = mountTask(
    { id: 't1', name: 'Alpha', description: 'A note' },
    { variant: 'card' },
  )
  const desc = wrapper.find('[data-testid="task-description"]')
  expect(desc.exists()).toBe(true)
  expect(desc.text()).toBe('A note')
})

it('hides description when variant="row" (default)', () => {
  wrapper = mountTask({ id: 't1', name: 'Alpha', description: 'A note' })
  expect(wrapper.find('[data-testid="task-description"]').exists()).toBe(false)
})

it('hides description line in card variant when description is empty', () => {
  wrapper = mountTask(
    { id: 't1', name: 'Alpha' },
    { variant: 'card' },
  )
  expect(wrapper.find('[data-testid="task-description"]').exists()).toBe(false)
})
```

#### Step 1.4.5 — Card variant also renders the task name + actions

```ts
it('renders the task name in card variant', () => {
  wrapper = mountTask({ id: 't1', name: 'Alpha' }, { variant: 'card' })
  expect(wrapper.text()).toContain('Alpha')
})

it('renders the pin toggle in card variant', () => {
  wrapper = mountTask({ id: 't1', name: 'Alpha' }, { variant: 'card' })
  expect(wrapper.find('[data-testid="task-pin-toggle"]').exists()).toBe(true)
})

it('renders the delete button in card variant', () => {
  wrapper = mountTask({ id: 't1', name: 'Alpha' }, { variant: 'card' })
  // Delete button has no testid today; use a stable class selector to
  // confirm the action icons render in the card variant. (Kept loose
  // because the exact selector is internal to the template.)
  expect(wrapper.findAll('button').length).toBeGreaterThanOrEqual(3)
})
```

### Task 1.5 — Register the new test in the runner (no separate runner in this project)

Frontend tests are auto-collected by `vitest`'s default `**/*.spec.ts` glob — no manual registration needed. Verify with:

```bash
cd src/apps/desktop && timeout 60 bunx vitest run workspaceItemTaskVariant 2>&1 | tail -n 15
```

Expected: `7 passed (or however many tests)` — all new green.

### Task 1.6 — Lock-in assertion on the existing row test

**File:** `src/apps/desktop/src/__tests__/workspaceItemTask.spec.ts`

Add ONE assertion to the existing first test (line 66 "renders the task name and a bullet by default") to lock in the row testid:

```ts
it('renders the task name and a bullet by default (no spinner, no active styling)', async () => {
  const { wrapper } = mountTask()
  expect(wrapper.text()).toContain('Alpha task')
  expect(wrapper.findAll('[data-testid="task-spinner"]')).toHaveLength(0)
  // NEW: lock in the row-variant testid so a future refactor that
  // accidentally flips the default to 'card' gets caught.
  expect(wrapper.find('[data-task-row]').exists()).toBe(true)
  expect(wrapper.find('[data-task-card]').exists()).toBe(false)
  // bullet selector unchanged
  expect(wrapper.findAll('span.w-1\\.5.h-1\\.5.rounded-full')).toHaveLength(1)
})
```

This is a 2-line, surgical add. None of the other tests in this file need changes (they're already variant-agnostic by virtue of asserting on testids / text, not classes).

---

## Chunk 2: Wire `KanbanCard.vue` to pass `variant="card"`

### Task 2.1 — Pass the variant prop

**File:** `src/apps/desktop/src/components/KanbanCard.vue`

In the `<WorkspaceItemTask>` invocation (line 84), add `:variant="'card'"`:

```vue
<WorkspaceItemTask
  :task="task"
  :workspace-id="workspaceId"
  :item-id="itemId"
  :variant="'card'"
  @select-task="(id) => emit('selectTask', id)"
  @delete-task="(ws, item, id) => emit('deleteTask', ws, item, id)"
  @rename-task="(ws, item, id, name) => emit('renameTask', ws, item, id, name)"
  @edit-routine="(ws, item, id) => emit('editRoutine', ws, item, id)"
  @run-routine="(ws, item, id) => emit('runRoutine', ws, item, id)"
  @pin-task="(ws, item, id, pinned) => emit('pinTask', ws, item, id, pinned)"
/>
```

That's it for this file. The `KanbanCard` wrapper itself keeps its draggable div + MIME handlers — only the inner component gets the variant bump.

### Task 2.2 — Test that `KanbanCard` passes the variant

**File:** `src/apps/desktop/src/__tests__/KanbanCard.spec.ts`

Append one new `it()` to the existing `describe('KanbanCard', ...)` block:

```ts
it('renders the wrapped WorkspaceItemTask in card variant (data-task-card present, data-task-row absent)', () => {
  wrapper = mountCard(sampleTask)
  expect(wrapper.find('[data-task-card]').exists()).toBe(true)
  expect(wrapper.find('[data-task-row]').exists()).toBe(false)
})

it('renders the description when present and card variant is in use', () => {
  wrapper = mountCard({ ...sampleTask, description: 'Card body' })
  const desc = wrapper.find('[data-testid="task-description"]')
  expect(desc.exists()).toBe(true)
  expect(desc.text()).toBe('Card body')
})
```

### Task 2.3 — Confirm no regressions in `KanbanColumn.spec.ts`

`KanbanColumn.spec.ts` tests assert on `data-kanban-card` (the wrapper element) and `data-testid` selectors inside the card. None of them inspect the inner `WorkspaceItemTask`'s class — they should all pass unchanged.

Verify with:

```bash
cd src/apps/desktop && timeout 60 bunx vitest run KanbanColumn KanbanCard KanbanView 2>&1 | tail -n 15
```

Expected: all green.

---

## Chunk 3: Verify no other call site breaks

### Task 3.1 — Audit all `<WorkspaceItemTask>` call sites

Run:

```bash
cd src/apps/desktop && timeout 10 rg "<WorkspaceItemTask" -n 2>&1
```

Expected output (pre-existing call sites):

- `src/apps/desktop/src/components/WorkspaceItem.vue:472` — pinned region (sidebar list)
- `src/apps/desktop/src/components/WorkspaceItem.vue:491` — unpinned region (sidebar list)
- `src/apps/desktop/src/components/KanbanCard.vue:84` — kanban card wrapper ← will be modified in Chunk 2

No new call sites are expected. If any future code (e.g. a memory-file picker) renders tasks, it gets the default `'row'` — which is correct for those contexts (memory is not a kanban).

### Task 3.2 — Static-contract test pinning the call-site invariant

Add ONE test to `src/apps/desktop/src/__tests__/KanbanCard.spec.ts` (or a new contract test file) that asserts `WorkspaceItem.vue`'s `<WorkspaceItemTask>` instances DO NOT pass `variant`:

```ts
/**
 * Contract test: the sidebar's WorkspaceItem (non-kanban consumers)
 * must NOT pass a `variant` prop to <WorkspaceItemTask>. The default
 * row rendering is required there — sidebar tasks are still rendered
 * as rows, not cards. If someone accidentally adds `:variant="'card'"`
 * to one of these lines, this test fires.
 */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const SIDEBAR_PATH = resolve(
  __dirname, '..', 'components', 'WorkspaceItem.vue',
)

describe('WorkspaceItem.vue — task variant invariant', () => {
  it('does not pass variant="card" to <WorkspaceItemTask>', () => {
    const source = readFileSync(SIDEBAR_PATH, 'utf8')
    expect(source).not.toMatch(/variant\s*=\s*['"]card['"]/)
  })

  it('still renders <WorkspaceItemTask> (sanity: the contract test is testing the right file)', () => {
    const source = readFileSync(SIDEBAR_PATH, 'utf8')
    expect(source).toContain('<WorkspaceItemTask')
  })
})
```

This static-contract test complements the dynamic tests in Chunks 1 & 2 and locks in the "kanban-only" scoping.

---

## Chunk 4: Build, type-check, and full test sweep

### Task 4.1 — Build the desktop frontend

```bash
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 30
```

Per memory `bun run build vs bun run build-only`: this runs the full `vue-tsc --build` pass which catches the TS errors that `bunx vitest run` alone misses. Must show **zero** TS errors. If you see `vue-tsc` complaining about the new `variant` prop, fix the prop type to be optional (`variant?: 'row' | 'card'`), not required, with default `'row'`.

### Task 4.2 — Run the full desktop test suite

```bash
cd src/apps/desktop
timeout 180 bunx vitest run 2>&1 | tail -n 30
```

Expected: all existing tests still pass + 8-10 new tests from Chunks 1 & 2 + 2 from Chunk 3.2 = ~10-12 net new tests passing.

### Task 4.3 — Spot-check the count delta

```bash
cd src/apps/desktop
timeout 60 bunx vitest run --reporter=verbose 2>&1 | rg -c "✓|✔|passed"
```

Should be higher than the baseline (run a baseline check first if you don't know the exact number — the project memory says "all frontend tests pass" as the standing condition, so any non-zero delta that doesn't drop the pass count is a win).

---

## Chunk 5: Manual smoke test on port 8080

### Task 5.1 — Start `nalar` on port 8080

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
./zig-out/bin/nalar --port 8080 &
```

(Per the project memory: never kill the nalar process on port 8081. Use port 8080 for local smoke testing.)

### Task 5.2 — Open the desktop app to a kanban item

In the app:
1. Navigate to the workspace containing the existing kanban items (the board titled "sprint 1" in the screenshot for the active task).
2. Click a kanban item — the board renders in the main content area (AppLayout.vue:1297).
3. Verify the cards inside columns NOW look like cards (background, border, padding) instead of rows.
4. Verify a card with a description (seed a test task with `description: 'review the workflow'` if none exist) shows the description line under the name.
5. Hover a card — verify the action icons (pin / edit / delete) appear via the same hover affordance, and the card's border highlights violet.
6. Click a card to navigate to the chat — same behavior as before (action unchanged).
7. Drag a card between columns — same DnD behavior (KanbanCard's dragstart / column's drop are unchanged).

### Task 5.3 — Confirm the sidebar list is unchanged

1. Click a non-kanban item (folder or chat-type item) in the sidebar.
2. Expand it.
3. Verify the per-task rows look **exactly** as they did before — same `px-3 py-1 text-xs` row, same hover behavior, no card styling, no description line.
4. Click a task — same selection behavior.

### Task 5.4 — Pin/unpin in the kanban card

1. Hover a kanban card.
2. Click the pin toggle button.
3. Verify the pin indicator (yellow pin icon) appears on the card immediately (optimistic update via the existing `pinTask` store action).
4. Verify the card stays in the same column (pinning does NOT remove it from the kanban — only the sidebar's per-item task-list pins are a separate concept; the kanban card is just locally "marked as pinned" and the yellow icon shows. Out of scope for this task to add a pinned-region within kanban columns).

### Task 5.5 — Stop the local nalar

```bash
kill %1   # the background job from Task 5.1
```

DO NOT use `pkill -f "zig build run"` — the project's nalar process on port 8081 is also a `nalar` process and would also match.

---

## Defaults locked by this plan

1. **`variant` default = `'row'`** — additive, non-breaking. Every existing call site keeps the row UX.
2. **`variant: 'card'` is opt-in via `<KanbanCard>`** — only kanban columns get the new rendering.
3. **No description in row variant** — `description` is a kanban-card-only field today; users editing it from the chat/task picker (in a future feature) would get the row UX without a description line until we extend that context.
4. **No dark/light theme re-coloring** — the card variant uses existing CSS variables (`--semantic-card-bg`, `--color-border`, `--color-violet`). The same theming system that styles the sidebar also styles the card.
5. **Action icons stay hover-revealed** — no change to the existing `group-hover/task:opacity-100` pattern. Keeping the icons hidden on idle keeps the card visually minimal and matches the existing kanban UX.
6. **No new tests for the rendering class strings** — we test the data attributes (`data-task-card`, `data-task-row`, `data-testid="task-description"`) which are stable across CSS-class refactors. Adding tests against `class="p-2.5 rounded-md ..."` would be brittle (renaming Tailwind classes, swapping to a custom class, etc.).

---

## Verification (final acceptance)

The task is "complete" when ALL of these are true:

1. `cd src/apps/desktop && timeout 180 bun run build 2>&1 | tail -n 10` → no TS errors.
2. `cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 5` → all tests pass (existing + new ≈ +10).
3. `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 240 zig build test --summary all 2>&1 | tail -n 5` → no Zig backend test regressions (defensive, even though we touched no `.zig` files).
4. Manual smoke test (Chunks 5.2-5.4) — cards look like cards inside columns; rows look like rows in the sidebar; actions still work; drag-and-drop still works; pin icon still toggles.

---

## Future work (NOT in this plan)

- **Card description editor** — a small modal similar to `KanbanColumnEditor` that lets the user add/edit the description on a card. Out of scope: requires deciding whether the backend's `updateTaskSimple` accepts a description-only patch (verified at `api/index.ts:1085` patch: `{ name?: string; description?: string; position?: number }` — yes, it does), and designing the UX for opening the editor.
- **Card color / label** — none of the backend fields support card-level color; would require a new migration and a `kanban_card_labels` table.
- **Per-card pinned-region inside a column** — would require merging the sidebar's pinned-task concept with the kanban's column-based layout.
- **Re-order cards within a column via drag** — separate feature, plan `2026-06-30-fix-kanban-drop-position.md` is the first cut.
- **Inline card title rename** (double-click to edit) — current rename flow goes through `RenameTaskModal` opened from the sidebar; would be a UX win for kanban users but needs design.
