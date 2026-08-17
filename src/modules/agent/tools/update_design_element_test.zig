//! Tests for `update_element` LLM tool.
//!
//! Two layers:
//!   1. Static source-check tests — verify tool definition (required
//!      element_id, all other fields optional) and tool_registry wiring.
//!   2. Behavioral tests — verify `executeUpdateElementToString` against
//!      an in-memory SQLite DB with the v6 design schema.
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md (Chunk 4)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const update_element = @import("update_design_element.zig");
const text_normalize = nalarcore.helpers.text_normalize;
const design_model = @import("../../../ai_workflow/tui/agentic_loop/design_model.zig");

const TOOL_PATH = "src/modules/agent/tools/update_design_element.zig";
const TOOL_REGISTRY_PATH = "src/ai_workflow/tui/agentic_loop/tools_equipped.zig"; // legacy alias; tool_registry.zig was deleted 2026-08-06 — see plan
/// The exec function was migrated from `tool_registry.zig` to
/// `src/ai_workflow/tui/agentic_loop/tools_exec_update_element.zig`.
const TOOL_EXEC_PATH = "src/ai_workflow/tui/agentic_loop/tools_exec_update_element.zig";
/// The comptime tool list moved out of `tool_registry.zig` into
/// `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` (which
/// `agentic_loop.tools.all_agent_tools` re-exports as `equips`).
/// Each entry in that comptime `tools_list` array uses the
/// trailing-comma format (`.tool_name,`) that this test grep matches.
const TOOLS_EQUIPPED_PATH = "src/ai_workflow/tui/agentic_loop/tools_equipped.zig";
const ROOT_PATH = "src/root.zig";

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

// ─── Static source-check tests ────────────────────────────────────────────

test "update_element tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"update_element\"")) {
        std.debug.print("!! update_design_element.zig does not define the tool with .name = \"update_element\" !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "update_element description mentions element_id is the only required field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The description must make clear that ALL fields except
    // element_id are optional. The LLM needs to know it can update
    // just one field at a time.
    if (!contains(source, "OPTIONAL") and !contains(source, "optional")) {
        std.debug.print("!! update_element description does not mention optional fields !!\n", .{});
        return error.OptionalFieldsHintMissing;
    }
}

test "update_element description explains where element_id comes from" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "set_design_page")) {
        std.debug.print("!! update_element description does not reference set_design_page as the source of element_id !!\n", .{});
        return error.ElementIdSourceMissing;
    }
}

test "update_element input struct has all fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    const fields = [_][]const u8{
        "element_id: []const u8",
        "name: ?[]const u8",
        "type: ?[]const u8",
        "html: ?[]const u8",
        "x: ?i64",
        "y: ?i64",
        "width: ?i64",
        "height: ?i64",
        "rotation: ?f64",
        "fill: ?[]const u8",
        "stroke: ?[]const u8",
        "stroke_width: ?i64",
        "corner_radius: ?i64",
        "opacity: ?f64",
        "text_content: ?[]const u8",
        "text_style: ?[]const u8",
        "image_url: ?[]const u8",
    };
    for (fields) |f| {
        if (!contains(source, f)) {
            std.debug.print("!! UpdateElementInput is missing field '{s}' !!\n", .{f});
            return error.FieldMissing;
        }
    }
}

// ─── Static wiring tests ─────────────────────────────────────────────────

test "tools_equipped.zig imports update_design_element module" {
    // After deduplication of `UNIFIED_TOOL_REGISTRY` (2026-08-06), the
    // registry body lives in `tools_equipped.zig` and no longer lives
    // in `tool_registry.zig`. This test now reads the imports from
    // the canonical home.
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, "const update_design_element_mod = nalarcore.update_design_element;")) {
        std.debug.print("!! tools_equipped.zig does not bind update_design_element_mod = nalarcore.update_design_element !!\n", .{});
        return error.UpdateElementModBindingMissing;
    }
}

test "agentic_loop defines execUpdateElement" {
    // After the migration, the exec function lives in
    // `tools_exec_update_element.zig` (re-exported via
    // `agentic_loop_mod.tools.execUpdateElement`).
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_EXEC_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub fn execUpdateElement(")) {
        std.debug.print("!! tools_exec_update_element.zig does not define pub fn execUpdateElement !!\n", .{});
        return error.ExecUpdateElementMissing;
    }
}

