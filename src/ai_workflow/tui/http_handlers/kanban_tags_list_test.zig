//! Behavioural tests for `kanbanTagsListUseCase`.
//! Plan: docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const handler = @import("kanban_tags_list.zig");

fn setupDbWithTags() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL)", &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT NOT NULL,
        \\  updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        \\  tags TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id) VALUES ('item_x', 'ws_x')", &.{});
    return .{ .db = db, .threaded = threaded };
}

test "useCase returns empty tags array + has_more=false for kanban with no tasks" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const result = try handler.useCase(testing.allocator, &s.db, .{
        .workspace_item_id = "item_x",
        .limit = 8,
        .offset = 0,
    });
    defer testing.allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("tags").?.array.items.len == 0);
    try testing.expect(parsed.value.object.get("has_more").?.bool == false);
}

test "useCase paginates: limit=2 returns 2 tags + has_more=true when 5 distinct tags exist" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, tags) VALUES ('t1', 'item_x', '[\"a\",\"b\",\"c\",\"d\",\"e\"]')", &.{});
    const result = try handler.useCase(alloc, &s.db, .{
        .workspace_item_id = "item_x",
        .limit = 2,
        .offset = 0,
    });
    defer alloc.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.object.get("tags").?.array.items.len);
    try testing.expect(parsed.value.object.get("has_more").?.bool == true);
}

test "useCase returns has_more=false on the last page" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, tags) VALUES ('t1', 'item_x', '[\"a\",\"b\",\"c\"]')", &.{});
    const result = try handler.useCase(alloc, &s.db, .{
        .workspace_item_id = "item_x",
        .limit = 2,
        .offset = 2,
    });
    defer alloc.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.object.get("tags").?.array.items.len);
    try testing.expect(parsed.value.object.get("has_more").?.bool == false);
}

test "useCase combines with offset to skip past the first page" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, tags) VALUES ('t1', 'item_x', '[\"a\",\"b\",\"c\",\"d\",\"e\"]')", &.{});
    const page1 = try handler.useCase(alloc, &s.db, .{
        .workspace_item_id = "item_x",
        .limit = 2,
        .offset = 0,
    });
    defer alloc.free(page1);
    const page2 = try handler.useCase(alloc, &s.db, .{
        .workspace_item_id = "item_x",
        .limit = 2,
        .offset = 2,
    });
    defer alloc.free(page2);
    const p1 = try std.json.parseFromSlice(std.json.Value, alloc, page1, .{});
    defer p1.deinit();
    const p2 = try std.json.parseFromSlice(std.json.Value, alloc, page2, .{});
    defer p2.deinit();
    const p1_name = p1.value.object.get("tags").?.array.items[0].object.get("name").?.string;
    const p2_name = p2.value.object.get("tags").?.array.items[0].object.get("name").?.string;
    try testing.expect(!std.mem.eql(u8, p1_name, p2_name));
}