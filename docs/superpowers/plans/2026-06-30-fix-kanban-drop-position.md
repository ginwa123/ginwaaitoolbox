# Kanban Card Drop Position — Frontend Position-Aware Drag-and-Drop

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the user drags a kanban card onto a column, place it at the **exact position where the user released the drag** (above/below/inserted-between other cards), not always at the end. This is the Trello/Linear/standard UX for kanban reordering.

**Architecture:** Frontend-only fix. The backend (`kanban_model.moveTask` in `src/ai_workflow/tui/kanban_model.zig:398`) already accepts an arbitrary `target_position` and does the right sibling re-numbering — verified by `kanban_model_test.zig:266` ("moveTask changes column and renumbers positions"). The API layer (`api.moveTask` in `src/apps/desktop/src/api/index.ts:1124`), the store action (`moveTaskToColumn` in `src/apps/desktop/src/stores/workspaces.ts:876`), the host wiring (`handleKanbanMoveTask` in `src/apps/desktop/src/components/AppLayout.vue:799`), and the SSE broadcast path (refetch on `kanban_task.*` events) are all in place.

The only thing missing is the **frontend drop handler** that translates the cursor position into a meaningful `position` integer before calling `emit('moveTask', { ... position })`. Currently `KanbanColumn.vue:228` hardcodes `position = cardsInColumn.value.length` regardless of where the user dropped.

**Tech Stack:** Vue 3 + TypeScript + Pinia (frontend only). No backend changes. No new dependencies.

---

## Root Cause

`src/apps/desktop/src/components/KanbanColumn.vue` lines 218-234:

```ts
const handleDrop = (event: DragEvent) => {
  event.preventDefault()
  isDragOver.value = false
  const dataTransfer = event.dataTransfer
  if (!dataTransfer) return
  const taskId = dataTransfer.getData('application/x-kanban-task-id')
  if (!taskId) return
  // v1: append to the end of the receiving column. The position is
  // the current card count — the backend re-numbers siblings after
  // the insert, so "append" maps to "position = current length".
  const position = cardsInColumn.value.length
  emit('moveTask', {
    taskId,
    columnId: props.column.id,
    position,
  })
}
```

The inline comment even admits it: **"v1: append to the end of the receiving column. The user can always reorder within a column in a future iteration."** — this plan implements that future iteration.

---

## Design: Gap-Based Drop Indicators (Linear/Trello UX)

The simplest, cleanest, and most-testable approach:

- Render **N+1 "gap" drop zones** in the cards container — one gap before the first card (position 0), one between each pair (positions 1..N-1), and one after the last card (position N = append to end).
- Each gap is a thin (~8px tall, transparent) horizontal bar with `data-insert-position` set to the position it represents.
- On `dragover`, the gap becomes visible as a solid violet insertion line (visual confirmation of "drop here").
- On `drop`, the gap emits `moveTask` with `position = gap's data-insert-position`.
- The existing column-level drop zone is repurposed: it remains responsible for the column-wide highlight (`isDragOver`) and serves as a fallback for empty columns (rendered as a single virtual gap at position 0).

This unifies the within-column and cross-column reorder under one model: every position in a column, regardless of which card is currently there, is reachable via a gap.

Visual mock (3 cards, dragging card "A" up):

```
┌─────────────────────────┐
│ header                  │
├─────────────────────────┤
│ ╔═══════════════════════╡  ← gap 0 (highlighted violet)
│ ║ card B                │
│ ║                       │
│ ╠ gap 1 (hidden)        │
│ ║ card C                │
│ ║                       │
│ ╠ gap 2 (hidden)        │
│ ║ card D                │
│ ║                       │
│ ╚ gap 3 (hidden)        │  ← position 3 = append to end
├─────────────────────────┤
│ + Add                   │
└─────────────────────────┘
```

---

## File Structure

Files to modify (frontend only):
- `src/apps/desktop/src/components/KanbanColumn.vue` — render gap drop zones, add per-gap dragover/drop handlers, remove the legacy "always append to end" logic.
- `src/apps/desktop/src/__tests__/KanbanColumn.spec.ts` — add tests for the new gap-based drop positions.
- `src/apps/desktop/src/__tests__/KanbanView.spec.ts` — update the existing "drop on column drop zone" test to reflect the new gap layout.

No backend changes (the `moveTask` API and `moveTaskToColumn` store action are unchanged). No new files. No new dependencies.

---

## Chunk 1: Render Gap Drop Indicators

### Task 1.1: Replace the column-level "append to end" drop with N+1 gap-based drops

**File:** `src/apps/desktop/src/components/KanbanColumn.vue`

#### Step 1.1.1: Add `dragInsertPosition` state and gap handlers

After the existing `isDragOver` / `isDragging` refs (around line 188), add a new ref for tracking which gap is currently highlighted:

