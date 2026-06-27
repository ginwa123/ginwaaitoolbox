const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const kanban_move_task = @import("kanban_move_task.zig");
const kanban_model = nalarcore.ai_mod.kanban_model;

const TOOL_PATH = "src/modules/agent/tools/kanban_move_task.zig";
const TOOL_REGISTRY_PATH = "src/ai_workflow/tui/tool_registry.zig";

/// Read a source file from disk, relative to the project root.
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── Static source-check tests ────────────────────────────────────────────

test "kanban_move_task tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"kanban_move_task\"")) {
        std.debug.print("!! kanban_move_task.zig does not define the tool with .name = \"kanban_move_task\" !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "kanban_move_task description explains WHEN to use the tool" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "Use this when")) {
        std.debug.print("!! kanban_move_task description does not include a 'Use this when' signal !!\n", .{});
        return error.WhenToUseMissing;
    }
}

test "kanban_move_task description tells LLM to call kanban_list first" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The description must instruct the LLM to call kanban_list
    // first to discover ids — otherwise the LLM will try to move
    // tasks with hallucinated ids.
    if (!contains(source, "kanban_list")) {
        std.debug.print("!! kanban_move_task description does not mention 'kanban_list' (LLM won't know to look up ids first) !!\n", .{});
        return error.KanbanListHintMissing;
    }
}

test "kanban_move_task description explains the name→id fallback" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The description must tell the LLM that target_column_name is
    // a fallback for when it doesn't have the column id.
    if (!contains(source, "target_column_name")) {
        std.debug.print("!! kanban_move_task description does not mention 'target_column_name' !!\n", .{});
        return error.TargetColumnNameDescriptionMissing;
    }
    if (!contains(source, "target_column_id")) {
        std.debug.print("!! kanban_move_task description does not mention 'target_column_id' !!\n", .{});
        return error.TargetColumnIdDescriptionMissing;
    }
}

test "kanban_move_task input struct has all required fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "workspace_id: []const u8")) {
        std.debug.print("!! KanbanMoveTaskInput is missing the 'workspace_id' field !!\n", .{});
        return error.WorkspaceIdFieldMissing;
    }
    if (!contains(source, "item_id: []const u8")) {
        std.debug.print("!! KanbanMoveTaskInput is missing the 'item_id' field !!\n", .{});
        return error.ItemIdFieldMissing;
    }
    if (!contains(source, "task_id: []const u8")) {
        std.debug.print("!! KanbanMoveTaskInput is missing the 'task_id' field !!\n", .{});
        return error.TaskIdFieldMissing;
    }
    if (!contains(source, "target_column_id: ?[]const u8")) {
        std.debug.print("!! KanbanMoveTaskInput is missing the 'target_column_id: ?[]const u8' field !!\n", .{});
        return error.TargetColumnIdFieldMissing;
    }
    if (!contains(source, "target_column_name: ?[]const u8")) {
        std.debug.print("!! KanbanMoveTaskInput is missing the 'target_column_name: ?[]const u8' field !!\n", .{});
        return error.TargetColumnNameFieldMissing;
    }
    if (!contains(source, "position: ?i64")) {
        std.debug.print("!! KanbanMoveTaskInput is missing the 'position: ?i64' field !!\n", .{});
        return error.PositionFieldMissing;
    }
}

test "kanban_move_task description explains recovery on error" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The description must include "On error, recover by" guidance
    // (mirrors the set_git_worktree pattern).
    if (!contains(source, "On error, recover by:")) {
        std.debug.print("!! kanban_move_task description is missing 'On error, recover by:' guidance !!\n", .{});
        return error.RecoveryGuidanceMissing;
    }
}

// ─── Static wiring tests ────────────────────────────────────────────────

test "tool_registry.zig imports kanban_move_task module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    if (!contains(source, "kanban_move_task_mod")) {
        std.debug.print("!! tool_registry.zig does not import kanban_move_task_mod !!\n", .{});
        return error.KanbanMoveTaskModImportMissing;
    }
    if (!contains(source, "const kanban_move_task_mod = nalar_mod.kanban_move_task;")) {
        std.debug.print("!! tool_registry.zig does not bind kanban_move_task_mod = nalar_mod.kanban_move_task !!\n", .{});
        return error.KanbanMoveTaskModBindingMissing;
    }
}

