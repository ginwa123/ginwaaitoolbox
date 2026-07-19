//! Tests for `add_element` LLM tool.
//!
//! Two layers:
//!   1. Static source-check tests — verify tool definition (6 types,
//!      required fields, page_id hint) and tool_registry wiring.
//!   2. Behavioral tests — verify `executeAddElementToString` against
//!      an in-memory SQLite DB with the v6 design schema.
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md (Chunk 4)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const add_element = @import("add_design_element.zig");
const text_normalize = nalarcore.helpers.text_normalize;
const design_model = @import("../../../ai_workflow/tui/design_model.zig");

const TOOL_PATH = "src/modules/agent/tools/add_design_element.zig";
const TOOL_REGISTRY_PATH = "src/ai_workflow/tui/tool_registry.zig";
/// The comptime tool list moved out of `tool_registry.zig` into
/// `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` (which
/// `agentic_loop.tools.all_agent_tools` re-exports as `equips`).
/// Each entry in that comptime `tools_list` array uses the
/// trailing-comma format (`.tool_name,`) that this test grep matches.
const TOOLS_EQUIPPED_PATH = "src/ai_workflow/tui/agentic_loop/tools_equipped.zig";
const ROOT_PATH = "src/root.zig";

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match.
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

test "add_element tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"add_element\"")) {
        std.debug.print("!! add_design_element.zig does not define the tool with .name = \"add_element\" !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "add_element description mentions the 6 valid types" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // All 6 element types must appear in the description.
    const types = [_][]const u8{ "rectangle", "ellipse", "text", "image", "frame", "group" };
    for (types) |t| {
        if (!contains(source, t)) {
            std.debug.print("!! add_element description is missing type '{s}' !!\n", .{t});
            return error.ElementTypeMissing;
        }
    }
}

test "add_element description explains where page_id comes from" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The LLM must know that page_id comes from a previous
    // set_design_page call (NOT from Workspace Context).
    if (!contains(source, "set_design_page")) {
        std.debug.print("!! add_element description does not reference set_design_page as the source of page_id !!\n", .{});
        return error.PageIdSourceMissing;
    }
}

test "add_element input struct has all required fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    const required = [_][]const u8{
        "page_id: []const u8",
        "name: []const u8",
        "type: []const u8",
        "html: []const u8",
    };
    for (required) |r| {
        if (!contains(source, r)) {
            std.debug.print("!! AddElementInput is missing required field '{s}' !!\n", .{r});
            return error.RequiredFieldMissing;
        }
    }
}

test "add_element input supports optional geometry defaults" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    const optionals = [_][]const u8{
        "x: ?i64",
        "y: ?i64",
        "width: ?i64",
        "height: ?i64",
        "rotation: ?f64",
        "corner_radius: ?i64",
        "opacity: ?f64",
    };
    for (optionals) |o| {
        if (!contains(source, o)) {
            std.debug.print("!! AddElementInput is missing optional field '{s}' !!\n", .{o});
            return error.OptionalFieldMissing;
        }
    }
}

test "add_element tool has parent_id parameter" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // Source-grep: the JSON schema has a parent_id property AND the
    // input struct has a parent_id field. Both must be present.
    if (!contains(source, ".name = \"parent_id\"")) {
        std.debug.print("!! add_element JSON schema is missing the parent_id property !!\n", .{});
        return error.ParentIdSchemaPropMissing;
    }
    if (!contains(source, "parent_id: []const u8 = \"\"")) {
        std.debug.print("!! AddElementInput is missing the parent_id field (with empty-string default) !!\n", .{});
        return error.ParentIdFieldMissing;
    }
    // Description must mention the two valid parent types (frame/group).
    if (!contains(source, "frame")) {
        std.debug.print("!! add_element parent_id description does not reference 'frame' !!\n", .{});
        return error.ParentIdDescMissingFrame;
    }
    if (!contains(source, "group")) {
        std.debug.print("!! add_element parent_id description does not reference 'group' !!\n", .{});
        return error.ParentIdDescMissingGroup;
    }
}

// ─── Static wiring tests ─────────────────────────────────────────────────

test "tool_registry.zig imports add_design_element module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    if (!contains(source, "add_design_element_mod")) {
        std.debug.print("!! tool_registry.zig does not import add_design_element_mod !!\n", .{});
        return error.AddElementModImportMissing;
    }
    if (!contains(source, "add_design_element_tool")) {
        std.debug.print("!! tool_registry.zig does not bind add_design_element_tool !!\n", .{});
        return error.AddElementToolBindingMissing;
    }
}

test "tool_registry.zig defines execAddElement" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub fn execAddElement(")) {
        std.debug.print("!! tool_registry.zig does not define pub fn execAddElement !!\n", .{});
        return error.ExecAddElementMissing;
    }
}

