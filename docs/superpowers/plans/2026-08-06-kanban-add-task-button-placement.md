# Kanban — Move "+ Add task" to a proper place (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the per-column footer "+ Add task" button to a single header button in the kanban view, and replace the read-only column label in the create dialog with an interactive dropdown so the user can pick the target column inside the dialog (matches the profile picker pattern).

**Architecture:** Three surgical changes — (1) `KanbanTaskDetailDialog.vue` gets a new `availableColumns` prop + a column dropdown picker + a `column-change` emit (create-mode only). (2) `KanbanView.vue` gets a new `+ Add task` button in the header (next to the search input) that opens the create dialog with the first column pre-selected; the existing `activeCreateColumnId` ref is wired to the new `column-change` emit. (3) `KanbanColumn.vue` loses its footer "+ Add" button (handler + emit + template). Zero backend changes.

**Tech Stack:** Vue 3 + TypeScript (`<script setup lang="ts">`), Pinia, vue-test-utils + Vitest, vue-tsc strict mode.

**Spec:** `docs/superpowers/specs/2026-08-06-kanban-add-task-button-placement-design.md`
**Worktree:** `~/.worktrees/kanban-add-button-placement` (branch: `worktree/kanban-add-button-placement`)

## Global Constraints

- Working directory for ALL commands: `cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-add-button-placement`
- **NEVER use port 8081** — use port 8080 for local smoke.
- All Vue tests must use **behavioural** assertions (mount + DOM/emit reads). No `@embedFile + indexOf` static-contract tests.
- TypeScript strict mode is enabled — `vue-tsc --build` MUST stay green.
- Each task ends with a commit. Use `git commit -m "..."` matching the existing commit-message style (`feat(kanban):`, `refactor(kanban):`, `docs(kanban):`).
- Frontend build smoke after each task: `timeout 60 bun run build 2>&1 | tail -n 10`.
- Frontend test smoke after each task: `timeout 60 bunx vitest run <file> 2>&1 | tail -n 20`.

---

## Task 1 — Add column dropdown to `KanbanTaskDetailDialog.vue` (create mode only)

**Files:** `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue`, `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.spec.ts`

