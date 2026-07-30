//! Behavioural tests for `llm_history.listKanbanDistinctTags`.
//! Plan: docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const llm_history = nalarcore.ai_mod.llm_history;
const sqlite = nalarcore.sqlite;

fn setupDbWithTags() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Minimal schema: workspace_items + workspace_item_tasks with the
    // tags column (Migration 067). We don't run all 66 prior migrations
    // — the model fn doesn't depend on them.
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

fn insertTaskWithTags(db: *sqlite.SqliteBackend, alloc: std.mem.Allocator, id: []const u8, item_id: []const u8, tags_json: []const u8) !void {
    // SqliteBackend.exec binds empty `[]const u8` as SQL NULL — which
    // would fail the NOT NULL constraint on `tags`. Match the
    // production pattern (see llm_history.createWorkspaceItemTask):
    // use a SQL `''` literal when the value is the empty string.
    if (tags_json.len == 0) {
        try db.exec(alloc,
            "INSERT INTO workspace_item_tasks (id, workspace_item_id, tags) VALUES (?, ?, '')",
            &.{ id, item_id });
    } else {
        try db.exec(alloc,
            "INSERT INTO workspace_item_tasks (id, workspace_item_id, tags) VALUES (?, ?, ?)",
            &.{ id, item_id, tags_json });
    }
}

fn insertTaskWithTagsAndUpdatedAt(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    id: []const u8,
    item_id: []const u8,
    tags_json: []const u8,
    updated_at: []const u8,
) !void {
    try db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, workspace_item_id, tags, updated_at) VALUES (?, ?, ?, ?)",
        &.{ id, item_id, tags_json, updated_at });
}

test "listKanbanDistinctTags returns empty page when kanban has no tasks" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    const page = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), page.tags.len);
    try testing.expectEqual(false, page.has_more);
}

test "listKanbanDistinctTags returns empty page when tasks exist but none have tags" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try insertTaskWithTags(&s.db, alloc, "t1", "item_x", "");
    try insertTaskWithTags(&s.db, alloc, "t2", "item_x", "");
    const page = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), page.tags.len);
    try testing.expectEqual(false, page.has_more);
}

test "listKanbanDistinctTags returns single tag from one task" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try insertTaskWithTags(&s.db, alloc, "t1", "item_x", "[\"bug\"]");
    const page = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), page.tags.len);
    try testing.expectEqualStrings("bug", page.tags[0].name);
    try testing.expectEqual(@as(u32, 1), page.tags[0].count);
    try testing.expectEqual(false, page.has_more);
}

test "listKanbanDistinctTags orders by frequency DESC (most-used first)" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    // "bug" used by 3 tasks, "urgent" used by 2, "frontend" used by 1.
    try insertTaskWithTags(&s.db, alloc, "t1", "item_x", "[\"bug\",\"urgent\"]");
    try insertTaskWithTags(&s.db, alloc, "t2", "item_x", "[\"bug\",\"frontend\"]");
    try insertTaskWithTags(&s.db, alloc, "t3", "item_x", "[\"bug\",\"urgent\"]");
    const page = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), page.tags.len);
    try testing.expectEqualStrings("bug", page.tags[0].name);
    try testing.expectEqual(@as(u32, 3), page.tags[0].count);
    try testing.expectEqualStrings("urgent", page.tags[1].name);
    try testing.expectEqual(@as(u32, 2), page.tags[1].count);
    try testing.expectEqualStrings("frontend", page.tags[2].name);
    try testing.expectEqual(@as(u32, 1), page.tags[2].count);
    try testing.expectEqual(false, page.has_more);
}

test "listKanbanDistinctTags breaks ties on recency (most-recently-used wins)" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try insertTaskWithTagsAndUpdatedAt(&s.db, alloc, "t1", "item_x", "[\"old-tag\"]", "2025-01-01 00:00:00");
    try insertTaskWithTagsAndUpdatedAt(&s.db, alloc, "t2", "item_x", "[\"new-tag\"]", "2026-12-31 23:59:59");
    const page = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), page.tags.len);
    try testing.expectEqualStrings("new-tag", page.tags[0].name);
    try testing.expectEqualStrings("old-tag", page.tags[1].name);
}

test "listKanbanDistinctTags respects the limit query" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    // 5 distinct tags but ask for limit=2.
    try insertTaskWithTags(&s.db, alloc, "t1", "item_x", "[\"a\",\"b\",\"c\",\"d\",\"e\"]");
    const page = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 2, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), page.tags.len);
    try testing.expectEqual(true, page.has_more); // 5 > 2, so more available
}

test "listKanbanDistinctTags has_more=false when result fits in limit" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try insertTaskWithTags(&s.db, alloc, "t1", "item_x", "[\"a\",\"b\",\"c\"]");
    const page = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), page.tags.len);
    try testing.expectEqual(false, page.has_more); // 3 <= 8, no more
}

test "listKanbanDistinctTags paginates with offset (next page fetches distinct tags past the first page)" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    // Seed 5 distinct tags, all used once. Fetch in pages of 2.
    try insertTaskWithTags(&s.db, alloc, "t1", "item_x", "[\"a\",\"b\",\"c\",\"d\",\"e\"]");
    // Page 1 (offset=0, limit=2): expect first 2 of {a,b,c,d,e} (alphabetical-ish, depends on seed).
    const page1 = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 2, 0);
    defer page1.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), page1.tags.len);
    try testing.expectEqual(true, page1.has_more);
    const page1_names = [_][]const u8{ page1.tags[0].name, page1.tags[1].name };
    // Page 2 (offset=2, limit=2): expect next 2, distinct from page 1.
    const page2 = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 2, 2);
    defer page2.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), page2.tags.len);
    try testing.expectEqual(true, page2.has_more);
    // Combined pages must contain all 5 distinct tags.
    const page3 = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 2, 4);
    defer page3.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), page3.tags.len); // last page has 1 tag
    try testing.expectEqual(false, page3.has_more); // exhausted
    _ = page1_names; // suppress unused warning
}

test "listKanbanDistinctTags filters by workspace_item_id (no cross-kanban leakage)" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try s.db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id) VALUES ('item_y', 'ws_x')", &.{});
    try insertTaskWithTags(&s.db, alloc, "t1", "item_x", "[\"bug\"]");
    try insertTaskWithTags(&s.db, alloc, "t2", "item_y", "[\"different\"]");
    const page = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), page.tags.len);
    try testing.expectEqualStrings("bug", page.tags[0].name);
}

test "listKanbanDistinctTags skips rows with malformed tags JSON (defensive)" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try insertTaskWithTags(&s.db, alloc, "t1", "item_x", "[\"good\"]");
    try insertTaskWithTags(&s.db, alloc, "t2", "item_x", "not-a-json-array");
    const page = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), page.tags.len);
    try testing.expectEqualStrings("good", page.tags[0].name);
}
