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
const TOOL_REGISTRY_PATH = "src/ai_workflow/tui/agentic_loop/tools_equipped.zig"; // legacy alias; tool_registry.zig was deleted 2026-08-06 — see plan
const TOOLS_EQUIPPED_PATH = "src/ai_workflow/tui/agentic_loop/tools_equipped.zig";
const TOOL_EXEC_PATH = "src/ai_workflow/tui/agentic_loop/tools_exec_create_kanban_task.zig";

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
        \\  last_human_touched_at_nano INTEGER,
        \\  -- Migrations 067 / 069 / 071: the agent tool now writes
        \\  -- these columns via the new optional `tags` / `image_urls`
        \\  -- / `cwd` input fields. The schema here mirrors the
        \\  -- post-migration shape so the createWorkspaceItemTask
        \\  -- INSERT path can bind them (the dynamic-SQL builder
        \\  -- at llm_history.zig:4047-4056 emits `''` literals when
        \\  -- the caller passes `""` — which fails fast without
        \\  -- these columns present).
        \\  tags TEXT NOT NULL DEFAULT '',
        \\  image_urls TEXT NOT NULL DEFAULT '',
        \\  cwd TEXT NOT NULL DEFAULT ''
        \\)
    , &[_][]const u8{});
    // sessions table — required for the is_auto_retry_until_stop /
    // selected_profile_model path. The agent tool does INSERT OR
    // IGNORE INTO sessions keyed by the new task's id when either
    // field is supplied (mirrors task_create.zig:587-605).
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT,
        \\  status TEXT,
        \\  is_auto_retry_until_stop TEXT,
        \\  selected_profile_model TEXT
        \\)
    , &[_][]const u8{});
    // Post-Migration-072: task→column mapping lives in `kanban` join table
    try db.exec(alloc,
        \\CREATE TABLE kanban (
        \\  workspace_item_task_id TEXT PRIMARY KEY,
        \\  kanban_column_id TEXT NOT NULL,
        \\  kanban_position INTEGER NOT NULL DEFAULT 0
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

/// Read the first column of the first row returned by `sql`.
/// Returns a heap-owned slice; caller frees with `alloc.free`.
/// Returns an empty slice when no row matches (NOT an error) so
/// callers can do `readColumn(...) == ""` for "row absent" assertions.
fn readColumn(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, args: []const []const u8) ![]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    const row = (try q.next()) orelse return try alloc.dupe(u8, "");
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

/// Extract the task_id from the success XML returned by the tool.
/// Returns the borrowed slice (no allocation).
fn extractTaskId(xml: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, xml, "<task_id>") orelse return error.MissingTaskIdTag;
    const task_id_start = start + "<task_id>".len;
    const end = std.mem.indexOf(u8, xml[task_id_start..], "</task_id>") orelse return error.MissingTaskIdCloseTag;
    return xml[task_id_start .. task_id_start + end];
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
        "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) " ++
            "VALUES ('t_existing_1', 'item_k1', 'first', 'standard')",
        &[_][]const u8{},
    );
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) " ++
            "VALUES ('t_existing_2', 'item_k1', 'second', 'standard')",
        &[_][]const u8{},
    );
    try s.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) " ++
            "VALUES ('t_existing_1', 'col_todo', 0), ('t_existing_2', 'col_todo', 1)",
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

// ─── New optional fields: tags / image_urls / cwd / unattended / profile ──
//
// These tests exercise the 5 new optional input fields that were added
// to mirror the user-facing KanbanTaskDetailDialog form (Migrations
// 067 / 069 / 070-071 + 063 + 040). They follow the same static + DB
// pattern as the existing tests.

test "create_kanban_task parameters include tags property" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"tags\"")) {
        std.debug.print(
            "\n!! create_kanban_task.zig is missing .name = \"tags\" property !!\n" ++
                "   The LLM won't see tags in the tool schema.\n",
            .{},
        );
        return error.TagsPropertyMissing;
    }
}

test "create_kanban_task parameters include image_urls property" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"image_urls\"")) {
        std.debug.print(
            "\n!! create_kanban_task.zig is missing .name = \"image_urls\" property !!\n" ++
                "   The LLM won't see image_urls in the tool schema.\n",
            .{},
        );
        return error.ImageUrlsPropertyMissing;
    }
}

