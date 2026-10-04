# Plan — Kanban "Row mode" (linear grouped list)

**Task:** `task_1790399586263_2` — *"add a option to change view kanban into row mode ?"*
**Status:** planning only. No implementation in this PR.
**Wireframe:** [`preview-kanban-row-mode-wireframe.html`](../preview-kanban-row-mode-wireframe.html) (repo root)
**Scope:** frontend only — `src/apps/desktop/`. **No backend change, no new endpoint, no migration.**

---

## 1. Problem

The kanban board is a horizontal row of fixed-width (280 px) columns
(`KanbanView.vue:1368-1402` → `KanbanColumn.vue:615-621`). That is the right
shape for *moving* work between stages, but a bad shape for *reading* a board:

- Only ~4 columns fit on a 1440 px screen; the rest need horizontal scrolling.
- Each card is ~96 px tall (`KanbanColumn.vue:822-830`, `:default-item-height="100"`),
  so a 40-task board is a lot of scrolling for very little information.
- There is no way to see "all tasks, newest first" across the whole board —
  sorting is **per column** (`?sorts=col_X:field:dir`), so a board-wide
  chronological read is impossible today.
- On narrow windows (and the mobile shells) the horizontal board is unusable.

**Row mode** = the same data, rendered as a vertical list grouped by column:
a collapsible section header per column (name + count + ⋮ menu) with compact
32 px task rows underneath. It is a *reading* view; column mode stays the
*moving* view.

---

## 2. Goals / non-goals

### Goals
1. A toggle in the kanban header that switches the board body between
   **Columns** and **Rows**.
2. The choice is **URL-backed** (`?layout=rows`) so refresh, Back/Forward and
   shared links restore it — per the repo rule *"Every View Switch Must Update
   the Browser URL"* (`AGENTS.md:158-188`).
3. Row mode renders **every task the board already has loaded**, grouped by
   column, with per-group collapse.
4. Row mode reuses the existing task-row component and the existing
   `useTaskActions` event contract — no new task UI, no new store mutations.
5. Zero backend work.

### Non-goals (v1)
- **No drag-and-drop in row mode.** Column mode keeps DnD. Moving a task in row
  mode is done by opening the task detail panel and changing its column there
  (the panel already has a column picker). Rationale in §7.
- **No board-wide sort control.** Row mode inherits each column's existing
  `?sorts=` order. A board-wide sort is a follow-up (§10).
- **No virtualization in v1.** See §8 for the threshold at which it becomes
  necessary.
- **No per-column layout** (some columns as cards, some as rows). One toggle
  per board.
- **No new "add task per group" button.** The global `+ Add task` button in the
  header already covers it (`KanbanView.vue:1266-1283`).

---

## 3. Current anatomy (verified, with line numbers)

### 3.1 `KanbanView.vue` (1497 lines) — the only production mount

| Region | Lines | Notes |
|---|---|---|
| Wrapper `div.kanban-view-wrap` | 1189-1193 | `relative flex flex-row h-full min-h-0` — positioning context for the detail panel |
| `section.kanban-view` | 1194-1403 | `flex flex-col flex-1 min-w-0 h-full min-h-0` |
| **Header** | **1208-1327** | title (1212-1230) → `Set project root` (1240-1256) → `KanbanSearchInput` (1257) → `+ Add task` (1266-1283) → `⚙️ Settings` (1285-1301) → `🤖 Agent` (1307-1325) |
| Search "no matches" banner | 1332-1340 | `v-if="tasks.length === 0 && searchQuery.trim() !== ''"` |
| Run-all summary banner | 1348-1358 | `role="status" aria-live="polite"` |
| **Board body** | **1368-1402** | `div[ref=kanbanColumnsContainer]` `flex-1 min-h-0 overflow-x-auto overflow-y-hidden` → inner `div.flex.gap-3.p-3.h-full.items-stretch` → `v-for="column in sortedColumns"` `<KanbanColumn>` |
| Detail / create panel | 1416-1452 | `absolute inset-0 z-30`, sibling of `<section>` |
| `FilePickerDialog` | 1463-1474 | |
| `<style scoped>` | 1478-1496 | **scrollbar pseudo-elements only** — zero layout rules |

Key state:

