const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const kanban_list = @import("kanban_list.zig");
const kanban_model = nalarcore.ai_mod.kanban_model;
const text_normalize = nalarcore.helpers.text_normalize;

const TOOL_PATH = "src/modules/agent/tools/kanban_list.zig";
const TOOL_REGISTRY_PATH = "src/ai_workflow/tui/tool_registry.zig";

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match even when
/// the file was checked out on Windows with autocrlf=true (see
/// `.gitattributes` + `src/helpers/text_normalize.zig` for context).
/// The returned buffer is owned by the caller (freed with `allocator.free`).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── Static source-check tests ────────────────────────────────────────────

test "kanban_list tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"kanban_list\"")) {
        std.debug.print("!! kanban_list.zig does not define the tool with .name = \"kanban_list\" !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "kanban_list description mentions workspace context for ids" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The description must tell the LLM that workspace_id and item_id
    // come from the active chat's workspace context — otherwise the
    // LLM will hallucinate ids or fail to call the tool.
    if (!contains(source, "## Workspace Context") and !contains(source, "workspace_id") and !contains(source, "workspace context")) {
        std.debug.print("!! kanban_list description does not mention the workspace context for id discovery !!\n", .{});
        return error.WorkspaceContextHintMissing;
    }
}

test "kanban_list description explains WHEN to use the tool" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The description must include a "when to use" sentence so the
    // LLM picks this tool for kanban-related queries. The user's
    // task description suggested phrases like "user mentions a
    // kanban" or "asks about task status".
    if (!contains(source, "Use this tool when")) {
        std.debug.print("!! kanban_list description does not include a 'Use this tool when' signal !!\n", .{});
        return error.WhenToUseMissing;
    }
}

test "kanban_list input struct has workspace_id + item_id fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "workspace_id: []const u8")) {
        std.debug.print("!! KanbanListInput is missing the 'workspace_id' field !!\n", .{});
        return error.WorkspaceIdFieldMissing;
    }
    if (!contains(source, "item_id: []const u8")) {
        std.debug.print("!! KanbanListInput is missing the 'item_id' field !!\n", .{});
        return error.ItemIdFieldMissing;
    }
}

test "kanban_list input struct supports optional column_id filter" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // column_id is optional — used to narrow the task list to one
    // column (e.g. "what's in the done column?"). Must be nullable.
    if (!contains(source, "column_id: ?[]const u8")) {
        std.debug.print("!! KanbanListInput is missing the 'column_id: ?[]const u8' field !!\n", .{});
        return error.ColumnIdFieldMissing;
    }
}

test "kanban_list description explains the column_id filter behavior" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "column_id")) {
        std.debug.print("!! kanban_list description does not mention 'column_id' (LLM won't know to use it) !!\n", .{});
        return error.ColumnIdDescriptionMissing;
    }
}

// ─── Static wiring tests ────────────────────────────────────────────────

test "tool_registry.zig imports kanban_list module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    if (!contains(source, "kanban_list_mod")) {
        std.debug.print("!! tool_registry.zig does not import kanban_list_mod !!\n", .{});
        return error.KanbanListModImportMissing;
    }
    if (!contains(source, "const kanban_list_mod = nalar_mod.kanban_list;")) {
        std.debug.print("!! tool_registry.zig does not bind kanban_list_mod = nalar_mod.kanban_list !!\n", .{});
        return error.KanbanListModBindingMissing;
    }
}

test "tool_registry.zig defines execKanbanList" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub fn execKanbanList(")) {
        std.debug.print("!! tool_registry.zig does not define pub fn execKanbanList !!\n", .{});
        return error.ExecKanbanListMissing;
    }
}

test "UNIFIED_TOOL_REGISTRY contains kanban_list entry" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"kanban_list\"")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY is missing the kanban_list name entry !!\n", .{});
        return error.RegistryNameEntryMissing;
    }
    if (!contains(source, ".exec = execKanbanList")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .exec = execKanbanList !!\n", .{});
        return error.RegistryExecBindingMissing;
    }
    if (!contains(source, ".tool_def = kanban_list_mod.kanban_list_tool")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .tool_def = kanban_list_mod.kanban_list_tool !!\n", .{});
        return error.RegistryToolDefBindingMissing;
    }
}

