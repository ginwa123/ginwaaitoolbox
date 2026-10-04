# Kanban table extraction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **⛔ DO ALL WORK IN A GIT WORKTREE — never on `main`.** See **Task 0 — Worktree setup** below for the exact command. Project convention: every feature/refactor ships via a PR from `worktree/<topic>`. The kanban column on the "sprint bulan juni" board reflects `merged` only after the user merges the PR.

**Goal:** Move the two kanban-specific columns (`kanban_column_id`, `kanban_position`) off the universal `workspace_item_tasks` table into a dedicated `kanban` join table. Pure restructuring — the API wire format (`Task.kanban_column_id`, `Task.kanban_position`) is **unchanged**, so the frontend stores/components/SSE handlers stay byte-for-byte the same.

**Architecture:** One new SQLite table `kanban` (1:1 with `workspace_item_tasks` via `workspace_item_task_id` PK), one new migration (Migration 072), surgical update to every SQL site that reads/writes `workspace_item_tasks.kanban_column_id` or `kanban_position` to instead LEFT JOIN `kanban`. All changes confined to backend (`src/ai_workflow/tui/kanban_model.zig`, `src/ai_workflow/tui/llm_history.zig`, `src/ai_workflow/tui/http_handlers/task_*.zig`, `src/ai_workflow/tui/http_handlers/tasks_*.zig`, `src/ai_workflow/tui/agentic_loop/*.zig`, `src/ai_workflow/tui/on_event_sent_kanban.zig`). Frontend `.spec.ts` fixtures unchanged.

**Tech Stack:** Zig 0.x (bundled sqlite), Vue 3 + TypeScript (untouched), Vitest, Zig test runner.

---

## Background — why we're doing this

`workspace_item_tasks` is the universal table for **all** task kinds (chat, routine, kanban). Over time it has accreted many task-attribute columns (`description`, `tags`, `image_urls`, `cwd`, `last_human_touched_at`, …) and exactly **two** kanban-board-placement columns (`kanban_column_id`, `kanban_position`). The task-attribute columns are properly task-scoped (any task can have them); the placement columns are different — they only exist when a task is on a kanban board, and they pull "this task belongs to column X at position Y" data into a table that's otherwise kanban-unaware.

Extracting the placement data into a `kanban` join table:

1. Makes `workspace_item_tasks` smaller and more focused (it no longer holds board-placement state).
2. Makes the kanban data model explicit — there's now a 1:1 table row per kanban-board card, foundable by `SELECT * FROM kanban k WHERE k.workspace_item_task_id = ?`.
3. Lets future kanban-specific fields be added next to the column/position data without touching the universal table (e.g. a future `kanban.color` or `kanban.due_date`).
4. Keeps the wire format stable: the API response still has `kanban_column_id` + `kanban_position` on every Task, populated via a `LEFT JOIN kanban k ON k.workspace_item_task_id = t.id` (NULL when the task is not on a kanban).

The trade-off (acknowledged): a few SQL queries change shape. None of those queries are user-observable; the migration is invisible to the frontend because the wire format doesn't change.

---

## Design Decisions (review before execution)

| ID | Decision | Why | Alternative rejected |
|----|----------|-----|----------------------|
| D1 | **`kanban` is a join table**, 1:1 with `workspace_item_tasks` via `workspace_item_task_id` PRIMARY KEY | A kanban card belongs to exactly one task. Composite PK `(workspace_item_task_id, kanban_column_id)` adds nothing. | EAV-style wide table, json column, or putting `kanban_column_id` + `position` back on a `task_metadata` TEXT — over-engineering. |
| D2 | `kanban_column_id` is **NOT NULL** in `kanban` (nullable-ness moves OUT of the FK) | A row in the `kanban` table IS a "task is on a kanban" assertion. Tasks NOT on a kanban have no row at all, which is equivalent to `IS NULL` and easier to reason about. | Keeping `kanban_column_id` nullable in `kanban` adds a redundant state (`row exists with NULL column_id` ≡ task unassigned). |
| D3 | `ON DELETE CASCADE` on `workspace_item_task_id` FK → `workspace_item_tasks(id)` | Deleting a task should drop its kanban-card row automatically. Matches the existing semantics of `task_delete.zig` (which today does nothing kanban-specific; relies on the FK relationship). | `ON DELETE SET NULL` on `workspace_item_task_id` — orphans card rows; `ON DELETE RESTRICT` — breaks task delete. |
| D4 | `ON DELETE SET NULL` on `kanban_column_id` FK → `kanban_columns(id)` | Matches the existing `deleteColumn` contract in `kanban_model.zig:301` (`UPDATE workspace_item_tasks SET kanban_column_id = NULL WHERE kanban_column_id = ?`). After the migration, deleting a column drops card rows' column reference; the model layer then NULLs `kanban_column_id` on `kanban` rows in one statement (replaces the old `UPDATE` on `workspace_item_tasks`). | `ON DELETE CASCADE` on column FK — destroys card rows when a column is deleted (loses data the user can recover via "unassigned"). |
| D5 | **Wire format preserved** (`Task.kanban_column_id`, `Task.kanban_position` still on every JSON task) | Frontend stores (`kanbanStore`, `workspacesStore`), components (`KanbanView`, `KanbanColumn`, `WorkspaceItemTaskCard`), SSE channels, and ~30 `.spec.ts` fixtures all read these two fields. Preserving the wire shape keeps the change invisible to the frontend. | Rename JSON fields to `column_id`/`position` — requires touching every frontend file and breaks in-flight branches. |
| D6 | **Migration wraps CREATE + INSERT + DROP in a single `BEGIN…COMMIT`** | SQLite auto-commits each statement. A crash between `INSERT INTO kanban` and `ALTER TABLE … DROP COLUMN` would strand a half-state where the new table has data AND the old columns exist. The transaction guarantees either both succeed or both roll back. | Per-statement auto-commit — leaves the DB in an inconsistent state on crash. |
| D7 | **Migration is forward-only, no down-migration** | Matches every existing migration in this project (see Migrations 051, 062, 067, 069, 071). The git history of `migration.zig` is the rollback — revert the commit. | Adding `down` — out of project convention; doubles maintenance. |
| D8 | `kanban_position` keeps `NOT NULL DEFAULT 0` semantics in the new table | Existing rows with `kanban_position = 0` (the NOT NULL default applied during Migration 051) preserve their position. No re-numbering on migration — dense 0..N-1 per column is preserved. | Re-numbering on migration — overkill; no user-visible benefit; risks non-deterministic ordering on concurrent writes. |
| D9 | **Index `idx_kanban_column_position` replaces `idx_tasks_column_position`** with identical shape `(kanban_column_id, kanban_position)` | Same query pattern (per-column ordering). The old index becomes dead weight after `DROP COLUMN` and must be dropped to avoid writing to a never-read index. | Keeping the old index "just in case" — wastes writes. |
| D10 | Single new column on `kanban`: `created_at DATETIME DEFAULT CURRENT_TIMESTAMP` | Future-proofs ordering/caching; cheap. Mirrors `kanban_columns.created_at`. Optional; no code reads it yet. (Could also do without — YAGNI. RECOMMEND OMIT for v1.) | Add `updated_at` too — no use case yet, defer. |
| D11 | **`migration.zig` in-file canonical CREATE TABLE** for `workspace_item_tasks` does NOT gain a `kanban` reference — fresh-DB users still create the same minimal schema, then Migration 072 runs | The canonical schema is "the shape right before any migrations would run" — fresh-DB users walk migrations 001 → 072 in order, and Migration 072 is what creates `kanban`. Mirrors how `description` was added in Migration 062. | Modifying the canonical CREATE TABLE — out of project pattern; needs careful conditional logic for "fresh DB" vs "migrating DB". |

