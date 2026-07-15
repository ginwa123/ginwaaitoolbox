# Local Memories Workspace Item Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the user clicks a workspace item that has a `path`, show the local memories at `<path>/.nalar/memories/*.md` in the UI (currently invisible — clicking a folder item like "be" only shows the centered card with the name + path). For non-kanban items the memories view replaces the centered empty card in the main content area; for kanban items it lives as a new tab inside the existing KanbanSettingsDialog.

**Architecture:** Frontend-only change. A new `WorkspaceItemMemoriesView.vue` component (list + detail, two-panel) is wired into `AppLayout.vue`'s empty-state branch and reuses the existing `listLocalMemories` / `getLocalMemoryDetail` / `createLocalMemory` / `updateLocalMemory` / `deleteLocalMemory` API methods. The same component is mounted inside `KanbanSettingsDialog.vue` as a new tab alongside the existing Columns tab. Zero backend changes.

**Tech Stack:** Vue 3 + TypeScript + Pinia (frontend only). No new dependencies.

---

## Context

### Current state

- `WorkspaceItem` interface (`src/apps/desktop/src/stores/workspaces.ts:23`, also `src/apps/desktop/src/api/index.ts:134`) has an optional `path?: string | null` field — the on-disk cwd for the project.
- Existing local-memories API in `src/apps/desktop/src/api/index.ts:1328-1385`:
  - `listLocalMemories(cwd)` → `GET /local-memories?cwd=...`
  - `getLocalMemoryDetail(name, cwd)` → `GET /local-memories/<name>?cwd=...`
  - `createLocalMemory(name, content, cwd)` → `POST /local-memories`
  - `updateLocalMemory(name, content, cwd)` → `PUT /local-memories/<name>?cwd=...`
  - `deleteLocalMemory(name, cwd)` → `DELETE /local-memories/<name>?cwd=...`
- Backend list handler: `src/ai_workflow/tui/http_handlers/local_memories_list.zig`. Files live at `<cwd>/.nalar/memories/*.md` (convention from `docs/plans/2026-06-10-local-cwd-memories-in-prompt.md:37`).
- Existing `MemoriesSettings.vue` (global memories UI at `~/.config/nalar/memories/`) uses a list+detail two-panel layout — the new per-item view mirrors that pattern, parameterized by `cwd`.
- `MemoryDetail.vue` (global-memories detail editor) is reusable as-is if we pass `cwd` via a new prop, but the existing API methods (e.g. `updateMemory`) are global-only. To avoid forking the component, the new detail view is a thin wrapper that calls `getLocalMemoryDetail` / `updateLocalMemory` / `deleteLocalMemory` directly (see Task 2 decision below).
- AppLayout current empty state: `src/apps/desktop/src/components/AppLayout.vue:1366-1414` — a centered card with the workspace item name + workspace name + path, no memories.
- KanbanSettingsDialog current structure: `src/apps/desktop/src/components/KanbanSettingsDialog.vue` — a single-column dialog with header + add-column form + columns list + copy-spec footer. Adding a tab strip at the top introduces a "Local Memories" tab without changing the existing columns tab.

### What's already in place

- All HTTP endpoints and API client methods (`api/index.ts:1328-1385`).
- The `Memory` / `MemoryDetail` TS interfaces in `api/index.ts:1239-1253`.
- The `local_memories_create.zig` HTTP handler validates that `cwd` is non-empty (returns 400 otherwise). The new component must handle the "no cwd" case by NOT calling the API.
- `setActiveWorkspaceItem` / `activeWorkspaceItem` (`src/apps/desktop/src/stores/workspaces.ts` ~line 1559-1577) — the active item changes on click and triggers re-renders.
- The Vue 3 `<Teleport>` + `<Transition>` pattern in `KanbanSettingsDialog.vue:179` — same idiom is used for the new memories list+detail if we ever need it as a modal.

### Out of scope

- Backend changes (every needed endpoint already exists).
- Auto-refresh on file-system change (no inotify / chokidar). Refresh is by clicking the workspace item again or hitting the "↻ Refresh" button.
- Editing the workspace item's `path` from the UI (separate "edit workspace item name" feature).
- A "global vs local memory" diff view (a separate dashboard, not a per-item concern).
- Per-item memory quotas, sizes, or sizes beyond what the API already returns.
- Real-time multi-user sync (not a project-wide concern).

---

## File Structure

### New frontend files (Vue / TS)

| File | Responsibility |
|---|---|
| `src/apps/desktop/src/components/WorkspaceItemMemoriesView.vue` | List+detail two-panel view of `<cwd>/.nalar/memories/`. Handles loading/empty/error states, create/edit/delete via existing API methods. |
| `src/apps/desktop/src/__tests__/WorkspaceItemMemoriesView.spec.ts` | Component tests (mock fetch, render list + detail per item type). |

### Modified frontend files (Vue / TS)