test "create_kanban_task parameters include cwd property" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"cwd\"")) {
        std.debug.print(
            "\n!! create_kanban_task.zig is missing .name = \"cwd\" property !!\n" ++
                "   The LLM won't see cwd in the tool schema.\n",
            .{},
        );
        return error.CwdPropertyMissing;
    }
}

test "create_kanban_task parameters include is_auto_retry_until_stop property" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"is_auto_retry_until_stop\"")) {
        std.debug.print(
            "\n!! create_kanban_task.zig is missing .name = \"is_auto_retry_until_stop\" property !!\n" ++
                "   The LLM won't see the unattended flag in the tool schema.\n",
            .{},
        );
        return error.UnattendedPropertyMissing;
    }
}

test "create_kanban_task parameters include selected_profile_model property" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"selected_profile_model\"")) {
        std.debug.print(
            "\n!! create_kanban_task.zig is missing .name = \"selected_profile_model\" property !!\n" ++
                "   The LLM won't see the profile field in the tool schema.\n",
            .{},
        );
        return error.SelectedProfilePropertyMissing;
    }
}

test "create_kanban_task input struct has tags field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "tags: ?[]const u8 = null,")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput is missing the 'tags' field !!\n",
            .{},
        );
        return error.TagsFieldMissing;
    }
}

test "create_kanban_task input struct has image_urls field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "image_urls: ?[]const u8 = null,")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput is missing the 'image_urls' field !!\n",
            .{},
        );
        return error.ImageUrlsFieldMissing;
    }
}

test "create_kanban_task input struct has cwd field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "cwd: ?[]const u8 = null,")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput is missing the 'cwd' field !!\n",
            .{},
        );
        return error.CwdFieldMissing;
    }
}

test "create_kanban_task input struct has is_auto_retry_until_stop field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "is_auto_retry_until_stop: ?[]const u8 = null,")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput is missing the 'is_auto_retry_until_stop' field !!\n",
            .{},
        );
        return error.UnattendedFieldMissing;
    }
}

test "create_kanban_task input struct has selected_profile_model field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "selected_profile_model: ?[]const u8 = null,")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput is missing the 'selected_profile_model' field !!\n",
            .{},
        );
        return error.SelectedProfileFieldMissing;
    }
}

test "create_kanban_task source mentions tags_validation and image_urls_validation" {
    // The validators live in http_handlers/ and are imported by the
    // tool. If a refactor moves them, this test catches it.
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "validateAndNormalizeTags")) {
        std.debug.print(
            "\n!! create_kanban_task.zig does not call validateAndNormalizeTags !!\n" ++
                "   Tags are not being validated.\n",
            .{},
        );
        return error.TagsValidatorCallMissing;
    }
    if (!contains(source, "validateImageUrls")) {
        std.debug.print(
            "\n!! create_kanban_task.zig does not call validateImageUrls !!\n" ++
                "   image_urls are not being validated.\n",
            .{},
        );
        return error.ImageUrlsValidatorCallMissing;
    }
    if (!contains(source, "updateTaskLastHumanTouchedAt")) {
        std.debug.print(
            "\n!! create_kanban_task.zig does not stamp last_human_touched_at !!\n" ++
                "   New cards will show 'awaiting review' until the user touches them.\n",
            .{},
        );
        return error.LastHumanTouchedStampMissing;
    }
}

// ─── DB behavior tests for new optional fields ──────────────────────────

test "executeCreateKanbanTaskToString persists tags when supplied" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "tagged",
        .tags = "[\"bug\",\"urgent\"]",
    });
    defer alloc.free(xml);

    const task_id = try extractTaskId(xml);
    const stored = try readColumn(alloc, &s.db,
        "SELECT tags FROM workspace_item_tasks WHERE id = ?",
        &.{task_id});
    defer alloc.free(stored);
    try testing.expectEqualStrings("[\"bug\",\"urgent\"]", stored);
}

test "executeCreateKanbanTaskToString persists image_urls when supplied" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "with images",
        .image_urls = "data:image/png;base64,abc||data:image/jpeg;base64,def",
    });
    defer alloc.free(xml);

    const task_id = try extractTaskId(xml);
    const stored = try readColumn(alloc, &s.db,
        "SELECT image_urls FROM workspace_item_tasks WHERE id = ?",
        &.{task_id});
    defer alloc.free(stored);
    try testing.expectEqualStrings("data:image/png;base64,abc||data:image/jpeg;base64,def", stored);
}

