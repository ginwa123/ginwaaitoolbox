# Kanban "Create task & run agent" — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a secondary `▶ Create task & run agent` button to the New Task dialog (`KanbanTaskDetailDialog`, mode `'create'`). The button creates the task, queues `title + '\n\n' + description` as the first user message via `POST /api/llm/session`, and routes the user to the new task's chat view via the existing `selectTask` event. Mirrors the routine `Run now` flow but at create time for standard tasks.

**Architecture:** Three frontend files + three test files. No backend, no migration, no Zig changes. The store action `runAgentOnNewTask` wraps `api.sendChatMessage` for future reuse. The dialog adds a sibling emit `create-and-run` (same payload shape as the existing `create`, different `mode` discriminator). `KanbanView.handleCreateTaskSave` branches on `mode` and reuses the existing `selectTask` emit to navigate (the existing `AppLayout → Sidebar` chain handles `setActiveTask` + `router.replace`).

**Tech Stack:** Vue 3 + TypeScript + Pinia + Vitest (`@vue/test-utils`). No new dependencies.

## Design Decisions (review before execution)

| ID | Decision | Why | Alternative rejected |
|----|----------|-----|----------------------|
| D1 | **Reuse the existing `selectTask` emit** for navigation, no new event | `selectTask` is already plumbed through AppLayout → Sidebar and does `setActiveTask` + `router.replace({ view: 'task', task })`. Adding a new `create-and-run-task` event duplicates the routing logic. | New event `create-and-run-task` — adds a second navigation handler that does the same thing. |
| D2 | **Single emit name `create-and-run`** with `mode: 'create_and_run'` discriminator | Mirrors the existing `create` / `save` payload shape (same fields, different `mode`). One handler in `KanbanView` switches on `mode`. | Two separate emits (`create` + `create-and-run`) — duplicate payload types, duplicate handlers. |
| D3 | **Queued message: `title + '\n\n' + description`** when description non-empty, else just `title` | Q1 = B, Q2 = 2b from the brainstorm. The `\n\n` is markdown paragraph break; chatview renders markdown. | Treat description as a separate user turn (2 messages) — overcomplicates the flow. |
| D4 | **Outlined secondary button** next to the primary `Create task` | The primary stays the safe default for users who want a placeholder task. Discoverability via hover + tooltip. | Filled gradient — hides the safe option behind a destructive-style action. |
| D5 | **Button enabled whenever name is non-empty** (description NOT required) | Q2 = 2b. Empty description → queued message is just the title. The agent may ask for clarification but the button works. | Disable when description empty (2a) — forces extra typing for the common case. |
| D6 | **Unattended toggle flows through** | Q3 = 3a. Toggle forwards as `is_auto_retry_until_stop` to `sendChatMessage`. Matches the existing routine fire path. | Force on / force off — surprises users who flipped the toggle. |
| D7 | **Partial-success: don't navigate if `sendChatMessage` fails** | The task exists, the user can click the card. Surface a `notifyError` toast. Never strand the user. | Navigate anyway — chatview opens with an empty session and no agent run. |
| D8 | **Store action wraps `api.sendChatMessage`** even though it's a 1-line forward | Gives a single owner of the cross-component contract (logging, future audit, future reuse for "run agent on existing task"). | Inline `api.sendChatMessage` in `KanbanView` — leaks the wire shape into the component. |
| D9 | **Tests live at the bottom of their impl files** for `addTask` siblings; the new tests live in dedicated `*.spec.ts` files for behavioural coverage | Matches the repo convention (see `KanbanTaskDetailDialog.spec.ts`, `useDesignHandlers.spec.ts`). | Static-contract tests in `_test.zig`-style — user rule forbids. |

## Global Constraints

- **Cross-platform**: every feature MUST work on Linux, macOS, AND Windows. This change is frontend-only — verify with `bun run build` (vue-tsc typecheck) + `bunx vitest run` (behavioural).
- **No static-contract tests**: ALL tests are behavioural. No `expect(source).toContain(...)` patterns. See `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md`.
- **TDD discipline**: every implementation step starts with a failing test, then minimal code to make it pass, then a commit.
- **`bun run build` IS the type-check**: every frontend commit must pass `bun run build` (which runs `vue-tsc` under node); `bunx vitest run` alone does NOT catch type errors — see `.nalar/memories/nalar-frontend-patterns.md`.
- **Behavioural Vue tests** use `@vue/test-utils` `mount` with `setActivePinia(createPinia())` in `beforeEach`. Mock fetch via `vi.fn()` returning `{ ok, status, json, text }` shape.
- **Teleport-based components**: `KanbanTaskDetailDialog` uses `<Teleport to="body">`. Use `attachTo: document.body` and `document.querySelector` for assertions (NOT `wrapper.find`). See `.nalar/skills/vue-teleport-vitest-document-queryselector/SKILL.MD`.
- **No port 8081**: smoke tests use port 8080 (the always-running dev `nalar` on 8081 is off-limits).
- **NO new comments above `logger.infoFmt(...)` calls** (see `~/.config/nalar/memories/no-comments-on-logger-calls.md`).