test "UNIFIED_TOOL_REGISTRY contains add_element entry" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"add_element\"")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY is missing the add_element entry !!\n", .{});
        return error.RegistryEntryMissing;
    }
    if (!contains(source, ".exec = execAddElement")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .exec = execAddElement !!\n", .{});
        return error.RegistryExecBindingMissing;
    }
    if (!contains(source, ".tool_def = add_design_element_mod.add_design_element_tool")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .tool_def binding !!\n", .{});
        return error.RegistryToolDefBindingMissing;
    }
}

test "allAgentTools comptime list contains add_design_element tool def" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, "add_design_element_mod.add_design_element_tool,")) {
        std.debug.print("!! tools_equipped.zig comptime list is missing add_design_element_mod.add_design_element_tool !!\n", .{});
        return error.AllAgentToolsEntryMissing;
    }
}

test "root.zig exposes add_design_element module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, ROOT_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub const add_design_element = @import(\"modules/agent/tools/add_design_element.zig\");")) {
        std.debug.print("!! root.zig does not expose add_design_element as a top-level module !!\n", .{});
        return error.NalarcoreExportMissing;
    }
}

// ─── ElementType parser ───────────────────────────────────────────────────

test "parseElementType accepts all 6 valid types" {
    try testing.expect(add_element.parseElementType("rectangle") == .rectangle);
    try testing.expect(add_element.parseElementType("ellipse") == .ellipse);
    try testing.expect(add_element.parseElementType("text") == .text);
    try testing.expect(add_element.parseElementType("image") == .image);
    try testing.expect(add_element.parseElementType("frame") == .frame);
    try testing.expect(add_element.parseElementType("group") == .group);
}

test "parseElementType returns null for invalid types" {
    try testing.expect(add_element.parseElementType("box") == null);
    try testing.expect(add_element.parseElementType("circle") == null);
    try testing.expect(add_element.parseElementType("Rectangle") == null); // case-sensitive
    try testing.expect(add_element.parseElementType("") == null);
    try testing.expect(add_element.parseElementType("div") == null);
}

// ─── XML serialization ───────────────────────────────────────────────────

test "elementToXml renders element with all v6 attributes" {
    const alloc = testing.allocator;
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
        .rotation = 15.0,
        .fill = try alloc.dupe(u8, "#22c55e"),
        .stroke = try alloc.dupe(u8, ""),
        .stroke_width = 0,
        .corner_radius = 8,
        .opacity = 0.85,
        .text_content = try alloc.dupe(u8, ""),
        .text_style = try alloc.dupe(u8, ""),
        .image_url = try alloc.dupe(u8, ""),
        .created_at = try alloc.dupe(u8, "2026-07-08 10:00:00"),
        .updated_at = try alloc.dupe(u8, "2026-07-08 10:00:00"),
    };
    defer design_model.freeElement(alloc, elem);

    const xml = try add_element.elementToXml(alloc, elem);
    defer alloc.free(xml);

    try testing.expect(std.mem.startsWith(u8, xml, "<element"));
    try testing.expect(contains(xml, "id=\"elem_xyz\""));
    try testing.expect(contains(xml, "page_id=\"page_abc\""));
    try testing.expect(contains(xml, "name=\"login-card\""));
    try testing.expect(contains(xml, "type=\"rectangle\""));
    try testing.expect(contains(xml, "x=\"100\""));
    try testing.expect(contains(xml, "y=\"200\""));
    try testing.expect(contains(xml, "width=\"400\""));
    try testing.expect(contains(xml, "height=\"300\""));
    try testing.expect(contains(xml, "fill=\"#22c55e\""));
    try testing.expect(contains(xml, "rotation=\"15"));
    try testing.expect(contains(xml, "opacity=\"0.850000\""));
    try testing.expect(contains(xml, "corner_radius=\"8\""));
    try testing.expect(contains(xml, "file_path="));
    try testing.expect(contains(xml, "created_at="));
    try testing.expect(contains(xml, "updated_at="));
}

test "elementToXml omits empty optional fields" {
    const alloc = testing.allocator;
    const elem = design_model.DesignElement{
        .id = try alloc.dupe(u8, "elem_xyz"),
        .page_id = try alloc.dupe(u8, "page_abc"),
        .name = try alloc.dupe(u8, "card"),
        .file_path = try alloc.dupe(u8, "/tmp/card.html"),
        .x = 0,
        .y = 0,
        .width = 200,
        .height = 100,
        .z_index = 0,
        .position = 0,
        .elem_type = try alloc.dupe(u8, "rectangle"),
        .rotation = 0.0,
        .fill = try alloc.dupe(u8, ""),
        .stroke = try alloc.dupe(u8, ""),
        .stroke_width = 0,
        .corner_radius = 0,
        .opacity = 1.0,
        .text_content = try alloc.dupe(u8, ""),
        .text_style = try alloc.dupe(u8, ""),
        .image_url = try alloc.dupe(u8, ""),
        .created_at = try alloc.dupe(u8, ""),
        .updated_at = try alloc.dupe(u8, ""),
    };
    defer design_model.freeElement(alloc, elem);

    const xml = try add_element.elementToXml(alloc, elem);
    defer alloc.free(xml);

    // Empty strings should NOT appear as attributes (saves bytes).
    try testing.expect(!contains(xml, "fill=\""));
    try testing.expect(!contains(xml, "stroke=\""));
    try testing.expect(!contains(xml, "text_content=\""));
    try testing.expect(!contains(xml, "text_style=\""));
    try testing.expect(!contains(xml, "image_url=\""));
}

