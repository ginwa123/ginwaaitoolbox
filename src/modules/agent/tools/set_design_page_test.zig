//! Tests for `set_design_page` LLM tool.
//!
//! Two layers:
//!   1. Static source-check tests (no DB) — verify the tool's
//!      definition has the workspace_id-aware description, the right
//!      fields, and the tool is wired into tool_registry.zig + root.zig.
//!   2. Behavioral tests — verify `executeSetDesignPageToString` against
//!      an in-memory SQLite DB with the v6 schema (workspace_items +
//!      design_pages + design_page_elements).
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md (Chunk 4)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const set_design_page = @import("set_design_page.zig");
const text_normalize = nalarcore.helpers.text_normalize;
const design_model = @import("../../../ai_workflow/tui/design_model.zig");

const TOOL_PATH = "src/modules/agent/tools/set_design_page.zig";
const TOOL_REGISTRY_PATH = "src/ai_workflow/tui/agentic_loop/tool_registry.zig";
/// The exec function was migrated from `tool_registry.zig` to
/// `src/ai_workflow/tui/agentic_loop/tools_exec_set_design_page.zig`.
const TOOL_EXEC_PATH = "src/ai_workflow/tui/agentic_loop/tools_exec_set_design_page.zig";
/// The comptime tool list moved out of `tool_registry.zig` into
/// `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` (which
/// `agentic_loop.tools.all_agent_tools` re-exports as `equips`).
/// Each entry in that comptime `tools_list` array uses the
/// trailing-comma format (`.tool_name,`) that this test grep matches.
const TOOLS_EQUIPPED_PATH = "src/ai_workflow/tui/agentic_loop/tools_equipped.zig";
const ROOT_PATH = "src/root.zig";

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match even when
/// the file was checked out on Windows with autocrlf=true (see
/// `.gitattributes` + `src/helpers/text_normalize.zig` for context).
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

test "set_design_page tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"set_design_page\"")) {
        std.debug.print("!! set_design_page.zig does not define the tool with .name = \"set_design_page\" !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "set_design_page description mentions Workspace Context for ids" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The description must tell the LLM that item_id comes from the
    // active chat's workspace context — otherwise the LLM will
    // hallucinate ids or fail to call the tool.
    if (!contains(source, "Workspace Context")) {
        std.debug.print("!! set_design_page description does not mention the Workspace Context !!\n", .{});
        return error.WorkspaceContextHintMissing;
    }
}

test "set_design_page description explains WHEN to use the tool" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "Use this tool to")) {
        std.debug.print("!! set_design_page description does not include a 'Use this tool to' signal !!\n", .{});
        return error.WhenToUseMissing;
    }
}

test "set_design_page input struct has item_id + page_name fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "item_id: []const u8")) {
        std.debug.print("!! SetDesignPageInput is missing the 'item_id' field !!\n", .{});
        return error.ItemIdFieldMissing;
    }
    if (!contains(source, "page_name: []const u8")) {
        std.debug.print("!! SetDesignPageInput is missing the 'page_name' field !!\n", .{});
        return error.PageNameFieldMissing;
    }
}

test "set_design_page input supports optional width/height" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "width: ?i64")) {
        std.debug.print("!! SetDesignPageInput is missing the 'width: ?i64' field !!\n", .{});
        return error.WidthFieldMissing;
    }
    if (!contains(source, "height: ?i64")) {
        std.debug.print("!! SetDesignPageInput is missing the 'height: ?i64' field !!\n", .{});
        return error.HeightFieldMissing;
    }
}

test "set_design_page description mentions idempotent behavior" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The description must mention idempotency — the v6 dual-semantics
    // design (create + list) requires the LLM to understand that
    // re-issuing the call doesn't break.
    if (!contains(source, "idempotent")) {
        std.debug.print("!! set_design_page description does not mention 'idempotent' behavior !!\n", .{});
        return error.IdempotentHintMissing;
    }
}

// ─── Static wiring tests ─────────────────────────────────────────────────

test "tool_registry.zig imports set_design_page module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    if (!contains(source, "set_design_page_mod")) {
        std.debug.print("!! tool_registry.zig does not import set_design_page_mod !!\n", .{});
        return error.SetDesignPageModImportMissing;
    }
    if (!contains(source, "set_design_page_tool")) {
        std.debug.print("!! tool_registry.zig does not bind set_design_page_tool !!\n", .{});
        return error.SetDesignPageToolBindingMissing;
    }
}

