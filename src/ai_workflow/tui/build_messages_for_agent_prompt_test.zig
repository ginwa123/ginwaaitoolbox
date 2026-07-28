//! Behavioral tests for `llm_history.getWorkspaceContext`.
//!
//! These tests cover the SQL helper added by Chunk 1 of
//! `docs/plans/2026-06-19-workspace-siblings-in-prompt.md`. They
//! exercise the data structure returned (a `WorkspaceContext`
//! populated with sibling items + tasks, with truncation flags
//! when caps are hit). The renderer that consumes this struct
//! (`BuildWorkspaceContext` in `build_messages_for_agent_prompt.zig`,
//! added in Chunk 2 of the plan) is tested separately.
//!
//! The test names are intentionally scoped to the SQL helper for
//! Chunk 1, but kept short ("BuildWorkspaceContext") so the
//! renderer tests in Chunk 2 can keep the same prefix.
//!
//! We use the in-memory sqlite pattern from `routines/model_test.zig`
//! — `std.Io.Threaded.init(alloc, .{})` + `db.init(io, ":memory:")`
//! + manual `CREATE TABLE` statements for `workspaces`,
//! `workspace_items`, and `workspace_item_tasks`. The helper
//! functions (`setupDb`, `seedWorkspace`) mirror the structure of
//! the routines tests so a future reader can grep one and find
//! the other.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const llm_history = @import("llm_history.zig");
const WorkspaceContext = llm_history.WorkspaceContext;
const agentic_loop = @import("agentic_loop/mod.zig");
// After the refactor that split prompt builders into agentic_loop/*,
// `makeWorkspaceContext` and `makeKanbanContext` live in
// `agentic_loop.prompts_mod`. The old `build_messages.BuildWorkspaceContext`
// and `build_messages.BuildKanbanStatusPrompt` paths no longer exist.

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the schema state matching
/// the post-Migration-045 / post-Migration-044 baseline that
/// `getWorkspaceContext` expects. The helper returns a `{db,
/// threaded}` tuple so tests can `defer ctx.db.deinit()` +
/// `defer ctx.threaded.deinit()` (mirrors `routines/model_test.zig`'s
/// `setupDb`).
fn setupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspaces — minimum columns used by `getWorkspaceContext`.
    try db.exec(alloc,
        \\CREATE TABLE workspaces (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});

    // workspace_items — mirrors Migration 045's schema (id,
    // workspace_id, item_type, name, path, position). The `position`
    // column is NOT NULL DEFAULT 0, which means we don't have to
    // supply it in the seed inserts.
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL,
        \\    name TEXT,
        \\    path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME DEFAULT NULL,
        \\    updated_at DATETIME DEFAULT NULL
        \\)
    , &.{});

    // workspace_item_tasks — mirrors Migration 044's schema (with
    // task_type added). updated_at is required by the SQL in
    // getWorkspaceContext (`ORDER BY t.updated_at DESC`).
    //
    // Note: this schema is intentionally post-Migration 052 —
    // the `session_id` column was dropped. Tasks use `id` as the
    // session id directly (the `task.id == session_id`
    // convention).
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    kanban_column_id TEXT,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    // kanban_columns — mirrors Migration 051's schema (used by
    // `BuildKanbanStatusPrompt` in `build_messages_for_agent_prompt.zig`,
    // added in the 2026-06-27 kanban-status-prompt plan).
    try db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL,
        \\    description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

/// One row in `workspace_items`. Top-level so tests can build a
/// `[N]ItemSeed` and pass it to `seedWorkspace` (Zig treats
/// anonymous structs in different positions as distinct types,
/// even with identical fields — so the items slice type and the
/// `WorkspaceSeed.items` slice element type must literally be the
/// same struct).
const ItemSeed = struct {
    id: []const u8,
    item_type: []const u8 = "chat",
    path: []const u8,
    name: []const u8 = "",
};

/// One row in `workspace_item_tasks`. The `id` field is also the
/// session id — tests use it as the lookup key in
/// `getWorkspaceContext`'s `WHERE t.id = ?` anchor.
const TaskSeed = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    name: []const u8 = "t",
};

