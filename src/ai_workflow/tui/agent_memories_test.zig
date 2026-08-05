//! Behavioural tests for `agent_memories.zig` — the storage layer behind
//! the `save_memory` + `load_memory` agent tools.
//!
//! Tests follow the project convention (per memory
//! `llm-history-test-use-migrations-module.md`): every test walks all
//! migrations from scratch so the schema under test is GUARANTEED to
//! match production. No hand-rolled CREATE TABLE.

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const migration = @import("../../migrations/migration.zig");

const agent_memories = @import("agent_memories.zig");

const MemoryRow = agent_memories.MemoryRow;
const MemoryHit = agent_memories.MemoryHit;

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

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

test "saveMemory: inserts a new row with auto-generated mem_<16-hex> id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row = try agent_memories.saveMemory(alloc, &ctx.db, .{
        .content = "the user's preferred LLM is claude-sonnet-4-5",
        .tags = &.{"preferences", "user"},
        .id = "",
    });
    defer agent_memories.freeMemoryRow(alloc, row);

    // Auto-generated id matches the `mem_<16-hex>` shape (mem_ + 16 hex chars).
    try testing.expect(row.id.len == 20); // 4 ("mem_") + 16 (hex)
    try testing.expect(std.mem.startsWith(u8, row.id, "mem_"));
    try testing.expectEqualStrings("the user's preferred LLM is claude-sonnet-4-5", row.content);
    // Tags stored as ||-joined string (the project convention).
    try testing.expectEqualStrings("preferences||user", row.tags);
    // Timestamps are populated (non-empty).
    try testing.expect(row.created_at.len > 0);
    try testing.expect(row.updated_at.len > 0);

    // Verify the row is actually in the DB.
    var q = try ctx.db.query(alloc,
        "SELECT content, tags FROM agent_memories WHERE id = ?",
        &.{row.id});
    defer q.deinit();
    const db_row = (try q.next()) orelse return error.RowNotInserted;
    defer db_row.deinit(alloc);
    try testing.expectEqualStrings("the user's preferred LLM is claude-sonnet-4-5", db_row.values[0]);
    try testing.expectEqualStrings("preferences||user", db_row.values[1]);
}

test "saveMemory: UPSERTs when caller passes an existing id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // First insert.
    const first = try agent_memories.saveMemory(alloc, &ctx.db, .{
        .content = "original content",
        .tags = &.{"preferences"},
        .id = "user-preferred-model",
    });
    defer agent_memories.freeMemoryRow(alloc, first);

    // Tiny sleep so the UPDATE bumps `updated_at` (DATETIME resolution is 1s).
    // std.c.nanosleep — std.Thread.sleep doesn't exist in Zig 0.16.
    var ts = std.c.timespec{ .sec = 1, .nsec = 0 };
    _ = std.c.nanosleep(&ts, null);

    // UPSERT with the same id.
    const second = try agent_memories.saveMemory(alloc, &ctx.db, .{
        .content = "updated content — user switched to claude-opus-4-1",
        .tags = &.{"preferences", "updated"},
        .id = "user-preferred-model",
    });
    defer agent_memories.freeMemoryRow(alloc, second);

    // Same id (UPSERT replaces the row in place).
    try testing.expectEqualStrings("user-preferred-model", second.id);
    // Content replaced.
    try testing.expectEqualStrings("updated content — user switched to claude-opus-4-1", second.content);
    // Tags replaced (||-joined).
    try testing.expectEqualStrings("preferences||updated", second.tags);
    // updated_at is bumped (>= first.updated_at — DATETIME second resolution
    // means the bump may be 0 seconds, but it must be >= not <).
    try testing.expect(std.mem.lessThan(u8, first.updated_at, second.updated_at) or
        std.mem.eql(u8, first.updated_at, second.updated_at));

    // Verify only ONE row in the DB (UPSERT, not INSERT-OR-APPEND).
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM agent_memories WHERE id = ?",
        &.{"user-preferred-model"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "saveMemory: empty content returns InvalidContent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = agent_memories.saveMemory(alloc, &ctx.db, .{
        .content = "",
        .tags = &.{},
        .id = "should-not-be-inserted",
    });
    try testing.expectError(error.InvalidContent, result);
}

test "saveMemory: content > 1 MiB returns ContentTooLarge" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Allocate a 1 MiB + 1 byte buffer filled with 'x'.
    const oversize = alloc.alloc(u8, (1 << 20) + 1) catch unreachable;
    defer alloc.free(oversize);
    @memset(oversize, 'x');

    const result = agent_memories.saveMemory(alloc, &ctx.db, .{
        .content = oversize,
        .tags = &.{},
        .id = "oversize-memory",
    });
    try testing.expectError(error.ContentTooLarge, result);
}