test "executeCreateKanbanTaskToString persists cwd when supplied" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "with cwd",
        .cwd = "/home/me/proj",
    });
    defer alloc.free(xml);

    const task_id = try extractTaskId(xml);
    const stored = try readColumn(alloc, &s.db,
        "SELECT cwd FROM workspace_item_tasks WHERE id = ?",
        &.{task_id});
    defer alloc.free(stored);
    try testing.expectEqualStrings("/home/me/proj", stored);
}

test "executeCreateKanbanTaskToString stamps last_human_touched_at on happy path" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "stamped",
    });
    defer alloc.free(xml);

    const task_id = try extractTaskId(xml);
    const stored = try readColumn(alloc, &s.db,
        "SELECT COALESCE(last_human_touched_at_nano, '') FROM workspace_item_tasks WHERE id = ?",
        &.{task_id});
    defer alloc.free(stored);
    // The stamp must be non-empty (a unix-ms integer string). The
    // pre-stamp default is NULL → COALESCE returns ''. After the
    // stamp it's a non-empty digit string.
    try testing.expect(stored.len > 0);
    try testing.expect(stored.len > 0 and stored[0] >= '0' and stored[0] <= '9');
}

test "executeCreateKanbanTaskToString creates sessions row when is_auto_retry_until_stop=1" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "unattended",
        .is_auto_retry_until_stop = "1",
    });
    defer alloc.free(xml);

    const task_id = try extractTaskId(xml);
    const stored = try readColumn(alloc, &s.db,
        "SELECT is_auto_retry_until_stop FROM sessions WHERE id = ?",
        &.{task_id});
    defer alloc.free(stored);
    try testing.expectEqualStrings("1", stored);
}

test "executeCreateKanbanTaskToString persists selected_profile_model when supplied" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "with profile",
        .selected_profile_model = "fast-model",
    });
    defer alloc.free(xml);

    const task_id = try extractTaskId(xml);
    const stored = try readColumn(alloc, &s.db,
        "SELECT selected_profile_model FROM sessions WHERE id = ?",
        &.{task_id});
    defer alloc.free(stored);
    try testing.expectEqualStrings("fast-model", stored);
}

test "executeCreateKanbanTaskToString writes both unattended and profile in single sessions row" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "combined",
        .is_auto_retry_until_stop = "1",
        .selected_profile_model = "my-profile",
    });
    defer alloc.free(xml);

    const task_id = try extractTaskId(xml);
    const flag = try readColumn(alloc, &s.db,
        "SELECT is_auto_retry_until_stop FROM sessions WHERE id = ?",
        &.{task_id});
    defer alloc.free(flag);
    try testing.expectEqualStrings("1", flag);

    const profile = try readColumn(alloc, &s.db,
        "SELECT selected_profile_model FROM sessions WHERE id = ?",
        &.{task_id});
    defer alloc.free(profile);
    try testing.expectEqualStrings("my-profile", profile);
}

// ─── Kanban task name = session name (plan: 2026-08-13-kanban-task-session-name-match.md) ──
//
// Pre-fix, the tool INSERT OR IGNORE INTO sessions keyed by task_id
// bound `name = task_id` (the literal id like "task_1786626864861"),
// while the kanban card showed the user-facing title. The sidebar
// (ChatsList / session_name) and the chat header (ChatView.chatName)
// read sessions.name and therefore displayed a different string than
// the kanban card. Post-fix the bind is `trimmed_name` so all three
// views show the same string the user typed.
//
// Behavioural regression: assert SELECT name FROM sessions WHERE id = task_id
// returns the trimmed user-facing title in both the unattended-only
// and profile-only code paths.

test "executeCreateKanbanTaskToString persists sessions.name == trimmed task name (unattended)" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "workspace item task nama and session name",
        .is_auto_retry_until_stop = "1",
    });
    defer alloc.free(xml);

    const task_id = try extractTaskId(xml);
    const stored = try readColumn(alloc, &s.db,
        "SELECT name FROM sessions WHERE id = ?",
        &.{task_id});
    defer alloc.free(stored);
    // Pre-fix this returned task_id (the literal task id). Post-fix it
    // must equal the trimmed user-facing title.
    try testing.expectEqualStrings("workspace item task nama and session name", stored);
}

