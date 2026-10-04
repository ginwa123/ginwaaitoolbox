# Kanban Chat: Side-by-Side Pane → Centered Modal Dialog — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current side-by-side `[kanban board] [resize-handle] [ChatView]` layout (kanban-embed-chatview, 2026-08-06) with a centered modal dialog that opens **on top of** the kanban board. The kanban board stays full-width behind a dimmed+blurred backdrop while the chat is open. Click the backdrop, press Esc, or click the dialog's ✕ to close. Clicking a different task card while the dialog is open swaps content (Notion/Linear pattern); the dialog itself stays open.

**Architecture:** New component `KanbanChatDialog.vue` mirrors the established project modal pattern (`KanbanTaskDetailDialog`, `FilePreviewModal`): `<Teleport to="body">`, `fixed inset-0 z-50 flex items-center justify-center p-4`, Esc keydown handler, backdrop click closes, `v-model:show` two-way binding + explicit `close` emit. The dialog wraps `<ChatView :show-header="false">` so we don't double up on headers. `<KanbanView>` loses its chat-pane branch + resize state machine + ChatView import (~376 lines deleted). `<KanbanChatDialog>` is mounted at the `<AppLayout>` level, driven by the existing `workspacesStore.activeTask` + `activeTaskWorkspaceItemId` getters. URL routing for `?view=task&task=<id>` stays in `AppLayout.handleCloseTaskView` — reused unchanged.

**Tech Stack:** Vue 3 (Composition API + `<script setup>`), TypeScript, Pinia, `@vue/test-utils` + Vitest, `node vue-tsc --build` for type-check. No backend changes, no migration.

**Spec:** `docs/superpowers/specs/2026-08-06-kanban-chat-as-dialog-design.md` (approved).

**Worktree:** `/home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog` on branch `worktree/kanban-chat-dialog`.

---

## Global Constraints

- **Cross-platform**: every feature MUST work on Linux, macOS, AND Windows. Verify with `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc ...` and `... -target aarch64-macos -lc ...` at the end of the plan.
- **No static-contract tests**: ALL tests are behavioural. No `expect(source).toContain(...)` / `indexOf(u8, source, ...)` patterns anywhere.
- **No port 8081**: smoke tests use port 8080.
- **Behavioural Vue tests use `@vue/test-utils` `mount` with `setActivePinia(createPinia())`** in `beforeEach`. Mock fetch via `vi.fn()` returning `{ ok, status, json, text }` shape.
- **TDD discipline**: every implementation task starts with a failing test, then minimal code to make it pass, then a commit.
- **Teleport-based dialog tests** must use `attachTo: document.body` and `document.querySelector(...)` for DOM assertions (not `wrapper.find(...)` for teleported content). See `.pabrik/skills/vue-teleport-vitest-document-queryselector/SKILL.MD`.
- **Pure architectural relocation**: no UX changes beyond what the design spec specifies. The dialog size, the close affordances, and the existing `:key` strategy are locked in the spec.
- **`useChatScrollRestore` works transparently**: the composable binds to the VirtualScroller ref inside ChatView, which is the same in dialog mode. No changes to `useChatScrollRestore` or its tests.

---

## File map

| File | Action | Why |
|---|---|---|
| `src/apps/desktop/src/components/kanban/KanbanChatDialog.vue` | NEW | Centered modal dialog wrapping `<ChatView :show-header="false">` |
| `src/apps/desktop/src/components/kanban/KanbanView.vue` | EDIT | Delete chat-pane branch + resize state machine + ChatView import (~376 lines) |
| `src/apps/desktop/src/components/AppLayout.vue` | EDIT | Add `<KanbanChatDialog>` mount (driven by `activeTask` + `activeTaskWorkspaceItemId`) |
| `src/apps/desktop/src/__tests__/KanbanChatDialog.spec.ts` | NEW | Behavioural tests for the new dialog (open, close, content swap) |
| `src/apps/desktop/src/__tests__/KanbanView.chatPane.spec.ts` | DELETE | Tests for the deleted chat-pane branch (no longer applicable) |
| `docs/SPEC.md` | EDIT | Add §10.2.1 PR index row; update Kanban layout §3.7 entry |
| `PABRIK.md` | EDIT | Append "### 2026-08-06: kanban chat as centered dialog" changelog entry |

Total: **7 files** (2 NEW, 4 EDIT, 1 DELETE). No backend changes, no migration, no Zig changes.

---

## Task 1: Build `KanbanChatDialog.vue` (TDD)

**Why:** Before we wire it into AppLayout, we need a working dialog component. This task builds it test-first with the full close-affordance matrix (backdrop, Esc, ✕) and the content-swap invariant.

**Files:**
- `src/apps/desktop/src/components/kanban/KanbanChatDialog.vue` — NEW
- `src/apps/desktop/src/__tests__/KanbanChatDialog.spec.ts` — NEW

### Step 1.1: Write the failing tests

Create `src/apps/desktop/src/__tests__/KanbanChatDialog.spec.ts` with EIGHT behavioural tests:

```ts
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, flushPromises } from '@vue/test-utils'
import KanbanChatDialog from '../components/kanban/KanbanChatDialog.vue'
import type { Task } from '../stores/workspaces'

const TASK_A: Task = {
  id: 'task_a',
  name: 'Task Alpha',
  description: '',
} as Task

const TASK_B: Task = {
  id: 'task_b',
  name: 'Task Beta',
  description: '',
} as Task

function mountDialog(props: Record<string, unknown>) {
  return mount(KanbanChatDialog, {
    props,
    attachTo: document.body,
  })
}

describe('KanbanChatDialog', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
  })

  it('does not render when show=false', async () => {
    const wrapper = mountDialog({ show: false, task: TASK_A, workspaceId: 'ws_1', itemId: 'item_1', projectName: 'Sprint', cwd: '' })
    await flushPromises()
    expect(document.querySelector('[data-testid="kanban-chat-dialog"]')).toBeNull()
  })

  it('renders when show=true with a task', async () => {
    const wrapper = mountDialog({ show: true, task: TASK_A, workspaceId: 'ws_1', itemId: 'item_1', projectName: 'Sprint', cwd: '' })
    await flushPromises()
    expect(document.querySelector('[data-testid="kanban-chat-dialog"]')).not.toBeNull()
    expect(document.querySelector('[data-testid="kanban-chat-dialog-title"]')?.textContent).toContain('Task Alpha')
  })

  it('emits update:show=false when backdrop is clicked', async () => {
    const wrapper = mountDialog({ show: true, task: TASK_A, workspaceId: 'ws_1', itemId: 'item_1', projectName: 'Sprint', cwd: '' })
    await flushPromises()
    const backdrop = document.querySelector('[data-testid="kanban-chat-dialog-backdrop"]') as HTMLElement
    expect(backdrop).not.toBeNull()
    backdrop.click()
    await flushPromises()
    expect(wrapper.emitted('update:show')).toBeTruthy()
    expect(wrapper.emitted('update:show')?.at(-1)).toEqual([false])
  })

  it('does NOT close when click inside the dialog panel (not backdrop)', async () => {
    const wrapper = mountDialog({ show: true, task: TASK_A, workspaceId: 'ws_1', itemId: 'item_1', projectName: 'Sprint', cwd: '' })
    await flushPromises()
    const panel = document.querySelector('[data-testid="kanban-chat-dialog"]') as HTMLElement
    panel.click()
    await flushPromises()
    expect(wrapper.emitted('update:show')).toBeFalsy()
    expect(wrapper.emitted('close')).toBeFalsy()
  })

  it('emits update:show=false when Escape key is pressed', async () => {
    const wrapper = mountDialog({ show: true, task: TASK_A, workspaceId: 'ws_1', itemId: 'item_1', projectName: 'Sprint', cwd: '' })
    await flushPromises()
    // Dispatch Esc on document (the dialog listens at document level via @keydown on the teleport root).
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await flushPromises()
    expect(wrapper.emitted('update:show')?.at(-1)).toEqual([false])
  })

  it('emits update:show=false when ✕ header button is clicked', async () => {
    const wrapper = mountDialog({ show: true, task: TASK_A, workspaceId: 'ws_1', itemId: 'item_1', projectName: 'Sprint', cwd: '' })
    await flushPromises()
    const closeBtn = document.querySelector('[data-testid="kanban-chat-dialog-close"]') as HTMLElement
    expect(closeBtn).not.toBeNull()
    closeBtn.click()
    await flushPromises()
    expect(wrapper.emitted('update:show')?.at(-1)).toEqual([false])
  })

  it('emits both update:show and close on every close path (backward compat)', async () => {
    const wrapper = mountDialog({ show: true, task: TASK_A, workspaceId: 'ws_1', itemId: 'item_1', projectName: 'Sprint', cwd: '' })
    await flushPromises()
    const backdrop = document.querySelector('[data-testid="kanban-chat-dialog-backdrop"]') as HTMLElement
    backdrop.click()
    await flushPromises()
    expect(wrapper.emitted('update:show')?.at(-1)).toEqual([false])
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('swaps task content when task prop changes (key contract)', async () => {
    const wrapper = mountDialog({ show: true, task: TASK_A, workspaceId: 'ws_1', itemId: 'item_1', projectName: 'Sprint', cwd: '' })
    await flushPromises()
    expect(document.querySelector('[data-testid="kanban-chat-dialog-title"]')?.textContent).toContain('Task Alpha')
    // Switch task — the title should update and ChatView should remount (key changes).
    await wrapper.setProps({ task: TASK_B })
    await flushPromises()
    expect(document.querySelector('[data-testid="kanban-chat-dialog-title"]')?.textContent).toContain('Task Beta')
  })
})
```