### 1.1 Read the existing test file to understand the test helper

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-add-button-placement
timeout 5 ls src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.spec.ts 2>&1 | head -n 5
```

- [ ] File exists. If not, surface immediately — the spec assumes an existing test file.
- [ ] Read the first 80 lines (the imports + the `mountDialog` helper + the `describe` layout).

### 1.2 Write failing tests for the column dropdown

In `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.spec.ts`, ADD a new `describe('KanbanTaskDetailDialog — column dropdown (create mode)', ...)` block at the end of the file (before the last `});`):

```ts
describe('KanbanTaskDetailDialog — column dropdown (create mode)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document
      .querySelectorAll('[data-testid="kanban-task-detail-dialog"]')
      .forEach((el) => el.remove())
    vi.restoreAllMocks()
  })

  // Helper: mount the dialog in create mode with the given columns.
  function mountCreateDialog(
    columns: { id: string; name: string }[],
    initialColumnId: string | null = columns[0]?.id ?? null,
  ) {
    const fullColumns = columns.map((c) => ({
      id: c.id,
      name: c.name,
      workspace_item_id: 'item_1',
      position: 0,
      created_at: '2026-06-21 12:00:00',
    }))
    const initialColumn = initialColumnId
      ? fullColumns.find((c) => c.id === initialColumnId) ?? null
      : null
    return mount(KanbanTaskDetailDialog, {
      props: {
        show: true,
        mode: 'create',
        task: null,
        column: initialColumn,
        availableColumns: fullColumns,
        workspaceId: 'ws_1',
      },
    })
  }

  it('create mode: column is rendered as a dropdown button (not a static text)', async () => {
    wrapper = mountCreateDialog([{ id: 'col_x', name: 'todo' }])
    await flushPromises()
    expect(
      wrapper.find('[data-testid="kanban-task-detail-column-picker"]').exists(),
    ).toBe(true)
    // The static strip should NOT render in create mode (the dropdown
    // replaces it).
    expect(
      document.querySelector('[data-testid="kanban-task-detail-column"]'),
    ).toBeNull()
  })

  it('create mode: column dropdown defaults to the column prop', async () => {
    wrapper = mountCreateDialog([
      { id: 'col_x', name: 'todo' },
      { id: 'col_y', name: 'in progress' },
    ])
    await flushPromises()
    const trigger = wrapper.find(
      '[data-testid="kanban-task-detail-column-picker"]',
    )
    expect(trigger.text()).toContain('todo')
  })

  it('create mode: opening the dropdown and picking a column emits column-change', async () => {
    wrapper = mountCreateDialog([
      { id: 'col_x', name: 'todo' },
      { id: 'col_y', name: 'in progress' },
    ])
    await flushPromises()

    // Open the dropdown.
    await wrapper
      .find('[data-testid="kanban-task-detail-column-picker"]')
      .trigger('click')
    await flushPromises()

    // Pick the second column.
    await wrapper
      .find('[data-testid="kanban-task-detail-column-picker-item-col_y"]')
      .trigger('click')
    await flushPromises()

    expect(wrapper.emitted('column-change')).toBeTruthy()
    expect(wrapper.emitted('column-change')?.[0]).toEqual(['col_y'])
  })

  it('create mode: single-column kanban — dropdown renders with the single item + checkmark', async () => {
    wrapper = mountCreateDialog([{ id: 'col_x', name: 'todo' }])
    await flushPromises()
    await wrapper
      .find('[data-testid="kanban-task-detail-column-picker"]')
      .trigger('click')
    await flushPromises()
    const item = wrapper.find(
      '[data-testid="kanban-task-detail-column-picker-item-col_x"]',
    )
    expect(item.exists()).toBe(true)
    expect(item.text()).toContain('✓')
  })

  it('edit mode: column is rendered as a static text strip (no dropdown)', async () => {
    // Edit mode: pass a task + column, no availableColumns.
    wrapper = mount(KanbanTaskDetailDialog, {
      props: {
        show: true,
        mode: 'edit',
        task: {
          id: 'task_1',
          name: 'existing task',
          description: '',
          kanban_column_id: 'col_x',
        },
        column: {
          id: 'col_x',
          name: 'todo',
          workspace_item_id: 'item_1',
          position: 0,
          created_at: '2026-06-21 12:00:00',
        },
        availableColumns: [],  // edit mode ignores availableColumns
      },
    })
    await flushPromises()
    // Static strip renders.
    expect(
      document.querySelector('[data-testid="kanban-task-detail-column"]'),
    ).not.toBeNull()
    // Dropdown does NOT render.
    expect(
      wrapper.find('[data-testid="kanban-task-detail-column-picker"]').exists(),
    ).toBe(false)
  })

  it('create mode: click outside the dropdown closes it', async () => {
    wrapper = mountCreateDialog([
      { id: 'col_x', name: 'todo' },
      { id: 'col_y', name: 'in progress' },
    ])
    await flushPromises()
    await wrapper
      .find('[data-testid="kanban-task-detail-column-picker"]')
      .trigger('click')
    await flushPromises()
    expect(
      wrapper.find('[data-testid="kanban-task-detail-column-picker-dropdown"]').exists(),
    ).toBe(true)
    // Dispatch a click on document.body (outside the picker).
    document.body.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushPromises()
    expect(
      wrapper.find('[data-testid="kanban-task-detail-column-picker-dropdown"]').exists(),
    ).toBe(false)
  })
})
```

- [ ] **Write the test block** (paste the `describe` above into the file, carefully matching the existing test-file imports).
- [ ] **Run the new tests** — they MUST fail (RED). Both `data-testid="kanban-task-detail-column-picker"` and the emit don't exist yet:
  ```bash
  cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-add-button-placement
  timeout 90 bunx vitest run src/__tests__/KanbanTaskDetailDialog.spec.ts 2>&1 | tail -n 30
  ```
  Confirm: 6 tests added, 6 failing (or matches the "all new ones fail" pattern). If you see compile errors, the test file is missing imports — fix the imports first.

### 1.3 Implement the dropdown (GREEN)

Edit `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue`:

- [ ] **Add the prop** to `defineProps` (after `workspaceId` on line 97):
  ```ts
  availableColumns?: KanbanColumn[]  // create-mode only: dropdown source
  ```
  And add `availableColumns: []` to the defaults object.

- [ ] **Add the emit** to `defineEmits` (after the existing emit-closing `}>` at line 203):
  ```ts
  'column-change': [columnId: string]
  ```

- [ ] **Add the local state** (after the existing `selectedProfile` block, around line 247):
  ```ts
  // Column dropdown (create mode only). selectedColumnId mirrors the
  // parent's `column` prop; the picker emits column-change so the host
  // updates its activeCreateColumnId in real-time.
  const selectedColumnId = ref<string | null>(props.column?.id ?? null)
  const isColumnPickerOpen = ref(false)
  const columnPickerRef = ref<HTMLElement | null>(null)
  const toggleColumnPicker = () => {
    isColumnPickerOpen.value = !isColumnPickerOpen.value
  }
  const selectColumn = (id: string) => {
    selectedColumnId.value = id
    isColumnPickerOpen.value = false
    emit('column-change', id)
  }
  // Click outside the picker closes it (mirrors the profile picker).
  const handleDocumentClickColumn = (event: MouseEvent) => {
    if (!isColumnPickerOpen.value) return
    const target = event.target as Node | null
    if (columnPickerRef.value && target && !columnPickerRef.value.contains(target)) {
      isColumnPickerOpen.value = false
    }
  }
  ```

- [ ] **Add the `onMounted`/`onUnmounted` listeners** — find the existing `onMounted(() => { document.addEventListener('click', handleDocumentClick) ... })` block (around line 433) and add the column listener alongside it:
  ```ts
  onMounted(() => {
    document.addEventListener('click', handleDocumentClick)
    document.addEventListener('keydown', handleSortModalKeyDown)
    document.addEventListener('click', handleDocumentClickColumn)
  })
  onUnmounted(() => {
    document.removeEventListener('click', handleDocumentClick)
    document.removeEventListener('keydown', handleSortModalKeyDown)
    document.removeEventListener('click', handleDocumentClickColumn)
  })
  ```

- [ ] **Add the `[show, column?.id]` watcher** — append after the existing `watch(() => [props.show, props.task?.id, props.mode], ...)` block (around line 329):
  ```ts
  // Re-sync the dropdown's selected column when the parent passes a
  // new `column` prop on dialog open (or when the parent flips
  // activeCreateColumnId externally). Only in create mode.
  watch(
    () => [props.show, props.column?.id] as const,
    ([show, columnId]) => {
      if (show && isCreateMode.value) {
        selectedColumnId.value = columnId ?? null
      }
    },
  )
  ```

- [ ] **Replace the read-only column strip** (lines 699–707) with the dropdown. Open the file and find:
  ```html
  <span v-if="columnLabel" data-testid="kanban-task-detail-column">
    {{ columnLabel }}
  </span>
  ```
  Replace with:
  ```html
  <!-- Column dropdown (create mode only). Edit mode falls through to
       the static read-only strip below. -->
  <div
    v-if="isCreateMode && props.availableColumns.length > 0"
    ref="columnPickerRef"
    class="relative"
  >
    <button
      type="button"
      @click.stop="toggleColumnPicker"
      class="px-2 py-0.5 rounded text-xs hover:opacity-80 inline-flex items-center gap-1"
      style="
        background-color: var(--semantic-sidebar-bg);
        border: 1px solid var(--color-border);
        color: var(--semantic-text);
      "
      data-testid="kanban-task-detail-column-picker"
    >
      <span>{{ columnLabel }}</span>
      <span class="text-[10px]">▾</span>
    </button>
    <div
      v-if="isColumnPickerOpen"
      class="absolute top-full mt-1 left-0 min-w-[180px] rounded-lg shadow-lg z-20 overflow-hidden"
      style="
        background-color: var(--semantic-card-bg);
        border: 1px solid var(--color-border);
      "
      data-testid="kanban-task-detail-column-picker-dropdown"
      @click.stop
    >
      <button
        v-for="col in props.availableColumns"
        :key="col.id"
        type="button"
        @click="selectColumn(col.id)"
        class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center justify-between"
        style="color: var(--semantic-text); border-top: 1px solid var(--color-border);"
        :data-testid="`kanban-task-detail-column-picker-item-${col.id}`"
      >
        <span class="font-medium">{{ col.name }}</span>
        <span v-if="selectedColumnId === col.id">✓</span>
      </button>
    </div>
  </div>
  <!-- Edit mode: read-only strip (unchanged). -->
  <span
    v-else-if="columnLabel"
    data-testid="kanban-task-detail-column"
  >
    {{ columnLabel }}
  </span>
  ```

### 1.4 Run the tests — they MUST pass (GREEN)

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-add-button-placement
timeout 90 bunx vitest run src/__tests__/KanbanTaskDetailDialog.spec.ts 2>&1 | tail -n 30
```