| File | Change |
|---|---|
| `src/apps/desktop/src/components/AppLayout.vue` | When `currentView === 'workspace'` AND `activeWorkspaceItem.path` is truthy, mount `WorkspaceItemMemoriesView` instead of the centered card. Pass `cwd` and `itemName` props. Keep the centered card as fallback when path is empty/null. |
| `src/apps/desktop/src/components/KanbanSettingsDialog.vue` | Add a `mode` ref (`'columns' \| 'memories'`) and a tab strip at the top of the dialog body. In `'memories'` mode, render `WorkspaceItemMemoriesView` with `cwd = props.item.path`. The existing columns-tab content (header + add-form + list + footer) becomes the `'columns'` mode and is unchanged. |
| `src/apps/desktop/src/components/AppLayout.vue` (second touch) | Bind the kanban settings dialog's default mode to `'columns'`, but if `props.item.path` is truthy, expose a way to navigate to `'memories'` (a prop OR a new emit). Decide in Task 4 — simplest is a `:initial-mode` prop. |

### No backend changes

The HTTP handlers at `src/ai_workflow/tui/http_handlers/local_memories_*.zig` are unchanged. The frontend reuses every method on `api/index.ts:1328-1385`.

---

## Defaults locked by this plan

1. **Placement for kanban items** — Memories live as a new tab inside the existing `KanbanSettingsDialog` (per user decision 2026-07-21). The kanban board view is unchanged. To reach memories for a kanban, the user clicks the existing "⚙ Settings" button on the kanban header, then switches to the "Local Memories" tab. (Decided in chat; see KanbanSettingsDialog.vue:222 for the settings button location.)
2. **Placement for non-kanban items** — Memories replace the centered empty card in the main content area (`AppLayout.vue:1366-1414`). The card collapses to a small header bar showing item name + workspace name + path (compact, not the 1/2-page centered card).
3. **Empty cwd fallback** — Items with no `path` (`null`, `""`, `undefined`) keep today's centered card. No empty-state hint or path-edit button in v1.
4. **Refresh** — The list auto-refetches when the workspace item is clicked (the active-item watcher fires on click). A "↻ Refresh" button in the list header covers the "edit file in another terminal" case.
5. **CRUD scope** — Full CRUD: list, view, create, edit, delete (mirroring `MemoryDetail.vue` for global memories). Reuses existing API methods; no new tool surface.
6. **Reuse vs fork of `MemoryDetail.vue`** — Forked into a thin `LocalMemoryDetailView.vue` (Task 2). Reason: `MemoryDetail.vue` calls global-memory API methods (`getMemoryDetail`, `updateMemory`, `deleteMemory`) which don't accept a `cwd` arg. A 30-line wrapper that calls the local-memory variants is simpler than parameterizing the global one.
7. **Tab strip in KanbanSettingsDialog** — Two tabs: "Columns" (existing content) and "Local Memories" (new). Tab is rendered as a `<div>` strip with 2 buttons; no router changes. Default tab: `Columns`.
8. **Header style in the new view** — Reuse the existing `MemoryList` / `MemoryDetail` visual idiom (🧠 icon, title, size, path). Same colors via `var(--semantic-*)` tokens (no new theme tokens).

---

## Task 1: Create `WorkspaceItemMemoriesView.vue`

**Files:**
- Create: `src/apps/desktop/src/components/WorkspaceItemMemoriesView.vue`
- Test: `src/apps/desktop/src/__tests__/WorkspaceItemMemoriesView.spec.ts` (created in Task 5)

This is the main building block. It is mounted by both AppLayout (non-kanban) and KanbanSettingsDialog (kanban). It takes `cwd: string` and `itemName?: string` as props.

### Step 1.1: Write the failing component test

**Files:**
- Create: `src/apps/desktop/src/__tests__/WorkspaceItemMemoriesView.spec.ts`

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import WorkspaceItemMemoriesView from '../components/WorkspaceItemMemoriesView.vue'
import * as api from '../api'

