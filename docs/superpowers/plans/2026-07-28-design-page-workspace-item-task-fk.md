# Design Page ↔ WorkspaceItemTask 1:1 Foreign Key

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each design page gets a `workspace_item_task_id` foreign key so the page IS 1:1 with a chat task. Replace the brittle name-based `"Design Chat: <pageName>"` lookup with a direct FK resolution.

**Architecture:** Mixed backend + frontend change. Backend: new migration 066 adds `workspace_item_task_id TEXT` to `design_pages` with UNIQUE constraint + ON DELETE CASCADE FK to `workspace_item_tasks(id)`. `design_model.setDesignPage` creates the task row atomically with the page. Backfill migration provisions tasks for existing pages. Wire format gains `workspace_item_task_id`. Frontend: `handleDesignOpenChat` resolves the chat via the FK directly, dropping the legacy `"Design Chat"` migration + name-based scan.

**Tech Stack:** Zig 0.16 (backend), Vue 3 + TypeScript + Pinia (frontend), SQLite (migration). Cross-platform support: Linux + macOS + Windows.

---

## Global Constraints

- Existing cross-platform + Zig 0.16 + Vue 3 constraints from `AGENTS.md` apply unchanged.
- **Every feature must work on Linux, macOS, AND Windows.** This is a hard requirement.
- **Do NOT kill the process on port 8081** (the always-running nalar). Use 8080 for any local smoke tests.
- Use `git worktree` for parallel development. This plan targets `worktree/design-page-task-fk` (already set up).
- The project's `addColumnIfMissing` / `dropColumnIfExists` helpers in `migration.zig` handle fresh-DB vs upgrade-split correctly (see project memory `nalar-data-and-routines.md` §"Migration #009-#052 fresh-DB cascade is fragile").
- The 1:1 invariant must be enforced by the DB schema: `UNIQUE(workspace_item_task_id)` on `design_pages`. The application code is the second line of defense (validation in `setDesignPage`).
- Migration registration is in `allMigrations` slice at the bottom of `migration.zig` — adding the struct is not enough, must add to the slice (see memory `migration-registration-trap.md`).
- Pre-commit checklist from `AGENTS.md` must pass before declaring done: `zig build test --summary all`, `zig build install:linux:system`, `rm -rf zig-out/bin && zig build`, cross-compile to Windows/macOS, `bun run build` (vue-tsc), `bunx vitest run`.

---

## Design Background (read first)

### Why a FK and not a name lookup

Today, the per-page chat lookup runs as:

```ts
const perPageName = "Design Chat: " + payload.pageName
const perPageTask = (item.tasks ?? []).find((t) => t.name === perPageName)
if (perPageTask) { workspacesStore.setActiveTask(perPageTask.id); return }
// fallback: scan legacy "Design Chat" task, rename, etc.
```

This worked, but has three failure modes:

1. **Name uniqueness is not enforced.** Two pages named `"Foo"` (different items) → both share the same name, but it's user-visible as a coincidence. Inside one item, the UNIQUE constraint `idx_design_pages_item_name` already prevents duplicate names. So in practice this works for the design domain — but it's still a brittle invariant.

2. **Renames break the binding.** If the user could rename a page (not in scope yet), the chat task's name would NOT track the new page name. The FK makes the binding row-level, not text-pattern-matching-level.

3. **No DB-level cascade.** When a design page is deleted, the chat task survives as an orphan (visible in sidebar, not bound to any page). The FK with `ON DELETE CASCADE` makes this happen automatically.

### What changes

- **Schema:** new `design_pages.workspace_item_task_id TEXT` column with UNIQUE constraint + FK to `workspace_item_tasks(id) ON DELETE CASCADE`.
- **Page creation:** `setDesignPage` now also INSERTs a `workspace_item_tasks` row in the same SQLite operation (wrapped in a transaction). The new task gets `name = "Design Chat: <page_name>"`, the same naming convention the legacy code uses — so existing per-page tasks already on disk match up.
- **Page deletion:** `deletePage` now relies on FK `ON DELETE CASCADE` to clean up the task. The model function does an extra lookup to get the task_id so it can also rmdir the on-disk chat folder (none yet, but the lookup is cheap and ready).
- **Wire format:** `DesignPageResponse` gains a `workspace_item_task_id` field. Frontend's `DesignPage` interface gains the same.
- **Frontend:** `handleDesignOpenChat` is reduced to: look up `payload.page.workspace_item_task_id` → `workspacesStore.setActiveTask(id)`. No name match. No legacy migration. No message probe.
- **Backfill:** Migration 066 also iterates existing design pages and creates a fresh `workspace_item_tasks` row for each one whose `workspace_item_task_id IS NULL`. The fresh task gets `name = "Design Chat: <page_name>"` — matching the canonical name so any leftover name-pattern code (e.g., old DB browsers, future migrations) still resolve correctly.

