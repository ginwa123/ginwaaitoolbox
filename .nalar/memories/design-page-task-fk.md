# Design Page ↔ WorkspaceItemTask 1:1 Foreign Key

## Symptom

The frontend's per-page chat lookup was a string pattern: build
`"Design Chat: <pageName>"`, scan `item.tasks` for a matching row,
fall back to legacy rename via `api.updateTask`. Three failure modes:

1. **Page rename broke the binding.** The task's name didn't track the
   page's name (renames of pages left a stale `"Design Chat: <oldName>"`
   task with no FK to surface the staleness).
2. **No DB-level enforcement of 1:1.** Two pages with the same name in
   different items could collide on `tasks.name` (worked in practice
   because `idx_workspace_item_tasks_item_name` was a soft contract).
3. **Deleting a page left an orphan chat task.** The task survived in
   the sidebar with no surface pointing back to the page that spawned
   it. No cascade.

## Root cause

No row-level FK between `design_pages` and `workspace_item_tasks`. The
binding was a string convention maintained in AppLayout's
`handleDesignOpenChat` (`name === perPageName`) + a one-shot legacy
rename on first 💬 click.

## Fix (1:1 FK)

Plan: `docs/superpowers/plans/2026-07-28-design-page-workspace-item-task-fk.md`

| Layer | Change |
|---|---|
| **Schema** | `Migration066AddDesignPageTaskFk` adds `design_pages.workspace_item_task_id TEXT` (nullable) + `idx_design_pages_workspace_item_task_id` UNIQUE index. Backfills every existing page with a fresh `workspace_item_tasks` row named `"Design Chat: <page_name>"`. |
| **Model** | `design_model.setDesignPage` now creates a fresh `task_<unix_nanoseconds>` row BEFORE the `design_pages` INSERT (same transaction shape — two `db.exec` calls, no SQL transaction wrapping because each statement commits atomically on the connection). |
| **Wire** | `DesignPageResponse` gains `workspace_item_task_id` field. |
| **Delete** | `design_model.deletePage` reads the FK from the JOIN lookup and DELETEs the paired `workspace_item_tasks` row manually (the migration intentionally skipped the SQL `REFERENCES` clause — see "FK constraint intentionally omitted" below). |
| **Frontend** | `AppLayout.handleDesignOpenChat` is now a one-liner: `workspacesStore.setActiveTask(page.workspace_item_task_id)`. Removed: `DESIGN_CHAT_TASK_NAME` + `PER_PAGE_CHAT_PREFIX` constants, `taskHasMessages` helper, legacy rename via `api.updateTask`, create-via-`workspacesStore.addTask`. |

## FK constraint intentionally omitted

SQLite does NOT support `ALTER TABLE … ADD CONSTRAINT FOREIGN KEY …`.
The canonical alternatives (BEFORE INSERT trigger + ON DELETE
CASCADE trigger, or recreate-table) both add complexity that's out of
scope for v1. The UNIQUE index + application-level validation in
`setDesignPage` is the second line of defense; revisit if migration
friction appears.

The 1:1 invariant is enforced by:

1. `UNIQUE(workspace_item_task_id)` index on `design_pages` (DB-level).
2. `setDesignPage` always pairs a fresh task with a new page INSERT
   (application-level). Re-INSERT on a duplicate `(item_id, name)`
   updates the existing page (no INSERT); the workspace_item_task_id
   stays as-is from the original pair.
3. `deletePage` cascades the task DELETE manually after the page DELETE
   succeeds.

## Per-page naming convention preserved

Tasks are still named `"Design Chat: <page_name>"` so the user-visible
sidebar entries remain readable. The naming is a derived display string,
not a lookup key.

## Migration registration trap

`Migration066AddDesignPageTaskFk` is defined in `migration.zig` AND
registered in `allMigrations` slice (line 1797 in the worktree).
Static tests pass with the struct defined but the slice missing — see
project memory `migration-registration-trap.md` for the trap.

The test file `migration_066_test.zig` includes a `Migration066 is
registered in allMigrations` test that catches future refactors that
remove the registration tuple.

## Why this design (vs the alternatives)

- **Why not `design_page_id` column on `workspace_item_tasks`?** That
  table is joined by every LLM-related surface (`llm_history.session_id`,
  `fireRoutine.task_id`, `routines.task_id`, all `/api/llm/session/...`
  routes). Adding a column there is more index/join key to maintain.
  Pages are owned by DesignView; tasks are owned by AppLayout. The
  "ownership" direction favors putting the FK on `design_pages`.

