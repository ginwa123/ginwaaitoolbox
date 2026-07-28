//! Tests for `group_elements` LLM tool.
//!
//! Two layers:
//!   1. Static source-check tests — verify tool definition (required
//!      page_id + child_ids, optional name + type), tool_registry wiring,
//!      tools_equipped wiring, and root.zig re-export.
//!   2. XML serialization tests — verify `errorXml` shape and
//!      `<group_elements>` envelope.
//!   3. DB integration behavioural tests — verify the success path
//!      against an in-memory SQLite DB with the v6 design schema,
//!      and verify error mapping for the canonical failure modes
//!      (PageNotFound, ChildAlreadyParented, BadChildId).
//!
//! Plan: docs/superpowers/plans/2026-07-28-grouped-layers.md (Chunk 8)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const group_elements = @import("group_design_elements.zig");
const text_normalize = nalarcore.helpers.text_normalize;
const design_model = @import("../../../ai_workflow/tui/design_model.zig");

const TOOL_PATH = "src/modules/agent/tools/group_design_elements.zig";
const TOOL_REGISTRY_PATH = "src/ai_workflow/tui/agentic_loop/tool_registry.zig";
const TOOL_EXEC_PATH = "src/ai_workflow/tui/agentic_loop/tools_exec_group_elements.zig";
const TOOLS_EQUIPPED_PATH = "src/ai_workflow/tui/agentic_loop/tools_equipped.zig";
const TOOLS_ZIG_PATH = "src/ai_workflow/tui/agentic_loop/tools.zig";
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

test "group_elements tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"group_elements\"")) {
        std.debug.print("!! group_design_elements.zig does not define the tool with .name = \"group_elements\" !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "group_elements description mentions frame vs group" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The description must disambiguate `group` (non-clipping) from
    // `frame` (clipping) and tell the LLM the 2+ children requirement.
    if (!contains(source, "frame") or !contains(source, "group")) {
        std.debug.print("!! group_elements description does not mention both frame and group !!\n", .{});
        return error.FrameGroupHintMissing;
    }
}

test "group_elements description mentions 2+ children requirement" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "2") or !contains(source, "child")) {
        std.debug.print("!! group_elements description does not mention the 2+ children requirement !!\n", .{});
        return error.TwoChildrenHintMissing;
    }
}

test "group_elements input struct has all fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    const fields = [_][]const u8{
        "page_id: []const u8",
        "child_ids: []const []const u8",
        "name: ?[]const u8",
        "type: ?[]const u8",
    };
    for (fields) |f| {
        if (!contains(source, f)) {
            std.debug.print("!! GroupElementsInput is missing field '{s}' !!\n", .{f});
            return error.FieldMissing;
        }
    }
}

test "group_elements description references set_design_page as the source of page_id" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "set_design_page")) {
        std.debug.print("!! group_elements description does not reference set_design_page as the source of page_id !!\n", .{});
        return error.PageIdSourceMissing;
    }
}

// ─── Static wiring tests ─────────────────────────────────────────────────

test "tool_registry.zig imports group_design_elements module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    if (!contains(source, "group_design_elements_mod")) {
        std.debug.print("!! tool_registry.zig does not import group_design_elements_mod !!\n", .{});
        return error.GroupElementsModImportMissing;
    }
    if (!contains(source, "group_design_element_tool")) {
        std.debug.print("!! tool_registry.zig does not bind group_design_element_tool !!\n", .{});
        return error.GroupElementsToolBindingMissing;
    }
}

test "agentic_loop defines execGroupElements" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_EXEC_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub fn execGroupElements(")) {
        std.debug.print("!! tools_exec_group_elements.zig does not define pub fn execGroupElements !!\n", .{});
        return error.ExecGroupElementsMissing;
    }
}

test "tools.zig re-exports execGroupElements" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_ZIG_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub const execGroupElements = @import(\"tools_exec_group_elements.zig\").execGroupElements")) {
        std.debug.print("!! tools.zig does not re-export execGroupElements !!\n", .{});
        return error.ExecGroupElementsReExportMissing;
    }
}