describe('WorkspaceItemMemoriesView', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('renders empty state when no memories exist for cwd', async () => {
    vi.spyOn(api, 'listLocalMemories').mockResolvedValue({ memories: [] })
    const wrapper = mount(WorkspaceItemMemoriesView, {
      props: { cwd: '/tmp/proj', itemName: 'My Project' },
    })
    await flushPromises()
    expect(wrapper.text()).toContain('No memories yet')
    expect(wrapper.text()).toContain('My Project')
  })

  it('renders list of memories after fetch', async () => {
    vi.spyOn(api, 'listLocalMemories').mockResolvedValue({
      memories: [
        { name: 'rule-a.md', title: 'Rule A', path: '/tmp/proj/.nalar/memories/rule-a.md', size: 256 },
        { name: 'rule-b.md', title: 'Rule B', path: '/tmp/proj/.nalar/memories/rule-b.md', size: 1024 },
      ],
    })
    const wrapper = mount(WorkspaceItemMemoriesView, {
      props: { cwd: '/tmp/proj' },
    })
    await flushPromises()
    expect(wrapper.text()).toContain('Rule A')
    expect(wrapper.text()).toContain('Rule B')
  })

  it('shows the cwd in the header subtitle', async () => {
    vi.spyOn(api, 'listLocalMemories').mockResolvedValue({ memories: [] })
    const wrapper = mount(WorkspaceItemMemoriesView, {
      props: { cwd: '/home/u/proj' },
    })
    await flushPromises()
    expect(wrapper.text()).toContain('/home/u/proj')
    expect(wrapper.text()).toContain('.nalar/memories')
  })

  it('does not call API when cwd is empty', async () => {
    const spy = vi.spyOn(api, 'listLocalMemories')
    const wrapper = mount(WorkspaceItemMemoriesView, {
      props: { cwd: '' },
    })
    await flushPromises()
    expect(spy).not.toHaveBeenCalled()
    expect(wrapper.text()).toContain('No path')
  })
})
```

### Step 1.2: Register the test file

**Files:**
- Modify: `src/apps/desktop/src/__tests__/...` — locate the test runner registration entry (search for `MemoryList.spec` import and add `WorkspaceItemMemoriesView.spec` next to it). Pattern matches the project memory `frontend-typescript-bun-build-as-typecheck.md`.

Run `cd src/apps/desktop && timeout 120 bunx vitest run WorkspaceItemMemoriesView.spec.ts 2>&1 | tail -n 20`. Expected: all 4 tests FAIL (component does not exist yet, so the import will error).

### Step 1.3: Implement the component (skeleton)

**Files:**
- Create: `src/apps/desktop/src/components/WorkspaceItemMemoriesView.vue`

```vue
<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import LocalMemoryDetailView from './LocalMemoryDetailView.vue'
import {
  listLocalMemories,
  getLocalMemoryDetail,
  createLocalMemory,
  updateLocalMemory,
  deleteLocalMemory,
  type Memory,
} from '../api'

const props = defineProps<{
  cwd: string
  itemName?: string
}>()

const memories = ref<Memory[]>([])
const isLoading = ref(false)
const error = ref<string | null>(null)
const selectedMemoryName = ref<string | null>(null)
const isCreating = ref(false)

const hasCwd = computed(() => !!props.cwd && props.cwd.length > 0)
const headerPath = computed(() =>
  hasCwd.value ? `${props.cwd}/.nalar/memories/` : '',
)

const loadList = async () => {
  if (!hasCwd.value) {
    memories.value = []
    return
  }
  isLoading.value = true
  error.value = null
  try {
    const result = await listLocalMemories(props.cwd)
    memories.value = result.memories || []
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load memories'
  } finally {
    isLoading.value = false
  }
}

const handleRefresh = () => loadList()

const handleSelectMemory = (name: string) => {
  selectedMemoryName.value = name
}

const handleStartCreate = () => {
  selectedMemoryName.value = null
  isCreating.value = true
}

const handleCancelCreate = () => {
  isCreating.value = false
}

const handleMemorySaved = () => {
  isCreating.value = false
  // Refresh list (new memory appears at top or bottom — server returns
  // sorted by name; preserve that). Detail's emit('memorySaved') fires
  // this AFTER the API returns, so reload here is safe.
  void loadList()
}

const handleMemoryDeleted = () => {
  selectedMemoryName.value = null
  void loadList()
}