| Name | Line | Persistence |
|---|---|---|
| `sortedColumns` | 359-361 | derived: `item.kanban_columns` sorted by `position` |
| `tasks` | 364 | derived: `item.tasks ?? []` (flat, all columns) |
| `searchQuery` | 379 | component-local, 300 ms debounce → `fetchKanbanTasksForAllColumns` (389-404) |
| `columnSorts` | 472 | **URL `?sorts=`** — watcher at 499-505 |
| `kanbanColumnsContainer` | 301 | **localStorage** `kanban-scroll-<itemId>` via `useKanbanScrollRestore` (303) |
| `activeTaskDetailId` / `showTaskDetail` | 658-659 | **URL `?detail=`** (push in at 690, replace out at 737) |
| `showCreateDialog` | 991 | not URL-backed (pre-existing asymmetry) |

### 3.2 The `?sorts=` watcher is a landmine

```ts
// KanbanView.vue:499-505
watch(columnSorts, (next) => {
  const encoded = encodeSortsParam(Object.values(next))
  const query: Record<string, string> = { view: 'workspace' }
  if (props.workspaceId) query.workspaceId = props.workspaceId
  if (effectiveItemId.value) query.itemId = effectiveItemId.value
  if (encoded) query.sorts = encoded
  router.replace({ path: '/app', query })
})
```

It **rebuilds the query from scratch** and therefore **drops `?detail=`** (and
would drop any new `?layout=`). Any new param must either be added to this
object or the watcher must be rewritten to use `flatQuery()` (710-725). The
plan picks the latter (§5.3).

### 3.3 `KanbanColumn.vue` (934 lines) — what is reusable

| Piece | Lines | Reusable in row mode? |
|---|---|---|
| Root `section.kanban-column` | 615-621 | ❌ `width: 280px` + `shrink-0` inside a horizontal flex row |
| Header (name / count / ⋮ menu) | 632-758 | ✅ **copy** — count badge 673-681, ⋮ menu 691-756 |
| Inline rename input | 648-662 | ✅ copy |
| Description subtitle | 766-774 | ✅ copy |
| Drop zone + DnD handlers | 790-802, 494-547 | ❌ not used in v1 (no DnD) |
| `VirtualScroller` | 821-830 | ❌ one scroller per column cannot become one scroller for a flat list |
| Empty placeholder | 855-864 | ✅ copy |
| Manual "Load more" | 869-891 | ✅ copy (per group) |
| Sort modal | 900-919 | ✅ copy |
| `cardsInColumn` filter | 185-188 | ✅ the grouping primitive |
| Per-column pagination | 216-230, 289 | ✅ read-only in row mode |

### 3.4 The row primitive already exists

`components/workspace/WorkspaceItemTaskRow.vue` (324 lines) is the sidebar's
compact task row:

- root is a real `<button>` with `min-h-[32px]`, `flex items-center gap-2 px-2 py-[7px]`
  (`WorkspaceItemTaskRow.vue:135-152`)
- props are the shared `TaskComponentProps` (`composables/useTaskActions.ts:33-54`):
  `task`, `workspaceId`, `itemId`, `dropIndicator?`, `cwd?`
- emits `selectTask`, `openTaskInBackground`, `deleteTask`, `renameTask`, `pinTask`
- renders: bullet / agent-error icon + tooltip / pin indicator / name / pin
  toggle / rename / delete / `SessionSlider` / `OpenInNewTabMenu`
- active-row highlight is **URL-driven** via `useCurrentMainView()`
  (`WorkspaceItemTaskRow.vue:60-66`) — already satisfies the repo's URL rule

**Gap vs. a kanban row:** it has no `viewTaskDetail` emit and no "open details"
button. `KanbanCard.vue` has that emit (`KanbanCard.vue:59-72`) and passes it
through. Row mode needs both, so the plan adds a thin wrapper (§5.2) rather
than modifying the shared sidebar row.

### 3.5 Data availability — nothing new is needed