- [ ] All 6 new tests pass. If any fail, fix the implementation (check the testid names, the prop name, the click-outside listener).

### 1.5 Type-check + commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-add-button-placement
timeout 60 bun run build 2>&1 | tail -n 10
```

- [ ] `vue-tsc` passes.
- [ ] **Commit**:
  ```bash
  git add src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.spec.ts
  git commit -m "feat(dialog): column dropdown in create mode (kanban add task)
  
  Replaces the read-only column label with an interactive dropdown in
  create mode. Mirrors the profile picker pattern (button trigger + ▾
  dropdown with ✓ checkmark + click-outside close). Pick emits
  column-change so the host can update activeCreateColumnId in real
  time. Edit mode keeps the read-only strip (the task is already in
  a column).
  
  Tests: 6 new behavioural tests (dropdown renders, defaults to column
  prop, pick emits column-change, single-column shows ✓, edit mode
  keeps static strip, click-outside closes the dropdown)."
  ```

---

## Task 2 — Add header "+ Add task" button in `KanbanView.vue` + wire `column-change`

**Files:** `src/apps/desktop/src/components/kanban/KanbanView.vue`, `src/apps/desktop/src/__tests__/KanbanView.spec.ts`

### 2.1 Read the existing test file header to understand the helper

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-add-button-placement
timeout 5 rg -n "function mountView|mountView =" src/apps/desktop/src/__tests__/KanbanView.spec.ts | head -n 5
```

