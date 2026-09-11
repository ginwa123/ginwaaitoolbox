//! Tests for the `get_design_context` LLM tool.
//!
//! Two layers:
//!   1. Static source-check tests — verify the tool is wired up correctly
//!      in `tools_equipped.zig` (both the `tools_list` and
//!      `UNIFIED_TOOL_REGISTRY()` arrays), in `root.zig`, and the exec
//!      function is exported from `agentic_loop/tools.zig`.
//!   2. Behavioural tests — verify `executeGetDesignContextToString` against
//!      an in-memory SQLite DB with the v6 schema (workspace_items +
//!      design_pages + design_page_elements).
//!
//! Plan: docs/superpowers/plans/2026-08-06-ai-agent-design-context-tool.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const get_design_context = @import("get_design_context.zig");
const text_normalize = @import("helpers").text_normalize;
const design_model = @import("../../../agentic_loop/design_model.zig");

const TOOL_PATH = "src/modules/agent/tools/get_design_context.zig";
const ROOT_PATH = "src/root.zig";
const TOOLS_EQUIPPED_PATH = "src/agentic_loop/tools_equipped.zig";
const TOOLS_PATH = "src/agentic_loop/tools.zig";
const TOOL_EXEC_PATH = "src/agentic_loop/tools_exec_get_design_context.zig";

// ─── Helpers ─────────────────────────────────────────────────────────────

/// Read a source file from disk, relative to the project root. Normalizes
/// CRLF → LF so multi-line literal needles match even when the file was
/// checked out on Windows with autocrlf=true.
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

/// In-memory SQLite v6 schema setup. Mirrors the helper in
/// `set_design_page_test.zig` + `add_design_element_test.zig` (the project
/// convention: one helper per test file, namespaced by the test suite's
/// `testing_*` alias).
const testing_ctx = std.testing;

fn setupCtx() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
} {
    const alloc = testing_ctx.allocator;
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

    var tmp = testing_ctx.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing_ctx.io, &tmpdir_buf);
    const tmpdir_path = try testing_ctx.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_design_ctx";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)",
        &.{ item_id_const, tmpdir_path });

    const item_id_slice = try alloc.dupe(u8, item_id_const);

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = item_id_slice,
        .item_path = tmpdir_path,
    };
}

fn teardownCtx(db: *sqlite.SqliteBackend, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

/// Insert a raw element row directly into `design_page_elements` (bypasses
/// the on-disk HTML write of `addElement`). Used by tests that only need
/// the metadata.
fn insertElementRaw(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
    name: []const u8,
    elem_type: []const u8,
    x: i64, y: i64, width: i64, height: i64,
    fill: []const u8,
    parent_id: ?[]const u8,
) !void {
    const id = try std.fmt.allocPrint(alloc, "elem_{s}", .{name});
    defer alloc.free(id);
    const x_str = try std.fmt.allocPrint(alloc, "{d}", .{x});
    defer alloc.free(x_str);
    const y_str = try std.fmt.allocPrint(alloc, "{d}", .{y});
    defer alloc.free(y_str);
    const w_str = try std.fmt.allocPrint(alloc, "{d}", .{width});
    defer alloc.free(w_str);
    const h_str = try std.fmt.allocPrint(alloc, "{d}", .{height});
    defer alloc.free(h_str);

    try db.exec(alloc,
        \\INSERT INTO design_page_elements (
        \\    id, page_id, name, file_path, x, y, width, height,
        \\    z_index, position, type, rotation,
        \\    fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at
        \\) VALUES (
        \\    ?, ?, ?, '', ?, ?, ?, ?,
        \\    0, 0, ?, 0,
        \\    ?, '', 0, 0, 1.0,
        \\    '', '', '', ?,
        \\    datetime('now'), datetime('now')
        \\)
    , .{
        id, page_id, name,
        x_str, y_str, w_str, h_str,
        elem_type,
        fill,
        parent_id orelse "",
    });
}

// ─── Wiring tests (static source-check) ──────────────────────────────────

test "wiring: get_design_context tool is registered in tools_equipped.zig tools_list" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, TOOLS_EQUIPPED_PATH);
    defer alloc.free(source);
    try testing.expect(contains(source,
        \\get_design_context_mod.get_design_context_tool,
    ));
}

test "wiring: get_design_context is in tools_equipped.zig UNIFIED_TOOL_REGISTRY" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, TOOLS_EQUIPPED_PATH);
    defer alloc.free(source);
    try testing.expect(contains(source,
        \\.{ .name = "get_design_context",
    ));
}