test "agentic_loop defines execSetDesignPage" {
    // After the migration, the exec function lives in
    // `tools_exec_set_design_page.zig` (re-exported via
    // `agentic_loop_mod.tools.execSetDesignPage`).
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_EXEC_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub fn execSetDesignPage(")) {
        std.debug.print("!! tools_exec_set_design_page.zig does not define pub fn execSetDesignPage !!\n", .{});
        return error.ExecSetDesignPageMissing;
    }
}

test "UNIFIED_TOOL_REGISTRY contains set_design_page entry" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"set_design_page\"")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY is missing the set_design_page entry !!\n", .{});
        return error.RegistryEntryMissing;
    }
    if (!contains(source, ".exec = agentic_loop_mod.tools.execSetDesignPage")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .exec = agentic_loop_mod.tools.execSetDesignPage !!\n", .{});
        return error.RegistryExecBindingMissing;
    }
    if (!contains(source, ".tool_def = set_design_page_mod.set_design_page_tool")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .tool_def binding !!\n", .{});
        return error.RegistryToolDefBindingMissing;
    }
}

test "allAgentTools comptime list contains set_design_page tool def" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, "set_design_page_mod.set_design_page_tool,")) {
        std.debug.print("!! tools_equipped.zig comptime list is missing set_design_page_mod.set_design_page_tool !!\n", .{});
        return error.AllAgentToolsEntryMissing;
    }
}

test "root.zig exposes set_design_page module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, ROOT_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub const set_design_page = @import(\"modules/agent/tools/set_design_page.zig\");")) {
        std.debug.print("!! root.zig does not expose set_design_page as a top-level module !!\n", .{});
        return error.NalarcoreExportMissing;
    }
}

// ─── XML serialization behavioral tests (no DB required) ────────────────

test "toXml on page with no elements produces <page .../>...</page>" {
    const alloc = testing.allocator;
    const page = design_model.DesignPage{
        .id = try alloc.dupe(u8, "page_abc"),
        .workspace_item_id = try alloc.dupe(u8, "item_test"),
        .name = try alloc.dupe(u8, "Login"),
        .workspace_item_task_id = try alloc.dupe(u8, "task_test"),
        .width = 1440,
        .height = 1024,
        .position = 0,
        .created_at = try alloc.dupe(u8, ""),
        .updated_at = try alloc.dupe(u8, ""),
    };
    defer {
        alloc.free(page.id);
        alloc.free(page.workspace_item_id);
        alloc.free(page.name);
        alloc.free(page.workspace_item_task_id);
        alloc.free(page.created_at);
        alloc.free(page.updated_at);
    }
    const xml = try set_design_page.toXml(alloc, page, &.{});
    defer alloc.free(xml);
    try testing.expect(std.mem.startsWith(u8, xml, "<page"));
    try testing.expect(std.mem.endsWith(u8, xml, "</page>"));
    try testing.expect(contains(xml, "id=\"page_abc\""));
    try testing.expect(contains(xml, "name=\"Login\""));
    try testing.expect(contains(xml, "width=\"1440\""));
    try testing.expect(contains(xml, "height=\"1024\""));
    try testing.expect(contains(xml, "position=\"0\""));
    // No <element> blocks for an empty elements slice.
    try testing.expect(!contains(xml, "<element"));
}

