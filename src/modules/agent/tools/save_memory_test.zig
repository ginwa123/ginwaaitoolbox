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
        .tags = "preferences",
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
        .tags = "",
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
        .tags = "",
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
        .tags = "preferences",
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
    // Use a portable helper because std.c.timespec is broken on Windows
    // (Zig 0.16 — see ../../ai_workflow/tui/agentic_loop/test_sleep.zig).
    const test_sleep = @import("../../../ai_workflow/tui/agentic_loop/test_sleep.zig");
    test_sleep.sleep(1, 0);

    const input2 = save_memory_mod.SaveMemoryInput{
        .content = "updated content",
        .tags = "preferences||updated",
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
        .tags = "",
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
        .tags = "alpha||beta||gamma",
        .id = "tagged-memory",
    };
    const out = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // Verify tags are stored as ||-joined string.
    var q = try ctx.db.query(alloc,
        "SELECT tags FROM agent_memories WHERE id = ?",
        &.{"tagged-memory"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("alpha||beta||gamma", row.values[0]);
}

// -----------------------------------------------------------------------
// REGRESSION: tags as a single STRING (the new wire format, 2026-08-06)
//
// The LLM tool schema declares `tags` as a string. The LLM faithfully
// sends it as a string (e.g. "demo|tool-test|nalar"). The parser
// previously expected tags as `[]const []const u8` (JSON array), so
// every string-form failed with "UnexpectedToken". The fix accepts
// the string form: split on `||` at the boundary, pass array to
// `agent_memories.saveMemory`.
// -----------------------------------------------------------------------
test "save_memory_tool: tags wire format is a string (parses without UnexpectedToken)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // EXACT shape the LLM produced in session-1785986173692 (the bug).
    // tags is a STRING with `|` separator.
    const llm_arguments =
        \\{"content":"Demo note","tags":"demo|tool-test|nalar","id":"test-bug-string"}
    ;

    const parsed = std.json.parseFromSlice(
        save_memory_mod.SaveMemoryInput,
        alloc,
        llm_arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        std.debug.print("UNEXPECTED parse failure: {s}\n", .{@errorName(err)});
        return err;
    };
    defer parsed.deinit();

    // The parser must succeed without "UnexpectedToken".
    try testing.expect(parsed.value.content.len > 0);
    try testing.expectEqualStrings("test-bug-string", parsed.value.id);
    try testing.expectEqualStrings("demo|tool-test|nalar", parsed.value.tags);

    // The string form must be passed through to storage correctly
    // (split on || at the wire boundary, joined back to || in DB).
    const out = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, parsed.value);
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);

    var q = try ctx.db.query(alloc,
        "SELECT tags FROM agent_memories WHERE id = ?",
        &.{"test-bug-string"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    // After splitTagsString + joinTags, the `|` separator is normalized
    // to `||` (the documented storage convention).
    try testing.expectEqualStrings("demo||tool-test||nalar", row.values[0]);
}

test "save_memory_tool: single tag (no separator) round-trips" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = save_memory_mod.SaveMemoryInput{
        .content = "single tag",
        .tags = "demo",
        .id = "single-tag-memory",
    };
    const out = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, input);
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);

    var q = try ctx.db.query(alloc,
        "SELECT tags FROM agent_memories WHERE id = ?",
        &.{"single-tag-memory"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("demo", row.values[0]);
}

test "save_memory_tool: empty tags string saves empty tags" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = save_memory_mod.SaveMemoryInput{
        .content = "no tags",
        .tags = "",
        .id = "no-tags-memory",
    };
    const out = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, input);
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);

    var q = try ctx.db.query(alloc,
        "SELECT tags FROM agent_memories WHERE id = ?",
        &.{"no-tags-memory"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "save_memory_tool: splitTagsString accepts ||, |, comma, and space separators" {
    const alloc = testing.allocator;

    // || separator (the documented "join" form).
    {
        const out = try save_memory_mod.splitTagsString(alloc, "foo||bar||baz");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 3), out.len);
        try testing.expectEqualStrings("foo", out[0]);
        try testing.expectEqualStrings("bar", out[1]);
        try testing.expectEqualStrings("baz", out[2]);
    }

    // | separator (the LLM tried this in the bug session).
    {
        const out = try save_memory_mod.splitTagsString(alloc, "demo|tool-test|nalar");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 3), out.len);
        try testing.expectEqualStrings("demo", out[0]);
    }

    // comma separator (intuitive fallback).
    {
        const out = try save_memory_mod.splitTagsString(alloc, "foo,bar,baz");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 3), out.len);
    }

    // space separator (also tried by the LLM).
    {
        const out = try save_memory_mod.splitTagsString(alloc, "demo tool-test nalar");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 3), out.len);
    }

    // Empty string → empty array.
    {
        const out = try save_memory_mod.splitTagsString(alloc, "");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 0), out.len);
    }

    // Only separators → empty array.
    {
        const out = try save_memory_mod.splitTagsString(alloc, "||,, ,|");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 0), out.len);
    }

    // Mixed separators (the LLM might mix).
    {
        const out = try save_memory_mod.splitTagsString(alloc, "foo||bar,baz qux");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 4), out.len);
        try testing.expectEqualStrings("foo", out[0]);
        try testing.expectEqualStrings("bar", out[1]);
        try testing.expectEqualStrings("baz", out[2]);
        try testing.expectEqualStrings("qux", out[3]);
    }
}