```ts
// Index of the gap currently being dragged over (null = none).
// When a card drag enters a gap, the gap shows a violet insertion
// line. When drag leaves, the ref clears (handled by the gap's
// dragleave + the next gap's dragover racing).
const dragInsertPosition = ref<number | null>(null)
```

#### Step 1.1.2: Add per-gap dragover / dragleave / drop handlers

After the existing `handleDragLeave` (around line 216), add three small handlers dedicated to the gap targets. These mirror the existing column-level dragover filter but target the gap's `data-insert-position` instead of the column id:

```ts
// Per-gap handlers. The gap element carries `data-insert-position`
// (0..cardsInColumn.length); on drop we emit move-task with that
// position. The MIME-type filter matches the column-level handler
// — only kanban card drags are accepted; column drags (which carry
// the column-id MIME) are ignored here because they target the
// header, not the cards container.
const handleGapDragOver = (event: DragEvent) => {
  if (!event.dataTransfer) return
  if (!event.dataTransfer.types.includes('application/x-kanban-task-id')) {
    return
  }
  event.preventDefault()
  if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'
  // Read the gap's position from the dataset and flag it as the
  // active insertion target. Browsers fire this on every micro-move
  // while the cursor is over the gap — assigning to a primitive ref
  // is cheap.
  const target = event.currentTarget as HTMLElement | null
  if (!target) return
  const pos = Number(target.dataset.insertPosition)
  if (Number.isFinite(pos)) {
    dragInsertPosition.value = pos
  }
}

const handleGapDragLeave = (event: DragEvent) => {
  // Only clear if the cursor LEAVES the gap entirely (not when it
  // crosses between cards inside the gap). `currentTarget` is the
  // gap; if `relatedTarget` is still inside, do nothing. Mirrors the
  // pattern in handleDragLeave (above).
  const gap = event.currentTarget as HTMLElement | null
  const next = event.relatedTarget as Node | null
  if (gap && next && gap.contains(next)) return
  // Don't unconditionally clear — the next gap's dragover will set
  // the new value. We only clear if the cursor genuinely left the
  // cards container (caller detects via handleDragLeave on the
  // container). The container-level handler will reset to null.
}

const handleGapDrop = (event: DragEvent) => {
  event.preventDefault()
  const dataTransfer = event.dataTransfer
  if (!dataTransfer) return
  const taskId = dataTransfer.getData('application/x-kanban-task-id')
  if (!taskId) return
  const target = event.currentTarget as HTMLElement | null
  if (!target) return
  const position = Number(target.dataset.insertPosition)
  if (!Number.isFinite(position)) return
  // Don't move a card onto its own current position. The backend's
  // moveTask would be a no-op API call but would still trigger an
  // SSE `kanban_task.moved` broadcast and an unnecessary re-numbering
  // pass on the source column. Skip the emit entirely.
  const sourceTask = props.tasks.find((t) => t.id === taskId)
  if (
    sourceTask
    && sourceTask.kanban_column_id === props.column.id
    && sourceTask.kanban_position === position
  ) {
    return
  }
  emit('moveTask', {
    taskId,
    columnId: props.column.id,
    position,
  })
}
```

#### Step 1.1.3: Update the column-level `handleDragOver` / `handleDragLeave` / `handleDrop`

The existing column-level handlers `handleDragOver` (line 190), `handleDragLeave` (line 208), and `handleDrop` (line 218) need to be **edited**, not replaced — they still handle:
- `isDragOver.value = true/false` for the column-wide highlight (the dashed violet outline on the cards container)
- The dragstart/dragend capture for source-card dimming (`handleDragStartCapture` / `handleDragEndCapture`)
- Resetting `dragInsertPosition` when the cursor leaves the cards container

Replace `handleDrop` so it handles **only the case where the user drops on the empty "No tasks yet" placeholder** (or, equivalently, where the gap array is empty). When the column has cards, all drops land on a gap and the gap's `handleGapDrop` fires. When the column is empty (no gaps rendered), the drop zone's own `handleDrop` acts as the position-0 drop:

```ts
const handleDrop = (event: DragEvent) => {
  event.preventDefault()
  // Clear per-gap state regardless of which path handles the move.
  isDragOver.value = false
  dragInsertPosition.value = null
  const dataTransfer = event.dataTransfer
  if (!dataTransfer) return
  const taskId = dataTransfer.getData('application/x-kanban-task-id')
  if (!taskId) return
  // If this column already has cards, the drop MUST have landed on
  // a gap (because the gaps cover the entire cards container). The
  // gap-level handler (handleGapDrop) has already emitted moveTask —
  // we just need to reset our state and return. The defensive
  // duplicate guard prevents a double-emit if for any reason the
  // gap handler did not fire (e.g. test mocks, future layout
  // changes).
  if (cardsInColumn.value.length > 0) return
  // Empty column: drop on the container = insert at position 0.
  emit('moveTask', {
    taskId,
    columnId: props.column.id,
    position: 0,
  })
}
```

