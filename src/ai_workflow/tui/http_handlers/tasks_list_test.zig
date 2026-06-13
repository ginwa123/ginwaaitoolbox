//! Static regression checks for the paginated `tasks_list` handler.
//!
//! Why this file exists
//! ────────────────────
//! The workspace-item task list is paginated with cursor-based "Load
//! More" (see docs/plans/2026-06-10-workspace-item-task-pagination.md).
//! The handler at `tasks_list.zig` parses `limit` and `cursor` query
//! params and delegates to `llm_history.listWorkspaceItemTasksWithCursor`.
//! The response struct at `http_response.zig` carries `has_more` and
//! `next_cursor` so the frontend can decide whether to render the Load
//! More button.
//!
//! These contracts are enforced by static substring checks (matching
//! the project's `task_update_test.zig` pattern), not by spinning up
//! an in-memory DB — the project has no precedent for the latter
//! (every test in `test_runner.zig` either covers a pure function or
//! is a static source check). If the pagination plumbing is removed
//! or routed to the old single-page path, these tests fail and the
//! bug is caught at `zig build test:ai_workflow:tui` time.
//!
//! Why a static check (not a behavioral DB test)?
//! ───────────────────────────────────────────────
//! Standing up an in-process sqlite DB + migrations + event bus to
//! behavioural-test the handler would duplicate the migration setup
//! and pull in `nalarcore.getSingleton()` (which depends on a live
//! `ContextIPCTui` with a server, logger, and event bus). The static
//! checks below directly test the bug — they fail if and only if the
//! pagination contract is removed or routed back to the old path.

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/tasks_list.zig";
const LLM_HISTORY_PATH = "src/ai_workflow/tui/llm_history.zig";
const HTTP_RESPONSE_PATH = "src/ai_workflow/tui/http_handlers/http_response.zig";
const MIGRATION_PATH = "src/ai_workflow/tui/migration.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test:ai_workflow:tui` runs).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

// ─── Contract 1: handler parses the `limit` query param ────────────────────

test "tasks_list handler parses the limit query param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must read `query.get("limit")` (or a similar pattern
    // such as `query.get("limit") orelse "20"`) and clamp it. If this
    // is missing, the limit-parse plumbing was removed and a client
    // asking for `?limit=5` would get the full unpaginated result set.
    if (std.mem.indexOf(u8, source, "\"limit\"") == null and
        std.mem.indexOf(u8, source, "'limit'") == null)
    {
        std.debug.print(
            "\n!! {s} does not reference the `limit` query param !!\n" ++
                "   The pagination contract is broken: clients cannot request\n" ++
                "   a smaller page size. The frontend will always fetch the\n" ++
                "   full task list, defeating pagination.\n" ++
                "   Restore the limit parse:\n" ++
                "     const limit_str = query.get(\"limit\") orelse \"20\";\n" ++
                "   See docs/plans/2026-06-10-workspace-item-task-pagination.md.\n",
            .{HANDLER_PATH},
        );
        return error.LimitParamMissing;
    }
}

// ─── Contract 2: handler parses the `cursor` query param ──────────────────

test "tasks_list handler parses the cursor query param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must read `query.get("cursor")` so the frontend can
    // pass the previous page's `next_cursor` to fetch the next page.
    // Without this, every call would return the first page regardless
    // of the cursor.
    if (std.mem.indexOf(u8, source, "\"cursor\"") == null and
        std.mem.indexOf(u8, source, "'cursor'") == null)
    {
        std.debug.print(
            "\n!! {s} does not reference the `cursor` query param !!\n" ++
                "   The pagination contract is broken: the frontend cannot\n" ++
                "   advance to the next page. Clicking 'Load more' would\n" ++
                "   re-fetch the first page.\n" ++
                "   Restore the cursor parse:\n" ++
                "     const cursor_raw = query.get(\"cursor\");\n" ++
                "   See docs/plans/2026-06-10-workspace-item-task-pagination.md.\n",
            .{HANDLER_PATH},
        );
        return error.CursorParamMissing;
    }
}

// ─── Contract 3: handler delegates to the cursor DB function ──────────────

test "tasks_list handler calls listWorkspaceItemTasksWithCursor" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call the new cursor-aware DB function. If the
    // call was reverted to the old `listWorkspaceItemTasks`, the
    // `limit` and `cursor` params would be silently ignored and every
    // page would return all tasks.
    if (std.mem.indexOf(u8, source, "listWorkspaceItemTasksWithCursor") == null) {
        std.debug.print(
            "\n!! {s} does not call listWorkspaceItemTasksWithCursor !!\n" ++
                "   The pagination contract is broken: the handler is using\n" ++
                "   the old single-page `listWorkspaceItemTasks` function,\n" ++
                "   which ignores limit/cursor and returns the full list.\n" ++
                "   Restore the cursor-aware call:\n" ++
                "     const result = ai_mod.workspace_item_tasks\n" ++
                "         .listWorkspaceItemTasksWithCursor(allocator, sqlite_db, item_id, limit, cursor) catch ...;\n" ++
                "   See docs/plans/2026-06-10-workspace-item-task-pagination.md.\n",
            .{HANDLER_PATH},
        );
        return error.CursorFunctionNotCalled;
    }
}

// ─── Contract 4: response struct has the `has_more` field ─────────────────