test "toXml renders element attributes with v6 fields" {
    const alloc = testing.allocator;
    const page = design_model.DesignPage{
        .id = try alloc.dupe(u8, "page_abc"),
        .workspace_item_id = try alloc.dupe(u8, "item_test"),
        .name = try alloc.dupe(u8, "Login"),
        .workspace_item_task_id = try alloc.dupe(u8, "task_test"),
        .width = 1440,
        .height = 1024,
        .position = 0,
        .created_at = try alloc.dupe(u8, ""),
        .updated_at = try alloc.dupe(u8, ""),
    };
    defer {
        alloc.free(page.id);
        alloc.free(page.workspace_item_id);
        alloc.free(page.name);
        alloc.free(page.workspace_item_task_id);
        alloc.free(page.created_at);
        alloc.free(page.updated_at);
    }
    const elem = design_model.DesignElement{
        .id = try alloc.dupe(u8, "elem_xyz"),
        .page_id = try alloc.dupe(u8, "page_abc"),
        .name = try alloc.dupe(u8, "login-card"),
        .file_path = try alloc.dupe(u8, "/tmp/.nalar/design/Login/login-card.html"),
        .x = 100,
        .y = 200,
        .width = 400,
        .height = 300,
        .z_index = 0,
        .position = 0,
        .elem_type = try alloc.dupe(u8, "rectangle"),
        .rotation = 0.0,
        .fill = try alloc.dupe(u8, "#ffffff"),
        .stroke = try alloc.dupe(u8, ""),
        .stroke_width = 0,
        .corner_radius = 0,
        .opacity = 1.0,
        .text_content = try alloc.dupe(u8, ""),
        .text_style = try alloc.dupe(u8, ""),
        .image_url = try alloc.dupe(u8, ""),
        .parent_id = try alloc.dupe(u8, ""),
        .created_at = try alloc.dupe(u8, ""),
        .updated_at = try alloc.dupe(u8, ""),
    };
    defer design_model.freeElement(alloc, elem);
    const elements = [_]design_model.DesignElement{elem};
    const xml = try set_design_page.toXml(alloc, page, &elements);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<element"));
    try testing.expect(contains(xml, "id=\"elem_xyz\""));
    try testing.expect(contains(xml, "name=\"login-card\""));
    try testing.expect(contains(xml, "type=\"rectangle\""));
    try testing.expect(contains(xml, "x=\"100\""));
    try testing.expect(contains(xml, "y=\"200\""));
    try testing.expect(contains(xml, "width=\"400\""));
    try testing.expect(contains(xml, "height=\"300\""));
    try testing.expect(contains(xml, "fill=\"#ffffff\""));
    try testing.expect(contains(xml, "file_path="));
    try testing.expect(contains(xml, "parent_id=\"\""));
}

test "toXml renders parent_id for a nested element" {
    const alloc = testing.allocator;
    const page = design_model.DesignPage{
        .id = try alloc.dupe(u8, "page_abc"),
        .workspace_item_id = try alloc.dupe(u8, "item_test"),
        .name = try alloc.dupe(u8, "Login"),
        .workspace_item_task_id = try alloc.dupe(u8, "task_test"),
        .width = 1440,
        .height = 1024,
        .position = 0,
        .created_at = try alloc.dupe(u8, ""),
        .updated_at = try alloc.dupe(u8, ""),
    };
    defer {
        alloc.free(page.id);
        alloc.free(page.workspace_item_id);
        alloc.free(page.name);
        alloc.free(page.workspace_item_task_id);
        alloc.free(page.created_at);
        alloc.free(page.updated_at);
    }
    // A child element parented under elem_parent_1.
    const elem = design_model.DesignElement{
        .id = try alloc.dupe(u8, "elem_child_1"),
        .page_id = try alloc.dupe(u8, "page_abc"),
        .name = try alloc.dupe(u8, "login-button"),
        .file_path = try alloc.dupe(u8, "/tmp/.nalar/design/Login/login-button.html"),
        .x = 10,
        .y = 20,
        .width = 80,
        .height = 30,
        .z_index = 0,
        .position = 1,
        .elem_type = try alloc.dupe(u8, "rectangle"),
        .rotation = 0.0,
        .fill = try alloc.dupe(u8, "#000000"),
        .stroke = try alloc.dupe(u8, ""),
        .stroke_width = 0,
        .corner_radius = 0,
        .opacity = 1.0,
        .text_content = try alloc.dupe(u8, ""),
        .text_style = try alloc.dupe(u8, ""),
        .image_url = try alloc.dupe(u8, ""),
        .parent_id = try alloc.dupe(u8, "elem_parent_1"),
        .created_at = try alloc.dupe(u8, ""),
        .updated_at = try alloc.dupe(u8, ""),
    };
    defer design_model.freeElement(alloc, elem);
    const elements = [_]design_model.DesignElement{elem};
    const xml = try set_design_page.toXml(alloc, page, &elements);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "parent_id=\"elem_parent_1\""));
}

test "errorXml on missing field returns <page><error>...</error></page>" {
    const alloc = testing.allocator;
    const xml = try set_design_page.errorXml(alloc, "item_id is required");
    defer alloc.free(xml);
    try testing.expect(std.mem.startsWith(u8, xml, "<page>"));
    try testing.expect(std.mem.endsWith(u8, xml, "</page>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "item_id is required"));
}

// ─── DB integration behavioral tests (in-memory SQLite) ────────────────

/// Set up an in-memory SQLite with the v6 design schema (workspace_items
/// + design_pages + design_page_elements with the 11 Migration 057
/// columns). Creates one workspace item with `path='/tmp'` so
/// `setDesignPage` doesn't return `ItemPathMissing`.
///
/// Returns the db + threaded as a value (not a pointer) so the
/// caller's `var s = try setupDb();` can pass `&s.db` to
/// non-const-`*SqliteBackend` parameters.
fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded, item_id: []u8, item_path: []u8 } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspace_items.
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

    // design_pages (v6 schema).
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

    // design_page_elements (v6 schema).
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

    // Real tempdir for path (setDesignPage needs a non-empty path so
    // its `ItemPathMissing` early-return doesn't fire).
    var tmp = testing.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing.io, &tmpdir_buf);
    const tmpdir_path = try alloc.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_str = "item_design_1";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path) " ++
        "VALUES (?, 'ws_test', 'design', 'Test Design', ?)",
        &.{ item_id_str, tmpdir_path });

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = try alloc.dupe(u8, item_id_str),
        .item_path = tmpdir_path,
    };
}