### Step 1.2: Run the tests to confirm they fail

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog/src/apps/desktop && timeout 60 bunx vitest run KanbanChatDialog.spec.ts 2>&1 | tail -n 30
```

Expect: 8/8 fail (the component does not exist yet — `mount` will throw `Failed to resolve import`).

### Step 1.3: Create `KanbanChatDialog.vue`

Create `src/apps/desktop/src/components/kanban/KanbanChatDialog.vue`:

```vue
<!--
  KanbanChatDialog — centered modal dialog that hosts the kanban task
  chat. Opens on top of the kanban board (which stays full-width
  behind a dimmed+blurred backdrop). Click backdrop / press Esc /
  click ✕ to close.

  Mirrors the project modal pattern (KanbanTaskDetailDialog,
  FilePreviewModal, KanbanSettingsDialog): <Teleport to="body">,
  fixed inset-0 z-50, Esc keydown, v-model:show + close emit.

  ChatView is mounted with :show-header="false" — the dialog's own
  header carries the task name + ✕ so we don't double up.

  The :key="'task-' + task.id" on <ChatView> preserves the
  useChatScrollRestore scroll position across task switches and
  forces a fresh mount when the user clicks a different task card
  while the dialog is open (Notion/Linear content-swap pattern).

  Public API:
    props:
      show          boolean
      task          Task | null
      workspaceId   string
      itemId        string        (the kanban item id; for context)
      projectName   string        (→ ChatView :project-name)
      cwd           string        (→ ChatView :cwd)
    emits:
      update:show   [value: boolean]  (v-model:show)
      close         []                (backward compat with KanbanSettingsDialog-style binding)
-->
<script setup lang="ts">
import { nextTick, ref, watch } from 'vue'
import ChatView from '../views/ChatView.vue'
import type { Task } from '../../stores/workspaces'

const props = withDefaults(
  defineProps<{
    show: boolean
    task: Task | null
    workspaceId?: string
    itemId?: string
    projectName?: string
    cwd?: string
  }>(),
  {
    workspaceId: '',
    itemId: '',
    projectName: '',
    cwd: '',
  },
)

const emit = defineEmits<{
  'update:show': [value: boolean]
  close: []
}>()

const closeDialog = () => {
  emit('update:show', false)
  emit('close')
}

const handleKeydown = (e: KeyboardEvent) => {
  if (e.key === 'Escape') {
    e.stopPropagation()
    closeDialog()
  }
}

// Focus the dialog wrapper on open so Esc works without a prior click.
// (Do NOT auto-focus the chat input — would steal typing position.)
const dialogRootRef = ref<HTMLDivElement | null>(null)
watch(
  () => props.show,
  async (open) => {
    if (open) {
      await nextTick()
      dialogRootRef.value?.focus()
    }
  },
)
</script>

<template>
  <Teleport to="body">
    <div
      v-if="show"
      ref="dialogRootRef"
      tabindex="-1"
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      @keydown="handleKeydown"
      data-testid="kanban-chat-dialog-root"
    >
      <!-- Backdrop -->
      <div
        class="absolute inset-0 backdrop-blur-md"
        style="background: rgba(0, 0, 0, 0.5);"
        data-testid="kanban-chat-dialog-backdrop"
        @click="closeDialog"
      ></div>

      <!-- Dialog panel -->
      <div
        class="relative flex flex-col rounded-xl shadow-2xl"
        style="
          background: var(--semantic-bg);
          width: 80vw;
          height: 80vh;
          max-width: 1100px;
          max-height: 800px;
          min-width: 480px;
          min-height: 320px;
        "
        data-testid="kanban-chat-dialog"
        @click.stop
      >
        <!-- Header -->
        <header
          class="flex items-center gap-3 px-4 py-2 shrink-0"
          style="border-bottom: 1px solid var(--color-border);"
        >
          <h3
            class="text-sm font-semibold truncate flex-1"
            style="color: var(--semantic-text);"
            data-testid="kanban-chat-dialog-title"
          >
            💬 {{ task?.name || 'Chat' }}
          </h3>
          <button
            type="button"
            class="px-2 py-1 rounded text-xs hover:opacity-80"
            style="color: var(--semantic-text-muted);"
            data-testid="kanban-chat-dialog-close"
            @click="closeDialog"
          >
            ✕
          </button>
        </header>

        <!-- Chat body (ChatView with internal header suppressed) -->
        <ChatView
          v-if="task"
          :key="'task-' + task.id"
          :chat-id="task.id"
          :chat-name="task.name"
          type="task"
          :cwd="cwd"
          :task-id="task.id"
          :task-name="task.name"
          :project-name="projectName"
          :show-header="false"
          @close="closeDialog"
        />
      </div>
    </div>
  </Teleport>
</template>
```

### Step 1.4: Run the tests to confirm they pass

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog/src/apps/desktop && timeout 60 bunx vitest run KanbanChatDialog.spec.ts 2>&1 | tail -n 40
```

Expect: 8/8 pass. If the "Esc" test fails, the most likely cause is that the keydown event is dispatched on `document` but the listener is on the dialog wrapper (not document). Update the test to dispatch on the wrapper element instead, OR add a document-level listener (recommended — see Pitfalls).

**If Esc fails**, prefer fixing the component to add a document-level listener (`onMounted(() => document.addEventListener('keydown', handleKeydown))` + `onUnmounted` cleanup) rather than the test, because users expect Esc anywhere on the page to close the dialog.

### Step 1.5: Verify type-check

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog/src/apps/desktop && timeout 120 node node_modules/vue-tsc/bin/vue-tsc.js -b 2>&1 | tail -n 20
```

Expect: clean exit.

### Step 1.6: Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog
git add -A
git commit -m "feat(kanban): add KanbanChatDialog centered modal wrapping ChatView

The dialog is mounted at AppLayout level (Task 2) and opens when a
kanban task is active. Mirrors the project modal pattern: Teleport to
body, fixed inset-0 backdrop with blur, Esc keydown, v-model:show +
close emit. ChatView is mounted with :show-header=false to avoid
double headers. The :key='task-' + task.id contract preserves
useChatScrollRestore scroll position across task switches.

Co-authored-by: session_1785598425276"
```

