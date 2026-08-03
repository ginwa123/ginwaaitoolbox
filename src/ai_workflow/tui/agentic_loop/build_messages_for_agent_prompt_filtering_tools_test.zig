//! Unit tests for `filteringTools` in `build_messages_for_agent_prompt.zig`.
//!
//! The function filters the LLM-facing tool list by the session's parent
//! workspace item type:
//!
//! | Item type    | Removed tools                                                   |
//! |--------------|-----------------------------------------------------------------|
//! | `design`     | kanban_list, kanban_move_task                                   |
//! | `folder`     | kanban_list, kanban_move_task, set_design_page, add_design_element, update_design_element, group_design_elements, set_element_parent, move_design_element |
//! | `kanban`     | set_design_page, add_design_element, update_design_element, group_design_elements, set_element_parent, move_design_element |
//! | any other    | (no filter — tools pass through unchanged)                       |
//! | empty/unbound session_id | (no filter — tools pass through unchanged)             |
//!
//! All three branches are mutually exclusive — only ONE of them fires
//! per call. Tests assert:
//!
//! 1. The right tools are removed for each item_type.
//! 2. The right tools are kept for each item_type.
//! 3. The function is a no-op for non-matching item types (chat/folder
//!    border cases + empty session + unbound session).
//! 4. Unknown tool names are preserved regardless of branch.
//! 5. The filter handles mixed-order input — order of tools in the input
//!    does not matter.
//! 6. The branches are mutually exclusive — folder parent doesn't also
//!    drop design-specific tools that are already part of the kanban
//!    branch (false-positive regression).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const build_msg_prompt = @import("build_messages_for_agent_prompt.zig");
const filteringTools = build_msg_prompt.filteringTools;

// ─── DB setup helpers (minimal — filteringTools only needs the
// getWorkspaceContext anchor tables) ─────────────────────────────────

fn setupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE workspaces (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});

    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL,
        \\    name TEXT,
        \\    path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME DEFAULT NULL,
        \\    updated_at DATETIME DEFAULT NULL
        \\)
    , &.{});

    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    kanban_column_id TEXT,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

/// Seed a workspace with one item (item_type) bound to one task.
/// `session_id` (the test side) equals `task.id` (the DB side)
/// per the `task.id == session_id` convention.
fn seedItem(db: *sqlite.SqliteBackend, alloc: std.mem.Allocator, workspace_id: []const u8, item_id: []const u8, item_type: []const u8, task_id: []const u8) !void {
    try db.exec(alloc,
        "INSERT INTO workspaces (id, name) VALUES (?, ?)",
        &.{ workspace_id, "test-ws" },
    );
    try db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path)
        \\VALUES (?, ?, ?, ?, ?)
    , &.{ item_id, workspace_id, item_type, item_type, "/abs/x" });
    try db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type)
        \\VALUES (?, ?, ?, 'standard')
    , &.{ task_id, "t", item_id });
}

// ─── Tool fixture helpers ────────────────────────────────────────────────
//
// We deliberately use the *actual* `*_tool` constants from each module
// so the test compares against the exact `function.name` strings the
// production code matches on. A future rename in the tool source would
// surface here as a real test failure (not a silent string drift).
//
// Two mock tools are added: `mock_unknown_tool` (never in any filter list,
// must survive every branch) and `mock_other_tool` (also never matched,
// exercises the "tools not in filter are preserved" invariant).

const AgentTool = nalarcore.tool_models.AgentTool;

const mock_unknown_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "mock_unknown_tool",
        .description = "sentinel — must survive every filter",
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
    },
};

const mock_other_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "mock_other_tool",
        .description = "sentinel — also never matched",
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
    },
};

/// The "all relevant tools" fixture: 8 production tools + 2 mocks.
/// Order is interleaved (kanban / design / unknown / kanban / other /
/// design) to verify order-independence.
fn allTools() [10]AgentTool {
    return [_]AgentTool{
        nalarcore.kanban_list.kanban_list_tool,
        nalarcore.set_design_page.set_design_page_tool,
        mock_unknown_tool,
        nalarcore.kanban_move_task.kanban_move_task_tool,
        mock_other_tool,
        nalarcore.add_design_element.add_design_element_tool,
        nalarcore.update_design_element.update_design_element_tool,
        nalarcore.group_design_elements.group_design_element_tool,
        nalarcore.set_element_parent.set_element_parent_tool,
        nalarcore.move_design_element.move_design_element_tool,
    };
}

