//! Static-contract + behavioural tests for `groupElements` model + the
//! `parent_id` extension to `updateElement`.
//!
//! What this file locks in
//! ───────────────────────
//!   1. `groupElements` function signature: `page_id`, `child_ids`,
//!      `parent_name`, `parent_type` (ElementType) parameters.
//!   2. The new parent element is INSERTed with `parent_id = NULL`
//!      (it is itself top-level).
//!   3. Each child's `parent_id` is UPDATEd to the new parent's id.
//!   4. The new group's geometry is the union bbox of the children.
//!   5. Cross-page child ids are rejected with `ChildAcrossDifferentPages`.
//!   6. Already-parented children are rejected with `ChildAlreadyParented`.
//!   7. `updateElement` accepts `parent_id: ?[]const u8 = null` and
//!      appends `parent_id = ?` to the SET clause when non-null.
//!
//! Plan: docs/superpowers/plans/2026-07-28-grouped-layers.md (Chunk 2)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const design_model = @import("design_model.zig");

const DESIGN_MODEL_PATH = "src/ai_workflow/tui/agentic_loop/design_model.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

/// Open a fresh in-memory sqlite DB with the minimum tables needed
/// for the design SQL. Same shape as
/// `design_model_test.zig::setupDbAndItem`.
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

    const item_id_const = "item_design_group";
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

/// Insert one design element with explicit (x, y, width, height) and
/// the given name. Returns the generated elem_<id>.
fn insertChild(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, page_id: []const u8, name: []const u8, x: i64, y: i64, w: i64, h: i64) ![]u8 {
    // db.exec binds only TEXT — stringify the integer columns.
    const x_str = try std.fmt.allocPrint(alloc, "{d}", .{x});
    defer alloc.free(x_str);
    const y_str = try std.fmt.allocPrint(alloc, "{d}", .{y});
    defer alloc.free(y_str);
    const w_str = try std.fmt.allocPrint(alloc, "{d}", .{w});
    defer alloc.free(w_str);
    const h_str = try std.fmt.allocPrint(alloc, "{d}", .{h});
    defer alloc.free(h_str);
    try db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   (?, ?, ?, '', ?, ?, ?, ?, 0, 0,
        \\    'rectangle', 0.0, '#ffffff', '', 0, 0, 1.0,
        \\    '', '', '', NULL, datetime('now'), datetime('now'))
    , &.{ name, page_id, name, x_str, y_str, w_str, h_str });
    return alloc.dupe(u8, name);
}

// ─── Contract 1: signature ───────────────────────────────────────────────

test "groupElements function signature declares page_id child_ids parent_name parent_type" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DESIGN_MODEL_PATH);
    defer allocator.free(source);

    // The GroupElementsInput struct carries (page_id, child_ids,
    // parent_name, parent_type) and lives immediately above the
    // groupElements function. Search a wider window that includes
    // both the struct declaration and the function signature.
    const struct_idx = std.mem.indexOf(u8, source, "pub const GroupElementsInput") orelse {
        std.debug.print("\n!! GroupElementsInput not declared in {s} !!\n", .{DESIGN_MODEL_PATH});
        return error.GroupElementsInputStructMissing;
    };
    const fn_idx = std.mem.indexOf(u8, source, "pub fn groupElements") orelse {
        std.debug.print("\n!! groupElements function not found in {s} !!\n", .{DESIGN_MODEL_PATH});
        return error.GroupElementsMissing;
    };
    const start = struct_idx;
    const end = @min(source.len, fn_idx + 1500);
    const window = source[start..end];

    if (std.mem.indexOf(u8, window, "page_id") == null) {
        std.debug.print("\n!! GroupElementsInput is missing page_id !!\n", .{});
        return error.GroupElementsPageIdMissing;
    }
    if (std.mem.indexOf(u8, window, "child_ids") == null) {
        std.debug.print("\n!! GroupElementsInput is missing child_ids !!\n", .{});
        return error.GroupElementsChildIdsMissing;
    }
    if (std.mem.indexOf(u8, window, "parent_name") == null) {
        std.debug.print("\n!! GroupElementsInput is missing parent_name !!\n", .{});
        return error.GroupElementsParentNameMissing;
    }
    if (std.mem.indexOf(u8, window, "parent_type") == null) {
        std.debug.print("\n!! GroupElementsInput is missing parent_type !!\n", .{});
        return error.GroupElementsParentTypeMissing;
    }
}

test "groupElements returns new parent element_id" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DESIGN_MODEL_PATH);
    defer allocator.free(source);

    const idx = std.mem.indexOf(u8, source, "pub fn groupElements") orelse {
        return error.GroupElementsMissing;
    };
    const after = source[idx..];
    const window_end = @min(after.len, 1500);
    const window = after[0..window_end];

    if (std.mem.indexOf(u8, window, "[]u8") == null) {
        std.debug.print("\n!! groupElements should return []u8 (new parent element_id) !!\n", .{});
        return error.GroupElementsReturnMissing;
    }
}