test "errorXml on bad page_id returns <add_element><error>...</error></add_element>" {
    const alloc = testing.allocator;
    const xml = try add_element.errorXml(alloc, "page_id is required");
    defer alloc.free(xml);
    try testing.expect(std.mem.startsWith(u8, xml, "<add_element>"));
    try testing.expect(std.mem.endsWith(u8, xml, "</add_element>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "page_id is required"));
}

// ─── DB integration behavioral tests (in-memory SQLite) ────────────────

fn setupDbWithPage() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []u8,
    page_id: []u8,
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
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
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
    // Use the stack buffer directly (don't dupe — `db.exec` copies
    // the slice internally). The `tmp` dir is reclaimed by the OS at
    // process exit (acceptable for test-suite use, per
    // design_model_test.zig's precedent).
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

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = try alloc.dupe(u8, item_id_str),
        .page_id = try alloc.dupe(u8, page_id_str),
    };
}

test "executeAddElementToString creates an element with default geometry" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = add_element.AddElementInput{
        .page_id = s.page_id,
        .name = "login-card",
        .type = "rectangle",
        .html = "<div>Hello</div>",
    };
    const xml = try add_element.executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(xml);

    try testing.expect(std.mem.startsWith(u8, xml, "<element"));
    try testing.expect(contains(xml, "name=\"login-card\""));
    try testing.expect(contains(xml, "type=\"rectangle\""));
    // Defaults: x=0, y=0, width=200, height=100
    try testing.expect(contains(xml, "x=\"0\""));
    try testing.expect(contains(xml, "y=\"0\""));
    try testing.expect(contains(xml, "width=\"200\""));
    try testing.expect(contains(xml, "height=\"100\""));
    try testing.expect(contains(xml, "opacity=\"1.000000\""));
    try testing.expect(contains(xml, "rotation=\"0"));
    try testing.expect(!contains(xml, "<error>"));
    try testing.expect(contains(xml, "file_path="));
}

test "executeAddElementToString respects explicit geometry" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = add_element.AddElementInput{
        .page_id = s.page_id,
        .name = "login-button",
        .type = "rectangle",
        .html = "<button>Sign in</button>",
        .x = 120,
        .y = 520,
        .width = 120,
        .height = 40,
        .fill = "#22c55e",
        .corner_radius = 8,
        .opacity = 0.95,
    };
    const xml = try add_element.executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(xml);

    try testing.expect(contains(xml, "name=\"login-button\""));
    try testing.expect(contains(xml, "x=\"120\""));
    try testing.expect(contains(xml, "y=\"520\""));
    try testing.expect(contains(xml, "width=\"120\""));
    try testing.expect(contains(xml, "height=\"40\""));
    try testing.expect(contains(xml, "fill=\"#22c55e\""));
    try testing.expect(contains(xml, "corner_radius=\"8\""));
    try testing.expect(contains(xml, "opacity=\"0.950000\""));
}

test "executeAddElementToString accepts all 6 element types" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const types = [_][]const u8{ "rectangle", "ellipse", "text", "image", "frame", "group" };
    for (types, 0..) |t, i| {
        const name = try std.fmt.allocPrint(alloc, "elem-{s}-{d}", .{ t, i });
        defer alloc.free(name);
        const input = add_element.AddElementInput{
            .page_id = s.page_id,
            .name = name,
            .type = t,
            .html = "<div></div>",
        };
        const xml = try add_element.executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
        defer alloc.free(xml);
        try testing.expect(std.mem.startsWith(u8, xml, "<element"));
        // Verify the type appears in the response (the wire format is
        // type="..." in the element's attribute list).
        var type_marker: [32]u8 = undefined;
        const marker = std.fmt.bufPrint(&type_marker, "type=\"{s}\"", .{t}) catch unreachable;
        try testing.expect(contains(xml, marker));
        try testing.expect(!contains(xml, "<error>"));
    }
}

