# Kanban: Embed ChatView inside KanbanView — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pure relocation — the kanban board and the task's chatview render as a **single combined component** (`KanbanView`) instead of two siblings in `AppLayout`. UX is identical (same resize, same `kanban-column-width` localStorage, same `:key` strategies, same `@select-task` / `@close-chat` event flow upward). Only the layout ownership changes — `AppLayout` shrinks ~150 lines, `KanbanView` grows ~150 lines.

**Architecture:** One `KanbanView` mount in `AppLayout` replaces both the standalone branch and the 3-column branch. KanbanView internally branches its template: `!activeTask` → full-width board (unchanged); `activeTask && activeTaskWorkspaceItemId === item.id` → 2-column `[Board][resize-handle][ChatView]`. The resize state machine (`kanbanColumnWidth`, `isKanbanResizing`, listeners, `kanbanColumnStyle`, localStorage key `kanban-column-width`) moves from `AppLayout.vue:763-895` into `KanbanView`'s `<script setup>`. The `activeTaskWorkspaceItemId` computed moves from `AppLayout.vue:701-712` into the `workspaces` Pinia store as a getter. URL routing (select/close task) stays in AppLayout.

**Tech Stack:** Vue 3 (Composition API + `<script setup>`), TypeScript, Pinia, `@vue/test-utils` + Vitest, `node vue-tsc --build` for type-check. No backend changes.

**Spec:** `docs/superpowers/specs/2026-08-06-kanban-embed-chatview-design.md` (approved).

**Worktree:** `/home/ginwa/ginwaaitoolbox/.worktrees/kanban-embed-chatview` on branch `worktree/kanban-embed-chatview`.

---

## Global Constraints

- **Cross-platform**: every feature MUST work on Linux, macOS, AND Windows (per project rule AGENTS.md §"Top-line mandate"). Verify with `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc ...` and `... -target aarch64-macos -lc ...` at the end of the plan.
- **No static-contract tests**: ALL tests are behavioural. No `expect(source).toContain(...)` / `indexOf(u8, source, ...)` patterns anywhere — see `~/.config/pabrik/memories/static-contract-test-when-to-prefer-behavioural.md`.
- **No port 8081**: smoke tests use port 8080 (the always-running dev pabrik on 8081 is off-limits).
- **Behavioural Vue tests use `@vue/test-utils` `mount`** with `setActivePinia(createPinia())` in `beforeEach`. Mock fetch via `vi.fn()` returning `{ ok, status, json, text }` shape (see `.pabrik/memories/pabrik-frontend-patterns.md` §"`apiFetch` mock helpers need `text()` method").
- **TDD discipline**: every implementation task starts with a failing test, then minimal code to make it pass, then a commit.
- **Pure relocation**: no UX changes beyond what this plan specifies. The resize behavior, localStorage key, `:key` strategies, and event flow upward are preserved exactly.

---

## File map

| File | Action | Why |
|---|---|---|
| `src/apps/desktop/src/stores/workspaces.ts` | edit | Add `activeTaskWorkspaceItemId` getter (move from AppLayout.vue:701-712) |
| `src/apps/desktop/src/components/kanban/KanbanView.vue` | edit | Add chat-pane branch + resize state + close-chat emit |
| `src/apps/desktop/src/components/AppLayout.vue` | edit | Delete 3-column block (lines 1739-1825) + resize state (lines 763-895) + standalone branch (line 1847); add @close-chat to unified KanbanView mount |
| `src/apps/desktop/src/components/views/ChatView.vue` | UNCHANGED | consumed by the new chat-pane branch in KanbanView |
| `src/apps/desktop/src/__tests__/workspaces.store.activeTaskWorkspaceItemId.spec.ts` | new | behavioural test for the store getter |
| `src/apps/desktop/src/__tests__/KanbanView.chatPane.spec.ts` | new | behavioural tests for the now-internal chat pane + resize |
| `src/apps/desktop/src/__tests__/AppLayout.kanban.spec.ts` | edit | update `data-kanban-three-column` references |
| `src/apps/desktop/src/__tests__/AppLayout.kanbanScrollPreservation.spec.ts` | edit | update `data-kanban-three-column` references |

---

## Task 1: Move `activeTaskWorkspaceItemId` into the workspaces store

**Why:** The "which kanban item owns the active task" relationship is store state, not view state. Two readers (AppLayout's v-else-if guard today; KanbanView's chat-pane branch after the refactor) should not duplicate the same lookup. The lookup is short (a nested loop over workspaces → items → tasks) but it's used in two places by the end of this plan.

**Files:**
- `src/apps/desktop/src/stores/workspaces.ts` — add getter
- `src/apps/desktop/src/components/AppLayout.vue` — delete local computed, consume store getter
- `src/apps/desktop/src/__tests__/workspaces.store.activeTaskWorkspaceItemId.spec.ts` — new

### Step 1.1: Write the failing test

Create `src/apps/desktop/src/__tests__/workspaces.store.activeTaskWorkspaceItemId.spec.ts` with three behavioural tests:

- `returns null when activeTaskId is null`
- `returns the owning item.id when activeTaskId matches a task under an item`
- `returns null when activeTaskId does not match any task`

Fixture pattern: build a `workspacesStore` with `setActiveWorkspaceItem(KANBAN_ID)` + `setActiveTask(TASK_ID)`.

```ts
import { setActivePinia, createPinia } from 'pinia'
import { beforeEach, describe, expect, it } from 'vitest'
import { useWorkspacesStore } from '../stores/workspaces'

describe('workspacesStore.activeTaskWorkspaceItemId', () => {
  beforeEach(() => setActivePinia(createPinia()))

  it('returns null when activeTaskId is null', () => {
    const store = useWorkspacesStore()
    expect(store.activeTaskWorkspaceItemId).toBeNull()
  })

  // ... see template above
})
```