/// Seed shape used by `seedWorkspace` — declarative enough that
/// tests read as "given X items and Y tasks, expect Z siblings".
const WorkspaceSeed = struct {
    workspace_id: []const u8,
    items: []const ItemSeed,
    tasks: []const TaskSeed,
};

/// Insert one workspace + N items + M tasks. All inserts are
/// parameterized (no string concatenation). Mirrors the project
/// "always alias tables in SQL" convention where it doesn't add
/// noise (single-table INSERTs don't need aliases; the convention
/// applies to SELECTs). Takes `db: *SqliteBackend` directly
/// instead of the `ctx` tuple because `anytype` + `.db.exec`
/// confuses Zig's pointer-inference (it can't tell that `ctx` is
/// a mutable struct return).
fn seedWorkspace(db: *sqlite.SqliteBackend, alloc: std.mem.Allocator, seed: WorkspaceSeed) !void {
    try db.exec(alloc,
        "INSERT INTO workspaces (id, name) VALUES (?, ?)",
        &.{ seed.workspace_id, "test-ws" },
    );
    for (seed.items) |item| {
        try db.exec(alloc,
            \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path)
            \\VALUES (?, ?, ?, ?, ?)
        , &.{ item.id, seed.workspace_id, item.item_type, item.name, item.path });
    }
    for (seed.tasks) |task| {
        try db.exec(alloc,
            \\INSERT INTO workspace_item_tasks
            \\    (id, name, workspace_item_id, task_type)
            \\VALUES (?, ?, ?, 'standard')
        , &.{ task.id, task.name, task.workspace_item_id });
    }
}

// ─── Test 1: empty case ───────────────────────────────────────────────────

test "BuildWorkspaceContext returns empty string for session not bound to any task" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedWorkspace(&ctx.db, alloc, .{
        .workspace_id = "ws_x",
        .items = &.{
            .{ .id = "wi_a", .path = "/abs/a" },
            .{ .id = "wi_b", .path = "/abs/b" },
        },
        .tasks = &.{
            .{ .id = "task_a1", .workspace_item_id = "wi_a" },
            .{ .id = "task_b1", .workspace_item_id = "wi_b" },
        },
    });

    // Per the `task.id == session_id` convention, we look up by
    // a session_id that doesn't match any task id. The helper
    // returns null (the session is unbound to any task).
    const maybe_ctx = try llm_history.getWorkspaceContext(alloc, &ctx.db, "sess_lone");
    try testing.expect(maybe_ctx == null);
}

// ─── Test 2: self item first ──────────────────────────────────────────────

test "BuildWorkspaceContext lists self item first with is_self flag" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedWorkspace(&ctx.db, alloc, .{
        .workspace_id = "ws_self",
        .items = &.{
            .{ .id = "wi_a", .path = "/abs/a", .name = "Alpha" },
            .{ .id = "wi_b", .path = "/abs/b", .name = "Beta" },
            .{ .id = "wi_c", .path = "/abs/c", .name = "Gamma" },
        },
        .tasks = &.{
            .{ .id = "task_a1", .workspace_item_id = "wi_a", .name = "a1" },
            .{ .id = "task_b1", .workspace_item_id = "wi_b", .name = "b1" },
            .{ .id = "task_c1", .workspace_item_id = "wi_c", .name = "c1" },
        },
    });

    // Per the `task.id == session_id` convention, we look up
    // by the task's own id (not a separate session_id column).
    const maybe_ctx = try llm_history.getWorkspaceContext(alloc, &ctx.db, "task_a1");
    const wc = maybe_ctx orelse return error.UnexpectedNullContext;

    defer wc.deinit(alloc);

    try testing.expectEqualStrings("ws_self", wc.workspace_id);
    try testing.expectEqualStrings("wi_a", wc.self_item_id);
    try testing.expectEqualStrings("task_a1", wc.self_task_id);
    try testing.expectEqual(@as(usize, 3), wc.siblings.len);
    try testing.expectEqual(@as(u32, 0), wc.truncated_items_count);
    try testing.expectEqual(@as(u32, 3), wc.total_item_count);

    // Self item must be first (sorted by is_self DESC).
    try testing.expect(wc.siblings[0].is_self);
    try testing.expectEqualStrings("wi_a", wc.siblings[0].id);
    try testing.expectEqualStrings("Alpha", wc.siblings[0].name orelse "");

    // Sibling items should not be self.
    try testing.expect(!wc.siblings[1].is_self);
    try testing.expect(!wc.siblings[2].is_self);
}