test "UNIFIED_TOOL_REGISTRY contains update_element entry" {
    // The registry body moved from `tool_registry.zig` (deleted) to
    // `tools_equipped.zig` (canonical home) on 2026-08-06. The test
    // now reads from the canonical file. tools_equipped.zig imports
    // `tools = @import("tools.zig")` directly, so the `.exec` binding
    // is `tools.execUpdateElement` (NOT `agentic_loop_mod.tools.execUpdateElement`).
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"update_element\"")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY is missing the update_element entry !!\n", .{});
        return error.RegistryEntryMissing;
    }
    if (!contains(source, ".exec = tools.execUpdateElement")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .exec = tools.execUpdateElement !!\n", .{});
        return error.RegistryExecBindingMissing;
    }
    if (!contains(source, ".tool_def = update_design_element_mod.update_design_element_tool")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .tool_def binding !!\n", .{});
        return error.RegistryToolDefBindingMissing;
    }
}

test "allAgentTools comptime list contains update_design_element tool def" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, "update_design_element_mod.update_design_element_tool,")) {
        std.debug.print("!! tools_equipped.zig comptime list is missing update_design_element_mod.update_design_element_tool !!\n", .{});
        return error.AllAgentToolsEntryMissing;
    }
}

test "root.zig exposes update_design_element module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, ROOT_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub const update_design_element = @import(\"modules/agent/tools/update_design_element.zig\");")) {
        std.debug.print("!! root.zig does not expose update_design_element as a top-level module !!\n", .{});
        return error.NalarcoreExportMissing;
    }
}

// ─── XML serialization ───────────────────────────────────────────────────

test "errorXml on missing field returns <update_element><error>...</error></update_element>" {
    const alloc = testing.allocator;
    const xml = try update_element.errorXml(alloc, "element_id is required");
    defer alloc.free(xml);
    try testing.expect(std.mem.startsWith(u8, xml, "<update_element>"));
    try testing.expect(std.mem.endsWith(u8, xml, "</update_element>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "element_id is required"));
}

// ─── DB integration behavioral tests (in-memory SQLite) ────────────────

/// Set up an in-memory SQLite with the v6 design schema + one page +
/// one rectangle element named "card". Returns the DB handle + the
/// element_id so tests can call update_element on it.
fn setupDbWithElement() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []u8,
    page_id: []u8,
    element_id: []u8,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL, name TEXT, path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME, updated_at DATETIME)
    , &.{});

    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    description TEXT NOT NULL DEFAULT '')
    , &.{});

    try db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    workspace_item_task_id TEXT,
        \\    width INTEGER NOT NULL DEFAULT 1440,
        \\    height INTEGER NOT NULL DEFAULT 1024,
        \\    x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME,
        \\    updated_at DATETIME,
        \\    UNIQUE (workspace_item_id, name),
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE)
    , &.{});

    try db.exec(alloc,
        \\CREATE TABLE design_page_elements (
        \\    id TEXT PRIMARY KEY, page_id TEXT NOT NULL, name TEXT NOT NULL DEFAULT '',
        \\    file_path TEXT NOT NULL DEFAULT '',
        \\    x INTEGER NOT NULL DEFAULT 0, y INTEGER NOT NULL DEFAULT 0,
        \\    width INTEGER NOT NULL DEFAULT 375, height INTEGER NOT NULL DEFAULT 667,
        \\    z_index INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0,
        \\    type TEXT NOT NULL DEFAULT 'rectangle', rotation REAL NOT NULL DEFAULT 0,
        \\    fill TEXT NOT NULL DEFAULT '', stroke TEXT NOT NULL DEFAULT '',
        \\    stroke_width INTEGER NOT NULL DEFAULT 0,
        \\    corner_radius INTEGER NOT NULL DEFAULT 0, opacity REAL NOT NULL DEFAULT 1.0,
        \\    text_content TEXT NOT NULL DEFAULT '', text_style TEXT NOT NULL DEFAULT '',
        \\    image_url TEXT NOT NULL DEFAULT '', parent_id TEXT,
        \\    created_at DATETIME, updated_at DATETIME,
        \\    FOREIGN KEY (page_id) REFERENCES design_pages(id) ON DELETE CASCADE)
    , &.{});

    var tmp = testing.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing.io, &tmpdir_buf);
    const tmpdir_path: []const u8 = tmpdir_buf[0..tmpdir_len];

    const item_id_str = "item_design_1";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path) " ++
        "VALUES (?, 'ws_test', 'design', 'Test Design', ?)",
        &.{ item_id_str, tmpdir_path });

    const page_id_str = "page_test_1";
    try db.exec(alloc,
        "INSERT INTO design_pages (id, workspace_item_id, name, width, height, position) " ++
        "VALUES (?, ?, 'Login', 1440, 1024, 0)",
        &.{ page_id_str, item_id_str });

    const element_id_str = "elem_test_1";
    try db.exec(alloc,
        "INSERT INTO design_page_elements (id, page_id, name, file_path, x, y, width, height, type, fill) " ++
        "VALUES (?, ?, 'card', '/tmp/card.html', 100, 200, 300, 150, 'rectangle', '#ffffff')",
        &.{ element_id_str, page_id_str });

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = try alloc.dupe(u8, item_id_str),
        .page_id = try alloc.dupe(u8, page_id_str),
        .element_id = try alloc.dupe(u8, element_id_str),
    };
}

