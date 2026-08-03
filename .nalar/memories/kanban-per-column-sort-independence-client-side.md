# Kanban per-column sort independence — backend can only sort one way

## Symptom

User picks "Name (Z→A)" in one column's ⋮ menu → Sort tasks…
modal. DevTools Network panel shows ALL columns receiving
`sort_by=name&direction=desc` in parallel. Every column renders in
`name Z→A` order, NOT just the column the user picked.

User feedback (task_1785730557641):
- *"sort not indepedence per column"*
- *"when i click sort it affected all"*

## Root cause

The backend's `listWorkspaceItemTasksWithCursor`
(`src/ai_workflow/tui/llm_history.zig:3933-4006`) accepts ONE
`sort_field` + `sort_direction` per request. The SQL `ORDER BY`
clause is global. There is no per-column sort in the wire shape.

Frontend architecture assumption: "backend ORDER BY is the single
source of visual order" — this is WRONG for per-column
independence. If column A picks `name desc` and column B stays on
Manual, the frontend must NOT depend on the backend's wire order
to render them differently. The frontend needs a client-side
re-sort.

## Fix pattern (client-side comparator)

`KanbanColumn.cardsInColumn` applies the local sortBy + direction
to the incoming `props.tasks`, then `kanban_position asc` as the
tiebreaker:

```ts
const cardsInColumn = computed<Task[]>(() => {
  return props.tasks
    .filter((t) => t.kanban_column_id === props.column.id)
    .slice()
    .sort((a, b) => {
      const cmp = compareBySortMode(a, b, sortBy.value, direction.value)
      if (cmp !== 0) return cmp
      const ap = a.kanban_position ?? Number.MAX_SAFE_INTEGER
      const bp = b.kanban_position ?? Number.MAX_SAFE_INTEGER
      return ap - bp
    })
})
```

The comparator handles:
- `position` → returns 0 (let tiebreaker drive, gives kanban_position asc).
- `name` → BINARY collate (matches SQL ORDER BY without LOWER()).
- `created_at` / `updated_at` → Date → ISO string for deterministic compare.

## What you DON'T change

- `fetchKanbanTasksForAllColumns` keeps its single `sortBy` /
  `direction` param. N parallel requests per column with N
  different sorts would mean N round-trips — wasteful when the
  client-side re-sort makes one fetch sufficient.
- The backend's `listWorkspaceItemTasksWithCursor` — already
  supports all 4 fields × 2 directions. No backend changes needed.

## Why the user-reported "i remove that and its become better" was a trap

Commit `0ed7582d` (2026-08-06, VirtualScroller + URL sort) removed
the `.sort()` based on a single-column feedback. The user later
discovered the regression when they actually had multiple columns
with different sorts. The lesson:

- When the user reports a SINGLE-COLUMN issue, don't remove
  PER-COLUMN features globally.
- The regression test is "two columns with different sorts render
  differently" — not "cards render in input order". The old test
  asserted input order, which silently passed on the buggy code.

## Files

- `src/apps/desktop/src/components/kanban/KanbanColumn.vue` —
  restore the `.sort()` + `compareBySortMode`.
- `src/apps/desktop/src/__tests__/KanbanColumn.sortIndependence.spec.ts`
  — NEW, 11 behavioural tests including the critical
  per-column-independence regression test.
- `src/apps/desktop/src/__tests__/KanbanColumn.spec.ts` — rewrite
  the "renders cards in input order" test to assert
  `kanban_position asc` instead.
- Plan: `docs/superpowers/plans/2026-08-06-kanban-sort-independence.md`.

## Branch / commit

- Branch: `worktree/kanban-sort-independence`
- Commit: `911e6647` (+ follow-up `7ab9ef17` for AGENTS.md)
- Task: `task_1785730557641`