// ─── Test 3: tasks under each item ────────────────────────────────────────

test "BuildWorkspaceContext includes tasks under each item" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedWorkspace(&ctx.db, alloc, .{
        .workspace_id = "ws_tasks",
        .items = &.{
            .{ .id = "wi_a", .path = "/abs/a" },
            .{ .id = "wi_b", .path = "/abs/b" },
        },
        .tasks = &.{
            .{ .id = "task_a1", .workspace_item_id = "wi_a", .name = "a1" },
            .{ .id = "task_a2", .workspace_item_id = "wi_a", .name = "a2" },
            .{ .id = "task_a3", .workspace_item_id = "wi_a", .name = "a3" },
            .{ .id = "task_b1", .workspace_item_id = "wi_b", .name = "b1" },
        },
    });

    // Per the `task.id == session_id` convention, look up by
    // the task's own id.
    const maybe_ctx = try llm_history.getWorkspaceContext(alloc, &ctx.db, "task_a1");
    const wc = maybe_ctx orelse return error.UnexpectedNullContext;
    defer wc.deinit(alloc);

    // Self (wi_a) first.
    try testing.expectEqualStrings("wi_a", wc.siblings[0].id);
    try testing.expectEqual(@as(usize, 3), wc.siblings[0].tasks.len);
    try testing.expectEqual(@as(u32, 0), wc.siblings[0].truncated_tasks_count);

    // wi_b has 1 task.
    try testing.expectEqualStrings("wi_b", wc.siblings[1].id);
    try testing.expectEqual(@as(usize, 1), wc.siblings[1].tasks.len);
    try testing.expectEqualStrings("b1", wc.siblings[1].tasks[0].name);
    // Note: the `session_id` field was dropped from SiblingTask
    // in Migration 052 (the task id IS the session id). The
    // task_type field carries the routine-vs-standard info
    // instead.
    try testing.expectEqualStrings("standard", wc.siblings[1].tasks[0].task_type);
}

// ─── Test 4: items cap at 20 with truncation flag ────────────────────────

test "BuildWorkspaceContext caps at 20 items and reports truncation" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Build 25 items inline; only wi_0 has the binding task.
    // `id` and `name` are dynamically allocated so each row has its
    // own backing memory (a shared buffer would alias and produce
    // double-frees — see std.fmt.bufPrint docs: it returns a slice
    // into the buffer, not a new allocation).
    var items: [25]ItemSeed = undefined;
    for (items[0..], 0..) |*it, i| {
        const id_owned = try std.fmt.allocPrint(alloc, "wi_{d}", .{i});
        errdefer alloc.free(id_owned);
        it.* = .{
            .id = id_owned,
            .item_type = "chat",
            .path = "/abs/x",
            .name = "x",
        };
    }
    defer for (items[0..]) |it| alloc.free(it.id);

    try seedWorkspace(&ctx.db, alloc, .{
        .workspace_id = "ws_big",
        .items = items[0..],
        .tasks = &.{
            .{ .id = "task_a1", .workspace_item_id = "wi_0" },
        },
    });

    // Per the `task.id == session_id` convention, look up by
    // the task's own id.
    const maybe_ctx = try llm_history.getWorkspaceContext(alloc, &ctx.db, "task_a1");
    const wc = maybe_ctx orelse return error.UnexpectedNullContext;
    defer wc.deinit(alloc);

    try testing.expectEqual(@as(usize, 20), wc.siblings.len);
    try testing.expectEqual(@as(u32, 5), wc.truncated_items_count);
    try testing.expectEqual(@as(u32, 25), wc.total_item_count);
    // Self item (wi_0) is still first.
    try testing.expect(wc.siblings[0].is_self);
    try testing.expectEqualStrings("wi_0", wc.siblings[0].id);
}