const formatSize = (bytes: number): string => {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

// Re-fetch when cwd changes (user clicks a different workspace item).
// This is the "auto-refresh on focus" decision (#4 in Defaults).
watch(
  () => props.cwd,
  () => {
    selectedMemoryName.value = null
    isCreating.value = false
    void loadList()
  },
  { immediate: true },
)
</script>

<template>
  <div class="flex flex-col h-full" data-testid="workspace-item-memories-view">
    <!-- Header: item name + path + refresh button -->
    <div
      class="flex items-center justify-between gap-3 px-6 py-3 shrink-0"
      style="border-bottom: 1px solid var(--color-border);"
    >
      <div class="flex flex-col min-w-0">
        <h2
          v-if="itemName"
          class="text-base font-semibold truncate"
          style="color: var(--semantic-text);"
        >
          🧠 {{ itemName }}
        </h2>
        <p
          v-if="hasCwd"
          class="text-xs mt-0.5 truncate"
          style="color: var(--semantic-text-dim);"
          data-testid="workspace-item-memories-path"
        >
          {{ headerPath }}
        </p>
      </div>
      <div class="flex items-center gap-2 shrink-0">
        <button
          v-if="hasCwd"
          type="button"
          @click="handleRefresh"
          :disabled="isLoading"
          data-testid="workspace-item-memories-refresh"
          class="px-3 py-1.5 rounded-lg text-xs font-medium"
          style="
            background-color: var(--semantic-card-bg);
            color: var(--semantic-text-muted);
            border: 1px solid var(--color-border);
          "
        >
          {{ isLoading ? 'Loading…' : '↻ Refresh' }}
        </button>
        <button
          v-if="hasCwd"
          type="button"
          @click="handleStartCreate"
          data-testid="workspace-item-memories-new"
          class="px-3 py-1.5 rounded-lg text-xs font-medium"
          style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: white;"
        >
          + New Memory
        </button>
      </div>
    </div>

    <!-- Empty cwd fallback (rare — only legacy items without path) -->
    <div
      v-if="!hasCwd"
      class="flex-1 flex items-center justify-center"
      data-testid="workspace-item-memories-no-cwd"
    >
      <p class="text-sm" style="color: var(--semantic-text-dim);">
        No path is set on this project — pick a directory when creating the item to enable local memories.
      </p>
    </div>

    <!-- Loading -->
    <div
      v-else-if="isLoading && memories.length === 0"
      class="flex-1 flex items-center justify-center"
      data-testid="workspace-item-memories-loading"
    >
      <div class="flex items-center gap-3">
        <div
          class="w-5 h-5 border-2 rounded-full animate-spin"
          style="border-color: var(--color-violet); border-top-color: transparent;"
        ></div>
        <span style="color: var(--semantic-text-muted);">Loading memories…</span>
      </div>
    </div>

    <!-- Error -->
    <div
      v-else-if="error"
      class="flex-1 flex items-center justify-center"
      data-testid="workspace-item-memories-error"
    >
      <div class="text-center">
        <p class="text-sm" style="color: var(--color-red);">{{ error }}</p>
        <button
          type="button"
          @click="handleRefresh"
          class="mt-3 px-4 py-2 rounded-lg text-sm"
          style="
            background-color: var(--semantic-card-bg);
            color: var(--semantic-text-muted);
            border: 1px solid var(--color-border);
          "
        >Retry</button>
      </div>
    </div>

    <!-- Empty list -->
    <div
      v-else-if="memories.length === 0"
      class="flex-1 flex items-center justify-center"
      data-testid="workspace-item-memories-empty"
    >
      <div class="text-center">
        <p class="text-sm" style="color: var(--semantic-text-muted);">
          No memories yet
        </p>
        <p class="text-xs mt-1" style="color: var(--semantic-text-dim);">
          Create one with the + New Memory button, or add a <code>.md</code> file to <code>{{ headerPath }}</code>.
        </p>
      </div>
    </div>

    <!-- List + detail two-panel -->
    <div v-else class="flex-1 flex min-h-0">
      <!-- List panel -->
      <div
        class="w-72 shrink-0 overflow-y-auto"
        style="border-right: 1px solid var(--color-border);"
      >
        <ul class="p-3 space-y-2" data-testid="workspace-item-memories-list">
          <li
            v-for="mem in memories"
            :key="mem.name"
            @click="handleSelectMemory(mem.name)"
            class="p-3 rounded-lg cursor-pointer transition-all"
            :class="{ 'ring-2': selectedMemoryName === mem.name }"
            :style="selectedMemoryName === mem.name
              ? 'background-color: var(--semantic-active-bg); border: 1px solid var(--color-violet);'
              : 'background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);'"
            :data-testid="`workspace-item-memories-row-${mem.name}`"
          >
            <div class="flex items-start gap-2 min-w-0">
              <span class="text-base">🧠</span>
              <div class="flex-1 min-w-0">
                <h3
                  class="text-sm font-medium truncate"
                  style="color: var(--semantic-text);"
                >{{ mem.title }}</h3>
                <p
                  class="text-xs mt-0.5 truncate"
                  style="color: var(--semantic-text-dim);"
                >{{ mem.name }} · {{ formatSize(mem.size) }}</p>
              </div>
            </div>
          </li>
        </ul>
      </div>

      <!-- Detail panel -->
      <div class="flex-1 overflow-hidden">
        <LocalMemoryDetailView
          v-if="selectedMemoryName || isCreating"
          :cwd="cwd"
          :memory-name="isCreating ? null : selectedMemoryName"
          :is-creating="isCreating"
          @memory-saved="handleMemorySaved"
          @memory-deleted="handleMemoryDeleted"
          @cancel-create="handleCancelCreate"
        />
        <div
          v-else
          class="h-full flex items-center justify-center"
          data-testid="workspace-item-memories-detail-empty"
        >
          <p class="text-sm" style="color: var(--semantic-text-muted);">
            Select a memory, or create a new one.
          </p>
        </div>
      </div>
    </div>
  </div>
</template>
```

### Step 1.4: Run the test, expect import errors for LocalMemoryDetailView

Run `cd src/apps/desktop && timeout 120 bunx vitest run WorkspaceItemMemoriesView.spec.ts 2>&1 | tail -n 20`. Expected: tests fail because `LocalMemoryDetailView` doesn't exist yet (next task). Or, depending on the Vitest config, the file fails to compile.

This is the natural pre-`LocalMemoryDetailView` failure. Don't fix it yet — proceed to Task 2.

---

## Task 2: Create `LocalMemoryDetailView.vue`

**Files:**
- Create: `src/apps/desktop/src/components/LocalMemoryDetailView.vue`

This is a fork of `MemoryDetail.vue` (lines 1-393) that calls the local-memory API methods. The two components share ~95% of their markup, but the API calls differ:
- `MemoryDetail.vue` calls `getMemoryDetail` / `updateMemory` / `deleteMemory` (no `cwd`).
- The new view calls `getLocalMemoryDetail` / `updateLocalMemory` / `deleteLocalMemory` (with `cwd`).

For the v1 scope, copy `MemoryDetail.vue` verbatim and replace the 3 API calls. Title/size/path rendering is identical. Future refactor can parameterize both via a `cwd?: string` prop and switch the API internally, but doing that now would touch `MemoryDetail.vue` callers (MemoriesSettings.vue + AddMemoryDialog.vue) and is out of scope.

### Step 2.1: Copy `MemoryDetail.vue` to `LocalMemoryDetailView.vue`

**Files:**
- Create: `src/apps/desktop/src/components/LocalMemoryDetailView.vue`
- Source: `src/apps/desktop/src/components/MemoryDetail.vue` (the global-memory detail editor)

```bash
cp src/apps/desktop/src/components/MemoryDetail.vue \
   src/apps/desktop/src/components/LocalMemoryDetailView.vue
```

### Step 2.2: Patch imports and API calls

In `LocalMemoryDetailView.vue`, replace the imports:

```ts
// Before:
import {
  getMemoryDetail,
  createMemory,
  updateMemory,
  deleteMemory,
  type MemoryDetail as MemoryDetailData,
} from '../api'

// After:
import {
  getLocalMemoryDetail,
  createLocalMemory,
  updateLocalMemory,
  deleteLocalMemory,
  type MemoryDetail as MemoryDetailData,
} from '../api'
```

Add the new prop:

```ts
const props = defineProps<{
  memoryName: string | null
  cwd: string  // ← NEW
  isCreating?: boolean  // ← NEW (set by WorkspaceItemMemoriesView)
}>()
```

Update the watcher to pass `cwd` to `getLocalMemoryDetail`:

```ts
// Replace `getMemoryDetail(newName)` with `getLocalMemoryDetail(newName, props.cwd)`.
```

Update `saveEdit` to call `updateLocalMemory`:

```ts
// Replace `await updateMemory(detail.value.name, editContent.value)` with
// `await updateLocalMemory(detail.value.name, editContent.value, props.cwd)`.
```

Update `saveCreate` to call `createLocalMemory`:

```ts
// Replace `await createMemory(trimmedName, editContent.value)` with
// `await createLocalMemory(trimmedName, editContent.value, props.cwd)`.
```

Update `handleDelete` to call `deleteLocalMemory`:

```ts
// Replace `await deleteMemory(detail.value.name)` with
// `await deleteLocalMemory(detail.value.name, props.cwd)`.
```

Add the cancel-create emit handler:

```ts
const emit = defineEmits<{
  memoryDeleted: [name: string]
  memorySaved: []
  error: [message: string]
  cancelCreate: []  // ← NEW
}>()

const cancelCreate = () => {
  emit('cancelCreate')
}

// In the template, change @click on the Cancel-create button (line ~262):
// Before: @click="cancelCreate"
// After:  @click="$emit('cancelCreate')"
// (and remove the `cancelCreate()` local that set mode to 'empty')
```

### Step 2.3: Add an `isCreating` prop wiring

When `isCreating=true`, the view is in create mode on mount (instead of waiting for a click). Adjust the template:

```vue
<!-- At the top of the watcher, before the existing branch: -->
watch(
  () => [props.memoryName, props.isCreating, props.cwd],
  async ([newName, isCreating, _cwd]) => {
    if (isCreating) {
      detail.value = null
      editName.value = ''
      editContent.value = '# New Memory\n\nWrite your notes here.\n'
      mode.value = 'create'
      return
    }
    // ... existing logic for fetching detail by memoryName ...
  },
  { immediate: true },
)
```

### Step 2.4: Run the tests for both components

```bash
cd src/apps/desktop
timeout 120 bunx vitest run WorkspaceItemMemoriesView.spec.ts 2>&1 | tail -n 20
timeout 120 bun run build 2>&1 | tail -n 10
```

Expected:
- `WorkspaceItemMemoriesView.spec.ts` — all 4 tests PASS.
- `bun run build` — type-check is clean (catches `vue-tsc` errors the vitest runtime misses per `frontend-typescript-bun-build-as-typecheck.md`).

### Step 2.5: Commit

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/WorkspaceItemMemoriesView.vue \
        src/apps/desktop/src/components/LocalMemoryDetailView.vue \
        src/apps/desktop/src/__tests__/WorkspaceItemMemoriesView.spec.ts
git commit -m "feat(memories): add WorkspaceItemMemoriesView + LocalMemoryDetailView components"
```

---

## Task 3: Wire `WorkspaceItemMemoriesView` into `AppLayout.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/AppLayout.vue` — replace the centered card branch with the new view when `path` is truthy.

### Step 3.1: Write the failing integration test

**Files:**
- Modify: `src/apps/desktop/src/__tests__/AppLayout.spec.ts` — if it exists. If not, create a minimal smoke test.

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import AppLayout from '../components/AppLayout.vue'
import * as api from '../api'

describe('AppLayout — workspace item memories view', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('renders WorkspaceItemMemoriesView when active workspace item has a path', async () => {
    vi.spyOn(api, 'listLocalMemories').mockResolvedValue({ memories: [] })
    // Bootstrap a workspace item into the store and set it active.
    const wrapper = mount(AppLayout, {
      props: { /* whatever AppLayout currently takes */ },
      // global.plugins: [pinia], use a fresh Pinia instance
    })
    // ... (use the existing workspacesStore patterns from AppLayout tests)
    await flushPromises()
    expect(wrapper.find('[data-testid="workspace-item-memories-view"]').exists()).toBe(true)
  })

  it('renders the centered card when path is empty', async () => {
    // ... existing fallback test
    expect(wrapper.text()).toContain('Select a project from the sidebar to get started')
  })
})
```

If `AppLayout.spec.ts` doesn't exist, skip and rely on manual smoke testing in Task 6.

### Step 3.2: Wire the view into the empty-state branch

In `src/apps/desktop/src/components/AppLayout.vue`:

```vue
<!-- Around line 1366-1414, replace the centered-card branch with: -->
<div
  v-else-if="currentView === 'workspace'"
  class="flex-1 flex flex-col"
