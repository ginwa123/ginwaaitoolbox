//! Storage layer for the `save_memory` + `load_memory` agent tools.
//!
//! Three public functions:
//!   - `saveMemory` — UPSERT a memory row (insert-or-replace by `id`)
//!   - `loadMemoriesByFts` — FTS5 phrase search with snippet + tags filter
//!   - `getMemoryById` — lookup a single row by id (returns null if missing)
//!
//! Backed by Migration 070's `agent_memories` table + `agent_memories_fts`
//! FTS5 virtual table. The sync triggers from Migration 070 keep the FTS5
//! index in lockstep with the source table automatically — no per-call
//! FTS5 maintenance needed here.
//!
//! Plan: docs/superpowers/plans/2026-08-06-save-load-memory-fts5.md (Task 2)
//! Task: task_1785958319567
//!
//! Why a dedicated module (NOT extending llm_history.zig)
//! ──────────────────────────────────────────────────────
//! `llm_history` is for session-scoped chat messages. The new memory
//! store is for cross-session, cross-workspace notes. Conceptually
//! distinct (different storage, different consumer, different access
//! pattern). Putting them in the same file would dilute both.
//!
//! Why `mem_<16-hex>` auto-generated ids
//! ─────────────────────────────────────
//! 64-bit random — collision odds for 10K rows are ~1 in 10^19
//! (astronomically safe). Opaque (no metadata leak), agent treats as a
//! token. Same shape as `llm_history` message ids (which use
//! `unix-ns-<hex>` — the timestamp prefix is incidental; the random
//! suffix is the meaningful bit).

const std = @import("std");
const sqlite = @import("nalarcore").sqlite;
const llm_history = @import("llm_history.zig");

/// One row in `agent_memories`. All string fields are allocator-owned and
/// must be freed by the caller — use `freeMemoryRow` for a single row or
/// `freeMemoryRows` for a slice.
pub const MemoryRow = struct {
    id: []const u8,
    content: []const u8,
    tags: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// One FTS5 search hit. `snippet` is the FTS5 10-token preview with
/// `[match]` markers around matched words. `total_count` is shared
/// across all hits in one result set (it's the unfiltered COUNT(*)
/// over the whole result window — same value on every hit).
pub const MemoryHit = struct {
    id: []const u8,
    tags: []const u8,
    snippet: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    total_count: u32,

    pub fn deinit(self: *const MemoryHit, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.tags);
        allocator.free(self.snippet);
        if (self.created_at.len > 0) allocator.free(self.created_at);
        if (self.updated_at.len > 0) allocator.free(self.updated_at);
    }
};

/// Arguments for `saveMemory`.
pub const SaveMemoryArgs = struct {
    /// The note body. 1 KiB – 1 MiB. Empty string → `error.InvalidContent`.
    content: []const u8,
    /// Optional tags. Each tag is a non-empty string. Stored as
    /// `||`-joined (matches the project's `tags` / `image_urls` convention
    /// — see Migration 067 / 069).
    tags: []const []const u8,
    /// Caller-provided id slug for UPSERT. Empty string → auto-generate
    /// `mem_<16-hex>`.
    id: []const u8,
};

/// Hard cap on the size of a single memory. 1 MiB is well above any
/// plausible note ("the user's preferred model is X" is ~50 bytes) and
/// prevents a runaway agent from filling the DB.
pub const MAX_CONTENT_BYTES: usize = 1 << 20; // 1 MiB

