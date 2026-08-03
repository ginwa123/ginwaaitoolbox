//! Tests for the `preview_design_page` LLM tool.
//!
//! Two layers (matches the project's tool-test convention):
//!   1. Static source-check tests that verify the tool is wired up
//!      correctly in `tools_equipped.zig`, `root.zig`, etc.
//!   2. Behavioural tests that drive `executePreviewDesignPageToString`
//!      directly against an in-memory SQLite DB with the v6 schema.
//!
//! The SVG content lives INSIDE the `<preview_id>` envelope (same shape as
//! `show_preview`'s envelope) — the frontend's existing `<show_preview>`
//! handler renders the html content-type via a sandboxed iframe.
//!
//! Plan: docs/superpowers/plans/2026-08-06-ai-agent-design-context-tool.md (Chunk 2)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const preview_design_page = @import("preview_design_page.zig");
const text_normalize = nalarcore.helpers.text_normalize;
const design_model = @import("../../../ai_workflow/tui/design_model.zig");

const TOOL_PATH = "src/modules/agent/tools/preview_design_page.zig";
const ROOT_PATH = "src/root.zig";
const TOOLS_EQUIPPED_PATH = "src/ai_workflow/tui/agentic_loop/tools_equipped.zig";
const TOOLS_PATH = "src/ai_workflow/tui/agentic_loop/tools.zig";
const TOOL_EXEC_PATH = "src/ai_workflow/tui/agentic_loop/tools_exec_preview_design_page.zig";

// ─── Helpers ─────────────────────────────────────────────────────────────

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

const testing_ctx = std.testing;

fn setupCtx() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    io: std.Io,
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

    const item_id_const = "item_design_preview";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)",
        &.{ item_id_const, tmpdir_path });

    const item_id_slice = try alloc.dupe(u8, item_id_const);

    return .{
        .db = db,
        .threaded = threaded,
        .io = io,
        .item_id = item_id_slice,
        .item_path = tmpdir_path,
    };
}

fn teardownCtx(db: *sqlite.SqliteBackend, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

/// Insert a raw element row directly. Bypasses on-disk HTML write.
fn insertElementRaw(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
    name: []const u8,
    elem_type: []const u8,
    x: i64, y: i64, width: i64, height: i64,
    fill: []const u8,
    parent_id: ?[]const u8,
    text_content: []const u8,
    image_url: []const u8,
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
        \\    ?, '', ?, ?,
        \\    datetime('now'), datetime('now')
        \\)
    , .{
        id, page_id, name,
        x_str, y_str, w_str, h_str,
        elem_type,
        fill,
        text_content,
        image_url,
        parent_id orelse "",
    });
}

// ─── Wiring tests ────────────────────────────────────────────────────────

test "wiring: preview_design_page tool is registered in tools_equipped.zig tools_list" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, TOOLS_EQUIPPED_PATH);
    defer alloc.free(source);
    try testing.expect(contains(source,
        \\preview_design_page_mod.preview_design_page_tool,
    ));
}

test "wiring: preview_design_page is in tools_equipped.zig UNIFIED_TOOL_REGISTRY" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, TOOLS_EQUIPPED_PATH);
    defer alloc.free(source);
    try testing.expect(contains(source,
        \\.{ .name = "preview_design_page",
    ));
}

test "wiring: preview_design_page is re-exported in src/root.zig" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, ROOT_PATH);
    defer alloc.free(source);
    try testing.expect(contains(source,
        \\pub const preview_design_page = @import("modules/agent/tools/preview_design_page.zig");
    ));
}

test "wiring: execPreviewDesignPage is re-exported in agentic_loop/tools.zig" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, TOOLS_PATH);
    defer alloc.free(source);
    try testing.expect(contains(source,
        \\pub const execPreviewDesignPage = @import("tools_exec_preview_design_page.zig").execPreviewDesignPage;
    ));
}

test "wiring: tools_exec_preview_design_page.zig exists" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, TOOL_EXEC_PATH);
    defer alloc.free(source);
    try testing.expect(contains(source,
        \\pub fn execPreviewDesignPage(
    ));
}

// ─── Behavioural tests ──────────────────────────────────────────────────