test "tool_registry.zig defines execKanbanMoveTask" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub fn execKanbanMoveTask(")) {
        std.debug.print("!! tool_registry.zig does not define pub fn execKanbanMoveTask !!\n", .{});
        return error.ExecKanbanMoveTaskMissing;
    }
}

test "UNIFIED_TOOL_REGISTRY contains kanban_move_task entry" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"kanban_move_task\"")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY is missing the kanban_move_task name entry !!\n", .{});
        return error.RegistryNameEntryMissing;
    }
    if (!contains(source, ".exec = execKanbanMoveTask")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .exec = execKanbanMoveTask !!\n", .{});
        return error.RegistryExecBindingMissing;
    }
    if (!contains(source, ".tool_def = kanban_move_task_mod.kanban_move_task_tool")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .tool_def = kanban_move_task_mod.kanban_move_task_tool !!\n", .{});
        return error.RegistryToolDefBindingMissing;
    }
}

test "allAgentTools comptime list contains kanban_move_task tool def" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    if (!contains(source, "kanban_move_task_mod.kanban_move_task_tool,")) {
        std.debug.print("!! allAgentTools comptime list is missing kanban_move_task_mod.kanban_move_task_tool !!\n", .{});
        return error.AllAgentToolsEntryMissing;
    }
}

test "nalarcore root.zig exposes kanban_move_task module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, "src/root.zig");
    defer allocator.free(source);
    if (!contains(source, "pub const kanban_move_task = @import(\"modules/agent/tools/kanban_move_task.zig\");")) {
        std.debug.print("!! root.zig does not expose kanban_move_task as a top-level module !!\n", .{});
        return error.NalarcoreExportMissing;
    }
}

// ─── XML serialization behavioral tests (no DB required) ───────────────

test "errorXml on missing field returns <kanban_move><success>false</success><error>...</error></kanban_move>" {
    const alloc = testing.allocator;
    const xml = try kanban_move_task.errorXml(alloc, "Missing required field: workspace_id");
    defer alloc.free(xml);
    try testing.expect(std.mem.startsWith(u8, xml, "<kanban_move>"));
    try testing.expect(std.mem.endsWith(u8, xml, "</kanban_move>"));
    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "Missing required field: workspace_id"));
}

test "successXml renders all fields" {
    const alloc = testing.allocator;
    const xml = try kanban_move_task.successXml(
        alloc,
        "task_123",
        "My task",
        "col_done",
        "done",
        2,
    );
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<success>true</success>"));
    try testing.expect(contains(xml, "<task_id>task_123</task_id>"));
    try testing.expect(contains(xml, "<task_name>My task</task_name>"));
    try testing.expect(contains(xml, "<column_id>col_done</column_id>"));
    try testing.expect(contains(xml, "<column_name>done</column_name>"));
    try testing.expect(contains(xml, "<position>2</position>"));
}

test "successXml escapes special characters" {
    const alloc = testing.allocator;
    const xml = try kanban_move_task.successXml(
        alloc,
        "task_&x",
        "<fancy>",
        "col_x",
        "in <review>",
        0,
    );
    defer alloc.free(xml);
    try testing.expect(contains(xml, "&amp;x"));
    try testing.expect(contains(xml, "&lt;fancy&gt;"));
    try testing.expect(contains(xml, "in &lt;review&gt;"));
    // Make sure the unescaped angle-bracket forms do NOT appear
    try testing.expect(!contains(xml, "<fancy>"));
    try testing.expect(!contains(xml, "in <review>"));
}

// ─── DB integration behavioral tests (in-memory SQLite) ────────────────

fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE workspaces (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT,
        \\  item_type TEXT,
        \\  name TEXT
        \\)
    , &.{});
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
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT,
        \\  name TEXT,
        \\  task_type TEXT,
        \\  kanban_column_id TEXT,
        \\  kanban_position INTEGER
        \\)
    , &.{});

    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'Test')", &.{});
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('item_1', 'ws_1', 'kanban', 'Sprint')", &.{});
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_todo', 'item_1', 'todo', 0)", &.{});
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_ip', 'item_1', 'in progress', 1)", &.{});
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_done', 'item_1', 'done', 2)", &.{});
    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type, kanban_column_id, kanban_position) VALUES ('t1', 'item_1', 'Auth task', 'standard', 'col_todo', 0)", &.{});
    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type, kanban_column_id, kanban_position) VALUES ('t2', 'item_1', 'Other task', 'standard', 'col_todo', 1)", &.{});

    return .{ .db = db, .threaded = threaded };
}