test "groupElements uses a transaction (db.begin / tx.exec / tx.commit)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DESIGN_MODEL_PATH);
    defer allocator.free(source);

    const idx = std.mem.indexOf(u8, source, "pub fn groupElements") orelse {
        return error.GroupElementsMissing;
    };
    const after = source[idx..];
    // groupElements is large (~400 lines). Scan the full function body.
    const window_end = @min(after.len, 30000);
    const window = after[0..window_end];

    const has_begin = std.mem.indexOf(u8, window, "db.begin") != null;
    const has_tx_exec = std.mem.indexOf(u8, window, "tx.exec") != null;
    const has_commit = std.mem.indexOf(u8, window, "tx.commit") != null;

    if (!has_begin or !has_tx_exec or !has_commit) {
        std.debug.print(
            "\n!! groupElements must use a transaction !!\n" ++
                "   Expected: db.begin() + tx.exec() + tx.commit()\n" ++
                "   Found: begin={}, tx_exec={}, commit={}\n",
            .{ has_begin, has_tx_exec, has_commit },
        );
        return error.GroupElementsTransactionMissing;
    }
}

test "groupElements emits design_element_created SSE event for the new parent" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DESIGN_MODEL_PATH);
    defer allocator.free(source);

    const idx = std.mem.indexOf(u8, source, "pub fn groupElements") orelse {
        return error.GroupElementsMissing;
    };
    const after = source[idx..];
    const window_end = @min(after.len, 30000);
    const window = after[0..window_end];

    if (std.mem.indexOf(u8, window, "onEventSendDesignElementCreated") == null) {
        std.debug.print(
            "\n!! groupElements must emit design_element_created SSE !!\n" ++
                "   The new parent element needs an SSE event for multi-tab sync.\n",
            .{});
        return error.GroupElementsSseCreatedMissing;
    }
}

test "groupElements emits design_element_updated SSE events for each child" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DESIGN_MODEL_PATH);
    defer allocator.free(source);

    const idx = std.mem.indexOf(u8, source, "pub fn groupElements") orelse {
        return error.GroupElementsMissing;
    };
    const after = source[idx..];
    const window_end = @min(after.len, 30000);
    const window = after[0..window_end];

    if (std.mem.indexOf(u8, window, "onEventSendDesignElementUpdated") == null) {
        std.debug.print(
            "\n!! groupElements must emit design_element_updated SSE for each child !!\n" ++
                "   Reparenting is a per-child event the frontend reconciles via SSE.\n",
            .{});
        return error.GroupElementsSseUpdatedMissing;
    }
}

// ─── Contract 2: union bbox geometry ─────────────────────────────────────

test "groupElements uses union bbox geometry (min_x, min_y, max_x, max_y)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DESIGN_MODEL_PATH);
    defer allocator.free(source);

    const idx = std.mem.indexOf(u8, source, "pub fn groupElements") orelse {
        return error.GroupElementsMissing;
    };
    const after = source[idx..];
    const window_end = @min(after.len, 8000);
    const window = after[0..window_end];

    if (std.mem.indexOf(u8, window, "min_x") == null or
        std.mem.indexOf(u8, window, "min_y") == null or
        std.mem.indexOf(u8, window, "max_x") == null or
        std.mem.indexOf(u8, window, "max_y") == null)
    {
        std.debug.print(
            "\n!! groupElements must compute union bbox via min_x/min_y/max_x/max_y !!\n",
            .{});
        return error.UnionBboxMissing;
    }
}

// ─── Contract 2b: group z_index sits BELOW its children ──────────────────
//
// Fix 2026-08-14 (task_1786693066547): a group's natural visual stacking
// must be BEHIND its children, otherwise the group's body occludes the
// children inside it (the user reported the dark fill #181616 hiding the
// 9 children until they set the group's fill to transparent).
//
// Implementation: track `min_z` and compute the group's z_index as
// `min_z - 1` so the container paints behind the children. Behavioural
// contract: the source must reference `min_z - 1` and must NOT use
// `max_z + 1` inside the groupElements function body.