test "executeUpdateElementToString updates x and y only" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = s.element_id,
        .x = 250,
        .y = 350,
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);

    try testing.expect(std.mem.startsWith(u8, xml, "<element"));
    try testing.expect(contains(xml, "id=\"elem_test_1\""));
    try testing.expect(contains(xml, "x=\"250\""));
    try testing.expect(contains(xml, "y=\"350\""));
    // Other fields stay unchanged.
    try testing.expect(contains(xml, "width=\"300\""));
    try testing.expect(contains(xml, "height=\"150\""));
    try testing.expect(contains(xml, "name=\"card\""));
    try testing.expect(contains(xml, "type=\"rectangle\""));
    try testing.expect(contains(xml, "fill=\"#ffffff\""));
    try testing.expect(!contains(xml, "<error>"));
}

test "executeUpdateElementToString updates fill" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = s.element_id,
        .fill = "#22c55e",
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);

    try testing.expect(contains(xml, "fill=\"#22c55e\""));
}

test "executeUpdateElementToString updates name" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = s.element_id,
        .name = "primary-card",
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);

    try testing.expect(contains(xml, "name=\"primary-card\""));
}

test "executeUpdateElementToString updates type" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = s.element_id,
        .type = "ellipse",
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);

    try testing.expect(contains(xml, "type=\"ellipse\""));
}

test "executeUpdateElementToString returns error XML on invalid type" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = s.element_id,
        .type = "hexagon",
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "type"));
}

test "executeUpdateElementToString returns error XML when element_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = "",
        .x = 100,
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "element_id"));
}

test "executeUpdateElementToString returns error XML when element_id has wrong prefix" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = "page_1782442554112",
        .x = 100,
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "page_"));
}

test "executeUpdateElementToString returns ElementNotFound error when element_id doesn't exist" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = "elem_does_not_exist",
        .x = 100,
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "element_id"));
}

test "executeUpdateElementToString with only element_id is a no-op success" {
    // All fields null except element_id → updateElement short-circuits
    // (no SET clauses), but still succeeds and returns the current state.
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = s.element_id,
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(std.mem.startsWith(u8, xml, "<element"));
    try testing.expect(contains(xml, "id=\"elem_test_1\""));
    // The state is unchanged.
    try testing.expect(contains(xml, "x=\"100\""));
    try testing.expect(contains(xml, "y=\"200\""));
    try testing.expect(contains(xml, "width=\"300\""));
    try testing.expect(!contains(xml, "<error>"));
}

test "executeUpdateElementToString updates rotation and opacity" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = s.element_id,
        .rotation = 45.0,
        .opacity = 0.7,
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "rotation=\"45"));
    try testing.expect(contains(xml, "opacity=\"0.700000\""));
}