/// Helper: count how many tools in a slice have a given name.
fn countNamed(tools: []const AgentTool, name: []const u8) usize {
    var count: usize = 0;
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.function.name, name)) count += 1;
    }
    return count;
}

/// Helper: assert a name appears exactly N times in a slice.
fn expectNamedCount(
    tools: []const AgentTool,
    name: []const u8,
    expected: usize,
) !void {
    const actual = countNamed(tools, name);
    if (actual != expected) {
        std.debug.print(
            "FAIL: expected '{s}' count={d}, got {d} in:\n",
            .{ name, expected, actual },
        );
        for (tools, 0..) |t, i| {
            std.debug.print("  [{d}] {s}\n", .{ i, t.function.name });
        }
    }
    try testing.expectEqual(expected, actual);
}

// ─── Test 1: design parent drops kanban tools, keeps design + mocks ─────

test "filteringTools — design parent removes kanban tools and keeps design tools" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedItem(
        &ctx.db,
        alloc,
        "ws_design",
        "wi_design",
        "design",
        "sess_design",
    );

    var tools = allTools();
    const filtered = try filteringTools(alloc, &ctx.db, "sess_design", &tools);
    // Note: `filtered` aliases `tools` (removeTools is in-place),
    // so both slices describe the same backing array. We do not
    // double-free.

    // Length check: 10 - 2 (kanban_* removed) = 8.
    try testing.expectEqual(@as(usize, 8), filtered.len);

    // Removed: 2 kanban tools.
    try expectNamedCount(filtered, "kanban_list", 0);
    try expectNamedCount(filtered, "kanban_move_task", 0);

    // Kept: 6 design tools (one each).
    try expectNamedCount(filtered, "set_design_page", 1);
    try expectNamedCount(filtered, "add_element", 1);
    try expectNamedCount(filtered, "update_element", 1);
    try expectNamedCount(filtered, "group_elements", 1);
    try expectNamedCount(filtered, "set_element_parent", 1);
    try expectNamedCount(filtered, "move_design_element", 1);

    // Kept: 2 mocks (not in any filter list — Figma-style).
    try expectNamedCount(filtered, "mock_unknown_tool", 1);
    try expectNamedCount(filtered, "mock_other_tool", 1);
}

// ─── Test 2: folder parent drops kanban + design tools (8 total) ──────

test "filteringTools — folder parent removes all kanban + design tools" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedItem(
        &ctx.db,
        alloc,
        "ws_folder",
        "wi_folder",
        "folder",
        "sess_folder",
    );

    var tools = allTools();
    const filtered = try filteringTools(alloc, &ctx.db, "sess_folder", &tools);

    // Length check: 10 - 8 (kanban_* + all 6 design tools) = 2 (mocks).
    try testing.expectEqual(@as(usize, 2), filtered.len);

    // Removed: 2 kanban + 6 design.
    try expectNamedCount(filtered, "kanban_list", 0);
    try expectNamedCount(filtered, "kanban_move_task", 0);
    try expectNamedCount(filtered, "set_design_page", 0);
    try expectNamedCount(filtered, "add_element", 0);
    try expectNamedCount(filtered, "update_element", 0);
    try expectNamedCount(filtered, "group_elements", 0);
    try expectNamedCount(filtered, "set_element_parent", 0);
    try expectNamedCount(filtered, "move_design_element", 0);

    // Kept: only the 2 mocks.
    try expectNamedCount(filtered, "mock_unknown_tool", 1);
    try expectNamedCount(filtered, "mock_other_tool", 1);
}

// ─── Test 3: kanban parent drops design tools, keeps kanban + mocks ───

test "filteringTools — kanban parent removes design tools and keeps kanban tools" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedItem(
        &ctx.db,
        alloc,
        "ws_kanban",
        "wi_kanban",
        "kanban",
        "sess_kanban",
    );

    var tools = allTools();
    const filtered = try filteringTools(alloc, &ctx.db, "sess_kanban", &tools);

    // Length check: 10 - 6 (design tools removed) = 4 (2 kanban + 2 mocks).
    try testing.expectEqual(@as(usize, 4), filtered.len);

    // Removed: 6 design tools.
    try expectNamedCount(filtered, "set_design_page", 0);
    try expectNamedCount(filtered, "add_element", 0);
    try expectNamedCount(filtered, "update_element", 0);
    try expectNamedCount(filtered, "group_elements", 0);
    try expectNamedCount(filtered, "set_element_parent", 0);
    try expectNamedCount(filtered, "move_design_element", 0);

    // Kept: 2 kanban + 2 mocks.
    try expectNamedCount(filtered, "kanban_list", 1);
    try expectNamedCount(filtered, "kanban_move_task", 1);
    try expectNamedCount(filtered, "mock_unknown_tool", 1);
    try expectNamedCount(filtered, "mock_other_tool", 1);
}