Update `handleDragLeave` so it ALSO clears `dragInsertPosition` when the cursor leaves the cards container entirely (only when `relatedTarget` is outside the zone):

```ts
const handleDragLeave = (event: DragEvent) => {
  const zone = event.currentTarget as HTMLElement | null
  const next = event.relatedTarget as Node | null
  if (zone && next && zone.contains(next)) return
  isDragOver.value = false
  // Clear the gap highlight too — the cursor has left the cards
  // container entirely. Per-gap handleGapDragLeave does NOT reset
  // the ref on its own (to let the next gap's dragover set the new
  // value); this is the single source of truth for "no gap
  // highlighted".
  dragInsertPosition.value = null
}
```

(Leave `handleDragOver` as-is — it still calls `preventDefault()` and sets `isDragOver` for the container-wide highlight. The MIME-type filter (`application/x-kanban-task-id`) is unchanged.)

#### Step 1.1.4: Render the N+1 gap elements in the template

In the `<template>` block, replace the existing `<KanbanCard v-for ...>` / "No tasks yet" `<div>` inside the cards container div (lines 455-478) with the gap+card+gap+card... interleaving:

```vue
<!-- ─── Cards drop zone (gap-aware) ───────────────────────────────── -->
<div
  class="flex-1 min-h-0 overflow-y-auto p-2"
  :style="isDragOver
    ? 'background-color: var(--semantic-active-bg); outline: 2px dashed var(--color-violet); outline-offset: -4px;'
    : ''"
  :data-kanban-drop-zone="column.id"
  :data-testid="`kanban-column-${column.id}-cards`"
  @dragover="handleDragOver"
  @dragleave="handleDragLeave"
  @drop="handleDrop"
  @dragstart.capture="handleDragStartCapture"
  @dragend.capture="handleDragEndCapture"
>
  <!-- Interleave N+1 gap drop zones with the N cards. The gap at
       position i emits move-task with `position: i`. The gap BEFORE
       the first card is position 0; the gap AFTER the last card is
       position N (= append to end). Each gap is a thin ~8px tall
       transparent bar that becomes a solid violet insertion line
       when dragInsertPosition === its index. -->
  <template v-for="(task, index) in cardsInColumn" :key="`gap-before-${task.id}`">
    <!-- gap before this card (position = index) -->
    <div
      class="kanban-insert-gap"
      :class="dragInsertPosition === index ? 'kanban-insert-gap-active' : ''"
      :data-insert-position="index"
      :data-testid="`kanban-column-${column.id}-insert-${index}`"
      style="
        height: 8px;
        margin: -4px 0;
        border-radius: 4px;
        transition: background-color 0.1s ease, height 0.1s ease;
      "
      @dragover="handleGapDragOver"
      @dragleave="handleGapDragLeave"
      @drop="handleGapDrop"
    ></div>
    <!-- the card itself -->
    <KanbanCard
      :task="task"
      :workspace-id="workspaceId"
      :item-id="itemId"
      :style="isDragging ? 'opacity: 0.4;' : ''"
      @select-task="(id) => emit('selectTask', id)"
      @delete-task="(ws, item, id) => emit('deleteTask', ws, item, id)"
      @rename-task="(ws, item, id, name) => emit('renameTask', ws, item, id, name)"
      @edit-routine="(ws, item, id) => emit('editRoutine', ws, item, id)"
      @run-routine="(ws, item, id) => emit('runRoutine', ws, item, id)"
      @pin-task="(ws, item, id, pinned) => emit('pinTask', ws, item, id, pinned)"
    />
  </template>
  <!-- gap after the last card (position = cardsInColumn.length = append to end) -->
  <div
    class="kanban-insert-gap"
    :class="dragInsertPosition === cardsInColumn.length ? 'kanban-insert-gap-active' : ''"
    :data-insert-position="cardsInColumn.length"
    :data-testid="`kanban-column-${column.id}-insert-${cardsInColumn.length}`"
    style="
      height: 8px;
      margin: -4px 0;
      border-radius: 4px;
      transition: background-color 0.1s ease, height 0.1s ease;
    "
    @dragover="handleGapDragOver"
    @dragleave="handleGapDragLeave"
    @drop="handleGapDrop"
  ></div>
  <!-- Empty placeholder. Shown only when there are no cards; the
       container-level handleDrop intercepts drops on it and emits
       move-task with position 0. -->
  <div
    v-if="cardsInColumn.length === 0"
    class="text-xs text-center py-6"
    style="color: var(--semantic-text-dim);"
    :data-testid="`kanban-column-${column.id}-empty`"
  >
    No tasks yet
  </div>
</div>
```

Update the `<style scoped>` block to add the `kanban-insert-gap` / `kanban-insert-gap-active` rules:

```css
/* Gap drop zones — always present (N+1 per column), hidden until
   the cursor hovers one with a kanban card drag. The
   "active" state shows a solid violet insertion line (Trello /
   Linear UX). The negative margin (-4px 0) tightens the visual
   gap when inactive but expands the hit target to 8px tall — the
   cursor has a forgiving target without the inactive state looking
   like extra padding. */
.kanban-insert-gap {
  background-color: transparent;
}
.kanban-insert-gap-active {
  background-color: var(--color-violet);
  height: 4px;
  margin: 0;
}
```

**Visual rationale:** the negative margin (`margin: -4px 0`) on the inactive state compresses the visual gap to 0px (so gaps don't add vertical noise when not in use), but keeps the hit target at 8px tall (so the cursor has a generous target). On activation, the margin collapses to 0 and height shrinks to 4px so the violet bar appears between cards without expanding the column.

#### Step 1.1.5: Reset `dragInsertPosition` on `dragend` (cancel + success cleanup)

The HTML5 DnD spec fires `dragend` for **both** successful drops AND cancellations (ESC, drop outside any valid target). Without this reset, a cancelled drag would leave the violet insertion line visible. Add this handler next to the existing `handleDragEndCapture`:

```ts
const handleColumnDragEndCapture = () => {
  isDragging.value = false
  isDragOver.value = false
  // Clear the gap highlight too — covers BOTH successful drops (the
  // gap that received the drop already cleared it via its own
  // handler) AND cancelled drags (no drop fired at all, so no gap
  // got the chance to clear it). Always reset on dragend.
  dragInsertPosition.value = null
}
```

Replace the existing `@dragend.capture="handleDragEndCapture"` binding on the cards container div with the new one:

```vue
@dragend.capture="handleColumnDragEndCapture"
```

(Keep the existing `handleDragStartCapture` (line 240) unchanged — it still sets `isDragging.value = true` for source-card dimming.)

---

### Task 1.2: Verify the visible UX in the browser

#### Step 1.2.1: Manual smoke test on port 8080

```bash
# Rebuild the desktop app and start the server (port 8080, NOT 8081).
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 600 bun run build 2>&1 | tail -n 10
# Expected: "Build Summary: ... built in N.NNs"
./zig-out/bin/nalar --port 8080 &
```

Then in the browser (open DevTools first):
1. Navigate to a kanban with several cards in a column.
2. Pick up a card from the middle.
3. While dragging, slowly move the cursor between two existing cards. The expected visual:
   - A thin violet bar appears between the cards where the cursor is hovering.
   - When the cursor is above the first card, the violet bar appears above the first card.
   - When the cursor is below the last card, the violet bar appears below the last card.
4. Drop the card. The card should snap to the position of the violet bar (NOT always at the end).
5. Cross-column drops should also work: drag from column A to gap 2 of column B. The card lands at slot 2 of column B.
6. Move several cards around in quick succession to verify no flicker / stale-highlight bugs.

If anything looks wrong (e.g. the violet bar doesn't appear, or the card always appends), `kill <pid>` of the nalar-8080 process and the dev console will have the Vue warnings.

#### Step 1.2.2: Clean up

```bash
kill <pid of the 8080 nalar process>
# IMPORTANT: never `pkill -f "zig build run"` and never touch the
# process on port 8081 — see NALAR.md rule + active_workers.
```

---

## Chunk 2: Update Tests

### Task 2.1: Update the existing KanbanView drop test

**File:** `src/apps/desktop/src/__tests__/KanbanView.spec.ts`

#### Step 2.1.1: Locate the existing drop test

Around line 240-263:

```ts
it('passes through move-task from the cards drop zone (append to end)', async () => {
  // ...
  const dropZone = wrapper.find('[data-kanban-drop-zone="col_x"]')
  const getData = vi.fn((mime: string) => (mime === 'application/x-kanban-task-id' ? 't1' : ''))
  const dataTransfer = { getData, types: ['application/x-kanban-task-id'] } as unknown as DataTransfer
  await dropZone.trigger('drop', { dataTransfer })
  expect(wrapper.emitted('moveTask')?.[0]).toEqual([{ taskId: 't1', columnId: 'col_x', position: 1 }])
})
```

This test exercises dropping onto the column with **1 existing task**. Per the new design:
- With 1 card, the column renders 2 gap drop zones (one before at position 0, one after at position 1).
- The "drop on column drop zone" event (no gap target reached) only fires when the column is **empty**. The defensive duplicate guard in handleDrop (`if (cardsInColumn.value.length > 0) return`) means triggering `drop` on the `[data-kanban-drop-zone="col_x"]` element now does NOTHING (no emit).

The correct new test for the "non-empty column → use gap" case:
- Use the gap element (e.g. `[data-testid="kanban-column-col_x-insert-1"]` to drop at position 1 = append to end, OR `[data-testid="kanban-column-col_x-insert-0"]` to drop at position 0 = insert at top).

Replace the existing single test with the following three:

```ts
describe('KanbanView — move-task event emission', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  function makeTaskDragDataTransfer(taskId: string): DataTransfer {
    return {
      effectAllowed: '',
      dropEffect: '',
      getData: vi.fn((mime: string) => (mime === 'application/x-kanban-task-id' ? taskId : '')),
      setData: vi.fn(),
      types: ['application/x-kanban-task-id'],
    } as unknown as DataTransfer
  }

  it('emits move-task with position 0 when dropping on the first gap (insert at top)', async () => {
    wrapper = mountView(
      makeItem({
        kanban_columns: [makeColumn({ id: 'col_x', name: 'todo', position: 0 })],
        tasks: [
          { id: 't1', name: 'A', kanban_column_id: 'col_x', kanban_position: 0 },
          { id: 't2', name: 'B', kanban_column_id: 'col_x', kanban_position: 1 },
        ],
      }),
    )
    const gap0 = wrapper.find('[data-testid="kanban-column-col_x-insert-0"]')
    expect(gap0.exists()).toBe(true)
    await gap0.trigger('drop', { dataTransfer: makeTaskDragDataTransfer('t1') })
    expect(wrapper.emitted('moveTask')?.[0]).toEqual([
      { taskId: 't1', columnId: 'col_x', position: 0 },
    ])
  })

  it('emits move-task with position N (append) when dropping on the last gap', async () => {
    wrapper = mountView(
      makeItem({
        kanban_columns: [makeColumn({ id: 'col_x', name: 'todo', position: 0 })],
        tasks: [
          { id: 't1', name: 'A', kanban_column_id: 'col_x', kanban_position: 0 },
          { id: 't2', name: 'B', kanban_column_id: 'col_x', kanban_position: 1 },
        ],
      }),
    )
    // Two cards → three gaps: insert-0 (before A), insert-1 (between), insert-2 (after B = append).
    const gap2 = wrapper.find('[data-testid="kanban-column-col_x-insert-2"]')
    expect(gap2.exists()).toBe(true)
    await gap2.trigger('drop', { dataTransfer: makeTaskDragDataTransfer('t1') })
    expect(wrapper.emitted('moveTask')?.[0]).toEqual([
      { taskId: 't1', columnId: 'col_x', position: 2 },
    ])
  })

  it('emits move-task with position 1 when dropping between two cards', async () => {
    wrapper = mountView(
      makeItem({
        kanban_columns: [makeColumn({ id: 'col_x', name: 'todo', position: 0 })],
        tasks: [
          { id: 't1', name: 'A', kanban_column_id: 'col_x', kanban_position: 0 },
          { id: 't2', name: 'B', kanban_column_id: 'col_x', kanban_position: 1 },
        ],
      }),
    )
    const gap1 = wrapper.find('[data-testid="kanban-column-col_x-insert-1"]')
    expect(gap1.exists()).toBe(true)
    await gap1.trigger('drop', { dataTransfer: makeTaskDragDataTransfer('t1') })
    expect(wrapper.emitted('moveTask')?.[0]).toEqual([
      { taskId: 't1', columnId: 'col_x', position: 1 },
    ])
  })

  it('emits move-task with position 0 when dropping on an empty column (no gaps rendered)', async () => {
    wrapper = mountView(
      makeItem({
        kanban_columns: [makeColumn({ id: 'col_x', name: 'todo', position: 0 })],
        tasks: [],
      }),
    )
    // No cards → no gaps rendered. The drop zone itself catches the
    // drop and emits position 0.
    const dropZone = wrapper.find('[data-kanban-drop-zone="col_x"]')
    await dropZone.trigger('drop', { dataTransfer: makeTaskDragDataTransfer('t1') })
    expect(wrapper.emitted('moveTask')?.[0]).toEqual([
      { taskId: 't1', columnId: 'col_x', position: 0 },
    ])
  })
})
```

Also remove the old "passes through move-task from the cards drop zone (append to end)" test (or convert it into a comment indicating the behavior was intentionally changed).

#### Step 2.1.2: Run the tests

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
# Expected: clean build, all four new KanbanView tests pass.

timeout 120 bunx vitest run KanbanView 2>&1 | tail -n 30
# Expected: "4 passed" (the four new tests).
```

---

### Task 2.2: Add per-gap tests at the KanbanColumn level

**File:** `src/apps/desktop/src/__tests__/KanbanColumn.spec.ts`

#### Step 2.2.1: Add the new test block

Append a new `describe` block at the bottom of the file (after the existing "column header drag-and-drop reorder" block):

```ts
describe('KanbanColumn — card drop position (gap-based)', () => {
  // The cards container renders N+1 gap drop zones. Each gap carries
  // a `data-insert-position` attribute. Dropping on a gap emits
  // move-task with that position. Insertion of an existing card at
  // its own current position is a no-op (no emit) to avoid
  // unnecessary SSE rebroadcasts.

  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  function dropDataTransfer(taskId: string): DataTransfer {
    return {
      effectAllowed: '',
      dropEffect: '',
      getData: vi.fn((mime: string) => (mime === 'application/x-kanban-task-id' ? taskId : '')),
      setData: vi.fn(),
      types: ['application/x-kanban-task-id'],
    } as unknown as DataTransfer
  }

  it('renders N+1 gap drop zones for N cards (insert-0 through insert-N)', () => {
    wrapper = mountColumn(
      makeColumn({ id: COL_TODO }),
      [
        makeTask({ id: 't1', kanban_column_id: COL_TODO, kanban_position: 0 }),
        makeTask({ id: 't2', kanban_column_id: COL_TODO, kanban_position: 1 }),
        makeTask({ id: 't3', kanban_column_id: COL_TODO, kanban_position: 2 }),
      ],
    )
    expect(wrapper.find(`[data-testid="kanban-column-${COL_TODO}-insert-0"]`).exists()).toBe(true)
    expect(wrapper.find(`[data-testid="kanban-column-${COL_TODO}-insert-1"]`).exists()).toBe(true)
    expect(wrapper.find(`[data-testid="kanban-column-${COL_TODO}-insert-2"]`).exists()).toBe(true)
    expect(wrapper.find(`[data-testid="kanban-column-${COL_TODO}-insert-3"]`).exists()).toBe(true)
    // Gap 4 should NOT exist (3 cards ⇒ 4 gaps: insert-0..insert-3).
    expect(wrapper.find(`[data-testid="kanban-column-${COL_TODO}-insert-4"]`).exists()).toBe(false)
  })

  it('renders zero gaps when the column has no cards (relies on drop-zone fallback)', () => {
    wrapper = mountColumn(makeColumn({ id: COL_TODO }), [])
    expect(wrapper.find(`[data-testid="kanban-column-${COL_TODO}-insert-0"]`).exists()).toBe(false)
  })

  it('drop on insert-0 emits move-task with position 0 (insert at top)', async () => {
    wrapper = mountColumn(
      makeColumn({ id: COL_TODO }),
      [
        makeTask({ id: 't1', kanban_column_id: COL_TODO, kanban_position: 0 }),
        makeTask({ id: 't2', kanban_column_id: COL_TODO, kanban_position: 1 }),
      ],
    )
    const gap = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-insert-0"]`)
    await gap.trigger('drop', { dataTransfer: dropDataTransfer('t1') })
    expect(wrapper.emitted('moveTask')?.[0]).toEqual([
      { taskId: 't1', columnId: COL_TODO, position: 0 },
    ])
  })

  it('drop on insert-2 (between cards[1] and cards[2]) emits position 2', async () => {
    wrapper = mountColumn(
      makeColumn({ id: COL_TODO }),
      [
        makeTask({ id: 't1', kanban_column_id: COL_TODO, kanban_position: 0 }),
        makeTask({ id: 't2', kanban_column_id: COL_TODO, kanban_position: 1 }),
        makeTask({ id: 't3', kanban_column_id: COL_TODO, kanban_position: 2 }),
      ],
    )
    const gap = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-insert-2"]`)
    await gap.trigger('drop', { dataTransfer: dropDataTransfer('t1') })
    expect(wrapper.emitted('moveTask')?.[0]).toEqual([
      { taskId: 't1', columnId: COL_TODO, position: 2 },
    ])
  })

  it('drop on insert-N (after last card) emits position N (append to end)', async () => {
    wrapper = mountColumn(
      makeColumn({ id: COL_TODO }),
      [
        makeTask({ id: 't1', kanban_column_id: COL_TODO, kanban_position: 0 }),
        makeTask({ id: 't2', kanban_column_id: COL_TODO, kanban_position: 1 }),
      ],
    )
    const gap = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-insert-2"]`)
    await gap.trigger('drop', { dataTransfer: dropDataTransfer('t1') })
    expect(wrapper.emitted('moveTask')?.[0]).toEqual([
      { taskId: 't1', columnId: COL_TODO, position: 2 },
    ])
  })

  it('drop on a gap from a different column task emits that column\'s id', async () => {
    // Cross-column drop: source task is in COL_DONE; dropping on a
    // gap in COL_TODO. The handler must emit COL_TODO as the target.
    wrapper = mountColumn(
      makeColumn({ id: COL_TODO }),
      [
        makeTask({ id: 't1', kanban_column_id: COL_DONE, kanban_position: 0 }),
      ],
    )
    const gap = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-insert-1"]`)
    await gap.trigger('drop', { dataTransfer: dropDataTransfer('t1') })
    expect(wrapper.emitted('moveTask')?.[0]).toEqual([
      { taskId: 't1', columnId: COL_TODO, position: 1 },
    ])
  })

  it('drop is a no-op when the dragged task is already at the gap\'s position (avoids unnecessary SSE rebroadcast)', async () => {
    wrapper = mountColumn(
      makeColumn({ id: COL_TODO }),
      [
        makeTask({ id: 't1', kanban_column_id: COL_TODO, kanban_position: 0 }),
      ],
    )
    // Gap 0 is BEFORE t1; dropping t1 on insert-0 means "move to
    // position 0" — t1 is already there. The defensive no-op
    // suppresses the emit.
    const gap = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-insert-0"]`)
    await gap.trigger('drop', { dataTransfer: dropDataTransfer('t1') })
    expect(wrapper.emitted('moveTask')).toBeUndefined()
  })

  it('drop on the empty-column drop zone (no gaps rendered) emits position 0', async () => {
    wrapper = mountColumn(makeColumn({ id: COL_TODO }), [])
    const dropZone = wrapper.find(`[data-kanban-drop-zone="${COL_TODO}"]`)
    await dropZone.trigger('drop', { dataTransfer: dropDataTransfer('t1') })
    expect(wrapper.emitted('moveTask')?.[0]).toEqual([
      { taskId: 't1', columnId: COL_TODO, position: 0 },
    ])
  })

  it('dragover on a gap adds the kanban-insert-gap-active class', async () => {
    wrapper = mountColumn(
      makeColumn({ id: COL_TODO }),
      [
        makeTask({ id: 't1', kanban_column_id: COL_TODO, kanban_position: 0 }),
      ],
    )
    const gap = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-insert-1"]`)
    expect(gap.classes()).not.toContain('kanban-insert-gap-active')
    await gap.trigger('dragover', { dataTransfer: dropDataTransfer('t1') })
    expect(gap.classes()).toContain('kanban-insert-gap-active')
  })
})
```

#### Step 2.2.2: Run the column-level tests

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
# Expected: clean build (vue-tsc type-check must pass — see step below).

timeout 120 bunx vitest run KanbanColumn 2>&1 | tail -n 30
# Expected: all 8 new tests pass + the existing tests still pass.
```

#### Step 2.2.3: vue-tsc catches the `dataset.insertPosition` index access

The test that `expect(gap.classes()).not.toContain('kanban-insert-gap-active')` followed by `await gap.trigger('dragover', ...)` might trip `vue-tsc --build` because the gap element's `dataset.insertPosition` is typed as `string | undefined` (DOMString). The conditional `if (Number.isFinite(position))` handles this at runtime. To make the type narrowing visible in the script, the read should use `target.dataset.insertPosition ?? ''` before `Number(...)`:

```ts
const pos = Number(target.dataset.insertPosition ?? '')
```

Re-run `bun run build` after this adjustment to verify zero TypeScript errors.

---

### Task 2.3: Run the full frontend test suite + build

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 240 bun run build 2>&1 | tail -n 15
# Expected: clean build. vue-tsc --build passes.

timeout 240 bunx vitest run 2>&1 | tail -n 10
# Expected: ALL existing tests still pass + the new tests pass.
# If any previously-passing test now fails, the most likely cause is
# the gap rendering changing query results in a test that asserted
# the absence of "extra" elements inside the cards container.
```

---

## Chunk 3: Manual Verification & Wrap-up

### Task 3.1: Run the kanban end-to-end on port 8080

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 600 bun run build 2>&1 | tail -n 10
./zig-out/bin/nalar --port 8080 &
NALAR_PID=$!
```

In the browser (DevTools open):
1. Open a kanban with at least 3 cards in 2 columns.
2. **Within-column reorder**: drag card A from slot 1 to slot 3 (via gap 2). Card moves; the others shift up to fill A's old position.
3. **Insert at top**: drag card C from slot 3 to gap 0 (above A). Card C moves to slot 0; A, B shift down.
4. **Append to end**: drag card A from anywhere to the last gap. Card moves to bottom.
5. **Cross-column move**: drag card A from column Todo to gap 1 of column Done. Card appears in column Done at slot 1.
6. **Empty column**: drop a card into a column with no cards. Lands at slot 0.
7. **Visual feedback**: during each drag, the violet insertion line follows the cursor between cards.

### Task 3.2: Stop the dev server

```bash
kill $NALAR_PID
# (No other nalar process to worry about — port 8081 stays untouched per NALAR.md.)
```

### Task 3.3: Move the task to "done"

After all tests pass and the manual smoke test succeeds, move the kanban card to the "done" column:

```bash
# Use the kanban_move_task MCP tool with the workspace_id, item_id, and task_id
# from the session context. Columns on this board:
#   col_1782442554112968570  todo
#   col_1782442554114534970  in progress  (current)
#   col_1782442554115179957  done         (target)
```

Pass `target_column_id = "col_1782442554115179957"`.

---

## Verification Checklist

- [ ] `timeout 600 bun run build` exits 0 with no vue-tsc errors.
- [ ] `timeout 240 bunx vitest run` shows the 4 new KanbanView tests + 8 new KanbanColumn tests passing, with no regressions in the existing 31+ frontend tests.
- [ ] Manual smoke test on `http://127.0.0.1:8080`: within-column reorder moves the dropped card to the EXACT gap the user released on (verified by the violet insertion line). Cross-column moves work. Empty-column drops land at slot 0. No flicker / stale-highlight bugs.
- [ ] The existing column-reorder feature (header drag) still works — independent of card-drop gaps.
- [ ] No Zig code changes (backend already supports the position parameter correctly).

---

## Risks & Mitigations

### Risk: Existing tests that asserted `[data-kanban-drop-zone]` triggers a move-task emit

The previous KanbanView test dropped onto `[data-kanban-drop-zone="col_x"]` and expected a `moveTask` emit with `position: 1`. With the new design:
- For **empty columns** the drop zone STILL emits `moveTask` (with `position: 0`, not `position: 1`). Test updated in Task 2.1.1.
- For **non-empty columns** the drop zone is now a no-op (the gap handlers intercept). The test that existed was the empty-column path; if any other test asserted a non-empty drop on the drop zone, the `expect(...emitted('moveTask')...).toBeUndefined()` needs to replace `expect(...emitted('moveTask')?).toEqual(...)`.

Mitigation: all tests touching the cards drop zone are updated as a block in Task 2.1.1.

### Risk: `dataset.insertPosition ?? ''` typing bites strict TypeScript

Vue's HTML data attribute access (`element.dataset.insertPosition`) is typed as `string | undefined`. The conditional `if (Number.isFinite(position))` handles runtime — but TypeScript's `strict` mode may complain that `position` is `number | undefined` after `Number(...)` (because of the optional chaining). The fallback `?? ''` makes the type narrowing explicit.

Mitigation: Task 2.2.3 covers this — `bun run build` (which runs `vue-tsc --build`) must be clean.

### Risk: `event.currentTarget` is null when the dragend event fires asynchronously

The HTML5 DnD spec allows `currentTarget` to be null on `dragend` if the target element is removed from the DOM during the drag (e.g. by a Vue re-render triggered by the optimistic local update). The handlers defensively check `if (!target) return` before reading `target.dataset`, so this is safe at runtime.

### Risk: Double-emit on simultaneous gap + drop-zone drop

Browsers fire `drop` on the deepest element first, then bubble up. If the gap's `handleGapDrop` emits `move-task` AND the drop zone's `handleDrop` also emits (because both handlers fire), two emits could happen. Mitigation: `handleDrop` has the defensive `if (cardsInColumn.value.length > 0) return` guard so it only emits when there are no gaps (empty column).

### Risk: `dragInsertPosition` not cleared on cancel

Drag cancel (ESC, drop outside any valid target) fires `dragend` but NOT `drop`. If `dragInsertPosition` isn't reset on `dragend`, a cancelled drag would leave the violet insertion line visible. Mitigation: Task 1.1.5 implements a `handleColumnDragEndCapture` that resets `dragInsertPosition.value = null` (plus the existing `isDragging` + `isDragOver` reset), bound to `@dragend.capture` on the cards container.

---

## Related Code References

- **Frontend (files this plan modifies):**
  - `src/apps/desktop/src/components/KanbanColumn.vue` — gap rendering + handlers
  - `src/apps/desktop/src/__tests__/KanbanColumn.spec.ts` — gap tests
  - `src/apps/desktop/src/__tests__/KanbanView.spec.ts` — view-level wiring tests
- **Frontend (files NOT touched but referenced):**
  - `src/apps/desktop/src/components/KanbanCard.vue` — card wrapper (unchanged; per-card drop not implemented; gaps handle everything)
  - `src/apps/desktop/src/components/KanbanView.vue` — view-level emit pass-through (unchanged)
  - `src/apps/desktop/src/stores/workspaces.ts:876` — `moveTaskToColumn(workspaceId, itemId, taskId, columnId, position)` (unchanged)
  - `src/apps/desktop/src/api/index.ts:1124` — `moveTask(workspaceId, itemId, taskId, columnId, position)` (unchanged)
  - `src/apps/desktop/src/components/AppLayout.vue:799` — `handleKanbanMoveTask` (unchanged)
- **Backend (no changes):**
  - `src/ai_workflow/tui/kanban_model.zig:398` — `pub fn moveTask(... target_position: i64)` (already supports arbitrary positions)
  - `src/ai_workflow/tui/kanban_model_test.zig:266` — `moveTask changes column and renumbers positions` test (already proves the backend logic)
  - `src/ai_workflow/tui/migration.zig:944` — Migration051 (kanban_column_id + kanban_position columns already in place)

---

## Why Frontend-Only

The bug is purely UI-layer: the user expects position-aware drops, the backend already accepts position, the API + store + host wiring are all in place. Adding a Zig round-trip would change nothing — the data flow is `gap index → position integer → api.moveTask(... position) → moveTask API endpoint` end-to-end already.