---

## File Structure

```
EDIT src/apps/desktop/src/stores/workspaces.ts                           (+ runAgentOnNewTask action)
NEW  src/apps/desktop/src/__tests__/workspacesStoreRunAgent.spec.ts     (behavioural: action forwards queue message + cwd + unattended)
EDIT src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue  (+ ▶ button + create-and-run emit + canRunAgent computed)
NEW  src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.runAgent.spec.ts (behavioural: button visibility, disabled state, emit shape)
EDIT src/apps/desktop/src/components/kanban/KanbanView.vue              (extend handleCreateTaskSave for mode='create_and_run')
NEW  src/apps/desktop/src/__tests__/KanbanView.createAndRun.spec.ts     (behavioural: call order, navigation, partial-success)

EDIT docs/SPEC.md                                                       (+ §3.7 entry; §10.2.1 PR index)
EDIT NALAR.md                                                           (+ Recent changes entry once shipped)
```

Total: **8 files** (3 NEW, 5 EDIT).

---

## Root Cause (read this before chunking — saves re-discovery)

```
User wants to create a kanban task AND start an agent on it in one click.

Current behavior:
  1. Click + on a column → New Task dialog opens.
  2. Fill title + description → click "Create task".
  3. Dialog closes, card appears in the column.
  4. Click the card → empty chatview opens.
  5. User re-types the description into the chatbox → hits Enter.
  6. Agent runs.

Failure mode (UX):
  - Steps 4-5 are redundant when description IS the prompt.
  - The user types the same thing twice.
  - Two-second mental interruption between "create" and "send".

Fix:
  - Add a sibling button "Create task & run agent" that combines
    steps 1-6 into one click:
      a. POST /tasks (create task row)
      b. POST /llm/session with queue_message = title + "\n\n" + description
      c. setActiveTask + router.replace (open chatview)
```

---

## Task 1 — Store action `runAgentOnNewTask` (TDD)

> **Outcome**: `workspacesStore.runAgentOnNewTask(workspaceId, itemId, taskId, params)` exists, returns `{ status: string } | undefined`, and forwards `queueMessage`, `cwd`, `isAutoRetryUntilStop` to `api.sendChatMessage`. Behavioural tests cover the happy path + `undefined` on failure.

### Step 1.1 — Write the failing test

Create `src/apps/desktop/src/__tests__/workspacesStoreRunAgent.spec.ts`:

```ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { useWorkspacesStore } from '../stores/workspaces'
import * as api from '../api'

describe('workspacesStore.runAgentOnNewTask', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('forwards queueMessage, cwd, and isAutoRetryUntilStop to api.sendChatMessage', async () => {
    const sendSpy = vi.spyOn(api, 'sendChatMessage').mockResolvedValue({ status: 'queued' })
    const store = useWorkspacesStore()
    const result = await store.runAgentOnNewTask('ws_1', 'item_1', 'task_abc', {
      queueMessage: 'Title\n\nBody',
      cwd: '/home/u/project',
      isAutoRetryUntilStop: '1',
    })
    expect(sendSpy).toHaveBeenCalledWith('task_abc', 'Title\n\nBody', '/home/u/project', undefined, '', '1')
    expect(result).toEqual({ status: 'queued' })
  })

  it('forwards empty string when isAutoRetryUntilStop is undefined', async () => {
    const sendSpy = vi.spyOn(api, 'sendChatMessage').mockResolvedValue({ status: 'queued' })
    const store = useWorkspacesStore()
    await store.runAgentOnNewTask('ws_1', 'item_1', 'task_abc', {
      queueMessage: 'Title',
      cwd: '/cwd',
    })
    expect(sendSpy).toHaveBeenCalledWith('task_abc', 'Title', '/cwd', undefined, '', '')
  })

  it('returns undefined when api.sendChatMessage throws', async () => {
    vi.spyOn(api, 'sendChatMessage').mockRejectedValue(new Error('network down'))
    const store = useWorkspacesStore()
    const result = await store.runAgentOnNewTask('ws_1', 'item_1', 'task_abc', {
      queueMessage: 'msg',
      cwd: '/cwd',
    })
    expect(result).toBeUndefined()
  })
})
```

