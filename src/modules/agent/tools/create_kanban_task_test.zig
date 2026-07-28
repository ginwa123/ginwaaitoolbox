//! Static-contract tests for the `create_kanban_task` agent tool.
//!
//! Lock the wire shape of the tool definition BEFORE any code lands
//! (TDD red). Each test reads `src/modules/agent/tools/create_kanban_task.zig`
//! from disk and asserts on required substrings. If a future refactor
//! drops a required substring, the corresponding test fails.
//!
//! Plan: docs/superpowers/plans/2026-07-29-create-kanban-task-tool.md (Task 1)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const create_kanban_task = @import("create_kanban_task.zig");
const text_normalize = nalarcore.helpers.text_normalize;

const TOOL_PATH = "src/modules/agent/tools/create_kanban_task.zig";

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
    allocator.free(raw);
    return normalized;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── Static source-check tests (RED — file does not exist yet) ────────────

test "create_kanban_task tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"create_kanban_task\"")) {
        std.debug.print(
            "\n!! create_kanban_task.zig does not define the tool with .name = \"create_kanban_task\" !!\n" ++
                "   The LLM dispatch will fail to find the tool by its schema name.\n", .{},
        );
        return error.ToolNameMissing;
    }
}

test "create_kanban_task description mentions kanban + task/card" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // Both substrings are required — "kanban" so the LLM scopes the
    // tool to kanban operations (matches the kanban_* prefix), and
    // "task" so the LLM recognizes the tool creates a card.
    if (!contains(source, "kanban")) {
        std.debug.print(
            "\n!! create_kanban_task description does not contain 'kanban' !!\n" ++
                "   LLM can't scope the tool to kanban contexts.\n", .{},
        );
        return error.KanbanKeywordMissing;
    }
    if (!contains(source, "task")) {
        std.debug.print(
            "\n!! create_kanban_task description does not contain 'task' !!\n" ++
                "   LLM can't recognize this as a card-creation tool.\n", .{},
        );
        return error.TaskKeywordMissing;
    }
}

test "create_kanban_task required fields are workspace_id + item_id + name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The .required field MUST contain all three. Order matters
    // only for the LLM's UX hint — we match the substring regardless.
    if (!contains(source, ".required = &.{ \"workspace_id\", \"item_id\", \"name\" }")) {
        std.debug.print(
            "\n!! create_kanban_task .required field is missing one of workspace_id / item_id / name !!\n" ++
                "   The tool must require all three; missing any one returns an undefined slice.\n", .{},
        );
        return error.RequiredFieldsMissing;
    }
}

test "create_kanban_task input struct has workspace_id + item_id + name fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The Zig struct must declare each field with the documented type.
    if (!contains(source, "workspace_id: []const u8")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput is missing the 'workspace_id' field !!\n",
        .{},
        );
        return error.WorkspaceIdFieldMissing;
    }
    if (!contains(source, "item_id: []const u8")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput is missing the 'item_id' field !!\n",
        .{},
        );
        return error.ItemIdFieldMissing;
    }
    if (!contains(source, "name: []const u8")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput is missing the 'name' field !!\n",
        .{},
        );
        return error.NameFieldMissing;
    }
}

test "create_kanban_task description marks column_id as optional" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The description must explicitly tell the LLM that column_id
    // is optional (so it knows to omit the field for auto-assign).
    if (!contains(source, "column_id")) {
        std.debug.print(
            "\n!! create_kanban_task description does not mention 'column_id' !!\n" ++
                "   LLM won't know it can omit the field for auto-assign.\n", .{},
        );
        return error.ColumnIdMentionMissing;
    }
}

test "create_kanban_task description tells LLM ids come from Workspace Context" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // Without this hint, the LLM will hallucinate ids. Matches the
    // convention in kanban_list / kanban_move_task / set_design_page.
    if (!contains(source, "## Workspace Context") and
        !contains(source, "Workspace Context") and
        !contains(source, "workspace context"))
    {
        std.debug.print(
            "\n!! create_kanban_task description does not mention Workspace Context !!\n" ++
                "   LLM will hallucinate workspace_id / item_id without this hint.\n", .{},
        );
        return error.WorkspaceContextHintMissing;
    }
}
// ─── DB integration behavioral tests (in-memory SQLite) ────────────────────
//
// These tests exercise `executeCreateKanbanTaskToString` end-to-end:
// they seed a workspace + kanban item + columns + (optionally) tasks,
// call the tool with crafted inputs, and assert on the returned XML
// + the DB state.
//
// Mirrors the pattern from `kanban_move_task_test.zig::setupDb`.
// See plan Task 3.

