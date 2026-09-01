//! Agent-callable tool: `save_memory` — UPSERT a short, structured note
//! that the agent can recall later via `load_memory`.
//!
//! Plan: docs/superpowers/plans/2026-08-06-save-load-memory-fts5.md (Task 3)
//! Task: task_1785958319567
//!
//! Wire shape:
//!   input:  { content: string, tags?: string, id?: string }
//!   output: <save_memory><id>...</id><created_at>...</created_at>
//!            <updated_at>...</updated_at></save_memory>
//!   or:     <save_memory><error>...</error></save_memory>
//!
//! The actual INSERT OR REPLACE lives in `agent_memories.saveMemory`.
//! This file is a thin XML wrapper around it (mirrors the
//! `kanban_list.zig` / `search_history.zig` pattern).
//!
//! Design choices:
//!   - Caller-provided `id` is optional. Empty → auto-generated
//!     `mem_<16-hex>` (collision-free for 10K rows, opaque token).
//!   - Per-row size cap is 1 MiB (rejects overflow, doesn't truncate).
//!   - Tags is a SINGLE STRING on the wire (matches the schema
//!     `type: "string"`). Multiple tags are joined with `||`
//!     (the project convention — matches Migration 067 / 069).
//!     The parser ALSO accepts `|`, `,`, and space as separators
//!     for robustness — the LLM has tried all of these.
//!   - Empty string → empty `tags` array (canonical "no tags" sentinel).
//!
//! Why `tags` is a string, not an array:
//!   The LLM tool schema declares `tags: { type: "string" }`. The
//!   LLM faithfully sends a string. The previous struct shape
//!   (`tags: []const []const u8`) parsed as a JSON array, so
//!   every string-form failed with "UnexpectedToken" (user bug,
//!   session-1785986173692, 2026-08-06). The string form is also
//!   simpler to reason about and matches the documented contract
//!   "Joined with `||` in storage".

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const agent_memories = nalarcore.agent_memories;

const helpers = @import("helpers");
const xmlEscape = helpers.xml_escape;

/// Input for `save_memory`.
pub const SaveMemoryInput = struct {
    /// The note body. 1 KiB – 1 MiB (validated by `agent_memories.saveMemory`).
    content: []const u8 = "",
    /// Optional labels as a single string. Multiple tags separated
    /// by `||` (preferred), `|`, `,`, or space. Empty string = no tags.
    /// Split at the boundary into `[]const []const u8` before passing
    /// to `agent_memories.saveMemory` (which joins with `||` for storage).
    tags: []const u8 = "",
    /// Caller-provided id slug for UPSERT. Empty → auto-generate
    /// `mem_<16-hex>`.
    id: []const u8 = "",
};

/// Top-level tool definition for the LLM. The description is the
/// agent's primary signal for WHEN to use this tool — it explicitly
/// tells the agent that memory entries are UPSERT, FTS5-indexed,
/// global (cross-session / cross-workspace), and capped at 1 MiB.
pub const save_memory_tool_system_prompt =
    \\## Save Memory Tool — Behavior
    \\Use `save_memory` to persist a fact across sessions (FTS5).
    \\- Content must be 1 KiB–1 MiB. UPSERT by `id` (auto-generates `mem_<hex>` if omitted).
    \\- Use for user preferences, project conventions, decisions, and corrections. Call immediately when you learn a preference.
    \\
;

pub const save_memory_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "save_memory",
        .description =
            \\Save (or update) a structured note that you can recall later via the `load_memory` tool. Use this to remember facts, preferences, decisions, or any short, structured context that you want to persist across sessions.
            \\
            \\This is a UPSERT: if you provide an `id` that already exists, the existing row's content and tags are replaced (the `updated_at` timestamp bumps). Omit `id` (or pass an empty string) to auto-generate a fresh `mem_<16-hex>` id.
            \\
            \\Storage: the note is stored in a global SQLite table with a FTS5 index. Searches (`load_memory`) can find it via phrase matching on the content or tags.
            \\
            \\Constraints:
            \\- `content` must be 1 KiB – 1 MiB. Empty content is rejected; oversized is rejected (no silent truncation).
            \\- `tags` are joined with `||` in storage and split on `|` at read time.
            \\- To remove an entry entirely (e.g. it is genuinely obsolete or the user asked to forget it), use `delete_memory({ id })` — but default to UPSERT-with-superseding-content unless the user explicitly asks to delete.
            \\- Global scope: memories are visible across all workspaces and sessions. There is no per-workspace filter.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "content", .type = "string", .description = "The note body. 1 KiB – 1 MiB. Required." },
                .{ .name = "tags", .type = "string", .description = "Optional labels as a single string. Multiple tags separated by `||` (preferred), e.g. 'preferences||user'. Also accepts `|`, `,`, or space as separators for robustness. Empty string = no tags." },
                .{ .name = "id", .type = "string", .description = "Optional caller-provided id slug for UPSERT. Empty string → auto-generated 'mem_<16-hex>'." },
            },
            .required = &.{"content"},
        },
        .system_prompt = save_memory_tool_system_prompt,
    },
};