| Need | Source | New API? |
|---|---|---|
| Group order | `sortedColumns` (`KanbanView.vue:359-361`) | no |
| Tasks per group | `tasks.filter(t => t.kanban_column_id === col.id)` (`KanbanColumn.vue:185-188`) | no |
| Group count | `.length` of the above | no |
| Per-task fields (name, tags, pin, git branch, agent error, media flags) | `Task` interface (`stores/workspaces.ts:119-225`) | no |
| Live updates | `kanbanSse.ts:125-214` mutates `item.tasks` in place / refetches | no |
| Search | server-side `q` (`api/index.ts:662-671`) | no |
| Per-column sort | server-side `sort_by`/`direction` (`api/index.ts:690-691`) | no |
| Per-column "load more" | `loadMoreTasksForColumn` (`stores/workspaces.ts:3585`) | no |

⚠️ **Counts are "loaded rows", not totals.** The wire has no `total_count`
(`http_response.zig:617` sets `count = tasks.len`). The existing column badge
already has this limitation (`KanbanColumn.vue:679`), so row mode inherits it
and must not claim otherwise. If a group has `hasMore`, the group header shows
`12+` and a "Load more" row.

---

## 4. UX design

### 4.1 The toggle

A two-button segmented control in the header, placed **between
`KanbanSearchInput` and `+ Add task`** (i.e. inserted at `KanbanView.vue:1258`).

Markup follows the repo's existing hand-rolled segmented control
(`components/tool_outputs/_shared/DiffView.vue:479-505`) — there is no shared
`SegmentedControl` component in this codebase, and three near-identical copies
already exist, so copying is the convention:

```html
<div
  class="inline-flex rounded overflow-hidden shrink-0"
  style="border: 1px solid var(--color-border)"
  role="tablist"
  aria-label="Kanban layout"
>
  <button
    type="button" role="tab"
    :aria-selected="layout === 'columns'"
    :data-testid="`kanban-view-${item.id}-layout-columns`"
    class="px-2 py-1 text-xs border-none cursor-pointer"
    :style="layout === 'columns'
      ? 'background: var(--color-violet); color: var(--color-bg);'
      : 'background: transparent; color: var(--semantic-text-muted);'"
    @click="setLayout('columns')"
  >
    <span aria-hidden="true">▦</span><span class="ml-1">Columns</span>
  </button>
  <button
    type="button" role="tab"
    :aria-selected="layout === 'rows'"
    :data-testid="`kanban-view-${item.id}-layout-rows`"
    class="px-2 py-1 text-xs border-none cursor-pointer"
    :style="layout === 'rows'
      ? 'background: var(--color-violet); color: var(--color-bg);'
      : 'background: transparent; color: var(--semantic-text-muted);'"
    @click="setLayout('rows')"
  >
    <span aria-hidden="true">☰</span><span class="ml-1">Rows</span>
  </button>
</div>
```

Glyphs are emoji/unicode in `<span aria-hidden="true">` — the dominant idiom in
`components/kanban/` (`➕` 1281, `⚙️` 1297, `🤖` 1319, `⇅` `KanbanSortMenu.vue:143`).
No icon library is installed.

### 4.2 Row mode layout

```
┌─ header (unchanged) ────────────────────────────────────────────────────┐
│ Sprint 42        [▦ Columns][☰ Rows]  🔍  ➕ Add task  ⚙️  🤖          │
├─────────────────────────────────────────────────────────────────────────┤
│ ▼  todo                                            12+   ⋮              │  ← group header
│   ─────────────────────────────────────────────────────────────────     │
│   • Fix login redirect on refresh          📌  ⚙  ✎  ✕                 │  ← 32px row
│   • Add retry to the SSE reconnect loop        ⚙  ✎  ✕                 │
│   • ⚠ Investigate flaky CI on windows          ⚙  ✎  ✕                 │
│   [ Load more ]                                                         │
│                                                                         │
│ ▶  in progress                                      4   ⋮              │  ← collapsed
│                                                                         │
│ ▼  done                                             31   ⋮              │
│   • Ship row mode                              📌  ⚙  ✎  ✕             │
│   …                                                                     │
└─────────────────────────────────────────────────────────────────────────┘
```

- **Group header** — chevron (rotates 90° when expanded, `WorkspaceItem.vue:616-630`),
  column name (click = inline rename, same as `KanbanColumn.vue:663-670`),
  count badge (`KanbanColumn.vue:673-681` verbatim), `⋮` menu
  (`KanbanColumn.vue:691-756` verbatim: Rename / Sort tasks… / Delete / Run all agents).
