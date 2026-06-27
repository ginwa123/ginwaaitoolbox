# Workspace Item Tasks: Sort by `updated_at` DESC

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make workspace-item tasks in the sidebar sort by `updated_at` (newest first) so that renaming a task moves it to the top of the list.

**Architecture:** Mirror the existing `SessionSortField` / `SessionSortDirection` pattern in `llm_history.zig:44-53` to make the paginated tasks endpoint `sort_by`/`direction`-aware. Default the handler to `updated_at DESC` (the user's desired order) and use the sort field's value as the cursor so pagination stays stable. Add a SQLite index for `(workspace_item_id, updated_at DESC)` and a tiebreaker on `id` for deterministic keyset pagination. Update the frontend `api.getTasks` to pass the new params and add `updatedAt` to the `Task` TypeScript interfaces.

**Tech Stack:** Zig 0.16 (backend), TypeScript + Vue 3 + Pinia (frontend), SQLite (storage).

---

## File Structure

### Files to modify

| File | Why |
|---|---|
| `src/ai_workflow/tui/llm_history.zig` | Add `TaskSortField`/`TaskSortDirection` enums; thread sort params into `listWorkspaceItemTasksWithCursor` (currently hardcoded to `created_at DESC` at lines 2419-2430) |
| `src/ai_workflow/tui/http_handlers/tasks_list.zig` | Parse `sort_by`/`direction` query params (currently only parses `limit`/`cursor`); pass to DB fn; emit `next_cursor` using the sort field's value (currently always `created_at` at line 76) |
| `src/ai_workflow/tui/migration.zig` | Add `Migration042AddWorkspaceItemTasksUpdatedAtIndex` after `Migration041` at line 628 |
| `src/apps/desktop/src/api/index.ts` | Add `sortBy`/`direction` params to `getTasks` (lines 146-171); add `updated_at` to `Task` interface (lines 50-56) |
| `src/apps/desktop/src/stores/workspaces.ts` | Add `updatedAt` to local `Task` interface (lines 50-56); set `updatedAt: new Date()` in the local fallback in `addTask` (lines 442-449); thread sort params in `init` and `loadMoreTasks` |
| `src/ai_workflow/tui/http_handlers/tasks_list_test.zig` | Add static source checks for the new `sort_by`/`direction` plumbing |

### Files NOT modified (out of scope)

- `src/ai_workflow/tui/http_handlers/workspaces_list.zig` — workspaces list ORDER BY stays `created_at DESC` (the user's request is specifically about workspace-item tasks)
- `src/ai_workflow/tui/http_handlers/workspace_items_get.zig` — workspace items list ORDER BY stays `created_at DESC` (same reason)
- The session list sortable impl (`session_list.zig`/`llm_history.zig:182-214`) is the **reference pattern** we mirror — we don't change it.

### Test pattern

The repo uses static source checks (regex / substring matches on the .zig source) for handler/DB-fn contracts — see `tasks_list_test.zig:1-218`. The "why" preamble in that file (lines 1-29) explains why we don't stand up an in-process sqlite DB. **Follow the same pattern for the new tests.**

---

## Context

### What the user reported

Screenshot of the WORKSPACES sidebar shows workspace item "be" with tasks ordered as:
- `Task 12:54:20 AM` (newest by `created_at`)
- `Task 12:51:37 AM`
- `fix-scroll-jump-glitch`, `continue-nalar-desktop-execution`, `trace-tool-call-error`, `split-workspace-item-vue`, `zig-bash-tool-compatibility` (active)…
- …

The user wants the **most recently updated** task on top. So if they rename `trace-tool-call-error` to `tanya-intro`, it should jump to the top of the list.

### Why the current order is `created_at` (and not `updated_at`)

Both `workspaces_list.zig:47, 91, 137`, `llm_history.zig:2170, 2203, 2361, 2419-2430`, and `tasks_list.zig` all hardcode `ORDER BY created_at DESC`. The sort param plumbing exists for sessions (`SessionSortField` / `SessionSortDirection` at `llm_history.zig:44-53`, parsed by `session_list.zig:24-29`) but was never extended to workspaces.

### What already exists in the DB

- `workspaces.updated_at` (Migration 030) — but is **never re-stamped** (no `UPDATE` sets it; only Migration 030's initial backfill does)
- `workspace_items.updated_at` (Migration 031) — same, **never re-stamped**
- `workspace_item_tasks.updated_at` (Migration 034) — **IS re-stamped** on every `updateWorkspaceItemTask` and `updateTaskName` call (`llm_history.zig:2340, 1882`)

So **sorting tasks by `updated_at` is meaningful** (renaming a task updates it), but **sorting workspaces or workspace_items by `updated_at` would currently be a no-op** (the column is only set on insert, not on update). The user's request is therefore correctly scoped to tasks, where the column has live values.

### Why the session pattern is the right reference

`getSessionListWithCursor` at `llm_history.zig:143-261` already does the dynamic ORDER BY + cursor pattern. **It has a known bug** (cursor always uses `created_at` even when sorting by `updated_at` — see `llm_history.zig:195-199` and `session_list.zig:45-49`). For our tasks impl, we should do this right: build the cursor filter using the same field as the sort.

### Cursor pagination ↔ sort interaction

For stable keyset pagination when sorting by `updated_at DESC`:

```sql
WHERE workspace_item_id = ?
  AND (updated_at < ? OR (updated_at = ? AND id < ?))   -- DESC tiebreaker
ORDER BY updated_at DESC, id DESC
LIMIT N+1
```

The `(updated_at, id)` key is unique. The tiebreaker on `id` is required because many tasks can have the same `updated_at` (e.g. all created in the same second, or all batch-renamed by a script). Without it, the cursor filter `updated_at < 'X'` would skip rows with the same `updated_at` and the user would see tasks disappear across pages.

The existing `getSessionListWithCursor` does NOT have this tiebreaker (a known issue) — we will do it correctly for the new task list impl and leave the session impl as-is for this plan (out of scope).

### Date format

`updated_at` is stored as SQLite `DATETIME` (string like `"2026-06-10 12:34:56"`). String comparison works correctly for this format because it's lexicographic for ISO-ish formats. No casting needed.

---

## Tasks

### Task 1: Add `TaskSortField` and `TaskSortDirection` enums

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig:44-53` (add right after `SessionSortField`/`SessionSortDirection`)

- [ ] **Step 1: Write the failing test**

Add a static source check to `src/ai_workflow/tui/http_handlers/tasks_list_test.zig` (new test at the end of the file, after line 217). The check verifies the enum is declared in `llm_history.zig`:

```zig
test "llm_history exposes TaskSortField enum" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    const sig = "pub const TaskSortField = enum";
    if (std.mem.indexOf(u8, source, sig) == null) {
        std.debug.print(
            "\n!! {s} does not define `TaskSortField` enum !!\n" ++
                "   The tasks-list sort plumbing is missing the sort-field\n" ++
                "   enum that maps `sort_by=...` query strings to SQL columns.\n" ++
                "   Add the enum near SessionSortField (around line 44):\n" ++
                "     pub const TaskSortField = enum { created_at, updated_at, name };\n" ++
                "   See docs/superpowers/plans/2026-06-11-workspace-item-tasks-sort-by-updated-at.md.\n",
            .{LLM_HISTORY_PATH},
        );
        return error.TaskSortFieldMissing;
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test:ai_workflow:tui 2>&1 | tail -n 20`
Expected: FAIL with `error.TaskSortFieldMissing`

- [ ] **Step 3: Write minimal implementation**

In `src/ai_workflow/tui/llm_history.zig`, immediately after `SessionSortDirection` (line 53), add:

```zig
/// Sort field for the paginated workspace-item tasks endpoint
/// (`GET /api/workspaces/:wid/items/:iid/tasks`). Mirrors
/// `SessionSortField` (above) so the API surface is consistent.
/// `name` is included for completeness even though the default UI
/// sorts by `updated_at` — the user can sort by name later if they
/// want an alphabetical fallback.
pub const TaskSortField = enum { created_at, updated_at, name };

/// Sort direction for workspace-item tasks. Asc/desc. Mirrors
/// `SessionSortDirection` (above).
pub const TaskSortDirection = enum { asc, desc };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test:ai_workflow:tui 2>&1 | tail -n 20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/llm_history.zig src/ai_workflow/tui/http_handlers/tasks_list_test.zig
git commit -m "feat(workspace-tasks): add TaskSortField/TaskSortDirection enums"
```

---

### Task 2: Make `listWorkspaceItemTasksWithCursor` sort-aware

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig:2398-2466` (`listWorkspaceItemTasksWithCursor`)

- [ ] **Step 1: Write the failing test**

Add a static source check to `tasks_list_test.zig` (after the new test from Task 1) that verifies the function signature now takes sort params:

```zig
test "listWorkspaceItemTasksWithCursor takes sort_field and sort_direction" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // The function must take sort_field and sort_direction. Use a
    // substring search for the parameter names since the exact
    // signature will vary.
    const has_sort_field = std.mem.indexOf(u8, source, "sort_field: TaskSortField") != null;
    const has_sort_direction = std.mem.indexOf(u8, source, "sort_direction: TaskSortDirection") != null;
    if (!has_sort_field or !has_sort_direction) {
        std.debug.print(
            "\n!! {s} does not thread sort_field/sort_direction into listWorkspaceItemTasksWithCursor !!\n" ++
                "   The sort plumbing was added at the handler but not threaded\n" ++
                "   into the DB function — the sort_by query param would be ignored.\n" ++
                "   Update the signature:\n" ++
                "     pub fn listWorkspaceItemTasksWithCursor(\n" ++
                "         allocator: std.mem.Allocator,\n" ++
                "         db: *sqlite.SqliteBackend,\n" ++
                "         workspace_item_id: []const u8,\n" ++
                "         limit: u32,\n" ++
                "         cursor: ?[]const u8,\n" ++
                "         sort_field: TaskSortField,\n" ++
                "         sort_direction: TaskSortDirection,\n" ++
                "     ) !struct { ... } {{ ... }}\n" ++
                "   See docs/superpowers/plans/2026-06-11-workspace-item-tasks-sort-by-updated-at.md.\n",
            .{LLM_HISTORY_PATH},
        );
        return error.SortParamsMissing;
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test:ai_workflow:tui 2>&1 | tail -n 20`
Expected: FAIL with `error.SortParamsMissing`

- [ ] **Step 3: Update the function signature and SQL building**

In `src/ai_workflow/tui/llm_history.zig`, replace the entire `listWorkspaceItemTasksWithCursor` function (lines 2398-2466) with the sort-aware version. The function header and doc comment change, and the SQL string construction gains the dynamic ORDER BY + cursor filter + tiebreaker.

```zig
/// List workspace item tasks with cursor pagination. The `cursor` is
/// the value of the `sort_field` for the last task from the previous
/// page; pass null to fetch the first page. The `sort_field` /
/// `sort_direction` controls the ORDER BY direction. The `id` column
/// is used as a tiebreaker for stable pagination when many tasks share
/// the same `updated_at` (e.g. all batch-renamed in one second).
///
/// Ordered by `sort_field sort_direction, id sort_direction` (newest
/// first when sort_direction is `desc`). Returns at most `limit`
/// tasks plus a `has_more` flag indicating whether at least one more
/// task exists after this page.
///
/// Cursor filter: `(sort_field, id) < (cursor_value, last_id)` for DESC,
/// or `>` for ASC. The last_id is encoded in the cursor as
/// `"<sort_value>|<id>"` by the handler. Mirrors
/// `getSessionListWithCursor` (above) for SQL building style.
pub fn listWorkspaceItemTasksWithCursor(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    limit: u32,
    cursor: ?[]const u8,
    sort_field: TaskSortField,
    sort_direction: TaskSortDirection,
) !struct {
    tasks: []WorkspaceItemTaskInfo,
    has_more: bool,
} {
    // Fetch `limit + 1` rows so we can detect "there are more pages"
    // without a separate COUNT query.
    const query_limit = limit + 1;
    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{query_limit});
    defer allocator.free(limit_str);

    // Build the ORDER BY column expression for the sort field. We
    // hardcode the column name (not the value) into the SQL string
    // — only the values are parameterized, so this is safe.
    const sort_col = switch (sort_field) {
        .created_at => "created_at",
        .updated_at => "updated_at",
        .name => "name",
    };
    const sort_dir_str = switch (sort_direction) {
        .asc => "ASC",
        .desc => "DESC",
    };
    const order_by = try std.fmt.allocPrint(
        allocator,
        "ORDER BY {s} {s}, id {s}",
        .{ sort_col, sort_dir_str, sort_dir_str },
    );
    defer allocator.free(order_by);

    // Cursor: encoded as "<sort_value>|<id>" by the handler. Split it
    // into the sort-field value (compared first) and the id (tiebreaker).
    // When cursor is null, no WHERE clause is added.
    const cursor_clause: []u8 = blk: {
        const c = cursor orelse break :blk try allocator.dupe(u8, "");
        defer allocator.free(c); // we'll re-allocate pieces below
        // The cursor format is "<sort_value>|<id>". For DATETIME columns
        // (created_at, updated_at) the value contains no '|' so the
        // split is unambiguous. For `name` a '|' in the name would
        // corrupt the split, but task names are user-typed and
        // unlikely to contain '|' — add a sanitizer in the handler if
        // that becomes a real problem.
        const pipe_idx = std.mem.indexOfScalar(u8, c, '|') orelse
            return error.MalformedCursor;
        const sort_value = c[0..pipe_idx];
        const id_value = c[pipe_idx + 1..];

        // For DESC: row should come AFTER the cursor pair in sort order,
        // which means sort_value < cursor.sort_value, OR sort_value
        // equals and id < cursor.id. For ASC: >. Build the clause.
        const cmp = switch (sort_direction) {
            .desc => "<",
            .asc => ">",
        };
        break :blk try std.fmt.allocPrint(
            allocator,
            " AND ({s} {s} '{s}' OR ({s} = '{s}' AND id {s} '{s}'))",
            .{ sort_col, cmp, sort_value, sort_col, sort_value, cmp, id_value },
        );
    };
    defer if (cursor_clause.len > 0) allocator.free(cursor_clause);

    const sql = try std.fmt.allocPrint(
        allocator,
        "SELECT id, name, workspace_item_id, session_id, created_at, updated_at FROM workspace_item_tasks WHERE workspace_item_id = ?{s} {s} LIMIT {s}",
        .{ cursor_clause, order_by, limit_str },
    );
    defer allocator.free(sql);

    var rows = try db.query(allocator, sql, &.{workspace_item_id});
    defer rows.deinit();

    var tasks = std.ArrayList(WorkspaceItemTaskInfo).empty;
    errdefer {
        for (tasks.items) |task| task.deinit(allocator);
        tasks.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const task = WorkspaceItemTaskInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .workspace_item_id = try allocator.dupe(u8, row.values[2]),
            .session_id = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .created_at = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .updated_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
        };
        try tasks.append(allocator, task);
        row.deinit(allocator);
    }

    const has_more = tasks.items.len > limit;
    if (has_more) {
        // Drop the extra row we fetched to detect has_more.
        const extra = tasks.pop().?;
        extra.deinit(allocator);
    }

    return .{
        .tasks = try tasks.toOwnedSlice(allocator),
        .has_more = has_more,
    };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test:ai_workflow:tui 2>&1 | tail -n 20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/llm_history.zig src/ai_workflow/tui/http_handlers/tasks_list_test.zig
git commit -m "feat(workspace-tasks): make listWorkspaceItemTasksWithCursor sort-aware with id tiebreaker"
```

---

### Task 3: Add `sort_by` / `direction` query param parsing to `tasksListHandler`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/tasks_list.zig:18-80` (the entire handler)

- [ ] **Step 1: Write the failing test**

Add static source checks to `tasks_list_test.zig` for the handler plumbing. Append after the Task 1-2 tests:

```zig
// ─── Contract 7: handler parses the sort_by query param ────────────────────

test "tasks_list handler parses the sort_by query param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "\"sort_by\"") == null and
        std.mem.indexOf(u8, source, "'sort_by'") == null)
    {
        std.debug.print(
            "\n!! {s} does not reference the `sort_by` query param !!\n" ++
                "   The sort plumbing is missing at the handler level — the\n" ++
                "   frontend cannot request a different sort order.\n" ++
                "   Restore the sort_by parse:\n" ++
                "     const sort_by_str = query.get(\"sort_by\") orelse \"updated_at\";\n" ++
                "     const sort_field = llm_history.enumFromString(llm_history.TaskSortField, sort_by_str) catch .updated_at;\n" ++
                "   See docs/superpowers/plans/2026-06-11-workspace-item-tasks-sort-by-updated-at.md.\n",
            .{HANDLER_PATH},
        );
        return error.SortByParamMissing;
    }
}

// ─── Contract 8: handler parses the direction query param ──────────────────

test "tasks_list handler parses the direction query param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "\"direction\"") == null and
        std.mem.indexOf(u8, source, "'direction'") == null)
    {
        std.debug.print(
            "\n!! {s} does not reference the `direction` query param !!\n" ++
                "   The sort plumbing is missing the direction toggle — the\n" ++
                "   user can never sort ascending.\n" ++
                "   Restore the direction parse:\n" ++
                "     const direction_str = query.get(\"direction\") orelse \"desc\";\n" ++
                "     const sort_direction = llm_history.enumFromString(llm_history.TaskSortDirection, direction_str) catch .desc;\n" ++
                "   See docs/superpowers/plans/2026-06-11-workspace-item-tasks-sort-by-updated-at.md.\n",
            .{HANDLER_PATH},
        );
        return error.DirectionParamMissing;
    }
}

// ─── Contract 9: handler passes sort params to the DB function ────────────

test "tasks_list handler passes sort_field and sort_direction to the DB fn" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler's call to listWorkspaceItemTasksWithCursor must
    // include sort_field and sort_direction args. We look for the
    // substring "sort_field," and "sort_direction" in the handler.
    if (std.mem.indexOf(u8, source, "sort_field,") == null or
        std.mem.indexOf(u8, source, "sort_direction") == null)
    {
        std.debug.print(
            "\n!! {s} does not pass sort_field/sort_direction to the DB fn !!\n" ++
                "   The handler parses the sort params but doesn't forward\n" ++
                "   them — the SQL still hardcodes the original ORDER BY.\n" ++
                "   Update the call site:\n" ++
                "     .listWorkspaceItemTasksWithCursor(allocator, sqlite_db, item_id, limit, cursor, sort_field, sort_direction) catch ...;\n" ++
                "   See docs/superpowers/plans/2026-06-11-workspace-item-tasks-sort-by-updated-at.md.\n",
            .{HANDLER_PATH},
        );
        return error.SortParamsNotForwarded;
    }
}
```

Also update the existing **Contract 3** test (`tasks_list handler calls listWorkspaceItemTasksWithCursor`, lines 106-129) to match the new error message hint — the call site now includes sort args, so the existing substring check is still satisfied. **No change needed** for that test.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test:ai_workflow:tui 2>&1 | tail -n 20`
Expected: FAIL with `error.SortByParamMissing` (and the other two)

- [ ] **Step 3: Update the handler**

In `src/ai_workflow/tui/http_handlers/tasks_list.zig`, add the `llm_history` import and the sort-param parsing. Also update the call site and the `next_cursor` emission. The file becomes:

```zig
const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
const llm_history = ai_mod.llm_history;

/// Default page size when the client doesn't pass `limit`.
const DEFAULT_PAGE_SIZE: u32 = 20;

/// Maximum page size (guards against a client asking for a million rows).
const MAX_PAGE_SIZE: u32 = 100;

/// Default sort field when the client doesn't pass `sort_by`.
/// `updated_at` is the default because that's what the user wants
/// to see (most recently renamed/updated task on top).
const DEFAULT_SORT_FIELD: llm_history.TaskSortField = .updated_at;

/// Default sort direction when the client doesn't pass `direction`.
/// `desc` matches the existing "newest first" behavior.
const DEFAULT_SORT_DIRECTION: llm_history.TaskSortDirection = .desc;

/// GET /api/workspaces/:workspace_id/items/:item_id/tasks
/// Optional query params:
///   - limit: u32, defaults to 20, max 100
///   - cursor: string in the form "<sort_field_value>|<id>" from the
///             previous page's `next_cursor`; pass undefined for the
///             first page
///   - sort_by: "created_at" | "updated_at" | "name", default "updated_at"
///   - direction: "asc" | "desc", default "desc"
/// Response: `{ tasks: [...], count, has_more, next_cursor }`
pub fn tasksListHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }) });
    }

    const query = req.query;

    // Parse limit (default 20, clamp to MAX_PAGE_SIZE; 0 → default).
    const limit_str = query.get("limit") orelse "20";
    const limit_parsed = std.fmt.parseInt(u32, limit_str, 10) catch DEFAULT_PAGE_SIZE;
    const limit: u32 = if (limit_parsed == 0)
        DEFAULT_PAGE_SIZE
    else if (limit_parsed > MAX_PAGE_SIZE)
        MAX_PAGE_SIZE
    else
        limit_parsed;

    // Parse sort_by (default: updated_at).
    const sort_by_str = query.get("sort_by") orelse "updated_at";
    const sort_field = llm_history.enumFromString(llm_history.TaskSortField, sort_by_str) catch DEFAULT_SORT_FIELD;

    // Parse direction (default: desc).
    const direction_str = query.get("direction") orelse "desc";
    const sort_direction = llm_history.enumFromString(llm_history.TaskSortDirection, direction_str) catch DEFAULT_SORT_DIRECTION;

    // Optional cursor — null when absent or empty. The cursor is the
    // "<sort_value>|<id>" pair from the previous page's next_cursor.
    // We forward it raw to the DB fn which knows how to split it.
    const cursor_raw = query.get("cursor");
    const cursor: ?[]const u8 = if (cursor_raw) |c| (if (c.len == 0) null else c) else null;

    const result = ai_mod.workspace_item_tasks.listWorkspaceItemTasksWithCursor(
        allocator,
        sqlite_db,
        item_id,
        limit,
        cursor,
        sort_field,
        sort_direction,
    ) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to fetch tasks" }) });
    };
    defer {
        for (result.tasks) |task| task.deinit(allocator);
        allocator.free(result.tasks);
    }

    // Convert to response format.
    var task_responses = std.ArrayList(http_response.WorkspaceItemTaskResponse).empty;
    defer task_responses.deinit(allocator);

    for (result.tasks) |task| {
        try task_responses.append(allocator, http_response.WorkspaceItemTaskResponse{
            .id = task.id,
            .name = task.name,
            .workspace_item_id = task.workspace_item_id,
            .session_id = task.session_id,
            .created_at = task.created_at,
            .updated_at = task.updated_at,
        });
    }

    // next_cursor: the encoded "<sort_value>|<id>" of the LAST task in
    // this page, when has_more is true. The DB fn will decode it.
    // Pick the sort field's value (not always created_at — that was
    // the bug in session_list.zig). null when there's no more.
    const next_cursor: ?[]const u8 = blk: {
        if (!result.has_more) break :blk null;
        if (result.tasks.len == 0) break :blk null;
        const last = result.tasks[result.tasks.len - 1];
        const sort_value: ?[]const u8 = switch (sort_field) {
            .created_at => last.created_at orelse null,
            .updated_at => last.updated_at orelse null,
            .name => last.name, // name is NOT NULL in the DB schema
        };
        const v = sort_value orelse break :blk null;
        // Encode as "<sort_value>|<id>". For DATETIME columns the
        // value never contains '|' (the format is "YYYY-MM-DD HH:MM:SS"),
        // so the split in the DB fn is unambiguous.
        break :blk try std.fmt.allocPrint(allocator, "{s}|{s}", .{ v, last.id });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeWorkspaceItemTaskListResponse(allocator, task_responses.items, result.has_more, next_cursor) });
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test:ai_workflow:tui 2>&1 | tail -n 20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/http_handlers/tasks_list.zig src/ai_workflow/tui/http_handlers/tasks_list_test.zig
git commit -m "feat(workspace-tasks): parse sort_by/direction in tasksListHandler, default updated_at DESC"
```

---

### Task 4: Add SQLite index for `(workspace_item_id, updated_at DESC)`

**Files:**
- Modify: `src/ai_workflow/tui/migration.zig:628-653` (append new migration after `Migration041`)

- [ ] **Step 1: Write the failing test**

Add a static source check to `tasks_list_test.zig` (or a new file `migration_test.zig` if one doesn't exist for indexes) that verifies the index is declared. First check the existing test files for migrations:

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && rg "Migration04[0-9]|idx_workspace_item_tasks_item_updated" src/ai_workflow/tui/ -l 2>&1 | head -n 20`

