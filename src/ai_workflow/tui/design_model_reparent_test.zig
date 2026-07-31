//! Behavioural tests for `updateElement` accepting `parent_id` (existing)
//! + the new optional `reposition: RepositionMode` field + cycle prevention.
//!
//! Plan: docs/superpowers/plans/2026-07-30-design-layer-drag-join-or-leave-group.md
//! (Chunk 1 — Tasks 1.1, 1.2)
//!
//! Tests:
//!   1. updateElement with `parent_id` + `reposition: .last_in_parent` recomputes
//!      position to MAX(position of new siblings) + 1.
//!   2. updateElement with `parent_id` + `reposition: .last_in_parent` chained
//!      calls produce strictly-increasing positions (a, b, c → max+1, max+2, max+3).
//!   3. updateElement with `parent_id` pointing to the element's own id
//!      returns `error.CycleDetected`.
//!   4. updateElement with `parent_id` pointing to a transitive descendant
//!      returns `error.CycleDetected`.
//!   5. updateElement with `parent_id` pointing to a non-descendant group
//!      succeeds (no false positive on cycle check).
//!   6. updateElement without `reposition` keeps the existing behavior
//!      (the element's position field is left unchanged).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const design_model = @import("design_model.zig");

/// Open a fresh in-memory sqlite DB with the minimum tables needed for
/// the design SQL. Same shape as
/// `design_model_set_element_parent_test.zig::setupDbAndItem` —
/// duplicated here for self-containment so the tests can stand alone.
fn setupDbAndItem() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
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
    const tmpdir_path = try testing.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_design_reparent";
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

fn teardown(db: *sqlite.SqliteBackend, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

// ─── Test 1: reposition recomputes position to MAX + 1 ────────────────────

test "updateElement with reposition: .last_in_parent sets position to MAX(siblings) + 1 (initially 0)" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    // Create one group at top-level + one leaf at top-level.
    const group_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-card",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const leaf_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf-a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 110, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf_id);

    // Reparent the leaf INTO the group with last_in_parent.
    const result_id = try design_model.updateElement(alloc, &ctx.db, .{
        .element_id = leaf_id,
        .parent_id = group_id,
        .reposition = .last_in_parent,
    });
    defer alloc.free(result_id);

    // Read back the leaf — verify parent_id and position.
    const got = try design_model.getElement(alloc, &ctx.db, leaf_id);
    defer design_model.freeElement(alloc, got);
    try testing.expectEqualStrings(group_id, got.parent_id);
    // The group had 0 children (no other elements had parent_id = group_id),
    // so MAX(position) of siblings-with-same-parent was -1 (the COALESCE
    // default), and the leaf lands at 0.
    try testing.expectEqual(@as(i64, 0), got.position);
}

// ─── Test 2: chained calls produce strictly-increasing positions ──────────

test "updateElement with reposition: .last_in_parent chains to MAX+1, MAX+2, MAX+3" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-card",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const a_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf-a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 110, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(a_id);

    const b_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf-b",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 200, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(b_id);

    const c_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf-c",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 300, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(c_id);

    // Reparent a → first (0)
    const ra = try design_model.updateElement(alloc, &ctx.db, .{
        .element_id = a_id,
        .parent_id = group_id,
        .reposition = .last_in_parent,
    });
    defer alloc.free(ra);

    // Reparent b → second (1)
    const rb = try design_model.updateElement(alloc, &ctx.db, .{
        .element_id = b_id,
        .parent_id = group_id,
        .reposition = .last_in_parent,
    });
    defer alloc.free(rb);

    // Reparent c → third (2)
    const rc = try design_model.updateElement(alloc, &ctx.db, .{
        .element_id = c_id,
        .parent_id = group_id,
        .reposition = .last_in_parent,
    });
    defer alloc.free(rc);

    // Verify positions are 0, 1, 2.
    const got_a = try design_model.getElement(alloc, &ctx.db, a_id);
    defer design_model.freeElement(alloc, got_a);
    const got_b = try design_model.getElement(alloc, &ctx.db, b_id);
    defer design_model.freeElement(alloc, got_b);
    const got_c = try design_model.getElement(alloc, &ctx.db, c_id);
    defer design_model.freeElement(alloc, got_c);

    try testing.expectEqual(@as(i64, 0), got_a.position);
    try testing.expectEqual(@as(i64, 1), got_b.position);
    try testing.expectEqual(@as(i64, 2), got_c.position);
}

// ─── Test 3: cycle — element into itself ─────────────────────────────────

test "updateElement with parent_id = self returns CycleDetected" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    // Attempt self-cycle.
    const result = design_model.updateElement(alloc, &ctx.db, .{
        .element_id = group_id,
        .parent_id = group_id,
    });
    try testing.expectError(error.CycleDetected, result);
}

// ─── Test 4: cycle — element into its own descendant ─────────────────────

test "updateElement with parent_id = transitive descendant returns CycleDetected" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_a_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group-a",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_a_id);

    const group_b_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group-b",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 200, .y = 300, .width = 200, .height = 200,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_b_id);

    const leaf_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 300, .y = 400, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf_id);

    // Manually set up the hierarchy: group_b → group_a (parent), leaf → group_b (parent).
    const b_into_a = try design_model.updateElement(alloc, &ctx.db, .{
        .element_id = group_b_id,
        .parent_id = group_a_id,
    });
    defer alloc.free(b_into_a);
    const leaf_into_b = try design_model.updateElement(alloc, &ctx.db, .{
        .element_id = leaf_id,
        .parent_id = group_b_id,
    });
    defer alloc.free(leaf_into_b);

    // Now try to set group_a's parent_id to leaf_id (a transitive descendant).
    // This would close the cycle: group_a → ... → leaf → group_a.
    const cycle_result = design_model.updateElement(alloc, &ctx.db, .{
        .element_id = group_a_id,
        .parent_id = leaf_id,
    });
    try testing.expectError(error.CycleDetected, cycle_result);
}

// ─── Test 5: cycle — unrelated groups reparent cleanly ────────────────────

test "updateElement with parent_id = unrelated group succeeds (no false positive on cycle check)" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_a_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group-a",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_a_id);

    const group_b_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group-b",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 600, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_b_id);

    // Reparent group_a INTO group_b — unrelated, no cycle.
    const result_id = try design_model.updateElement(alloc, &ctx.db, .{
        .element_id = group_a_id,
        .parent_id = group_b_id,
        .reposition = .last_in_parent,
    });
    defer alloc.free(result_id);

    const got = try design_model.getElement(alloc, &ctx.db, group_a_id);
    defer design_model.freeElement(alloc, got);
    try testing.expectEqualStrings(group_b_id, got.parent_id);
}

// ─── Test 6: backward compat — no reposition → position unchanged ─────────

test "updateElement without reposition leaves position unchanged" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const leaf_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 110, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf_id);

    // Reparent WITHOUT reposition — the leaf's position should stay 0
    // (the default from addElement).
    const result_id = try design_model.updateElement(alloc, &ctx.db, .{
        .element_id = leaf_id,
        .parent_id = group_id,
    });
    defer alloc.free(result_id);

    const got = try design_model.getElement(alloc, &ctx.db, leaf_id);
    defer design_model.freeElement(alloc, got);
    try testing.expectEqualStrings(group_id, got.parent_id);
    // addElement assigns positions sequentially: group=0, leaf=1.
    // Without reposition, the UPDATE only changes parent_id and
    // leaves position as-is. So leaf.position stays at 1.
    try testing.expectEqual(@as(i64, 1), got.position);
}