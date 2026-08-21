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

test "load_memory_tool: parameters include query, id, tags, limit, offset, with_content" {
    var found_query = false;
    var found_id = false;
    var found_tags = false;
    var found_limit = false;
    var found_offset = false;
    var found_with_content = false;
    for (load_memory_mod.load_memory_tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "query")) found_query = true;
        if (std.mem.eql(u8, prop.name, "id")) found_id = true;
        if (std.mem.eql(u8, prop.name, "tags")) found_tags = true;
        if (std.mem.eql(u8, prop.name, "limit")) found_limit = true;
        if (std.mem.eql(u8, prop.name, "offset")) found_offset = true;
        if (std.mem.eql(u8, prop.name, "with_content")) found_with_content = true;
    }
    try testing.expect(found_query);
    try testing.expect(found_id);
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

    // Queries with FTS5-special chars must NOT crash (escapeFtsQuery
    // strips the operators and joins tokens with OR, so the FTS5 query
    // parser doesn't see `.`, `:`, `-`, etc.).
    const input = load_memory_mod.LoadMemoryInput{
        .query = "handle_tool.zig",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // No <error> — the query didn't crash. The row should be found
    // because FTS5's tokenizer splits `handle_tool.zig` (in the
    // indexed content) on the dot, and the OR-joined query asks for
    // either `handle_tool` OR `zig` — both present in the row.
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<load_memory") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-special-chars</id>") != null);
}

// --- Regression tests for the strict-search bug (task_1787050039216_3) ---
//
// Symptom: load_memory({query: "preferred model"}) returned 0 hits because
// the query was wrapped in FTS5 phrase syntax, requiring "preferred" to be
// ADJACENT to "model" in the indexed text. After the fix, multi-word queries
// are joined with OR — natural recall semantics.

test "load_memory_tool: multi-token query joins with OR (regression for strict-search bug)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed 3 memories that mention "preferred" or "model" separately,
    // but NOT the literal substring "preferred model" as adjacent text.
    const _o1 = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, .{
        .content = "the user's preferred model is claude-sonnet",
        .tags = "",
        .id = "mem-coding-pref",
    });
    defer alloc.free(_o1);
    const _o2 = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, .{
        .content = "user prefers claude-sonnet for writing tasks",
        .tags = "",
        .id = "mem-writing-pref",
    });
    defer alloc.free(_o2);
    const _o3 = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, .{
        .content = "the project's database model is documented in spec",
        .tags = "",
        .id = "mem-db-model",
    });
    defer alloc.free(_o3);

    // With the old phrase-wrap behavior, this query would return 0 hits
    // because no memory contains the literal substring "preferred model".
    // With the new OR-join behavior, this query should find all 3.
    const input = load_memory_mod.LoadMemoryInput{
        .query = "preferred model",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // No error, no crash.
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);

    // All 3 memories should be found (each contains at least one of the
    // two tokens).
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-coding-pref</id>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-writing-pref</id>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-db-model</id>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<count>3</count>") != null);
}

test "load_memory_tool: single-token query still works (regression guard)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const _o1 = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, .{
        .content = "the user prefers dark mode for the editor",
        .tags = "",
        .id = "mem-dark-mode",
    });
    defer alloc.free(_o1);

    const input = load_memory_mod.LoadMemoryInput{
        .query = "dark",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-dark-mode</id>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<count>1</count>") != null);
}

test "load_memory_tool: hyphenated date query returns sanitized recall (no crash)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Memory contains a date that the user might search for verbatim.
    const _o1 = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, .{
        .content = "log entry on 2026-08-06 says the build is green",
        .tags = "",
        .id = "mem-date-row",
    });
    defer alloc.free(_o1);

    // The old phrase-wrap behavior turned this into "2026 08 06" (phrase).
    // The new OR-join behavior turns it into "2026 OR 08 OR 06". Both
    // find the row — but we just want to verify no crash and at least
    // 1 hit.
    const input = load_memory_mod.LoadMemoryInput{
        .query = "2026-08-06",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-date-row</id>") != null);
}

test "load_memory_tool: empty-after-sanitize query returns empty results (no crash)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // A query of only FTS5 operators sanitizes to empty string. The
    // load_memories helper now guards against FTS5's "empty query"
    // error and returns 0 hits instead of crashing.
    const input = load_memory_mod.LoadMemoryInput{
        .query = "+++--",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<count>0</count>") != null);
}

