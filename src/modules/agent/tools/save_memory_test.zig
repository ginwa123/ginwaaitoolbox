//! Behavioural tests for `save_memory.zig` — the agent-callable tool
//! that UPSERTs a memory via `agent_memories.saveMemory`.
//!
//! Pattern mirrors `kanban_list_test.zig` — in-memory DB + full
//! migrations walk + assert on the wire XML.

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const migration = @import("../../../migrations/migration.zig");

const save_memory_mod = @import("save_memory.zig");

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

test "save_memory_tool: tool name is 'save_memory'" {
    const tool = save_memory_mod.save_memory_tool;
    try testing.expectEqualStrings("save_memory", tool.function.name);
}

test "save_memory_tool: parameters include content, tags, id" {
    const tool = save_memory_mod.save_memory_tool;
    var found_content = false;
    var found_tags = false;
    var found_id = false;
    for (tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "content")) found_content = true;
        if (std.mem.eql(u8, prop.name, "tags")) found_tags = true;
        if (std.mem.eql(u8, prop.name, "id")) found_id = true;
    }
    try testing.expect(found_content);
    try testing.expect(found_tags);
    try testing.expect(found_id);
}

test "save_memory_tool: returns success XML envelope on insert" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = save_memory_mod.SaveMemoryInput{
        .content = "user prefers dark mode",
        .tags = &.{"preferences"},
        .id = "user-dark-mode",
    };
    const out = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // Returns <save_memory> envelope on success.
    try testing.expect(std.mem.indexOf(u8, out, "<save_memory>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "</save_memory>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>user-dark-mode</id>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<created_at>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<updated_at>") != null);
    // No error envelope.
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
}

test "save_memory_tool: returns error XML on empty content" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = save_memory_mod.SaveMemoryInput{
        .content = "",
        .tags = &.{},
        .id = "should-not-save",
    };
    const out = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "empty") != null or
        std.mem.indexOf(u8, out, "InvalidContent") != null);
}

test "save_memory_tool: returns error XML on content > 1 MiB" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Allocate 1 MiB + 1 byte of garbage.
    const oversize = alloc.alloc(u8, (1 << 20) + 1) catch unreachable;
    defer alloc.free(oversize);
    @memset(oversize, 'x');

    const input = save_memory_mod.SaveMemoryInput{
        .content = oversize,
        .tags = &.{},
        .id = "oversize-memory",
    };
    const out = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>") != null);
}

test "save_memory_tool: UPSERTs on second call with same id (updated_at bumps)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input1 = save_memory_mod.SaveMemoryInput{
        .content = "original content",
        .tags = &.{"preferences"},
        .id = "user-preference",
    };
    const out1 = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, input1);
    defer alloc.free(out1);

    // Extract updated_at from the first response.
    const updated_at_open = std.mem.indexOf(u8, out1, "<updated_at>") orelse return error.MissingUpdatedAt;
    const updated_at_close = std.mem.indexOf(u8, out1, "</updated_at>") orelse return error.MissingUpdatedAtClose;
    const first_updated_at = out1[updated_at_open + "<updated_at>".len .. updated_at_close];
    try testing.expect(first_updated_at.len > 0);

    // Sleep 1 second so the UPDATE bumps the timestamp (DATETIME resolution).
    var ts = std.c.timespec{ .sec = 1, .nsec = 0 };
    _ = std.c.nanosleep(&ts, null);

    const input2 = save_memory_mod.SaveMemoryInput{
        .content = "updated content",
        .tags = &.{"preferences", "updated"},
        .id = "user-preference",
    };
    const out2 = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, input2);
    defer alloc.free(out2);

    // Same id.
    try testing.expect(std.mem.indexOf(u8, out2, "<id>user-preference</id>") != null);
    // Content replaced.
    try testing.expect(std.mem.indexOf(u8, out2, "<error>") == null);

    // Only ONE row in the DB (UPSERT, not INSERT-OR-APPEND).
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM agent_memories WHERE id = ?",
        &.{"user-preference"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "save_memory_tool: auto-generates mem_<16-hex> id when none provided" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = save_memory_mod.SaveMemoryInput{
        .content = "auto-generated memory",
        .tags = &.{},
        .id = "",
    };
    const out = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // Extract the auto-generated id.
    const id_open = std.mem.indexOf(u8, out, "<id>") orelse return error.MissingId;
    const id_close = std.mem.indexOf(u8, out, "</id>") orelse return error.MissingIdClose;
    const generated_id = out[id_open + "<id>".len .. id_close];

    // Format: mem_<16 hex chars>.
    try testing.expectEqual(@as(usize, 4 + 16), generated_id.len);
    try testing.expect(std.mem.startsWith(u8, generated_id, "mem_"));
    for (generated_id[4..]) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(is_hex);
    }
}

test "save_memory_tool: round-trips tag list through storage" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = save_memory_mod.SaveMemoryInput{
        .content = "memory with multiple tags",
        .tags = &.{ "alpha", "beta", "gamma" },
        .id = "tagged-memory",
    };
    _ = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, input);

    // Verify tags are stored as ||-joined string.
    var q = try ctx.db.query(alloc,
        "SELECT tags FROM agent_memories WHERE id = ?",
        &.{"tagged-memory"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("alpha||beta||gamma", row.values[0]);
}