- **Rows** — `WorkspaceItemTaskRow` + a details button, 32 px each, indented
  under the group with a left rail (`ml-4 pl-2 border-l border-[--color-border]/30`,
  the repo's established "these belong to that group" signal — `WorkspaceItem.vue:720-728`).
- **Collapse state** — per group, persisted in `localStorage` under
  `pabrik-kanban-row-collapsed:<itemId>` as a JSON array of column ids
  (mirrors `pabrik-workspace-item-expanded`, `stores/workspaces.ts:228`).
  Collapse is *not* URL state — it is a density preference, like
  `sidebar-width`, and the repo's URL rule targets *view switches*, not
  disclosure state.
- **Empty board** — no columns at all: a centred "No columns yet — add one in
  Settings" block. (There is currently **no** board-level empty state anywhere;
  `KanbanColumn.vue:855-864` is column-scoped.)
- **Empty group** — "No tasks yet" (copy of `KanbanColumn.vue:855-864`).
- **Search with no matches** — the existing banner at 1332-1340 already covers
  it and is layout-agnostic; keep it shared.

### 4.3 What stays shared between the two modes

Header, both banners, the detail/create panel (1416-1452), `FilePickerDialog`
(1463-1474), search debounce, `?sorts=` handling, SSE. **Only lines 1368-1402
are swapped.**

---

## 5. Implementation plan

### 5.1 New component — `components/kanban/KanbanRowView.vue`

Props:

```ts
{
  columns: KanbanColumn[]      // already position-sorted by the parent
  tasks: Task[]                // the flat item.tasks array
  workspaceId: string
  itemId: string
  cwd?: string
  collapsedIds: string[]       // controlled by the parent (localStorage owner)
  runAllBusyByColumn: Record<string, boolean>
}
```

Emits — **exactly the same names/payloads `KanbanColumn` already emits**, so
`KanbanView`'s existing pass-through block (1384-1401) is reused verbatim:

```
moveTask? (unused in v1)   renameColumn   deleteColumn   reorderColumn
requestRenameColumn        requestDeleteColumn          requestRunAllAgents
sortChange                 selectTask     openTaskInBackground
openTaskDetailInBackground deleteTask     renameTask     pinTask
viewTaskDetail             toggleCollapse
```

Internals:
- `groupedRows = computed(() => columns.map(col => ({ col, rows: tasks.filter(t => t.kanban_column_id === col.id) })))`
  — the same filter as `KanbanColumn.vue:185-188`, hoisted.
- Per-group `hasMore` / `isLoading` read from
  `parentItem.columnPagination[col.id]` (same as `KanbanColumn.vue:226-230`).
- "Load more" → `workspacesStore.loadMoreTasksForColumn(workspaceId, itemId, col.id)`.
- Group header + ⋮ menu + sort modal copied from `KanbanColumn.vue` (632-758,
  900-919) with the drag handlers removed.
- Rows rendered with `KanbanTaskRow` (§5.2).

### 5.2 New component — `components/kanban/KanbanTaskRow.vue`

A ~40-line wrapper that pairs the shared sidebar row with the kanban-only
"open details" affordance:

```vue
<template>
  <div class="group/kanban-row flex items-center gap-1" :data-kanban-row="task.id">
    <WorkspaceItemTaskRow
      :task="task" :workspace-id="workspaceId" :item-id="itemId" :cwd="cwd"
      @select-task="(id) => emit('selectTask', id)"
      @open-task-in-background="(p) => emit('openTaskInBackground', p)"
      @delete-task="(ws, i, id) => emit('deleteTask', ws, i, id)"
      @rename-task="(ws, i, id, n) => emit('renameTask', ws, i, id, n)"
      @pin-task="(ws, i, id, p) => emit('pinTask', ws, i, id, p)"
    />
    <button
      type="button"
      class="shrink-0 w-6 h-6 flex items-center justify-center rounded opacity-0 group-hover/kanban-row:opacity-60 hover:opacity-100"
      :data-testid="`kanban-row-${task.id}-details`"
      title="Open task details"
      @click.stop="emit('viewTaskDetail', task.id)"
    >⋯</button>
  </div>
</template>
```