---

## Task 2: Mount `KanbanChatDialog` in `AppLayout.vue`

**Why:** Now that the dialog component is built and tested, wire it into AppLayout so it actually opens when the user navigates to a kanban task. The mount is driven by the existing `workspacesStore.activeTask` + `activeTaskWorkspaceItemId` getters (added in the kanban-embed-chatview plan).

**Files:**
- `src/apps/desktop/src/components/AppLayout.vue` — EDIT
- `src/apps/desktop/src/__tests__/AppLayout.kanbanChatDialog.spec.ts` — NEW

### Step 2.1: Write the failing tests

Create `src/apps/desktop/src/__tests__/AppLayout.kanbanChatDialog.spec.ts` with FOUR behavioural tests:

```ts
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, flushPromises } from '@vue/test-utils'
import { ref } from 'vue'
import AppLayout from '../components/AppLayout.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem, Task } from '../stores/workspaces'

const WS_ID = 'ws_1'
const KANBAN_ITEM_ID = 'item_kanban_1'
const DESIGN_ITEM_ID = 'item_design_1'
const TASK_ID = 'task_1'

function makeKanbanItem(overrides: Partial<WorkspaceItem> = {}): WorkspaceItem {
  return {
    id: KANBAN_ITEM_ID,
    name: 'Sprint A',
    item_type: 'kanban',
    kanban_columns: [],
    tasks: [],
    ...overrides,
  } as WorkspaceItem
}

function setupActiveKanbanTask(store: ReturnType<typeof useWorkspacesStore>) {
  store.workspaces = [{
    id: WS_ID,
    name: 'WS',
    items: [
      makeKanbanItem(),
      { id: DESIGN_ITEM_ID, name: 'Design', item_type: 'design' } as WorkspaceItem,
    ],
  }] as any
  store.setActiveWorkspaceItem(KANBAN_ITEM_ID)
  store.setActiveTask(TASK_ID)
}

describe('AppLayout — kanban chat dialog wiring', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
  })

  it('does NOT render KanbanChatDialog when no task is active', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [{ id: WS_ID, name: 'WS', items: [makeKanbanItem()] }] as any
    store.setActiveWorkspaceItem(KANBAN_ITEM_ID)
    mount(AppLayout, {
      attachTo: document.body,
      global: { provide: { processingState: ref({}) } },
    })
    await flushPromises()
    expect(document.querySelector('[data-testid="kanban-chat-dialog"]')).toBeNull()
  })

  it('renders KanbanChatDialog when active task belongs to a kanban item', async () => {
    const store = useWorkspacesStore()
    setupActiveKanbanTask(store)
    mount(AppLayout, {
      attachTo: document.body,
      global: { provide: { processingState: ref({}) } },
    })
    await flushPromises()
    expect(document.querySelector('[data-testid="kanban-chat-dialog"]')).not.toBeNull()
  })

  it('does NOT render KanbanChatDialog when active task belongs to a non-kanban item', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [{
      id: WS_ID,
      name: 'WS',
      items: [
        makeKanbanItem({ tasks: [{ id: 'other_task', name: 'Other' } as Task] } as any),
        { id: DESIGN_ITEM_ID, name: 'Design', item_type: 'design', tasks: [{ id: TASK_ID, name: 'Design Task' } as Task] } as any,
      ],
    }] as any
    store.setActiveWorkspaceItem(KANBAN_ITEM_ID)
    store.setActiveTask(TASK_ID) // TASK_ID is under DESIGN_ITEM_ID, not KANBAN_ITEM_ID
    mount(AppLayout, {
      attachTo: document.body,
      global: { provide: { processingState: ref({}) } },
    })
    await flushPromises()
    expect(document.querySelector('[data-testid="kanban-chat-dialog"]')).toBeNull()
  })

  it('renders dialog header with the active task name', async () => {
    const store = useWorkspacesStore()
    setupActiveKanbanTask(store)
    mount(AppLayout, {
      attachTo: document.body,
      global: { provide: { processingState: ref({}) } },
    })
    await flushPromises()
    // The active task has the default name from setupActiveKanbanTask — but it's empty.
    // The test fixture should provide a named task; update setupActiveKanbanTask to include name.
    const title = document.querySelector('[data-testid="kanban-chat-dialog-title"]')
    // If the title element exists, it must not be null. (Name content depends on the task fixture.)
    expect(title).not.toBeNull()
  })
})
```

Update `setupActiveKanbanTask` to set a task with a name so the title assertion is meaningful:

```ts
function setupActiveKanbanTask(store: ReturnType<typeof useWorkspacesStore>) {
  store.workspaces = [{
    id: WS_ID,
    name: 'WS',
    items: [
      { ...makeKanbanItem(), tasks: [{ id: TASK_ID, name: 'Hello Task' } as Task] },
      { id: DESIGN_ITEM_ID, name: 'Design', item_type: 'design' } as WorkspaceItem,
    ],
  }] as any
  store.setActiveWorkspaceItem(KANBAN_ITEM_ID)
  store.setActiveTask(TASK_ID)
}
```