test "allAgentTools comptime list contains kanban_list tool def" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    if (!contains(source, "kanban_list_mod.kanban_list_tool,")) {
        std.debug.print("!! allAgentTools comptime list is missing kanban_list_mod.kanban_list_tool !!\n", .{});
        return error.AllAgentToolsEntryMissing;
    }
}

test "nalarcore root.zig exposes kanban_list module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, "src/root.zig");
    defer allocator.free(source);
    if (!contains(source, "pub const kanban_list = @import(\"modules/agent/tools/kanban_list.zig\");")) {
        std.debug.print("!! root.zig does not expose kanban_list as a top-level module !!\n", .{});
        return error.NalarcoreExportMissing;
    }
}

// ─── XML serialization behavioral tests (no DB required) ───────────────

test "toXml on empty lists produces <kanban>...</kanban>" {
    const alloc = testing.allocator;
    const cols = &[_]kanban_list.ColumnSummary{};
    const tasks = &[_]kanban_list.TaskSummary{};
    const xml = try kanban_list.toXml(alloc, "ws_1", "item_1", cols, tasks);
    defer alloc.free(xml);
    try testing.expect(std.mem.startsWith(u8, xml, "<kanban>"));
    try testing.expect(std.mem.endsWith(u8, xml, "</kanban>"));
    // No <column> or <task> blocks for empty lists
    try testing.expect(!contains(xml, "<column>"));
    try testing.expect(!contains(xml, "<task>"));
}

test "toXml renders column summaries with id/name/position/task_count" {
    const alloc = testing.allocator;
    const cols = [_]kanban_list.ColumnSummary{
        .{ .id = "col_todo", .name = "todo", .position = 0, .task_count = 2 },
        .{ .id = "col_done", .name = "done", .position = 1, .task_count = 1 },
    };
    const tasks = &[_]kanban_list.TaskSummary{};
    const xml = try kanban_list.toXml(alloc, "ws_1", "item_1", &cols, tasks);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<column>"));
    try testing.expect(contains(xml, "<id>col_todo</id>"));
    try testing.expect(contains(xml, "<name>todo</name>"));
    try testing.expect(contains(xml, "<task_count>2</task_count>"));
    try testing.expect(contains(xml, "<name>done</name>"));
    try testing.expect(contains(xml, "<task_count>1</task_count>"));
}

test "toXml renders task summaries with optional column_id/column_name" {
    const alloc = testing.allocator;
    const cols = &[_]kanban_list.ColumnSummary{};
    const tasks = [_]kanban_list.TaskSummary{
        .{ .id = "t_a", .name = "Task A", .column_id = "col_todo", .column_name = "todo", .position = 0 },
        .{ .id = "t_b", .name = "Task B", .column_id = null, .column_name = null, .position = -1 },
    };
    const xml = try kanban_list.toXml(alloc, "ws_1", "item_1", cols, &tasks);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<task>"));
    try testing.expect(contains(xml, "<id>t_a</id>"));
    try testing.expect(contains(xml, "<name>Task A</name>"));
    try testing.expect(contains(xml, "<column_id>col_todo</column_id>"));
    try testing.expect(contains(xml, "<column_name>todo</column_name>"));
    // Unassigned task has empty <column_id>...</column_id> and
    // <column_name>...</column_name> blocks (NOT absent).
    try testing.expect(contains(xml, "<column_id></column_id>"));
    try testing.expect(contains(xml, "<column_name></column_name>"));
}

test "toXml escapes special characters in column + task names" {
    const alloc = testing.allocator;
    const cols = [_]kanban_list.ColumnSummary{
        .{ .id = "col_x", .name = "in <review>", .position = 0, .task_count = 0 },
    };
    const tasks = &[_]kanban_list.TaskSummary{};
    const xml = try kanban_list.toXml(alloc, "ws_1", "item_1", &cols, tasks);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "&lt;review&gt;"));
    try testing.expect(!contains(xml, "<review>")); // ensure raw is escaped
}