> **RECOMMEND D10 OMITTED for v1** — just `workspace_item_task_id`, `kanban_column_id`, `kanban_position`. Add `created_at` later if needed.

---

## Global Constraints

- **Cross-platform**: every change MUST work on Linux, macOS, AND Windows. The migration uses portable SQLite (`ALTER TABLE … DROP COLUMN` requires SQLite ≥3.35 — bundled sqlite is recent).
- **No static-contract tests**: ALL tests are behavioural. No `expect(source).toContain(...)` patterns. See `~/.config/pabrik/memories/static-contract-test-when-to-prefer-behavioural.md`.
- **TDD discipline**: every implementation step starts with a failing test, then minimal code to make it pass, then a commit.
- **`bun run build` IS the type-check**: every frontend commit must pass `bun run build`; `bunx vitest run` alone does NOT catch type errors.
- **Behavioural Zig tests** use the `db:test_pattern` established by Migration 062/071/069/067 test files (see `src/migrations/migration_062_test.zig`).
- **No port 8081**: smoke tests use port 8080.
- **NO new comments above `logger.infoFmt(...)` calls** (see `~/.config/pabrik/memories/no-comments-on-logger-calls.md`).
- **Migration registration** — the new migration struct MUST be added to the `allMigrations` slice in `src/migrations/migration.zig` or it becomes a silent-skip bug (see project memory `migration-registration-trap`).
- **Idempotency** — `addColumnIfMissing` is used for fresh-DB canonical schema that already declares the column (matches Migration 062/067/069/071 pattern). For DROP operations use raw `ALTER TABLE … DROP COLUMN` since the migration only drops columns it itself added.

---

## Target schema

### Before (current, after Migration 071)

```sql
CREATE TABLE workspace_item_tasks (
    id TEXT PRIMARY KEY,
    name TEXT,
    workspace_item_id TEXT,
    -- ... ~16 other task-attribute columns ...
    kanban_column_id TEXT,              -- ← moves to kanban table
    kanban_position INTEGER NOT NULL DEFAULT 0,  -- ← moves to kanban table
    -- ...
);
CREATE INDEX idx_tasks_column_position
    ON workspace_item_tasks(kanban_column_id, kanban_position);
```

### After (Migration 072)

```sql
CREATE TABLE workspace_item_tasks (
    id TEXT PRIMARY KEY,
    name TEXT,
    workspace_item_id TEXT,
    -- ... ~16 other task-attribute columns, SAME as before ...
    -- kanban_column_id REMOVED
    -- kanban_position REMOVED
    -- ...
);

CREATE TABLE kanban (
    workspace_item_task_id TEXT PRIMARY KEY,                 -- 1:1 with workspace_item_tasks.id
    kanban_column_id TEXT NOT NULL,
    kanban_position  INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (workspace_item_task_id)         REFERENCES workspace_item_tasks(id) ON DELETE CASCADE,
    FOREIGN KEY (kanban_column_id) REFERENCES kanban_columns(id)     ON DELETE SET NULL
);
CREATE INDEX idx_kanban_column_position
    ON kanban(kanban_column_id, kanban_position);
```

### Wire format (UNCHANGED)

`Task` JSON shape on HTTP `GET /api/.../tasks` and on SSE `kanban_task` events stays exactly the same:

```jsonc
{
  "id": "task_xxx",
  "name": "...",
  // ... 20 task-attribute fields ...
  "kanban_column_id": "col_xxx",  // nullable in JSON, populated via LEFT JOIN
  "kanban_position": 3
}
```

The Task struct in `llm_history.zig` keeps fields `kanban_column_id: ?[]u8 = null` and `kanban_position: i64 = 0`. The list queries get a `LEFT JOIN kanban k ON k.workspace_item_task_id = t.id` to populate them.

---

## File Structure

