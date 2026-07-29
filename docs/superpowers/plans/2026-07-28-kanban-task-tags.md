# Kanban Task Tags — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add free-form `tags` to kanban tasks. Tasks carry 0+ tags (each a short string). Tags render as colored chips on the kanban card and can be edited in the task detail dialog.

**Architecture:**

1. **NEW** `src/migrations/migration_067.zig` (or inline in `migration.zig`) — adds `tags TEXT NOT NULL DEFAULT ''` column to `workspace_item_tasks`, registered in `allMigrations` slice + a regression test.
2. **EDIT** `src/ai_workflow/tui/llm_history.zig` — `WorkspaceItemTaskInfo` gains `tags` field; `createWorkspaceItemTask`, `getWorkspaceItemTask`, `listWorkspaceItemTasksWithCursor`, `updateWorkspaceItemTask` gain `tags` handling (parse JSON, free in `deinit`).
3. **EDIT** `src/ai_workflow/tui/http_handlers/http_response.zig` — `WorkspaceItemTaskResponse`, `TaskCreateRequest`, `TaskUpdateRequest` all gain `tags` field.
4. **EDIT** `src/ai_workflow/tui/http_handlers/task_create.zig` — accept `tags` from body, validate, persist via dynamic SQL builder (mirrors description pattern).
5. **EDIT** `src/ai_workflow/tui/http_handlers/task_update.zig` — accept `tags` from body, validate, persist.
6. **EDIT** `src/apps/desktop/src/stores/workspaces.ts` — `Task.tags?: string[]`, `createTask` accepts `tags?: string[]`, `updateTaskSimple` accepts `tags?: string[]`.
7. **EDIT** `src/apps/desktop/src/api/index.ts` — `createTask` and `updateTaskSimple` accept `tags?: string[]`, JSON-encode before sending.
8. **NEW** `src/apps/desktop/src/components/kanban/KanbanTagsInput.vue` — chip input (type + Enter to add, ✕ to remove, Backspace on empty removes last, deterministic color from hash).
9. **EDIT** `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` — render `<KanbanTagsInput>` between description and unattended-mode, parse `task.tags` on edit-mode load.
10. **EDIT** `src/apps/desktop/src/components/workspace/WorkspaceItemTaskCard.vue` — render tags row (up to 3 chips, `+N more` link).

**Tech Stack:** Zig 0.16 (backend, project pin), SQLite via `nalarcore.sqlite.SqliteBackend`, Vue 3 + TypeScript + Vitest (frontend). No new dependencies.

## Global Constraints

- **Cross-platform** — every step must work on Linux, macOS, AND Windows. No `std.posix.*` direct calls; use `nalarcore.helpers.*` wrappers.
- **Zig 0.16 stdlib** — follow the existing patterns in `task_create.zig` (the dynamic-SQL builder for description, see lines 209-244). Use `parseFromSliceLeaky` (per-request arena). Always register the migration in `allMigrations` AND in a regression test (the migration-registration-trap).
- **TDD** — every implementation step is preceded by a failing test step. Prefer behavioural tests over static-contract grep when feasible (per `static-contract-test-when-to-prefer-behavioural`).
- **Vue 3** — `bun run build` is the type-check (vue-tsc); `bunx vitest run` does not type-check. Run BOTH before declaring done.
- **Static-contract tests for wire-shape** — the project convention for HTTP handlers is to assert on the response struct's fields and the handler's parsing/validation (e.g. `task_create_description_test.zig`). Reuse the pattern.
- **Verification before completion** — `zig build test --summary all` + `zig build install:linux:system` + `rm -rf zig-out/bin && zig build` + `bun run build` + `bunx vitest run` must all pass before any task is marked complete.
- **End-to-end smoke** — final task includes a curl-based smoke test against port 8080 (NEVER 8081) to verify the tags are persisted + rendered.

## File Touch Map

| File | Action | Lines changed (est.) |
|---|---|---|
| `src/migrations/migration.zig` | EDIT | +30 (Migration 067 struct) |
| `src/migrations/migration_067_test.zig` | NEW | ~120 |
| `src/migrations/test_runner.zig` | EDIT | +1 |
| `src/ai_workflow/tui/llm_history.zig` | EDIT | +15 (struct + 4 functions) |
| `src/ai_workflow/tui/http_handlers/http_response.zig` | EDIT | +3 (3 fields) |
| `src/ai_workflow/tui/http_handlers/task_create.zig` | EDIT | +30 (accept + validate + persist) |
| `src/ai_workflow/tui/http_handlers/task_create_tags_test.zig` | NEW | ~180 |
| `src/ai_workflow/tui/http_handlers/task_update.zig` | EDIT | +20 (accept + validate + persist) |
| `src/ai_workflow/tui/http_handlers/task_update_tags_test.zig` | NEW | ~140 |
| `src/ai_workflow/tui/http_handlers/http_handlers_test_runner.zig` | EDIT | +2 (register new tests) |
| `src/apps/desktop/src/stores/workspaces.ts` | EDIT | +5 (Task.tags + createTask + updateTaskSimple) |
| `src/apps/desktop/src/api/index.ts` | EDIT | +10 (createTask + updateTaskSimple) |
| `src/apps/desktop/src/components/kanban/KanbanTagsInput.vue` | NEW | ~200 |
| `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` | EDIT | +30 (tags section + parse) |
| `src/apps/desktop/src/components/workspace/WorkspaceItemTaskCard.vue` | EDIT | +25 (tags row) |
| `src/apps/desktop/src/__tests__/KanbanTagsInput.spec.ts` | NEW | ~250 |
| `src/apps/desktop/src/__tests__/WorkspaceItemTaskCard.tags.spec.ts` | NEW | ~140 |
| `src/apps/desktop/src/__tests__/workspacesStore.tags.spec.ts` | NEW | ~110 |

Total: ~18 files, ~11 NEW + ~7 EDIT. ~1310 lines net.

---

## Tasks

### Task 1 — Migration 067: add `tags` column

**Goal:** Add the `tags` column to `workspace_item_tasks`. The migration runs cleanly on fresh AND existing DBs. The migration is registered in `allMigrations` AND has a registration regression test.

**File:** `src/migrations/migration.zig`

