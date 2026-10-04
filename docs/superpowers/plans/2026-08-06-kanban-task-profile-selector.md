# Kanban New Task Profile Selector — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a profile-model picker to the New Task dialog (`KanbanTaskDetailDialog`, create mode only). User pre-selects which `LlmConfig.profiles_models[name]` profile the agent should use; choice flows through `POST /api/llm/session` and persists on the new session so the chatview's picker reflects it on landing.

**Architecture:** Dialog loads profiles via `api.getPabrikConfig()` (mirroring `ChatView.loadProfiles`). Local `selectedProfile: string` ref (default `''`). The picker is rendered in the same row as the existing Unattended-mode toggle (Q2 = 2a). Selected profile is added to both `create` and `create-and-run` emit payloads. `KanbanView.handleCreateTaskSave` forwards it to `workspacesStore.runAgentOnNewTask`, which forwards to `api.sendChatMessage`. No backend changes.

**Tech Stack:** Vue 3 + TypeScript + Pinia + Vitest (`@vue/test-utils`). No new dependencies. Reuses existing `api.getPabrikConfig()` and `api.sendChatMessage(selectedProfile)` patterns.

## Design Decisions (review before execution)

| ID | Decision | Why | Alternative rejected |
|----|----------|-----|----------------------|
| D1 | **Create mode only** (Q1 = 1a) | Matches user's screenshot scope; chatview picker covers edit-mode use cases. | Both modes — duplicates chatview picker; bigger scope. |
| D2 | **Same row as Unattended toggle** (Q2 = 2a) | Compact, visually pairs the two controls. The dialog is already long. | Separate row above — more vertical space; less critical. |
| D3 | **Path A: only thread via `runAgentOnNewTask`** (create-and-run path). Plain create loses profile choice. | Minimal scope; plain-create users can set profile later from chatview. | Path B: persist on task create (backend + migration). Bigger scope. |
| D4 | **Reuse `ChatView.loadProfiles()` pattern** | Same `api.getPabrikConfig()` call. Tested already. | New `/api/profiles` endpoint — YAGNI. |
| D5 | **Default value is `''`** (backend default / "Default (top-level config)") | Matches chatview's existing convention. | Default to first profile — magic; surprising. |
| D6 | **Empty-profile list → still render the picker with just "Default"** | User can still proceed; non-blocking failure mode. | Disable picker on empty — over-restrictive. |
| D7 | **Tests live in dedicated `*.spec.ts` files** (behavioural) | User rule (2026-07-29): no static-contract tests. | Inline tests — inconsistent with existing patterns. |

## Global Constraints

- **Cross-platform**: every feature MUST work on Linux, macOS, AND Windows. Frontend-only — verify with `bun run build` + `bunx vitest run`.
- **No static-contract tests**: ALL tests are behavioural.
- **TDD discipline**: every implementation step starts with a failing test.
- **`bun run build` IS the type-check**: every commit must pass vue-tsc.
- **Teleport-based components**: `KanbanTaskDetailDialog` uses `<Teleport to="body">`. Use `attachTo: document.body` + `document.querySelector` for DOM assertions.
- **Behavioural Vue tests**: `setActivePinia(createPinia())` in `beforeEach`. Mock `api.getPabrikConfig` via `vi.spyOn(api, 'getPabrikConfig')`.

---

## File Structure

```
EDIT src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue  (+ profile picker UI + selectedProfile ref + loadProfiles)
EDIT src/apps/desktop/src/stores/workspaces.ts                            (extend runAgentOnNewTask params)
EDIT src/apps/desktop/src/components/kanban/KanbanView.vue               (forward selectedProfile to runAgentOnNewTask)
NEW  src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.profile.spec.ts (behavioural: visible in create mode, loaded from api, selection, emit)
EDIT src/apps/desktop/src/__tests__/workspacesStoreRunAgent.spec.ts       (+ selectedProfile forwarding tests)
EDIT src/apps/desktop/src/__tests__/KanbanView.createAndRun.spec.ts      (+ selectedProfile flow test)

EDIT docs/SPEC.md                                                        (+ §3.7.6 entry; PR index row)
EDIT PABRIK.md                                                            (+ Recent changes entry once shipped)
```