```
src/migrations/
├── migration.zig                                     # ADD struct Migration072 + register in allMigrations
├── migration_072_test.zig                            # NEW — behavioural tests
├── mod.zig                                           # UNCHANGED
└── test_runner.zig                                   # ADD `migration_072_test.zig` import line

src/ai_workflow/tui/
├── kanban_model.zig                                  # 4 SQL sites: deleteColumn, countTasksInColumn, moveTask
├── llm_history.zig                                   # 2 SELECT sites: Task JSON serialize + WHERE filter
├── http_handlers/
│   ├── task_create.zig                               # 3 SQL sites: kanban auto-assign INSERT, re-read SELECT
│   ├── tasks_list.zig                                # 1 SQL filter site (column_id WHERE)
│   ├── task_update.zig                               # 0 SQL sites for kanban placement (description/tags/cwd only)
│   └── task_delete.zig                               # VERIFY (no change needed — CASCADE handles it)
├── agentic_loop/
│   ├── prompts_build_messages_for_agent_prompt.zig           # reads kanban_column_id (system-prompt context)
│   ├── build_messages_for_agent_prompt_test.zig      # fixture has kanban_column_id in CREATE TABLE
│   ├── build_messages_for_agent_prompt_design_canvas_test.zig  # same
│   ├── build_messages_for_agent_prompt_filtering_tools_test.zig  # same
│   ├── prompts_make_kanban_context.zig               # reads kanban_column_id (per-task prompt)
│   └── tools_equipped.zig                            # doc-comment mentions columns (no code change)
├── kanban_model_test.zig                             # fixtures: 6 sites with kanban_column_id in CREATE TABLE
├── kanban_copy_spec_test.zig                         # 1 site with kanban_column_id in CREATE TABLE
├── llm_history_notification_test.zig                 # 1 site with kanban_column_id in CREATE TABLE
├── llm_history_description_test.zig                  # VERIFY (uses description but not kanban placement)
├── on_event_sent_kanban.zig                          # VERIFY (payload unchanged — wire compatibility)

src/apps/desktop/src/  (NO CHANGES — wire format preserved)
```

**Test fixtures rule:** any `*_test.zig` that hand-rolls a `workspace_item_tasks` CREATE TABLE for unit-test purposes needs its `kanban_column_id` + `kanban_position` columns removed AND a matching `kanban` table added — otherwise the helpers' `INSERT INTO workspace_item_tasks (..., kanban_column_id, kanban_position)` lines crash with "no such column".

---

## Risks & breaking changes analysis (D-series already covers design; this is what we're protecting against)

| # | Risk | Mitigation |
|---|------|-----------|
| R1 | **Frontend breaks**: 30+ `.spec.ts` files construct `{ kanban_column_id, kanban_position }` literals | Wire format preserved — none of these fixtures need to change |
| R2 | **Migration crashes on drop**: pre-Migration-051 DBs have `kanban_column_id` INDEX but column may not exist on deeply old DBs | `DROP INDEX IF EXISTS` + `dropColumnIfExists` — both helpers exist (Migration 052 pattern) |
| R3 | **Mid-migration crash** leaves DB in inconsistent state | Wrap `CREATE kanban` + backfill INSERT + `DROP COLUMN` in `BEGIN…COMMIT` |
| R4 | **Concurrent writes during migration** — agent runs while migration is happening | SQLite serializes writers; readers see the old schema for the duration of `BEGIN…COMMIT`. Migration holds a write lock — non-issue in single-process project |
| R5 | **`ON DELETE SET NULL` semantics shift**: today, deleting a kanban column nulls `kanban_column_id` on tasks. After: deleting a column triggers FK ON DELETE SET NULL on `kanban.kanban_column_id`. The TASK itself is untouched. Net effect: same observable behavior. | Verify with a behavioural test in Task 5. |
| R6 | **`workspace_items` row deletion cascade**: `workspace_items.id` is parent of `workspace_item_tasks.workspace_item_id`. When a kanban item is deleted, its tasks cascade-delete (existing FK). Now their `kanban` rows also cascade-delete via `workspace_item_task_id` FK. Net effect: same. | Verify with a behavioural test. |
| R7 | **Test fixture maintenance burden**: every backend test that hand-rolls the schema needs the `kanban` table added. ~6 files. | Documented in File Structure above + checklist in Task 6. |
| R8 | **A `workspace_item_task_id` row already exists in `kanban` with a `kanban_column_id` of a column that was deleted between Migration 051 and Migration 072**: after migration, those rows have `kanban_column_id` pointing at a stale / deleted column. `ON DELETE SET NULL` would have nulled them, but the FK existed only after migration. | Backfill INSERT must handle: if `kanban_column_id` on a task points at a non-existent `kanban_columns.id`, skip the row (or insert with a sentinel). Recommend: validate backfill with `INSERT … SELECT … WHERE EXISTS (kanban_columns WHERE id = t.kanban_column_id)`. |
| R9 | **Two separate migration paths**: production walks migrations 001 → 072; tests' hand-rolled CREATE TABLE skips migrations. Inconsistency between real schema and test schema. | All `_test.zig` fixtures that include `workspace_item_tasks` must be updated in lockstep (Task 6). |

---

## Task 0 — Git worktree setup (do this FIRST)

**CRITICAL: do NOT implement directly on `main`.** Every commit in this plan lands on the worktree branch; the user (or `gh pr merge`) is the only one who moves them to `main`. The kanban task moves to `merged` only after the PR is merged.

### Step 0.1 — Create the worktree
The project convention (every existing refactor follows this) is:
- Path: `/home/ginwa/ginwaaitoolbox/.worktrees/<topic-slug>`
- Branch: `worktree/<topic-slug>` (auto-derived from the path basename)

Use the `set_git_worktree` tool:
```
path: /home/ginwa/ginwaaitoolbox/.worktrees/extract-kanban-columns-to-kanban-table
```

Or equivalently:
```bash
cd /home/ginwa/ginwaaitoolbox
git worktree add .worktrees/extract-kanban-columns-to-kanban-table -b worktree/extract-kanban-columns-to-kanban-table main
```