- [ ] Read the `mountView` helper to understand the fixture shape (the tests will use it).

### 2.2 Write failing tests for the header button

In `src/apps/desktop/src/__tests__/KanbanView.spec.ts`, ADD a new `describe('KanbanView — header + Add task button', ...)` block at the end of the file (before the final `});`):

```ts
describe('KanbanView — header + Add task button', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document
      .querySelectorAll('[data-testid="kanban-task-detail-dialog"]')
      .forEach((el) => el.remove())
    vi.restoreAllMocks()
  })

  it('renders the header + Add task button', async () => {
    const item = makeItem({
      kanban_columns: [
        makeColumn({ id: 'col_x', name: 'todo', position: 0 }),
      ],
    })
    wrapper = mountView(item)
    await flushPromises()
    expect(
      wrapper.find('[data-testid="kanban-add-task-button"]').exists(),
    ).toBe(true)
  })

  it('disables the header button when there are no columns', async () => {
    const item = makeItem({ kanban_columns: [] })
    wrapper = mountView(item)
    await flushPromises()
    const btn = wrapper.find('[data-testid="kanban-add-task-button"]')
    expect(btn.exists()).toBe(true)
    expect(btn.attributes('disabled')).toBeDefined()
    // Helpful tooltip explains the disabled state.
    expect(btn.attributes('title')).toContain('Add columns first')
  })

  it('enables the header button when at least one column exists', async () => {
    const item = makeItem({
      kanban_columns: [
        makeColumn({ id: 'col_x', name: 'todo', position: 0 }),
      ],
    })
    wrapper = mountView(item)
    await flushPromises()
    const btn = wrapper.find('[data-testid="kanban-add-task-button"]')
    expect(btn.attributes('disabled')).toBeUndefined()
  })

  it('clicking the header button opens the create dialog with the first column pre-selected', async () => {
    const item = makeItem({
      kanban_columns: [
        makeColumn({ id: 'col_x', name: 'todo', position: 0 }),
        makeColumn({ id: 'col_y', name: 'in progress', position: 1 }),
      ],
    })
    wrapper = mountView(item)
    await flushPromises()
    await wrapper.find('[data-testid="kanban-add-task-button"]').trigger('click')
    await flushPromises()
    // The dialog renders, focused on the name input.
    expect(
      document.querySelector('[data-testid="kanban-task-detail-dialog"]'),
    ).not.toBeNull()
    // The dropdown defaults to the first column.
    const picker = document.querySelector(
      '[data-testid="kanban-task-detail-column-picker"]',
    )
    expect(picker?.textContent).toContain('todo')
  })

  it('column-change in the dialog updates the active create column (so moveTaskToColumn uses the chosen column at submit)', async () => {
    const item = makeItem({
      kanban_columns: [
        makeColumn({ id: 'col_x', name: 'todo', position: 0 }),
        makeColumn({ id: 'col_y', name: 'in progress', position: 1 }),
      ],
    })
    wrapper = mountView(item)
    await flushPromises()
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    vi.spyOn(store, 'addTask').mockResolvedValue('task_new_1')
    const moveTaskSpy = vi
      .spyOn(store, 'moveTaskToColumn')
      .mockResolvedValue(undefined)

    // Open the dialog via the header button (defaults to col_x).
    await wrapper.find('[data-testid="kanban-add-task-button"]').trigger('click')
    await flushPromises()

    // Switch to col_y via the dropdown.
    document
      .querySelector<HTMLButtonElement>(
        '[data-testid="kanban-task-detail-column-picker-item-col_y"]',
      )!
      .click()
    await flushPromises()

    // Fill the name and submit.
    const nameInput = document.querySelector<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-name"]',
    )
    nameInput!.value = 'My new task'
    nameInput!.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    document
      .querySelector<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')!
      .click()
    await flushPromises()
    await flushPromises()  // await the handleCreateTaskSave await chain

    expect(moveTaskSpy).toHaveBeenCalledWith(
      WS_ID,
      ITEM_ID,
      'task_new_1',
      'col_y',  // not col_x — the column-change flow worked
      0,
    )
  })
})
```