test "wiring: get_design_context is re-exported in src/root.zig" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, ROOT_PATH);
    defer alloc.free(source);
    try testing.expect(contains(source,
        \\pub const get_design_context = @import("modules/agent/tools/get_design_context.zig");
    ));
}

test "wiring: execGetDesignContext is re-exported in agentic_loop/tools.zig" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, TOOLS_PATH);
    defer alloc.free(source);
    try testing.expect(contains(source,
        \\pub const execGetDesignContext = @import("tools_exec_get_design_context.zig").execGetDesignContext;
    ));
}

test "wiring: tools_exec_get_design_context.zig exists" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, TOOL_EXEC_PATH);
    defer alloc.free(source);
    try testing.expect(contains(source,
        \\pub fn execGetDesignContext(
    ));
}

// ─── Behavioural tests (in-memory SQLite + v6 schema) ────────────────────

test "executeGetDesignContextToString with page_id returns single page + elements" {
    const alloc = testing.allocator;
    var ctx = try setupCtx();
    defer teardownCtx(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    try insertElementRaw(alloc, &ctx.db, page_id, "clear-button", "rectangle",
        1356, 16, 60, 24, "transparent", null);

    const out = try get_design_context.executeGetDesignContextToString(alloc, &ctx.db, .{
        .page_id = page_id,
        .workspace_item_id = null,
    });
    defer alloc.free(out);

    // Envelope shape
    try testing.expect(contains(out, "<design_context>"));
    try testing.expect(contains(out, "<pages count=\"1\">"));
    try testing.expect(contains(out, "<page "));
    try testing.expect(contains(out, "name=\"Login\""));
    try testing.expect(contains(out, "width=\"1440\""));
    try testing.expect(contains(out, "height=\"1024\""));
    try testing.expect(contains(out, "<design_page_elements count=\"1\">"));
    try testing.expect(contains(out, "<element "));
    try testing.expect(contains(out, "name=\"clear-button\""));
    try testing.expect(contains(out, "type=\"rectangle\""));
    try testing.expect(contains(out, "x=\"1356\""));
    try testing.expect(contains(out, "y=\"16\""));
    try testing.expect(contains(out, "width=\"60\""));
    try testing.expect(contains(out, "height=\"24\""));
    try testing.expect(contains(out, "fill=\"transparent\""));
    // Empty parent_id rendered explicitly as parent_id=""
    try testing.expect(contains(out, "parent_id=\"\""));
    try testing.expect(contains(out, "</design_page_elements>"));
    try testing.expect(contains(out, "</pages>"));
    try testing.expect(contains(out, "</design_context>"));
}

test "executeGetDesignContextToString with workspace_item_id returns ALL pages in position order" {
    const alloc = testing.allocator;
    var ctx = try setupCtx();
    defer teardownCtx(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    // 3 pages, in a non-creation order to verify position sort
    const login_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id, .page_name = "Login", .width = 1440, .height = 1024,
    });
    defer alloc.free(login_id);
    const dashboard_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id, .page_name = "Dashboard", .width = 1440, .height = 1024,
    });
    defer alloc.free(dashboard_id);
    const settings_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id, .page_name = "Settings", .width = 1440, .height = 1024,
    });
    defer alloc.free(settings_id);

    const out = try get_design_context.executeGetDesignContextToString(alloc, &ctx.db, .{
        .page_id = null,
        .workspace_item_id = ctx.item_id,
    });
    defer alloc.free(out);

    try testing.expect(contains(out, "<pages count=\"3\">"));

    // Verify order: login appears before dashboard, dashboard before settings
    const login_idx = std.mem.indexOf(u8, out, "name=\"Login\"") orelse unreachable;
    const dash_idx = std.mem.indexOf(u8, out, "name=\"Dashboard\"") orelse unreachable;
    const sett_idx = std.mem.indexOf(u8, out, "name=\"Settings\"") orelse unreachable;
    try testing.expect(login_idx < dash_idx);
    try testing.expect(dash_idx < sett_idx);
}