Total: **8 files** (1 NEW, 7 EDIT).

---

## Root Cause (read this before chunking)

```
User creates a kanban task + agent run with the chatview's default
profile (backend's top-level config). They want to pre-select a
non-default profile at task-create time so the FIRST message
(the queued title+description) already uses the right model.

Fix:
  - Add profile picker to New Task dialog (create mode only)
  - Forward selectedProfile through to runAgentOnNewTask
  - api.sendChatMessage already accepts selectedProfile; backend
    POST /api/llm/session persists to sessions.selected_profile_model
  - Chatview's picker reflects the new profile when user lands
```

---

## Task 1 — Dialog profile picker UI + selectedProfile ref (TDD)

> **Outcome**: `KanbanTaskDetailDialog` (create mode only) renders a profile picker next to the Unattended-mode toggle. Loads profiles via `api.getPabrikConfig`. Selection updates a local `selectedProfile` ref. Both `create` and `create-and-run` emits carry `selectedProfile`. Behavioural tests cover: picker visible in create mode only, profile loads, selection, emit shape, edit mode hides picker.

### Step 1.1 — Write the failing tests

Create `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.profile.spec.ts`:

```ts
/**
 * Tests for the profile-model picker in KanbanTaskDetailDialog
 * (create mode only).
 *
 * Mount pattern: same as KanbanTaskDetailDialog.runAgent.spec.ts —
 * <Teleport to="body">, attachTo: document.body + document.querySelector.
 *
 * Plan: docs/superpowers/plans/2026-08-06-kanban-task-profile-selector.md
 *   Task 1 / Step 1.1
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanTaskDetailDialog from '@/components/kanban/KanbanTaskDetailDialog.vue'
import * as api from '@/api'
import type { Task } from '@/stores/workspaces'

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function findAllInDom<T extends Element = Element>(selector: string): T[] {
  return Array.from(document.querySelectorAll<T>(selector))
}

describe('KanbanTaskDetailDialog — profile picker', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    // Default mock: one profile + top-level defaults so the picker has
    // both "Default" and one profile entry.
    vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({
      profiles: {
        '900r1bu': { model: 'MiniMax-M3', base_url: 'https://api.minimax.io/v1' },
      },
    } as any)
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) => el.remove())
    vi.restoreAllMocks()
  })

  function mountDialog(propsOverride: Record<string, unknown> = {}) {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, task: null, mode: 'create', ...propsOverride },
    })
    return wrapper
  }

  it('renders the profile picker button in create mode', async () => {
    mountDialog()
    await flushPromises()
    expect(
      findInDom('[data-testid="kanban-task-detail-profile-picker"]'),
    ).not.toBeNull()
  })

  it('does NOT render the profile picker in edit mode', async () => {
    mountDialog({
      mode: 'edit',
      task: { id: 'task_1', name: 'Existing', task_type: 'standard' } as Task,
    })
    await flushPromises()
    expect(
      findInDom('[data-testid="kanban-task-detail-profile-picker"]'),
    ).toBeNull()
  })

  it('button label defaults to "Default"', async () => {
    mountDialog()
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-profile-picker"]',
    )
    expect(btn?.textContent).toContain('Default')
  })

  it('clicking the picker opens a dropdown with Default + each profile', async () => {
    mountDialog()
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-profile-picker"]',
    )
    btn?.click()
    await flushPromises()
    expect(
      findInDom('[data-testid="kanban-task-detail-profile-picker-dropdown"]'),
    ).not.toBeNull()
    const items = findAllInDom('[data-testid="kanban-task-detail-profile-picker-item"]')
    // Default + one profile
    expect(items.length).toBe(2)
    expect(items[0]?.textContent).toContain('Default')
    expect(items[1]?.textContent).toContain('900r1bu')
  })

  it('selecting a profile updates the button label', async () => {
    mountDialog()
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-profile-picker"]',
    )
    btn?.click()
    await flushPromises()
    const profileItem = findAllInDom(
      '[data-testid="kanban-task-detail-profile-picker-item"]',
    )[1] as HTMLButtonElement
    profileItem?.click()
    await flushPromises()
    expect(btn?.textContent).toContain('900r1bu')
  })

  it('emits create-and-run with selectedProfile after a profile is picked', async () => {
    mountDialog()
    await flushPromises()
    const input = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-name"]',
    )
    if (!input) throw new Error('name input missing')
    input.value = 'My task'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    // Pick the 900r1bu profile
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-profile-picker"]',
    )
    btn?.click()
    await flushPromises()
    const profileItem = findAllInDom(
      '[data-testid="kanban-task-detail-profile-picker-item"]',
    )[1] as HTMLButtonElement
    profileItem?.click()
    await flushPromises()
    // Click the create-and-run button
    const runBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )
    runBtn?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create-and-run')
    expect(emitted).toBeTruthy()
    const payload = emitted![0]![0] as { selectedProfile: string }
    expect(payload.selectedProfile).toBe('900r1bu')
  })

  it('emits create with selectedProfile for plain create', async () => {
    mountDialog()
    await flushPromises()
    const input = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-name"]',
    )
    if (!input) throw new Error('name input missing')
    input.value = 'My task'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    // Pick the 900r1bu profile
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-profile-picker"]',
    )
    btn?.click()
    await flushPromises()
    const profileItem = findAllInDom(
      '[data-testid="kanban-task-detail-profile-picker-item"]',
    )[1] as HTMLButtonElement
    profileItem?.click()
    await flushPromises()
    // Click the create button (not create-and-run)
    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    saveBtn?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create')
    expect(emitted).toBeTruthy()
    const payload = emitted![0]![0] as { selectedProfile: string }
    expect(payload.selectedProfile).toBe('900r1bu')
  })

  it('emits create-and-run with selectedProfile="" when Default is selected', async () => {
    mountDialog()
    await flushPromises()
    const input = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-name"]',
    )
    if (!input) throw new Error('name input missing')
    input.value = 'My task'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    // No profile picked — should be empty string
    const runBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )
    runBtn?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create-and-run')
    const payload = emitted![0]![0] as { selectedProfile: string }
    expect(payload.selectedProfile).toBe('')
  })

  it('handles api.getPabrikConfig failure gracefully (no profiles)', async () => {
    vi.spyOn(api, 'getPabrikConfig').mockRejectedValue(new Error('boom'))
    mountDialog()
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-profile-picker"]',
    )
    expect(btn).not.toBeNull()
    // Button still functional; dropdown only shows Default
    btn?.click()
    await flushPromises()
    const items = findAllInDom('[data-testid="kanban-task-detail-profile-picker-item"]')
    expect(items.length).toBe(1)
    expect(items[0]?.textContent).toContain('Default')
  })
})
```