/// Execute save_memory. Returns an XML string for the LLM.
///
/// Caller owns the returned slice and must free it with `allocator.free()`.
pub fn executeSaveMemory(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: SaveMemoryInput,
) ![]const u8 {
    // Split the wire-string tags into an array for the storage layer.
    // Empty string → empty array (canonical "no tags" sentinel).
    const tags_array = try splitTagsString(allocator, input.tags);
    defer allocator.free(tags_array);

    const row = agent_memories.saveMemory(allocator, db, .{
        .content = input.content,
        .tags = tags_array,
        .id = input.id,
    }) catch |err| {
        const msg = switch (err) {
            error.InvalidContent => "content must be non-empty (1 KiB minimum)",
            error.ContentTooLarge => "content exceeds the 1 MiB per-memory cap",
            error.RowNotFoundAfterInsert => "row missing after insert (DB inconsistency)",
            else => @errorName(err),
        };
        return errorXml(allocator, msg);
    };
    defer agent_memories.freeMemoryRow(allocator, row);

    return successXml(allocator, row);
}

/// Split a tags wire string by `||` (preferred), `|`, `,`, and space.
/// Returns an allocated array of `[]const u8` slices — caller owns the
/// array and the slices (free the array with `allocator.free()`; the
/// slices are views into the input string and don't need individual
/// frees unless they were trimmed).
///
/// The bounds are loose: `"foo, ,bar"` yields `["foo", "bar"]` (empty
/// segments skipped). Whitespace around tags is trimmed.
pub fn splitTagsString(allocator: std.mem.Allocator, input: []const u8) ![]const []const u8 {
    // First pass: count tags (skip empty segments).
    var count: usize = 0;
    var in_segment = false;
    for (input) |c| {
        const is_sep = c == '|' or c == ',' or c == ' ';
        if (!is_sep and !in_segment) {
            count += 1;
            in_segment = true;
        } else if (is_sep) {
            in_segment = false;
        }
    }
    if (count == 0) return &.{};

    // Second pass: extract each tag (pointers into the input; bounds-check
    // ensures the input slice stays alive for the caller's use).
    var out = try allocator.alloc([]const u8, count);
    var idx: usize = 0;
    var start: ?usize = null;
    for (input, 0..) |c, i| {
        const is_sep = c == '|' or c == ',' or c == ' ';
        if (is_sep) {
            if (start) |s| {
                out[idx] = trimWhitespace(input[s..i]);
                idx += 1;
                start = null;
            }
        } else if (start == null) {
            start = i;
        }
    }
    if (start) |s| {
        out[idx] = trimWhitespace(input[s..]);
    }
    return out;
}

fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t' or s[start] == '\n' or s[start] == '\r')) : (start += 1) {}
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\n' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[start..end];
}

fn successXml(allocator: std.mem.Allocator, row: agent_memories.MemoryRow) ![]u8 {
    const id_e = try xmlEscape(allocator, row.id);
    defer allocator.free(id_e);
    const created_at_e = try xmlEscape(allocator, row.created_at);
    defer allocator.free(created_at_e);
    const updated_at_e = try xmlEscape(allocator, row.updated_at);
    defer allocator.free(updated_at_e);
    return std.fmt.allocPrint(allocator,
        "<save_memory>" ++
        "<id>{s}</id>" ++
        "<created_at>{s}</created_at>" ++
        "<updated_at>{s}</updated_at>" ++
        "</save_memory>",
        .{ id_e, created_at_e, updated_at_e });
}

fn errorXml(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, msg);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        "<save_memory><error>{s}</error></save_memory>",
        .{escaped});
}

const testing = std.testing;
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