Run the test, expect FAIL (no `runAgentOnNewTask` action yet):

```bash
cd src/apps/desktop && timeout 60 bunx vitest run workspacesStoreRunAgent.spec.ts 2>&1 | tail -n 30
```

- [ ] Failing test confirmed

### Step 1.2 — Implement the store action

Edit `src/apps/desktop/src/stores/workspaces.ts`:

1. Find the existing `runRoutine` action (around line 1605). Add the new action right after it. Match the style: arrow function on `workspacesStore`, try/catch returning `undefined` on error.

```ts
// Kanban "create task & run agent" flow (plan:
// docs/superpowers/plans/2026-08-06-kanban-create-task-run-agent.md).
// Wraps api.sendChatMessage so KanbanView doesn't import the wire
// shape directly. Returns the backend status so the host can decide
// whether to navigate to the chat view.
async function runAgentOnNewTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  params: {
    queueMessage: string
    cwd: string
    isAutoRetryUntilStop?: '0' | '1'
  },
): Promise<{ status: string } | undefined> {
  try {
    return await api.sendChatMessage(
      taskId,
      params.queueMessage,
      params.cwd,
      undefined,                                  // imageUrls
      '',                                         // selectedProfile
      params.isAutoRetryUntilStop ?? '',          // forwards '1' when toggle ON, else ''
    )
  } catch (err) {
    console.error('Failed to run agent on new task:', err)
    return undefined
  }
}
```

2. Find the `defineStore` return object (around line 2575 where `runRoutine` is exported). Add `runAgentOnNewTask` to the return next to `runRoutine`:

```ts
return {
  // ...existing returns...
  runRoutine,
  runAgentOnNewTask,
  // ...rest...
}
```

Run the test, expect PASS:

```bash
cd src/apps/desktop && timeout 60 bunx vitest run workspacesStoreRunAgent.spec.ts 2>&1 | tail -n 30
```

- [ ] Test passes
- [ ] Type-check via `bun run build` (catches any signature mismatch with `api.sendChatMessage`)

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20
```

### Step 1.3 — Commit

```bash
git add src/apps/desktop/src/stores/workspaces.ts \
        src/apps/desktop/src/__tests__/workspacesStoreRunAgent.spec.ts
git -c user.name=ginwa -c user.email=ginwa@local commit -m "feat(store): runAgentOnNewTask wraps api.sendChatMessage

Wraps api.sendChatMessage for the kanban 'Create task & run agent'
flow. One-line forward today; gives a single owner of the
cross-component contract (logging, future audit, future reuse for
'run agent on existing task').

Returns { status } | undefined; matches the runRoutine shape.