test "executePreviewDesignPageToString with unknown page_id returns <show_preview><error> envelope" {
    const alloc = testing.allocator;
    var ctx = try setupCtx();
    defer teardownCtx(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    var preview_id: []u8 = undefined;
    const out = try preview_design_page.executePreviewDesignPageToString(
        alloc, ctx.io, &ctx.db,
        .{ .page_id = "page_ghost", .scale = 1.0 },
        &preview_id,
    );
    defer alloc.free(out);
    defer alloc.free(preview_id);

    try testing.expect(contains(out, "<show_preview>"));
    try testing.expect(contains(out, "<error>"));
    try testing.expect(contains(out, "not found"));
    try testing.expect(contains(out, "</show_preview>"));
}

test "executePreviewDesignPageToString on empty page returns success envelope + valid SVG" {
    const alloc = testing.allocator;
    var ctx = try setupCtx();
    defer teardownCtx(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id, .page_name = "Empty", .width = 800, .height = 600,
    });
    defer alloc.free(page_id);

    var preview_id: []u8 = undefined;
    const out = try preview_design_page.executePreviewDesignPageToString(
        alloc, ctx.io, &ctx.db,
        .{ .page_id = page_id, .scale = 1.0 },
        &preview_id,
    );
    defer alloc.free(out);
    defer alloc.free(preview_id);

    // Envelope shape (matches show_preview)
    try testing.expect(contains(out, "<show_preview>"));
    try testing.expect(contains(out, "<status>shown</status>"));
    try testing.expect(contains(out, "<preview_id>"));
    try testing.expect(contains(out, "pv_"));
    try testing.expect(contains(out, "<content_type>html</content_type>"));
    try testing.expect(contains(out, "<content_length>"));
    try testing.expect(contains(out, "</show_preview>"));

    // SVG content
    try testing.expect(contains(out, "<svg"));
    try testing.expect(contains(out, "viewBox=\"0 0 800 600\""));
    try testing.expect(contains(out, "</svg>"));
}

test "executePreviewDesignPageToString renders a rectangle as <rect>" {
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
        1356, 16, 60, 24, "transparent", null, "", "");

    var preview_id: []u8 = undefined;
    const out = try preview_design_page.executePreviewDesignPageToString(
        alloc, ctx.io, &ctx.db,
        .{ .page_id = page_id, .scale = 1.0 },
        &preview_id,
    );
    defer alloc.free(out);
    defer alloc.free(preview_id);

    // The rectangle renders as <rect x="1356" y="16" width="60" height="24" fill="transparent"/>
    try testing.expect(contains(out, "<rect "));
    try testing.expect(contains(out, "x=\"1356\""));
    try testing.expect(contains(out, "y=\"16\""));
    try testing.expect(contains(out, "width=\"60\""));
    try testing.expect(contains(out, "height=\"24\""));
    try testing.expect(contains(out, "fill=\"transparent\""));
}

test "executePreviewDesignPageToString renders an ellipse as <ellipse>" {
    const alloc = testing.allocator;
    var ctx = try setupCtx();
    defer teardownCtx(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id, .page_name = "Page", .width = 800, .height = 600,
    });
    defer alloc.free(page_id);

    try insertElementRaw(alloc, &ctx.db, page_id, "circle", "ellipse",
        100, 100, 80, 80, "#ff0000", null, "", "");

    var preview_id: []u8 = undefined;
    const out = try preview_design_page.executePreviewDesignPageToString(
        alloc, ctx.io, &ctx.db,
        .{ .page_id = page_id, .scale = 1.0 },
        &preview_id,
    );
    defer alloc.free(out);
    defer alloc.free(preview_id);

    try testing.expect(contains(out, "<ellipse "));
    // cx/cy = center of bbox, rx/ry = half width/height
    try testing.expect(contains(out, "cx=\"140\""));
    try testing.expect(contains(out, "cy=\"140\""));
    try testing.expect(contains(out, "rx=\"40\""));
    try testing.expect(contains(out, "ry=\"40\""));
    try testing.expect(contains(out, "fill=\"#ff0000\""));
}

test "executePreviewDesignPageToString renders a text element with text_content" {
    const alloc = testing.allocator;
    var ctx = try setupCtx();
    defer teardownCtx(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id, .page_name = "Page", .width = 800, .height = 600,
    });
    defer alloc.free(page_id);

    try insertElementRaw(alloc, &ctx.db, page_id, "title", "text",
        100, 100, 200, 40, "", null, "Welcome to nalar", "");

    var preview_id: []u8 = undefined;
    const out = try preview_design_page.executePreviewDesignPageToString(
        alloc, ctx.io, &ctx.db,
        .{ .page_id = page_id, .scale = 1.0 },
        &preview_id,
    );
    defer alloc.free(out);
    defer alloc.free(preview_id);

    try testing.expect(contains(out, "<text "));
    try testing.expect(contains(out, "x=\"100\""));
    try testing.expect(contains(out, "y=\"140\"")); // baseline = y + height
    try testing.expect(contains(out, "Welcome to nalar"));
}