Then add the test to the most relevant file. Most migration tests are in the form of static source checks (look for `migration_test.zig` or similar). If none exists, add the test to `tasks_list_test.zig` as a new contract:

```zig
const MIGRATION_PATH = "src/ai_workflow/tui/migration.zig";

// ─── Contract 10: migration adds updated_at index ─────────────────────────

test "migration declares idx_workspace_item_tasks_item_updated" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MIGRATION_PATH);
    defer allocator.free(source);

    const idx = "idx_workspace_item_tasks_item_updated";
    if (std.mem.indexOf(u8, source, idx) == null) {
        std.debug.print(
            "\n!! {s} does not declare `{s}` index !!\n" ++
                "   The sort_by=updated_at hot path is unindexed — every page\n" ++
                "   fetch will full-scan workspace_item_tasks. As task counts\n" ++
                "   grow this becomes O(n) per page.\n" ++
                "   Add a migration that creates the index:\n" ++
                "     try db.exec(allocator, \"CREATE INDEX IF NOT EXISTS\n" ++
                "       {s} ON workspace_item_tasks(workspace_item_id, updated_at DESC)\", ...);\n" ++
                "   See docs/superpowers/plans/2026-06-11-workspace-item-tasks-sort-by-updated-at.md.\n",
            .{ MIGRATION_PATH, idx, idx },
        );
        return error.UpdatedAtIndexMissing;
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test:ai_workflow:tui 2>&1 | tail -n 20`
Expected: FAIL with `error.UpdatedAtIndexMissing`