/// Open a fresh in-memory SQLite DB. Caller owns the returned
/// `db` + `threaded` and must `defer s.threaded.deinit();
/// defer s.db.deinit();`.
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
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT,
        \\  item_type TEXT,
        \\  name TEXT
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT,
        \\  name TEXT,
        \\  description TEXT NOT NULL DEFAULT '',
        \\  position INTEGER,
        \\  created_at TEXT NOT NULL DEFAULT ''
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT,
        \\  name TEXT,
        \\  description TEXT NOT NULL DEFAULT '',
        \\  task_type TEXT,
        \\  kanban_column_id TEXT,
        \\  kanban_position INTEGER,
        \\  last_human_touched_at INTEGER
        \\)
    , &[_][]const u8{});

    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'Test')", &[_][]const u8{});
    // Default seeded item — a kanban named 'Sprint' with 3 columns.
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) " ++
            "VALUES ('item_k1', 'ws_1', 'kanban', 'Sprint')",
        &[_][]const u8{},
    );
    try db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
            "VALUES ('col_todo', 'item_k1', 'todo', 0)",
        &[_][]const u8{},
    );
    try db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
            "VALUES ('col_ip', 'item_k1', 'in progress', 1)",
        &[_][]const u8{},
    );
    try db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
            "VALUES ('col_done', 'item_k1', 'done', 2)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

/// Count rows in `workspace_item_tasks` matching `WHERE id = ?`.
/// Used to assert the tool inserted exactly one row.
fn taskRowExists(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, task_id: []const u8) !bool {
    var q = try db.query(alloc,
        "SELECT 1 FROM workspace_item_tasks WHERE id = ?",
        &.{task_id},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return false;
    defer row.deinit(alloc);
    return true;
}

test "executeCreateKanbanTaskToString returns success XML on happy path" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "new task",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<kanban_task>"));
    try testing.expect(contains(xml, "<success>true</success>"));
    try testing.expect(contains(xml, "<task_id>"));
    try testing.expect(contains(xml, "<column_id>col_todo</column_id>"));
    try testing.expect(contains(xml, "<position>0</position>"));
    try testing.expect(!contains(xml, "<error>"));
}

test "executeCreateKanbanTaskToString inserts a row into workspace_item_tasks" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "insert me",
    });
    defer alloc.free(xml);

    // Extract the task_id from the XML (between <task_id> and </task_id>).
    const start = std.mem.indexOf(u8, xml, "<task_id>") orelse return error.MissingTaskIdTag;
    const task_id_start = start + "<task_id>".len;
    const end = std.mem.indexOf(u8, xml[task_id_start..], "</task_id>") orelse return error.MissingTaskIdCloseTag;
    const task_id = xml[task_id_start .. task_id_start + end];

    try testing.expect(try taskRowExists(alloc, &s.db, task_id));
}

test "executeCreateKanbanTaskToString appends at MAX(kanban_position)+1 when column has existing tasks" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Seed 2 existing tasks in the todo column at positions 0 and 1.
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type, kanban_column_id, kanban_position) " ++
            "VALUES ('t_existing_1', 'item_k1', 'first', 'standard', 'col_todo', 0)",
        &[_][]const u8{},
    );
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type, kanban_column_id, kanban_position) " ++
            "VALUES ('t_existing_2', 'item_k1', 'second', 'standard', 'col_todo', 1)",
        &[_][]const u8{},
    );

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "third",
    });
    defer alloc.free(xml);

    // The first column is col_todo — position 2 should be appended.
    try testing.expect(contains(xml, "<column_id>col_todo</column_id>"));
    try testing.expect(contains(xml, "<position>2</position>"));
}

test "executeCreateKanbanTaskToString returns error when workspace_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "",
        .item_id = "item_k1",
        .name = "x",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "workspace_id"));
}

test "executeCreateKanbanTaskToString returns error when item_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "",
        .name = "x",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "item_id"));
}

test "executeCreateKanbanTaskToString returns error when name is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "name"));
}

test "executeCreateKanbanTaskToString returns error when name is whitespace-only" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "   \t\n  ",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "name"));
}

test "executeCreateKanbanTaskToString returns error when parent item_type is not kanban" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Replace the kanban item with a chat item.
    try s.db.exec(alloc,
        "UPDATE workspace_items SET item_type = 'chat' WHERE id = 'item_k1'",
        &[_][]const u8{},
    );

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "x",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    // The error must mention the parent type so the LLM can self-correct.
    try testing.expect(contains(xml, "kanban") or contains(xml, "item_type"));
}

test "executeCreateKanbanTaskToString returns error when kanban has zero columns" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Delete all 3 seeded columns — the kanban is now column-less.
    try s.db.exec(alloc, "DELETE FROM kanban_columns WHERE workspace_item_id = 'item_k1'", &[_][]const u8{});

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "x",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "column") or contains(xml, "Column"));
}

test "executeCreateKanbanTaskToString honors explicit column_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "explicit placement",
        .column_id = "col_ip",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>true</success>"));
    try testing.expect(contains(xml, "<column_id>col_ip</column_id>"));
    try testing.expect(contains(xml, "<position>0</position>"));
}

test "executeCreateKanbanTaskToString rejects column_id that does not belong to the item" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Add a column under a DIFFERENT kanban item.
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) " ++
            "VALUES ('item_k2', 'ws_1', 'kanban', 'Other Sprint')",
        &[_][]const u8{},
    );
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
            "VALUES ('col_other', 'item_k2', 'todo', 0)",
        &[_][]const u8{},
    );

    // Try to place the new task in 'col_other' while item_id points
    // to 'item_k1'. The tool must reject this — the column does not
    // belong to the item.
    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "x",
        .column_id = "col_other",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "column") or contains(xml, "Column"));
}