// ─── Test 5: tasks cap at 5 per item ──────────────────────────────────────

test "BuildWorkspaceContext caps tasks at 5 per item" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // 1 item, 8 tasks. Each task's id/name is independently
    // allocated (a shared buffer would alias and produce
    // double-frees). Per the `task.id == session_id` convention,
    // each task's id IS its session id.
    var tasks: [8]TaskSeed = undefined;
    for (tasks[0..], 0..) |*t, i| {
        const id_owned = try std.fmt.allocPrint(alloc, "task_{d}", .{i});
        errdefer alloc.free(id_owned);
        t.id = id_owned;
        t.workspace_item_id = "wi_a";
        t.name = id_owned;
    }
    defer for (tasks[0..]) |t| alloc.free(t.id);

    try seedWorkspace(&ctx.db, alloc, .{
        .workspace_id = "ws_taskcap",
        .items = &.{.{ .id = "wi_a", .path = "/abs/a" }},
        .tasks = tasks[0..],
    });

    // Look up by the first task's id (its session id).
    const maybe_ctx = try llm_history.getWorkspaceContext(alloc, &ctx.db, "task_0");
    const wc = maybe_ctx orelse return error.UnexpectedNullContext;
    defer wc.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), wc.siblings.len);
    try testing.expectEqual(@as(usize, 5), wc.siblings[0].tasks.len);
    try testing.expectEqual(@as(u32, 3), wc.siblings[0].truncated_tasks_count);
}

// ─── Test 6: renderer — markdown shape (self marker + tasks) ──────────────

test "BuildWorkspaceContext renders markdown with self marker and tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Same seed as Test 2 ("self item first") plus a task under
    // each item so the task-rendering branch is exercised. The
    // self task is "task-a1" (its id IS its session id per the
    // `task.id == session_id` convention; Migration 052 dropped
    // the redundant session_id column).
    try seedWorkspace(&ctx.db, alloc, .{
        .workspace_id = "ws_md",
        .items = &.{
            .{ .id = "wi_a", .path = "/abs/a", .name = "Alpha" },
            .{ .id = "wi_b", .path = "/abs/b", .name = "Beta" },
        },
        .tasks = &.{
            .{ .id = "task_a1", .workspace_item_id = "wi_a", .name = "task-a1" },
            .{ .id = "task_b1", .workspace_item_id = "wi_b", .name = "task-b1" },
        },
    });

    const md = try agentic_loop.prompts_mod.makeWorkspaceContext(alloc, &ctx.db, "task_a1");
    defer alloc.free(md);

    // Section header is required.
    try testing.expect(std.mem.indexOf(u8, md, "## Workspace Context") != null);

    // Preamble references the workspace id.
    try testing.expect(std.mem.indexOf(u8, md, "ws_md") != null);

    // Self marker on the right item.
    try testing.expect(std.mem.indexOf(u8, md, "*(this task)*") != null);

    // item_type rendering.
    try testing.expect(std.mem.indexOf(u8, md, "item_type: `chat`") != null);

    // The canonical item id MUST be rendered alongside the name —
    // kanban tools (kanban_list, kanban_move_task) look up by id
    // not name, and the LLM only sees what the renderer produces.
    // The label is `item_id:` (NOT bare `id:`) so it can't be
    // confused with `task_id:` on the tasks listed below.
    try testing.expect(std.mem.indexOf(u8, md, "item_id: `wi_a`") != null);
    try testing.expect(std.mem.indexOf(u8, md, "item_id: `wi_b`") != null);

    // Task name rendering (the self task is "task-a1" — its name
    // appears in the task list under its parent item).
    try testing.expect(std.mem.indexOf(u8, md, "`task-a1`") != null);

    // The other item's task is also rendered.
    try testing.expect(std.mem.indexOf(u8, md, "`task-b1`") != null);

    // Task id rendering — the LLM passes task_id (id, not name) to
    // kanban_move_task, so the renderer must expose the task's id.
    // The label is `task_id:` (NOT bare `id:`) so it can't be
    // confused with `item_id:` on the parent sibling line.
    try testing.expect(std.mem.indexOf(u8, md, "task_id: `task_a1`") != null);
    try testing.expect(std.mem.indexOf(u8, md, "task_id: `task_b1`") != null);

    // Sanity: the cwd hint is present (Alpha's path was /abs/a).
    try testing.expect(std.mem.indexOf(u8, md, "/abs/a") != null);
}