Use the existing `createWorkspaceWithItem` helper if one exists in the test directory; otherwise inline a workspace + item + task via `store.workspaces = [{ id: 'ws_1', items: [...] }]` and `store.setActiveWorkspaceItem(ITEM_ID)`.

### Step 1.2: Run the test to confirm it fails

```bash
cd src/apps/desktop && timeout 60 bunx vitest run workspaces.store.activeTaskWorkspaceItemId.spec.ts 2>&1 | tail -n 25
```

Expect: `TypeError: store.activeTaskWorkspaceItemId is not a function` (or similar — it's not a getter yet).

### Step 1.3: Add the getter to the store

In `src/apps/desktop/src/stores/workspaces.ts`, find the existing `activeTask` computed (around line 516) and add `activeTaskWorkspaceItemId` next to it. Follow the existing computed style (arrow function with `computed(() => { ... })`).

```ts
const activeTaskWorkspaceItemId = computed(() => {
  const taskId = activeTaskId.value
  if (!taskId) return null
  for (const ws of workspaces.value) {
    for (const item of ws.items) {
      if (item.tasks?.some((t) => t.id === taskId)) {
        return item.id
      }
    }
  }
  return null
})
```

Add `activeTaskWorkspaceItemId` to the `return { ... }` block at the bottom of the store (around line 2650 where `activeTask` is exported).

### Step 1.4: Run the test to confirm it passes

```bash
cd src/apps/desktop && timeout 60 bunx vitest run workspaces.store.activeTaskWorkspaceItemId.spec.ts 2>&1 | tail -n 25
```

Expect: 3/3 pass.

### Step 1.5: Update AppLayout to consume the store getter

In `src/apps/desktop/src/components/AppLayout.vue`:

- Delete the local computed at lines 701-712:
  ```ts
  const activeTaskWorkspaceItemId = computed(() => {
    const taskId = workspacesStore.activeTaskId
    if (!taskId) return null
    for (const ws of workspacesStore.workspaces) {
      for (const item of ws.items) {
        if (item.tasks?.some((t) => t.id === taskId)) {
          return item.id
        }
      }
    }
    return null
  })
  ```
- Replace ALL references to `activeTaskWorkspaceItemId` in this file with `workspacesStore.activeTaskWorkspaceItemId` (5 references: lines 1744, 1909, and 2 in the test file that imports it via the local).

Use `text_replace` for each reference. Be careful: the local is `const activeTaskWorkspaceItemId = ...` and the store getter is `workspacesStore.activeTaskWorkspaceItemId`. They have the same name but different owning objects.

### Step 1.6: Verify AppLayout's tests still pass

```bash
cd src/apps/desktop && timeout 60 bunx vitest run AppLayout.kanban.spec.ts 2>&1 | tail -n 35
```

Expect: all 41 tests pass (the v-else-if condition still works because the computed returns the same value).

### Step 1.7: Verify type-check

```bash
cd src/apps/desktop && timeout 120 node node_modules/vue-tsc/bin/vue-tsc.js -b 2>&1 | tail -n 20
```

Expect: clean exit, no errors.

### Step 1.8: Commit

```bash
cd /home/ginwa/ginwaaitoolbox
git add -A
git commit -m "refactor(stores): move activeTaskWorkspaceItemId getter into workspaces store

The 'which kanban item owns the active task' lookup was duplicated in
AppLayout.vue (local computed, lines 701-712) and is now needed by
KanbanView (deprecated 3-column branch in AppLayout is being refactored
to own the chat pane). Moving the lookup into the store keeps the
relationship in one place.

Co-authored-by: session_1785526795361"
```

---

## Task 2: Add chat-pane branch skeleton in KanbanView (no resize yet)

**Why:** Before we can delete the 3-column block from AppLayout, KanbanView must be able to render the chat pane itself. This task adds the v-if/v-else structure that switches between full-width board and board+chat, mount the ChatView, and reads `activeTask` + `activeTaskWorkspaceItemId` from the store. The resize handle is added in Task 3.

**Files:**
- `src/apps/desktop/src/components/kanban/KanbanView.vue` — add chat-pane branch
- `src/apps/desktop/src/__tests__/KanbanView.chatPane.spec.ts` — new

### Step 2.1: Write the failing tests

Create `src/apps/desktop/src/__tests__/KanbanView.chatPane.spec.ts` with four behavioural tests:

- `renders full-width board when no active task`
- `renders chat pane when active task belongs to this kanban`
- `does NOT render chat pane when active task belongs to a different kanban`
- `renders chat pane with the active task's chat-id and chat-name`

Test fixture pattern: mount `KanbanView` with a `processingState` ref provided; use `setActivePinia(createPinia())` + `useWorkspacesStore()` to set `activeWorkspaceItem` + `activeTask`; assert DOM via `wrapper.find(...)`.

```ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, flushPromises } from '@vue/test-utils'
import { ref } from 'vue'
import KanbanView from '../components/kanban/KanbanView.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem, Task } from '../stores/workspaces'

const ITEM_ID = 'item_kanban_1'
const OTHER_ITEM_ID = 'item_kanban_2'
const TASK_ID = 'task_1'
const WS_ID = 'ws_1'

function makeItem(overrides: Partial<WorkspaceItem> = {}): WorkspaceItem {
  return {
    id: ITEM_ID,
    name: 'Sprint A',
    item_type: 'kanban',
    kanban_columns: [],
    tasks: [],
    ...overrides,
  } as WorkspaceItem
}

function setupActiveTask(store: ReturnType<typeof useWorkspacesStore>, ownerItemId: string) {
  // Build a workspace with two kanban items; activate item 1; set active task under item 1.
  store.workspaces = [{
    id: WS_ID,
    name: 'WS',
    items: [
      { ...makeItem({ id: ITEM_ID }), tasks: [{ id: TASK_ID, name: 'Hello' } as Task] },
      { ...makeItem({ id: OTHER_ITEM_ID }) },
    ],
  } as any]
  store.setActiveWorkspaceItem(ownerItemId)
  store.setActiveTask(TASK_ID)
}

describe('KanbanView — chat pane branch', () => {
  beforeEach(() => setActivePinia(createPinia()))
  afterEach(() => { vi.restoreAllMocks() })

  it('renders full-width board when no active task', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [{ id: WS_ID, name: 'WS', items: [makeItem()] }] as any
    store.setActiveWorkspaceItem(ITEM_ID)
    const wrapper = mount(KanbanView, {
      props: { item: makeItem(), workspaceId: WS_ID },
      global: { provide: { processingState: ref({}) } },
    })
    await flushPromises()
    expect(wrapper.find('[data-kanban-with-chat]').exists()).toBe(false)
    expect(wrapper.find('[data-kanban-host]').exists()).toBe(true)
  })

  it('renders chat pane when active task belongs to this kanban', async () => {
    const store = useWorkspacesStore()
    setupActiveTask(store, ITEM_ID)
    const wrapper = mount(KanbanView, {
      props: { item: makeItem(), workspaceId: WS_ID },
      global: { provide: { processingState: ref({}) } },
    })
    await flushPromises()
    expect(wrapper.find('[data-kanban-with-chat]').exists()).toBe(true)
    expect(wrapper.find('[data-kanban-host]').exists()).toBe(true)
  })

  it('does NOT render chat pane when active task belongs to a different kanban', async () => {
    const store = useWorkspacesStore()
    setupActiveTask(store, OTHER_ITEM_ID)
    const wrapper = mount(KanbanView, {
      props: { item: makeItem(), workspaceId: WS_ID },
      global: { provide: { processingState: ref({}) } },
    })
    await flushPromises()
    expect(wrapper.find('[data-kanban-with-chat]').exists()).toBe(false)
  })

  it('renders chat pane with the active task chat-id and chat-name', async () => {
    const store = useWorkspacesStore()
    setupActiveTask(store, ITEM_ID)
    const wrapper = mount(KanbanView, {
      props: { item: makeItem(), workspaceId: WS_ID },
      global: { provide: { processingState: ref({}) } },
    })
    await flushPromises()
    const chatEl = wrapper.find('[data-kanban-with-chat]')
    expect(chatEl.exists()).toBe(true)
    // ChatView is mounted somewhere inside the chat pane; assert
    // the parent has the chat pane class. Detailed ChatView prop
    // assertions are covered in Task 4.
  })
})
```

The exact `setupActiveTask` helper depends on the store's public surface (`setActiveWorkspaceItem`, `setActiveTask`). Read those signatures from `src/apps/desktop/src/stores/workspaces.ts` before writing the test.

### Step 2.2: Run the tests to confirm they fail

```bash
cd src/apps/desktop && timeout 60 bunx vitest run KanbanView.chatPane.spec.ts 2>&1 | tail -n 25
```

Expect: 4/4 fail (no `data-kanban-with-chat` yet, no `data-kanban-host` yet).

### Step 2.3: Add the chat-pane branch to KanbanView's template

In `src/apps/desktop/src/components/kanban/KanbanView.vue`:

1. Add `import ChatView from '../views/ChatView.vue'` to the script imports.
2. Add `useWorkspacesStore` already imported at line 63. Add `computed` is already imported at line 58.
3. Add the computed derives inside `<script setup>`:
   ```ts
   const activeTask = computed(() => workspacesStore.activeTask)
   const activeTaskWorkspaceItemId = computed(() => workspacesStore.activeTaskWorkspaceItemId)
   const showChatPane = computed(
     () => !!(activeTask.value && activeTaskWorkspaceItemId.value === effectiveItemId.value),
   )
   ```
4. Wrap the existing template (header + columns row) in either:
   - `<div v-if="!showChatPane" class="flex-1 flex flex-col min-h-0" data-kanban-host="without-chat">` (existing full-width layout, unchanged)
   - `<div v-else class="flex-1 flex min-h-0" data-kanban-with-chat data-kanban-host="with-chat">` containing the existing header + columns row on the left, and on the right a `<ChatView>` (no resize handle yet — added in Task 3).

   The simplest path: keep the existing root `<div class="flex-1 flex flex-col min-h-0">` and add `data-kanban-host` to it. Then add a new v-if structure that conditionally renders the chat pane NEXT TO the existing content (overlap with the columns row on the right). To avoid duplicating the header + columns row, use TWO sibling branches:

   ```vue
   <template>
     <div class="flex-1 flex flex-col min-h-0" data-kanban-host>
       <!-- No active task: full-width board (unchanged) -->
       <template v-if="!showChatPane">
         <header>...</header>
         <div class="overflow-x-auto">...columns row...</div>
       </template>

       <!-- Active task: board + chat side by side -->
       <div v-else class="flex-1 flex min-h-0" data-kanban-with-chat>
         <div class="flex flex-col h-full min-h-0" style="border-right: 1px solid var(--color-border)">
           <header>...</header>
           <div class="overflow-x-auto flex-1">...columns row...</div>
         </div>
         <!-- resize handle slot — Task 3 -->
         <div class="flex-1 flex flex-col h-full min-w-0 min-h-0">
           <ChatView
             :key="'task-' + activeTask.id"
             :chat-id="activeTask.id"
             :chat-name="activeTask.name"
             :type="'task'"
             :cwd="item.path || ''"
             :task-id="activeTask.id"
             :task-name="activeTask.name"
             :project-name="item.name || ''"
             :show-header="true"
             @close="$emit('close-chat')"
           />
         </div>
       </div>
     </div>
   </template>
   ```

   **IMPORTANT:** `<header>` and `...columns row...` are the EXACT JSX that currently lives in KanbanView's template. Read KanbanView.vue carefully and copy them verbatim in both branches. Do not refactor them — this is a relocation, not a redesign.

   Note: the chat pane uses `:key="'task-' + activeTask.id"` (UNCHANGED from today — same as line 1813 in AppLayout). The `$emit('close-chat')` is added in Task 4; for now, the `:close` binding won't be there OR will be a placeholder emit. Use `v-on:close="$emit('close-chat')"` only if the test doesn't break.

   The `@close="$emit('close-chat')"` requires KanbanView to declare `close-chat` as an emit. To avoid TypeScript errors in Task 2, define `defineEmits` with an empty map for now and add `close-chat` to it in Task 4. Alternatively, define the full emit map now (`defineEmits<{ 'close-chat': [] }>()`) so Task 4 only adds the handler.

   **Recommended:** define the full emit map now. The emit declaration is harmless.

### Step 2.4: Run the tests to confirm they pass

```bash
cd src/apps/desktop && timeout 60 bunx vitest run KanbanView.chatPane.spec.ts 2>&1 | tail -n 30
```

Expect: 4/4 pass.

### Step 2.5: Run the existing KanbanView tests to confirm no regressions

```bash
cd src/apps/desktop && timeout 60 bunx vitest run KanbanView.spec.ts KanbanView.searchFilter.spec.ts 2>&1 | tail -n 25
```

Expect: all pass. The full-width branch is unchanged, so existing tests should still pass.

### Step 2.6: Verify type-check

```bash
cd src/apps/desktop && timeout 120 node node_modules/vue-tsc/bin/vue-tsc.js -b 2>&1 | tail -n 20
```

Expect: clean exit.

### Step 2.7: Commit

```bash
cd /home/ginwa/ginwaaitoolbox
git add -A
git commit -m "feat(kanban): KanbanView renders chat pane when active task belongs to it

Adds the v-if/v-else structure that switches between full-width board
(no active task) and board+chat (active task belongs to this kanban).
The chat pane mounts ChatView with the same props + key as the existing
3-column branch in AppLayout. Resize handle is added in a follow-up.

Co-authored-by: session_1785526795361"
```

---

## Task 3: Move the resize state machine from AppLayout into KanbanView

**Why:** The 3-column branch's resize handle + state + listeners all live in AppLayout. After the relocation, KanbanView owns the chat pane and the resize handle goes with it. The localStorage key `kanban-column-width` is preserved exactly so the user keeps their saved width.

**Files:**
- `src/apps/desktop/src/components/kanban/KanbanView.vue` — add resize state + listeners + handle JSX
- `src/apps/desktop/src/__tests__/KanbanView.chatPane.spec.ts` — extend with resize tests

### Step 3.1: Write the failing tests for the resize behavior

Extend `src/apps/desktop/src/__tests__/KanbanView.chatPane.spec.ts` with three behavioural tests:

- `drag the resize handle updates the kanban column width`
- `mouseup persists the width to localStorage`
- `falls back to 40% default when no localStorage value`

Test pattern: mount KanbanView with activeTask set; trigger `mousedown` on `[data-kanban-resize-handle]`; dispatch `mousemove` on `document` with `clientX` delta; dispatch `mouseup` on `document`; assert `kanbanColumnStyle` is now `px` and `localStorage.getItem('kanban-column-width')` is set.

```ts
it('drag the resize handle updates the kanban column width', async () => {
  localStorage.removeItem('kanban-column-width')
  const store = useWorkspacesStore()
  setupActiveTask(store, ITEM_ID)
  const wrapper = mount(KanbanView, {
    props: { item: makeItem(), workspaceId: WS_ID },
    global: { provide: { processingState: ref({}) } },
  })
  await flushPromises()
  const handle = wrapper.find('[data-kanban-resize-handle]')
  expect(handle.exists()).toBe(true)
  // Simulate drag: mousedown on handle, mousemove +50px on document, mouseup.
  await handle.trigger('mousedown', { clientX: 100 })
  document.dispatchEvent(new MouseEvent('mousemove', { clientX: 150 }))
  document.dispatchEvent(new MouseEvent('mouseup', { clientX: 150 }))
  // The kanban column's outer style now has a width set in px.
  const boardColumn = wrapper.find('[data-kanban-with-chat] > :first-child')
  const style = (boardColumn.element as HTMLElement).style.width
  expect(style).toMatch(/^\d+px$/i)
  // Width is at least KANBAN_MIN_WIDTH (0) and at most KANBAN_MAX_WIDTH (720), measured from start.
  // The default start width is the rendered width (measure on mount).
  expect(parseInt(style, 10)).toBeGreaterThanOrEqual(0)
  expect(parseInt(style, 10)).toBeLessThanOrEqual(720)
})
```

Read the existing `AppLayout.vue:813-866` (the `startKanbanResize` / `handleKanbanResize` / `stopKanbanResize` functions) to confirm the exact semantics:
- `startKanbanResize` reads `clientX` from `MouseEvent` or `TouchEvent`; sets `kanbanResizeStartX = clientX`; if `kanbanResizeStartWidth <= 0`, measures `document.querySelector('[data-kanban-three-column] > :first-child')?.getBoundingClientRect().width ?? 400`; attaches `mousemove` + `mouseup` listeners on `document`; sets `body.style.userSelect = 'none'`; sets `body.style.cursor = 'col-resize'`; calls `e.preventDefault()`.
- `handleKanbanResize` clamps `kanbanColumnWidth` to `[KANBAN_MIN_WIDTH, KANBAN_MAX_WIDTH]`.
- `stopKanbanResize` removes listeners; restores body styles; persists to localStorage.

For the new selector, replace `[data-kanban-three-column] > :first-child` with `[data-kanban-with-chat] > :first-child` (the new selector added in Task 2).

### Step 3.2: Run the tests to confirm they fail

```bash
cd src/apps/desktop && timeout 60 bunx vitest run KanbanView.chatPane.spec.ts 2>&1 | tail -n 30
```

Expect: 3 new tests fail (no resize handle yet, no resize state yet).

### Step 3.3: Move the resize state machine into KanbanView

Copy the following from `AppLayout.vue:763-895` into `KanbanView.vue`'s `<script setup>`:

- `KANBAN_MIN_WIDTH = 0` (line 788)
- `KANBAN_MAX_WIDTH = 720` (line 789)
- `KANBAN_DEFAULT_WIDTH = 40` (line 790) — used as percentage fallback
- `KANBAN_WIDTH_STORAGE_KEY = 'kanban-column-width'` (line 791)
- `loadKanbanColumnWidth()` helper (lines 799-806)
- `kanbanColumnWidth` ref (line 808)
- `isKanbanResizing` ref (line 809)
- `kanbanResizeStartX` ref (line 810)
- `kanbanResizeStartWidth` ref (line 811)
- `startKanbanResize`, `handleKanbanResize`, `stopKanbanResize` (lines 813-866)
- `kanbanColumnStyle` computed (lines 873-895 — read it to confirm exact logic)

Critical update: the `startKanbanResize` function uses `document.querySelector('[data-kanban-three-column] > :first-child')` to measure the rendered column. Replace this with `[data-kanban-with-chat] > :first-child` (the new selector from Task 2).

### Step 3.4: Add the resize handle JSX in the chat-pane branch

In the new chat-pane branch added in Task 2, between the board column and the ChatView column, insert:

```vue
<!--
  Resize handle — mirrors AppLayout.vue's original 3-column handle
  (lines 1790-1810). 4px-wide hit area with a 1px violet bar; the bar
  turns brighter on hover and during drag. The drag is owned by
  startKanbanResize (mousedown handler) which adds document-level
  mousemove/mouseup listeners.
-->
<div
  class="shrink-0 w-2 cursor-col-resize relative flex items-center justify-center bg-[var(--color-violet)]/15 hover:bg-[var(--color-violet)]/40 transition-colors"
  :class="isKanbanResizing ? '!bg-[var(--color-violet)]/60' : ''"
  data-kanban-resize-handle
  data-testid="kanban-resize-handle"
  title="Drag to resize"
  @mousedown="startKanbanResize"
>
  <svg width="14" height="2" viewBox="0 0 14 2" fill="currentColor" class="text-[var(--color-violet)] opacity-70" aria-hidden="true">
    <circle cx="3" cy="1" r="1" />
    <circle cx="7" cy="1" r="1" />
    <circle cx="11" cy="1" r="1" />
  </svg>
</div>
```

Bind the board column's `:style="kanbanColumnStyle"` so the width applies.

### Step 3.5: Run the resize tests to confirm they pass

```bash
cd src/apps/desktop && timeout 60 bunx vitest run KanbanView.chatPane.spec.ts 2>&1 | tail -n 40
```

Expect: all 7 tests pass (4 from Task 2 + 3 new).

### Step 3.6: Run the existing KanbanView tests for regressions

```bash
cd src/apps/desktop && timeout 60 bunx vitest run KanbanView.spec.ts KanbanView.searchFilter.spec.ts 2>&1 | tail -n 25
```

Expect: all pass.

### Step 3.7: Verify type-check

```bash
cd src/apps/desktop && timeout 120 node node_modules/vue-tsc/bin/vue-tsc.js -b 2>&1 | tail -n 20
```

Expect: clean exit.

### Step 3.8: Commit

```bash
cd /home/ginwa/ginwaaitoolbox
git add -A
git commit -m "feat(kanban): move resize state machine from AppLayout into KanbanView

The 3-column branch's resize handle + state + listeners (KANBAN_MIN_WIDTH,
KANBAN_MAX_WIDTH, kanbanColumnWidth, isKanbanResizing, startKanbanResize,
handleKanbanResize, stopKanbanResize, kanbanColumnStyle, localStorage
'kanban-column-width' persistence) move from AppLayout.vue:763-895 into
KanbanView's <script setup>. The selector for measuring the rendered
column updates from [data-kanban-three-column] > :first-child to
[data-kanban-with-chat] > :first-child.

Co-authored-by: session_1785526795361"
```

---

## Task 4: Wire `@close-chat` emit from KanbanView → AppLayout

**Why:** The ChatView's ✕ button emits `@close`. KanbanView needs to forward this as `@close-chat` so AppLayout's `handleCloseTaskView` (which handles URL routing + state cleanup) can be invoked.

**Files:**
- `src/apps/desktop/src/components/kanban/KanbanView.vue` — add `close-chat` to emits (already declared in Task 2); wire ChatView's `@close` to the emit
- `src/apps/desktop/src/__tests__/KanbanView.chatPane.spec.ts` — add a test that asserts the emit fires

### Step 4.1: Write the failing test

Add ONE test to `KanbanView.chatPane.spec.ts`:

- `emits close-chat when ChatView's close event fires`

```ts
it('emits close-chat when ChatView close event fires', async () => {
  const store = useWorkspacesStore()
  setupActiveTask(store, ITEM_ID)
  const wrapper = mount(KanbanView, {
    props: { item: makeItem(), workspaceId: WS_ID },
    global: { provide: { processingState: ref({}) } },
  })
  await flushPromises()
  // Find ChatView inside the chat pane and emit close via its defineExpose.
  // ChatView emits 'close' via $emit — find the component instance and call it.
  const chatView = wrapper.findComponent({ name: 'ChatView' })
  expect(chatView.exists()).toBe(true)
  chatView.vm.$emit('close')
  await flushPromises()
  expect(wrapper.emitted('close-chat')).toBeTruthy()
  expect(wrapper.emitted('close-chat')?.length).toBe(1)
})
```

### Step 4.2: Run the test to confirm it fails

```bash
cd src/apps/desktop && timeout 60 bunx vitest run KanbanView.chatPane.spec.ts 2>&1 | tail -n 30
```

Expect: 1 test fails (`wrapper.emitted('close-chat')` is undefined because the binding is missing or ChatView's `@close` doesn't reach KanbanView's emit).

If Task 2's wire (`@close="$emit('close-chat')"`) is already in place, the test may pass without further changes. If it passes, skip Steps 4.3-4.4 and go to Step 4.5.

### Step 4.3: Wire `@close` to `@close-chat` in the template

In `KanbanView.vue`'s chat-pane branch, the ChatView element should be:

```vue
<ChatView
  :key="'task-' + activeTask.id"
  :chat-id="activeTask.id"
  :chat-name="activeTask.name"
  :type="'task'"
  :cwd="item.path || ''"
  :task-id="activeTask.id"
  :task-name="activeTask.name"
  :project-name="item.name || ''"
  :show-header="true"
  @close="$emit('close-chat')"
/>
```

Verify the `@close` binding is present from Task 2; if not, add it now.

### Step 4.4: Declare `close-chat` in defineEmits

In `KanbanView.vue`'s `<script setup>`, after the props declaration, add:

```ts
defineEmits<{
  (e: 'close-chat'): void
}>()
```

OR, if the existing emits list is being added (Task 2 recommendation), include `close-chat` in it.

### Step 4.5: Run the test to confirm it passes

```bash
cd src/apps/desktop && timeout 60 bunx vitest run KanbanView.chatPane.spec.ts 2>&1 | tail -n 30
```

Expect: 8/8 pass.

### Step 4.6: Verify type-check

```bash
cd src/apps/desktop && timeout 120 node node_modules/vue-tsc/bin/vue-tsc.js -b 2>&1 | tail -n 20
```

Expect: clean exit.

### Step 4.7: Commit

```bash
cd /home/ginwa/ginwaaitoolbox
git add -A
git commit -m "feat(kanban): wire ChatView close to close-chat emit on KanbanView

ChatView's @close event is forwarded as @close-chat so AppLayout's
handleCloseTaskView can handle URL routing + state cleanup (URL stays
source of truth).

Co-authored-by: session_1785526795361"
```

---

## Task 5: Delete 3-column block + resize state from AppLayout; unify KanbanView mount

**Why:** Now that KanbanView owns the chat pane + resize, AppLayout no longer needs the 3-column block, the standalone branch, or the resize state machine. This task deletes them and unifies to a single KanbanView mount that includes `@close-chat="handleCloseTaskView"`.

**Files:**
- `src/apps/desktop/src/components/AppLayout.vue` — delete 3-column block (lines 1739-1825) + resize state (lines 763-895) + standalone branch (line 1847-1868); replace with ONE mount that includes `@close-chat`
- `src/apps/desktop/src/__tests__/AppLayout.kanban.spec.ts` — update selectors
- `src/apps/desktop/src/__tests__/AppLayout.kanbanScrollPreservation.spec.ts` — update selectors

### Step 5.1: Delete the 3-column block from AppLayout

In `src/apps/desktop/src/components/AppLayout.vue`, delete the entire v-else-if block at lines 1739-1825 (the `[data-kanban-three-column]` wrapper containing the inline KanbanView + resize handle + ChatView).

Use `text_replace` with the exact opening/closing. The opening is the `<!-- 3-column kanban layout -->` comment block at line 1727 and the v-else-if begins at line 1740. The closing is the `</div>` at line 1825.

Read the file once to confirm the exact start/end, then do one `text_replace` to delete the block.

### Step 5.2: Delete the standalone KanbanView mount and replace with the unified mount

In `AppLayout.vue`:

- Delete the standalone mount at lines 1847-1868 (the `<KanbanView v-else-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'kanban'">` block, including the comment block above it at lines 1839-1846).
- At the position of the deleted 3-column block (now the merged location), add the unified mount:

```vue
<KanbanView
  v-else-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'kanban'"
  :key="'kanban-' + activeWorkspaceItem.id"
  :item="activeWorkspaceItem"
  :workspace-id="activeWorkspace?.id ?? ''"
  :item-id="activeWorkspaceItem.id"
  @move-task="handleKanbanMoveTask"
  @add-column="handleKanbanAddColumn"
  @rename-column="handleKanbanRenameColumn"
  @delete-column="handleKanbanDeleteColumn"
  @reorder-column="handleKanbanReorderColumn"
  @request-rename-column="handleKanbanRequestRenameColumn"
  @request-delete-column="handleKanbanRequestDeleteColumn"
  @select-task="handleKanbanSelectTask"
  @delete-task="handleKanbanDeleteTask"
  @rename-task="handleKanbanRenameTask"
  @edit-routine="handleKanbanEditRoutine"
  @run-routine="handleKanbanRunRoutine"
  @pin-task="handleKanbanPinTask"
  @open-settings="handleOpenKanbanSettings"
  @rename-item="handleKanbanRenameItem"
  @close-chat="handleCloseTaskView"
/>
```

The unified mount is the same as today's standalone mount (lines 1847-1868) plus the new `@close-chat="handleCloseTaskView"` binding.

### Step 5.3: Delete the resize state machine from AppLayout

In `AppLayout.vue`, delete the resize block at lines 763-895:

- The `KANBAN_MIN_WIDTH`, `KANBAN_MAX_WIDTH`, `KANBAN_DEFAULT_WIDTH`, `KANBAN_WIDTH_STORAGE_KEY` constants (lines 788-791)
- The `loadKanbanColumnWidth` helper (lines 799-806)
- The `kanbanColumnWidth`, `isKanbanResizing`, `kanbanResizeStartX`, `kanbanResizeStartWidth` refs (lines 808-811)
- The `startKanbanResize`, `handleKanbanResize`, `stopKanbanResize` functions (lines 813-866)
- The `kanbanColumnStyle` computed (lines 873-895)

Read the file once to confirm the exact start/end, then do one `text_replace` to delete the block.

### Step 5.4: Run the AppLayout tests to identify selector failures

```bash
cd src/apps/desktop && timeout 60 bunx vitest run AppLayout.kanban.spec.ts AppLayout.kanbanScrollPreservation.spec.ts 2>&1 | tail -n 60
```

Expect: SOME tests fail with `data-kanban-three-column` not found. Note which tests fail.

### Step 5.5: Update selectors in AppLayout.kanban.spec.ts

In `src/apps/desktop/src/__tests__/AppLayout.kanban.spec.ts`, find every reference to `data-kanban-three-column` and replace with the new selector. The natural replacement is `data-kanban-with-chat` (the new selector inside KanbanView's chat-pane branch).

Use `search` to find all references:

```bash
cd src/apps/desktop && rg -n "data-kanban-three-column" src/__tests__/AppLayout.kanban.spec.ts
```

For each match, decide:
- If the test checks "the 3-column branch is rendered" → change to `data-kanban-with-chat`.
- If the test checks "the 3-column branch is NOT rendered" → change to `!data-kanban-with-chat` OR find a different selector (e.g. `data-kanban-host` for the kanban alone).
- If the test checks something internal (e.g. the resize handle) → handle in Step 5.6.

Update the test code + comments to match the new selector.

### Step 5.6: Update selectors in AppLayout.kanbanScrollPreservation.spec.ts

Same as Step 5.5, but for `AppLayout.kanbanScrollPreservation.spec.ts`. The selectors that need updating:
- `data-kanban-three-column` → `data-kanban-with-chat`

For resize-handle tests, the handle still exists (it's now inside KanbanView). The selector `[data-kanban-resize-handle]` is unchanged. The container selector `[data-kanban-three-column] > :first-child` is unchanged as a CONCEPT (it's now `[data-kanban-with-chat] > :first-child`).

### Step 5.7: Run the AppLayout tests to confirm they pass

```bash
cd src/apps/desktop && timeout 60 bunx vitest run AppLayout.kanban.spec.ts AppLayout.kanbanScrollPreservation.spec.ts AppLayout.chatview.spec.ts 2>&1 | tail -n 60
```

Expect: all tests pass.

### Step 5.8: Run the full frontend test suite

```bash
cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 30
```

Expect: all tests pass (or only pre-existing unrelated flakes — see known issues in AGENTS.md).

### Step 5.9: Verify type-check

```bash
cd src/apps/desktop && timeout 120 node node_modules/vue-tsc/bin/vue-tsc.js -b 2>&1 | tail -n 20
```

Expect: clean exit.

### Step 5.10: Commit

```bash
cd /home/ginwa/ginwaaitoolbox
git add -A
git commit -m "refactor(applayout): unify KanbanView mount, delete 3-column block + resize state

KanbanView now owns the chat pane + resize handle + state, so
AppLayout no longer needs to render two branches of KanbanView or
own the resize state machine. The 3-column block (AppLayout.vue
~lines 1739-1825) and the resize state (lines 763-895) are deleted.
The standalone mount (~lines 1847-1868) is replaced with a single
unified mount that includes @close-chat=handleCloseTaskView.

Net diff: AppLayout.vue -150 lines, KanbanView.vue +150 lines (in
Task 2-3). Selector in tests updated from data-kanban-three-column
to data-kanban-with-chat.

Co-authored-by: session_1785526795361"
```

---

## Task 6: Final verification (cross-platform, type-check, build, smoke)

**Why:** The pre-commit checklist (per AGENTS.md §"Pre-commit checklist") is non-negotiable. This task verifies everything is green before declaring done.

### Step 6.1: Run frontend type-check

```bash
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop
timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js -b 2>&1 | tail -n 20
```

Expect: clean exit. (Alternatively use `bun run build` which runs `vue-tsc -b` as the first step.)

### Step 6.2: Run the full frontend test suite

```bash
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop
timeout 180 bunx vitest run 2>&1 | tail -n 30
```

Expect: all tests pass (or only pre-existing flakes documented in AGENTS.md).

### Step 6.3: Run the backend test suite

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 30
```

Expect: same or better pass count as before the refactor (backend is untouched, so it should be unchanged).

### Step 6.4: Build the Linux binary

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -n 20
```

Expect: builds successfully.

### Step 6.5: Fresh rebuild (catches lazy-analysis + stale-cache)

```bash
cd /home/ginwa/ginwaaitoolbox
rm -rf zig-out/bin && timeout 360 zig build 2>&1 | tail -n 30
```

Expect: builds successfully.

### Step 6.6: Cross-compile smoke tests (Windows + macOS)

```bash
cd /home/ginwa/ginwaaitoolbox
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep pabrikcore -Mroot=/tmp/test_mod.zig -Mpabrikcore=src/root.zig 2>&1 | tail -n 20
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep pabrikcore -Mroot=/tmp/test_mod.zig -Mpabrikcore=src/root.zig 2>&1 | tail -n 20
```

Expect: both compile clean (no errors).

### Step 6.7: Build the frontend bundle

```bash
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 20
```

Expect: builds successfully.

### Step 6.8: Manual smoke (port 8080)

The dev `pabrik` runs on port 8081 — leave it alone. Spin up a fresh instance on port 8080 for smoke:

```bash
# Start pabrik on port 8080 in the background (use a tmp HOME)
TMPHOME=$(mktemp -d /tmp/pabrik-smoke-XXXX)
HOME="$TMPHOME" /home/ginwa/ginwaaitoolbox/zig-out/bin/pabrik --port 8080 --static-dir /home/ginwa/ginwaaitoolbox/src/apps/desktop/dist &
PABRIK_PID=$!
sleep 3

# Wait for health
for i in 1 2 3 4 5; do
  curl -sf http://localhost:8080/api/health && break
  sleep 1
done

# Visit the kanban in a browser (manual) or just confirm it's rendering via the network round-trip
# (For automated smoke, the existing tests/functional/kanban_lifecycle_test.py covers this.)

# Cleanup
kill $PABRIK_PID
rm -rf "$TMPHOME"
```

Manual smoke checklist (open the app in a browser pointing at port 8080):

1. Open a kanban → board alone, no chat.
2. Click a task → chatview appears on the right, board on the left.
3. Drag the resize handle → board shrinks, chatview grows.
4. Close the chatview → board fills the main area again.
5. Reload the page → resize width persists.
6. Open a different kanban → board alone again.
7. Click a second task → chatview re-mounts with the new task's content.

### Step 6.9: Update AGENTS.md with the changelog entry

Append a new `### YYYY-MM-DD: ...` block to the `Recent changes` section of `AGENTS.md`. Pattern follows the existing 2026-07-25 / 2026-07-28 / 2026-07-30 entries.

```markdown
### 2026-08-06: Kanban: embed ChatView inside KanbanView (pure relocation)

**Symptom (pre-fix).** AppLayout.vue mounted <KanbanView> twice — once
standalone (line 1847) and once in a 3-column wrapper (line 1739) that
gluing a <ChatView> as a sibling. The 3-column wrapper also owned the
entire kanban-column resize state machine (~130 lines, lines 763-895).

**What landed.** Single <KanbanView> mount in AppLayout. KanbanView
internally branches: !activeTask → full-width board; activeTask belongs
to this kanban → 2-column [Board][resize-handle][ChatView]. The resize
state + listeners + handle JSX move from AppLayout into KanbanView.
`activeTaskWorkspaceItemId` computed moves from AppLayout into the
workspaces store as a getter. URL routing stays in AppLayout (KanbanView
emits @close-chat → AppLayout's handleCloseTaskView).

**Pure relocation.** UX is identical: same drag-to-resize 0-720px,
same localStorage key 'kanban-column-width', same `@select-task` /
@close-chat event flow, same `:key` strategies. Net diff: AppLayout
-150 lines, KanbanView +150 lines.

**Selectors.** Old `data-kanban-three-column` → new `data-kanban-with-chat`
(in the kanban+chat 2-column branch inside KanbanView).

**Out of scope.** Design + chat 3-column (AppLayout.vue:1904) has the
same architectural shape but is a separate feature (design chats are
per-page, not per-task). A separate plan can apply the same refactor.
```

### Step 6.10: Commit the changelog

```bash
cd /home/ginwa/ginwaaitoolbox
git add -A
git commit -m "docs(agents): changelog entry for kanban-embed-chatview relocation"
```

---

## Pitfalls

- **`data-kanban-three-column` selector coupling** — many tests reference this. Update them in one pass (Task 5.5-5.6), not incrementally.
- **The "active task belongs to this kanban" check** must use `effectiveItemId.value` (the same value the v-else-if in AppLayout used), not `item.id` — there's a subtle difference when `itemId` is overridden (the prop can override `item.id`).
- **`@close` on ChatView vs `@close-chat` on KanbanView** — they are different events. KanbanView translates `@close` (from ChatView) into `@close-chat` (for AppLayout). Don't drop `@close-chat` thinking `@close` propagates up — it doesn't.
- **The `data-kanban-resize-handle`** needs to move into KanbanView's template together with the resize state — otherwise the handle is in the DOM but the listeners are not.
- **The KanbanView's `:key` is `'kanban-' + item.id`** — switching between two kanbans remounts the entire KanbanView (including the chat pane). This is the same behavior as today.
- **vue-tsc** will catch the prop / emit / type mismatches — `bun run build` is the first defense.
- **The 12 `@on` handlers on KanbanView remain** — AppLayout still forwards all of them. The `@close-chat` is the only new one (translating from ChatView's `@close`).
- **`activeTaskWorkspaceItemId` is now a getter on the store** — code that previously called the local computed (just AppLayout, lines 701-712) must now use `workspacesStore.activeTaskWorkspaceItemId`. The TS type is `string | null` (was `string | null` as well).
- **Memo / cache invalidation** — the store getter is `computed(() => ...)` over `activeTaskId.value` and `workspaces.value`. These are already reactive refs, so the getter re-runs when they change. Make sure no test relies on a stale snapshot.
- **Test mount helper** — `KanbanView` requires `processingState: Ref<Record<string, boolean>>` to be provided via `global: { provide: { processingState: ref({}) } }`. The new `KanbanView.chatPane.spec.ts` tests must include this. Without it, the test will throw on mount.
- **The `flushPromises()` after mount** — the chat pane may not render synchronously; Pinia stores need the next tick to resolve. Always `await flushPromises()` after mount before asserting DOM.
- **The `startKanbanResize` function modifies `document.body.style.userSelect` and `cursor`** — these are global side effects. After a test, the `afterEach` should NOT need to reset them (the original `stopKanbanResize` does that). If a test fails before `mouseup`, the test may leave the body styles in a tweaked state. Add `afterEach(() => { document.body.style.userSelect = ''; document.body.style.cursor = '' })` to the spec file's `afterEach` to be safe.

---

## Verification checklist (post-implementation)

- [ ] `bun run build` clean (vue-tsc + build)
- [ ] `bunx vitest run` all pass (or only pre-existing flakes)
- [ ] `zig build test --summary all` unchanged (backend untouched)
- [ ] `zig build install:linux:system` builds
- [ ] `zig build-obj` cross-compile for Windows + macOS clean
- [ ] Manual smoke on port 8080: 7-step checklist
- [ ] AGENTS.md changelog entry added
- [ ] Branch `worktree/kanban-embed-chatview` pushed + PR opened (or follow project convention)

---

## Out of scope (deferred)

- **Design + chat 3-column** (AppLayout.vue:1904-2015) — structurally identical, but design chats are per-page (not per-task). A separate plan can apply the same refactor.
- **Always-visible chat pane with collapsed state** — UX change, not a relocation. Could be a follow-up.
- **Snap behavior or different resize UX** — current drag-to-resize works; changing it is a separate UX plan.
- **Marquee / layer / drag from layers panel** — already mentioned in `docs/SPEC.md` §5 Pending. Not related to this refactor.