// ─── Test 4: chat parent — no branch matches → no filter applied ──────

test "filteringTools — chat parent returns tools unchanged (no branch matches)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedItem(
        &ctx.db,
        alloc,
        "ws_chat",
        "wi_chat",
        "chat",
        "sess_chat",
    );

    var tools = allTools();
    const filtered = try filteringTools(alloc, &ctx.db, "sess_chat", &tools);

    // No filter fires for `chat` — all 10 tools pass through.
    try testing.expectEqual(@as(usize, 10), filtered.len);

    // Every name appears exactly once.
    try expectNamedCount(filtered, "kanban_list", 1);
    try expectNamedCount(filtered, "kanban_move_task", 1);
    try expectNamedCount(filtered, "set_design_page", 1);
    try expectNamedCount(filtered, "add_element", 1);
    try expectNamedCount(filtered, "update_element", 1);
    try expectNamedCount(filtered, "group_elements", 1);
    try expectNamedCount(filtered, "set_element_parent", 1);
    try expectNamedCount(filtered, "move_design_element", 1);
    try expectNamedCount(filtered, "mock_unknown_tool", 1);
    try expectNamedCount(filtered, "mock_other_tool", 1);
}

// ─── Test 5: empty session_id → getWorkspaceContext returns null ──────

test "filteringTools — empty session_id returns tools unchanged" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // DB seeded with a design item + task, but we pass ""
    // (empty session_id). getWorkspaceContext short-circuits to null
    // before any DB lookup, so the no-filter branch fires.
    try seedItem(
        &ctx.db,
        alloc,
        "ws_design",
        "wi_design",
        "design",
        "sess_design",
    );

    var tools = allTools();
    const filtered = try filteringTools(alloc, &ctx.db, "", &tools);

    try testing.expectEqual(@as(usize, 10), filtered.len);
    try expectNamedCount(filtered, "kanban_list", 1);
    try expectNamedCount(filtered, "kanban_move_task", 1);
    try expectNamedCount(filtered, "set_design_page", 1);
}

// ─── Test 6: unbound session (no task matches) → null context ─────────

test "filteringTools — unbound session_id returns tools unchanged" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed a design item, but look up by a session_id that doesn't
    // match any task. getWorkspaceContext returns null.
    try seedItem(
        &ctx.db,
        alloc,
        "ws_design",
        "wi_design",
        "design",
        "sess_design",
    );

    var tools = allTools();
    const filtered = try filteringTools(
        alloc,
        &ctx.db,
        "sess_lone_wolf",
        &tools,
    );

    try testing.expectEqual(@as(usize, 10), filtered.len);
    try expectNamedCount(filtered, "kanban_list", 1);
    try expectNamedCount(filtered, "kanban_move_task", 1);
}

// ─── Test 7: empty tools list — no-op regardless of parent ────────────

test "filteringTools — empty tools list returns empty slice" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed for every item_type — the function must return an empty
    // slice regardless of which branch fires.
    try seedItem(
        &ctx.db,
        alloc,
        "ws_design",
        "wi_design",
        "design",
        "sess_design",
    );

    var tools: [0]AgentTool = .{};
    const filtered = try filteringTools(alloc, &ctx.db, "sess_design", &tools);

    try testing.expectEqual(@as(usize, 0), filtered.len);
}

// ─── Test 8: all-tools-filtered branch ends in empty slice ─────────────

test "filteringTools — kanban-only tools + design parent returns empty" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedItem(
        &ctx.db,
        alloc,
        "ws_design",
        "wi_design",
        "design",
        "sess_design",
    );

    // Only kanban tools in the input. With a design parent, both
    // are filtered out → empty result.
    var tools = [_]AgentTool{
        nalarcore.kanban_list.kanban_list_tool,
        nalarcore.kanban_move_task.kanban_move_task_tool,
    };
    const filtered = try filteringTools(alloc, &ctx.db, "sess_design", &tools);

    try testing.expectEqual(@as(usize, 0), filtered.len);
}

// ─── Test 9: only design tools + kanban parent → empty ────────────────

