//! Behavioural tests for `load_memory.zig` — the FTS5 search tool.

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const migration = @import("../../../migrations/migration.zig");

const load_memory_mod = @import("load_memory.zig");
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

test "load_memory_tool: tool name is 'load_memory'" {
    try testing.expectEqualStrings("load_memory", load_memory_mod.load_memory_tool.function.name);
}

test "load_memory_tool: parameters include query, tags, limit, offset, with_content" {
    var found_query = false;
    var found_tags = false;
    var found_limit = false;
    var found_offset = false;
    var found_with_content = false;
    for (load_memory_mod.load_memory_tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "query")) found_query = true;
        if (std.mem.eql(u8, prop.name, "tags")) found_tags = true;
        if (std.mem.eql(u8, prop.name, "limit")) found_limit = true;
        if (std.mem.eql(u8, prop.name, "offset")) found_offset = true;
        if (std.mem.eql(u8, prop.name, "with_content")) found_with_content = true;
    }
    try testing.expect(found_query);
    try testing.expect(found_tags);
    try testing.expect(found_limit);
    try testing.expect(found_offset);
    try testing.expect(found_with_content);
}

test "load_memory_tool: returns success XML envelope" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed one memory.
    const _out = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, .{
        .content = "the user prefers dark mode",
        .tags = "preferences",
        .id = "user-dark-mode",
    });
    defer alloc.free(_out);

    const input = load_memory_mod.LoadMemoryInput{
        .query = "dark mode",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<load_memory") != null);
    try testing.expect(std.mem.indexOf(u8, out, "</load_memory>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>user-dark-mode</id>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<snippet>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[") != null); // [match] marker
    try testing.expect(std.mem.indexOf(u8, out, "<count>1</count>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<total_count>1</total_count>") != null);
}

test "load_memory_tool: returns error XML on empty query" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = load_memory_mod.LoadMemoryInput{
        .query = "",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>") != null);
}

test "load_memory_tool: limits result count to MAX_LIMIT (50) when caller requests more" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed 60 memories that all match the query.
    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        const id = std.fmt.allocPrint(alloc, "mem-cap-{d}", .{i}) catch unreachable;
        defer alloc.free(id);
        const _out = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, .{
            .content = "shared memory content for cap test",
            .tags = "",
            .id = id,
        });
        defer alloc.free(_out);
    }

    // Request limit=999 — should be capped to 50.
    const input = load_memory_mod.LoadMemoryInput{
        .query = "shared",
        .tags = "",
        .limit = 999,
        .offset = 0,
        .with_content = false,
    };
    const out = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // Verify <count>50</count> appears (the cap).
    try testing.expect(std.mem.indexOf(u8, out, "<count>50</count>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<total_count>60</total_count>") != null);
}

test "load_memory_tool: snippets contain [match] markers (FTS5 convention)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const _out = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, .{
        .content = "the user prefers dark mode for the editor",
        .tags = "",
        .id = "mem-snippet",
    });
    defer alloc.free(_out);

    const input = load_memory_mod.LoadMemoryInput{
        .query = "dark",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // Every snippet must have [match] markers (the FTS5 convention).
    try testing.expect(std.mem.indexOf(u8, out, "<snippet>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[dark]") != null or
        std.mem.indexOf(u8, out, "[dark mode]") != null);
}

test "load_memory_tool: AND-filters by tags" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const _out1 = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, .{
        .content = "memory one with model preference",
        .tags = "preferences||user",
        .id = "mem-one",
    });
    defer alloc.free(_out1);
    const _out2 = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, .{
        .content = "memory two with project context",
        .tags = "preferences||project",
        .id = "mem-two",
    });
    defer alloc.free(_out2);
    const _out3 = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, .{
        .content = "memory three with project context",
        .tags = "project",
        .id = "mem-three",
    });
    defer alloc.free(_out3);

    const input = load_memory_mod.LoadMemoryInput{
        .query = "context",
        .tags = "project",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // mem-two + mem-three match (both have "context" + "project" tag).
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-two</id>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-three</id>") != null);
    // mem-one does NOT match (no "context" in content).
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-one</id>") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<count>2</count>") != null);
}

test "load_memory_tool: without with_content, snippets only (no raw <content>)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const _out = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, .{
        .content = "short content for anti-bloat test",
        .tags = "",
        .id = "mem-no-content",
    });
    defer alloc.free(_out);

    const input = load_memory_mod.LoadMemoryInput{
        .query = "content",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false, // ← snippets only
    };
    const out = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // <snippet> present, <content> NOT present.
    try testing.expect(std.mem.indexOf(u8, out, "<snippet>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<content") == null);
}

test "load_memory_tool: paginates via limit + offset" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed 5 memories that all match "pageword".
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const id = std.fmt.allocPrint(alloc, "mem-page-{d}", .{i}) catch unreachable;
        defer alloc.free(id);
        const _out = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, .{
            .content = "pageword row",
            .tags = "",
            .id = id,
        });
        defer alloc.free(_out);
    }

    // Page 1: limit=3 → 3 hits.
    const out1 = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, .{
        .query = "pageword",
        .tags = "",
        .limit = 3,
        .offset = 0,
        .with_content = false,
    });
    defer alloc.free(out1);
    try testing.expect(std.mem.indexOf(u8, out1, "<count>3</count>") != null);
    try testing.expect(std.mem.indexOf(u8, out1, "<total_count>5</total_count>") != null);

    // Page 2: limit=3 offset=3 → 2 hits.
    const out2 = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, .{
        .query = "pageword",
        .tags = "",
        .limit = 3,
        .offset = 3,
        .with_content = false,
    });
    defer alloc.free(out2);
    try testing.expect(std.mem.indexOf(u8, out2, "<count>2</count>") != null);
    try testing.expect(std.mem.indexOf(u8, out2, "<total_count>5</total_count>") != null);
}

test "load_memory_tool: FTS5 query sanitization (dots, dashes, colons don't crash)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const _out = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, .{
        .content = "this row contains handle_tool.zig and AGENTS.md",
        .tags = "",
        .id = "mem-special-chars",
    });
    defer alloc.free(_out);

    // Queries with FTS5-special chars must NOT crash (escapeFtsQuery wraps them).
    const input = load_memory_mod.LoadMemoryInput{
        .query = "handle_tool.zig",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // Either found the row (FTS5 matched despite sanitization) or returned 0 hits
    // (phrase didn't match). Either way, no <error> — the query didn't crash.
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<load_memory") != null);
}