Run the test, expect FAIL (no profile picker exists yet):

```bash
cd src/apps/desktop && timeout 60 bunx vitest run KanbanTaskDetailDialog.profile 2>&1 | tail -n 25
```

- [ ] Failing test confirmed

### Step 1.2 — Add the profile picker to KanbanTaskDetailDialog

Edit `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue`:

1. Add `selectedProfile` to the local state (next to `unattended`):

```ts
const selectedProfile = ref<string>('')
const isProfilePickerOpen = ref(false)
const profilePickerRef = ref<HTMLElement | null>(null)
const availableProfiles = ref<Array<{ name: string; model: string; base_url: string }>>([])
const profilesLoading = ref(false)
```

2. Import `api`:

```ts
import * as api from '../../api'
```

3. Add a `loadProfiles` function (mirroring `ChatView.loadProfiles`):

```ts
const loadProfiles = async () => {
  if (!isCreateMode.value) return
  profilesLoading.value = true
  try {
    const config = await api.getPabrikConfig()
    const profiles = (config.profiles ?? {}) as Record<
      string,
      { model?: string; base_url?: string }
    >
    availableProfiles.value = Object.entries(profiles).map(([name, p]) => ({
      name,
      model: p.model ?? '',
      base_url: p.base_url ?? '',
    }))
  } catch (err) {
    console.error('Failed to load profiles:', err)
    availableProfiles.value = []
  } finally {
    profilesLoading.value = false
  }
}

const closeProfilePickerOnOutsideClick = (e: MouseEvent) => {
  if (profilePickerRef.value && !profilePickerRef.value.contains(e.target as Node)) {
    isProfilePickerOpen.value = false
  }
}

const toggleProfilePicker = () => {
  isProfilePickerOpen.value = !isProfilePickerOpen.value
}

const selectProfile = (name: string) => {
  selectedProfile.value = name
  isProfilePickerOpen.value = false
}
```