// ─── Test 7: renderer — truncation footer for 25 items ────────────────────

test "BuildWorkspaceContext renders truncation footer when over 20 items" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // 25 items; only wi_0 binds a task. Each row's id is independently
    // allocated (shared buffer would alias — see Test 4's comment).
    var items: [25]ItemSeed = undefined;
    for (items[0..], 0..) |*it, i| {
        const id_owned = try std.fmt.allocPrint(alloc, "wi_{d}", .{i});
        errdefer alloc.free(id_owned);
        it.* = .{
            .id = id_owned,
            .item_type = "chat",
            .path = "/abs/x",
            .name = "x",
        };
    }
    defer for (items[0..]) |it| alloc.free(it.id);

    try seedWorkspace(&ctx.db, alloc, .{
        .workspace_id = "ws_trunc",
        .items = items[0..],
        .tasks = &.{
            .{ .id = "task_a1", .workspace_item_id = "wi_0" },
        },
    });

    // Per the `task.id == session_id` convention, look up by
    // the task's own id.
    const md = try agentic_loop.prompts_mod.makeWorkspaceContext(alloc, &ctx.db, "task_a1");
    defer alloc.free(md);

    // Section header is still present.
    try testing.expect(std.mem.indexOf(u8, md, "## Workspace Context") != null);

    // Truncation footer: 25 - 20 = 5 hidden, with the cap-stated.
    try testing.expect(std.mem.indexOf(u8, md, "and 5 more items") != null);
    try testing.expect(std.mem.indexOf(u8, md, "cap: 20 shown") != null);

    // The 5 items past the cap are wi_5..wi_9 (the 21st-25th by
    // the `(is_self DESC, position DESC, id ASC)` order). They
    // must NOT appear in the rendered output. The previous
    // version of this test asserted `wi_20` was not in the output,
    // but `wi_20` is actually within the cap (alphabetically sorted,
    // `wi_20` precedes `wi_21`..`wi_24` and `wi_3`..`wi_4`). The
    // test was silently wrong before because the rendered output
    // had no `id:` field, so the substring `wi_20` happened to
    // appear nowhere. Adding the id renderer surfaced the latent
    // bug — the correct assertion is the 5 dropped items.
    for (5..10) |i| {
        const expected_dropped = try std.fmt.allocPrint(alloc, "wi_{d}", .{i});
        defer alloc.free(expected_dropped);
        try testing.expect(std.mem.indexOf(u8, md, expected_dropped) == null);
    }
}

// ─── Test 8: renderer — empty string for unbound session ──────────────────

test "BuildWorkspaceContext returns empty string for empty workspace" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Workspace exists, but no items and no tasks. A session query
    // that doesn't match any task row returns null → renderer returns "".
    try ctx.db.exec(alloc,
        "INSERT INTO workspaces (id, name) VALUES (?, ?)",
        &.{ "ws_empty", "empty" },
    );

    const md = try agentic_loop.prompts_mod.makeWorkspaceContext(alloc, &ctx.db, "sess_any");
    defer alloc.free(md);

    try testing.expectEqualStrings("", md);
}

// ─── Test 9: regression — item_id: / task_id: labels are visually distinct ──