// ─── by-id lookup (Task 1 of 2026-08-19-load-memory-by-id) ──────────────
//
// Adds an `id` parameter to `load_memory` so the LLM can fetch a
// specific memory's FULL body (no 2 KiB cap) without running an FTS5
// query. Wire contract:
//   - When `id` is non-empty, FTS5 is skipped — `agent_memories.getMemoryById`
//     does a single-row SELECT and returns the full content (up to 1 MiB).
//   - When `id` is empty, the FTS5 path runs as before (no behaviour change).
//   - When both `id` and `query` are empty → `<error>must supply either
//     query or id</error>`.
//   - When `id` is non-empty but no row exists → `<error>not found: <id></error>`.
//   - `tags` is ignored when `id` is set (only 1 row can match anyway).

test "load_memory_tool: by-id lookup returns single row with full content" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const _out = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, .{
        .content = "the user's preferred model is claude-sonnet",
        .tags = "preferences||user",
        .id = "mem-coding-pref",
    });
    defer alloc.free(_out);

    // id-only, with_content defaults to false — content still comes back
    // because the by-id path is targeted (not an FTS snippet).
    const input = load_memory_mod.LoadMemoryInput{
        .query = "",
        .id = "mem-coding-pref",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<load_memory") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-coding-pref</id>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<tags>preferences||user</tags>") != null);
    // Full body, not just a 10-token snippet.
    try testing.expect(std.mem.indexOf(u8, out, "preferred model is claude-sonnet") != null);
    // Wrapped in <results> for shape consistency with the FTS path.
    try testing.expect(std.mem.indexOf(u8, out, "<count>1</count>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<total_count>1</total_count>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<results>") != null);
}

test "load_memory_tool: by-id lookup returns content beyond 2 KiB (no MAX_FULL_CONTENT_BYTES cap)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed a memory with content > 2 KiB so the FTS5 + with_content=true
    // path would truncate at MAX_FULL_CONTENT_BYTES (2 KiB). The by-id
    // path must return the FULL body.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(alloc);
    const filler = "lorem ipsum dolor sit amet consectetur adipiscing elit ";
    var i: u32 = 0;
    while (big.items.len < 4096) : (i += 1) {
        try big.print(alloc, "{s}", .{filler});
    }
    try big.appendSlice(alloc, "DISTINCT_TAIL_TOKEN_AFTER_2KIB_MARK");

    const _out = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, .{
        .content = big.items,
        .tags = "",
        .id = "mem-big-content",
    });
    defer alloc.free(_out);

    const input = load_memory_mod.LoadMemoryInput{
        .query = "",
        .id = "mem-big-content",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
    // Tail marker is well past the 2 KiB cutoff — only reachable if the
    // by-id path bypasses MAX_FULL_CONTENT_BYTES.
    try testing.expect(std.mem.indexOf(u8, out, "DISTINCT_TAIL_TOKEN_AFTER_2KIB_MARK") != null);
    // No <content truncated="1"> flag — content is not truncated.
    try testing.expect(std.mem.indexOf(u8, out, "<content truncated=\"1\">") == null);
}

test "load_memory_tool: by-id lookup returns error when id not found" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = load_memory_mod.LoadMemoryInput{
        .query = "",
        .id = "mem-does-not-exist",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "not found") != null);
    // No empty <results> — error shape only.
    try testing.expect(std.mem.indexOf(u8, out, "<results>") == null);
}

test "load_memory_tool: empty id + empty query returns error" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = load_memory_mod.LoadMemoryInput{
        .query = "",
        .id = "",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "must supply either query or id") != null);
}

test "load_memory_tool: by-id ignores tags (only one row can match anyway)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed two memories — the by-id lookup must return only the one
    // with the matching id, regardless of the tags filter.
    const _a = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, .{
        .content = "memory alpha",
        .tags = "alpha",
        .id = "mem-alpha",
    });
    defer alloc.free(_a);
    const _b = try save_memory_mod.executeSaveMemory(alloc, &ctx.db, .{
        .content = "memory beta",
        .tags = "beta",
        .id = "mem-beta",
    });
    defer alloc.free(_b);

    const input = load_memory_mod.LoadMemoryInput{
        .query = "",
        .id = "mem-alpha",
        .tags = "beta", // intentionally wrong tag — must be ignored
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try load_memory_mod.executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-alpha</id>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-beta</id>") == null);
}
