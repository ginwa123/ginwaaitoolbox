# Kanban — restore per-column sort independence (client-side sort comparator)

## Symptom (user report, task_1785730557641)

User picks "Name (Z→A)" in the **"in progress"** column's ⋮ menu →
Sort tasks… modal. The DevTools Network panel shows 5 parallel
requests, one per column, ALL carrying
`sort_by=name&direction=desc`. Result: every column's cards render
in `name Z→A` order, NOT just the column the user picked.

User feedback:
- *"sort not indepedence per column, the goal should independecen
  per sort column"*
- *"when i click sort it affected all"* (with DevTools screenshot
  showing `sort_by=name&direction=desc` on every column's fetch)

## Root cause

Commit `0ed7582d` ("feat(frontend): kanban VirtualScroller +
default-sort URL behavior", 2026-08-06) removed the client-side
`.sort()` call in `KanbanColumn.cardsInColumn` AND deleted the
`compareBySortMode` comparator. The justification at the time:

> User feedback (2026-08-06): "i remove that and its become better" —
> removed the client-side .sort() in cardsInColumn (the comparator
> function is now deleted; backend ORDER BY is the single source of
> visual order).

The removal broke per-column independence. The backend's
`listWorkspaceItemTasksWithCursor` only accepts ONE `sort_field` /
`sort_direction` per request (see `llm_history.zig:3962-3976`), so
every column receives its tasks in the SAME global order.

`fetchKanbanTasksForAllColumns` (workspaces.ts:1302) is correct in
that it fetches each column in parallel — but every parallel fetch
gets the SAME `sortBy` / `direction` from the caller. The caller
(KanbanView.vue:442-471) takes the LAST-changed entry from
`columnSorts` and passes it as the global sort. So picking "Name
(Z→A)" in column A causes column B (Manual) to also be re-fetched
in `name Z→A` order.

Without a client-side re-sort in `cardsInColumn`, column B displays
in `name Z→A` order — a regression of the per-column independence
the original feature (commits `77482f07` + `c26244fc` +
`125bdfd0` + `a2a51193` + `71e62403` + `26023563` + `bb536899`)
shipped.

## Fix (surgical)

Re-add the client-side sort comparator in
`KanbanColumn.vue::cardsInColumn`. The architecture becomes:

1. **Backend**: each column fetch goes out with the LATEST changed
   sort (current behaviour — single `sortBy` / `direction` URL
   param). This guarantees the wire data is "best ordered for the
   user most recently expressed intent".
2. **Frontend**: each `KanbanColumn.cardsInColumn` applies its own
   local `sortBy` + `direction` to the incoming tasks. Two columns
   with different sorts display differently, even though they were
   fetched with the same wire order.

This is the original architecture from `77482f07`. The comparator
deleted in `0ed7582d` is restored verbatim — `name` (BINARY
collate), `created_at` / `updated_at` (Date → ISO string), with
`kanban_position asc` as the tiebreaker for stable ordering across
equal sort-field values.

### Why the backend fetches with ONE sort

We don't change `fetchKanbanTasksForAllColumns` (the caller passes
one sort, every column gets it). Two reasons:

1. **The backend can only sort by one criterion per request** (one
   `ORDER BY` clause, no per-column override).
2. **Per-column fetches with DIFFERENT sorts** would mean N backend
   round-trips per sort change — wasteful when the user only changed
   one column. The client-side re-sort makes a single fetch
   sufficient.

### Why the client's per-column sort is independent of the backend

The wire returns tasks in whatever order the backend's
`ORDER BY` produces (default `updated_at desc` when no sort, or
the user's last-picked sort). The client's `cardsInColumn`
`.sort()` runs over that wire array and produces the column's
locally-desired order. The two are independent — picking
"name Z→A" on column A does NOT change column B's wire order in
any meaningful way (both got the same wire order), but column B's
client-side re-sort still applies `position asc` because that's
column B's local state.

## Files

### Modify
- `src/apps/desktop/src/components/kanban/KanbanColumn.vue`
  - Restore the `.sort()` call in `cardsInColumn`
  - Restore the `compareBySortMode` function
  - Update the doc comment block on `cardsInColumn` (the current
    comment still references "the sort applies the per-column
    sortBy + direction FIRST" but does nothing)
  - Update the `sortChange` emit doc comment (remove the "client-
    side comparator is gone" note)
  - Update the `compareBySortMode` REMOVED comment block → restore
    the actual function

- `src/apps/desktop/src/components/kanban/KanbanColumn.vue` — emit
  doc: `sortChange` already says "client-side comparator is gone" —
  remove that line (the comparator is back).

- `src/apps/desktop/src/__tests__/KanbanColumn.spec.ts` — the test
  at line 99 ("renders cards in input order (client-side sort
  removed 2026-08-06 — backend drives ORDER BY via the URL sorts=
  param)") currently asserts input order. Rewrite to assert
  `kanban_position asc` order (the default Manual sort).

### Add
- `src/apps/desktop/src/__tests__/KanbanColumn.sortIndependence.spec.ts`
  — new behavioural tests (the deleted
  `KanbanColumn.sortMenu.spec.ts` is the prior art; restore the
  per-column sort tests, drop the modal tests since the modal flow
  is already tested in `KanbanSortMenu.spec.ts` and the new
  `KanbanColumn.virtualScroller.spec.ts`).

  Cases:
  1. Default sort = `position asc` (kanban_position order).
  2. `name asc` → A→Z order.
  3. `name desc` → Z→A order.
  4. `created_at desc` → newest-first order.
  5. `updated_at asc` → oldest-first order.
  6. Same sort-field value → `kanban_position asc` tiebreaker.
  7. **Independence (the bug case)**: two columns with different
     sorts render differently. Critical regression test.
  8. Setting sort back to `position` restores `kanban_position asc`.
  9. `setSortMode(sortBy, direction)` via `defineExpose` is the
     test seam.
  10. `sortChange` emit fires on every sort change (parent needs
      it for URL persistence + re-fetch).

## Verification

- `bun run build` — vue-tsc clean.
- `bunx vitest run src/__tests__/KanbanColumn.sortIndependence.spec.ts`
  — all 10 tests pass.
- `bunx vitest run` (full suite) — should keep
  2016-pass / 12-fail baseline (the 12 are pre-existing on main,
  unrelated to this fix).
- Live smoke on port 8080: pick "Name (Z→A)" in column A, leave
  column B on Manual. Verify:
  - Column A displays tasks in name Z→A order.
  - Column B displays tasks in `kanban_position asc` order.
  - Network panel shows ONE `sort_by=name&direction=desc` batch
    (one request per column, but they all carry the same sort —
    because the backend can only honour one sort per request;
    per-column visual order is restored client-side).
  - Repeat in reverse: pick Manual in A and Name (Z→A) in B.
    Columns display with their INDEPENDENT sorts.

## Pitfalls

- **Don't remove the `fetchKanbanTasksForAllColumns` sort param**.
  The backend sort is still useful — it ensures the wire data is
  in the user's most-recently-expressed order (e.g. the user picks
  "Name (Z→A)" in column A — the wire is now in `name Z→A` order,
  which is what the user expects for column A; the client-side
  re-sort overrides for column B back to Manual).
- **The tiebreaker is `kanban_position asc`, not `id asc`**. The
  backend's tuple pagination uses `(sort_field, id)`, but
  `kanban_position` is the user-visible "drag-reorder position"
  — keeping the tiebreaker here matches the pre-removal behaviour
  (commit `77482f07`'s implementation) AND the user's mental model
  ("when two tasks have the same name, the one I dragged up first
  is on top").
- **Watch the `cardsInColumn` watcher** (for pagination auto-fetch):
  it watches `[cardsInColumn, moreTasksAvailable, loadingMoreTasks,
  scrollerIsScrollable]`. The `cardsInColumn` length doesn't
  change when we add the sort back (we still filter to the same
  count), so the watcher won't re-fire spuriously. Confirmed by
  reading the watcher — its triggers are `.length`, not the order.
- **The `setSortMode` `defineExpose` seam** must stay — URL
  restore in KanbanView calls it on mount. Existing tests use it.
- **The backend `ORDER BY` already supports all 4 fields × 2
  directions** (per `llm_history.zig:3962-3976`). No backend
  changes needed. Confirmed with the user: *"sort logic is
  already in backend"*.

## Out of scope

- Per-column `sortBy` URL persistence (already done — `?sorts=
  col_X:<field>:<direction>,...`).
- Per-column API fetch with DIFFERENT sorts (would mean N round-
  trips; client-side re-sort is sufficient and cheaper).
- Changing the tiebreaker from `kanban_position` to `id` (no user
  request for this; `kanban_position` matches the original
  behaviour).

## Related memory

- `kanban-lazy-load-tasks` — the auto-fetch watcher on
  `cardsInColumn.length` is preserved (length doesn't change with
  sort).
- `vue-3-virtual-scroller-reactive-scrollability` — VirtualScroller
  re-renders correctly when the input array reference changes
  (the `.slice().sort()` produces a new array).

## Branch

`worktree/kanban-sort-independence` (worktree created at the
start of this task).