test "BuildWorkspaceContext uses item_id: and task_id: labels (visually distinct)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Same seed as Test 6 (the markdown-shape test) — gives us a
    // self item + a sibling item, each with one task. The renderer
    // should produce both `item_id:` and `task_id:` labels and
    // crucially should NOT use the bare `id:` label (it was the
    // source of the LLM confusion that Chunk 1 validates against).
    try seedWorkspace(&ctx.db, alloc, .{
        .workspace_id = "ws_disambig",
        .items = &.{
            .{ .id = "wi_a", .path = "/abs/a", .name = "Alpha" },
            .{ .id = "wi_b", .path = "/abs/b", .name = "Beta" },
        },
        .tasks = &.{
            .{ .id = "task_a1", .workspace_item_id = "wi_a", .name = "task-a1" },
            .{ .id = "task_b1", .workspace_item_id = "wi_b", .name = "task-b1" },
        },
    });

    const md = try agentic_loop.prompts_mod.makeWorkspaceContext(alloc, &ctx.db, "task_a1");
    defer alloc.free(md);

    // The two labels must be visually distinct so the LLM doesn't
    // confuse them (see kanban_list input validation in Chunk 1).
    try testing.expect(std.mem.indexOf(u8, md, "item_id: ") != null);
    try testing.expect(std.mem.indexOf(u8, md, "task_id: ") != null);

    // And the bare `id: ` label (without a prefix) must NOT appear
    // anywhere — it's ambiguous and was the source of the original
    // bug. Match against the markdown rendering prefix `(id: `
    // (item lines start with `- **Name** (`) and task lines with
    // `  - task: \`name\` (`, so the only way an ambiguous `id: `
    // could appear is inside one of those parenthesized groups.
    // We use `((id: \`` and ` (id: \`` as the search needles — both
    // are impossible substrings of the disambiguated `item_id:` and
    // `task_id:` labels.
    try testing.expect(std.mem.indexOf(u8, md, " (id: `") == null);
    try testing.expect(std.mem.indexOf(u8, md, "(id: `") == null);
}

// ─── Tests for BuildKanbanStatusPrompt ────────────────────────────────────
//
// These tests cover the renderer added by Chunk 2 of the
// 2026-06-27-kanban-status-prompt plan. The renderer:
//
//   1. Returns "" when the parent item's item_type !== 'kanban'.
//   2. Returns "" when the session is not bound to any task (the
//      getWorkspaceContext anchor returns null).
//   3. Renders the "## Kanban Status Tracking" block with the
//      mandatory rule + column listing + 4 status transitions
//      when the parent is a kanban with columns.
//   4. Renders an unassigned note when the task has NULL kanban_column_id.
//   5. Renders an empty-board hint when the kanban has no columns.
//
// Plan: docs/plans/2026-06-27-kanban-status-prompt.md (Chunk 2)

test "BuildKanbanStatusPrompt returns empty string for non-kanban parent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed: a chat item (not kanban) with a task.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_chat', 'ws_x', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) VALUES ('sess_chat', 'chat task', 'wi_chat', 'standard')",
        &.{});

    const result = try agentic_loop.prompts_mod.makeKanbanContext(alloc, &ctx.db, "sess_chat", &[_]nalarcore.tool_models.AgentTool{});
    defer alloc.free(result);

    try testing.expectEqualStrings("", result);
}

test "BuildKanbanStatusPrompt returns empty string for unbound session" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // No tasks seeded — getWorkspaceContext returns null.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_kanban', 'ws_x', 'kanban')",
        &.{});

    const result = try agentic_loop.prompts_mod.makeKanbanContext(alloc, &ctx.db, "sess_unbound", &[_]nalarcore.tool_models.AgentTool{});
    defer alloc.free(result);

    try testing.expectEqualStrings("", result);
}