- [ ] **Run the new tests** — they MUST fail (RED). The `kanban-add-task-button` testid doesn't exist yet:
  ```bash
  cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-add-button-placement
  timeout 90 bunx vitest run src/__tests__/KanbanView.spec.ts 2>&1 | tail -n 30
  ```
  Confirm: 5 tests added, 5 failing.

### 2.3 Implement the header button + wire the column-change

Edit `src/apps/desktop/src/components/kanban/KanbanView.vue`:

- [ ] **Pass `:available-columns` to the create-mode dialog mount** (around line 1171, the second `<KanbanTaskDetailDialog v-model:show="showCreateDialog" ...>` block). Find:
  ```html
  <KanbanTaskDetailDialog
    v-model:show="showCreateDialog"
    mode="create"
    :task="null"
    :column="activeCreateColumn"
    :cwd="item.path || ''"
    :workspace-id="workspaceId"
    :error-message="createError"
    @create="(payload) => handleCreateTaskSave({ ...payload, mode: 'create' })"
    @create-and-run="(payload) => handleCreateTaskSave({ ...payload, mode: 'create_and_run' })"
  />
  ```
  Replace with:
  ```html
  <KanbanTaskDetailDialog
    v-model:show="showCreateDialog"
    mode="create"
    :task="null"
    :column="activeCreateColumn"
    :available-columns="sortedColumns"
    :cwd="item.path || ''"
    :workspace-id="workspaceId"
    :error-message="createError"
    @create="(payload) => handleCreateTaskSave({ ...payload, mode: 'create' })"
    @create-and-run="(payload) => handleCreateTaskSave({ ...payload, mode: 'create_and_run' })"
    @column-change="(columnId) => activeCreateColumnId = columnId"
  />
  ```

- [ ] **Add the header button** in the header block (around line 1045, between the `<KanbanSearchInput>` and the Settings button). Find:
  ```html
  <KanbanSearchInput v-model="searchQuery" />
  
  <button
    type="button"
    class="px-2 py-1 rounded text-xs font-medium hover:opacity-80 transition-opacity"
    style="
      background-color: var(--semantic-sidebar-bg);
      border: 1px solid var(--color-border);
      color: var(--semantic-text-muted);
    "
    :data-testid="`kanban-view-${item.id}-open-settings`"
    @click="handleOpenSettings"
    title="Open board settings (add columns, edit descriptions)"
  >
    <span aria-hidden="true">⚙️</span>
    <span class="ml-1">Settings</span>
  </button>
  ```
  Insert the `+ Add task` button BETWEEN the `<KanbanSearchInput>` and the Settings button:
  ```html
  <KanbanSearchInput v-model="searchQuery" />
  
  <!-- NEW: one global + Add task button (replaces per-column footer
       add buttons — spec: 2026-08-06-kanban-add-task-button-placement).
       Opens the create dialog with the first column pre-selected.
       The dialog itself has a column dropdown for the user to pick a
       different column. Button is disabled when the kanban has zero
       columns. The `title` attribute explains the disabled state. -->
  <button
    type="button"
    class="px-2 py-1 rounded text-xs font-medium hover:opacity-80 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed"
    style="
      background-color: var(--semantic-sidebar-bg);
      border: 1px solid var(--color-border);
      color: var(--semantic-text-muted);
    "
    :data-testid="`kanban-add-task-button`"
    :disabled="sortedColumns.length === 0"
    :title="sortedColumns.length ? 'Add a task to this kanban' : 'Add columns first in Settings'"
    @click="handleOpenCreateDialog"
  >
    <span aria-hidden="true">➕</span>
    <span class="ml-1">Add task</span>
  </button>
  
  <button
    type="button"
    ...
  ```