test "executeSetDesignPageToString creates a page when none exists" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = s.item_id,
        .page_name = "Login",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);

    try testing.expect(std.mem.startsWith(u8, xml, "<page"));
    try testing.expect(std.mem.endsWith(u8, xml, "</page>"));
    try testing.expect(contains(xml, "id=\"page_"));
    try testing.expect(contains(xml, "name=\"Login\""));
    try testing.expect(contains(xml, "width=\"1440\""));
    try testing.expect(contains(xml, "height=\"1024\""));
    try testing.expect(!contains(xml, "<error>"));
}

test "executeSetDesignPageToString is idempotent on second call with same name" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = s.item_id,
        .page_name = "Login",
        .width = 800,
        .height = 600,
    };
    const xml1 = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml1);
    try testing.expect(contains(xml1, "width=\"800\""));
    try testing.expect(contains(xml1, "height=\"600\""));

    // Second call with same name → must reuse the same page id (idempotent
    // upsert via setDesignPage), and pick up the new dimensions.
    const input2 = set_design_page.SetDesignPageInput{
        .item_id = s.item_id,
        .page_name = "Login",
        .width = 1920,
        .height = 1080,
    };
    const xml2 = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input2);
    defer alloc.free(xml2);
    try testing.expect(contains(xml2, "width=\"1920\""));
    try testing.expect(contains(xml2, "height=\"1080\""));

    // The page id should be the same between the two calls — extract
    // the id="..." value and compare.
    const id_start1 = (std.mem.indexOf(u8, xml1, "id=\"") orelse 0) + 4;
    const id_end1 = std.mem.indexOf(u8, xml1[id_start1..], "\"") orelse xml1.len;
    const id1 = xml1[id_start1..][0..id_end1];

    const id_start2 = (std.mem.indexOf(u8, xml2, "id=\"") orelse 0) + 4;
    const id_end2 = std.mem.indexOf(u8, xml2[id_start2..], "\"") orelse xml2.len;
    const id2 = xml2[id_start2..][0..id_end2];

    try testing.expect(std.mem.eql(u8, id1, id2));
}

test "executeSetDesignPageToString returns error XML when item_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = "",
        .page_name = "Login",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "item_id"));
}

test "executeSetDesignPageToString returns error XML when item_id looks like a task_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = "task_1782442569739",
        .page_name = "Login",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "task_"));
    // Should mention the correct id source so the LLM self-corrects.
    try testing.expect(contains(xml, "item_"));
}

test "executeSetDesignPageToString returns error XML when item_id looks like a page_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = "page_1782442554112",
        .page_name = "Login",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "page_"));
}

test "executeSetDesignPageToString returns error XML when item_id looks like an elem_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = "elem_1782442554112",
        .page_name = "Login",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "elem_"));
}

test "executeSetDesignPageToString returns error XML when item_id looks like a workspace_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = "ws_test",
        .page_name = "Login",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
}

test "executeSetDesignPageToString returns error XML when item_id has unrecognized prefix" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = "foo_123",
        .page_name = "Login",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "unrecognized"));
}

test "executeSetDesignPageToString returns error XML when page_name is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = s.item_id,
        .page_name = "",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "page_name"));
}

test "executeSetDesignPageToString returns error XML when page_name contains '/'" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = s.item_id,
        .page_name = "Login/Foo",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "/"));
}

test "executeSetDesignPageToString returns ItemPathMissing error when item has no path" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    // Insert a second design item WITHOUT a path.
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path) " ++
        "VALUES ('item_no_path', 'ws_test', 'design', 'No path', '')",
        &.{});

    const input = set_design_page.SetDesignPageInput{
        .item_id = "item_no_path",
        .page_name = "Login",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "no path"));
    try testing.expect(contains(xml, "AddDesignDialog"));
}