test "BuildKanbanStatusPrompt renders mandatory rule + columns for kanban parent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed: a kanban item with 3 columns, task in column 0.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_kanban', 'ws_x', 'kanban')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, description, position) VALUES " ++
            "('col_a', 'wi_kanban', 'todo', '', 0), " ++
            "('col_b', 'wi_kanban', 'in progress', 'Work currently in flight', 1), " ++
            "('col_c', 'wi_kanban', 'done', 'Shipped to the user', 2)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, kanban_column_id, task_type) " ++
            "VALUES ('sess_kanban', 'kanban task', 'wi_kanban', 'col_a', 'standard')",
        &.{});

    const result = try agentic_loop.prompts_mod.makeKanbanContext(alloc, &ctx.db, "sess_kanban", &[_]nalarcore.tool_models.AgentTool{});
    defer alloc.free(result);

    // Mandatory rule is present (imperative wording — matches the
    // exact substring so a future "soften the wording" PR breaks this test).
    try testing.expect(std.mem.indexOf(u8, result, "## Kanban Status Tracking") != null);
    try testing.expect(std.mem.indexOf(u8, result, "MUST call the `kanban_move_task` tool") != null);

    // Current column line shows the resolved column name + id.
    try testing.expect(std.mem.indexOf(u8, result, "Current column:** `todo` (`col_a`)") != null);

    // All three columns listed with ids + positions.
    try testing.expect(std.mem.indexOf(u8, result, "- `todo` (`col_a`, position 0)") != null);
    try testing.expect(std.mem.indexOf(u8, result, "- `in progress` (`col_b`, position 1)") != null);
    try testing.expect(std.mem.indexOf(u8, result, "- `done` (`col_c`, position 2)") != null);

    // Descriptions (Migration 053): the two non-empty descriptions render
    // as indented sub-lines, the empty one (col_a) renders no sub-line.
    try testing.expect(std.mem.indexOf(u8, result, "  Description: Work currently in flight") != null);
    try testing.expect(std.mem.indexOf(u8, result, "  Description: Shipped to the user") != null);

    // Sanity: the empty-description column should NOT have a stray
    // "Description: " sub-line immediately after its row. Check only
    // the next single line (slice up to the next "\n"), not the whole
    // tail — later rows do have descriptions and would match.
    const todo_row = std.mem.indexOf(u8, result, "- `todo` (`col_a`, position 0)\n") orelse
        return error.TodoRowNotFound;
    const after_todo = result[todo_row..];
    const next_nl = std.mem.indexOfScalar(u8, after_todo, '\n') orelse after_todo.len;
    const next_line = after_todo[0..next_nl];
    try testing.expect(std.mem.indexOf(u8, next_line, "  Description: ") == null);

    // All four status transitions present (each as a **bold** word at
    // the start of a bullet).
    try testing.expect(std.mem.indexOf(u8, result, "**start**") != null);
    try testing.expect(std.mem.indexOf(u8, result, "**milestone**") != null);
    try testing.expect(std.mem.indexOf(u8, result, "**complete**") != null);
    try testing.expect(std.mem.indexOf(u8, result, "**blocked**") != null);
}

test "BuildKanbanStatusPrompt renders unassigned note when task has no column" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed: kanban item with columns, but task has NULL kanban_column_id.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_kanban', 'ws_x', 'kanban')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_a', 'wi_kanban', 'todo', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) " ++
            "VALUES ('sess_kanban', 'kanban task', 'wi_kanban', 'standard')",
        &.{});

    const result = try agentic_loop.prompts_mod.makeKanbanContext(alloc, &ctx.db, "sess_kanban", &[_]nalarcore.tool_models.AgentTool{});
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "Current column:** _unassigned_") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Your first move will assign it") != null);
}

test "BuildKanbanStatusPrompt renders empty-board hint when kanban has no columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed: kanban item, NO columns, 1 task.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_kanban', 'ws_x', 'kanban')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) " ++
            "VALUES ('sess_kanban', 'kanban task', 'wi_kanban', 'standard')",
        &.{});

    const result = try agentic_loop.prompts_mod.makeKanbanContext(alloc, &ctx.db, "sess_kanban", &[_]nalarcore.tool_models.AgentTool{});
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "_No columns configured yet._") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Ask the user to add columns") != null);
}