- [ ] **Add the `handleOpenCreateDialog` method** — find the existing `handleOpenSettings` (around line 574) and add right after it:
  ```ts
  // NEW: open the create dialog with the first column pre-selected.
  // The header button does NOT preserve the previously-picked column —
  // every fresh open starts at the leftmost column. Matches the
  // "Add task" mental model (form opens in its default state).
  const handleOpenCreateDialog = () => {
    const firstColumn = sortedColumns.value[0]
    if (!firstColumn) return  // disabled button covers this, defensive
    handleViewCreateTask(firstColumn.id)
  }
  ```

### 2.4 Run the tests — they MUST pass (GREEN)

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-add-button-placement
timeout 90 bunx vitest run src/__tests__/KanbanView.spec.ts 2>&1 | tail -n 30
```

- [ ] All 5 new tests pass.
- [ ] **The existing `KanbanView — create-task flow` tests should still fail** (they use the old `kanban-column-col_x-add-task` testid). That's expected — Task 3 fixes them.

### 2.5 Type-check + commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-add-button-placement
timeout 60 bun run build 2>&1 | tail -n 10
```

- [ ] `vue-tsc` passes.
- [ ] **Commit**:
  ```bash
  git add src/apps/desktop/src/components/kanban/KanbanView.vue src/apps/desktop/src/__tests__/KanbanView.spec.ts
  git commit -m "feat(kanban): header + Add task button with column dropdown
  
  Replaces the per-column footer + Add buttons with a single header
  button next to the search input. The button opens the create dialog
  with the first column pre-selected; the dialog's new column
  dropdown (Task 1) lets the user pick a different column. The
  column-change emit keeps activeCreateColumnId in sync so the
  final moveTaskToColumn places the task in the chosen column.
  
  Disabled state when kanban has zero columns (title 'Add columns
  first in Settings' explains the disabled state).
  
  Tests: 5 new behavioural tests (renders, disabled when no columns,
  enabled when 1+ columns, opens dialog with first column,
  column-change updates moveTaskToColumn target)."
  ```

---

## Task 3 — Remove per-column footer "+ Add" button from `KanbanColumn.vue` + update tests

**Files:** `src/apps/desktop/src/components/kanban/KanbanColumn.vue`, `src/apps/desktop/src/__tests__/KanbanColumn.spec.ts`, `src/apps/desktop/src/__tests__/KanbanView.spec.ts`

### 3.1 Delete the footer from `KanbanColumn.vue`

- [ ] **Open the file** and delete the `<footer>` block (lines 830–849):
  ```html
  <!-- ─── Footer "+ Add" button ────────────────────────────────────── -->
  <footer
    class="px-3 py-2 shrink-0"
    style="border-top: 1px solid var(--color-border);"
  >
    <button
      type="button"
      class="w-full flex items-center justify-center gap-1 px-2 py-1.5 rounded text-xs font-medium hover:opacity-80 transition-opacity"
      ...
      :data-testid="`kanban-column-${column.id}-add-task`"
      @click="handleAddClick"
    >
      <span aria-hidden="true">+</span>
      <span>Add</span>
    </button>
  </footer>
  ```
  Delete the entire `<footer>...</footer>` block.

- [ ] **Delete `handleAddClick`** (lines 569–573):
  ```ts
  // ─── Footer add ────────────────────────────────────────────────────────────
  
  const handleAddClick = () => {
    emit('addTask', props.column.id)
  }
  ```
  Delete the comment + the function.

- [ ] **Delete the `addTask` emit** (line 69). Find:
  ```ts
  const emit = defineEmits<{
    addTask: [columnId: string]
    moveTask: [{ taskId: string; columnId: string; position: number }]
    ...
  ```
  Remove the `addTask: [columnId: string]` line.

- [ ] **Update the docstring header comment** (lines 21, 34–35). Find:
  ```
  3. Footer  — "+ Add" button → emits `add-task` with the column id.
  ```
  Delete that line. Also find:
  ```
  emits:
    add-task           [columnId: string]
  ```
  Delete that line.