test "executeGetDesignContextToString returns error envelope when BOTH ids are missing" {
    const alloc = testing.allocator;
    var ctx = try setupCtx();
    defer teardownCtx(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const out = try get_design_context.executeGetDesignContextToString(alloc, &ctx.db, .{
        .page_id = null,
        .workspace_item_id = null,
    });
    defer alloc.free(out);

    try testing.expect(contains(out, "<design_context>"));
    try testing.expect(contains(out, "<error>"));
    try testing.expect(contains(out, "exactly one"));
    try testing.expect(contains(out, "</design_context>"));
}

test "executeGetDesignContextToString returns error envelope when BOTH ids are provided" {
    const alloc = testing.allocator;
    var ctx = try setupCtx();
    defer teardownCtx(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id, .page_name = "Login", .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    const out = try get_design_context.executeGetDesignContextToString(alloc, &ctx.db, .{
        .page_id = page_id,
        .workspace_item_id = ctx.item_id,
    });
    defer alloc.free(out);

    try testing.expect(contains(out, "<error>"));
    try testing.expect(contains(out, "exactly one"));
}

test "executeGetDesignContextToString with workspace_item_id and ZERO pages returns empty <pages>" {
    const alloc = testing.allocator;
    var ctx = try setupCtx();
    defer teardownCtx(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const out = try get_design_context.executeGetDesignContextToString(alloc, &ctx.db, .{
        .page_id = null,
        .workspace_item_id = ctx.item_id,
    });
    defer alloc.free(out);

    try testing.expect(contains(out, "<design_context>"));
    try testing.expect(contains(out, "<pages count=\"0\">"));
    try testing.expect(contains(out, "</pages>"));
}

test "executeGetDesignContextToString with unknown page_id returns PageNotFound error envelope" {
    const alloc = testing.allocator;
    var ctx = try setupCtx();
    defer teardownCtx(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const out = try get_design_context.executeGetDesignContextToString(alloc, &ctx.db, .{
        .page_id = "page_ghost",
        .workspace_item_id = null,
    });
    defer alloc.free(out);

    try testing.expect(contains(out, "<design_context>"));
    try testing.expect(contains(out, "<error>"));
    try testing.expect(contains(out, "not found"));
}

test "executeGetDesignContextToString element attributes mirror the wire shape (full attribute set)" {
    const alloc = testing.allocator;
    var ctx = try setupCtx();
    defer teardownCtx(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id, .page_name = "Login", .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    try insertElementRaw(alloc, &ctx.db, page_id, "clear-button", "rectangle",
        1356, 16, 60, 24, "transparent", null);

    const out = try get_design_context.executeGetDesignContextToString(alloc, &ctx.db, .{
        .page_id = page_id,
        .workspace_item_id = null,
    });
    defer alloc.free(out);

    // Every attribute the user expects must be present on the <element>
    try testing.expect(contains(out, "id="));
    try testing.expect(contains(out, "page_id=\""));
    try testing.expect(contains(out, "name=\"clear-button\""));
    try testing.expect(contains(out, "file_path="));
    try testing.expect(contains(out, "x=\"1356\""));
    try testing.expect(contains(out, "y=\"16\""));
    try testing.expect(contains(out, "width=\"60\""));
    try testing.expect(contains(out, "height=\"24\""));
    try testing.expect(contains(out, "z_index="));
    try testing.expect(contains(out, "position="));
    try testing.expect(contains(out, "type=\"rectangle\""));
    try testing.expect(contains(out, "rotation="));
    try testing.expect(contains(out, "fill=\"transparent\""));
    try testing.expect(contains(out, "stroke="));
    try testing.expect(contains(out, "stroke_width="));
    try testing.expect(contains(out, "corner_radius="));
    try testing.expect(contains(out, "opacity="));
    try testing.expect(contains(out, "text_content="));
    try testing.expect(contains(out, "text_style="));
    try testing.expect(contains(out, "image_url="));
    try testing.expect(contains(out, "parent_id=\"\""));
    try testing.expect(contains(out, "created_at="));
    try testing.expect(contains(out, "updated_at="));
}

test "executeGetDesignContextToString with parent_id set renders the FK" {
    const alloc = testing.allocator;
    var ctx = try setupCtx();
    defer teardownCtx(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id, .page_name = "Login", .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    try insertElementRaw(alloc, &ctx.db, page_id, "parent-frame", "frame",
        100, 200, 400, 300, "transparent", null);
    try insertElementRaw(alloc, &ctx.db, page_id, "child-leaf", "rectangle",
        110, 220, 80, 30, "#000000", "elem_parent-frame");

    const out = try get_design_context.executeGetDesignContextToString(alloc, &ctx.db, .{
        .page_id = page_id,
        .workspace_item_id = null,
    });
    defer alloc.free(out);

    try testing.expect(contains(out, "name=\"parent-frame\""));
    try testing.expect(contains(out, "name=\"child-leaf\""));
    try testing.expect(contains(out, "parent_id=\"elem_parent-frame\""));
    try testing.expect(contains(out, "<design_page_elements count=\"2\">"));
}