Plan: docs/superpowers/plans/2026-08-06-kanban-create-task-run-agent.md
Task 1 of 3"
```

---

## Task 2 — Dialog button + `create-and-run` emit (TDD)

> **Outcome**: `KanbanTaskDetailDialog` (create mode) renders a secondary `▶ Create task & run agent` button. Button enabled when name is non-empty (regardless of description). Clicking emits `create-and-run` with the same payload as `create` (different `mode` discriminator). Behavioural tests cover: visible only in create mode, enabled/disabled states, click emit shape.

### Step 2.1 — Write the failing test

Create `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.runAgent.spec.ts`. Mirror the test setup from `KanbanTaskDetailDialog.spec.ts`:

```ts
/**
 * Tests for the "Create task & run agent" button in
 * KanbanTaskDetailDialog (create mode).
 *
 * Mount pattern: same as KanbanTaskDetailDialog.spec.ts.
 * <Teleport to="body">, so use `attachTo: document.body` +
 * `document.querySelector` (NOT `wrapper.find`).
 *
 * Plan: docs/superpowers/plans/2026-08-06-kanban-create-task-run-agent.md
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanTaskDetailDialog from '@/components/kanban/KanbanTaskDetailDialog.vue'
import type { Task } from '@/stores/workspaces'

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function findAllInDom<T extends Element = Element>(selector: string): T[] {
  return Array.from(document.querySelectorAll<T>(selector))
}

describe('KanbanTaskDetailDialog — Create task & run agent', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) => el.remove())
  })

  function mountDialog(propsOverride: Record<string, unknown> = {}) {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, task: null, mode: 'create', ...propsOverride },
    })
    return wrapper
  }

  it('renders the create-and-run button in create mode', async () => {
    mountDialog()
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-create-and-run"]')).not.toBeNull()
  })

  it('does NOT render the create-and-run button in edit mode', async () => {
    mountDialog({
      mode: 'edit',
      task: { id: 'task_1', name: 'Existing', task_type: 'standard' } as Task,
    })
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-create-and-run"]')).toBeNull()
  })

  it('disables the create-and-run button when name is empty', async () => {
    mountDialog()
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')
    expect(btn?.disabled).toBe(true)
  })

  it('enables the create-and-run button when name is non-empty (description may be empty)', async () => {
    mountDialog()
    await flushPromises()
    const input = findInDom<HTMLInputElement>('[data-testid="kanban-task-detail-create-name"]')
    if (!input) throw new Error('name input missing')
    input.value = 'My task title'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')
    expect(btn?.disabled).toBe(false)
  })

  it('emits create-and-run with mode create_and_run on click', async () => {
    mountDialog()
    await flushPromises()
    const input = findInDom<HTMLInputElement>('[data-testid="kanban-task-detail-create-name"]')
    const desc = findInDom<HTMLTextAreaElement>('[data-testid="kanban-task-detail-create-description"]')
    if (!input || !desc) throw new Error('inputs missing')
    input.value = 'My task'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    desc.value = 'Body of the task'
    desc.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')
    btn?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create-and-run')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([
      {
        mode: 'create_and_run',
        name: 'My task',
        description: 'Body of the task',
        is_auto_retry_until_stop: '0',
        tags: [],
      },
    ])
  })

  it('forwards unattended toggle value into the emit payload', async () => {
    mountDialog()
    await flushPromises()
    const input = findInDom<HTMLInputElement>('[data-testid="kanban-task-detail-create-name"]')
    if (!input) throw new Error('name input missing')
    input.value = 'My task'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    const toggle = findInDom<HTMLInputElement>('[data-testid="kanban-task-detail-unattended-toggle"]')
    toggle?.dispatchEvent(new Event('change', { bubbles: true }))
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')
    btn?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create-and-run')
    expect(emitted![0][0].is_auto_retry_until_stop).toBe('1')
  })
})
```

Run the test, expect FAIL:

```bash
cd src/apps/desktop && timeout 60 bunx vitest run KanbanTaskDetailDialog.runAgent.spec.ts 2>&1 | tail -n 30
```

- [ ] Failing test confirmed

### Step 2.2 — Add the button to KanbanTaskDetailDialog

Edit `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue`:

1. Add the new emit to `defineEmits` (around line 166, after the existing `update-unattended`):

```ts
'create-and-run': [
  payload: {
    mode: 'create_and_run'
    name: string
    description: string
    is_auto_retry_until_stop: '0' | '1'
    tags: string[]
  },
]
```

2. Add `canRunAgent` computed next to `canSave` (around line 277):

```ts
const canRunAgent = computed<boolean>(() => isValid.value)
```

3. Add a `handleRunAgent` handler near `handleSave`:

```ts
const handleRunAgent = () => {
  if (!canRunAgent.value) return
  tagsInputRef.value?.commitDraft()
  if (!canRunAgent.value) return
  emit('create-and-run', {
    mode: 'create_and_run',
    name: name.value.trim(),
    description: description.value,
    is_auto_retry_until_stop: unattended.value,
    tags: tags.value,
  })
}
```

4. Add the button in the actions footer (after the existing "Create task" button, around line 718):

```html
<button
  v-if="isCreateMode"
  type="button"
  @click="handleRunAgent"
  :disabled="!canRunAgent"
  data-testid="kanban-task-detail-create-and-run"
  class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
  style="
    background-color: transparent;
    border: 1px solid var(--color-border);
    color: var(--semantic-text);
  "
  title="Create the task and start the agent. The title + description becomes the first user message."
>
  <span aria-hidden="true">▶</span>
  <span class="ml-1">Create task &amp; run agent</span>
</button>
```

Run the tests, expect PASS:

```bash
cd src/apps/desktop && timeout 60 bunx vitest run KanbanTaskDetailDialog.runAgent.spec.ts 2>&1 | tail -n 30
```

- [ ] All 7 tests pass
- [ ] Type-check via `bun run build`:

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20
```

### Step 2.3 — Commit

```bash
git add src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue \
        src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.runAgent.spec.ts
git -c user.name=ginwa -c user.email=ginwa@local commit -m "feat(kanban): Create task & run agent button

Adds a secondary 'Create task & run agent' button to the New Task
dialog (create mode only). Emits create-and-run with mode=
'create_and_run' and the same payload as the existing 'create' emit.

Button is enabled whenever name is non-empty; description is NOT
required (Q2 = 2b from the brainstorm — empty description degrades
to a queued message that is just the title). The unattended toggle
flows through (Q3 = 3a).

Plan: docs/superpowers/plans/2026-08-06-kanban-create-task-run-agent.md
Task 2 of 3"
```

---

## Task 3 — Host wiring in `KanbanView` (TDD)

> **Outcome**: `KanbanView.handleCreateTaskSave` branches on `mode`. For `'create_and_run'`: create the task → move to column → `runAgentOnNewTask` → on `status: 'queued'` emit `selectTask(taskId)` so the existing AppLayout → Sidebar chain navigates. On any other status: surface a `notifyError` toast and skip navigation. Behavioural tests cover: call order, navigation only on success, partial-success toast.

### Step 3.1 — Write the failing test

Create `src/apps/desktop/src/__tests__/KanbanView.createAndRun.spec.ts`. Mirror the existing test setup style for kanban views (see `KanbanColumn.spec.ts` for the pattern):

```ts
/**
 * Tests for KanbanView.handleCreateTaskSave's
 * `mode: 'create_and_run'` branch.
 *
 * Mount pattern: shallow mount with stub children + vi.spyOn for the
 * store actions. We assert the call ORDER and payload, not the
 * implementation details. The dialog emit is mocked via the parent
 * by reaching into the dialog component.
 *
 * Plan: docs/superpowers/plans/2026-08-06-kanban-create-task-run-agent.md
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'

import KanbanView from '@/components/kanban/KanbanView.vue'
import * as api from '@/api'
import { useWorkspacesStore } from '@/stores/workspaces'
import { useNotificationStore } from '@/stores/notifications'

// Stub the heavy children — we only test the host's handleCreateTaskSave.
vi.mock('@/components/kanban/KanbanColumn.vue', () => ({
  default: { name: 'KanbanColumn', template: '<div />' },
}))
vi.mock('@/components/kanban/KanbanSearchInput.vue', () => ({
  default: { name: 'KanbanSearchInput', template: '<div />' },
}))
vi.mock('@/components/kanban/KanbanTaskDetailDialog.vue', () => ({
  default: {
    name: 'KanbanTaskDetailDialog',
    template: '<div data-testid="stub-dialog" />',
  },
}))
vi.mock('@/composables/useKanbanScrollRestore', () => ({
  useKanbanScrollRestore: () => ({}),
}))
vi.mock('../preview/InlineEditableText.vue', () => ({
  default: { name: 'InlineEditableText', template: '<div />' },
}))

const ITEM: any = {
  id: 'item_1',
  name: 'Kanban',
  path: '/home/u/proj',
  tasks: [],
  kanban_columns: [
    { id: 'col_todo', name: 'todo', position: 0, workspace_item_id: 'item_1' },
  ],
}

describe('KanbanView.handleCreateTaskSave — create_and_run', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  async function mountView() {
    wrapper = mount(KanbanView, {
      props: { item: structuredClone(ITEM), workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await flushPromises()
    return wrapper!
  }

  it('creates the task, moves it to the column, then runs the agent — in that order', async () => {
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: 'task_new',
      name: 'My task',
      description: 'desc',
      task_type: 'standard',
    })
    vi.spyOn(api, 'moveTaskToColumn').mockResolvedValue({ success: true })
    const sendSpy = vi.spyOn(api, 'sendChatMessage').mockResolvedValue({ status: 'queued' })
    const store = useWorkspacesStore()
    const moveSpy = vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)
    vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    vi.spyOn(store, 'runAgentOnNewTask').mockResolvedValue({ status: 'queued' })
    const setActiveSpy = vi.spyOn(store, 'setActiveTask')

    const view = await mountView()
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create_and_run',
      name: 'My task',
      description: 'desc',
      is_auto_retry_until_stop: '0',
      tags: [],
    })
    await flushPromises()

    // Call order: addTask -> moveTaskToColumn -> runAgentOnNewTask
    expect(store.addTask).toHaveBeenCalledBefore(store.moveTaskToColumn as any)
    expect(store.moveTaskToColumn).toHaveBeenCalledBefore(store.runAgentOnNewTask as any)
    // Queue message is title + "\n\n" + description
    expect(store.runAgentOnNewTask).toHaveBeenCalledWith(
      'ws_1', 'item_1', 'task_new',
      { queueMessage: 'My task\n\ndesc', cwd: '/home/u/proj', isAutoRetryUntilStop: '0' },
    )
    // Navigates to the new task
    expect(setActiveSpy).toHaveBeenCalledWith('task_new')
    // Used api.sendChatMessage indirectly via store (spy should have been called by the store)
    expect(sendSpy).toHaveBeenCalledTimes(0) // store action does the call
  })

  it('queue message is just the title when description is empty', async () => {
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: 'task_new', name: 'Just title', description: '', task_type: 'standard',
    })
    vi.spyOn(api, 'moveTaskToColumn').mockResolvedValue({ success: true })
    const store = useWorkspacesStore()
    vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)
    vi.spyOn(store, 'runAgentOnNewTask').mockResolvedValue({ status: 'queued' })

    const view = await mountView()
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create_and_run',
      name: 'Just title',
      description: '',
      is_auto_retry_until_stop: '0',
      tags: [],
    })
    await flushPromises()

    expect(store.runAgentOnNewTask).toHaveBeenCalledWith(
      'ws_1', 'item_1', 'task_new',
      { queueMessage: 'Just title', cwd: '/home/u/proj', isAutoRetryUntilStop: '0' },
    )
  })

  it('forwards unattended toggle value', async () => {
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: 'task_new', name: 'My task', description: 'd', task_type: 'standard',
    })
    vi.spyOn(api, 'moveTaskToColumn').mockResolvedValue({ success: true })
    const store = useWorkspacesStore()
    vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)
    vi.spyOn(store, 'runAgentOnNewTask').mockResolvedValue({ status: 'queued' })

    const view = await mountView()
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create_and_run',
      name: 'My task',
      description: 'd',
      is_auto_retry_until_stop: '1',
      tags: [],
    })
    await flushPromises()
    expect(store.runAgentOnNewTask).toHaveBeenCalledWith(
      'ws_1', 'item_1', 'task_new',
      { queueMessage: 'My task\n\nd', cwd: '/home/u/proj', isAutoRetryUntilStop: '1' },
    )
  })

  it('does NOT navigate when runAgentOnNewTask returns undefined (partial success)', async () => {
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: 'task_new', name: 't', description: 'd', task_type: 'standard',
    })
    vi.spyOn(api, 'moveTaskToColumn').mockResolvedValue({ success: true })
    const store = useWorkspacesStore()
    vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)
    vi.spyOn(store, 'runAgentOnNewTask').mockResolvedValue(undefined)
    const setActiveSpy = vi.spyOn(store, 'setActiveTask')
    const notifySpy = vi.spyOn(useNotificationStore(), 'notifyError')

    const view = await mountView()
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create_and_run',
      name: 't',
      description: 'd',
      is_auto_retry_until_stop: '0',
      tags: [],
    })
    await flushPromises()

    expect(setActiveSpy).not.toHaveBeenCalled()
    expect(notifySpy).toHaveBeenCalled()
  })

  it('does NOT navigate when runAgentOnNewTask returns status != queued', async () => {
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: 'task_new', name: 't', description: 'd', task_type: 'standard',
    })
    vi.spyOn(api, 'moveTaskToColumn').mockResolvedValue({ success: true })
    const store = useWorkspacesStore()
    vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)
    vi.spyOn(store, 'runAgentOnNewTask').mockResolvedValue({ status: 'offline' })
    const setActiveSpy = vi.spyOn(store, 'setActiveTask')

    const view = await mountView()
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create_and_run',
      name: 't',
      description: 'd',
      is_auto_retry_until_stop: '0',
      tags: [],
    })
    await flushPromises()
    expect(setActiveSpy).not.toHaveBeenCalled()
  })

  it('still creates the task in plain create mode (existing behavior unchanged)', async () => {
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: 'task_new', name: 't', description: 'd', task_type: 'standard',
    })
    vi.spyOn(api, 'moveTaskToColumn').mockResolvedValue({ success: true })
    const store = useWorkspacesStore()
    vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)
    const runAgentSpy = vi.spyOn(store, 'runAgentOnNewTask')
    const setActiveSpy = vi.spyOn(store, 'setActiveTask')

    const view = await mountView()
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create',
      name: 't',
      description: 'd',
      is_auto_retry_until_stop: '0',
      tags: [],
    })
    await flushPromises()
    expect(runAgentSpy).not.toHaveBeenCalled()
    expect(setActiveSpy).not.toHaveBeenCalled()
  })
})
```

Run the test, expect FAIL:

```bash
cd src/apps/desktop && timeout 60 bunx vitest run KanbanView.createAndRun.spec.ts 2>&1 | tail -n 30
```

- [ ] Failing test confirmed

### Step 3.2 — Wire the host

Edit `src/apps/desktop/src/components/kanban/KanbanView.vue`:

1. Import `useNotificationStore`:

```ts
import { useNotificationStore } from '../../stores/notifications'
```

2. Extend the `handleCreateTaskSave` signature (around line 423) to accept `mode`:

```ts
const handleCreateTaskSave = async (payload: {
  mode: 'create' | 'create_and_run'
  name: string
  description: string
  is_auto_retry_until_stop?: '0' | '1'
  tags?: string[]
}) => {
  if (!activeCreateColumnId.value) return
  createBusy.value = true
  createError.value = null
  const wsId = props.workspaceId
  const itId = props.itemId || props.item.id
  const desiredColumnId = activeCreateColumnId.value
  try {
    const taskId = await workspacesStore.addTask(wsId, itId, {
      name: payload.name,
      description: payload.description,
      isAutoRetryUntilStop: payload.is_auto_retry_until_stop,
      tags: payload.tags,
    })
    if (!taskId) {
      createError.value = 'Failed to create task — please retry.'
      return
    }
    await workspacesStore.moveTaskToColumn(wsId, itId, taskId, desiredColumnId, 0)

    // NEW (plan: 2026-08-06-kanban-create-task-run-agent): when the user
    // clicks "Create task & run agent", also queue the title +
    // description as the first user message and route to the chatview.
    // Reuses the existing selectTask emit so the AppLayout -> Sidebar
    // chain does the navigation.
    if (payload.mode === 'create_and_run') {
      const queueMessage =
        payload.description.trim() !== ''
          ? `${payload.name}\n\n${payload.description}`
          : payload.name
      const result = await workspacesStore.runAgentOnNewTask(wsId, itId, taskId, {
        queueMessage,
        cwd: props.item.path || '',
        isAutoRetryUntilStop: payload.is_auto_retry_until_stop,
      })
      if (result?.status === 'queued') {
        emit('selectTask', taskId)
      } else {
        // Partial success: task was created but the agent didn't start.
        // Surface a toast so the user knows to click the card to retry.
        useNotificationStore().notifyError(
          'Task created — agent did not start',
          'Click the card to retry, or check the nalar logs.',
        )
      }
    }

    showCreateDialog.value = false
    activeCreateColumnId.value = null
  } catch (err) {
    console.error('Failed to create kanban task:', err)
    createError.value = err instanceof Error ? err.message : String(err)
  } finally {
    createBusy.value = false
  }
}
```

Run the tests, expect PASS:

```bash
cd src/apps/desktop && timeout 60 bunx vitest run KanbanView.createAndRun.spec.ts 2>&1 | tail -n 30
```

- [ ] All 6 tests pass
- [ ] Type-check via `bun run build`:

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20
```

### Step 3.3 — Update the dialog's `@create` binding

The dialog template in `KanbanView.vue` currently emits the `create` event. Find that binding (around line ~640 in the template) and ensure it passes `mode: 'create'`:

```html
<KanbanTaskDetailDialog
  ...
  @create="(payload) => handleCreateTaskSave({ ...payload, mode: 'create' })"
  @create-and-run="(payload) => handleCreateTaskSave({ ...payload, mode: 'create_and_run' })"
  ...
/>
```

Run the full KanbanView test suite to confirm no regression in the existing flow:

```bash
cd src/apps/desktop && timeout 60 bunx vitest run KanbanView 2>&1 | tail -n 30
```

- [ ] No regressions

### Step 3.4 — Commit

```bash
git add src/apps/desktop/src/components/kanban/KanbanView.vue \
        src/apps/desktop/src/__tests__/KanbanView.createAndRun.spec.ts
git -c user.name=ginwa -c user.email=ginwa@local commit -m "feat(kanban): wire create_and_run in KanbanView host

handleCreateTaskSave branches on mode:
  - 'create'           — today's flow (create + move + close dialog)
  - 'create_and_run'   — also queues title + description via
                         api.sendChatMessage, then emits selectTask
                         so the existing AppLayout -> Sidebar chain
                         navigates to the new chat view.

Partial success: when sendChatMessage fails after the task is
created, surface a notifyError toast and skip navigation. The user
can click the card to retry.

Plan: docs/superpowers/plans/2026-08-06-kanban-create-task-run-agent.md
Task 3 of 3"
```

---

## Task 4 — Final integration verification

> **Outcome**: All quality gates green. The full vitest suite still passes; vue-tsc still passes; Zig backend still builds (no Zig changes but verify).

### Step 4.1 — Run the full vitest suite

```bash
cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 30
```

- [ ] All tests pass (existing + 16 new from Tasks 1-3)
- [ ] No regressions in `KanbanTaskDetailDialog.spec.ts`, `KanbanView.spec.ts`, `KanbanColumn.spec.ts`, etc.

### Step 4.2 — Type-check the whole frontend

```bash
cd src/apps/desktop && timeout 180 bun run build 2>&1 | tail -n 20
```

- [ ] `vue-tsc --build` exits clean (no type errors)
- [ ] No `.js` files emitted next to `.ts` source files (per `.nalar/skills/vue-tsc-build-emits-js-files/SKILL.MD`, delete any if present):

```bash
git status --short | grep -E '\.ts\.js$|\.ts\.js\.map$' | head -n 5
# If any found, delete them BEFORE committing.
```

### Step 4.3 — Backend smoke (no changes, but verify)

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 20
```

- [ ] Same pass count as before this branch (frontend-only change so should be unchanged)
- [ ] Binary builds:

```bash
timeout 180 zig build install:linux:system 2>&1 | tail -n 10
```

### Step 4.4 — Manual smoke (port 8080)

Use the always-running dev `nalar` on a different port to avoid touching 8081:

```bash
# Start a fresh nalar on port 8080 with isolated tmpdir
mkdir -p /tmp/nalar-smoke && cd /tmp/nalar-smoke
HOME=/tmp/nalar-smoke timeout 600 ../zig-out/bin/nalar --port 8080 &
NALAR_PID=$!
sleep 2

# In a separate terminal, drive the API:
# 1. Create workspace + kanban item
# 2. POST /workspaces/:ws/items/:item/tasks with name + description (would be done by UI; here we just verify the queue_message gets routed correctly via the LLM)

# Easier: open the webapp at http://127.0.0.1:8080/ and:
#   - Click + on Todo column
#   - Type "Smoke test task" + "This is the description"
#   - Click ▶ Create task & run agent
#   - Assert dialog closes
#   - Assert card appears in Todo column
#   - Assert chatview opens automatically
#   - Assert first user message is "Smoke test task\n\nThis is the description"
#   - Assert agent spinner appears within 500ms

kill $NALAR_PID 2>/dev/null
```

- [ ] Manual smoke passes
- [ ] Verify on `chrome devtools` Network tab: `POST /api/llm/session` shows the queued message with the expected shape

### Step 4.5 — Final docs update

Edit `docs/SPEC.md`:

1. Add to §3.7 (or whichever "Frontend — Kanban" section is current):
   > **Create task & run agent** — New Task dialog adds a secondary `▶ Create task & run agent` button (plan: `2026-08-06-kanban-create-task-run-agent.md`). Creates the task, queues `title + '\n\n' + description` as the first user message, and routes the user to the new task's chat view. Empty description allowed; unattended toggle flows through.

2. Add a row to §10.2.1 PR index:
   > | kanban create task & run agent | worktree/kanban-create-task-run-agent | PR #TBD | 2026-08-06 |

Edit `NALAR.md`:

Add to the Recent Changes section:

```markdown
### 2026-08-06: kanban create task & run agent

**What landed.** Secondary `▶ Create task & run agent` button in the New Task dialog. The button creates the task, queues `title + '\n\n' + description` as the first user message via `POST /api/llm/session`, and routes the user to the new task's chat view. Mirrors the routine `Run now` flow but at create time for standard tasks.

**Files.** 8 (3 NEW, 5 EDIT). Frontend-only — no backend, no migration, no Zig changes.

**Plan:** docs/superpowers/plans/2026-08-06-kanban-create-task-run-agent.md
**Branch:** worktree/kanban-create-task-run-agent
**Task:** task_1785506127328
```

### Step 4.6 — Final commit + PR

```bash
git add docs/SPEC.md NALAR.md
git -c user.name=ginwa -c user.email=ginwa@local commit -m "docs(kanban): SPEC.md + NALAR.md entries for create-and-run

Spec entry: §3.7 frontend kanban section.
PR index: §10.2.1.
NALAR.md changelog: 2026-08-06 entry.

Plan: docs/superpowers/plans/2026-08-06-kanban-create-task-run-agent.md
Task 4 of 4"

git push -u origin worktree/kanban-create-task-run-agent
```

- [ ] All commits pushed
- [ ] PR opened (squash-merge target: `main`)

---

## Out of scope (deferred — do NOT do in this plan)

- **"Run agent on existing task"** — same primitive, easy follow-up. `runAgentOnExistingTask(taskId, message, cwd)`.
- **Spinner in chatview before first LLM chunk** — `processingState` already flips via SSE.
- **Markdown rendering of queued message** — `loadChatHistory` already handles it.
- **Confirmation modal** — button is enabled whenever name is non-empty (Q2 = 2b).
- **Backwards-compat with the legacy "Create task" button** — stays as-is. New button is a sibling.
- **Queueing for routine/memory tasks at create time** — routines have `initial_prompt` already; memories don't run agents.