### What does NOT change

- The legacy `"Design Chat"` migration code in AppLayout.vue is REMOVED (no longer needed — the FK makes it irrelevant).
- `workspace_item_tasks` schema is NOT changed — the table already has all the columns we need.
- The `task.id == session.id` convention stays intact — every per-page task IS its own chat session.

### Why not put `design_page_id` on `workspace_item_tasks` instead

The inverse design (column on tasks instead of on pages) would also work, but has issues:

- `workspace_item_tasks` is the table every other surface joins on (`llm_history.session_id`, `fireRoutine.task_id`, `routines.task_id`). Adding a new column there is one more index + join key to maintain.
- The pattern `tasks have design pages` reads naturally as `pages have tasks` in our system: DesignView owns pages, AppLayout owns chat lookup. The pages table is the natural home for the FK.

### Things that intentionally stay name-based

- The `workspace_item_tasks.name` value stays `"Design Chat: <page_name>"` so the user-visible sidebar entries remain readable. The name is a derived display string, not a lookup key.

---

## File Structure

Files touched by this plan:

| File | What changes |
|---|---|
| `src/migrations/migration.zig` | Add `Migration066AddDesignPageTaskFk` struct + register in `allMigrations` slice |
| `src/migrations/migration_066_test.zig` | New test file (5+ tests) |
| `src/ai_workflow/tui/design_model.zig` | `DesignPage` struct gets `workspace_item_task_id` field; `setDesignPage` wraps in tx + creates the task; `listPages`/`getPageWithElements`/`updateDesignPage` SELECT the column; `deletePage` reads + logs the FK; `freePages`/`free` updates |
| `src/ai_workflow/tui/design_model_test.zig` | New test for the FK invariant (1:1) |
| `src/ai_workflow/tui/http_handlers/http_response.zig` | `DesignPageResponse` struct + `makeDesignPageResponse` gain `workspace_item_task_id` |
| `src/ai_workflow/tui/http_handlers/design_pages_create_test.zig` | Add a contract test for the new field |
| `src/apps/desktop/src/api/index.ts` | `DesignPage` interface gains `workspace_item_task_id: string` |
| `src/apps/desktop/src/components/AppLayout.vue` | Rewrite `handleDesignOpenChat` to use the FK directly; remove `DESIGN_CHAT_TASK_NAME` constant; remove `taskHasMessages` helper; remove legacy migration code |
| `src/apps/desktop/src/__tests__/DesignChatToggle.spec.ts` | Rewrite tests for the FK-based lookup |
| `docs/SPEC.md` | Update §3.8 row to mention FK + remove "naming convention + legacy migration" framing |

No new HTTP endpoints (the existing `GET /design/pages` returns the new field; clients consume it).
No changes to `set_design_page` LLM tool — tool stays verbatim, the model does the work.

---

## Task 1 — Migration 066: add `design_pages.workspace_item_task_id` column

**Files:** `src/migrations/migration.zig`, `src/migrations/migration_066_test.zig`

**Why:** The schema has to enforce the 1:1 invariant. Column + UNIQUE index + FK are the bedrock; everything else is application logic on top.

**Steps:**

- [ ] Open `src/migrations/migration.zig` and look at `Migration065AddTaskHumanTouchedAt` (around line 2244). Add a sibling `Migration066AddDesignPageTaskFk` struct after it (using `version: u32 = 66`, `name = "add_design_page_task_fk"`).
- [ ] Inside `up()`, do all three of:
  1. `addColumnIfMissing(db, allocator, "design_pages", "workspace_item_task_id", "workspace_item_task_id TEXT")` — note: `addColumnIfMissing` requires BOTH the column name AND the type (see memory `addColumnIfMissing-requires-name-type`).
  2. `try db.exec(allocator, "CREATE UNIQUE INDEX IF NOT EXISTS idx_design_pages_workspace_item_task_id ON design_pages(workspace_item_task_id)", &[_][]const u8{});` — uniqueness for the 1:1 invariant.
  3. `try db.exec(allocator, "DROP INDEX IF EXISTS idx_design_pages_workspace_item_task_id_fk", &[_][]const u8{}); try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_design_pages_workspace_item_task_id_fk ON design_pages(workspace_item_task_id)", &[_][]const u8{});` — the FK lookup is a non-unique search (each task is at most one page, but SQLite uses the unique index for both the UNIQUE check AND the FK lookup; no need for a separate non-unique index).