test "executeAddElementToString returns error XML on invalid type" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = add_element.AddElementInput{
        .page_id = s.page_id,
        .name = "x",
        .type = "box", // not one of the 6 valid types
        .html = "<div></div>",
    };
    const xml = try add_element.executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "type"));
    try testing.expect(contains(xml, "rectangle"));
    try testing.expect(contains(xml, "ellipse"));
}

test "executeAddElementToString returns error XML when page_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = add_element.AddElementInput{
        .page_id = "",
        .name = "x",
        .type = "rectangle",
        .html = "<div></div>",
    };
    const xml = try add_element.executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "page_id"));
}

test "executeAddElementToString returns error XML when page_id has wrong prefix" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = add_element.AddElementInput{
        .page_id = "elem_1782442554112",
        .name = "x",
        .type = "rectangle",
        .html = "<div></div>",
    };
    const xml = try add_element.executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "elem_"));
}

test "executeAddElementToString returns error XML when name is empty" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = add_element.AddElementInput{
        .page_id = s.page_id,
        .name = "",
        .type = "rectangle",
        .html = "<div></div>",
    };
    const xml = try add_element.executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "name"));
}

test "executeAddElementToString returns error XML when name contains '/'" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = add_element.AddElementInput{
        .page_id = s.page_id,
        .name = "card/sub",
        .type = "rectangle",
        .html = "<div></div>",
    };
    const xml = try add_element.executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "/"));
}

test "executeAddElementToString returns error XML when html is empty" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = add_element.AddElementInput{
        .page_id = s.page_id,
        .name = "x",
        .type = "rectangle",
        .html = "",
    };
    const xml = try add_element.executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "html"));
}

test "executeAddElementToString returns PageNotFound error when page_id doesn't exist" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = add_element.AddElementInput{
        .page_id = "page_does_not_exist",
        .name = "x",
        .type = "rectangle",
        .html = "<div></div>",
    };
    const xml = try add_element.executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "page_id"));
}

// ─── parent_id (frame/group nesting) ─────────────────────────────────────

test "executeAddElementToString with parent_id nests the new element under a frame" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    // Step 1: create the parent (a frame).
    const frame_input = add_element.AddElementInput{
        .page_id = s.page_id,
        .name = "app-window",
        .type = "frame",
        .html = "<div>window</div>",
        .fill = "#ffffff",
        .width = 800,
        .height = 600,
    };
    const frame_xml = try add_element.executeAddElementToString(alloc, &s.db, s.threaded.io(), frame_input);
    defer alloc.free(frame_xml);
    try testing.expect(!contains(frame_xml, "<error>"));
    // Pull the frame id out of `id="..."` for use as parent_id below.
    const id_marker = "id=\"";
    const id_start = std.mem.indexOf(u8, frame_xml, id_marker).? + id_marker.len;
    const id_end = std.mem.indexOfPos(u8, frame_xml, id_start, "\"").?;
    const frame_id = try alloc.dupe(u8, frame_xml[id_start..id_end]);
    defer alloc.free(frame_id);

    // Step 2: create a child element with parent_id pointing at the frame.
    const child_input = add_element.AddElementInput{
        .page_id = s.page_id,
        .name = "callout",
        .type = "rectangle",
        .html = "<div>hi</div>",
        .fill = "#22c55e",
        .width = 100,
        .height = 100,
        .parent_id = frame_id,
    };
    const child_xml = try add_element.executeAddElementToString(alloc, &s.db, s.threaded.io(), child_input);
    defer alloc.free(child_xml);
    try testing.expect(!contains(child_xml, "<error>"));
    // The child XML response surfaces the round-tripped parent_id attr.
    try testing.expect(contains(child_xml, "parent_id="));
}

test "executeAddElementToString rejects parent_id pointing at a rectangle (not a container)" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    // Create a non-container (rectangle) to misuse as a parent.
    const rect_input = add_element.AddElementInput{
        .page_id = s.page_id,
        .name = "rect",
        .type = "rectangle",
        .html = "<div>r</div>",
        .fill = "#ffffff",
    };
    const rect_xml = try add_element.executeAddElementToString(alloc, &s.db, s.threaded.io(), rect_input);
    defer alloc.free(rect_xml);
    const id_marker = "id=\"";
    const id_start = std.mem.indexOf(u8, rect_xml, id_marker).? + id_marker.len;
    const id_end = std.mem.indexOfPos(u8, rect_xml, id_start, "\"").?;
    const rect_id = try alloc.dupe(u8, rect_xml[id_start..id_end]);
    defer alloc.free(rect_id);

    // Try to nest a child under the rectangle.
    const input = add_element.AddElementInput{
        .page_id = s.page_id,
        .name = "child",
        .type = "rectangle",
        .html = "<div>c</div>",
        .fill = "#22c55e",
        .parent_id = rect_id,
    };
    const xml = try add_element.executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "frame"));
    try testing.expect(contains(xml, "group"));
    try testing.expect(contains(xml, "parent_id"));
}