### Step 2.2: Run the tests to confirm they fail

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog/src/apps/desktop && timeout 60 bunx vitest run AppLayout.kanbanChatDialog.spec.ts 2>&1 | tail -n 30
```

Expect: 4/4 fail (no KanbanChatDialog mount in AppLayout yet).

### Step 2.3: Add the mount to `AppLayout.vue`

In `src/apps/desktop/src/components/AppLayout.vue`:

1. **Add the import** next to the existing `KanbanView` import (around line 30-40):
   ```ts
   import KanbanChatDialog from './components/kanban/KanbanChatDialog.vue'
   ```

2. **Add a computed `activeKanbanItem`** (around the existing `activeTaskWorkspaceItemId` reference area):
   ```ts
   const activeKanbanItem = computed(() => {
     const item = activeWorkspaceItem.value
     return item?.item_type === 'kanban' ? item : null
   })
   ```

   If `activeWorkspaceItem` is not already a computed in AppLayout, use whatever the existing variable name is for the active workspace item — search the file for `activeWorkspaceItem` to confirm.

3. **Add the mount** next to the existing `<KanbanView>` mount (find the v-else-if block that mounts KanbanView). Insert the dialog mount INSIDE that v-else-if block, AFTER the `<KanbanView>` element:
   ```vue
   <KanbanChatDialog
     v-if="activeTaskWorkspaceItemId === activeWorkspaceItem.id && activeTask"
     v-model:show="kanbanChatDialogOpen"
     :task="activeTask"
     :workspace-id="activeWorkspace?.id ?? ''"
     :item-id="activeWorkspaceItem.id"
     :project-name="activeWorkspaceItem.name ?? ''"
     :cwd="activeWorkspaceItem.path ?? ''"
     @close="handleCloseTaskView"
   />
   ```

   Where `kanbanChatDialogOpen` is a new local `ref<boolean>` (since v-model:show needs a writable binding):
   ```ts
   const kanbanChatDialogOpen = ref(false)
   watch(
     () => activeTask.value,
     (t) => {
       kanbanChatDialogOpen.value = !!t
     },
     { immediate: true },
   )
   ```

   **Why a watch on activeTask?** The dialog visibility must stay in sync with the URL-driven `activeTask`. When the user clicks a task card, `activeTask` is set → dialog opens. When the user navigates away, `activeTask` is cleared → dialog closes. The watch keeps the v-model:show binding in sync.

4. **Reuse** `handleCloseTaskView` (already exists in AppLayout) — it strips `?view=task&task=<id>` from the URL and clears `workspacesStore.activeTask`. No changes.

### Step 2.4: Run the tests to confirm they pass

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog/src/apps/desktop && timeout 60 bunx vitest run AppLayout.kanbanChatDialog.spec.ts 2>&1 | tail -n 40
```

Expect: 4/4 pass.

### Step 2.5: Run existing AppLayout tests for regressions

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog/src/apps/desktop && timeout 60 bunx vitest run AppLayout.kanban.spec.ts AppLayout.chatview.spec.ts 2>&1 | tail -n 40
```

Expect: all pass. AppLayout's existing wiring is unchanged; we're purely additive (a new mount that gates on `activeTaskWorkspaceItemId === activeWorkspaceItem.id`).

### Step 2.6: Verify type-check

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog/src/apps/desktop && timeout 120 node node_modules/vue-tsc/bin/vue-tsc.js -b 2>&1 | tail -n 20
```

Expect: clean exit.

### Step 2.7: Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog
git add -A
git commit -m "feat(applayout): mount KanbanChatDialog driven by activeTask

When the user navigates to a kanban task, the dialog opens centered
on top of the kanban board. URL routing (?view=task&task=<id>) is
unchanged — AppLayout's existing handleCloseTaskView clears the
activeTask on @close. Visibility is gated by
activeTaskWorkspaceItemId === activeWorkspaceItem.id so the dialog
only opens for kanban items (design + routine use their own mounts).

Co-authored-by: session_1785598425276"
```

---

## Task 3: Refactor `KanbanView.vue` — remove chat-pane branch + resize state

**Why:** The dialog is mounted at AppLayout now, so KanbanView no longer needs its internal chat-pane branch, the resize state machine, or the ChatView import. This is pure deletion — ~376 lines removed.

**Files:**
- `src/apps/desktop/src/components/kanban/KanbanView.vue` — EDIT (deletions)

### Step 3.1: Verify current KanbanView tests still pass before changes

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog/src/apps/desktop && timeout 60 bunx vitest run KanbanView.spec.ts KanbanView.chatPane.spec.ts KanbanView.searchFilter.spec.ts 2>&1 | tail -n 30
```

Expect: all pass (baseline before deletion).

### Step 3.2: Delete the resize state machine

In `KanbanView.vue`, delete lines 106-211 (the entire resize block):

