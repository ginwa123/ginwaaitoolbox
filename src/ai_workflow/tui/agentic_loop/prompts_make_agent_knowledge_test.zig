//! Behavioural tests for `prompts_make_agent_knowledge.zig`.
//!
//! Plan: docs/superpowers/plans/2026-08-15-agent-mode.md (Task 10)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const make_agent_knowledge = @import("prompts_make_agent_knowledge.zig");
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
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    workspace_item_id TEXT,
        \\    created_at DATETIME,
        \\    updated_at DATETIME,
        \\    task_type TEXT DEFAULT 'standard'
        \\)
    , &.{});
    try Migration076.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

fn insertWorkspaceItem(ctx: *TestCtx, id: []const u8, item_type: []const u8) !void {
    try ctx.db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES (?, 'ws_1', ?, 'Test', '/tmp', 0)",
        &[_][]const u8{ id, item_type },
    );
}

fn insertSession(ctx: *TestCtx, session_id: []const u8, workspace_item_id: []const u8) !void {
    try ctx.db.exec(testing.allocator,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, created_at, updated_at, task_type) VALUES (?, 'Test Task', ?, datetime('now'), datetime('now'), 'standard')",
        &[_][]const u8{ session_id, workspace_item_id },
    );
}

fn insertKnowledge(ctx: *TestCtx, id: []const u8, agent_id: []const u8, file_path: []const u8, position: i64) !void {
    var sql_buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrint(
        &sql_buf,
        "INSERT INTO agent_knowledge (id, agent_id, file_path, position) VALUES ('{s}', '{s}', '{s}', {d})",
        .{ id, agent_id, file_path, position },
    );
    try ctx.db.exec(testing.allocator, sql, &.{});
}

/// Helper: write a test file with given contents to a unique /tmp path.
/// Uses an atomic counter so each call gets a unique path (multiple
/// files in one test don't collide).
var test_file_counter: std.atomic.Value(u64) = .init(0);
fn writeTestFile(allocator: std.mem.Allocator, io: std.Io, contents: []const u8) ![]u8 {
    const n = test_file_counter.fetchAdd(1, .seq_cst);
    const path = try std.fmt.allocPrint(allocator, "/tmp/test_agent_knowledge_{d}.md", .{n});
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer std.Io.File.close(file, io);
    try std.Io.File.writeStreamingAll(file, io, contents);
    return path;
}

test "makeAgentKnowledge: returns empty slice when session_id is empty" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try make_agent_knowledge.makeAgentKnowledge(alloc, ctx.threaded.io(), &ctx.db, "");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentKnowledge: returns empty slice when session doesn't exist" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try make_agent_knowledge.makeAgentKnowledge(alloc, ctx.threaded.io(), &ctx.db, "non_existent_session");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentKnowledge: returns empty slice when workspace_item is not an agent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "kanban");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    const result = try make_agent_knowledge.makeAgentKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentKnowledge: returns empty slice when agent has no knowledge rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    const result = try make_agent_knowledge.makeAgentKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentKnowledge: returns ## Agent Knowledge section with file contents for valid entries" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    const tmp_path = try writeTestFile(alloc, ctx.threaded.io(), "# Test Knowledge\n\nThis file contains agent instructions.\n");
    defer alloc.free(tmp_path);
    defer std.Io.Dir.deleteFileAbsolute(ctx.threaded.io(), tmp_path) catch {};

    try insertKnowledge(&ctx, "know_1", "ws_item_1", tmp_path, 0);

    const result = try make_agent_knowledge.makeAgentKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "## Agent Knowledge") != null);
    try testing.expect(std.mem.indexOf(u8, result, "# Test Knowledge") != null);
    try testing.expect(std.mem.indexOf(u8, result, "agent instructions") != null);
}

test "makeAgentKnowledge: respects position DESC ordering" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    const path_low = try writeTestFile(alloc, ctx.threaded.io(), "content_low_marker\n");
    defer alloc.free(path_low);
    defer std.Io.Dir.deleteFileAbsolute(ctx.threaded.io(), path_low) catch {};
    const path_high = try writeTestFile(alloc, ctx.threaded.io(), "content_high_marker\n");
    defer alloc.free(path_high);
    defer std.Io.Dir.deleteFileAbsolute(ctx.threaded.io(), path_high) catch {};

    try insertKnowledge(&ctx, "know_low", "ws_item_1", path_low, 0);
    try insertKnowledge(&ctx, "know_high", "ws_item_1", path_high, 100);

    const result = try make_agent_knowledge.makeAgentKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    const high_idx = std.mem.indexOf(u8, result, "content_high_marker") orelse return error.MarkerNotFound;
    const low_idx = std.mem.indexOf(u8, result, "content_low_marker") orelse return error.MarkerNotFound;
    try testing.expect(high_idx < low_idx);
}

test "makeAgentKnowledge: skips unreadable file paths with logged warning" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    // Point at a path that does not exist.
    try insertKnowledge(&ctx, "know_1", "ws_item_1", "/tmp/non_existent_path_xyz_12345.md", 0);

    const result = try make_agent_knowledge.makeAgentKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    // Section header IS still emitted, but the body is empty (file skipped).
    try testing.expect(std.mem.indexOf(u8, result, "## Agent Knowledge") != null);
    try testing.expect(std.mem.indexOf(u8, result, "non_existent_path_xyz_12345") == null);
}