>
  <!-- Compact header card (always shown when an item is active) -->
  <div
    v-if="activeWorkspaceItem"
    class="px-6 py-3 flex items-center justify-between gap-3 shrink-0"
    style="border-bottom: 1px solid var(--color-border);"
  >
    <div class="flex flex-col min-w-0">
      <h2 class="text-lg font-semibold truncate" style="color: var(--semantic-text);">
        {{ activeWorkspaceItem.name }}
      </h2>
      <p class="text-xs truncate" style="color: var(--semantic-text-dim);">
        {{ workspacesStore.activeWorkspace?.name }}
        <span v-if="activeWorkspaceItem.path"> · {{ activeWorkspaceItem.path }}</span>
      </p>
    </div>
  </div>

  <!-- Memories view: only when path is truthy -->
  <div v-if="activeWorkspaceItem && activeWorkspaceItem.path" class="flex-1 min-h-0">
    <WorkspaceItemMemoriesView
      :key="activeWorkspaceItem.id"
      :cwd="activeWorkspaceItem.path"
      :item-name="activeWorkspaceItem.name"
    />
  </div>

  <!-- No-path fallback: keep today's centered card -->
  <div
    v-else
    class="flex-1 flex flex-col items-center justify-center p-8"
  >
    <!-- ... existing centered-card markup (lines 1382-1413) ... -->
  </div>