test "WorkspaceItemTaskListResponse has the has_more field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HTTP_RESPONSE_PATH);
    defer allocator.free(source);

    // The frontend reads `data.has_more` to decide whether to render
    // the "Load more" button. If the field is missing, the button
    // either never appears (data.has_more undefined) or always appears
    // (data.has_more is some other field).
    if (std.mem.indexOf(u8, source, "has_more") == null) {
        std.debug.print(
            "\n!! {s} does not contain a `has_more` field !!\n" ++
                "   The pagination contract is broken: the frontend cannot\n" ++
                "   tell whether more pages exist, so the 'Load more' button\n" ++
                "   will never appear.\n" ++
                "   Restore the field on WorkspaceItemTaskListResponse:\n" ++
                "     pub const WorkspaceItemTaskListResponse = struct {{\n" ++
                "         tasks: ...,\n" ++
                "         count: u32,\n" ++
                "         has_more: bool = false,\n" ++
                "         next_cursor: ?[]const u8 = null,\n" ++
                "     }};\n" ++
                "   See docs/plans/2026-06-10-workspace-item-task-pagination.md.\n",
            .{HTTP_RESPONSE_PATH},
        );
        return error.HasMoreFieldMissing;
    }
}

// ─── Contract 5: response struct has the `next_cursor` field ─────────────

test "WorkspaceItemTaskListResponse has the next_cursor field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HTTP_RESPONSE_PATH);
    defer allocator.free(source);

    // The frontend reads `data.next_cursor` to advance the cursor when
    // the user clicks "Load more". If the field is missing, the
    // cursor cannot advance and pagination stops after the first page.
    if (std.mem.indexOf(u8, source, "next_cursor") == null) {
        std.debug.print(
            "\n!! {s} does not contain a `next_cursor` field !!\n" ++
                "   The pagination contract is broken: the frontend cannot\n" ++
                "   advance the cursor, so 'Load more' would re-fetch the\n" ++
                "   first page indefinitely.\n" ++
                "   Restore the field on WorkspaceItemTaskListResponse:\n" ++
                "     pub const WorkspaceItemTaskListResponse = struct {{\n" ++
                "         tasks: ...,\n" ++
                "         count: u32,\n" ++
                "         has_more: bool = false,\n" ++
                "         next_cursor: ?[]const u8 = null,\n" ++
                "     }};\n" ++
                "   See docs/plans/2026-06-10-workspace-item-task-pagination.md.\n",
            .{HTTP_RESPONSE_PATH},
        );
        return error.NextCursorFieldMissing;
    }
}

// ─── Contract 6: cursor DB function exists in llm_history ────────────────

test "llm_history exposes listWorkspaceItemTasksWithCursor" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // The new function must be defined with the expected signature.
    // If it's missing, the handler's call site won't compile and
    // pagination is impossible to wire up.
    const sig = "pub fn listWorkspaceItemTasksWithCursor(";
    if (std.mem.indexOf(u8, source, sig) == null) {
        std.debug.print(
            "\n!! {s} does not define `listWorkspaceItemTasksWithCursor` !!\n" ++
                "   The pagination contract is broken: the cursor-aware DB\n" ++
                "   function is missing, so the handler has no way to fetch\n" ++
                "   a paginated subset of tasks.\n" ++
                "   Restore the function:\n" ++
                "     pub fn listWorkspaceItemTasksWithCursor(\n" ++
                "         allocator, db, workspace_item_id, limit, cursor,\n" ++
                "     ) !struct {{ tasks: []WorkspaceItemTaskInfo, has_more: bool }} {{ ... }}\n" ++
                "   See docs/plans/2026-06-10-workspace-item-task-pagination.md.\n",
            .{LLM_HISTORY_PATH},
        );
        return error.CursorFunctionMissing;
    }
}

// ─── Contract 7: llm_history exposes the TaskSortField enum ──────────────

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
                "     pub const TaskSortField = enum {{ created_at, updated_at, name }};\n" ++
                "   See docs/superpowers/plans/2026-06-11-workspace-item-tasks-sort-by-updated-at.md.\n",
            .{LLM_HISTORY_PATH},
        );
        return error.TaskSortFieldMissing;
    }
}

// ─── Contract 8: listWorkspaceItemTasksWithCursor is sort-aware ──────────

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
                "     ) !struct {{ tasks: []WorkspaceItemTaskInfo, has_more: bool }} {{ ... }}\n" ++
                "   See docs/superpowers/plans/2026-06-11-workspace-item-tasks-sort-by-updated-at.md.\n",
            .{LLM_HISTORY_PATH},
        );
        return error.SortParamsMissing;
    }
}

// ─── Contract 9: handler parses the sort_by query param ───────────────────

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

// ─── Contract 10: handler parses the direction query param ────────────────

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

// ─── Contract 11: handler passes sort_field and sort_direction to the DB fn

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

// ─── Contracts 13-14: routine-aware response shape ────────────────────

test "WorkspaceItemTaskResponse has task_type + routine fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HTTP_RESPONSE_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "task_type") == null) return error.TaskTypeFieldMissing;
    if (std.mem.indexOf(u8, source, "routine") == null) return error.RoutineFieldMissing;
}

test "tasks_list handler threads task_type + routine into the response" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "task_type") == null) return error.TaskTypeNotThreaded;
    if (std.mem.indexOf(u8, source, ".routine") == null) return error.RoutineNotThreaded;
}

// ─── Contract 12: migration declares idx_workspace_item_tasks_item_updated ─

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