test "groupElements sets z_index below children (min_z - 1, not max_z + 1)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DESIGN_MODEL_PATH);
    defer allocator.free(source);

    const idx = std.mem.indexOf(u8, source, "pub fn groupElements") orelse {
        return error.GroupElementsMissing;
    };
    // Find the NEXT `pub fn ` after groupElements so the window
    // covers ONLY groupElements' body (not unrelated functions like
    // reorderElements that also use `max_z + 1` for Bring-to-front).
    const after = source[idx..];
    const fn_marker = "pub fn ";
    const fn_after = std.mem.indexOfPos(u8, after, "pub fn ".len, fn_marker) orelse after.len;
    const window = after[0..fn_after];

    const has_min_z = std.mem.indexOf(u8, window, "min_z") != null;
    const has_min_z_minus_1 = std.mem.indexOf(u8, window, "min_z - 1") != null;
    const has_max_z_plus_1 = std.mem.indexOf(u8, window, "max_z + 1") != null;

    if (!has_min_z) {
        std.debug.print(
            "\n!! groupElements must track min_z across children !!\n",
            .{});
        return error.GroupZIndexMinZMissing;
    }
    if (!has_min_z_minus_1) {
        std.debug.print(
            "\n!! groupElements must allocate z_index_str from `min_z - 1` !!\n" ++
                "   A container must render BEHIND its children; otherwise the\n" ++
                "   group's opaque fill occludes the children inside it.\n",
            .{});
        return error.GroupZIndexAboveChildren;
    }
    if (has_max_z_plus_1) {
        std.debug.print(
            "\n!! groupElements must NOT use `max_z + 1` for the group's z_index !!\n" ++
                "   Reversed: a container drawn on top of its contents occludes them.\n",
            .{});
        return error.GroupZIndexAboveChildren;
    }
}

// ─── Contract 3: error set ───────────────────────────────────────────────

test "groupElements error set declares ChildAcrossDifferentPages and ChildAlreadyParented" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DESIGN_MODEL_PATH);
    defer allocator.free(source);

    const idx = std.mem.indexOf(u8, source, "pub const GroupElementsError") orelse {
        std.debug.print("\n!! GroupElementsError not declared in {s} !!\n", .{DESIGN_MODEL_PATH});
        return error.GroupElementsErrorMissing;
    };
    const after = source[idx..];
    const window_end = @min(after.len, 600);
    const window = after[0..window_end];

    if (std.mem.indexOf(u8, window, "ChildAcrossDifferentPages") == null) {
        std.debug.print("\n!! GroupElementsError missing ChildAcrossDifferentPages !!\n", .{});
        return error.CrossPageErrorMissing;
    }
    if (std.mem.indexOf(u8, window, "ChildAlreadyParented") == null) {
        std.debug.print("\n!! GroupElementsError missing ChildAlreadyParented !!\n", .{});
        return error.AlreadyParentedErrorMissing;
    }
}

// ─── Contract 4: updateElement SET clause accepts parent_id ──────────────

test "updateElement SET clause includes parent_id when input.parent_id is non-null" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DESIGN_MODEL_PATH);
    defer allocator.free(source);

    const idx = std.mem.indexOf(u8, source, "pub fn updateElement") orelse {
        std.debug.print("\n!! updateElement not found in {s} !!\n", .{DESIGN_MODEL_PATH});
        return error.UpdateElementMissing;
    };
    const after = source[idx..];
    const window_end = @min(after.len, 6000);
    const window = after[0..window_end];

    if (std.mem.indexOf(u8, window, "\"parent_id = ?\"") == null) {
        std.debug.print(
            "\n!! updateElement must append `parent_id = ?` to the SET clause when non-null !!\n",
            .{});
        return error.UpdateElementParentIdSetMissing;
    }
    if (std.mem.indexOf(u8, window, "input.parent_id") == null) {
        std.debug.print(
            "\n!! updateElement must reference input.parent_id in its SET clause builder !!\n",
            .{});
        return error.UpdateElementParentIdRefMissing;
    }
}

// ─── Behavioural tests ───────────────────────────────────────────────────

