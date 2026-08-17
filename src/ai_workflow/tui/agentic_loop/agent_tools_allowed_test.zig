//! Behavioural tests for `agent_tools_allowed.zig`.
//!
//! The helper is the runtime filter's input: it resolves the enabled
//! tool names for the agent bound to a workspace_item. The runtime
//! filter at `workflow.zig:1478` then takes that list and builds the
//! allowlist string passed to `WorkflowArgs.allowed_tools`.
//!
//! Secure-by-default semantics (spec D1): the helper returns an empty
//! slice (NOT an error) when:
//!   - workspace_item_id doesn't exist
//!   - workspace_items.item_type != 'agent'
//!   - the agent has no rows in agent_tools
//!
//! Callers MUST treat an empty slice as "no tools" — NOT as "all tools".
//!
//! Plan: docs/superpowers/plans/2026-08-15-agent-mode.md (Task 3)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const agent_tools_allowed = @import("agent_tools_allowed.zig");
const Migration076 = @import("../../../migrations/migration.zig").Migration076AddAgentsAndAgentKnowledgeAndAgentTools;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    // Migration 076 depends on workspace_items existing. The migration
    // doesn't CREATE workspace_items (it adds FKs against it), so we
    // must create it here.
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT,
        \\    item_type TEXT,
        \\    name TEXT,
        \\    path TEXT,
        \\    position INTEGER,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    try Migration076.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

/// Helper: insert a workspace_items row with the given item_type.
fn insertWorkspaceItem(ctx: *TestCtx, id: []const u8, item_type: []const u8) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES (?, 'ws_1', ?, 'Test', '/tmp', 0)",
        &[_][]const u8{ id, item_type },
    );
}

/// Helper: insert an agents row pointing at the given workspace_item_id.
fn insertAgent(ctx: *TestCtx, agent_id: []const u8, workspace_item_id: []const u8) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id) VALUES (?, ?)",
        &[_][]const u8{ agent_id, workspace_item_id },
    );
}

/// Helper: insert an agent_tools row. `enabled` is hardcoded via two
/// SQL branches (the `?` parameter binding for u8 was failing the slice
/// coercion in earlier iterations — keeping it simple).
fn insertTool(ctx: *TestCtx, tool_id: []const u8, agent_id: []const u8, tool_name: []const u8, enabled: u8) !void {
    const alloc = testing.allocator;
    const enabled_str: []const u8 = if (enabled == 1) "1" else "0";
    var sql_buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrint(
        &sql_buf,
        "INSERT INTO agent_tools (id, agent_id, tool_name, enabled) VALUES ('{s}', '{s}', '{s}', {s})",
        .{ tool_id, agent_id, tool_name, enabled_str },
    );
    try ctx.db.exec(alloc, sql, &.{});
}

test "agentToolsAllowed: returns empty slice when workspace_item_id doesn't exist" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try agent_tools_allowed.agentToolsAllowed(alloc, &ctx.db, "non_existent_item");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "agentToolsAllowed: returns empty slice when workspace_items.item_type != 'agent'" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_kanban", "kanban");

    const result = try agent_tools_allowed.agentToolsAllowed(alloc, &ctx.db, "ws_item_kanban");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "agentToolsAllowed: returns empty slice when agent has no rows in agent_tools (secure-by-default)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertAgent(&ctx, "agent_1", "ws_item_1");
    // No rows in agent_tools — secure-by-default returns empty slice.

    const result = try agent_tools_allowed.agentToolsAllowed(alloc, &ctx.db, "ws_item_1");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "agentToolsAllowed: returns enabled tool_name list when agent has rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Per spec D3: agents.id == workspace_item_id. Both rows share the
    // workspace_item's id string ("ws_item_1") — this is what
    // workspace_items_create_agent will insert in production.
    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertAgent(&ctx, "ws_item_1", "ws_item_1");
    try insertTool(&ctx, "at_bash", "ws_item_1", "bash", 1);
    try insertTool(&ctx, "at_read", "ws_item_1", "read_file", 1);
    try insertTool(&ctx, "at_write", "ws_item_1", "write_file", 1);

    const result = try agent_tools_allowed.agentToolsAllowed(alloc, &ctx.db, "ws_item_1");
    defer {
        for (result) |n| alloc.free(n);
        alloc.free(result);
    }
    try testing.expectEqual(@as(usize, 3), result.len);
    // The query orders by tool_name ASC; verify the order.
    try testing.expectEqualStrings("bash", result[0]);
    try testing.expectEqualStrings("read_file", result[1]);
    try testing.expectEqualStrings("write_file", result[2]);
}

test "agentToolsAllowed: skips rows where enabled = 0" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // agents.id == workspace_item_id (D3).
    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertAgent(&ctx, "ws_item_1", "ws_item_1");
    try insertTool(&ctx, "at_bash", "ws_item_1", "bash", 1);
    try insertTool(&ctx, "at_read", "ws_item_1", "read_file", 0); // disabled

    const result = try agent_tools_allowed.agentToolsAllowed(alloc, &ctx.db, "ws_item_1");
    defer {
        for (result) |n| alloc.free(n);
        alloc.free(result);
    }
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("bash", result[0]);
}