- [ ] **Remove the `@add-task` listener in `KanbanView.vue`** (line 1109). Find:
  ```ts
  @add-task="handleViewCreateTask"
  ```
  Delete that line. Verify `KanbanView.vue` still compiles (no other `@add-task` references).

### 3.2 Delete the now-orphan test in `KanbanColumn.spec.ts`

- [ ] **Delete the entire `describe('KanbanColumn — footer add', ...)` block** (lines 231–249):
  ```ts
  describe('KanbanColumn — footer add', () => {
    let wrapper: VueWrapper | null = null
    beforeEach(() => {
      setActivePinia(createPinia())
    })
    afterEach(() => {
      wrapper?.unmount()
      wrapper = null
      vi.restoreAllMocks()
    })
    it('clicking "+ Add" emits add-task with the column id', async () => {
      wrapper = mountColumn(makeColumn())
      await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-add-task"]`).trigger('click')
      expect(wrapper.emitted('addTask')?.[0]).toEqual([COL_TODO])
    })
  })
  ```

### 3.3 Update the existing `KanbanView — create-task flow` tests

The existing test in `KanbanView.spec.ts` (lines 598–onward) has a `mountAndOpenDialog` helper that uses the OLD `kanban-column-col_x-add-task` testid. Update it to use the new header button.

- [ ] **Find `mountAndOpenDialog`** (around line 630). Update the trigger:
  ```ts
  // BEFORE
  await wrapper
    .find('[data-testid="kanban-column-col_x-add-task"]')
    .trigger('click')
  
  // AFTER
  await wrapper
    .find('[data-testid="kanban-add-task-button"]')
    .trigger('click')
  ```

- [ ] **Run the file's tests** — all pass:
  ```bash
  cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-add-button-placement
  timeout 90 bunx vitest run src/__tests__/KanbanView.spec.ts src/__tests__/KanbanColumn.spec.ts 2>&1 | tail -n 30
  ```
  Confirm: 5 (new) + 5 (existing migrated) + ~(remaining) all pass. No references to the deleted testid.

### 3.4 Type-check + commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-add-button-placement
timeout 60 bun run build 2>&1 | tail -n 10
```

- [ ] `vue-tsc` passes.
- [ ] **Commit**:
  ```bash
  git add src/apps/desktop/src/components/kanban/KanbanColumn.vue src/apps/desktop/src/components/kanban/KanbanView.vue src/apps/desktop/src/__tests__/KanbanColumn.spec.ts src/apps/desktop/src/__tests__/KanbanView.spec.ts
  git commit -m "refactor(kanban): remove per-column footer + Add button
  
  One global header button (Task 2) replaces per-column footer add
  buttons. The empty-state 'No tasks yet' placeholder is kept as-is.
  
  Cleanup:
  - Delete <footer> block in KanbanColumn.vue
  - Delete handleAddClick + addTask emit
  - Delete orphan 'KanbanColumn — footer add' describe block
  - Update existing KanbanView create-task flow tests to drive the
    header button (testid: kanban-add-task-button)"
  ```

---

## Task 4 — Final verification + cross-platform smoke + AGENTS.md changelog

### 4.1 Full test suite

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-add-button-placement
timeout 240 bunx vitest run 2>&1 | tail -n 20
```

- [ ] Compare the test count to the pre-change baseline of `2100 pass / 19 fail` (the 19 pre-existing failures per `AGENTS.md`).
- [ ] Expected: ~2111 pass / 19 fail (added 11 new tests: 6 dialog + 5 view). The 19 pre-existing failures are unchanged.
- [ ] If any NEW test fails, fix the failing test or fix the implementation. **Do NOT commit if the test count is worse than the pre-change baseline.**

### 4.2 Build + type-check

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-add-button-placement
timeout 180 bun run build 2>&1 | tail -n 20
```

- [ ] `vue-tsc --build` passes. No TypeScript errors.