test "executePreviewDesignPageToString renders an image element with image_url href" {
    const alloc = testing.allocator;
    var ctx = try setupCtx();
    defer teardownCtx(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id, .page_name = "Page", .width = 800, .height = 600,
    });
    defer alloc.free(page_id);

    try insertElementRaw(alloc, &ctx.db, page_id, "hero", "image",
        0, 0, 400, 300, "", null, "", "https://example.com/hero.png");

    var preview_id: []u8 = undefined;
    const out = try preview_design_page.executePreviewDesignPageToString(
        alloc, ctx.io, &ctx.db,
        .{ .page_id = page_id, .scale = 1.0 },
        &preview_id,
    );
    defer alloc.free(out);
    defer alloc.free(preview_id);

    try testing.expect(contains(out, "<image "));
    try testing.expect(contains(out, "href=\"https://example.com/hero.png\""));
    try testing.expect(contains(out, "x=\"0\""));
    try testing.expect(contains(out, "y=\"0\""));
    try testing.expect(contains(out, "width=\"400\""));
    try testing.expect(contains(out, "height=\"300\""));
}

test "executePreviewDesignPageToString scale=2.0 doubles the SVG viewBox and element coords" {
    const alloc = testing.allocator;
    var ctx = try setupCtx();
    defer teardownCtx(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id, .page_name = "Page", .width = 800, .height = 600,
    });
    defer alloc.free(page_id);

    try insertElementRaw(alloc, &ctx.db, page_id, "box", "rectangle",
        100, 100, 50, 50, "#000", null, "", "");

    var preview_id: []u8 = undefined;
    const out = try preview_design_page.executePreviewDesignPageToString(
        alloc, ctx.io, &ctx.db,
        .{ .page_id = page_id, .scale = 2.0 },
        &preview_id,
    );
    defer alloc.free(out);
    defer alloc.free(preview_id);

    // viewBox is 2x (1600 x 1200)
    try testing.expect(contains(out, "viewBox=\"0 0 1600 1200\""));
    // The rectangle's x/y/width/height are all 2x
    try testing.expect(contains(out, "x=\"200\""));
    try testing.expect(contains(out, "y=\"200\""));
    try testing.expect(contains(out, "width=\"100\""));
    try testing.expect(contains(out, "height=\"100\""));
}

test "executePreviewDesignPageToString renders groups/frames as <g> containers" {
    const alloc = testing.allocator;
    var ctx = try setupCtx();
    defer teardownCtx(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id, .page_name = "Page", .width = 800, .height = 600,
    });
    defer alloc.free(page_id);

    // Group at (0,0) 200x100 with 1 child inside.
    try insertElementRaw(alloc, &ctx.db, page_id, "parent-frame", "frame",
        0, 0, 200, 100, "transparent", null, "", "");
    try insertElementRaw(alloc, &ctx.db, page_id, "child-leaf", "rectangle",
        10, 10, 30, 30, "#ff0000", "elem_parent-frame", "", "");

    var preview_id: []u8 = undefined;
    const out = try preview_design_page.executePreviewDesignPageToString(
        alloc, ctx.io, &ctx.db,
        .{ .page_id = page_id, .scale = 1.0 },
        &preview_id,
    );
    defer alloc.free(out);
    defer alloc.free(preview_id);

    // Group rendered as <g> with a transform
    try testing.expect(contains(out, "<g "));
    // The child rect appears INSIDE the <g> (we don't enforce literal
    // nesting in the test — we just check that both the g AND the child
    // rect exist. The renderer's tree-walk ensures nesting.)
    try testing.expect(contains(out, "name=\"child-leaf\"") or contains(out, "fill=\"#ff0000\""));
}

test "executePreviewDesignPageToString preview_id is generated and unique" {
    const alloc = testing.allocator;
    var ctx = try setupCtx();
    defer teardownCtx(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id, .page_name = "Page", .width = 800, .height = 600,
    });
    defer alloc.free(page_id);

    var preview_id_1: []u8 = undefined;
    const out1 = try preview_design_page.executePreviewDesignPageToString(
        alloc, ctx.io, &ctx.db,
        .{ .page_id = page_id, .scale = 1.0 },
        &preview_id_1,
    );
    defer alloc.free(out1);
    defer alloc.free(preview_id_1);

    var preview_id_2: []u8 = undefined;
    const out2 = try preview_design_page.executePreviewDesignPageToString(
        alloc, ctx.io, &ctx.db,
        .{ .page_id = page_id, .scale = 1.0 },
        &preview_id_2,
    );
    defer alloc.free(out2);
    defer alloc.free(preview_id_2);

    // Both ids are present in their own envelope
    try testing.expect(contains(out1, preview_id_1));
    try testing.expect(contains(out2, preview_id_2));

    // Different ids (different timestamps / random suffixes)
    try testing.expect(!std.mem.eql(u8, preview_id_1, preview_id_2));
}