4. Extend the watcher (the `watch(() => [props.show, ...])` block) to load profiles on dialog open in create mode:

```ts
if (isCreateMode.value) {
  selectedProfile.value = ''
}
void loadProfiles()
```

5. Update the `create` and `create-and-run` emit payloads (in `handleSave` and `handleRunAgent`):

```ts
emit('create', {
  mode: 'create',
  name: name.value.trim(),
  description: description.value,
  is_auto_retry_until_stop: unattended.value,
  tags: tags.value,
  selectedProfile: selectedProfile.value,  // NEW — '' when no profile picked
})

emit('create-and-run', {
  mode: 'create_and_run',
  name: name.value.trim(),
  description: description.value,
  is_auto_retry_until_stop: unattended.value,
  tags: tags.value,
  selectedProfile: selectedProfile.value,  // NEW — '' when no profile picked
})
```

6. Update the emit type definitions to include `selectedProfile`:

```ts
'create': [
  payload: {
    mode: 'create'
    name: string
    description: string
    is_auto_retry_until_stop: '0' | '1'
    tags: string[]
    selectedProfile: string  // NEW
  },
]
'create-and-run': [
  payload: {
    mode: 'create_and_run'
    name: string
    description: string
    is_auto_retry_until_stop: '0' | '1'
    tags: string[]
    selectedProfile: string  // NEW
  },
]
```

7. Add the picker UI in the unattended-mode row (so it becomes a 2-column layout — picker on left, toggle on right):

Replace the existing unattended-mode div with:

```html
<!-- Unattended-mode + Profile row (create mode only — combines two
     controls into one row to keep the dialog compact) -->
<div
  v-if="isCreateMode"
  class="mt-4 pt-4 flex items-center gap-4"
  style="border-top: 1px solid var(--color-border);"
  data-testid="kanban-task-detail-unattended"
>
  <!-- Profile picker -->
  <div ref="profilePickerRef" class="relative shrink-0">
    <button
      type="button"
      @click.stop="toggleProfilePicker"
      class="px-3 py-1.5 rounded-lg text-xs font-medium transition-all duration-200 hover:opacity-80"
      style="
        background-color: var(--semantic-sidebar-bg);
        border: 1px solid var(--color-border);
        color: var(--semantic-text);
      "
      :title="selectedProfile
        ? `Using profile: ${selectedProfile}`
        : 'Using default (top-level config)'"
      data-testid="kanban-task-detail-profile-picker"
    >
      <span aria-hidden="true">🤖</span>
      <span class="ml-1">{{ selectedProfile || 'Default' }}</span>
      <span class="ml-1 text-[10px]">▾</span>
    </button>
    <div
      v-if="isProfilePickerOpen"
      class="absolute bottom-full mb-2 left-0 min-w-[240px] rounded-lg shadow-lg z-20 overflow-hidden"
      style="
        background-color: var(--semantic-card-bg);
        border: 1px solid var(--color-border);
      "
      data-testid="kanban-task-detail-profile-picker-dropdown"
    >
      <button
        type="button"
        @click.stop="selectProfile('')"
        class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center justify-between"
        style="color: var(--semantic-text);"
        data-testid="kanban-task-detail-profile-picker-item"
      >
        <span class="font-medium">Default (top-level config)</span>
        <span v-if="selectedProfile === ''">✓</span>
      </button>
      <button
        v-for="p in availableProfiles"
        :key="p.name"
        type="button"
        @click.stop="selectProfile(p.name)"
        class="w-full text-left px-3 py-2 text-xs hover:opacity-80"
        style="color: var(--semantic-text); border-top: 1px solid var(--color-border)"
        data-testid="kanban-task-detail-profile-picker-item"
      >
        <div class="flex items-center justify-between">
          <span class="font-medium">{{ p.name }}</span>
          <span v-if="selectedProfile === p.name">✓</span>
        </div>
        <div class="text-[10px] mt-0.5" style="color: var(--semantic-text-muted)">
          {{ p.model }} · {{ p.base_url }}
        </div>
      </button>
      <div
        v-if="!profilesLoading && availableProfiles.length === 0"
        class="px-3 py-2 text-xs"
        style="color: var(--semantic-text-muted)"
        data-testid="kanban-task-detail-profile-picker-empty"
      >
        No profiles configured. Add one in Settings.
      </div>
    </div>
  </div>

  <!-- Unattended mode (existing toggle, unchanged) -->
  <div class="flex-1 min-w-0 flex items-center justify-between gap-3">
    <div class="flex-1 min-w-0">
      <div class="text-xs font-medium" style="color: var(--semantic-text-dim);">
        Unattended mode
      </div>
      <div class="text-[11px] mt-0.5" style="color: var(--semantic-text-dim);">
        Keep retrying past the 10-error limit for overnight runs.
        Off = stop on too-many-retries.
      </div>
    </div>
    <label
      class="relative inline-flex items-center cursor-pointer shrink-0"
      style="color: var(--semantic-text);"
    >
      <input
        type="checkbox"
        :checked="unattended === '1'"
        @change="handleUnattendedToggle"
        class="sr-only peer"
        data-testid="kanban-task-detail-unattended-toggle"
      />
      <div
        class="w-11 h-6 rounded-full transition-colors duration-200"
        style="background-color: var(--semantic-text-dim);"
        :style="unattended === '1' ? { backgroundColor: '#f59e0b' } : {}"
      />
      <div
        class="absolute top-0.5 left-0.5 w-5 h-5 rounded-full transition-transform duration-200"
        style="background-color: white;"
        :class="unattended === '1' ? 'translate-x-5' : ''"
      />
    </label>
  </div>
</div>

<!-- Edit-mode unattended toggle (unchanged — just the toggle, no picker) -->
<div
  v-else
  class="mt-4 pt-4 flex items-center justify-between gap-3"
  style="border-top: 1px solid var(--color-border);"
  data-testid="kanban-task-detail-unattended"
>
  <div class="flex-1 min-w-0">
    <div class="text-xs font-medium" style="color: var(--semantic-text-dim);">
      Unattended mode
    </div>
    <div class="text-[11px] mt-0.5" style="color: var(--semantic-text-dim);">
      Keep retrying past the 10-error limit for overnight runs.
      Off = stop on too-many-retries.
    </div>
  </div>
  <label class="relative inline-flex items-center cursor-pointer shrink-0" ...>
    <!-- existing checkbox markup -->
  </label>
</div>
```

Run the tests, expect PASS:

```bash
cd src/apps/desktop && timeout 60 bunx vitest run KanbanTaskDetailDialog.profile 2>&1 | tail -n 15
```

- [ ] All 9 tests pass
- [ ] Type-check via `bun run build`:

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5
```

### Step 1.3 — Commit

```bash
git add src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue \
        src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.profile.spec.ts
git -c user.name=ginwa -c user.email=ginwa@local commit -m "feat(kanban): profile picker in New Task dialog (create mode)

Adds a profile-model picker to the New Task dialog (create mode
only). Mirrors ChatView's picker pattern: loads profiles via
api.getPabrikConfig(); renders a dropdown with 'Default (top-level
config)' + each profile; selection updates a local selectedProfile
ref; both create + create-and-run emits carry selectedProfile.