- Lines 106-134: comment block + constants `KANBAN_MIN_WIDTH`, `KANBAN_MAX_WIDTH`, `KANBAN_DEFAULT_WIDTH`, `KANBAN_WIDTH_STORAGE_KEY`.
- Lines 136-143: `loadKanbanColumnWidth` function.
- Lines 145-148: the four refs (`kanbanColumnWidth`, `isKanbanResizing`, `kanbanResizeStartX`, `kanbanResizeStartWidth`).
- Lines 150-166: `startKanbanResize` function.
- Lines 168-177: `handleKanbanResize` function.
- Lines 179-195: `stopKanbanResize` function.
- Lines 197-211: `kanbanColumnStyle` computed.

Use `text_replace` with the exact start/end of this block. Read the file first to confirm the boundaries.

### Step 3.3: Delete the chat-pane-related computed derives

In `KanbanView.vue`, delete lines 93-104 (the activeTask / activeTaskWorkspaceItemId / showChatPane computed block) AND lines 213-216 (the `close-chat` emit comment).

The comment block at lines 227-247 (about "Horizontal scroll position preservation") references `data-kanban-three-column` which no longer exists. Update the comment to remove that reference (the kanban-column horizontal scroll preservation is still real, just no longer referenced as part of a layout transition).

### Step 3.4: Delete the ChatView import

In `KanbanView.vue`, line 62: delete `import ChatView from '../views/ChatView.vue'`.

### Step 3.5: Delete the chat-pane branch in the template

In `KanbanView.vue`'s `<template>`:

1. **Remove the v-if wrapper** at line 742: `<template v-if="!showChatPane">` → delete this line and the closing `</template>` at line 873. The board content (header + columns row) becomes the unconditional body.

2. **Delete the v-else branch** (lines 880-980): the entire `<div v-else class="flex-1 flex min-h-0" data-kanban-with-chat>` block, including:
   - The board column wrapper (lines 885-942 — duplicated header + columns row + KanbanColumn mount)
   - The resize handle div (lines 944-964)
   - The chat-side wrapper + ChatView mount (lines 965-979)

3. **Update comment block** at lines 732-741 to remove the "Layout branches" description (no longer branching).

### Step 3.6: Verify KanbanView is back to single full-width board

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog/src/apps/desktop && timeout 60 bunx vitest run KanbanView.spec.ts KanbanView.searchFilter.spec.ts KanbanView.createTask.spec.ts 2>&1 | tail -n 30
```

Expect: all pass. The `KanbanView.chatPane.spec.ts` tests will fail at this point because `data-kanban-with-chat` no longer exists. This is expected — we delete that file in Task 4.

### Step 3.7: Verify type-check

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog/src/apps/desktop && timeout 120 node node_modules/vue-tsc/bin/vue-tsc.js -b 2>&1 | tail -n 20
```

Expect: clean exit.

### Step 3.8: Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog
git add -A
git commit -m "refactor(kanban): remove chat-pane branch + resize state from KanbanView

KanbanView now renders only the full-width board (the dialog is
mounted at AppLayout level). Deletes:
- the chat-pane v-else-if branch (was data-kanban-with-chat wrapper
  with duplicated header + columns + KanbanColumn + ChatView mount)
- the kanban-column resize state machine (KANBAN_MIN_WIDTH,
  KANBAN_MAX_WIDTH, kanbanColumnWidth, isKanbanResizing,
  startKanbanResize, handleKanbanResize, stopKanbanResize,
  kanbanColumnStyle + localStorage key 'kanban-column-width')
- the ChatView import
- the showChatPane + activeTask + activeTaskWorkspaceItemId computed
  derives

Net: KanbanView 1056 → ~680 lines.

Co-authored-by: session_1785598425276"
```

---

## Task 4: Delete `KanbanView.chatPane.spec.ts` and any stale references

**Why:** With the chat pane removed from KanbanView, the chatPane tests reference selectors that no longer exist. The coverage migrates to `KanbanChatDialog.spec.ts` (Task 1).

**Files:**
- `src/apps/desktop/src/__tests__/KanbanView.chatPane.spec.ts` — DELETE

### Step 4.1: Confirm no other code references the deleted selectors

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog && rg -l 'data-kanban-with-chat|data-kanban-resize-handle|kanban-column-width' src/ 2>&1 | head -n 20
```

Expect: only `KanbanChatDialog.spec.ts` (the new tests) and possibly `AppLayout.kanban.spec.ts` if it referenced the old selectors. If the latter appears, update those references to remove the chat-pane assertions.

### Step 4.2: Delete the file

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog && git rm src/apps/desktop/src/__tests__/KanbanView.chatPane.spec.ts 2>&1
```

### Step 4.3: Run the full frontend test suite

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog/src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 40
```

Expect: all tests pass. The 8 deleted `KanbanView.chatPane.spec.ts` tests are gone. The new 8 `KanbanChatDialog.spec.ts` tests + 4 `AppLayout.kanbanChatDialog.spec.ts` tests cover the same behavior at the dialog layer.

### Step 4.4: Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog
git add -A
git commit -m "test(kanban): delete obsolete KanbanView.chatPane tests

The chat pane branch is gone from KanbanView (moved to AppLayout-level
KanbanChatDialog). Coverage now lives in KanbanChatDialog.spec.ts
(dialog close paths) and AppLayout.kanbanChatDialog.spec.ts (mount
wiring).