- [ ] Add the FK as a recursive ALTER via `db.exec("CREATE TRIGGER ... ")` or as a recursive migration step. SQLite does NOT support adding a FK constraint via ALTER TABLE — it requires a recreate-table pattern. Use the **triggers approach** (same as the existing Migration 020 / 052 pattern): on `INSERT INTO design_pages` with non-null task_id, validate it exists in `workspace_item_tasks`; on `DELETE FROM workspace_item_tasks` CASCADE the dependent page. Skip the FK for now if it's too much; the UNIQUE index + application code is the second line of defense.
- [ ] **Decision: skip the FK for now.** The UNIQUE index + application code enforces the 1:1 invariant well enough for v1; revisit if migration friction appears. The data integrity risk is low (the only mutation path is `setDesignPage` in `design_model.zig`).
- [ ] Register the migration in the `allMigrations` slice after the 065 tuple (around line 1791):
  ```zig
  .{ .version = Migration066AddDesignPageTaskFk.version, .name = Migration066AddDesignPageTaskFk.name, .up = Migration066AddDesignPageTaskFk.up },
  ```
- [ ] Create `src/migrations/migration_066_test.zig` mirroring the pattern from `migration_065_test.zig`. Add tests for:
  - Column added (positive).
  - Idempotent on re-run.
  - Idempotent on fresh-DB install where canonical schema already has the column (declarative style — drop table + re-create with the column, run migration, assert no crash).
  - Pre-existing rows stay NULL (not '').
  - **Backfill helper test:** the migration's `backfill` step creates a task per existing page. Setup: create `design_pages(workspace_item_id, name)` rows with no `workspace_item_task_id`, run migration, assert each page now has a `workspace_item_task_id` that points to a `workspace_item_tasks` row whose name is `"Design Chat: <page_name>"`.
  - Migration is registered in `allMigrations` (the trap check — see memory `migration-registration-trap.md`).
- [ ] Run `zig build test --summary all` and confirm the 6 new tests pass.

**Verification (after Task 1 alone):**

```bash
cd /home/ginwa/ginwaaitoolbox_worktrees/design-page-task-fk
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
```

Expect: `Migration 066` tests pass; pre-existing test count unchanged (other tests still pass — column is additive).

---

## Task 2 — `design_model.zig` model layer updates

**Files:** `src/ai_workflow/tui/design_model.zig`

**Why:** The data layer needs to (a) carry the new field in the `DesignPage` struct, (b) create the task row atomically with page creation, (c) return the field from list/get, (d) look up the task_id on delete.

**Steps:**

- [ ] **Step 2.1 — struct field:** In `design_model.zig`, add `workspace_item_task_id: []u8` to the `DesignPage` struct (between `name` and `width`). Update `freePages` to also free it.
- [ ] **Step 2.2 — `setDesignPage` UPDATE branch:** Change the existing-branch UPDATE path so it does NOT touch `workspace_item_task_id` (the column is set once at create time). The current SQL is:
  ```zig
  try db.exec(allocator,
      "UPDATE design_pages SET width = ?, height = ?, updated_at = datetime('now') WHERE id = ?",
      &.{ width_str, height_str, existing_id });
  ```
  Verify it does not include `workspace_item_task_id` — good, leave it alone.
- [ ] **Step 2.3 — `setDesignPage` INSERT branch (KEY):** Wrap the INSERT + the `workspace_item_tasks` INSERT in a transaction (use `db.begin()` from `src/modules/databases/sqlite/Sqlite.zig`). Generate both ids first (use `helpers.unixTimestampNanos()` for both, suffixed with `page_` and `task_` respectively). Then in one tx:
  1. INSERT into `workspace_item_tasks` (id, name, workspace_item_id, task_type, description).
  2. INSERT into `design_pages` (id, workspace_item_id, name, workspace_item_task_id, width, height, position, created_at, updated_at).
  The task row's `name = "Design Chat: " + page_name` (the canonical per-page naming).