P2 = 'Default' (= backend default). Empty profile list = picker
still works (just shows Default). Profile is included in emit
payload but Path A: only runAgentOnNewTask threads it through to
the backend (plain-create loses the profile choice — user can set
from chatview later).

UI: same row as Unattended-mode toggle (Q2 = 2a). The picker is
on the left, the toggle on the right.

Plan: docs/superpowers/plans/2026-08-06-kanban-task-profile-selector.md
Task 1 of 3"
```

---

## Task 2 — Store action + host wiring (TDD)

> **Outcome**: `workspacesStore.runAgentOnNewTask` accepts `selectedProfile?: string` and forwards it to `api.sendChatMessage`. `KanbanView.handleCreateTaskSave` passes `payload.selectedProfile` through. Behavioural tests extend the existing test files.

### Step 2.1 — Extend store test

Edit `src/apps/desktop/src/__tests__/workspacesStoreRunAgent.spec.ts`:

Add 2 new test cases after the existing 3:

```ts
it('forwards selectedProfile to api.sendChatMessage when provided', async () => {
  const sendSpy = vi
    .spyOn(api, 'sendChatMessage')
    .mockResolvedValue({ status: 'send' })
  const store = useWorkspacesStore()
  await store.runAgentOnNewTask('ws_1', 'item_1', 'task_abc', {
    queueMessage: 'Title',
    cwd: '/cwd',
    selectedProfile: '900r1bu',
  })
  expect(sendSpy).toHaveBeenCalledWith(
    'task_abc',
    'Title',
    '/cwd',
    undefined,
    '900r1bu',
    '',
  )
})

it('forwards empty string when selectedProfile is undefined', async () => {
  const sendSpy = vi
    .spyOn(api, 'sendChatMessage')
    .mockResolvedValue({ status: 'send' })
  const store = useWorkspacesStore()
  await store.runAgentOnNewTask('ws_1', 'item_1', 'task_abc', {
    queueMessage: 'Title',
    cwd: '/cwd',
  })
  expect(sendSpy).toHaveBeenCalledWith(
    'task_abc',
    'Title',
    '/cwd',
    undefined,
    '',
    '',
  )
})
```

Run, expect FAIL:

```bash
cd src/apps/desktop && timeout 60 bunx vitest run workspacesStoreRunAgent 2>&1 | tail -n 15
```

- [ ] Failing test confirmed

### Step 2.2 — Extend the store action

Edit `src/apps/desktop/src/stores/workspaces.ts` — find the `runAgentOnNewTask` action (added in PR #160):

```ts
async function runAgentOnNewTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  params: {
    queueMessage: string
    cwd: string
    isAutoRetryUntilStop?: '0' | '1'
    selectedProfile?: string  // NEW (plan: 2026-08-06-kanban-task-profile-selector)
  },
): Promise<{ status: string } | undefined> {
  try {
    return await api.sendChatMessage(
      taskId,
      params.queueMessage,
      params.cwd,
      undefined, // imageUrls
      params.selectedProfile ?? '', // CHANGED — was ''
      params.isAutoRetryUntilStop ?? '',
    )
  } catch (err) {
    console.error('Failed to run agent on new task:', err)
    return undefined
  }
}
```

Run, expect PASS:

```bash
cd src/apps/desktop && timeout 60 bunx vitest run workspacesStoreRunAgent 2>&1 | tail -n 10
```

- [ ] All 5 tests pass

### Step 2.3 — Extend the host test

Edit `src/apps/desktop/src/__tests__/KanbanView.createAndRun.spec.ts`:

Add a new test after the existing 6:

```ts
it('forwards selectedProfile from dialog emit to runAgentOnNewTask', async () => {
  vi.spyOn(api, 'createTask').mockResolvedValue({
    id: 'task_new',
    name: 'My task',
    description: 'desc',
    task_type: 'standard',
  })
  vi.spyOn(api, 'moveTaskToColumn').mockResolvedValue({ success: true })
  vi.spyOn(api, 'sendChatMessage').mockResolvedValue({ status: 'send' })

  const store = useWorkspacesStore()
  vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
  vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)
  const runSpy = vi
    .spyOn(store, 'runAgentOnNewTask')
    .mockResolvedValue({ status: 'send' })

  const view = await mountView()
  const vm: any = view.vm
  await vm.handleCreateTaskSave({
    mode: 'create_and_run',
    name: 'My task',
    description: 'desc',
    is_auto_retry_until_stop: '0',
    tags: [],
    selectedProfile: '900r1bu',
  })
  await flushPromises()

  expect(runSpy).toHaveBeenCalledWith(
    'ws_1',
    'item_1',
    'task_new',
    expect.objectContaining({
      selectedProfile: '900r1bu',
    }),
  )
})
```

Run, expect FAIL:

```bash
cd src/apps/desktop && timeout 60 bunx vitest run KanbanView.createAndRun 2>&1 | tail -n 15
```

- [ ] Failing test confirmed

### Step 2.4 — Wire the host

Edit `src/apps/desktop/src/components/kanban/KanbanView.vue` — find the `runAgentOnNewTask` call inside `handleCreateTaskSave`:

```ts
const result = await workspacesStore.runAgentOnNewTask(
  wsId,
  itId,
  taskId,
  {
    queueMessage,
    cwd: props.item.path || '',
    isAutoRetryUntilStop: payload.is_auto_retry_until_stop,
    selectedProfile: payload.selectedProfile ?? '',  // NEW
  },
)
```

Run all three test suites, expect PASS:

```bash
cd src/apps/desktop && timeout 60 bunx vitest run workspacesStoreRunAgent KanbanView.createAndRun 2>&1 | tail -n 10
```

- [ ] All tests pass
- [ ] Type-check via `bun run build`:

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5
```