Why a wrapper and not a `variant` prop on `KanbanCard`: `KanbanCard` wraps
`WorkspaceItemTaskCard` (the ~96 px card) and its whole reason to exist is that
pairing (`KanbanCard.vue:14-18`). Adding a second child + a height switch to it
would make one component own two unrelated layouts. A 40-line wrapper is
cheaper to read and to test — the same argument `DesignPageRow.vue:25-30`
already makes for not reusing `WorkspaceItemTaskRow` for pages.

### 5.3 `KanbanView.vue` changes

1. **State** (near line 379):

```ts
type KanbanLayout = 'columns' | 'rows'
const LAYOUT_PARAM = 'layout'

const readLayoutParam = (): KanbanLayout | null => {
  try {
    const v = route.query?.[LAYOUT_PARAM]
    return v === 'rows' || v === 'columns' ? v : null
  } catch { return null }
}

// URL wins (deep link) → localStorage (sticky preference) → default.
const layout = ref<KanbanLayout>(readLayoutParam() ?? readStoredLayout() ?? 'columns')

const setLayout = (next: KanbanLayout) => {
  if (layout.value === next) return
  layout.value = next
  writeStoredLayout(next)          // try/catch, key `pabrik-kanban-layout`
  try {
    const q = flatQuery()
    if (next === 'columns') delete q[LAYOUT_PARAM]   // strip the default
    else q[LAYOUT_PARAM] = next
    void router.replace({ query: q })                // replace, never push
  } catch { /* router absent in unit tests */ }
}
```

2. **Fix the `?sorts=` watcher (499-505)** to preserve sibling params instead of
   rebuilding the query — this is a **pre-existing bug** (`?detail=` is dropped
   today) and row mode would inherit it:

```ts
watch(columnSorts, (next) => {
  const encoded = encodeSortsParam(Object.values(next))
  const query = flatQuery()
  query.view = 'workspace'
  if (props.workspaceId) query.workspaceId = props.workspaceId
  if (effectiveItemId.value) query.itemId = effectiveItemId.value
  if (encoded) query.sorts = encoded
  else delete query.sorts
  void router.replace({ path: '/app', query })
})
```

3. **Restore on mount** — extend `loadColumnsAndTasks` (150-265) Step 1 to also
   read `?layout=` and mirror it into `layout` (so a deep link wins over the
   stored preference), and add a `watch` on `route.query.layout` so Back/Forward
   flips the view without a remount.

4. **Template** — wrap the board body:

```html
<div v-if="layout === 'columns'" ref="kanbanColumnsContainer" …>   <!-- 1368-1402 unchanged -->
  …
</div>
<KanbanRowView
  v-else
  ref="kanbanRowsContainer"
  :columns="sortedColumns"
  :tasks="tasks"
  :workspace-id="workspaceId"
  :item-id="itemId || item.id"
  :cwd="item.path || ''"
  :collapsed-ids="collapsedColumnIds"
  :run-all-busy-by-column="runAllBusyByColumn"
  @toggle-collapse="toggleColumnCollapsed"
  … (same 16 pass-through listeners as KanbanColumn, 1384-1401)
/>
```

5. **Scroll restore** — `useKanbanScrollRestore` persists `scrollLeft` only
   (`composables/useKanbanScrollRestore.ts:4-5, 172`). Row mode scrolls
   vertically, so it needs its own container ref + key. Two options:
   - **(a)** add a `useKanbanRowScrollRestore` composable mirroring the existing
     one but writing `scrollTop`, key `kanban-row-scroll-<itemId>`; or
   - **(b)** generalise the existing composable with an `axis: 'x' | 'y'` option.
   Plan picks **(b)** — one composable, one spec, and the existing
   `useKanbanScrollRestore.spec.ts` (432 lines) already covers the hard parts
   (rAF ticks, `scrollend` fast path, debounce, unmount flush).

6. **Collapse persistence** — `pabrik-kanban-row-collapsed:<itemId>` (JSON array),
   read/written with the repo's `try/catch` + allow-list shape
   (`DiffView.vue:81-101`). Not user-scoped: it is a visual preference, and
   `userScope.ts:13-16` reserves `userScopedKey()` for identity data.