- [ ] **Step 3: Add the migration**

In `src/ai_workflow/tui/migration.zig`, after the `Migration041AddPerformanceIndexes` closing brace (around line 653), add:

```zig
pub const Migration042AddWorkspaceItemTasksUpdatedAtIndex = struct {
    pub const version: u32 = 42;
    pub const name = "add_workspace_item_tasks_updated_at_index";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Hot read path for the workspace-item tasks endpoint when
        // sort_by=updated_at (the new default). Mirrors
        // idx_workspace_item_tasks_item_created (Migration 041).
        // Compound (workspace_item_id, updated_at DESC) matches the
        // query's WHERE + ORDER BY so SQLite does a forward index scan.
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_item_tasks_item_updated ON workspace_item_tasks(workspace_item_id, updated_at DESC)", &[_][]const u8{});

        // ANALYZE so the query planner sees the new index on existing
        // databases (without this, the planner may still pick a full
        // scan on pre-existing data).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
```

Then in the `migrations_list` array (search for `Migration041AddPerformanceIndexes` in the same file to find the array), append a new entry:

```zig
.{ .version = Migration042AddWorkspaceItemTasksUpdatedAtIndex.version, .name = Migration042AddWorkspaceItemTasksUpdatedAtIndex.name, .up = Migration042AddWorkspaceItemTasksUpdatedAtIndex.up },
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test:ai_workflow:tui 2>&1 | tail -n 20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/migration.zig src/ai_workflow/tui/http_handlers/tasks_list_test.zig
git commit -m "feat(workspace-tasks): add idx_workspace_item_tasks_item_updated (Migration 042)"
```