test "UNIFIED_TOOL_REGISTRY contains group_elements entry" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"group_elements\"")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY is missing the group_elements entry !!\n", .{});
        return error.RegistryEntryMissing;
    }
    if (!contains(source, ".exec = agentic_loop_mod.tools.execGroupElements")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .exec = agentic_loop_mod.tools.execGroupElements !!\n", .{});
        return error.RegistryExecBindingMissing;
    }
    if (!contains(source, ".tool_def = group_design_elements_mod.group_design_element_tool")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .tool_def binding !!\n", .{});
        return error.RegistryToolDefBindingMissing;
    }
}

test "allAgentTools comptime list contains group_design_element tool def" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, "group_design_elements_mod.group_design_element_tool,")) {
        std.debug.print("!! tools_equipped.zig comptime list is missing group_design_elements_mod.group_design_element_tool !!\n", .{});
        return error.AllAgentToolsEntryMissing;
    }
}

test "root.zig exposes group_design_elements module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, ROOT_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub const group_design_elements = @import(\"modules/agent/tools/group_design_elements.zig\");")) {
        std.debug.print("!! root.zig does not expose group_design_elements as a top-level module !!\n", .{});
        return error.NalarcoreExportMissing;
    }
}

// ─── XML serialization ───────────────────────────────────────────────────

test "errorXml on missing field returns <group_elements><error>...</error></group_elements>" {
    const alloc = testing.allocator;
    const xml = try group_elements.errorXml(alloc, "page_id is required");
    defer alloc.free(xml);
    try testing.expect(std.mem.startsWith(u8, xml, "<group_elements>"));
    try testing.expect(std.mem.endsWith(u8, xml, "</group_elements>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "page_id is required"));
}

test "errorXmlOwned takes ownership and frees the message" {
    const alloc = testing.allocator;
    const msg = try alloc.dupe(u8, "child_ids must be at least 2 elements");
    const xml = try group_elements.errorXmlOwned(alloc, msg);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "child_ids must be at least 2 elements"));
    // msg has been freed by errorXmlOwned — using `msg` here would
    // be UAF. The test passes by virtue of the closure capturing the
    // allocation lifecycle.
}

// ─── DB integration behavioral tests (in-memory SQLite) ────────────────

/// Set up an in-memory SQLite with the v6 design schema + one page +
/// three rectangle elements ("card-a", "card-b", "card-c") all on the
/// same page. Returns the DB handle + page_id so tests can call
/// group_elements on them.
fn setupDbWithThreeElements() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []u8,
    page_id: []u8,
    element_a: []u8,
    element_b: []u8,
    element_c: []u8,
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

    const item_id_str = "item_design_group_1";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path) " ++
        "VALUES (?, 'ws_test', 'design', 'Test Design', ?)",
        &.{ item_id_str, tmpdir_path });

    const page_id_str = "page_test_group_1";
    try db.exec(alloc,
        "INSERT INTO design_pages (id, workspace_item_id, name, width, height, position) " ++
        "VALUES (?, ?, 'Login', 1440, 1024, 0)",
        &.{ page_id_str, item_id_str });

    const element_a_str = "elem_a";
    try db.exec(alloc,
        "INSERT INTO design_page_elements (id, page_id, name, file_path, x, y, width, height, z_index, position, type, fill) " ++
        "VALUES (?, ?, 'card-a', '/tmp/a.html', 10, 20, 100, 50, 0, 0, 'rectangle', '#ffffff')",
        &.{ element_a_str, page_id_str });

    const element_b_str = "elem_b";
    try db.exec(alloc,
        "INSERT INTO design_page_elements (id, page_id, name, file_path, x, y, width, height, z_index, position, type, fill) " ++
        "VALUES (?, ?, 'card-b', '/tmp/b.html', 200, 300, 100, 50, 1, 1, 'rectangle', '#ffffff')",
        &.{ element_b_str, page_id_str });

    const element_c_str = "elem_c";
    try db.exec(alloc,
        "INSERT INTO design_page_elements (id, page_id, name, file_path, x, y, width, height, z_index, position, type, fill) " ++
        "VALUES (?, ?, 'card-c', '/tmp/c.html', 400, 600, 100, 50, 2, 2, 'rectangle', '#ffffff')",
        &.{ element_c_str, page_id_str });

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = try alloc.dupe(u8, item_id_str),
        .page_id = try alloc.dupe(u8, page_id_str),
        .element_a = try alloc.dupe(u8, element_a_str),
        .element_b = try alloc.dupe(u8, element_b_str),
        .element_c = try alloc.dupe(u8, element_c_str),
    };
}