### 5.4 Files touched

| File | Change |
|---|---|
| `src/components/kanban/KanbanRowView.vue` | **new** (~260 lines) |
| `src/components/kanban/KanbanTaskRow.vue` | **new** (~45 lines) |
| `src/components/kanban/KanbanView.vue` | +~70 lines: layout state, toggle markup, `v-if`/`v-else` body, watcher fix |
| `src/composables/useKanbanScrollRestore.ts` | +`axis` option (~15 lines) |
| `src/__tests__/KanbanView.rowMode.spec.ts` | **new** |
| `src/__tests__/KanbanRowView.spec.ts` | **new** |
| `src/__tests__/KanbanView.sortByApi.spec.ts` | +1 case: layout toggle preserves `?sorts=` |
| `src/__tests__/KanbanView.spec.ts` | +toggle render/emit cases |
| `tests/functional_ui/kanban_lifecycle_ui_test.py` | selectors still valid (columns is the default) — add a row-mode smoke step |

**No backend file is touched.**

---

## 6. URL contract

| Param | Values | Written by | Verb | Default |
|---|---|---|---|---|
| `layout` | `rows` \| `columns` | `setLayout` | `router.replace` | `columns` (stripped from the URL) |

- **Why a new param and not reuse `?sorts=`:** `sorts` has a validated
  `col_<id>:<field>:<dir>` grammar (`KanbanView.vue:437-456`); folding an
  orthogonal mode into it breaks the parser.
- **Why `replace` and not `push`:** the repo rule is explicit — *"clicks write
  it (`router.replace`, not `push`, for tab switches)"* (`AGENTS.md:180-181`).
  `push` is reserved for opening a discrete record (`?detail=`, 690).
- **Default stripped:** `columns` deletes the key, mirroring
  `SidebarDiffPanel.vue:77-79` and `PabrikSettings.vue:105-111`.
- **Precedence:** URL → localStorage → `columns`. Deep links must beat the
  sticky preference (`PabrikTabStrip.vue:35-38` states the same rule).
- **Preservation:** the `?sorts=` watcher fix (§5.3.2) is what keeps `layout`
  and `detail` alive. Without it, picking a column sort silently resets the
  layout — the exact bug class documented at `AppLayout.vue:642-645`.

---

## 7. Why no drag-and-drop in v1

Column mode's DnD is **drop-into-a-column, append-to-end**:
`KanbanColumn.handleDrop` reads `application/x-kanban-task-id` and emits
`position = cardsInColumn.length` (`KanbanColumn.vue:520-535`). There is no
intra-column reordering anywhere in the codebase.

In a linear list the drop target is ambiguous — dropping between two rows could
mean "into the upper row's column at its index" or "into the lower row's column
at index 0", and neither matches the existing append-only semantics. Getting
this wrong silently reorders a user's board.

So v1 ships row mode as a **read + open** view:
- click a row → task chat (`selectTask`, unchanged)
- click `⋯` → task detail panel, which already has a column picker
- `⋮` on a group header → Rename / Sort / Delete / Run all agents (unchanged)

DnD in row mode is a follow-up (§10) and needs its own design pass.

---

## 8. Performance

- **v1 renders all loaded rows.** The board loads page 1 (10 tasks) per column
  (`KanbanView.vue:252-265`, `KanbanColumn.vue:289`), so a 7-column board is
  ~70 rows — trivial. `WorkspaceItemTaskRow` is a light component (no
  description, no image, no meta row).
- **Threshold:** if a board exceeds ~500 loaded rows, wrap the flat list in the
  existing `VirtualScroller` (`helpers/VirtualScroller.vue`, already used at
  `KanbanColumn.vue:821-830`) with `:default-item-height="32"`. Because the list
  is grouped, the scroller needs a flattened `[header, row, row, header, …]`
  array — that is a real refactor, which is why it is deferred until measured.
- **No extra network calls.** Row mode reads the same `item.tasks` the board
  already has; SSE keeps it fresh (`kanbanSse.ts:125-214`).

---

## 9. Test plan

### 9.1 New — `src/__tests__/KanbanView.rowMode.spec.ts`