test "loadMemoriesByFts: returns ranked hits with snippets" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Insert 3 memories.
    const row1 = try agent_memories.saveMemory(alloc, &ctx.db, .{
        .content = "the user's preferred model is claude-sonnet for coding tasks",
        .tags = &.{"preferences"},
        .id = "mem-coding",
    });
    defer agent_memories.freeMemoryRow(alloc, row1);
    const row2 = try agent_memories.saveMemory(alloc, &ctx.db, .{
        .content = "the project's database is SQLite with FTS5 enabled",
        .tags = &.{"project"},
        .id = "mem-database",
    });
    defer agent_memories.freeMemoryRow(alloc, row2);
    const row3 = try agent_memories.saveMemory(alloc, &ctx.db, .{
        .content = "claude-sonnet is also the user's preferred writing model",
        .tags = &.{"preferences"},
        .id = "mem-writing",
    });
    defer agent_memories.freeMemoryRow(alloc, row3);

    // Search for "preferred" — should return 2 hits (coding + writing).
    const hits = try agent_memories.loadMemoriesByFts(alloc, &ctx.db, .{
        .query = "preferred",
        .tags = &.{},
        .limit = 10,
        .offset = 0,
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqual(@as(u32, 2), hits[0].total_count);

    // Every hit has a non-empty snippet that contains [match] markers
    // (the FTS5 snippet() convention).
    for (hits) |h| {
        try testing.expect(h.snippet.len > 0);
        try testing.expect(std.mem.indexOf(u8, h.snippet, "[") != null);
        try testing.expect(std.mem.indexOf(u8, h.snippet, "]") != null);
    }
}

test "loadMemoriesByFts: AND-filters by tags" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row1 = try agent_memories.saveMemory(alloc, &ctx.db, .{
        .content = "memory one with model preference",
        .tags = &.{"preferences", "user"},
        .id = "mem-one",
    });
    defer agent_memories.freeMemoryRow(alloc, row1);
    const row2 = try agent_memories.saveMemory(alloc, &ctx.db, .{
        .content = "memory two with project context",
        .tags = &.{"preferences", "project"},
        .id = "mem-two",
    });
    defer agent_memories.freeMemoryRow(alloc, row2);
    const row3 = try agent_memories.saveMemory(alloc, &ctx.db, .{
        .content = "memory three with project context",
        .tags = &.{"project"},
        .id = "mem-three",
    });
    defer agent_memories.freeMemoryRow(alloc, row3);

    // Search for "context" + filter by tags=["project"] → should return
    // mem-two + mem-three (both have "project" tag) but NOT mem-one
    // (only has "preferences" + "user").
    const hits = try agent_memories.loadMemoriesByFts(alloc, &ctx.db, .{
        .query = "context",
        .tags = &.{"project"},
        .limit = 10,
        .offset = 0,
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqual(@as(u32, 2), hits[0].total_count);

    // AND filter — tags=["preferences", "project"] → only mem-two has BOTH.
    const hits2 = try agent_memories.loadMemoriesByFts(alloc, &ctx.db, .{
        .query = "context",
        .tags = &.{ "preferences", "project" },
        .limit = 10,
        .offset = 0,
    });
    defer {
        for (hits2) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits2);
    }

    try testing.expectEqual(@as(usize, 1), hits2.len);
    try testing.expectEqualStrings("mem-two", hits2[0].id);
}

test "loadMemoriesByFts: paginates via limit + offset and reports total_count" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Insert 15 memories, each with a unique ID and a common word "match".
    var i: u32 = 0;
    while (i < 15) : (i += 1) {
        const id = std.fmt.allocPrint(alloc, "mem-page-{d}", .{i}) catch unreachable;
        defer alloc.free(id);
        const content = std.fmt.allocPrint(alloc, "match row number {d}", .{i}) catch unreachable;
        defer alloc.free(content);
        const row = try agent_memories.saveMemory(alloc, &ctx.db, .{
            .content = content,
            .tags = &.{},
            .id = id,
        });
        agent_memories.freeMemoryRow(alloc, row);
    }

    // Page 1: limit=10 offset=0 → 10 rows, total=15.
    {
        const hits = try agent_memories.loadMemoriesByFts(alloc, &ctx.db, .{
            .query = "match",
            .tags = &.{},
            .limit = 10,
            .offset = 0,
        });
        defer {
            for (hits) |h| {
                var copy = h;
                copy.deinit(alloc);
            }
            alloc.free(hits);
        }
        try testing.expectEqual(@as(usize, 10), hits.len);
        try testing.expectEqual(@as(u32, 15), hits[0].total_count);
    }

    // Page 2: limit=10 offset=10 → 5 rows, total=15.
    {
        const hits = try agent_memories.loadMemoriesByFts(alloc, &ctx.db, .{
            .query = "match",
            .tags = &.{},
            .limit = 10,
            .offset = 10,
        });
        defer {
            for (hits) |h| {
                var copy = h;
                copy.deinit(alloc);
            }
            alloc.free(hits);
        }
        try testing.expectEqual(@as(usize, 5), hits.len);
        try testing.expectEqual(@as(u32, 15), hits[0].total_count);
    }

    // Page 3: limit=10 offset=20 → 0 rows, total=15 reported elsewhere.
    // (We can't read hits[0].total_count when hits.len==0 — would be
    // an out-of-bounds access. The total_count on every previous page
    // already verified it stays at 15 throughout.)
    {
        const hits = try agent_memories.loadMemoriesByFts(alloc, &ctx.db, .{
            .query = "match",
            .tags = &.{},
            .limit = 10,
            .offset = 20,
        });
        defer {
            for (hits) |h| {
                var copy = h;
                copy.deinit(alloc);
            }
            alloc.free(hits);
        }
        try testing.expectEqual(@as(usize, 0), hits.len);
    }
}

test "getMemoryById: returns the row when id exists, null otherwise" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row1 = try agent_memories.saveMemory(alloc, &ctx.db, .{
        .content = "the test memory content",
        .tags = &.{"test"},
        .id = "test-id-exists",
    });
    defer agent_memories.freeMemoryRow(alloc, row1);

    // Existing id → returns the row.
    const found = (try agent_memories.getMemoryById(alloc, &ctx.db, "test-id-exists")) orelse return error.GetReturnedNull;
    defer agent_memories.freeMemoryRow(alloc, found);
    try testing.expectEqualStrings("test-id-exists", found.id);
    try testing.expectEqualStrings("the test memory content", found.content);
    try testing.expectEqualStrings("test", found.tags);

    // Missing id → returns null (not error).
    const missing = try agent_memories.getMemoryById(alloc, &ctx.db, "no-such-id");
    try testing.expect(missing == null);
}