test "BuildKanbanStatusPrompt returns empty string for empty session_id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const result = try agentic_loop.prompts_mod.makeKanbanContext(alloc, &ctx.db, "", &[_]nalarcore.tool_models.AgentTool{});
    defer alloc.free(result);

    try testing.expectEqualStrings("", result);
}

// ─── Tests for the Follow-up Tasks hint (gated on create_kanban_task) ──
//
// Plan: docs/superpowers/plans/2026-07-29-create-kanban-task-tool.md
// (post-PR feature: conditional system prompt in kanban mode that
// tells the AI to suggest creating a kanban task when it discovers
// follow-up work).

test "BuildKanbanStatusPrompt renders Follow-up Tasks hint when create_kanban_task is equipped" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed: a kanban item with 1 task.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_kanban', 'ws_x', 'kanban')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, description, position) VALUES " ++
            "('col_a', 'wi_kanban', 'todo', '', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, kanban_column_id, task_type) " ++
            "VALUES ('sess_kanban', 'kanban task', 'wi_kanban', 'col_a', 'standard')",
        &.{});

    // Equip the create_kanban_task tool.
    const tools = [_]nalarcore.tool_models.AgentTool{
        .{
            .type = "function",
            .function = .{
                .name = "create_kanban_task",
                .description = "stub",
                .parameters = .{
                    .type = "object",
                    .properties = &.{},
                    .required = &.{},
                },
            },
        },
    };

    const result = try agentic_loop.prompts_mod.makeKanbanContext(alloc, &ctx.db, "sess_kanban", &tools);
    defer alloc.free(result);

    // The Follow-up Tasks header is present (verifies the gate fires).
    try testing.expect(std.mem.indexOf(u8, result, "## Follow-up Tasks") != null);

    // The hint tells the AI to suggest creating tasks on this kanban
    // (verifies the prompt content matches the spec).
    try testing.expect(std.mem.indexOf(u8, result, "suggest creating a new task on this kanban") != null);
    try testing.expect(std.mem.indexOf(u8, result, "create_kanban_task") != null);
}

test "BuildKanbanStatusPrompt omits Follow-up Tasks hint when create_kanban_task is NOT equipped" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_kanban', 'ws_x', 'kanban')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, description, position) VALUES " ++
            "('col_a', 'wi_kanban', 'todo', '', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, kanban_column_id, task_type) " ++
            "VALUES ('sess_kanban', 'kanban task', 'wi_kanban', 'col_a', 'standard')",
        &.{});

    // Equip a different (unrelated) tool. The gate should NOT fire.
    const tools = [_]nalarcore.tool_models.AgentTool{
        .{
            .type = "function",
            .function = .{
                .name = "kanban_list",
                .description = "stub",
                .parameters = .{
                    .type = "object",
                    .properties = &.{},
                    .required = &.{},
                },
            },
        },
    };

    const result = try agentic_loop.prompts_mod.makeKanbanContext(alloc, &ctx.db, "sess_kanban", &tools);
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "## Follow-up Tasks") == null);
}

test "BuildKanbanStatusPrompt omits Follow-up Tasks hint for non-kanban parent even when tool is equipped" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Parent is a CHAT item, not a kanban. The whole kanban section
    // is silently skipped (returns ""), so the conditional hint
    // never renders.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_chat', 'ws_x', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) " ++
            "VALUES ('sess_chat', 'chat task', 'wi_chat', 'standard')",
        &.{});

    const tools = [_]nalarcore.tool_models.AgentTool{
        .{
            .type = "function",
            .function = .{
                .name = "create_kanban_task",
                .description = "stub",
                .parameters = .{
                    .type = "object",
                    .properties = &.{},
                    .required = &.{},
                },
            },
        },
    };

    const result = try agentic_loop.prompts_mod.makeKanbanContext(alloc, &ctx.db, "sess_chat", &tools);
    defer alloc.free(result);

    try testing.expectEqualStrings("", result);
}