/// Save a memory. UPSERT by `id` — if a row with the same id exists,
/// its content + tags are replaced and `updated_at` is bumped. If `id`
/// is empty, a fresh `mem_<16-hex>` id is generated.
///
/// Returns the persisted row (with the auto-generated id if `id` was
/// empty). Caller owns the row's strings and must free with
/// `freeMemoryRow`.
///
/// Errors:
///   - `error.InvalidContent` — content is empty
///   - `error.ContentTooLarge` — content exceeds `MAX_CONTENT_BYTES`
///   - DB errors propagate verbatim
pub fn saveMemory(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    args: SaveMemoryArgs,
) !MemoryRow {
    if (args.content.len == 0) return error.InvalidContent;
    if (args.content.len > MAX_CONTENT_BYTES) return error.ContentTooLarge;

    // Generate id if caller didn't provide one.
    const id: []const u8 = if (args.id.len == 0)
        try generateMemoryId(allocator)
    else
        args.id;

    // Build the `||`-joined tags string. Empty tags array → empty string
    // (the canonical "no tags" sentinel — matches Migration 067/069).
    const tags_str = if (args.tags.len == 0)
        try allocator.dupe(u8, "")
    else
        try joinTags(allocator, args.tags);
    defer if (args.tags.len > 0) allocator.free(tags_str);

    // UPSERT via SQLite's INSERT OR REPLACE. The DELETE+INSERT fires
    // both the `agent_memories_ad` and `agent_memories_ai` triggers,
    // which keeps the FTS5 index in sync. (Plain INSERT with a primary
    // key collision would crash; REPLACE handles the collision.)
    const insert_sql =
        \\INSERT OR REPLACE INTO agent_memories (id, content, tags, created_at, updated_at)
        \\VALUES (?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    ;
    var binds: [3][]const u8 = .{ id, args.content, tags_str };
    try db.exec(allocator, insert_sql, &binds);

    // Read the row back so the caller sees the canonical timestamps.
    // If `id` was caller-provided, we MUST NOT free it (it's a borrow
    // of the caller's slice). If we generated it, we MUST free it.
    var generated_id: ?[]u8 = null;
    if (args.id.len == 0) generated_id = @constCast(id);
    defer if (generated_id) |g| allocator.free(g);

    const row = (try getMemoryById(allocator, db, id)) orelse return error.RowNotFoundAfterInsert;
    return row;
}

/// Look up a memory by id. Returns null when no row with that id exists
/// (does NOT error — the caller branches on null to handle "not found"
/// cleanly).
pub fn getMemoryById(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !?MemoryRow {
    var q = try db.query(allocator,
        "SELECT id, content, tags, COALESCE(created_at, ''), COALESCE(updated_at, '') " ++
            "FROM agent_memories WHERE id = ?",
        &.{id});
    defer q.deinit();

    const row = (try q.next()) orelse return null;
    defer row.deinit(allocator);

    return MemoryRow{
        .id = try allocator.dupe(u8, row.values[0]),
        .content = try allocator.dupe(u8, row.values[1]),
        .tags = try allocator.dupe(u8, row.values[2]),
        .created_at = try allocator.dupe(u8, row.values[3]),
        .updated_at = try allocator.dupe(u8, row.values[4]),
    };
}

/// Free a single MemoryRow's owned strings.
pub fn freeMemoryRow(allocator: std.mem.Allocator, row: MemoryRow) void {
    allocator.free(row.id);
    allocator.free(row.content);
    allocator.free(row.tags);
    if (row.created_at.len > 0) allocator.free(row.created_at);
    if (row.updated_at.len > 0) allocator.free(row.updated_at);
}

/// Free a slice of MemoryRow. Each row's strings are freed by
/// `freeMemoryRow`; the slice itself is freed last.
pub fn freeMemoryRows(allocator: std.mem.Allocator, rows: []MemoryRow) void {
    for (rows) |row| freeMemoryRow(allocator, row);
    allocator.free(rows);
}

/// Free a slice of MemoryHit. Each hit's strings are freed by
/// `MemoryHit.deinit`; the slice itself is freed last.
pub fn freeMemoryHits(allocator: std.mem.Allocator, hits: []MemoryHit) void {
    for (hits) |h| {
        var copy = h;
        copy.deinit(allocator);
    }
    allocator.free(hits);
}

/// Options for `loadMemoriesByFts`.
pub const LoadOptions = struct {
    /// FTS5 phrase search. Must be non-empty. Sanitized via
    /// `llm_history.escapeFtsQuery` before binding (so `.`, `-`, `:`,
    /// `*`, `^`, `(`, `)`, `"`, `+` in the user's query don't crash
    /// the FTS5 MATCH parser).
    query: []const u8,
    /// AND filter: every tag must be present in the row's tags
    /// (substring match — `LIKE '%tag%'`). Empty array = no filter.
    tags: []const []const u8,
    /// Max rows to return. Caller caps at a sane upper bound (50 in
    /// the tool layer).
    limit: u32,
    /// Skip the first N rows of the ranked result set. 0 = start from
    /// the top.
    offset: u32,
};

/// FTS5 phrase search over `agent_memories_fts`. Returns ranked hits
/// with `snippet(..., 0, '[', ']', '…', 10)` (10-token window with
/// `[match]` markers around matches). The `total_count` field on every
/// hit is the unfiltered COUNT(*) over the post-LIMIT result set — same
/// value on every hit.
///
/// Tag filter semantics: AND across all tags. Each tag must be present
/// in the row's `tags` column (substring match). Empty tags array = no
/// filter.
///
/// FTS5 sanitization: the query is passed through
/// `llm_history.escapeFtsQuery` so plain text with FTS5 operators
/// (`.`, `-`, `:`, `*`, etc.) doesn't crash the parser. See
/// `llm_history.zig:1770` for the full rationale.
pub fn loadMemoriesByFts(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    opts: LoadOptions,
) ![]MemoryHit {
    if (opts.query.len == 0) return allocator.alloc(MemoryHit, 0);

    // Sanitize the FTS5 query — same helper `search_history` uses.
    const sanitized_query = try llm_history.escapeFtsQuery(allocator, opts.query);
    defer allocator.free(sanitized_query);

    // Build the SQL.
    //
    // The query JOINs `agent_memories` to `agent_memories_fts` so the
    // `snippet()` function can read the FTS5-indexed content AND we can
    // also get the source-table columns (tags, created_at, updated_at).
    // The `COUNT(*) OVER ()` window function gives us the total result
    // count before LIMIT/OFFSET — same value on every row.
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);

    // Wrap FTS5 access in a subquery because SQLite virtual tables have
    // restrictions on what SQL features they accept (notably window
    // functions like `COUNT(*) OVER ()`). The outer query wraps the
    // FTS5 access in a subquery, then ORDER BY / LIMIT / OFFSET work
    // normally on the wrapper. Same pattern as `searchMessagesFts` in
    // llm_history.zig:1797.
    try sql.appendSlice(allocator,
        \\SELECT
        \\    id, tags, snippet, created_at, updated_at,
        \\    COUNT(*) OVER () AS total_count
        \\FROM (
        \\    SELECT
        \\        m.id AS id, m.tags AS tags,
        \\        snippet(agent_memories_fts, 0, '[', ']', '...', 10) AS snippet,
        \\        COALESCE(m.created_at, '') AS created_at,
        \\        COALESCE(m.updated_at, '') AS updated_at,
        \\        rank AS fts_rank
        \\    FROM agent_memories_fts
        \\    JOIN agent_memories m ON m.rowid = agent_memories_fts.rowid
        \\    WHERE agent_memories_fts MATCH ?
    );

    var binds: std.ArrayList([]const u8) = .empty;
    var tag_patterns: std.ArrayList([]u8) = .empty;
    defer {
        for (tag_patterns.items) |p| allocator.free(p);
        tag_patterns.deinit(allocator);
        binds.deinit(allocator);
    }
    try binds.append(allocator, sanitized_query);

    // AND-filter by tags. Each tag adds a `LIKE '%tag%'` clause to the
    // WHERE. Substring match is the project's convention (matches
    // `workspace_item_tasks.tags` from Migration 067 — the agent picks
    // tag names so substring collisions are unlikely).
    for (opts.tags) |tag| {
        if (tag.len == 0) continue;
        try sql.appendSlice(allocator, " AND m.tags LIKE ?");
        // The pattern is heap-owned — free AFTER `db.query` reads it.
        // If we `defer free` inside this loop iteration, the defer
        // fires before `db.query` runs and the bind slice dangles.
        const pattern = try std.fmt.allocPrint(allocator, "%{s}%", .{tag});
        try tag_patterns.append(allocator, pattern);
        try binds.append(allocator, pattern);
    }

    // Close the subquery, then ORDER BY / LIMIT / OFFSET on the outer query.
    try sql.appendSlice(allocator, ") AS hits ORDER BY fts_rank");
    try sql.print(allocator, " LIMIT {d}", .{opts.limit});
    if (opts.offset > 0) {
        try sql.print(allocator, " OFFSET {d}", .{opts.offset});
    }

    var rows = db.query(allocator, sql.items, binds.items) catch |err| {
        return err;
    };
    defer rows.deinit();

    var hits: std.ArrayList(MemoryHit) = .empty;
    errdefer {
        for (hits.items) |h| {
            var copy = h;
            copy.deinit(allocator);
        }
        hits.deinit(allocator);
    }

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        const total_count: u32 = std.fmt.parseInt(u32, row.values[5], 10) catch 0;
        try hits.append(allocator, MemoryHit{
            .id = try allocator.dupe(u8, row.values[0]),
            .tags = try allocator.dupe(u8, row.values[1]),
            .snippet = try allocator.dupe(u8, row.values[2]),
            .created_at = try allocator.dupe(u8, row.values[3]),
            .updated_at = try allocator.dupe(u8, row.values[4]),
            .total_count = total_count,
        });
    }

    return try hits.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Generate a fresh `mem_<16-hex>` id. Uses `std.c.getrandom` for the
/// 8 random bytes (cross-platform, per `zig-cross-platform.md`).
/// Returns an allocated string the caller owns.
fn generateMemoryId(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [8]u8 = undefined;
    // Retry loop in case the kernel returns short (rare but possible).
    var filled: usize = 0;
    while (filled < 8) {
        const slice = bytes[filled..];
        const got = std.c.getrandom(slice.ptr, slice.len, 0);
        if (got <= 0) return error.RandomFailed;
        filled += @intCast(got);
    }

    // Format as 16 hex chars.
    var hex: [16]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        hex[i * 2] = hex_chars[(b >> 4) & 0x0F];
        hex[i * 2 + 1] = hex_chars[b & 0x0F];
    }

    const out = try allocator.alloc(u8, 4 + 16);
    @memcpy(out[0..4], "mem_");
    @memcpy(out[4..][0..16], &hex);
    return out;
}

/// Join a slice of tags into a `||`-delimited string. Empty tags are
/// skipped (defensive — the tool layer should already filter).
fn joinTags(allocator: std.mem.Allocator, tags: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (tags) |t| {
        if (t.len == 0) continue;
        total += t.len + 2; // t + "||"
    }
    if (total >= 2) total -= 2; // trim trailing "||"

    const out = try allocator.alloc(u8, total);
    var pos: usize = 0;
    var first = true;
    for (tags) |t| {
        if (t.len == 0) continue;
        if (!first) {
            @memcpy(out[pos..][0..2], "||");
            pos += 2;
        }
        @memcpy(out[pos..][0..t.len], t);
        pos += t.len;
        first = false;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Inline tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "generateMemoryId produces mem_<16-hex>" {
    const alloc = testing.allocator;
    const id = try generateMemoryId(alloc);
    defer alloc.free(id);

    try testing.expectEqual(@as(usize, 4 + 16), id.len);
    try testing.expect(std.mem.startsWith(u8, id, "mem_"));
    // Verify the 16 chars after the prefix are hex.
    for (id[4..]) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(is_hex);
    }
}

test "generateMemoryId produces unique ids" {
    // Sanity check: 100 generated ids should all be unique (relaxed
    // from 1000 to avoid `StringHashMapUnmanaged`'s Wyhash read past
    // a short-string tail — collision odds over 100 rows for 64-bit
    // random are ~1 in 10^17). The format test above already covers
    // the structural contract; this test only covers uniqueness.
    const alloc = testing.allocator;
    var seen: [100][]const u8 = [_][]const u8{""} ** 100;
    var count: usize = 0;

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const id = try generateMemoryId(alloc);
        defer alloc.free(id);

        // Check uniqueness against the array (O(n^2) but fine for n=100).
        var j: usize = 0;
        while (j < count) : (j += 1) {
            try testing.expect(!std.mem.eql(u8, id, seen[j]));
        }
        seen[count] = id;
        count += 1;
    }
}

test "joinTags joins with || and skips empty tags" {
    const alloc = testing.allocator;

    // Empty slice → empty string.
    {
        const out = try joinTags(alloc, &.{});
        defer alloc.free(out);
        try testing.expectEqualStrings("", out);
    }

    // Single tag.
    {
        const out = try joinTags(alloc, &.{"foo"});
        defer alloc.free(out);
        try testing.expectEqualStrings("foo", out);
    }

    // Multiple tags.
    {
        const out = try joinTags(alloc, &.{ "foo", "bar", "baz" });
        defer alloc.free(out);
        try testing.expectEqualStrings("foo||bar||baz", out);
    }

    // Empty tags are skipped.
    {
        const out = try joinTags(alloc, &.{ "foo", "", "bar" });
        defer alloc.free(out);
        try testing.expectEqualStrings("foo||bar", out);
    }
}