test "findColumnsByName case-insensitive match" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const matches = try kanban_move_task.findColumnsByName(alloc, &s.db, "item_1", "DONE");
    defer kanban_move_task.freeColumnMatches(alloc, matches);
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqualStrings("col_done", matches[0].id);
    try testing.expectEqualStrings("done", matches[0].name);
}

test "findColumnsByName returns empty when no match" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const matches = try kanban_move_task.findColumnsByName(alloc, &s.db, "item_1", "nonexistent");
    defer kanban_move_task.freeColumnMatches(alloc, matches);
    try testing.expectEqual(@as(usize, 0), matches.len);
}

test "findColumnsByName trims whitespace" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const matches = try kanban_move_task.findColumnsByName(alloc, &s.db, "item_1", "  done  ");
    defer kanban_move_task.freeColumnMatches(alloc, matches);
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqualStrings("done", matches[0].name);
}

test "findColumnsByName matches 'in progress' with space" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const matches = try kanban_move_task.findColumnsByName(alloc, &s.db, "item_1", "In Progress");
    defer kanban_move_task.freeColumnMatches(alloc, matches);
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqualStrings("col_ip", matches[0].id);
}

test "executeKanbanMoveTaskToString returns success XML on valid move" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_move_task.KanbanMoveTaskInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .task_id = "t1",
        .target_column_id = "col_done",
        .position = 0,
    };
    const xml = try kanban_move_task.executeKanbanMoveTaskToString(alloc, &s.db, input);
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>true</success>"));
    try testing.expect(contains(xml, "<task_id>t1</task_id>"));
    try testing.expect(contains(xml, "<task_name>Auth task</task_name>"));
    try testing.expect(contains(xml, "<column_id>col_done</column_id>"));
    try testing.expect(contains(xml, "<column_name>done</column_name>"));
}

test "executeKanbanMoveTaskToString resolves column name to id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_move_task.KanbanMoveTaskInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .task_id = "t1",
        .target_column_id = null,
        .target_column_name = "DONE", // case-insensitive match against "done"
        .position = 0,
    };
    const xml = try kanban_move_task.executeKanbanMoveTaskToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<success>true</success>"));
    try testing.expect(contains(xml, "<column_id>col_done</column_id>"));
}

test "executeKanbanMoveTaskToString returns Column not found error" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_move_task.KanbanMoveTaskInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .task_id = "t1",
        .target_column_name = "nonexistent",
    };
    const xml = try kanban_move_task.executeKanbanMoveTaskToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "Column not found"));
}

test "executeKanbanMoveTaskToString returns Need target_column_id/name error" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_move_task.KanbanMoveTaskInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .task_id = "t1",
        // Both target_column_id and target_column_name are null.
    };
    const xml = try kanban_move_task.executeKanbanMoveTaskToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "target_column_id or target_column_name"));
}

test "executeKanbanMoveTaskToString returns TaskNotFound error" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_move_task.KanbanMoveTaskInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .task_id = "nonexistent_task",
        .target_column_id = "col_done",
    };
    const xml = try kanban_move_task.executeKanbanMoveTaskToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "TaskNotFound"));
}

test "executeKanbanMoveTaskToString returns Missing required field for empty workspace_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_move_task.KanbanMoveTaskInput{
        .workspace_id = "",
        .item_id = "item_1",
        .task_id = "t1",
        .target_column_id = "col_done",
    };
    const xml = try kanban_move_task.executeKanbanMoveTaskToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "workspace_id"));
}

test "executeKanbanMoveTaskToString without position appends to end of column" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Insert one task in done column to set the max position.
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type, kanban_column_id, kanban_position) VALUES ('t_done', 'item_1', 'Already done', 'standard', 'col_done', 0)", &.{});

    // Move t1 to col_done with no position.
    const input = kanban_move_task.KanbanMoveTaskInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .task_id = "t1",
        .target_column_id = "col_done",
        // position = null → end-of-column
    };
    const xml = try kanban_move_task.executeKanbanMoveTaskToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<success>true</success>"));
    // The position should be MAX(0) + 1 = 1
    try testing.expect(contains(xml, "<position>1</position>"));
}