</div>
```

Add the import at the top of `AppLayout.vue`:

```ts
import WorkspaceItemMemoriesView from './WorkspaceItemMemoriesView.vue'
```

### Step 3.3: Verify build + smoke test

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
timeout 120 bunx vitest run AppLayout 2>&1 | tail -n 20
```

Expected:
- `bun run build` clean (vue-tsc strict).
- AppLayout tests pass.

Manual smoke (use the project's `run nalar` recipe):
1. `./zig-out/bin/nalar --port 8080 &`
2. Open `http://127.0.0.1:8080/`
3. Click the "be" workspace item (folder) — the memories view should appear, fetching from `/home/.../ginwaaitoolbox/.nalar/memories/`.
4. Click "sprint 2" (kanban) — the kanban board still renders (NOT the memories view; that's in the kanban settings).

### Step 3.4: Commit

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/AppLayout.vue \
        src/apps/desktop/src/__tests__/AppLayout.spec.ts
git commit -m "feat(memories): show local memories when clicking a workspace item with a path"
```

---

## Task 4: Add "Local Memories" tab to `KanbanSettingsDialog.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/KanbanSettingsDialog.vue` — add a tab strip + conditional render of `WorkspaceItemMemoriesView` in the new tab.

### Step 4.1: Add tab state and props

```ts
// In <script setup>, after the existing `showSettingsEditor` ref:
type SettingsMode = 'columns' | 'memories'
const settingsMode = ref<SettingsMode>('columns')

// Accept an optional initial mode prop:
const props = defineProps<{
  show: boolean
  item: WorkspaceItem | null
  initialMode?: SettingsMode  // ← NEW; default 'columns'
}>()

// Sync settingsMode when dialog opens, respecting initialMode:
watch(
  () => [props.show, props.initialMode] as const,
  ([show, initialMode]) => {
    if (show) {
      settingsMode.value = initialMode ?? 'columns'
    }
  },
  { immediate: true },
)
```

### Step 4.2: Add the tab strip in the template

After the header `<div>` (around line 253 in `KanbanSettingsDialog.vue:211-253`), insert:

```vue
<!-- Tab strip: Columns | Local Memories -->
<div
  v-if="item?.path"
  class="flex gap-1 px-5 pt-3 pb-0 shrink-0"
  style="border-bottom: 1px solid var(--color-border);"
  data-testid="kanban-settings-tabs"
>
  <button
    type="button"
    @click="settingsMode = 'columns'"
    :data-testid="'kanban-settings-tab-columns'"
    class="px-3 py-2 text-xs font-medium rounded-t-lg transition-colors"
    :style="settingsMode === 'columns'
      ? 'background-color: var(--semantic-card-bg); color: var(--semantic-text); border: 1px solid var(--color-border); border-bottom-color: var(--semantic-card-bg); margin-bottom: -1px;'
      : 'background-color: transparent; color: var(--semantic-text-muted);'"
  >Columns</button>
  <button
    type="button"
    @click="settingsMode = 'memories'"
    :data-testid="'kanban-settings-tab-memories'"
    class="px-3 py-2 text-xs font-medium rounded-t-lg transition-colors"
    :style="settingsMode === 'memories'
      ? 'background-color: var(--semantic-card-bg); color: var(--semantic-text); border: 1px solid var(--color-border); border-bottom-color: var(--semantic-card-bg); margin-bottom: -1px;'
      : 'background-color: transparent; color: var(--semantic-text-muted);'"
  >🧠 Local Memories</button>
</div>
```

### Step 4.3: Wrap the existing columns content in a `v-if`

Wrap the existing add-form + columns list + copy-spec footer in a `v-if="settingsMode === 'columns'"` (line ~256 onwards in `KanbanSettingsDialog.vue`):

```vue
<template v-if="settingsMode === 'columns'">
  <!-- existing add-form, columns list, copy-spec footer -->
</template>
```

Add the memories tab body (renders the new view inside the dialog):

```vue
<div
  v-else-if="settingsMode === 'memories' && item?.path"
  class="flex-1 min-h-0 overflow-hidden"
  data-testid="kanban-settings-memories-panel"
>
  <WorkspaceItemMemoriesView
    :cwd="item.path"
    :item-name="item.name"
  />
</div>
<div
  v-else-if="settingsMode === 'memories' && !item?.path"
  class="flex-1 flex items-center justify-center p-8"
  data-testid="kanban-settings-memories-no-path"
>
  <p class="text-sm" style="color: var(--semantic-text-dim);">
    No directory is set on this kanban — pick one when creating the kanban to enable local memories.
  </p>
</div>
```

Add the import at the top of `KanbanSettingsDialog.vue`:

```ts
import WorkspaceItemMemoriesView from './WorkspaceItemMemoriesView.vue'
```

### Step 4.4: Wire initialMode in `AppLayout.vue`

In `AppLayout.vue` (`<KanbanSettingsDialog>` mount around line 1513), add an optional `initial-mode` binding — but since AppLayout only opens the dialog from one place, the default ('columns') is fine. The user navigates to memories by clicking the new tab. Skip this if AppLayout doesn't need to programmatically open the memories tab.

If we want a quick "⚙ Memories" entry point on the kanban board header, add it as a separate emit (out of scope for v1).

### Step 4.5: Verify

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
timeout 120 bunx vitest run KanbanSettingsDialog 2>&1 | tail -n 20
```

Manual smoke (port 8080):
1. Open the kanban for "sprint 2".
2. Click ⚙ Settings — verify the existing columns UI still works (no regression).
3. Click the "🧠 Local Memories" tab — verify the memories view fetches and renders for the kanban's path.

### Step 4.6: Commit

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/KanbanSettingsDialog.vue
git commit -m "feat(kanban-settings): add Local Memories tab"
```

---

## Task 5: Tests + verification

**Files:**
- Extend `src/apps/desktop/src/__tests__/WorkspaceItemMemoriesView.spec.ts` (already created in Task 1; add coverage for delete + edit paths here).
- Extend `src/apps/desktop/src/__tests__/apiLocalMemories.spec.ts` if it's missing coverage for the new component-level wiring (it already covers API methods).

### Step 5.1: Add delete coverage

In `WorkspaceItemMemoriesView.spec.ts`, add:

```ts
it('refetches the list after a memory is deleted', async () => {
  const listSpy = vi.spyOn(api, 'listLocalMemories')
    .mockResolvedValueOnce({ memories: [{ name: 'a.md', title: 'A', path: '/p/a.md', size: 1 }] })
    .mockResolvedValueOnce({ memories: [] })
  vi.spyOn(api, 'getLocalMemoryDetail').mockResolvedValue({ memory: { name: 'a.md', title: 'A', path: '/p/a.md', size: 1, content: '' }, error_message: null })
  vi.spyOn(api, 'deleteLocalMemory').mockResolvedValue({ success: true, name: 'a.md', error_message: null })

  const wrapper = mount(WorkspaceItemMemoriesView, { props: { cwd: '/p' } })
  await flushPromises()
  await wrapper.find('[data-testid="workspace-item-memories-row-a.md"]').trigger('click')
  // Trigger delete via the detail view's delete button (data-testid="memory-detail-delete")
  // Then assert listSpy was called twice.
  // ... (full assertion)
})
```

### Step 5.2: Add edit coverage

```ts
it('saves an edit and refreshes the list', async () => {
  // Similar to delete — mock getLocalMemoryDetail, click Edit, change content,
  // click Save, assert updateLocalMemory was called and listSpy was called twice.
})
```

### Step 5.3: Run all frontend tests + build

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
timeout 120 bunx vitest run 2>&1 | tail -n 30
```

Expected:
- `bun run build` clean.
- All Vitest tests pass (the previous baseline + the new ones).

If a test fails because of `bun run build`'s vue-tsc strict mode (per `frontend-typescript-bun-build-as-typecheck.md`), fix the underlying TS error, not the test.

### Step 5.4: Run all backend tests + build

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
rm -rf zig-out/bin
timeout 300 zig build 2>&1 | tail -n 5
```

Expected: all three pass with no new failures. (Backend is untouched — these are sanity checks per the project memory `zig-build-catches-lazy-analysis-errors-test-misses.md`.)

### Step 5.5: Manual smoke test on port 8080

```bash
./zig-out/bin/nalar --port 8080 &
# Wait ~3s for startup, then:
curl -s http://127.0.0.1:8080/api/health | head -n 5

# Create some local memories for testing (replace <path> with a real workspace item path):
mkdir -p /tmp/test-proj/.nalar/memories
echo '# My Rule' > /tmp/test-proj/.nalar/memories/rule-1.md
echo '# Another' > /tmp/test-proj/.nalar/memories/rule-2.md
echo "1. Be terse" >> /tmp/test-proj/.nalar/memories/rule-1.md
```

Open `http://127.0.0.1:8080/`, click a workspace item with path `/tmp/test-proj`, verify:
- The memories view shows two entries: "My Rule" and "Another".
- Click "My Rule" → detail shows `# My Rule\n\n1. Be terse`.
- Click "+ New Memory" → create a third entry → it appears in the list.

### Step 5.6: Final commit

```bash
git add src/apps/desktop/src/__tests__/WorkspaceItemMemoriesView.spec.ts
git commit -m "test(memories): add delete + edit coverage for WorkspaceItemMemoriesView"
```

---

## Verification

1. `cd src/apps/desktop && timeout 120 bun run build` — clean (vue-tsc strict, catches type errors vitest misses).
2. `cd src/apps/desktop && timeout 120 bunx vitest run` — all tests pass.
3. `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all` — baseline + new tests pass (backend unchanged).
4. `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && rm -rf zig-out/bin && timeout 300 zig build` — clean compile.
5. Manual smoke on port 8080:
   - Folder/chat/memory item with a path → memories view replaces the centered card.
   - Item without a path → today's centered card renders unchanged (no regression).
   - Kanban item → click ⚙ Settings → switch to "🧠 Local Memories" tab → memories render.
   - Create / edit / delete / refresh all work end-to-end.

## Pitfalls

- **`@cImport`-style cross-module side effects** — none. All API methods are already there.
- **`bun run build` vs `bunx vitest run`** — only `bun run build` does vue-tsc. Always run both per `frontend-typescript-bun-build-as-typecheck.md`. The new test file uses strict `Memory[]` typing — if you accidentally type it as `any[]`, `bunx vitest run` won't catch it but `bun run build` will.
- **`fetchFolderContents` race** — clicking a folder workspace item triggers `fetchFolderContents` in `Sidebar.vue:347-349`. The new memories view's `cwd` watcher fires concurrently. No conflict (they hit different endpoints), but if the folder fetch fails, the user may see the memories view with the wrong (loading) cwd. Mitigated by the explicit `:key="activeWorkspaceItem.id"` on `WorkspaceItemMemoriesView` — switching items remounts.
- **Empty cwd hidden state** — when path is `""`, the view renders the "No path is set" message. The component still calls `loadList` in the watcher (which is a no-op when `hasCwd` is false). No backend call is made.
- **Tab strip styling** — the active-tab styling uses an inline `:style` because the existing theme doesn't have semantic-tab-* tokens. Future refactor: add `--semantic-tab-bg` / `--semantic-tab-active-text` to `style.css` and replace inline styles.
- **`initialMode` prop** — defaulted to `'columns'`. If a future caller wants to open directly to the memories tab, they pass `:initial-mode="'memories'"`. AppLayout doesn't need this in v1.
- **`WorkspaceItem` literal typing** — `path?: string | null` is optional. The view handles `null`, `undefined`, and `""` as "no cwd". Tests must cover all three (the existing `MemoryList.spec.ts` precedent asserts `path` as `null` in fixtures).
- **`MemoryList.spec.ts` precedent** — the new tests should mirror its `beforeEach` setup (`setActivePinia(createPinia())`) and mock-fetch helpers (see memory `apiFetch-mock-must-include-text-and-pinia.md`).
- **`std.process.spawn` and FD leaks** — N/A (frontend only).

## Out of scope (deferred to follow-up if needed)

- Editing the workspace item's `path` from the UI (separate "edit workspace item" feature).
- A "global + local memory" diff view per item.
- A direct file-system watcher for live refresh (no chokidar dependency).
- Per-item memory quotas / sizes.
- Real-time multi-user sync (already not a project-wide concern).
- Refactoring `MemoryDetail.vue` to share with `LocalMemoryDetailView.vue` via a `cwd?: string` prop. Out of scope for v1 (would touch `MemoriesSettings.vue` and `AddMemoryDialog.vue`).