**If the path already exists** (someone else's worktree):
- `git worktree list` to see what's there
- Either pick a different slug OR pass `branch=<existing-branch>` to bind to the existing branch

**If a different worktree already has the same branch checked out:**
- Pass `branch=''` to fall back to the auto-derived name (or pick a different slug)

### Step 0.2 — Verify the worktree
```bash
cd .worktrees/extract-kanban-columns-to-kanban-table
git status            # should be on worktree/extract-kanban-columns-to-kanban-table, clean
git log -1 --oneline  # should match main HEAD (25ec944a at time of writing)
```

### Step 0.3 — Run every subsequent command from inside the worktree
All `git add` / `git commit` / `zig build` / `bunx vitest` / `bun run build` commands in Tasks 1–8 run from `.worktrees/extract-kanban-columns-to-kanban-table/`. Path-relative in this plan (e.g. `src/migrations/migration.zig`) resolves from this worktree root.

### Step 0.4 — Open the PR at the end (Task 8.6)
After Task 8 verification:
```bash
cd .worktrees/extract-kanban-columns-to-kanban-table
gh pr create \
    --title "feat(db): Migration072 — extract kanban_column_id + kanban_position into kanban table" \
    --body-file <(git log main..HEAD --pretty=format:"- %s%n%b%n")
```
Then the user reviews and merges.

### Step 0.5 — Kanban tracking
- **before starting Task 1**: move the kanban card from `todo` to `in progress` (mandatory per the project's Kanban Status Tracking rules)
- **after Step 8.6**: move the card to `in_review_task` (waiting on user merge)
- **user merges the PR**: user moves the card to `merged`

---

## Task 1 — Migration 072 + register it (TDD)

This task is split into sub-steps because the test scaffold matters.

### Step 1.1 — Write the failing test
**File:** `src/migrations/migration_072_test.zig` (new)

Mirror the structure of `migration_062_test.zig` and `migration_071_test.zig`. Required tests:

1. **Adds the `kanban` table** after migration runs.
2. **Adds the `kanban_column_id` index** with the expected definition.
3. **Backfills existing rows** — pre-migration rows with `kanban_column_id = 'col_xxx'` end up as rows in `kanban` with the same `workspace_item_task_id` and column.
4. **Drops `kanban_column_id` and `kanban_position` columns** from `workspace_item_tasks`.
5. **Drops `idx_tasks_column_position`** from `workspace_item_tasks`.
6. **Idempotent** — re-running on a DB that already has `kanban` + new schema is a no-op (uses the same `CREATE TABLE IF NOT EXISTS` + `INSERT OR IGNORE` + `dropColumnIfExists` pattern).
7. **Wire-format preservation** — after migration, `SELECT t.id, k.kanban_column_id, k.kanban_position FROM workspace_item_tasks t LEFT JOIN kanban k ON k.workspace_item_task_id = t.id` returns the same data the old `SELECT … t.kanban_column_id, t.kanban_position … FROM workspace_item_tasks t` would have (with NULL/0 for non-kanban tasks).

The `setupDb()` helper for this test must create the **pre-Migration-072** schema (i.e. the schema that EXISTS today), not a hand-rolled minimum.

### Step 1.2 — Implement Migration072
**File:** `src/migrations/migration.zig`

Add the struct (place it after `Migration071AddTaskCwd`, follow the same doc-comment style):

```zig
/// Migration 072 — Extract `kanban_column_id` + `kanban_position`
/// from `workspace_item_tasks` into a dedicated `kanban` join table.
///
/// Before: the two placement columns live on the universal
/// `workspace_item_tasks` table (alongside chat/routine/kanban task
/// attributes like `description`, `tags`, `image_urls`, `cwd`, etc.).
/// After: a new `kanban(workspace_item_task_id, kanban_column_id, kanban_position)`
/// table holds the 1:1 task-to-board placement; non-kanban tasks
/// simply have no row.
///
/// Wire format UNCHANGED — `Task.kanban_column_id` and
/// `Task.kanban_position` continue to appear on every Task JSON via
/// a `LEFT JOIN kanban k ON k.workspace_item_task_id = t.id` in list queries. The
/// frontend stores/components/SSE handlers stay byte-for-byte the
/// same.
///
/// Plan: docs/superpowers/plans/2026-08-15-extract-kanban-columns-to-kanban-table.md
/// Task: task_1786527996378 (kanban: sprint bulan juni → "move column
///   workspace_item_tasks table").
///
/// Steps (inside a single BEGIN..COMMIT for atomicity — a crash mid-
/// migration would otherwise leave the DB with both new and old
/// columns populated, which the model layer's `LEFT JOIN` would
/// silently drop data from):
///   1. CREATE TABLE IF NOT EXISTS kanban (...) — fresh-DB-safe
///   2. CREATE INDEX IF NOT EXISTS idx_kanban_column_position ...
///   3. INSERT OR IGNORE INTO kanban (...) SELECT … FROM
///      workspace_item_tasks WHERE kanban_column_id IS NOT NULL AND
///      kanban_column_id IN (SELECT id FROM kanban_columns) — skip
///      orphans (R8)
///   4. DROP INDEX IF EXISTS idx_tasks_column_position
///   5. DROP COLUMN kanban_column_id (dropColumnIfExists for fresh-DB
///      safety)
///   6. DROP COLUMN kanban_position
pub const Migration072ExtractKanbanTable = struct {
    pub const version: u32 = 72;
    pub const name = "extract_kanban_table";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Wrap in BEGIN..COMMIT so the CREATE+INSERT+DROP sequence is
        // atomic. Without the wrapper, SQLite auto-commits each step
        // and a crash between step 3 (backfill) and step 5 (DROP
        // COLUMN) would leave the DB with both new and old columns
        // populated.
        try db.exec(allocator, "BEGIN", &.{});
        errdefer {
            // If anything below errors, rollback best-effort. The
            // errdefer doesn't run on the success path (the explicit
            // COMMIT runs first).
            db.exec(allocator, "ROLLBACK", &.{}) catch {};
        }

        // Step 1: CREATE kanban (idempotent via IF NOT EXISTS)
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS kanban (
            \\    workspace_item_task_id TEXT PRIMARY KEY,
            \\    kanban_column_id       TEXT NOT NULL,
            \\    kanban_position        INTEGER NOT NULL DEFAULT 0,
            \\    FOREIGN KEY (workspace_item_task_id)
            \\        REFERENCES workspace_item_tasks(id) ON DELETE CASCADE,
            \\    FOREIGN KEY (kanban_column_id)
            \\        REFERENCES kanban_columns(id)     ON DELETE SET NULL
            \\)
        , &[_][]const u8{});

        // Step 2: per-column ordering index
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_kanban_column_position " ++
            "ON kanban(kanban_column_id, kanban_position)",
            &[_][]const u8{},
        );

        // Step 3: backfill from existing data. Two filters:
        //   - `kanban_column_id IS NOT NULL` skips chat/routine/design
        //     tasks (they shouldn't be on a kanban anyway, but be
        //     defensive).
        //   - `kanban_column_id IN (SELECT id FROM kanban_columns)`
        //     skips orphan references (R8 — a task's column could
        //     have been hard-deleted before the FK existed; we don't
        //     surface unassigned rows retroactively).
        // INSERT OR IGNORE makes a re-run safe (won't crash on the
        // PRIMARY KEY collision).
        try db.exec(allocator,
            \\INSERT OR IGNORE INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position)
            \\SELECT t.id, t.kanban_column_id, COALESCE(t.kanban_position, 0)
            \\FROM workspace_item_tasks t
            \\WHERE t.kanban_column_id IS NOT NULL
            \\  AND t.kanban_column_id IN (SELECT id FROM kanban_columns)
        , &[_][]const u8{});

        // Step 4: drop the per-column index on workspace_item_tasks
        try db.exec(allocator,
            "DROP INDEX IF EXISTS idx_tasks_column_position",
            &[_][]const u8{},
        );

        // Step 5 + 6: drop the two columns. dropColumnIfExists is the
        // safe pattern (used in Migration 052) — fresh-DB users who
        // walked the canonical schema may not have these columns if
        // we eventually move them out of the canonical CREATE TABLE.
        try dropColumnIfExists(db, allocator, "workspace_item_tasks", "kanban_column_id");
        try dropColumnIfExists(db, allocator, "workspace_item_tasks", "kanban_position");

        // Commit the transaction. After this, Migration 072 is "done"
        // and the new schema is durable.
        try db.exec(allocator, "COMMIT", &[_][]const u8{});

        // ANALYZE so the query planner sees the new index (mirrors
        // Migration 051 / 041 / 042 / 043 / 048 / 049 / 050).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
```

### Step 1.3 — Register in `allMigrations`
**File:** `src/migrations/migration.zig` — find the `allMigrations` slice (ends after the `Migration071AddTaskCwd` entry on line 1838) and append:

```zig
// Migration 072 — extracts `kanban_column_id` + `kanban_position` off
// `workspace_item_tasks` into a dedicated `kanban` join table; wire
// format preserved (Task.{kanban_column_id, kanban_position} continue
// to exist via LEFT JOIN). Plan:
// docs/superpowers/plans/2026-08-15-extract-kanban-columns-to-kanban-table.md.
// Task: task_1786527996378.
.{ .version = Migration072ExtractKanbanTable.version, .name = Migration072ExtractKanbanTable.name, .up = Migration072ExtractKanbanTable.up },
```

**File:** `src/migrations/test_runner.zig` — add an import line alongside the others:

```zig
_ = @import("migration_072_test.zig");  // workspace_item_tasks → kanban table (extract kanban columns plan, 2026-08-15)
```

### Step 1.4 — Run tests and commit
```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/extract-kanban-columns-to-kanban-table
zig build test --summary all 2>&1 | head -n 100
git add src/migrations/{migration.zig,migration_072_test.zig,test_runner.zig}
git commit -m "feat(db): Migration072 — extract kanban_column_id + kanban_position into kanban table"
```

**Done when:** `zig build test --summary all` passes (including the 7+ new tests in `migration_072_test.zig`), and the commit is atomic.

---

## Task 2 — `kanban_model.zig` SQL sites

Four SQL sites in `src/ai_workflow/tui/kanban_model.zig` reference the old columns. Rewrite each.

### Step 2.1 — `deleteColumn` (line ~293-306)

**Before:**
```zig
pub fn deleteColumn(...) !void {
    try db.exec(allocator,
        "UPDATE workspace_item_tasks SET kanban_column_id = NULL WHERE kanban_column_id = ?",
        &.{column_id});
    try db.exec(allocator,
        "DELETE FROM kanban_columns WHERE id = ?",
        &.{column_id});
}
```

**After:**
```zig
pub fn deleteColumn(...) !void {
    // `kanban.kanban_column_id` ON DELETE SET NULL handles this
    // automatically — the FK triggers NULL-out when the column row
    // is deleted. Tasks themselves (workspace_item_tasks) are not
    // touched; just their kanban-card row gets `kanban_column_id =
    // NULL`, which the LEFT JOIN in list queries surfaces as "task
    // exists but is unassigned". Same wire-format semantics as
    // before.
    _ = workspace_item_id;
    try db.exec(allocator,
        "DELETE FROM kanban_columns WHERE id = ?",
        &.{column_id});
}
```

The new behavior is: tasks stay on the board (in unassigned limbo), their `kanban` row stays, but `kanban_column_id` goes NULL. The list-query LEFT JOIN surfaces this as the old `kanban_column_id = NULL` JSON value. Same observable behavior, simpler code.

### Step 2.2 — `countTasksInColumn` (line ~466-478)

**Before:**
```zig
pub fn countTasksInColumn(...) !u32 {
    var q = try db.query(allocator,
        \\SELECT COUNT(*) FROM workspace_item_tasks t WHERE t.kanban_column_id = ?
    , &.{column_id});
    ...
}
```

**After:**
```zig
pub fn countTasksInColumn(...) !u32 {
    var q = try db.query(allocator,
        \\SELECT COUNT(*) FROM kanban k WHERE k.kanban_column_id = ?
    , &.{column_id});
    ...
}
```

Semantically identical — a row exists in `kanban` iff a task is assigned to that column.

### Step 2.3 — `moveTask` (line ~583-633)

This is the big one — 3 of the 4 SQL statements in `moveTask` need rewriting:

**Step 1 (line ~594-602) — read current column:** swap `workspace_item_tasks` for `kanban`:
```zig
const current_col_id = blk: {
    var q = try db.query(allocator,
        "SELECT COALESCE(k.kanban_column_id, '') FROM kanban k WHERE k.workspace_item_task_id = ?",
        &.{task_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.TaskNotFound;
    defer row.deinit(allocator);
    break :blk try allocator.dupe(u8, row.values[0]);
};
defer allocator.free(current_col_id);
```

**Step 2 (line ~609-611) — move task to target column:** an UPDATE on `workspace_item_tasks` becomes a no-op (the row's identity doesn't change) and an `INSERT OR REPLACE` on `kanban`:
```zig
try db.exec(allocator,
    "INSERT OR REPLACE INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES (?, ?, ?)",
    &.{ task_id, target_column_id, pos_str });
```

**Step 3 (line ~614-619) — shift other tasks' positions in target column:** rewrite from `workspace_item_tasks` to `kanban`:
```zig
try db.exec(allocator,
    \\UPDATE kanban
    \\SET kanban_position = kanban_position + 1
    \\WHERE kanban_column_id = ? AND workspace_item_task_id != ? AND kanban_position >= ?
, &.{ target_column_id, task_id, pos_str });
```

**Step 4 (line ~621-633) — compact source column:** rewrite:
```zig
if (!std.mem.eql(u8, current_col_id, target_column_id)) {
    try db.exec(allocator,
        \\UPDATE kanban
        \\SET kanban_position = (
        \\    SELECT COUNT(*) FROM kanban k2
        \\    WHERE k2.kanban_column_id = kanban.kanban_column_id
        \\        AND (k2.kanban_position < kanban.kanban_position
        \\            OR (k2.kanban_position = kanban.kanban_position AND k2.workspace_item_task_id <= kanban.workspace_item_task_id))
        \\) - 1
        \\WHERE kanban_column_id = ?
    , &.{current_col_id});
}
```

### Step 2.4 — `kanban_model_test.zig` fixture update

The test fixture (lines 174-176, 210-212, 233-235, 256-258, 280-282) all do:
```zig
try db.exec(alloc,
    \\CREATE TABLE workspace_item_tasks (
    \\    id TEXT PRIMARY KEY,
    \\    ...
    \\    kanban_column_id TEXT,
    \\    kanban_position INTEGER
    \\)
, &.{});
```

Replace each occurrence with:
```zig
try db.exec(alloc,
    \\CREATE TABLE workspace_item_tasks (
    \\    id TEXT PRIMARY KEY,
    \\    ...
    \\    -- kanban_column_id REMOVED (now in kanban table)
    \\    -- kanban_position REMOVED (now in kanban table)
    \\)
, &.{});
try db.exec(alloc,
    \\CREATE TABLE kanban (
    \\    workspace_item_task_id TEXT PRIMARY KEY,
    \\    kanban_column_id TEXT NOT NULL,
    \\    kanban_position INTEGER NOT NULL DEFAULT 0
    \\)
, &.{});
```

Then update the `INSERT INTO workspace_item_tasks (..., kanban_column_id, kanban_position) ...` lines (174-183, 214-216, 236-238, 290-293) to split into two statements: one INSERT into `workspace_item_tasks`, then an `INSERT OR IGNORE INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES (...)`.

### Step 2.5 — Run kanban_model tests
```bash
zig build test --summary all 2>&1 | rg -A 5 "kanban_model" | head -n 100
```

**Done when:** all `kanban_model_test.zig` and `kanban_copy_spec_test.zig` tests pass green.

### Step 2.6 — Commit
```bash
git add src/ai_workflow/tui/kanban_model.zig src/ai_workflow/tui/kanban_model_test.zig src/ai_workflow/tui/kanban_copy_spec_test.zig
git commit -m "refactor(kanban): move moveTask + countTasksInColumn + deleteColumn SQL to kanban table"
```

---

## Task 3 — `llm_history.zig` SELECT sites

Two SELECT sites reference the old columns. The Task struct is unchanged; only the query SELECT-list changes.

### Step 3.1 — `readSession` / list-tasks SELECT (~line 4547)

**Before:**
```zig
"SELECT t.id, t.name, t.workspace_item_id, t.description, t.created_at, t.updated_at, t.task_type, COALESCE(t.is_pinned, 0), COALESCE(t.pinned_position, 0), t.kanban_column_id, COALESCE(t.kanban_position, 0), r.schedule, ... FROM workspace_item_tasks t LEFT JOIN routines r ON r.task_id = t.id LEFT JOIN sessions s ON s.id = t.id WHERE t.workspace_item_id = ?...",
```

**After:** change the SELECT list to read from `kanban`:
```zig
"SELECT t.id, t.name, t.workspace_item_id, t.description, t.created_at, t.updated_at, t.task_type, COALESCE(t.is_pinned, 0), COALESCE(t.pinned_position, 0), k.kanban_column_id, COALESCE(k.kanban_position, 0), r.schedule, ... FROM workspace_item_tasks t LEFT JOIN kanban k ON k.workspace_item_task_id = t.id LEFT JOIN routines r ON r.task_id = t.id LEFT JOIN sessions s ON s.id = t.id WHERE t.workspace_item_id = ?...",
```

The read at the cursor (around line 4633) becomes:
```zig
.kanban_column_id = if (row.values[9].len > 0) try allocator.dupe(u8, row.values[9]) else null,
.kanban_position = std.fmt.parseInt(i64, row.values[10], 10) catch 0,
```
which is **unchanged** (it already reads from `row.values[9]` and `[10]` — those indices now point at the JOINed columns instead of the dropped columns, but the wire shape is identical).

### Step 3.2 — `listTasks`-style queries (~line 4288)

There's another `SELECT t.kanban_column_id, COALESCE(t.kanban_position, 0),` call earlier in the file (in `listTasks`). Apply the same `LEFT JOIN kanban` rewrite.

### Step 3.3 — `llm_history_notification_test.zig` + `kanban_model_test*.zig` + `tasks_create_value_alloc_test.zig` fixtures

These test files have hand-rolled `CREATE TABLE workspace_item_tasks (... kanban_column_id TEXT, kanban_position INTEGER ...)` fixtures. Apply the same fixture pattern as Task 2.4 (remove the two columns from `workspace_item_tasks` AND add a `CREATE TABLE kanban (...)` block AND split the INSERTs).

Affected files:
- `src/ai_workflow/tui/llm_history_notification_test.zig` (line 148)
- `src/ai_workflow/tui/agentic_loop/build_messages_for_agent_prompt_test.zig` (lines 95, 643, 768, 814)
- `src/ai_workflow/tui/agentic_loop/build_messages_for_agent_prompt_design_canvas_test.zig` (line 75)
- `src/ai_workflow/tui/agentic_loop/build_messages_for_agent_prompt_filtering_tools_test.zig` (line 77)

### Step 3.4 — Run llm_history tests
```bash
zig build test --summary all 2>&1 | rg -A 3 "llm_history" | head -n 100
```

### Step 3.5 — Commit
```bash
git add src/ai_workflow/tui/llm_history.zig src/ai_workflow/tui/llm_history_notification_test.zig src/ai_workflow/tui/agentic_loop/build_messages_for_agent_prompt*.zig
git commit -m "refactor(llm_history): list/readSession queries LEFT JOIN kanban for placement fields"
```

---

## Task 4 — `http_handlers/` SQL sites

### Step 4.1 — `task_create.zig` (~line 514)

The kanban-auto-assign block does:
```zig
"UPDATE workspace_item_tasks SET kanban_column_id = ?, kanban_position = (SELECT COALESCE(MAX(kanban_position), -1) + 1 FROM workspace_item_tasks WHERE kanban_column_id = ?) WHERE id = ?"
```

Replace with INSERT OR IGNORE into kanban:
```zig
// Resolve the next position from the existing `kanban` table (since
// that's where positions now live). MAX is over kanban tasks in the
// same column. The `INSERT OR IGNORE` makes this safe for re-runs
// (if the kanban row already exists, the UPDATE below re-positions
// it).
try db.exec(allocator,
    "INSERT OR IGNORE INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES (?, ?, (SELECT COALESCE(MAX(kanban_position), -1) + 1 FROM kanban WHERE kanban_column_id = ?))",
    &.{ task_id, column_id, column_id });
```

Then the re-read at line 544 needs the JOIN:
```zig
"SELECT k.kanban_column_id, COALESCE(k.kanban_position, 0) FROM kanban k WHERE k.workspace_item_task_id = ?"
```

And the fallback at line 549 (when the task has no `kanban` row) stays as `.kanban_column_id = null, .kanban_position = 0`.

### Step 4.2 — `tasks_list.zig` WHERE filter (~line 4511)

The `column_id` query-param filter:
```zig
" AND (t.kanban_column_id = ? OR t.kanban_column_id IS NULL)"
```
becomes:
```zig
" AND (k.kanban_column_id = ? OR k.kanban_column_id IS NULL)"
```
And the SELECT must be updated to include `LEFT JOIN kanban k ON k.workspace_item_task_id = t.id` (matching the new shape from Task 3.1).

The `additional WHERE ... WHERE ... ` clause uses `{s}` placeholders; that pattern stays.

### Step 4.3 — `task_create.zig` — separate SSE emit fields
The SSE `onEventSendKanbanTask` payload carries `kanban_column_id` + `kanban_position`. With the JOIN rewrite, these are still populated. **No change** in `on_event_sent_kanban.zig`. Verify by running the SSE-mirror test (covered by `kanbanSseMirrorMove.spec.ts` on the frontend — must still pass).

### Step 4.4 — `task_update.zig` — no change
Verify by reading the file: `task_update.zig` only writes `description`/`tags`/`cwd`/`name`. No `kanban_column_id` or `kanban_position` writes. ✓

### Step 4.5 — `task_delete.zig` — no change
Verify by reading the file: deletes `workspace_item_tasks` by id. The `kanban` row auto-cascades via `ON DELETE CASCADE`. ✓

### Step 4.6 — `tasks_create_kanban_test.zig` + `tasks_create_value_alloc_test.zig`

Update fixtures like Task 2.4.

### Step 4.7 — Run http_handlers tests + commit
```bash
zig build test --summary all 2>&1 | rg -A 3 "task_create\|tasks_list\|task_update\|task_delete" | head -n 100
```

```bash
git add src/ai_workflow/tui/http_handlers/task_create.zig src/ai_workflow/tui/http_handlers/tasks_list.zig src/ai_workflow/tui/http_handlers/tasks_create_kanban_test.zig src/ai_workflow/tui/http_handlers/tasks_create_value_alloc_test.zig
git commit -m "refactor(http_handlers): kanban auto-assign + column-id filter use kanban table"
```

---

## Task 5 — `agentic_loop/` SQL sites + verify wire format

### Step 5.1 — `prompts_make_kanban_context.zig` (~line 94)

**Before:**
```zig
\\SELECT COALESCE(kanban_column_id, '')
\\FROM workspace_item_tasks
\\WHERE id = ?
```

**After:**
```zig
\\SELECT COALESCE(k.kanban_column_id, '')
\\FROM kanban k
\\JOIN workspace_item_tasks t ON t.id = k.workspace_item_task_id
\\WHERE t.id = ?
```

(INNER JOIN because the agent only wants current placement; if the task is not on a kanban, the row is absent — match the existing behaviour where `kanban_column_id` is empty string but the agent still proceeds.)

### Step 5.2 — `prompts_build_messages_for_agent_prompt.zig`

Search for `t.kanban_column_id` reads in the SELECT or WHERE clauses and update to `LEFT JOIN kanban k ON k.workspace_item_task_id = t.id` (same pattern as Task 3.1).

### Step 5.3 — `tools_equipped.zig` (line 153)

This is a **doc comment** only (it documents the column names to the LLM as context):
```zig
// kanban_column_id / kanban_position (see project memory ...
```
Update to reflect the new schema:
```zig
// kanban table → (kanban_column_id, kanban_position) — one row per kanban-assigned task (see project memory ...
```

### Step 5.4 — Update test fixtures for `build_messages_for_agent_prompt*_test.zig`

Apply Task 2.4 pattern to all three test files.

### Step 5.5 — Run all agentic_loop tests + commit
```bash
zig build test --summary all 2>&1 | rg "agentic_loop\|prompts_make" | head -n 50
```

```bash
git add src/ai_workflow/tui/agentic_loop/
git commit -m "refactor(agentic_loop): prompts_make_kanban_context + system-prompt build use kanban table"
```

---

## Task 6 — Sweep all remaining backend test fixtures (mechanical)

### Step 6.1 — Find every remaining fixture with the old columns

```bash
rg "kanban_column_id TEXT" src/ --type zig -n | rg -v "kanban_columns|kanban\.zig|migration\.zig" | head -n 30
rg "kanban_position INTEGER" src/ --type zig -n | rg -v "kanban_columns|migration\.zig|kanban\.zig" | head -n 30
```

Every hit is a hand-rolled `*_test.zig` fixture that needs updating. The pattern is the same as Task 2.4:
1. Remove `kanban_column_id TEXT,` and `kanban_position INTEGER ...` from the `workspace_item_tasks` CREATE TABLE in the fixture
2. Add a `CREATE TABLE kanban (...)` block
3. Update any `INSERT INTO workspace_item_tasks (..., kanban_column_id, kanban_position)` to split into two INSERTs (or remove the kanban columns from the INSERT)

Likely files (verify with the rg above):
- `src/migrations/migration_051_test.zig` (test fixture; Migration 051 is what added the columns, so the "after" state for that test is the pre-Migration-072 state — no change needed, but verify)
- `src/migrations/migration_053_test.zig` (fixture for the routine FK test)
- `src/migrations/migration_062_test.zig` (line 56 — already minimal, but verify)
- `src/migrations/migration_065_test.zig` (line 63 — minimal, verify)
- `src/migrations/migration_066_test.zig` (line 75 — minimal, verify)
- `src/migrations/migration_067_test.zig` (line 56 — minimal, verify)
- `src/migrations/migration_069_test.zig` (line 52 — has kanban_column_id in fixture; update if needed)
- `src/migrations/migration_routines_test.zig` (line 61 — minimal, verify)
- `src/migrations/migration_defensive_indexes_test.zig` (line 59 — minimal, verify)

### Step 6.2 — Run full backend test suite
```bash
zig build test --summary all 2>&1 | tail -n 30
```

**Done when:** zero failures, zero skipped.

### Step 6.3 — Commit
```bash
git add src/migrations/ src/ai_workflow/tui/
git commit -m "test: update test fixtures — remove kanban_column_id/kanban_position from workspace_item_tasks mocks"
```

---

## Task 7 — Frontend verification (no changes expected)

### Step 7.1 — Confirm wire format
Open `src/ai_workflow/tui/http_handlers/tasks_list.zig` and confirm the JSON serialization (`.kanban_column_id = task.kanban_column_id,` line ~212) still references the same field names. Wire format = unchanged.

### Step 7.2 — Run frontend test suite (should be green without changes)
```bash
cd src/apps/desktop && bunx vitest run 2>&1 | tail -n 30
```

Likely green because the API response shape hasn't changed. If any test fails, the cause is likely a fixture that hard-codes a `task_type='kanban'` task without a `kanban` row in the backend test — but this would be caught in Task 6 first.

### Step 7.3 — Run frontend type check
```bash
cd src/apps/desktop && bun run build 2>&1 | tail -n 30
```

### Step 7.4 — No commit needed (frontend untouched)

---

## Task 8 — Final integration verification

### Step 8.1 — Build full backend
```bash
zig build 2>&1 | tail -n 20
```

### Step 8.2 — Run complete test suites (Zig + frontend)
```bash
zig build test --summary all 2>&1 | tail -n 20
cd src/apps/desktop && bunx vitest run 2>&1 | tail -n 20 && bun run build 2>&1 | tail -n 10
```

### Step 8.3 — Manual smoke (port 8080)
1. Start the backend: `./zig-out/bin/pabrik --port 8080`
2. Start the frontend: `cd src/apps/desktop && bun run dev` (opens its own port)
3. Open a kanban board, verify tasks render in correct columns
4. Drag a task between columns — verify position updates and persists on refresh
5. Delete a column with tasks in it — verify tasks become "Unassigned"
6. Create a new task on the kanban — verify it lands at the bottom of the first column
7. Create a task in a chat workspace (not kanban) — verify it gets no kanban-related fields (column_id = null, position = 0)
8. Reload the page — verify all positions preserved

### Step 8.4 — Migration smoke (existing DB upgrade path)
1. Take a DB from before Migration 072 (i.e. a backup of a real user's DB). If none available locally, create one by running migrations 001-071 + inserting some kanban tasks.
2. Start the backend with the Migration-072-aware binary.
3. Confirm the migration runs on startup.
4. Confirm kanban features still work as before.

### Step 8.5 — Update SPEC.md if it references the old columns
```bash
rg "kanban_column_id|kanban_position" docs/SPEC.md
```
If found, update the spec to note that the columns now live in the `kanban` table.

### Step 8.6 — Final commit + PR
```bash
git add docs/SPEC.md  # if any changes
git commit -m "docs(spec): update SPEC.md to reference kanban table for placement data"
gh pr create --title "feat(db): extract kanban_column_id + kanban_position into kanban table" --body "..."
```

---

## Out of scope (deferred — do NOT do in this plan)

- **Extracting `description` / `tags` / `image_urls` / `cwd` to a similar `task_metadata` table** — these are used by chat/routine tasks too, not kanban-exclusive. Moving them would break non-kanban task display. See brainstorm notes.
- **JSON-typed columns** (`tags`, `image_urls`) — keep as `TEXT` for v1.
- **`kanban.created_at`** — YAGNI for now; can add in a follow-up if needed.
- **`workspace_items.item_type='kanban'` being a separate table** — the current `item_type='kanban'` discriminator on `workspace_items` is fine; the `kanban` table is purely the card-placement mapping.
- **Frontend KanbanCard UX changes** — the wire format is preserved, so KanbanCard / KanbanColumn / KanbanView components don't change.

---

## Implementation Notes (added after execution)

- TBD — fill in as you go with any deviations from the plan or discoveries.

---

## Verification checklist (copy this for the final response)

- [ ] Migration 072 added + registered in `allMigrations` (Task 1)
- [ ] `kanban_model.zig` 4 SQL sites updated + tests green (Task 2)
- [ ] `llm_history.zig` list/SELECT queries updated + tests green (Task 3)
- [ ] `http_handlers/task_create.zig` + `tasks_list.zig` SQL updated + tests green (Task 4)
- [ ] `agentic_loop/prompts_make_kanban_context.zig` + `prompts_build_messages_for_agent_prompt.zig` + tools comment updated (Task 5)
- [ ] All test fixtures swept (Task 6)
- [ ] Frontend test suite + type check still green (Task 7)
- [ ] Full build + manual smoke + migration upgrade path verified (Task 8)
- [ ] SPEC.md updated if applicable
- [ ] PR opened, all commits atomic and independently-passing