- **Why eager task creation (not lazy on 💬 click)?** The FK intent is
  "every page has a task". Lazy creation defeats the FK by leaving it
  NULL until first use. Eager creation = `UNIQUE` constraint is always
  meaningful. Tasks created before user clicks 💬 show up in the
  Chats sidebar as `Design Chat: <page_name>` (empty) — that's fine;
  the user opens it via the design canvas, not via the Chats list.

## Pitfalls

- **Migration tests' `setupDb()` must create `workspace_item_tasks`.**
  `setDesignPage` now INSERTs into this table; tests that don't create
  it fail with `no such table: workspace_item_tasks`. Updated 9 test
  fixtures (each `CREATE TABLE design_pages …` block now has a paired
  `CREATE TABLE workspace_item_tasks …` and a `workspace_item_task_id
  TEXT` column on `design_pages`).

- **Test fixtures need the `workspace_item_task_id` column declared on
  the `design_pages` CREATE TABLE.** `listPages` selects the column;
  `getPageWithElements` selects it; `updateDesignPage` selects it.
  Missing column → `no such column: dp.workspace_item_task_id`.

- **`PageWithElements.deinit` must free `workspace_item_task_id`.**
  Easy to miss since it's a new field. Forgetting it leaks the slice.

- **`DesignPageResponse` struct field order matters for `std.json.Stringify.valueAlloc`.**
  The frontend's `DesignPage` interface field order doesn't matter,
  but the backend struct does (output order). Place `workspace_item_task_id`
  next to `workspace_item_id` for readability.

- **The handler's `setActiveTask` payload type changed.** Three callers
  (`<DesignView @open-chat=...>` listeners) need to forward the
  full `(pageId, pageName, workspaceItemTaskId)` payload. `vue-tsc`
  catches this with "expected N arguments, found M".

- **Static-contract test for "FK on the wire" must check the response
  struct file, not the handler file.** The handler delegates to
  `makeDesignPageResponse(page)` in `http_response.zig` — the field
  is declared there, not inline. Grep `workspace_item_task_id` in
  EITHER `design_pages_create.zig` OR `http_response.zig`.

## Verification

```bash
# Static tests
cd /home/ginwa/ginwaaitoolbox_worktrees/design-page-task-fk
timeout 180 zig build test --summary all
# 1950/1956 pass (6 skipped, 0 failed)

# Build
rm -rf zig-out/bin
timeout 240 zig build install:linux:system
# 86 MB binary at zig-out/bin/nalar (the cp-to-/usr/local/bin/nalar
# permission error is expected and harmless)

# Live smoke test
HOME=/tmp/nalar-fk-smoke setsid -f zig-out/bin/nalar --port 8080 > /tmp/smoke.log 2>&1 < /dev/null
sleep 6
WS=$(curl -sS -X POST http://127.0.0.1:8080/api/workspaces \
  -H 'content-type: application/json' -d '{"name":"fk-smoke"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
ITEM=$(curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/design" \
  -H 'content-type: application/json' \
  -d '{"name":"FK Test","path":"/tmp"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/design/pages" \
  -H 'content-type: application/json' -d '{"name":"First Page"}' | python3 -m json.tool
# Expect: response includes "workspace_item_task_id": "task_<...>"
curl -sS "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/design/pages" | python3 -m json.tool
# Expect: 2 pages, each with its own workspace_item_task_id
curl -sS "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/tasks" | python3 -m json.tool | head -n 20
# Expect: 2 tasks, names "Design Chat: First Page" and "Design Chat: Second Page"
curl -sS -X DELETE "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/design/pages/<page_id>"
# Expect: {"success":true}; subsequent GET shows 1 page + 1 task (cascade worked)

# Frontend
cd src/apps/desktop
ln -s /home/ginwa/ginwaaitoolbox/src/apps/desktop/node_modules .
timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build
timeout 180 node_modules/.bin/vitest run
# 1520/1520 pass
rm node_modules

# Cleanup
pkill -f "nalar --port 8080"
```

## Reference

- Plan: `docs/superpowers/plans/2026-07-28-design-page-workspace-item-task-fk.md`
- Migration: `Migration066AddDesignPageTaskFk` in `src/migrations/migration.zig`
- Model: `design_model.setDesignPage` (inserts task before page) +
  `design_model.deletePage` (cascades task DELETE)
- Frontend: `AppLayout.handleDesignOpenChat` (one-liner via FK) +
  `DesignView.handleOpenChat` (emit payload includes `workspaceItemTaskId`)
- Test file: `src/migrations/migration_066_test.zig` + `src/apps/desktop/src/__tests__/DesignChatToggle.spec.ts`
- Branch: `worktree/design-page-task-fk`
- Commit: 4 commits — migration, model + tests, wire + delete cascade + static-contract, frontend handler + tests + bugfix