### Step 2.5 — Commit

```bash
git add src/apps/desktop/src/stores/workspaces.ts \
        src/apps/desktop/src/components/kanban/KanbanView.vue \
        src/apps/desktop/src/__tests__/workspacesStoreRunAgent.spec.ts \
        src/apps/desktop/src/__tests__/KanbanView.createAndRun.spec.ts
git -c user.name=ginwa -c user.email=ginwa@local commit -m "feat(kanban): thread selectedProfile through store + host

runAgentOnNewTask accepts selectedProfile?: string and forwards
to api.sendChatMessage (replaces today's hardcoded '').

KanbanView.handleCreateTaskSave forwards payload.selectedProfile
from the dialog's create-and-run emit down to runAgentOnNewTask.
Empty/undefined defaults to '' (= backend default).

Plan: docs/superpowers/plans/2026-08-06-kanban-task-profile-selector.md
Task 2 of 3"
```

---

## Task 3 — Final integration verification

> **Outcome**: All quality gates green. Full vitest suite passes; vue-tsc passes; Zig backend builds (no changes but verify).

### Step 3.1 — Run the full vitest suite

```bash
cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 5
```

- [ ] All tests pass (existing + new). Same single pre-existing `DesignView.nudge.spec.ts` flake as baseline.

### Step 3.2 — Type-check

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5
```

- [ ] vue-tsc clean
- [ ] No `.js` files emitted next to `.ts` source files (per `.pabrik/skills/vue-tsc-build-emits-js-files/SKILL.MD`)

### Step 3.3 — Backend smoke (no changes, verify)

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

- [ ] Same pass count as baseline (frontend-only change)

```bash
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
```

### Step 3.4 — Manual smoke (port 8080)

```bash
mkdir -p /tmp/pabrik-smoke && HOME=/tmp/pabrik-smoke timeout 600 /path/to/zig-out/bin/pabrik --port 8080 &
sleep 4
```

In the webapp:
1. Open a kanban → click + on Todo → fill title "Test profile" + description "Body"
2. Click the profile picker → select "900r1bu" (or another configured profile)
3. Click ▶ Create task & run agent
4. Assert: chatview opens → chatview's profile picker shows "900r1bu" (not "Default")
5. Assert: the queued message is "Test profile\n\nBody"; the agent runs

Cleanup:

```bash
kill $PABRIK_PID 2>/dev/null
rm -rf /tmp/pabrik-smoke
```

### Step 3.5 — Final docs update

Edit `docs/SPEC.md`:

1. Add a row to §3.7 plans mapping (after the create-and-run row):

```
| `2026-08-06-kanban-task-profile-selector.md` | ✅ | Profile-model picker in the New Task dialog (create mode). See §3.7.6 below. |
```

2. Add a new subsection after §3.7.5 (call it §3.7.6):

```
#### 3.7.6 New Task dialog — profile-model picker (2026-08-06)