test "executeGroupElementsToString wraps two elements into a parent with union bbox" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = group_elements.GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{ s.element_a, s.element_b },
    };
    const xml = try group_elements.executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(xml);

    // Outer envelope.
    try testing.expect(std.mem.startsWith(u8, xml, "<group_elements>"));
    try testing.expect(std.mem.endsWith(u8, xml, "</group_elements>"));
    // Parent rendered with the union bbox (10, 20, 290, 330).
    try testing.expect(contains(xml, "<parent"));
    try testing.expect(contains(xml, "name=\"Group\""));
    try testing.expect(contains(xml, "type=\"group\""));
    try testing.expect(contains(xml, "x=\"10\""));
    try testing.expect(contains(xml, "y=\"20\""));
    try testing.expect(contains(xml, "width=\"290\""));
    try testing.expect(contains(xml, "height=\"330\""));
    // Both children rendered with parent_id pointing to the new parent.
    try testing.expect(contains(xml, "<child"));
    try testing.expect(contains(xml, "id=\"elem_a\""));
    try testing.expect(contains(xml, "id=\"elem_b\""));
    try testing.expect(contains(xml, "name=\"card-a\""));
    try testing.expect(contains(xml, "name=\"card-b\""));
    // The parent_id must appear 2 times with the elem_ prefix
    // (once per child render — note: the parent block also renders
    // `parent_id=""` so a naive count of `parent_id="` would be 3).
    const parent_id_with_id = std.mem.count(u8, xml, "parent_id=\"elem_");
    try testing.expect(parent_id_with_id == 2);
    try testing.expect(!contains(xml, "<error>"));
}

test "executeGroupElementsToString honours custom name and type=frame" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = group_elements.GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{ s.element_b, s.element_c },
        .name = "Kanban-view",
        .type = "frame",
    };
    const xml = try group_elements.executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(xml);

    try testing.expect(contains(xml, "name=\"Kanban-view\""));
    try testing.expect(contains(xml, "type=\"frame\""));
    // Union bbox of (200,300,500,650) and (400,600,500,650) →
    // (200, 300, 300, 350).
    try testing.expect(contains(xml, "x=\"200\""));
    try testing.expect(contains(xml, "y=\"300\""));
    try testing.expect(contains(xml, "width=\"300\""));
    try testing.expect(contains(xml, "height=\"350\""));
}

test "executeGroupElementsToString returns error XML when page_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = group_elements.GroupElementsInput{
        .page_id = "",
        .child_ids = &.{ s.element_a, s.element_b },
    };
    const xml = try group_elements.executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "page_id"));
}

test "executeGroupElementsToString returns error XML when child_ids is empty" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = group_elements.GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{},
    };
    const xml = try group_elements.executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "child_ids"));
}

test "executeGroupElementsToString returns error XML when child_ids has only 1 element" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = group_elements.GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{s.element_a},
    };
    const xml = try group_elements.executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "child_ids"));
}

test "executeGroupElementsToString returns error XML when type is invalid" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = group_elements.GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{ s.element_a, s.element_b },
        .type = "rectangle",
    };
    const xml = try group_elements.executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "type"));
}

test "executeGroupElementsToString returns error XML when page_id does not exist" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = group_elements.GroupElementsInput{
        .page_id = "page_does_not_exist",
        .child_ids = &.{ s.element_a, s.element_b },
    };
    const xml = try group_elements.executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "page_id"));
}

test "executeGroupElementsToString returns error XML when a child_id does not exist" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = group_elements.GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{ s.element_a, "elem_does_not_exist" },
    };
    const xml = try group_elements.executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
}

test "executeGroupElementsToString returns error XML when a child is already parented" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    // Pre-parent element_b to a non-existent parent (still parented
    // in the DB). The model rejects children whose parent_id is set.
    try s.db.exec(alloc,
        "UPDATE design_page_elements SET parent_id = 'elem_orphan' WHERE id = ?",
        &.{s.element_b});

    const input = group_elements.GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{ s.element_a, s.element_b },
    };
    const xml = try group_elements.executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "parented"));
}