test "errorXml on missing field returns <kanban><error>...</error></kanban>" {
    const alloc = testing.allocator;
    const xml = try kanban_list.errorXml(alloc, "workspace_id and item_id are required");
    defer alloc.free(xml);
    try testing.expect(std.mem.startsWith(u8, xml, "<kanban>"));
    try testing.expect(std.mem.endsWith(u8, xml, "</kanban>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "workspace_id and item_id are required"));
}

// ─── DB integration behavioral tests (in-memory SQLite) ────────────────

/// Set up an in-memory SQLite with the kanban tables + a kanban
/// workspace item + 3 default columns (todo/in progress/done).
///
/// Returns the db + threaded as a value (not a pointer) so the
/// caller can `var s = try setupDb();` and pass `&s.db` to
/// non-const-`*SqliteBackend` parameters — exactly the pattern from
/// `kanban_model_test.zig`. Returns an unnamed struct so the
/// caller's `var s` infers the fields.
fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspaces
    try db.exec(alloc,
        \\CREATE TABLE workspaces (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT,
        \\  created_at TEXT,
        \\  updated_at TEXT
        \\)
    , &.{});
    // workspace_items
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT,
        \\  item_type TEXT,
        \\  name TEXT,
        \\  path TEXT,
        \\  position INTEGER,
        \\  created_at TEXT,
        \\  updated_at TEXT
        \\)
    , &.{});
    // kanban_columns (mirrors Migration 051)
    try db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT,
        \\  name TEXT,
        \\  description TEXT NOT NULL DEFAULT '',
        \\  position INTEGER,
        \\  created_at TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    // workspace_item_tasks (with kanban_column_id + kanban_position
    // per Migration 051)
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT,
        \\  name TEXT,
        \\  session_id TEXT,
        \\  task_type TEXT,
        \\  kanban_column_id TEXT,
        \\  kanban_position INTEGER
        \\)
    , &.{});

    // Insert one workspace + one kanban item + 3 columns.
    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'Test')", &.{});
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('item_1', 'ws_1', 'kanban', 'Sprint board')", &.{});
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_todo', 'item_1', 'todo', 0)", &.{});
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_ip', 'item_1', 'in progress', 1)", &.{});
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_done', 'item_1', 'done', 2)", &.{});

    return .{ .db = db, .threaded = threaded };
}

test "listKanbanTasks returns all tasks with column + position" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Two tasks in todo, one in done, one unassigned.
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type, kanban_column_id, kanban_position) VALUES ('t1', 'item_1', 'Task 1', 'standard', 'col_todo', 0)", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type, kanban_column_id, kanban_position) VALUES ('t2', 'item_1', 'Task 2', 'standard', 'col_todo', 1)", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type, kanban_column_id, kanban_position) VALUES ('t3', 'item_1', 'Task 3', 'standard', 'col_done', 0)", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type, kanban_column_id, kanban_position) VALUES ('t4', 'item_1', 'Task 4 unassigned', 'standard', NULL, NULL)", &.{});

    const rows = try kanban_list.listKanbanTasks(alloc, &s.db, "item_1");
    defer kanban_list.freeKanbanTaskRows(alloc, rows);

    try testing.expectEqual(@as(usize, 4), rows.len);
    // Unassigned task has empty kanban_column_id (the COALESCE
    // maps NULL → '').
    var unassigned_found = false;
    for (rows) |r| {
        if (std.mem.eql(u8, r.id, "t4")) {
            try testing.expectEqual(@as(usize, 0), r.kanban_column_id.len);
            try testing.expectEqual(@as(i64, -1), r.kanban_position);
            unassigned_found = true;
        }
    }
    try testing.expect(unassigned_found);
}

test "executeKanbanListToString returns columns with task_count" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // 2 in todo, 1 in done.
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type, kanban_column_id, kanban_position) VALUES ('t1', 'item_1', 'Task 1', 'standard', 'col_todo', 0)", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type, kanban_column_id, kanban_position) VALUES ('t2', 'item_1', 'Task 2', 'standard', 'col_todo', 1)", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type, kanban_column_id, kanban_position) VALUES ('t3', 'item_1', 'Task 3', 'standard', 'col_done', 0)", &.{});

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);

    // todo has 2 tasks
    try testing.expect(contains(xml, "<id>col_todo</id>"));
    try testing.expect(contains(xml, "<name>todo</name>"));
    try testing.expect(contains(xml, "<task_count>2</task_count>"));
    // done has 1 task
    try testing.expect(contains(xml, "<id>col_done</id>"));
    try testing.expect(contains(xml, "<task_count>1</task_count>"));
    // in progress has 0 tasks
    try testing.expect(contains(xml, "<id>col_ip</id>"));
    try testing.expect(contains(xml, "<task_count>0</task_count>"));
}