---

### Task 5: Update `api.getTasks` to pass `sortBy` / `direction` params

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts:134-171`

- [ ] **Step 1: Update the API function**

In `src/apps/desktop/src/api/index.ts`, replace the existing `getTasks` function (lines 146-171) with a sort-aware version. The function gains two new parameters with backwards-compatible defaults (default: `updated_at` / `desc`, which is the user's desired order):

```ts
/**
 * Fetch tasks for a workspace item, with optional cursor pagination.
 *
 * @param workspaceId  - owning workspace
 * @param itemId       - workspace item (e.g. a project folder)
 * @param limit        - page size (default 20; backend clamps at 100)
 * @param cursor       - the encoded "<sort_value>|<id>" from the
 *                       previous page's `next_cursor`; pass undefined
 *                       for the first page
 * @param sortBy       - field to sort by: 'created_at' | 'updated_at'
 *                       | 'name'. Default: 'updated_at' (most recently
 *                       renamed task first). The backend uses this for
 *                       both ORDER BY and the cursor value.
 * @param direction    - 'asc' | 'desc'. Default: 'desc'.
 * @returns `{ tasks, has_more, next_cursor }`. `next_cursor` is null
 *          when there are no more pages.
 */
export async function getTasks(
  workspaceId: string,
  itemId: string,
  limit = 20,
  cursor?: string,
  sortBy: 'created_at' | 'updated_at' | 'name' = 'updated_at',
  direction: 'asc' | 'desc' = 'desc',
): Promise<{
  tasks: Task[]
  has_more: boolean
  next_cursor: string | null
}> {
  const params = new URLSearchParams()
  params.set('limit', String(limit))
  params.set('sort_by', sortBy)
  params.set('direction', direction)
  if (cursor) {
    params.set('cursor', cursor)
  }
  const response = await fetch(
    `${API_BASE}/workspaces/${workspaceId}/items/${itemId}/tasks?${params.toString()}`,
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  const data = await response.json()
  return {
    tasks: data.tasks ?? [],
    has_more: data.has_more ?? false,
    next_cursor: data.next_cursor ?? null,
  }
}
```

- [ ] **Step 2: Build the desktop app to confirm types still align**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20`
Expected: Clean build (no TS errors)

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/api/index.ts
git commit -m "feat(workspace-tasks): pass sortBy/direction to getTasks, default updated_at DESC"
```

---

### Task 6: Add `updated_at` to the `Task` interfaces and the local fallback

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts:50-56` (api.Task interface)
- Modify: `src/apps/desktop/src/stores/workspaces.ts:50-56` (local Task interface)
- Modify: `src/apps/desktop/src/stores/workspaces.ts:442-449` (local fallback in `addTask`)

- [ ] **Step 1: Add `updated_at` to the API `Task` interface**

In `src/apps/desktop/src/api/index.ts`, update the `Task` interface (lines 50-56):

```ts
export interface Task {
  id: string
  name: string
  description?: string
  completed?: boolean
  createdAt?: Date
  updatedAt?: Date  // ISO datetime string from the backend; present
                    // for tasks returned by getTasks() and used to
                    // sort/filter on the frontend if needed. Backend
                    // stamps this on every update (rename, complete).
}
```

- [ ] **Step 2: Add `updatedAt` to the local `Task` interface in workspaces.ts**

In `src/apps/desktop/src/stores/workspaces.ts`, update the `Task` interface (lines 50-56):

```ts
// Task interface for project tasks
export interface Task {
  id: string
  name: string
  description?: string
  completed?: boolean
  createdAt?: Date
  updatedAt?: Date
}
```

- [ ] **Step 3: Update the local fallback in `addTask`**

In `src/apps/desktop/src/stores/workspaces.ts`, update the fallback object inside the catch block of `addTask` (lines 442-449) to include `updatedAt`:

```ts
// Fallback to local creation if API fails
const taskId = `task-${Date.now()}`
item.tasks.unshift({
  id: taskId,
  name,
  description,
  completed: false,
  createdAt: new Date(),
  updatedAt: new Date(),
})
```

- [ ] **Step 4: Build to confirm types align**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20`
Expected: Clean build

- [ ] **Step 5: Run unit tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 20`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/api/index.ts src/apps/desktop/src/stores/workspaces.ts
git commit -m "feat(workspace-tasks): add updatedAt to Task interfaces + local fallback"
```

---

### Task 7: Verify the full pipeline end-to-end

- [ ] **Step 1: Run all Zig tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 300 zig build test 2>&1 | tail -n 30`
Expected: All test steps pass; the new `tasks_list_test.zig` source checks (Contracts 7-10) pass.

- [ ] **Step 2: Build the desktop app**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20`
Expected: Clean build, no TS errors.

- [ ] **Step 3: Run desktop unit tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 20`
Expected: All tests pass.

- [ ] **Step 4: Manual smoke test — rename a task and watch it jump to the top**

1. Start the desktop app (`bun run dev` or the built binary).
2. Open a workspace item with multiple tasks (e.g. `be` in the screenshot).
3. Note the current order.
4. Rename a task that's currently NOT at the top (e.g. `trace-tool-call-error` → `trace-sse-segfault`).
5. Wait ~1 second.
6. **Expected**: the renamed task appears at the TOP of the list. The other tasks shift down by one. (The rename API hits `updateWorkspaceItemTask` at `llm_history.zig:2306-2343` which does `updated_at = datetime('now')` on line 2340.)
7. Reload the page → the order is preserved (backend returns the new order).
8. Click "Load more" → the second page is sorted by `updated_at DESC` and the `id` tiebreaker is used for any tasks with the same `updated_at`.

- [ ] **Step 5: Manual smoke test — verify the API works directly**

```bash
# 1. Find the backend's API base URL (default http://127.0.0.1:8080)
API=http://127.0.0.1:8080

# 2. Find a workspace_item_id (from the network tab or a DB query)
WORKSPACE_ID=...
ITEM_ID=...

# 3. Fetch first page sorted by updated_at DESC (the new default)
curl -s "$API/api/workspaces/$WORKSPACE_ID/items/$ITEM_ID/tasks?limit=20" | jq '.tasks[] | {id, name, updated_at}'

# 4. Fetch first page sorted by created_at DESC (explicit)
curl -s "$API/api/workspaces/$WORKSPACE_ID/items/$ITEM_ID/tasks?limit=20&sort_by=created_at&direction=desc" | jq '.tasks[] | {id, name, updated_at, created_at}'

# 5. Verify the two orderings differ for the same dataset
```

Expected: the two orderings differ; `sort_by=updated_at&direction=desc` puts the most-recently-renamed task first.

- [ ] **Step 6: Commit any final fixes**

If the manual test revealed any bugs (cursor encoding edge cases, sort-field name collision, etc.), fix them and commit before merging.

---

## Acceptance Criteria

This change is **DONE** when ALL of the following are true:

1. ✅ All static source checks in `tasks_list_test.zig` pass (original 6 + new 4 = 10 contracts).
2. ✅ `zig build test:ai_workflow:tui` is clean.
3. ✅ `zig build test` is clean (no other test step regressed).
4. ✅ `bun run build` is clean (no TS errors).
5. ✅ `bunx vitest run` passes all existing tests.
6. ✅ The new SQLite index `idx_workspace_item_tasks_item_updated` exists in the database after upgrade.
7. ✅ Renaming a task in the sidebar makes it jump to the top of the list.
8. ✅ Clicking "Load more" preserves the sort order (keyset pagination works with the `id` tiebreaker).
9. ✅ Reloading the page shows the same order (backend returns the new order).

## Out of Scope

- Sorting **workspaces** by `updated_at` — the column is never re-stamped (only Migration 030 sets it on insert), so this would be a no-op for now. Add this when workspace rename learns to update `updated_at`.
- Sorting **workspace_items** by `updated_at` — same reason. Add when `workspace_items.updated_at` starts being re-stamped.
- The known bug in `getSessionListWithCursor` (`llm_history.zig:195-199`) where the cursor always uses `created_at` regardless of sort_field. The new tasks impl does this correctly; the session impl can be fixed in a follow-up.
- A frontend toggle for the sort field/direction. The user's request is for the default order to be `updated_at DESC`; UI for changing it is a follow-up.

## Pitfalls

- **Cursor format**: we encode the cursor as `"<sort_value>|<id>"`. For `DATETIME` columns (`created_at`, `updated_at`) the value never contains `|` (the format is `YYYY-MM-DD HH:MM:SS`), so the split is unambiguous. For the `name` field, a user-typed `|` in a task name would corrupt the split. **Mitigation**: task names are user-typed and unlikely to contain `|`; if it becomes a real problem, sanitize at the handler (replace `|` with `\|` in the cursor encoding, or use a delimiter that can't appear in any of the three sort fields like a NUL byte — `0x00` is forbidden in SQLite TEXT columns by default, so use a different escape). For now, document this in the handler doc comment.
- **Local optimistic update vs backend order**: `addTask` does `item.tasks.unshift(newTask)` (workspaces.ts:437). This matches `updated_at DESC` because a freshly created task has the latest `updated_at`. If the user later switches to `created_at DESC` or `name ASC`, the optimistic update will be wrong (it always unshifts to position 0). **Mitigation**: out of scope for this plan; note it for the future UI toggle work.
- **Tiebreaker on `id` only**: the new `ORDER BY updated_at DESC, id DESC` only uses `id` as the tiebreaker, not `(workspace_item_id, id)`. That's correct because the WHERE clause already filters to a single `workspace_item_id`, so `id` is unique within the result set. No need for a compound tiebreaker.
- **The frontend `getTasks` default of `updated_at` is a behavior change**. Any existing client (curl scripts, the `init()` call in workspaces.ts, etc.) will now receive tasks in `updated_at DESC` order instead of `created_at DESC`. This is the desired behavior per the user's request, but it IS a behavior change. Document in the commit message.
- **The cursor encoding is a breaking change for any client that was already using the previous `next_cursor` as a `created_at` value**. The frontend is the only client and we're updating it in this same plan, so no external break.

## Verification

- `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 300 zig build test 2>&1 | tail -n 20` — all tests pass
- `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20` — clean
- `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 20` — all green
- Manual: rename a task → it moves to the top → "Load more" preserves order

## Reference

- **Existing pattern** (sessions): `src/ai_workflow/tui/http_handlers/session_list.zig:24-49` + `src/ai_workflow/tui/llm_history.zig:182-214`
- **Test pattern** (static source checks): `src/ai_workflow/tui/http_handlers/tasks_list_test.zig:1-218`
- **Migration pattern**: `src/ai_workflow/tui/migration.zig:628-653` (Migration 041)
- **Existing tasks list handler**: `src/ai_workflow/tui/http_handlers/tasks_list.zig:18-80`
- **Existing tasks list DB fn**: `src/ai_workflow/tui/llm_history.zig:2398-2466`
- **Frontend store**: `src/apps/desktop/src/stores/workspaces.ts:155-221, 513-545`
- **Frontend API**: `src/apps/desktop/src/api/index.ts:146-171`
- **Screenshot in user report**: WORKSPACES sidebar → `agentic_coding_zig` → `be` workspace item → task list