- [ ] **Step 1.1** — Add the migration struct in `migration.zig` after the existing `Migration066AddDesignPageTaskFk`. Pattern (from `Migration065AddTaskHumanTouchedAt` at lines 2251-2268):

  ```zig
  pub const Migration067AddTaskTags = struct {
      pub const version: u32 = 67;
      pub const name = "add_task_tags";

      pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
          try addColumnIfMissing(
              db,
              allocator,
              "workspace_item_tasks",
              "tags",
              // `addColumnIfMissing` builds `ALTER TABLE {table} ADD COLUMN {definition}`,
              // so the definition must include BOTH the column name AND the type.
              // Omitting the type would create a column literally named "TEXT"
              // (see memory `addColumnIfMissing-requires-name-type`).
              "tags TEXT",
          );
      }
  };
  ```

- [ ] **Step 1.2** — Register the migration in the `allMigrations` slice (around line 1791, after the Migration 066 entry):

  ```zig
  .{ .version = Migration067AddTaskTags.version, .name = Migration067AddTaskTags.name, .up = Migration067AddTaskTags.up },
  ```

- [ ] **Step 1.3** — Write the failing test. Create `src/migrations/migration_067_test.zig`:

  ```zig
  test "Migration067 adds tags column to workspace_item_tasks" {
      // setupDb() with fresh DB (apply migrations 001-066 first via
      // migration registry, then run Migration067AddTaskTags.up directly).
      // PRAGMA table_info('workspace_item_tasks') and assert 'tags' is in the
      // result with type 'TEXT' and NOT NULL DEFAULT ''.
  }

  test "Migration067 is registered in allMigrations" {
      const all = @import("migration.zig").allMigrations;
      for (all) |m| {
          if (m.version == Migration067AddTaskTags.version) return;
      }
      return error.Migration067NotRegistered;
  }

  test "Migration067 is idempotent (re-run does not error)" {
      // Run Migration067AddTaskTags.up twice; second call must NOT raise
      // `duplicate column name: tags` (addColumnIfMissing checks pragma_table_info
      // before issuing the ALTER).
  }

  test "Migration067 default value is empty string" {
      // After Migration067, INSERT a row without specifying tags. SELECT the
      // row's tags column — must be '' (the canonical "no tags" sentinel).
  }
  ```

  Run `timeout 180 zig build test --summary all 2>&1 | tail -n 5`. Expected: 4 new tests fail (Migration 067 doesn't exist yet).

- [ ] **Step 1.4** — Add `_ = @import("migration_067_test.zig");` to `src/migrations/test_runner.zig` (around line 33, after the Migration 066 entry).

- [ ] **Step 1.5** — Run `timeout 180 zig build test --summary all 2>&1 | tail -n 5`. Expected: 4 tests pass. Migration registered + idempotent + default value verified.

- [ ] **Step 1.6** — Run `timeout 180 zig build install:linux:system 2>&1 | tail -n 5`. Expected: clean (catches lazy-analysis errors `zig build test` misses).

- [ ] **Step 1.7** — Commit: `git add -A && git commit -m "feat(migrations): add workspace_item_tasks.tags column (Migration 067)"`.

### Task 2 — Backend: `WorkspaceItemTaskInfo.tags` field

**Goal:** Add the `tags` field to the DB-layer struct so it can carry through `createWorkspaceItemTask`, `getWorkspaceItemTask`, `listWorkspaceItemTasksWithCursor`, `updateWorkspaceItemTask`. Add `deinit` cleanup.

**File:** `src/ai_workflow/tui/llm_history.zig`

- [ ] **Step 2.1** — Add the `tags` field to `WorkspaceItemTaskInfo` (around line 3316, after `needs_human_review`):

  ```zig
  /// JSON-encoded array of tag strings (Migration 067).
  /// Empty string is the canonical "no tags" sentinel.
  /// Owned by the lister; freed by `deinit`.
  tags: []u8 = &.{},
  ```

- [ ] **Step 2.2** — Update `WorkspaceItemTaskInfo.deinit` (around line 3334) to free the tags slice:

  ```zig
  if (self.tags.len > 0) allocator.free(self.tags);
  ```

- [ ] **Step 2.3** — Run `timeout 180 zig build test --summary all 2>&1 | tail -n 5`. Expected: clean (no behavior change yet, but verifies `tags` field default doesn't break existing tests).

- [ ] **Step 2.4** — Commit: `git add -A && git commit -m "feat(llm_history): add tags field to WorkspaceItemTaskInfo"`.

### Task 3 — Backend: `createWorkspaceItemTask` accepts `tags`

**Goal:** The model's `createWorkspaceItemTask` function accepts an optional `tags: ?[]const u8` (JSON-encoded string) and persists it.

**File:** `src/ai_workflow/tui/llm_history.zig`

- [ ] **Step 3.1** — Update `createWorkspaceItemTask` signature (around line 3339) to add a `tags` parameter:

  ```zig
  pub fn createWorkspaceItemTask(
      allocator: std.mem.Allocator,
      db: *sqlite.SqliteBackend,
      id: []const u8,
      name: []const u8,
      workspace_item_id: []const u8,
      task_type: []const u8,
      description: ?[]const u8,
      tags: ?[]const u8,  // JSON-encoded array string; null = no tags
  ) !WorkspaceItemTaskInfo {
  ```

- [ ] **Step 3.2** — Add `tags` to the INSERT (inside the dynamic SQL builder around line 3386, after the `description` column appending):

  ```zig
  // Same pattern as description: null → omit column (DEFAULT '' applies);
  // "" → SQL '' literal (NOT bound via `?`, to avoid the empty-slice-as-NULL
  // bind footgun, see memory `sqlite-backend-empty-slice-binds-as-null`);
  // "x…" → bind via `?`.
  if (tags) |t| {
      if (t.len == 0) {
          try cols_buf.appendSlice(allocator, ", tags");
          try vals_buf.appendSlice(allocator, ", ''");
      } else {
          try cols_buf.appendSlice(allocator, ", tags");
          try vals_buf.appendSlice(allocator, ", ?");
          try bind_values.append(allocator, t);
      }
  }
  ```

- [ ] **Step 3.3** — Add `tags` to the returned `WorkspaceItemTaskInfo` (around line 3414):

  ```zig
  return WorkspaceItemItemTaskInfo{
      .id = try allocator.dupe(u8, id),
      .name = try allocator.dupe(u8, name),
      .workspace_item_id = try allocator.dupe(u8, workspace_item_id),
      .task_type = try allocator.dupe(u8, task_type),
      .routine = null,
      .description = try allocator.dupe(u8, returned_desc),
      .tags = try allocator.dupe(u8, tags orelse ""),
  };
  ```

- [ ] **Step 3.4** — Update the 2 call sites of `createWorkspaceItemTask`:
  - `src/ai_workflow/tui/http_handlers/task_create.zig:343` — pass `null` (tags not yet accepted at the HTTP boundary; will be wired in Task 6).
  - Any other callers (search via `rg "createWorkspaceItemTask\(" src/`). Pass `null` for now.

  Run `timeout 180 zig build install:linux:system 2>&1 | tail -n 5` to catch any missed callsite (lazy-analysis trap).

- [ ] **Step 3.5** — Run `timeout 180 zig build test --summary all 2>&1 | tail -n 5`. Expected: clean (signature change is propagated; behavior unchanged when tags=null).

- [ ] **Step 3.6** — Commit: `git add -A && git commit -m "feat(llm_history): createWorkspaceItemTask accepts tags JSON"`.

### Task 4 — Backend: `getWorkspaceItemTask` reads `tags`

**Goal:** The single-task fetch reads the `tags` column and parses it into the `WorkspaceItemTaskInfo.tags` field.

**File:** `src/ai_workflow/tui/llm_history.zig`

- [ ] **Step 4.1** — Update the SELECT in `getWorkspaceItemTask` (around line 3436) to add `tags` to the column list. New column index for tags = 7 (after `task_type` at index 6). Update the comment.

- [ ] **Step 4.2** — Update the constructor (around line 3442) to assign the tags from `row.values[7]`:

  ```zig
  // tags is NOT NULL DEFAULT '' (Migration 067) so the row value
  // is always present. dupe unconditionally (empty slice still gets
  // a fresh allocation so deinit can free it consistently).
  .tags = try allocator.dupe(u8, row.values[7]),
  ```

- [ ] **Step 4.3** — Update the column index comments throughout the function (all `row.values[N]` references after the tags column shift by 1).

- [ ] **Step 4.4** — Run `timeout 180 zig build install:linux:system 2>&1 | tail -n 5`. Expected: clean.

- [ ] **Step 4.5** — Run `timeout 180 zig build test --summary all 2>&1 | tail -n 5`. Expected: clean.

- [ ] **Step 4.6** — Commit: `git add -A && git commit -m "feat(llm_history): getWorkspaceItemTask reads tags column"`.

### Task 5 — Backend: `listWorkspaceItemTasksWithCursor` reads `tags` (kanban-list join)

**Goal:** The kanban-list query (the join path that powers the board) reads the `tags` column and exposes it on each task.

**File:** `src/ai_workflow/tui/llm_history.zig`

- [ ] **Step 5.1** — Locate `listWorkspaceItemTasksWithCursor` (around line 3601). Find the SELECT statement that JOINs `routines` and `sessions` onto `workspace_item_tasks t`.

- [ ] **Step 5.2** — Add `t.tags` to the SELECT column list. Update the column index for every column that follows in the same projection.

- [ ] **Step 5.3** — Update the row → struct mapping (around line 3654) to assign the tags from `row.values[N]`:

  ```zig
  .tags = try allocator.dupe(u8, row.values[N]),  // the new tags index
  ```

  Update the comment with the column index number.

- [ ] **Step 5.4** — Run `timeout 180 zig build install:linux:system 2>&1 | tail -n 5`. Expected: clean.

- [ ] **Step 5.5** — Run `timeout 180 zig build test --summary all 2>&1 | tail -n 5`. Expected: clean.

- [ ] **Step 5.6** — Commit: `git add -A && git commit -m "feat(llm_history): listWorkspaceItemTasksWithCursor reads tags"`.

### Task 6 — Backend: wire layer (http_response.zig) gains `tags` field

**Goal:** The wire struct `WorkspaceItemTaskResponse`, `TaskCreateRequest`, `TaskUpdateRequest` all gain `tags`. Wire the JSON-encoding contract so the frontend sees `tags: string`.

**File:** `src/ai_workflow/tui/http_handlers/http_response.zig`

- [ ] **Step 6.1** — Add `tags` to `WorkspaceItemTaskResponse` (around line 453, after `needs_human_review`):

  ```zig
  /// JSON-encoded array of tag strings (Migration 067). Empty string
  /// means the task has no tags. Frontend decodes via JSON.parse.
  tags: []const u8 = "",
  ```

- [ ] **Step 6.2** — Add `tags` to `TaskCreateRequest`:

  ```zig
  /// JSON-encoded array of tag strings (Migration 067). null/undefined
  /// = no tags supplied (same as empty array).
  tags: ?[]const u8 = null,
  ```

- [ ] **Step 6.3** — Add `tags` to `TaskUpdateRequest` (similar shape; null = don't change, "" = clear all, JSON array = replace).

- [ ] **Step 6.4** — Run `timeout 180 zig build install:linux:system 2>&1 | tail -n 5`. Expected: clean.

- [ ] **Step 6.5** — Commit: `git add -A && git commit -m "feat(wire): tags field on task create/update/list responses"`.

### Task 7 — Backend: `task_create.zig` accepts `tags`

**Goal:** The HTTP handler `tasksCreateHandler` accepts `tags: ?[]const u8` from the body, validates it (parse JSON array, trim, dedupe, char whitelist, length cap), persists via the model.

**File:** `src/ai_workflow/tui/http_handlers/task_create.zig`

- [ ] **Step 7.1** — Write the failing test. Create `src/ai_workflow/tui/http_handlers/task_create_tags_test.zig` with 8 tests:
  - `tags: ["bug","urgent"]` → 201 + response includes `tags: '["bug","urgent"]'`
  - `tags: null` → 201 + `tags: ''`
  - `tags: ""` → 201 + `tags: ''`
  - `tags: [""]` → 400 `InvalidTags`
  - `tags: ["  "]` (only whitespace) → 400 `InvalidTags` (empty after trim)
  - `tags: ["with space"]` → 400 `InvalidTags` (forbidden char)
  - `tags: ["a".repeat(51)]` → 400 `InvalidTags` (length cap)
  - `tags: ["bug","Bug"]` → 201 + dedupe → `tags: '["bug"]'`
  - `tags: "[not json]"` → 400 `InvalidJson` (the parseFromSliceLeaky on the body fails first; that's OK)

  Run `timeout 180 zig build test --summary all 2>&1 | tail -n 5`. Expected: 8 tests fail.

- [ ] **Step 7.2** — Add the validation error variant to `TaskCreateError` (around line 50, after `Canceled`):

  ```zig
  InvalidTags,
  ```

- [ ] **Step 7.3** — Add the message mapping in the handler (around line 580):

  ```zig
  error.InvalidTags => "tags: empty, too long (>50 chars), or contain forbidden characters (only a-zA-Z0-9_- allowed)",
  ```

- [ ] **Step 7.4** — Add the validation + persistence. In `createStandardTask` (around line 337), call a new helper `validateAndNormalizeTags(allocator, input.body.tags) catch return error.InvalidTags;` and pass the normalized result to `createWorkspaceItemTask`. The helper lives in a new `src/ai_workflow/tui/http_handlers/tags_validation.zig` file (testable directly):

  ```zig
  pub fn validateAndNormalizeTags(allocator: std.mem.Allocator, raw: ?[]const u8) ![]u8 {
      if (raw == null or raw.?.len == 0) return allocator.dupe(u8, "");
      const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw.?, .{}) catch return error.InvalidTags;
      defer parsed.deinit();
      if (parsed.value != .array) return error.InvalidTags;
      const arr = parsed.value.array;
      if (arr.items.len == 0) return allocator.dupe(u8, "");
      var seen = std.StringHashMapUnmanaged(void) = .empty;
      defer seen.deinit(allocator);
      var out: std.ArrayList(u8) = .empty;
      try out.append(allocator, '[');
      for (arr.items) |item, i| {
          if (item != .string) return error.InvalidTags;
          var tag = std.mem.trim(u8, item.string, " \t\n");
          if (tag.len == 0) return error.InvalidTags;
          if (tag.len > 50) return error.InvalidTags;
          for (tag) |c| {
              const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                  (c >= '0' and c <= '9') or c == '_' or c == '-';
              if (!ok) return error.InvalidTags;
          }
          const lower = try allocator.dupe(u8, tag);
          defer allocator.free(lower);
          for (lower) |*c| c.* = std.ascii.toLower(c.*);
          const gop = try seen.getOrPut(allocator, lower);
          if (gop.found_existing) continue;  // duplicate (case-insensitive)
          if (i > 0) try out.append(allocator, ',');
          try out.append(allocator, '"');
          try out.appendSlice(allocator, tag);  // preserve original casing
          try out.append(allocator, '"');
      }
      try out.append(allocator, ']');
      return out.toOwnedSlice(allocator);
  }
  ```

- [ ] **Step 7.5** — Wire the validated tags into `createWorkspaceItemTask` (around line 343):

  ```zig
  const validated_tags = try validateAndNormalizeTags(allocator, input.body.tags);
  defer allocator.free(validated_tags);

  const task = ai_mod.workspace_item_tasks.createWorkspaceItemTask(
      allocator,
      db,
      task_id,
      input.body.name,
      input.item_id,
      "standard",
      input.body.description,
      validated_tags,
  ) catch return error.StandardTaskCreateFailed;
  ```

- [ ] **Step 7.6** — Add `tags` to the response struct (`StandardResponse` around line 159):

  ```zig
  tags: []const u8 = "",
  ```

  And serialize it (around line 651):

  ```zig
  .standard => |r| res.jsonResponse(.{
      .status_code = 201,
      .data = try std.json.Stringify.valueAlloc(
          allocator,
          StandardResponse{
              .id = r.task_id,
              .name = r.name,
              .workspace_item_id = r.workspace_item_id,
              .session_id = r.session_id,
              .kanban_column_id = r.kanban_column_id,
              .kanban_position = r.kanban_position,
              tags = validated_tags,
          },
          .{},
      ),
  }),
  ```

- [ ] **Step 7.7** — Register the test in `src/ai_workflow/tui/http_handlers/http_handlers_test_runner.zig` (search for the existing tag test runner; add `_ = @import("task_create_tags_test.zig");` next to the other `task_create_*_test.zig` imports).

- [ ] **Step 7.8** — Run `timeout 180 zig build test --summary all 2>&1 | tail -n 5`. Expected: 8 tests pass.

- [ ] **Step 7.9** — Run `timeout 180 zig build install:linux:system 2>&1 | tail -n 5`. Expected: clean.

- [ ] **Step 7.10** — Commit: `git add -A && git commit -m "feat(task_create): accept + validate + persist tags"`.

### Task 8 — Backend: `task_update.zig` accepts `tags`

**Goal:** The HTTP handler `tasksUpdateHandler` (and the simple variant) accepts `tags: ?[]const u8` from the body, validates it, persists it.

**File:** `src/ai_workflow/tui/http_handlers/task_update.zig`

- [ ] **Step 8.1** — Write the failing test. Create `src/ai_workflow/tui/http_handlers/task_update_tags_test.zig` with 5 tests (mirror the create tests):
  - `tags: ["bug","urgent"]` → 200 + tags persisted
  - `tags: null` → 200 + tags unchanged (null = don't update)
  - `tags: ""` → 200 + tags cleared (empty array)
  - `tags: [""]` → 400 `InvalidTags`
  - `tags: ["with space"]` → 400 `InvalidTags`

  Run `timeout 180 zig build test --summary all 2>&1 | tail -n 5`. Expected: 5 tests fail.

- [ ] **Step 8.2** — Add the validation error variant, message mapping, and `validateAndNormalizeTags` call (mirror Task 7's pattern). Persist via `db.exec`:

  ```zig
  if (input.body.tags != null) {
      const validated = validateAndNormalizeTags(allocator, input.body.tags) catch return error.InvalidTags;
      defer allocator.free(validated);
      db.exec(allocator,
          "UPDATE workspace_item_tasks SET tags = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
          &.{ validated, task_id },
      ) catch return error.TaskUpdateFailed;
  }
  ```

  Note: empty string `validated == ""` correctly triggers the empty-string-binds-as-NULL footgun. Use the same SQL literal pattern as in Task 3:

  ```zig
  // Empty-string: SQL literal '' (NOT bound via `?`).
  // Value: bind it.
  if (validated.len == 0) {
      db.exec(allocator,
          "UPDATE workspace_item_tasks SET tags = '', updated_at = CURRENT_TIMESTAMP WHERE id = ?",
          &.{task_id},
      ) catch return error.TaskUpdateFailed;
  } else {
      // ... the bind-via-? path above
  }
  ```

- [ ] **Step 8.3** — Register the test in `src/ai_workflow/tui/http_handlers/http_handlers_test_runner.zig`.

- [ ] **Step 8.4** — Run `timeout 180 zig build test --summary all 2>&1 | tail -n 5`. Expected: 5 tests pass.

- [ ] **Step 8.5** — Run `timeout 180 zig build install:linux:system 2>&1 | tail -n 5`. Expected: clean.

- [ ] **Step 8.6** — Commit: `git add -A && git commit -m "feat(task_update): accept + validate + persist tags"`.

### Task 9 — Frontend: `Task.tags?` interface + store updates

**Goal:** The frontend `Task` interface gains `tags?: string[]`. The `createTask` + `updateTaskSimple` API functions accept `tags?: string[]`.

**Files:** `src/apps/desktop/src/stores/workspaces.ts`, `src/apps/desktop/src/api/index.ts`

- [ ] **Step 9.1** — Add `tags?: string[]` to the `Task` interface in `workspaces.ts` (around line 161, after `last_finish_reason`):

  ```ts
  // NEW (kanban task tags feature). Array of free-form tag strings.
  // Optional for backwards compat with legacy task literals in tests.
  // Empty array = no tags.
  tags?: string[]
  ```

- [ ] **Step 9.2** — Update `api.createTask` signature in `api/index.ts` (around line 540) to accept `tags?: string[]`. Inside the function body, encode the array as a JSON string and put it in the request body:

  ```ts
  export async function createTask(
      workspaceId: string,
      itemId: string,
      params: {
          name: string
          description?: string
          taskType?: 'standard' | 'routine' | 'memory'
          routine?: { ... }
          memory?: { ... }
          isAutoRetryUntilStop?: string
          tags?: string[]  // ← NEW
      },
  ): Promise<Task> {
      // ... existing logic ...
      if (params.tags && params.tags.length > 0) {
          body.tags = JSON.stringify(params.tags)
      }
      // ...
  }
  ```

- [ ] **Step 9.3** — Update `api.updateTaskSimple` signature (around line 618) to accept `tags?: string[]`. Same JSON-encode logic.

- [ ] **Step 9.4** — Update `api.updateTask` (around line 596) similarly (it's a `Partial<Task>` wrapper — just verify the wire encoding works through it).

- [ ] **Step 9.5** — Decode `tags` on the response side: the frontend `Task` interface has `tags?: string[]`, but the wire returns `tags: string` (JSON-encoded). Add a decode helper or do it inline at each fetch site:

  ```ts
  // In workspacesStore.fetchKanbanTasks, after the API call:
  tasks.forEach((t: any) => {
      try { t.tags = JSON.parse(t.tags ?? '[]') } catch { t.tags = [] }
  })
  ```

  Or add a normalization helper at the API module level. Whichever is cleaner — leave the choice to the implementer.

- [ ] **Step 9.6** — Run `timeout 180 cd src/apps/desktop && bun run build 2>&1 | tail -n 5`. Expected: clean.

- [ ] **Step 9.7** — Run `timeout 180 bunx vitest run 2>&1 | tail -n 5`. Expected: clean (no existing tests should break — `tags?` is optional).

- [ ] **Step 9.8** — Commit: `git add -A && git commit -m "feat(frontend): Task.tags + createTask/updateTaskSimple accept tags"`.

### Task 10 — Frontend: `KanbanTagsInput.vue` chip input component

**Goal:** The reusable chip input component: type + Enter to add, ✕ to remove, Backspace on empty removes last, deterministic color from hash.

**File:** `src/apps/desktop/src/components/kanban/KanbanTagsInput.vue`

- [ ] **Step 10.1** — Create the component. Props:

  ```ts
  interface Props {
      modelValue: string[]  // v-model
      testId?: string  // for testing
  }
  ```

  Emits: `update:modelValue: [tags: string[]]`.

- [ ] **Step 10.2** — Implement the component (template + script + scoped style):
  - **Local `draftInput: ref<string>`** — what the user is typing.
  - **Add logic** (called on Enter or comma):
    - Trim, validate `[a-zA-Z0-9_-]` only, length ≤ 50.
    - Case-insensitive dedupe against existing tags.
    - On valid: append to local array, emit `update:modelValue`.
  - **Remove logic** (called on chip ✕ click):
    - Filter out, emit.
  - **Backspace-on-empty logic** (called on `@keydown.backspace` when `draftInput` is empty):
    - Remove the LAST chip, emit.
  - **Color logic** (helper function `tagColor(tag: string): string`):
    - `djb2(tag.toLowerCase()) % 6` → 1 of 6 colors.
    - Returns `{ bg: string, border: string, text: string }` object.
  - **Layout:**
    ```
    <div flex flex-wrap gap-1>
      <span v-for="tag" :style="colors[tag]"> {{ tag }} <button @click="remove">✕</button> </span>
      <input v-model="draftInput" @keydown.enter.prevent="commitDraft" @keydown.backspace="onBackspace" />
    </div>
    ```
  - **Style:** use the 6-color palette from the design doc (alpha 0.18 bg, alpha 0.45 border, full text color).

- [ ] **Step 10.3** — Write the failing test. Create `src/apps/desktop/src/__tests__/KanbanTagsInput.spec.ts` with 8 tests:
  - Renders empty when `modelValue = []`
  - Renders existing tags as chips
  - Typing a tag + Enter adds it to the array + clears the input
  - Typing a tag + comma adds it
  - ✕ click removes the tag
  - Backspace on empty input removes the last tag
  - Duplicate (case-insensitive) does NOT add a duplicate
  - Forbidden char shows inline error (or rejects the input — pick one and test it)
  - Long tag (>50 chars) is rejected

  Run `timeout 180 bunx vitest run src/__tests__/KanbanTagsInput.spec.ts 2>&1 | tail -n 5`. Expected: tests fail (component doesn't exist yet).

- [ ] **Step 10.4** — Implement the component to make the tests pass.

- [ ] **Step 10.5** — Run `timeout 180 bunx vitest run src/__tests__/KanbanTagsInput.spec.ts 2>&1 | tail -n 5`. Expected: all tests pass.

- [ ] **Step 10.6** — Run `timeout 180 cd src/apps/desktop && bun run build 2>&1 | tail -n 5`. Expected: clean.

- [ ] **Step 10.7** — Commit: `git add -A && git commit -m "feat(frontend): KanbanTagsInput chip input component"`.

### Task 11 — Frontend: `KanbanTaskDetailDialog` renders tags section

**Goal:** The dialog renders `<KanbanTagsInput>` between description and unattended-mode, in both create and edit modes. Edit mode pre-fills with existing tags.

**File:** `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue`

- [ ] **Step 11.1** — Add `tags: ref<string[]>([])` to the dialog's form state (around line 139, alongside `name`, `description`, `unattended`).

- [ ] **Step 11.2** — Initialize `tags` from `props.task.tags` on edit-mode load (in the `watch` around line 169):

  ```ts
  if (isCreateMode.value) {
      tags.value = []
  } else if (props.task) {
      tags.value = props.task.tags ?? []
  }
  ```

- [ ] **Step 11.3** — Include `tags` in the `create` emit payload (around line 216):

  ```ts
  emit('create', {
      mode: 'create',
      name: name.value.trim(),
      description: description.value,
      is_auto_retry_until_stop: unattended.value,
      tags: tags.value,  // ← NEW
  })
  ```

- [ ] **Step 11.4** — Include `tags` in the `save` emit payload (around line 230):

  ```ts
  emit('save', {
      mode: 'edit',
      name: name.value.trim(),
      description: description.value,
      tags: tags.value,  // ← NEW
  })
  ```

- [ ] **Step 11.5** — Render the tags section in the template (between description and unattended-mode, around line 494):

  ```vue
  <div class="mt-4">
      <label class="block text-xs font-medium mb-2" style="color: var(--semantic-text-dim);">
          Tags
      </label>
      <KanbanTagsInput
          v-model="tags"
          :test-id="isCreateMode ? 'kanban-task-detail-create-tags' : 'kanban-task-detail-tags'"
      />
  </div>
  ```

  And import it at the top of the script:

  ```ts
  import KanbanTagsInput from './KanbanTagsInput.vue'
  ```

- [ ] **Step 11.6** — Update the emit type definitions (around line 110):

  ```ts
  save: [payload: { mode: 'edit'; name: string; description: string; tags: string[] }]
  create: [payload: { mode: 'create'; name: string; description: string; is_auto_retry_until_stop: '0' | '1'; tags: string[] }]
  ```

- [ ] **Step 11.7** — Write the test. Add 3 new tests to `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.tags.spec.ts`:
  - Renders tags input section
  - Edit mode pre-fills tags from `task.tags`
  - Create emit includes `tags`

  Run `timeout 180 bunx vitest run src/__tests__/KanbanTaskDetailDialog.tags.spec.ts 2>&1 | tail -n 5`. Expected: tests fail.

- [ ] **Step 11.8** — Make the tests pass by completing the wiring.

- [ ] **Step 11.9** — Run `timeout 180 cd src/apps/desktop && bun run build 2>&1 | tail -n 5`. Expected: clean.

- [ ] **Step 11.10** — Run `timeout 180 bunx vitest run 2>&1 | tail -n 5`. Expected: clean (full suite passes).

- [ ] **Step 11.11** — Commit: `git add -A && git commit -m "feat(frontend): KanbanTaskDetailDialog renders tags section"`.

### Task 12 — Frontend: `WorkspaceItemTaskCard` renders tags row

**Goal:** The kanban card renders up to 3 tag chips below the title, with `+N more` link if more than 3.

**File:** `src/apps/desktop/src/components/workspace/WorkspaceItemTaskCard.vue`

- [ ] **Step 12.1** — Add the tags row to the template (around line 487, before the description preview). Mirror the `v-if="task.description"` pattern:

  ```vue
  <div
      v-if="task.tags && task.tags.length > 0"
      class="flex items-center gap-1 flex-wrap"
      data-testid="workspace-item-task-card-tags"
  >
      <span
          v-for="(tag, idx) in visibleTags"
          :key="tag"
          class="text-[10px] px-1.5 py-0.5 rounded font-medium"
          :style="tagChipStyle(tag)"
          :data-testid="`workspace-item-task-card-tag-${tag}`"
      >
          {{ tag }}
      </span>
      <button
          v-if="extraTagsCount > 0"
          type="button"
          @click.stop="emit('viewTaskDetail', task.id)"
          class="text-[10px] underline"
          style="color: var(--semantic-text-dim);"
          :data-testid="`workspace-item-task-card-tags-more`"
      >
          +{{ extraTagsCount }} more
      </button>
  </div>
  ```

- [ ] **Step 12.2** — Add the computed properties to the script:

  ```ts
  const visibleTags = computed<string[]>(() => (task.value.tags ?? []).slice(0, 3))
  const extraTagsCount = computed<number>(() => Math.max(0, (task.value.tags ?? []).length - 3))

  function tagChipStyle(tag: string): Record<string, string> {
      const palette = [
          { bg: 'rgba(139, 92, 246, 0.18)', border: 'rgba(139, 92, 246, 0.45)', text: '#a78bfa' },
          { bg: 'rgba(59, 130, 246, 0.18)', border: 'rgba(59, 130, 246, 0.45)', text: '#60a5fa' },
          { bg: 'rgba(34, 197, 94, 0.18)', border: 'rgba(34, 197, 94, 0.45)', text: '#4ade80' },
          { bg: 'rgba(245, 158, 11, 0.18)', border: 'rgba(245, 158, 11, 0.45)', text: '#fbbf24' },
          { bg: 'rgba(249, 115, 22, 0.18)', border: 'rgba(249, 115, 22, 0.45)', text: '#fb923c' },
          { bg: 'rgba(239, 68, 68, 0.18)', border: 'rgba(239, 68, 68, 0.45)', text: '#f87171' },
      ]
      // djb2 hash (same as KanbanTagsInput.vue for visual consistency)
      let hash = 5381
      for (const c of tag.toLowerCase()) hash = ((hash << 5) + hash + c.charCodeAt(0)) >>> 0
      const c = palette[hash % 6]
      return {
          backgroundColor: c.bg,
          border: `1px solid ${c.border}`,
          color: c.text,
      }
  }
  ```

- [ ] **Step 12.3** — Write the test. Create `src/apps/desktop/src/__tests__/WorkspaceItemTaskCard.tags.spec.ts` with 5 tests:
  - Tags row doesn't render when `task.tags` is empty/undefined
  - Tags row renders chips when `task.tags.length > 0`
  - Renders at most 3 chips; shows `+N more` link when `task.tags.length > 3`
  - `+N more` link emits `viewTaskDetail`
  - Each chip has the deterministic color from `tagChipStyle`

  Run `timeout 180 bunx vitest run src/__tests__/WorkspaceItemTaskCard.tags.spec.ts 2>&1 | tail -n 5`. Expected: tests fail.

- [ ] **Step 12.4** — Make the tests pass.

- [ ] **Step 12.5** — Run `timeout 180 cd src/apps/desktop && bun run build 2>&1 | tail -n 5`. Expected: clean.

- [ ] **Step 12.6** — Run `timeout 180 bunx vitest run 2>&1 | tail -n 5`. Expected: clean (full suite passes).

- [ ] **Step 12.7** — Commit: `git add -A && git commit -m "feat(frontend): WorkspaceItemTaskCard renders tags row"`.

### Task 13 — Frontend: workspace store handles tag persistence

**Goal:** The store's `addTask` (create) and `updateTaskDetails` (edit) pass `tags` through to the API.

**File:** `src/apps/desktop/src/stores/workspaces.ts`

- [ ] **Step 13.1** — Find `addTask` in the store (around line 618). Pass `tags` to `api.createTask`:

  ```ts
  const newTask = await api.createTask(workspaceId, itemId, {
      name: ...,
      description: ...,
      taskType: ...,
      tags: ...,  // ← NEW
  })
  ```

  Likely the surrounding context is a kanban-task-detail-dialog handler. Make sure the tag values flow from the dialog's `create` emit to this call.

- [ ] **Step 13.2** — Find `updateTaskDetails` (around line 1887). Pass `tags` to `api.updateTask` and/or `api.updateTaskSimple`:

  ```ts
  await api.updateTaskSimple(taskId, {
      name: ...,
      description: ...,
      tags: ...,  // ← NEW
  })
  ```

- [ ] **Step 13.3** — Write the test. Add 2 tests to `src/apps/desktop/src/__tests__/workspacesStore.tags.spec.ts`:
  - `addTask` passes `tags` to `api.createTask`
  - `updateTaskDetails` passes `tags` to `api.updateTaskSimple`

  Run `timeout 180 bunx vitest run src/__tests__/workspacesStore.tags.spec.ts 2>&1 | tail -n 5`. Expected: tests fail.

- [ ] **Step 13.4** — Make the tests pass.

- [ ] **Step 13.5** — Run `timeout 180 cd src/apps/desktop && bun run build 2>&1 | tail -n 5`. Expected: clean.

- [ ] **Step 13.6** — Run `timeout 180 bunx vitest run 2>&1 | tail -n 5`. Expected: clean.

- [ ] **Step 13.7** — Commit: `git add -A && git commit -m "feat(store): addTask + updateTaskDetails pass tags through"`.

### Task 14 — End-to-end smoke test (port 8080)

**Goal:** Verify the full path works: create a task with tags via curl, GET the task list, see tags rendered, PUT updated tags, DELETE clears tags.

- [ ] **Step 14.1** — Build the binary:

  ```bash
  timeout 180 zig build install:linux:system
  ```

  Expected: clean.

- [ ] **Step 14.2** — Boot isolated server on port 8080 (NEVER 8081):

  ```bash
  rm -rf /tmp/nalar-tags-smoke
  env -i HOME=/tmp/nalar-tags-smoke PATH=$PATH \
      nohup ./zig-out/bin/nalar --port 8080 > /tmp/tags-smoke.log 2>&1 < /dev/null &
  disown 2>/dev/null
  sleep 6
  ```

- [ ] **Step 14.3** — Create workspace + kanban + task with tags:

  ```bash
  WS=$(curl -sS -X POST http://127.0.0.1:8080/api/workspaces \
      -H 'content-type: application/json' -d '{"name":"tags-smoke"}' \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')

  ITEM=$(curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/kanban" \
      -H 'content-type: application/json' -d '{"name":"Tags Board","path":"/tmp"}' \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["item"]["id"])')

  TASK=$(curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/tasks" \
      -H 'content-type: application/json' \
      -d '{"name":"Fix login bug","tags":["bug","urgent","frontend"]}' \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')

  echo "Created task: $TASK"
  ```

  Expected: `id` prints (the new task's id).

- [ ] **Step 14.4** — GET the task list, verify `tags` is in the response:

  ```bash
  curl -sS "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/tasks" | python3 -m json.tool
  ```

  Expected: response includes `tasks: [{ ..., "tags": "[\"bug\",\"urgent\",\"frontend\"]" }]`.

- [ ] **Step 14.5** — Test validation: try invalid tags, expect 400:

  ```bash
  curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/tasks" \
      -H 'content-type: application/json' \
      -d '{"name":"bad","tags":["with space"]}' \
      -w "\nHTTP %{http_code}\n"

  curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/tasks" \
      -H 'content-type: application/json' \
      -d '{"name":"bad2","tags":[""]}' \
      -w "\nHTTP %{http_code}\n"
  ```

  Expected: both return `HTTP 400` with the `InvalidTags` message.

- [ ] **Step 14.6** — UPDATE task tags:

  ```bash
  curl -sS -X PUT "http://127.0.0.1:8080/api/workspaces/tasks/$TASK" \
      -H 'content-type: application/json' \
      -d '{"tags":["bug","newtag"]}' \
      -w "\nHTTP %{http_code}\n"
  ```

  Expected: `HTTP 200`. Re-GET and verify `tags: '["bug","newtag"]'`.

- [ ] **Step 14.7** — Test dedupe: update with `["Bug","bug"]`:

  ```bash
  curl -sS -X PUT "http://127.0.0.1:8080/api/workspaces/tasks/$TASK" \
      -H 'content-type: application/json' \
      -d '{"tags":["Bug","bug"]}' \
      -w "\nHTTP %{http_code}\n"
  ```

  Expected: `HTTP 200`. Re-GET and verify `tags: '["Bug"]'` (first occurrence preserved).

- [ ] **Step 14.8** — Cleanup:

  ```bash
  SMOKE_PID=$(ps aux | grep "nalar --port 8080" | grep -v grep | awk '{print $2}')
  [ -n "$SMOKE_PID" ] && kill $SMOKE_PID
  ```

- [ ] **Step 14.9** — Commit: `git add -A && git commit -m "test(smoke): verify kanban task tags end-to-end"`.

### Task 15 — Update NALAR.md + memory

**Goal:** Document the new feature in `NALAR.md` changelog. Update project memory if any non-obvious gotcha was encountered.

- [ ] **Step 15.1** — Add a new changelog entry to `NALAR.md` under `## Recent changes`:

  ```markdown
  ### YYYY-MM-DD: Kanban task tags (free-form string list)

  **What landed:**
  - New column on `workspace_item_tasks`: `tags TEXT NOT NULL DEFAULT ''` (Migration 067). JSON-encoded array of strings.
  - Wire shape: `WorkspaceItemTaskResponse.tags` (string, JSON-encoded), `TaskCreateRequest.tags`, `TaskUpdateRequest.tags`.
  - Frontend: `KanbanTagsInput` chip input component. `<KanbanTagsInput>` rendered between description and unattended-mode toggle in `KanbanTaskDetailDialog` (both create + edit modes).
  - `WorkspaceItemTaskCard` renders up to 3 colored tag chips below the title (with `+N more` link if more).

  **Decisions taken:**
  - Free-form string list (Option A) — chose simplicity over managed vocabulary. Forward-compatible with a future managed-tag migration (read the JSON array, create proper tag rows).
  - JSON string column, not a separate table — no SQL-level filtering needed in v1.
  - Per-tag char whitelist `[a-zA-Z0-9_-]` (GitHub-style). Per-tag length cap 50 chars.
  - Case-insensitive dedupe (preserve first-occurrence casing).
  - 6-color palette deterministically chosen via djb2 hash of lowercase tag name.

  **Out of scope (v1):**
  - Tag filtering on the kanban board (substring search later if needed).
  - Tag management page (no rename, no merge).
  - Tag autocomplete.
  - Tag rename propagation across tasks.

  **Plan:** docs/superpowers/plans/2026-07-28-kanban-task-tags.md
  **Spec:** docs/superpowers/specs/2026-07-28-kanban-task-tags-design.md
  ```

- [ ] **Step 15.2** — If any non-obvious gotcha was encountered during the build, write a `.nalar/memories/kanban-tags-*` memory file. Otherwise skip.

- [ ] **Step 15.3** — Commit: `git add -A && git commit -m "docs: changelog entry for kanban task tags feature"`.

---

## End-to-end verification (run all in order)

```bash
cd /home/ginwa/ginwaaitoolbox

# Backend
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
rm -rf zig-out/bin
timeout 360 zig build 2>&1 | tail -n 5

# Frontend
cd src/apps/desktop
timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build 2>&1 | tail -n 5  # MUST use node, not bun
timeout 180 bunx vitest run 2>&1 | tail -n 5
timeout 240 bun run build 2>&1 | tail -n 5  # vue-tsc + vite (production build)

# Cross-compile smoke
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
    --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
    --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
```

All 7 must exit 0 with no errors.

## Pitfalls

- **Don't use `parseFromSlice` for the request body** — the per-request arena reaps everything; use `parseFromSliceLeaky` (project convention). Borrowed slice deinit footgun per memory `std-json-deep-copy-before-deinit`.
- **Don't bind empty `[]const u8` via `?`** — `SqliteBackend.exec` binds empty slices as SQL NULL (breaks NOT NULL). Use SQL `''` literal. See memory `sqlite-backend-empty-slice-binds-as-null`.
- **Don't `bun run build` to skip `vue-tsc`** — `bunx vitest run` doesn't type-check (per memory `bun-run-build-is-type-check-not-vitest`). Use Node for vue-tsc, not Bun (per memory `webapp-rebuild-bun-cjs-loader-skips-fs-readfilesync`).
- **Don't forget to register the migration in `allMigrations`** — defining the struct alone is a silent-skip bug. Per memory `migration-registration-trap`.
- **Don't introduce `std.posix.*` direct calls** — use `nalarcore.helpers.*` wrappers for cross-platform safety.
- **Don't rebase `zig build test` to validate production code paths** — lazy analysis misses callsites. Always run `zig build install:linux:system` (per memory `zig-build-test-catches-lazy-analysis-errors`).
- **Don't reuse `task.routine` or `task.kanban_column_id` allocation shapes** for the `tags` JSON string — they're separate heap allocations with their own deinit branches. Mirror the `description` pattern exactly.
- **Don't forget to free the `lower` slice** in `validateAndNormalizeTags` — case-insensitive dedupe key. Mirror the `tags_validation.zig` helper's `defer allocator.free(lower)` after the loop.
- **Don't try to render the tags row on non-kanban tasks** — the card is only used on kanban boards. The `WorkspaceItemTaskCard` is shared but the tags row is naturally hidden because non-kanban task objects don't carry tags.
- **Don't include the `+N more` link if `extraTagsCount === 0`** — the `v-if="extraTagsCount > 0"` handles this.