Co-authored-by: session_1785598425276"
```

---

## Task 5: Final verification (cross-platform, type-check, build, smoke)

**Why:** The pre-commit checklist (per AGENTS.md §"Pre-commit checklist") is non-negotiable. This task verifies everything is green before declaring done.

### Step 5.1: Run frontend type-check

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog/src/apps/desktop
timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js -b 2>&1 | tail -n 20
```

Expect: clean exit.

### Step 5.2: Run the full frontend test suite

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog/src/apps/desktop
timeout 180 bunx vitest run 2>&1 | tail -n 30
```

Expect: all tests pass (or only pre-existing flakes documented in AGENTS.md).

### Step 5.3: Run the backend test suite

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog
timeout 180 zig build test --summary all 2>&1 | tail -n 30
```

Expect: same or better pass count as before the refactor (backend is untouched).

### Step 5.4: Build the Linux binary

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog
timeout 180 zig build install:linux:system 2>&1 | tail -n 20
```

Expect: builds successfully.

### Step 5.5: Build the frontend bundle

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog/src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 20
```

Expect: builds successfully (vue-tsc + Vite build).

### Step 5.6: Manual smoke (port 8080)

The dev `pabrik` runs on port 8081 — leave it alone. Spin up a fresh instance on port 8080:

```bash
# Start pabrik on port 8080 in the background (use a tmp HOME)
TMPHOME=$(mktemp -d /tmp/pabrik-smoke-XXXX)
HOME="$TMPHOME" /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog/zig-out/bin/pabrik --port 8080 --static-dir /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog/src/apps/desktop/dist &
PABRIK_PID=$!
sleep 3

# Wait for health
for i in 1 2 3 4 5; do
  curl -sf http://localhost:8080/api/health && break
  sleep 1
done

# Cleanup
kill $PABRIK_PID
rm -rf "$TMPHOME"
```

Manual smoke checklist (open the app in a browser pointing at port 8080):

1. Open a kanban → board alone, no chat.
2. Click a task → dialog opens centered, chat visible, kanban board visible behind dimmed backdrop.
3. Press `Esc` → dialog closes; URL strips `view=task&task=<id>`; kanban board back to full-width.
4. Click backdrop → dialog closes (same as Esc).
5. Click `✕` in dialog header → dialog closes (same).
6. Click inside dialog (chat body) → dialog stays open; no accidental close.
7. Open task A → while dialog is open, click task B card → dialog stays open, content swaps to B.
8. Open task A → scroll up → close dialog → reopen task A → scroll position restored.

### Step 5.7: Cross-compile smoke tests (Windows + macOS)

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep pabrikcore -Mroot=/tmp/test_mod.zig -Mpabrikcore=src/root.zig 2>&1 | tail -n 20
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep pabrikcore -Mroot=/tmp/test_mod.zig -Mpabrikcore=src/root.zig 2>&1 | tail -n 20
```

Expect: both compile clean.

---

## Task 6: Update AGENTS.md and docs/SPEC.md

**Why:** Per project convention (AGENTS.md §"Recent changes" + SPEC.md §10.2.1 PR index), every merged feature lands a changelog entry + a PR index row.

### Step 6.1: Append to AGENTS.md

In `/home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog/PABRIK.md`, append a new `### 2026-08-06: ...` block to the "Recent changes (changelog)" section. Pattern follows the 2026-08-06 entries.

```markdown
### 2026-08-06: Kanban chat — side-by-side pane → centered modal dialog

**Symptom (pre-fix).** Opening a kanban task reshaped the layout into
`[kanban 40%][resize-handle][ChatView 60%]` (kanban-embed-chatview,
2026-08-06). The board shrank every time a task was opened, and
closing meant "back to full width but the chat pane was the default
UX." For a focused kanban, the board is the hero and the chat is a
focused event.

**What landed.** New `KanbanChatDialog.vue` component (Teleport to
body, fixed inset-0 backdrop, Esc + backdrop + ✕ close paths) wraps
`<ChatView :show-header="false">`. Mounted at `<AppLayout>` level,
driven by the existing `activeTask` + `activeTaskWorkspaceItemId`
getters. `<KanbanView>` loses its chat-pane branch + resize state
machine + ChatView import — net 1056 → ~680 lines. URL routing is
unchanged (AppLayout's `handleCloseTaskView` reused for close).

**Click-different-task-while-open** swaps content via `:key="'task-' +
newTask.id"` (Notion/Linear pattern); the dialog itself stays open.
Chat scroll position is preserved across open/close via
`useChatScrollRestore` (same per-task-id storage).

**Selectors.** Old `data-kanban-with-chat` / `data-kanban-resize-handle`
(kanban-embed-chatview) → removed. New `data-testid="kanban-chat-dialog"`
+ `data-testid="kanban-chat-dialog-backdrop"` +
`data-testid="kanban-chat-dialog-close"` + `data-testid="kanban-chat-dialog-title"`.