- [ ] **Step 2.4 — page name → task name:** Compute task name as `"Design Chat: <page_name>"` (matching the existing 2026-07-28 plan's naming). Use `std.fmt.allocPrint(allocator, "Design Chat: {s}", .{input.page_name})`. Save the slices on the local defer chain; the per-call arena in tests will reclaim at the end.
- [ ] **Step 2.5 — `listPages`:** Add `dp.workspace_item_task_id` to the SELECT and the duplicate-into-struct logic (around line 348-359 of `design_model.zig`).
- [ ] **Step 2.6 — `getPageWithElements`:** Add the same column to the single-page SELECT (around line 1003-1029).
- [ ] **Step 2.7 — `updateDesignPage`:** Add the same column to the row dupe (around line 291-296).
- [ ] **Step 2.8 — `deletePage`:** Add `workspace_item_task_id` to the JOIN/SELECT lookup at the start of the function. The current SQL JOINs `workspace_items` for context — extend it to also SELECT `dp.workspace_item_task_id`. Store the task_id in the local `Lookup` struct. After the SQL DELETE on `design_pages` succeeds, also issue a `DELETE FROM workspace_item_tasks WHERE id = ?` for the task_id (since we skipped the FK in the migration, the cascade is manual). Wrap in `try { ... } catch { /* log warning */ }` — the task deletion is best-effort (the page is gone; the task is an orphan now, no harm). Future cleanup: emit an SSE event so the chat-list sidebar refreshes.
- [ ] **Step 2.9 — `deletePage` on-disk chat folder:** (Optional, deferred — see Out of Scope.) No on-disk chat folder exists today (LLM chat persistence is in `llm_history` table, not on disk). So nothing to clean up here.
- [ ] **Step 2.10 — compile:** Run `zig build test --summary all` to verify nothing broke. Pre-existing tests in `set_design_page_test.zig` / `add_design_element_test.zig` / etc. assert on the SELECT query text — they'll need the column added too. **Fix all failing call sites** by re-running the test suite and addressing each `expected N columns found M` or `no such column: workspace_item_task_id` error.

**Verification:**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 10
```

Expect: previously-failing tests now pass (or the new model returns the additional column gracefully); pre-existing test count unchanged (no test deleted, only new assertions added).

---

## Task 3 — Wire format (`DesignPageResponse`)

**Files:** `src/ai_workflow/tui/http_handlers/http_response.zig`

**Why:** The frontend needs the new field. JSON shape is the contract.

**Steps:**

- [ ] Open `http_response.zig`, find the `DesignPageResponse` struct (around line 709).
- [ ] Add `workspace_item_task_id: []const u8` field. Place it between `workspace_item_id` and `name` to keep related fields grouped.
- [ ] Update `makeDesignPageResponse(page: anytype)` to include `.workspace_item_task_id = page.workspace_item_task_id`.
- [ ] The wire shape now includes the task id. Frontend's `DesignPage` interface needs the matching field (Task 5).

**Verification:**

```bash
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
```

Expect: clean build; the new field flows through `std.json.Stringify.valueAlloc` cleanly.

---

## Task 4 — Static-contract test for the new field

**Files:** `src/ai_workflow/tui/http_handlers/design_pages_create_test.zig`

**Why:** Lock the wire contract so future refactors don't accidentally drop the field.

**Steps:**

- [ ] Add a new contract test to `design_pages_create_test.zig`:
  ```zig
  test "design_pages_create handler response includes workspace_item_task_id field" {
      const allocator = testing.allocator;
      const source = try readSource(allocator, HANDLER_PATH);
      defer allocator.free(source);

      if (std.mem.indexOf(u8, source, "workspace_item_task_id") == null) {
          std.debug.print(
              "\n!! {s} does not reference workspace_item_task_id !!\n" ++
                  "   The wire contract requires the FK on every page create response.\n",
              .{HANDLER_PATH},
          );
          return error.WorkspaceItemTaskIdFieldMissing;
      }
  }
  ```
- [ ] Run `zig build test --summary all` and confirm the new test passes (the handler's `useCase` returns a heap-owned `DesignPage`; the response builder picks up the new field automatically).

**Verification:**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expect: 1 new test passes.

---

## Task 5 — Frontend wire format (`DesignPage` interface)

**Files:** `src/apps/desktop/src/api/index.ts`

**Why:** Mirror the backend wire change on the frontend. Without this, vue-tsc errors when accessing `page.workspace_item_task_id`.

**Steps:**

- [ ] Open `src/apps/desktop/src/api/index.ts` and find the `DesignPage` interface (around line 148).
- [ ] Add `workspace_item_task_id: string` (between `workspace_item_id` and `name`).
- [ ] Run `cd src/apps/desktop && timeout 180 bunx vitest run` — no test should fail (interface-only changes don't break tests; they break call sites that destructure fields they don't expect, which there are none here).

**Verification:**

```bash
cd src/apps/desktop
timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build 2>&1 | tail -n 10
timeout 180 bunx vitest run 2>&1 | tail -n 10
```

Expect: clean.

---

## Task 6 — Rewrite `handleDesignOpenChat` to use the FK

**Files:** `src/apps/desktop/src/components/AppLayout.vue`, `src/apps/desktop/src/__tests__/DesignChatToggle.spec.ts`

**Why:** The lookup is now a one-liner (FK resolution). Drop the legacy name matching + probe + migration code.

**Steps:**

- [ ] **Step 6.1 — AppLayout.vue:** Find the current `handleDesignOpenChat` (around line 1400-1470) and the related constants/helpers (`DESIGN_CHAT_TASK_NAME`, `PER_PAGE_CHAT_PREFIX`, `taskHasMessages`).
- [ ] **Step 6.2:** Replace the entire function body with:
  ```ts
  const handleDesignOpenChat = async (payload: {
    pageId: string
    pageName: string
  }): Promise<void> => {
    const ws = activeWorkspace.value
    const item = activeWorkspaceItem.value
    if (!ws || !item || item.item_type !== 'design') return
    if (!payload.pageId || !payload.pageName) return

    // Look up the page via the local DesignView's pages list (single
    // source of truth for active page data). The page row carries
    // the workspace_item_task_id directly — no name matching, no
    // legacy migration, no N+1 message probe.
    const page = pages.value.find((p) => p.id === payload.pageId)
    if (!page?.workspace_item_task_id) return

    workspacesStore.setActiveTask(page.workspace_item_task_id)
  }
  ```
  Note: `pages.value` is DesignView's local ref. Import it from the DesignView ref OR lift it into the store. Cleanest is to look up the page from the page row already carried by DesignView's emit (extend the emit payload to include the page row).
- [ ] **Step 6.3 — payload shape:** Update DesignView.vue's `openChat` emit so the payload includes the full `DesignPage` row (not just id + name). This eliminates the need to maintain a separate `pages` ref on AppLayout.
- [ ] **Step 6.4:** Delete the now-unused `DESIGN_CHAT_TASK_NAME` and `PER_PAGE_CHAT_PREFIX` constants (or rename to `DESIGN_CHAT_PREFIX` and keep for the task name display label only — the task creation happens in the backend now). Delete `taskHasMessages` helper — no longer needed.
- [ ] **Step 6.5:** Update the two `<DesignView @open-chat=...>` listeners in AppLayout.vue's template to pass through the new payload shape.
- [ ] **Step 6.6 — DesignChatToggle.spec.ts:** Rewrite the file to lock the new FK-based behavior. Tests:
  - 'handleDesignOpenChat uses page.workspace_item_task_id for the setActiveTask call' (regex locks source contains `page.workspace_item_task_id`).
  - 'handleDesignOpenChat does NOT use DESIGN_CHAT_TASK_NAME for lookup' (negative: assert no `tasks.find((t) => t.name === DESIGN_CHAT_TASK_NAME)` line remains).
  - 'handleDesignOpenChat does NOT use taskHasMessages probe' (negative: assert no `api.getChatHistory(` call in handleDesignOpenChat's body).
  - 'DesignView @open-chat emit includes workspace_item_task_id field' (assert the new payload is `{ pageId, workspace_item_task_id }` or includes both fields).
  - 'AppLayout forwards the @open-chat payload directly to handleDesignOpenChat on both DesignView invocations'.
- [ ] Run `bun run build` (vue-tsc + vite). Both must be clean.
- [ ] Run `bunx vitest run`. Both must be green.

**Verification:**

```bash
cd src/apps/desktop
timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build 2>&1 | tail -n 10
timeout 180 bunx vitest run 2>&1 | tail -n 10
```

Expect: vue-tsc clean, all vitest green. Specifically, the new `DesignChatToggle.spec.ts` tests pass.

---

## Task 7 — Manual smoke test against the running server

**Files:** none (manual verification only)

**Why:** Static-contract tests grep source; behavioural coverage requires a real wire-up. Verify each page gets its own chat with the right task_id, and that delete cascades.

**Steps:**

- [ ] Boot nalar on port 8080 (NEVER 8081 — see AGENTS.md):
  ```bash
  cd /home/ginwa/ginwaaitoolbox_worktrees/design-page-task-fk
  env -i HOME=/tmp/nalar-fk-smoke PATH=$PATH \
    ./zig-out/bin/nalarcore-linux-x86_64 --port 8080 &
  sleep 4
  ```
- [ ] Create a workspace:
  ```bash
  WS=$(curl -sS -X POST http://127.0.0.1:8080/api/workspaces \
    -H 'content-type: application/json' \
    -d '{"name":"fk-smoke"}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
  ```
- [ ] Create a design item:
  ```bash
  ITEM=$(curl -sS -X POST http://127.0.0.1:8080/api/workspaces/$WS/items/design \
    -H 'content-type: application/json' \
    -d '{"name":"FK Test","path":"/tmp"}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
  ```
- [ ] Create two design pages:
  ```bash
  PAGE1=$(curl -sS -X POST http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/design/pages \
    -H 'content-type: application/json' \
    -d '{"name":"First Page"}' | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["id"], d["workspace_item_task_id"])')
  echo "Page 1: $PAGE1"
  PAGE2=$(curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/design/pages" \
    -H 'content-type: application/json' \
    -d '{"name":"Second Page"}' | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["id"], d["workspace_item_task_id"])')
  echo "Page 2: $PAGE2"
  ```
  Expect: each page has its own `workspace_item_task_id` (different ids).
- [ ] List pages and verify:
  ```bash
  curl -sS http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/design/pages | python3 -m json.tool
  ```
  Expect: 2 pages, each with a `workspace_item_task_id` field.
- [ ] Verify the tasks were created:
  ```bash
  curl -sS http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/tasks | python3 -m json.tool
  ```
  Expect: 2 tasks, names `"Design Chat: First Page"` and `"Design Chat: Second Page"`, ids matching the `workspace_item_task_id` values from the pages.
- [ ] Delete one page and verify the cascade:
  ```bash
  curl -sS -X DELETE http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/design/pages/<page1_id> \
    | python3 -m json.tool
  curl -sS http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/tasks | python3 -m json.tool
  ```
  Expect: 1 page remaining, 1 task remaining (the matching task was deleted).
- [ ] Cross-platform compile smoke (verify the new schema + Zig code compiles cleanly on Windows + macOS targets):
  ```bash
  cd /home/ginwa/ginwaaitoolbox_worktrees/design-page-task-fk
  zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
    -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig 2>&1 | head -n 20
  zig build-obj -fno-emit-bin -target aarch64-macos -lc \
    -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig 2>&1 | head -n 20
  ```
- [ ] Cleanup:
  ```bash
  SMOKE_PID=$(ps aux | grep nalarcore-linux-x86_64 | grep -v grep | awk '{print $2}')
  [ -n "$SMOKE_PID" ] && kill $SMOKE_PID
  ```
- [ ] Commit: `feat(design): FK design_pages.workspace_item_task_id → workspace_item_tasks.id (1:1)`.

---

## Task 8 — Memory note + SPEC update

**Files:** `.nalar/memories/design-page-task-fk.md`, `docs/SPEC.md`

**Why:** Future agents need to know why the FK exists and what to do with it. Mirror the established memory pattern from the existing `design-chat-canonical-name-lookup-orphans-prior-chats.md` and `design-chat-per-page-sessions.md` notes.

**Steps:**

- [ ] Create `.nalar/memories/design-page-task-fk.md` with the standard structure (Symptom, Root cause, Fix, Pitfalls, Verification). Cover:
  - Why the FK replaced the `"Design Chat: <page_name>"` name lookup.
  - The 1:1 invariant (UNIQUE index + create-time pairing in `setDesignPage`).
  - Why we skipped the FK `REFERENCES` clause in the migration (SQLite ALTER TABLE can't add FKs without recreate-table; UNIQUE + application code is the second line of defense).
  - The backfill behavior (existing design pages get a fresh task row named `"Design Chat: <page_name>"`).
  - Migration registration trap (slice + struct).
- [ ] Update `docs/SPEC.md` §3.8 row to remove the "Per-page chat scoping (each design page gets a disjoint 'Design Chat: <pageName>' task) + one-shot legacy migration" framing and replace with "Per-page chat scoping via FK (design_pages.workspace_item_task_id → workspace_item_tasks.id, 1:1)". Add a new subsection §3.8.1 describing the FK architecture.
- [ ] Commit: `docs(design): FK architecture spec + memory note`.

**Verification:**

```bash
cd /home/ginwa/ginwaaitoolbox_worktrees/design-page-task-fk
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
rm -rf zig-out/bin && timeout 360 zig build 2>&1 | tail -n 5
cd src/apps/desktop
timeout 240 node node_modules/vue-tsc/bin/vue-tsc.js --build 2>&1 | tail -n 10
timeout 120 bunx vitest run 2>&1 | tail -n 10
timeout 240 bun run build 2>&1 | tail -n 20
```

Expect: all green.

---

## Out of Scope (deferred)

- **Recreate-table migration to add the FK properly.** SQLite can't ALTER TABLE ADD CONSTRAINT; this would require a transactional rename + recreate. The UNIQUE index + `setDesignPage` validation is sufficient for v1; revisit if data integrity issues emerge.
- **`task_type='design'` on `workspace_item_tasks`.** Distinguishing "design page" tasks from "kanban" tasks at the type level is a nice-to-have; the FK is the discriminator for now. Add a follow-up if other surfaces need to filter on it.
- **Per-page chat folder on disk.** The LLM chat persistence lives in `llm_history` table only — no on-disk chat folder to clean up on page delete.
- **Renaming a page → re-associating the chat.** When a page is renamed, the chat task keeps its old name (`"Design Chat: <old name>"`). The FK is by id so the binding is preserved across renames — but the display label is stale. Out of scope; same limitation as the 2026-07-28 plan.
- **Auto-cleanup of orphaned tasks.** If a user manually deletes a row from `workspace_item_tasks` (not via the page-delete endpoint), the matching `design_pages` row's `workspace_item_task_id` is now dangling. A periodic cleanup job is out of scope; the application code's INSERT into `workspace_item_tasks` (Task 2 Step 2.3) always succeeds together with the page INSERT.

---

## Reference

- Context: Kanban task `task_1785222769712` ("connect design_pages with table workspace_item_task_id") on workspace `ws_1785055733544_28e79c9db8950100`, item `item_1785055824163739523`.
- Existing related work:
  - `.nalar/memories/design-chat-canonical-name-lookup-orphans-prior-chats.md` — 2026-07-26 fix (the original single-canonical bug).
  - `.nalar/memories/design-chat-per-page-sessions.md` — 2026-07-28 frontend-only fix (per-page naming convention). Superseded by this plan for the design domain.
  - `docs/superpowers/plans/2026-07-28-design-per-page-chat-sessions.md` — the plan this one supersedes.
- Existing relevant memory files:
  - `.nalar/memories/migration-registration-trap.md` — register Migration 066 in `allMigrations`.
  - `.nalar/memories/add-skill-tool-prepends-frontmatter.md` — only relevant if I add a new SKILL.md; not needed for this plan.
  - `.nalar/memories/zig-sqlite-patterns.md` — `addColumnIfMissing` requires name + type; SQLite `SQLITE_BUSY` on transactions; etc.
  - `.nalar/memories/nalar-data-and-routines.md` §"Migration #009-#052 fresh-DB cascade is fragile" — fresh-DB vs upgrade split.
  - `.nalar/memories/zig-build-and-test.md` — `addColumnIfMissing` literal-string pitfall (no terminating `;` in `\\` raw strings).
- Existing tests:
  - `src/ai_workflow/tui/design_model_test.zig` — the `CREATE TABLE design_pages` block needs the new column added to keep the model tests working.
  - `src/ai_workflow/tui/http_handlers/design_pages_create_test.zig` — static-contract tests add a new contract for the new field.
  - `src/apps/desktop/src/__tests__/DesignChatToggle.spec.ts` — rewritten in Task 6.
- Cross-platform note: this plan touches the backend schema (Zig 0.16 + SQLite). The migration is platform-neutral. The cross-compile smoke test (Task 7) covers both Windows + macOS targets.
- Plan branch: `worktree/design-page-task-fk` (worktree at `/home/ginwa/ginwaaitoolbox_worktrees/design-page-task-fk`).