### 4.3 Backend smoke (no backend changes, but verify nothing broke)

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-add-button-placement
timeout 180 zig build test --summary all 2>&1 | tail -n 10
```

- [ ] Same 2181 pass / 6 skip / 2 leaks as the pre-change baseline.

### 4.4 Live smoke (manual)

- [ ] **Start the dev server** (use port 8080, NEVER 8081):
  ```bash
  cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-add-button-placement
  timeout 60 bun run dev 2>&1 | tail -n 20 &  # background
  ```
  Wait for it to be ready (look for "Local: http://localhost:5173" or similar).
- [ ] **Open `http://localhost:5173`** in a browser. Navigate to a kanban with at least 2 columns.
- [ ] **Verify visually**:
  - The header (next to search) has a `➕ Add task` button.
  - No `+ Add` buttons in the column footers.
  - Click the header button → dialog opens with a column dropdown showing the first column.
  - Click the dropdown → list of columns appears + `✓` on the active one.
  - Pick a different column → the dropdown button now shows the new column.
  - Fill the name + click `Create task` → the new task appears in the column you picked.
- [ ] **Kill the dev server** when done.

### 4.5 Update AGENTS.md changelog

- [ ] **Find the recent changes section** in `/home/ginwa/ginwaaitoolbox/.worktrees/kanban-add-button-placement/AGENTS.md` — search for the most recent `### ` block.
- [ ] **Append a new block** at the top of the appended-only changelog (above the most recent entry):
  ```markdown
  ### 2026-08-06: Kanban "+ Add task" — single header button + dropdown column picker

  **Symptom (user report, task_1785865184856).** Every kanban column had a `+ Add` button in its footer (7 columns = 7 buttons). User wanted one global button + dropdown column selection.

  **What landed (3 commits, branch `worktree/kanban-add-button-placement`).**

  - **KanbanColumn.vue** — REMOVED the per-column footer `+ Add` button (handler + emit + template block + docstring). The `No tasks yet` empty-state placeholder is kept.
  - **KanbanView.vue** — ADDED a single `➕ Add task` button in the header (between search input and Settings button). Disabled when the kanban has zero columns (title `Add columns first in Settings`). Click opens the create dialog with the first column pre-selected.
  - **KanbanTaskDetailDialog.vue** — REPLACED the read-only column label in create mode with an interactive dropdown (mirrors the profile picker pattern: button trigger + ▾ dropdown with ✓ checkmark + click-outside close). Pick emits `column-change` so the host updates `activeCreateColumnId` in real-time. Edit mode keeps the read-only strip (the task is already in a column).

  **Files (3 components + 3 tests, +448/-135).**

  - `src/apps/desktop/src/components/kanban/KanbanColumn.vue` — remove footer add
  - `src/apps/desktop/src/components/kanban/KanbanView.vue` — add header button + wire column-change
  - `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` — column dropdown + new prop + new emit
  - `src/apps/desktop/src/__tests__/KanbanColumn.spec.ts` — delete `KanbanColumn — footer add` describe block
  - `src/apps/desktop/src/__tests__/KanbanView.spec.ts` — update existing create-task tests + add 5 new tests
  - `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.spec.ts` — add 6 new column-dropdown tests

  **Tests.** 11 new behavioural tests (6 dialog + 5 view). 1 test deleted (footer add). Full suite: 2111 pass / 19 fail (the 19 are the documented pre-existing baseline).

  **Out of scope (deferred).**

  - In-column `+ Add` link when the column is empty (user said "only one button").
  - Keyboard shortcut (e.g. `c` or `n`) for the header button.
  - Drag-and-drop from outside the kanban into a specific column.

  **Branch / commit / PR.**

  - Branch: `worktree/kanban-add-task-button-placement`
  - Spec: `docs/superpowers/specs/2026-08-06-kanban-add-task-button-placement-design.md`
  - Plan: `docs/superpowers/plans/2026-08-06-kanban-add-task-button-placement.md`
  - PR: pending (squash-merge candidate)
  ```

### 4.6 Final commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-add-button-placement
git add AGENTS.md
git commit -m "docs(kanban): changelog entry for Add task button placement"
```

- [ ] Done. Optionally push the branch and open a PR.

---

## Verification (success criteria)

- [ ] All 4 tasks complete with their commits.
- [ ] `bunx vitest run` shows ~~2111 pass / 19 fail (matches the pre-change baseline / 19 pre-existing failures).
- [ ] `bun run build` is clean (vue-tsc passes).
- [ ] `zig build test --summary all` matches the pre-change baseline (no backend regressions).
- [ ] Live smoke on port 8080 passes (header button + dropdown + new task lands in chosen column).
- [ ] AGENTS.md changelog entry exists.
- [ ] Branch `worktree/kanban-add-button-placement` is ready for squash-merge OR a PR is open.