test "groupElements creates a new parent element and reparents the children" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    // Create 3 children with disjoint bboxes (union = 0,0 → 200,150).
    const child_a = try insertChild(alloc, &ctx.db, page_id, "elem_a", 0, 0, 100, 50);
    defer alloc.free(child_a);
    const child_b = try insertChild(alloc, &ctx.db, page_id, "elem_b", 50, 100, 100, 50);
    defer alloc.free(child_b);
    const child_c = try insertChild(alloc, &ctx.db, page_id, "elem_c", 200, 0, 0, 150);
    defer alloc.free(child_c);

    const new_id = try design_model.groupElements(alloc, &ctx.db, .{
        .page_id = page_id,
        .child_ids = &.{ child_a, child_b, child_c },
        .parent_name = "Kanban-view",
        .parent_type = .group,
    });
    defer alloc.free(new_id);

    // The new element should be a top-level 'group' with union bbox.
    const parent = try design_model.getElement(alloc, &ctx.db, new_id);
    defer design_model.freeElement(alloc, parent);

    try testing.expectEqualStrings("Kanban-view", parent.name);
    try testing.expectEqualStrings("group", parent.elem_type);
    try testing.expectEqual(@as(i64, 0), parent.x);
    try testing.expectEqual(@as(i64, 0), parent.y);
    try testing.expectEqual(@as(i64, 200), parent.width);
    try testing.expectEqual(@as(i64, 150), parent.height);
    try testing.expectEqual(@as(usize, 0), parent.parent_id.len);

    // The group must render BEHIND its children — otherwise an opaque
    // fill occludes its contents. Children default to z_index 0, so the
    // group must sit at -1 (min_z - 1).
    try testing.expectEqual(@as(i64, -1), parent.z_index);

    // Each child should now have parent_id set to the new parent.
    const a_after = try design_model.getElement(alloc, &ctx.db, child_a);
    defer design_model.freeElement(alloc, a_after);
    try testing.expectEqualStrings(new_id, a_after.parent_id);

    const b_after = try design_model.getElement(alloc, &ctx.db, child_b);
    defer design_model.freeElement(alloc, b_after);
    try testing.expectEqualStrings(new_id, b_after.parent_id);

    const c_after = try design_model.getElement(alloc, &ctx.db, child_c);
    defer design_model.freeElement(alloc, c_after);
    try testing.expectEqualStrings(new_id, c_after.parent_id);
}

test "groupElements rejects cross-page child ids" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_a = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "A",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_a);

    const page_b = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "B",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_b);

    const child_a = try insertChild(alloc, &ctx.db, page_a, "elem_a1", 0, 0, 50, 50);
    defer alloc.free(child_a);
    const child_b = try insertChild(alloc, &ctx.db, page_b, "elem_b1", 0, 0, 50, 50);
    defer alloc.free(child_b);

    // Try to group children that live on different pages.
    const result = design_model.groupElements(alloc, &ctx.db, .{
        .page_id = page_a,
        .child_ids = &.{ child_a, child_b },
        .parent_name = "Cross-page-group",
        .parent_type = .group,
    });
    try testing.expectError(error.ChildAcrossDifferentPages, result);
}

test "groupElements rejects already-parented children" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    const child_a = try insertChild(alloc, &ctx.db, page_id, "elem_a2", 0, 0, 50, 50);
    defer alloc.free(child_a);
    const child_b = try insertChild(alloc, &ctx.db, page_id, "elem_b2", 0, 0, 50, 50);
    defer alloc.free(child_b);

    // Pre-set parent_id on child_a to simulate "already parented".
    try ctx.db.exec(alloc,
        "UPDATE design_page_elements SET parent_id = 'elem_some_parent' WHERE id = ?",
        &.{child_a});

    const result = design_model.groupElements(alloc, &ctx.db, .{
        .page_id = page_id,
        .child_ids = &.{ child_a, child_b },
        .parent_name = "Should-fail",
        .parent_type = .group,
    });
    try testing.expectError(error.ChildAlreadyParented, result);
}

test "updateElement accepts parent_id and writes it to the row" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    const parent_id_slice = try alloc.dupe(u8, "elem_parent_set");
    defer alloc.free(parent_id_slice);

    const child_id = try insertChild(alloc, &ctx.db, page_id, "elem_to_reparent", 10, 10, 100, 50);
    defer alloc.free(child_id);

    // Sanity: parent_id is empty before the update.
    {
        const before = try design_model.getElement(alloc, &ctx.db, child_id);
        defer design_model.freeElement(alloc, before);
        try testing.expectEqual(@as(usize, 0), before.parent_id.len);
    }

    const updated_id = try design_model.updateElement(alloc, &ctx.db, .{
        .element_id = child_id,
        .parent_id = parent_id_slice,
    });
    defer alloc.free(updated_id);

    const after = try design_model.getElement(alloc, &ctx.db, child_id);
    defer design_model.freeElement(alloc, after);
    try testing.expectEqualStrings("elem_parent_set", after.parent_id);
}

test "updateElement with parent_id = null leaves existing parent_id unchanged" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    const child_id = try insertChild(alloc, &ctx.db, page_id, "elem_keep_parent", 10, 10, 100, 50);
    defer alloc.free(child_id);

    // Set parent_id once.
    const set_id = try design_model.updateElement(alloc, &ctx.db, .{
        .element_id = child_id,
        .parent_id = "elem_first_parent",
    });
    defer alloc.free(set_id);

    // Update x without touching parent_id (parent_id stays "elem_first_parent").
    const x_id = try design_model.updateElement(alloc, &ctx.db, .{
        .element_id = child_id,
        .x = 99,
    });
    defer alloc.free(x_id);

    const after = try design_model.getElement(alloc, &ctx.db, child_id);
    defer design_model.freeElement(alloc, after);
    try testing.expectEqualStrings("elem_first_parent", after.parent_id);
    try testing.expectEqual(@as(i64, 99), after.x);
}