**Out of scope.** Design mode chat (`AppLayout.vue:1864` + `:1904`)
stays as 3-column with resize handle. Different chat-per-page model;
separate plan can apply the same refactor when desired.
```

### Step 6.2: Add PR index row to docs/SPEC.md

In `/home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog/docs/SPEC.md`, find the §10.2.1 PR index table (or wherever recent PRs are listed). Add a row:

```markdown
| kanban-chat-as-dialog | 2026-08-06 | Kanban chat side-by-side pane → centered modal dialog |
```

(Adjust column order if the table uses a different shape.)

### Step 6.3: Update §3.7 Kanban layout description

Find the existing §3.7 entry for kanban layout (the kanban-embed-chatview description). Update it to describe the dialog:

```markdown
**Layout.** When the user navigates to a kanban task, the board stays
full-width behind a dimmed+blurred backdrop; the chat opens in a
centered `<KanbanChatDialog>` modal on top. Click backdrop, press Esc,
or click the dialog's ✕ to close. Clicking a different task card while
the dialog is open swaps the content (Notion/Linear pattern); the
dialog stays open.
```

### Step 6.4: Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog
git add -A
git commit -m "docs(agents,spec): changelog + PR index for kanban-chat-as-dialog

Co-authored-by: session_1785598425276"
```

---

## Pitfalls

- **`data-kanban-with-chat` selector coupling** — referenced in old `KanbanView.chatPane.spec.ts`. Delete in Task 4; don't try to keep the selector alive.
- **The `:key="'task-' + task.id"` contract** is critical. Without it, switching tasks while the dialog is open DOES NOT swap the chat content — Vue reuses the existing ChatView instance with the old props. Tests must verify the title element updates when `task` prop changes.
- **The Esc keydown listener** must catch Esc from anywhere on the page, not just when the dialog wrapper has focus. Prefer a document-level listener (`onMounted` add / `onUnmounted` remove) OR `@keydown.esc` on the teleport root with `tabindex="-1"` and a `focus()` call on open (the component does the latter).
- **The chat input auto-focus** is intentionally NOT applied — would steal the user's typing position from a previously-open chat. Test the dialog with `dialogRootRef.focus()` only.
- **Body scroll lock** is intentionally NOT applied — matches `KanbanTaskDetailDialog` behavior. Don't add it "for UX"; the project pattern is no lock.
- **Teleport-based dialog tests** must use `attachTo: document.body` AND `document.querySelector(...)` for assertions (not `wrapper.find(...)`). The teleported content is NOT in the wrapper's DOM tree.
- **The dialog wrapper's `@click.stop`** prevents inner clicks from bubbling to the backdrop. WITHOUT it, clicking inside the dialog would also fire the backdrop's `@click="closeDialog"`.
- **The `kanban-column-width` localStorage key** is orphaned but harmless. Users who had a saved width during the kanban-embed-chatview era (2026-08-06) will have a stale value that nothing reads. Don't migrate; ignore.
- **`activeTaskWorkspaceItemId` getter is already in the store** (added in kanban-embed-chatview plan). AppLayout already uses it. The dialog mount just adds a consumer.
- **The `data-kanban-three-column` selector** is gone (it was AppLayout-level from a prior era). The new mount uses `activeTaskWorkspaceItemId === activeWorkspaceItem.id` for gating.
- **The `vue-teleport-vitest-document-queryselector` skill** is mandatory reading for this task — `attachTo: document.body` + `document.querySelector` is the only way to assert teleported DOM.
- **`vue-tsc --build` emits `.js` files** next to `.ts` source files in this project. Delete them before committing (per `.pabrik/skills/vue-tsc-build-emits-js-files/SKILL.MD`).
- **The `useChatScrollRestore` composable** works transparently in dialog mode — the VirtualScroller ref is the same. Don't touch the composable or its tests.

---

## Verification checklist (post-implementation)

- [ ] `bun run build` clean (vue-tsc + build)
- [ ] `bunx vitest run` all pass (or only pre-existing flakes)
- [ ] `zig build test --summary all` unchanged (backend untouched)
- [ ] `zig build install:linux:system` builds
- [ ] `zig build-obj` cross-compile for Windows + macOS clean
- [ ] Manual smoke on port 8080: 8-step checklist
- [ ] AGENTS.md changelog entry added
- [ ] docs/SPEC.md §3.7 + §10.2.1 updated
- [ ] `vue-tsc --build` `.js` artifact files deleted
- [ ] Branch `worktree/kanban-chat-dialog` pushed + PR opened (or follow project convention)

---

## Out of scope (deferred)

- **Design chat (`AppLayout.vue:1864` + `:1904`)** — design canvas + chat 3-column block stays as-is. Different chat-per-page model. Can be migrated in a follow-up plan.
- **Body scroll lock + focus trap** — matches existing `KanbanTaskDetailDialog` behavior (no lock, no trap). Easy to add in a follow-up if user feedback wants it.
- **Auto-focus the chat input on open** — would steal typing position from a previously-open chat. Intentional omission.
- **Drag-to-resize the dialog** — fixed size (80vw × 80vh, max 1100×800). Matches "focused modal" pattern.
- **Animation choreography** — Vue `<Transition>` with default fade+scale (200ms). No custom easing.
- **Migration of `kanban-column-width` localStorage key** — orphan value is harmless.
- **Marquee / multiple chats open at once** — single active chat at a time.
- **Snap behavior or different resize UX** — N/A (no resize).
- **Marquee / layer / drag from layers panel** — already in `docs/SPEC.md` §5 Pending. Not related to this refactor.