The New Task dialog (create mode) gains a profile-model picker. Loads profiles via `api.getPabrikConfig()`; mirrors ChatView's pattern. Selected profile is threaded through `POST /api/llm/session` and persisted on the new session via `sessions.selected_profile_model` (per PR #158).

**Layout.** Same row as the Unattended-mode toggle (compact 2-column). Picker on the left, toggle on the right.

**Default.** `''` = backend default ("Default (top-level config)"). User opts in.

**Persistence.** Path A: profile is set only when the user clicks "Create task & run agent" (which calls `runAgentOnNewTask` → `api.sendChatMessage(selectedProfile)` → backend `POST /api/llm/session`). Plain "Create task" without an agent run captures the choice in the payload but does NOT persist (user can set from chatview later). Editing `selectedProfile` via `PUT /api/llm/session/:id` works the same as today.

**Plan:** `docs/superpowers/plans/2026-08-06-kanban-task-profile-selector.md`
```

3. Update the §10.1 PR index row from `#TBD` to `#160` (assuming we squash into PR #160).

4. Update §10.1 status count (143 → 145 if we treat the picker as a separate PR, or just bump the comment).

Edit `PABRIK.md`:

Append a changelog entry:

```markdown
### 2026-08-06: kanban new task profile picker

**What landed.** Profile-model picker in the New Task dialog (create mode only). Mirrors ChatView's picker pattern. Loads profiles via `api.getPabrikConfig`; renders a dropdown with "Default (top-level config)" + each profile. Selection updates a local `selectedProfile` ref; both `create` and `create-and-run` emits carry `selectedProfile`. Same row as Unattended-mode toggle (Q2 = 2a — compact 2-column layout).

**Persistence.** Path A: profile is set only when the user clicks "Create task & run agent" (which calls `runAgentOnNewTask` → `api.sendChatMessage(selectedProfile)`). Plain "Create task" without an agent run captures the choice but does NOT persist (user can set from chatview later). The chatview's profile picker reflects the new profile immediately when the user lands on the new chat.

**Files.** 6 (1 NEW test, 5 EDIT impl+tests). Frontend-only — no backend changes, no migration, no Zig changes.

**Plan:** `docs/superpowers/plans/2026-08-06-kanban-task-profile-selector.md`
**Branch:** `worktree/kanban-create-task-run-agent` (squashed into PR #160)
```

### Step 3.6 — Final commit + push

```bash
git add docs/SPEC.md PABRIK.md
git -c user.name=ginwa -c user.email=ginwa@local commit -m "docs: SPEC.md + PABRIK.md entries for kanban task profile selector

SPEC.md:
  - New §3.7 plans mapping row
  - New §3.7.6 'profile picker' subsection
  - PR index #TBD -> #160

PABRIK.md:
  - 2026-08-06 changelog entry

Plan: docs/superpowers/plans/2026-08-06-kanban-task-profile-selector.md
Task 3 of 3"

git push origin worktree/kanban-create-task-run-agent
```

- [ ] Branch pushed (PR #160 auto-updates)

---

## Out of scope (deferred — do NOT do in this plan)

- **Profile picker in edit mode** (Q1 = 1a). Follow-up.
- **Path B: persist `selected_profile_model` on task create** (would need backend + migration). Follow-up.
- **Profile creation from the picker** (today: "Add one in Settings" link to PabrikSettings).
- **Profile filtering / search.** Out of scope.