Model on `KanbanView.sortByApi.spec.ts:71-113` (the `vi.hoisted` router mock +
`mountKanbanView(query)` factory) and `SidebarDiffPanel.tabs.spec.ts:171-244`
(the two mandated URL-sync cases).

1. `clicking Rows writes ?layout=rows via router.replace` — assert
   `replaceMock.mock.calls.at(-1)[0].query.layout === 'rows'`.
2. `mount with ?layout=rows restores the row view` — assert
   `[data-testid="kanban-view-<id>-layout-rows"]` has `aria-selected="true"`
   and the row container exists.
3. `clicking Columns strips ?layout= from the URL` (default-value stripping).
4. `mount with ?layout=rows renders one group per column, in position order`.
5. `mount with ?layout=rows renders a row per task, grouped by kanban_column_id`.
6. `toggling layout preserves ?sorts=` — the regression guard for §5.3.2.
7. `toggling layout preserves ?detail=` — the pre-existing bug this fixes.
8. `unknown ?layout= value falls back to columns` (allow-list validation).
9. `localStorage preference is used when the URL has no ?layout=`.
10. `URL wins over localStorage when both are present`.
11. `collapsing a group hides its rows and persists to localStorage`.
12. `row click emits selectTask`; `⋯ click emits viewTaskDetail`.
13. `group ⋮ menu emits requestRenameColumn / requestDeleteColumn / requestRunAllAgents`.
14. `empty board renders the board-level empty state`.

### 9.2 New — `src/__tests__/KanbanRowView.spec.ts`

Grouping, count badge, `hasMore` → "Load more" → `loadMoreTasksForColumn`,
empty group placeholder, collapse toggle emit, `runAllBusy` disables the menu item.

### 9.3 Modified

- `KanbanView.spec.ts` — toggle renders in the header; `aria-selected` flips.
- `KanbanView.sortByApi.spec.ts` — add "layout toggle preserves `sorts`".
- `composables/__tests__/useKanbanScrollRestore.spec.ts` — add the `axis: 'y'` case.

### 9.4 Commands

```bash
cd src/apps/desktop
npx vitest --run src/__tests__/KanbanView.rowMode.spec.ts
npx vitest --run KanbanView          # all KanbanView*.spec.ts
npx vitest --run Kanban              # every Kanban*.spec.ts
pnpm type-check && pnpm lint:check
```

Playwright (`tests/functional_ui/kanban_lifecycle_ui_test.py`) keeps passing
unchanged because **columns stays the default**; add one step that clicks Rows
and asserts the groups render.

---

## 10. Follow-ups (explicitly out of scope)

1. **Board-wide sort in row mode** — a `?rowsort=field:dir` param + a
   `fetchKanbanTasksBoardWide` store wrapper over the existing
   `api.getTasks` (its `column_id` param is already optional,
   `api/index.ts:703-705`; the backend already handles `column_id: null`,
   `tasks_list.zig:114-118`). One request instead of N.
2. **Drag-and-drop in row mode** — needs a drop-semantics design (§7).
3. **True totals** — `total_count` on the task-list response
   (`http_response.zig:609-622`) so counts stop meaning "loaded rows".
4. **Virtualized row list** for very large boards (§8).
5. **Extract a shared `SegmentedControl`** — three hand-rolled copies exist
   (`DiffView.vue:479-505`, `AgentKnowledgeDialog.vue:162-182`,
   `ChatRightSidebar.vue:194-213`); a fourth is about to be added here.

---

## 11. Risks

| Risk | Mitigation |
|---|---|
| `?sorts=` watcher clobbers `?layout=` | §5.3.2 rewrites it to use `flatQuery()`; test 9.1.6 |
| `?detail=` already dropped by that watcher | Same fix; test 9.1.7 |
| Row mode loses scroll position on task-chat round-trip | `KanbanView` unmounts when a task chat opens (`AppLayout.vue:2980-2982` `:key`), so the vertical position must be persisted — §5.3.5 |
| Counts read as totals | Group header shows `N+` when `hasMore`; documented in §3.5 |
| Playwright board test breaks | Columns stays the default; only an additive step |
| Two layouts drift apart | Both consume the same `sortedColumns` / `tasks` / `?sorts=` / SSE; only the body markup differs |