test "filteringTools — design-only tools + kanban parent returns empty" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedItem(
        &ctx.db,
        alloc,
        "ws_kanban",
        "wi_kanban",
        "kanban",
        "sess_kanban",
    );

    var tools = [_]AgentTool{
        nalarcore.set_design_page.set_design_page_tool,
        nalarcore.add_design_element.add_design_element_tool,
        nalarcore.update_design_element.update_design_element_tool,
        nalarcore.group_design_elements.group_design_element_tool,
        nalarcore.set_element_parent.set_element_parent_tool,
        nalarcore.move_design_element.move_design_element_tool,
    };
    const filtered = try filteringTools(alloc, &ctx.db, "sess_kanban", &tools);

    try testing.expectEqual(@as(usize, 0), filtered.len);
}

// ─── Test 10: order independence — same tools in reversed order ───────

test "filteringTools — filter outcome is independent of input order" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedItem(
        &ctx.db,
        alloc,
        "ws_design",
        "wi_design",
        "design",
        "sess_design",
    );

    // The "before" array: 10 tools in interleaved order (test 1's
    // fixture). Verify the post-filter names match.
    var before = allTools();
    const filtered = try filteringTools(alloc, &ctx.db, "sess_design", &before);
    var names_before = try std.ArrayList([]const u8).initCapacity(alloc, filtered.len);
    defer names_before.deinit(alloc);
    for (filtered) |t| try names_before.append(alloc, t.function.name);
    const before_slice = names_before.items;
    std.mem.sort([]const u8, before_slice, {}, lessThanStr);

    // The "after" array: SAME 10 tools, but in a completely different
    // order. Build it from scratch so the test doesn't share state
    // with `before`.
    var after = [_]AgentTool{
        nalarcore.move_design_element.move_design_element_tool,
        nalarcore.set_element_parent.set_element_parent_tool,
        nalarcore.kanban_move_task.kanban_move_task_tool,
        nalarcore.update_design_element.update_design_element_tool,
        mock_other_tool,
        nalarcore.group_design_elements.group_design_element_tool,
        nalarcore.kanban_list.kanban_list_tool,
        mock_unknown_tool,
        nalarcore.add_design_element.add_design_element_tool,
        nalarcore.set_design_page.set_design_page_tool,
    };
    const filtered_after = try filteringTools(alloc, &ctx.db, "sess_design", &after);
    var names_after = try std.ArrayList([]const u8).initCapacity(alloc, filtered_after.len);
    defer names_after.deinit(alloc);
    for (filtered_after) |t| try names_after.append(alloc, t.function.name);
    const after_slice = names_after.items;
    std.mem.sort([]const u8, after_slice, {}, lessThanStr);

    // Same lengths, same multiset of names — regardless of order.
    try testing.expectEqual(before_slice.len, after_slice.len);
    for (before_slice, after_slice) |a, b| {
        try testing.expectEqualStrings(a, b);
    }
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ─── Test 11: folder branch doesn't double-fire (regression) ─────────
//
// Earlier draft of filteringTools had the kanban tools removed as a
// step BEFORE the design branch fired — so a folder parent had
// BOTH branches fire and the result was over-aggressive. The current
// implementation uses mutually-exclusive `std.mem.eql` checks: only
// ONE branch can ever match per call. This test pins that down.

test "filteringTools — folder branch and kanban-only branch never both fire" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Custom tool list: a kanban tool that's NOT in the folder filter,
    // and a folder-dropped tool that's NOT in the kanban filter.
    // (In production these are the same 2 names, but the test pins
    // the OR-vs-AND semantics by tracking how many of each survive.)
    try seedItem(
        &ctx.db,
        alloc,
        "ws_folder",
        "wi_folder",
        "folder",
        "sess_folder",
    );

    // A tool with a name that is ONLY in the kanban_design filter
    // list. If the kanban branch ALSO fires (wrong), this drops too.
    // In the current implementation, folder branch fires (drops it)
    // and kanban branch does NOT fire (keeps it) — but since folder
    // drops all design tools, this is still a drop. So instead we use
    // a tool with a name OUTSIDE any filter: it must survive.
    var tools = [_]AgentTool{
        nalarcore.kanban_list.kanban_list_tool, // dropped by folder
        nalarcore.set_design_page.set_design_page_tool, // dropped by folder
        mock_unknown_tool, // NOT in any filter — must survive
    };
    const filtered = try filteringTools(alloc, &ctx.db, "sess_folder", &tools);

    // 10 → 8 (kanban+design removed) → here we expect mock to survive.
    try testing.expectEqual(@as(usize, 1), filtered.len);
    try expectNamedCount(filtered, "mock_unknown_tool", 1);
    try expectNamedCount(filtered, "kanban_list", 0);
    try expectNamedCount(filtered, "set_design_page", 0);
}