test "executeCreateKanbanTaskToString persists sessions.name == trimmed task name (profile)" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        // Leading/trailing whitespace; the tool trims before INSERT
        // (see executeCreateKanbanTaskToString line 463-466), so the
        // sessions.name must be the trimmed value.
        .name = "   my chatty task   ",
        .selected_profile_model = "fast-model",
    });
    defer alloc.free(xml);

    const task_id = try extractTaskId(xml);
    const stored = try readColumn(alloc, &s.db,
        "SELECT name FROM sessions WHERE id = ?",
        &.{task_id});
    defer alloc.free(stored);
    try testing.expectEqualStrings("my chatty task", stored);
}

test "executeCreateKanbanTaskToString rejects malformed tags" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "bad tags",
        .tags = "not-a-json-array",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "tags"));
}

test "executeCreateKanbanTaskToString rejects invalid image_urls" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "bad images",
        .image_urls = "not-a-data-url",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "image_urls"));
}

test "executeCreateKanbanTaskToString rejects relative cwd" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "relative",
        .cwd = "relative/path",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "absolute"));
}

// ─── Registration static-contract tests (Task 7) ────────────────────────
//
// Pin the registration contract: a future refactor that drops
// `create_kanban_task` from any of the registry / re-export /
// tools_equipped surfaces would silently disable the tool. These
// tests catch that.

test "tools_equipped imports create_kanban_task module" {
    // After deduplication of `UNIFIED_TOOL_REGISTRY` (2026-08-06), the
    // registry body lives in `tools_equipped.zig` and no longer lives
    // in `tool_registry.zig`. This test now reads the imports from
    // the canonical home.
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, "const kanban_create_task_tool = nalarcore.create_kanban_task;")) {
        std.debug.print(
            "\n!! tools_equipped.zig does not bind create_kanban_task module !!\n",
            .{},
        );
        return error.CreateKanbanTaskModBindingMissing;
    }
}

test "agentic_loop defines execCreateKanbanTask" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_EXEC_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub fn execCreateKanbanTask(")) {
        std.debug.print(
            "\n!! tools_exec_create_kanban_task.zig does not define pub fn execCreateKanbanTask !!\n",
            .{},
        );
        return error.ExecCreateKanbanTaskMissing;
    }
}

test "UNIFIED_TOOL_REGISTRY contains create_kanban_task entry" {
    // The registry body moved from `tool_registry.zig` (deleted) to
    // `tools_equipped.zig` (canonical home) on 2026-08-06. The test
    // now reads from the canonical file. tools_equipped.zig imports
    // `tools = @import("tools.zig")` directly, so the `.exec` binding
    // is `tools.execCreateKanbanTask` (NOT `agentic_loop_mod.tools.execCreateKanbanTask`).
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"create_kanban_task\"")) {
        std.debug.print(
            "\n!! UNIFIED_TOOL_REGISTRY is missing the create_kanban_task name entry !!\n",
            .{},
        );
        return error.RegistryNameEntryMissing;
    }
    if (!contains(source, ".exec = tools.execCreateKanbanTask")) {
        std.debug.print(
            "\n!! UNIFIED_TOOL_REGISTRY entry is missing .exec = tools.execCreateKanbanTask !!\n",
            .{},
        );
        return error.RegistryExecBindingMissing;
    }
    if (!contains(source, ".tool_def = kanban_create_task_tool.create_kanban_task_tool")) {
        std.debug.print(
            "\n!! UNIFIED_TOOL_REGISTRY entry is missing .tool_def = kanban_create_task_tool.create_kanban_task_tool !!\n",
            .{},
        );
        return error.RegistryToolDefBindingMissing;
    }
}

test "nalarcore root.zig exposes create_kanban_task module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, "src/root.zig");
    defer allocator.free(source);
    if (!contains(source, "pub const create_kanban_task = @import(\"modules/agent/tools/create_kanban_task.zig\");")) {
        std.debug.print(
            "\n!! root.zig does not expose create_kanban_task as a top-level module !!\n",
            .{},
        );
        return error.NalarcoreExportMissing;
    }
}

test "agentic_loop tools.zig re-exports execCreateKanbanTask" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, "src/ai_workflow/tui/agentic_loop/tools.zig");
    defer allocator.free(source);
    if (!contains(source, "execCreateKanbanTask")) {
        std.debug.print(
            "\n!! agentic_loop/tools.zig does not re-export execCreateKanbanTask !!\n",
            .{},
        );
        return error.ToolsReexportMissing;
    }
}