test "executeKanbanListToString with column_id filter returns only that column's tasks" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type, kanban_column_id, kanban_position) VALUES ('t1', 'item_1', 'Task 1', 'standard', 'col_todo', 0)", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type, kanban_column_id, kanban_position) VALUES ('t2', 'item_1', 'Task 2', 'standard', 'col_todo', 1)", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type, kanban_column_id, kanban_position) VALUES ('t3', 'item_1', 'Task 3', 'standard', 'col_done', 0)", &.{});

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .column_id = "col_todo",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);

    // Both todo tasks should appear
    try testing.expect(contains(xml, "<name>Task 1</name>"));
    try testing.expect(contains(xml, "<name>Task 2</name>"));
    // Done task should NOT appear
    try testing.expect(!contains(xml, "<name>Task 3</name>"));
}

test "executeKanbanListToString returns error XML when item_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "workspace_id and item_id are required"));
}

// Regression test for the use-after-free bug fixed in this branch.
// Before the fix, `defer if (col_name) |n| allocator.free(n);` inside
// the for-loop fired at the end of EACH iteration — so the col_name
// slice was freed BEFORE toXml() was called, leaving task_summaries
// with dangling pointers. The AI then read the freed memory (Zig's
// 0xAA debug-allocator free-fill pattern) and interpreted the garbled
// output as "empty board".
//
// This test inserts a task assigned to a column and asserts the
// rendered XML contains the real column_name, not 0xAA bytes.
test "executeKanbanListToString column_name is real bytes (use-after-free regression)" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // setupDb() inserts 3 default columns (todo/in progress/done).
    // Add one task assigned to the "in progress" column.
    try s.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type, kanban_column_id, kanban_position)
        \\VALUES ('t_uaf', 'item_1', 'Task Under Test', 'standard', 'col_ip', 0)
    , &.{});

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);

    // The task's column_name must be the literal string "in progress",
    // not freed/garbled memory. If the use-after-free bug recurs, the
    // slice would point at Zig's 0xAA free-fill pattern.
    try testing.expect(contains(xml, "<column_name>in progress</column_name>"));
    try testing.expect(contains(xml, "<id>col_ip</id>"));

    // Defensive: assert the rendered XML does NOT contain the 0xAA
    // free-fill byte (octal 252 = 0xAA). If it does, the slice
    // header is pointing at freed memory.
    try testing.expect(std.mem.indexOfScalar(u8, xml, 0xAA) == null);
}

// ─── Input validation tests (4 mistake shapes + empty-board hint) ──────

test "executeKanbanListToString returns error XML when item_id looks like a task_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // AI confused task_id (from kanban_move_task input) with item_id.
    // listColumns will silently return 0 rows; we want validation to
    // catch this BEFORE the query runs.
    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "task_1782442569739",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "item_id"));
    try testing.expect(contains(xml, "task_"));
    // Should mention the correct id source so the LLM self-corrects.
    try testing.expect(contains(xml, "item_"));
}

test "executeKanbanListToString returns error XML when item_id looks like a column_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "col_1782442554112968570",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "col_"));
}

test "executeKanbanListToString returns error XML when item_id looks like a workspace_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "ws_1",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
}

test "executeKanbanListToString returns error XML when item_id matches no workspace_item" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Valid shape (starts with item_) but the row doesn't exist.
    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_does_not_exist",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "no workspace_item"));
}

test "executeKanbanListToString returns empty-board hint (not error) when item_id is valid but has no columns" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Insert a kanban item with NO columns (degenerate case — user
    // deleted all of them).
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('item_empty', 'ws_1', 'kanban', 'Empty board')",
        &.{});

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_empty",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    // NOT an error — the kanban genuinely has no columns. Just an
    // empty <columns> block + a friendly hint.
    try testing.expect(!contains(xml, "<error>"));
    try testing.expect(contains(xml, "<columns></columns>"));
    // Hint: "no columns" so the LLM can distinguish from a wrong-id case.
    try testing.expect(contains(xml, "no columns"));
}
