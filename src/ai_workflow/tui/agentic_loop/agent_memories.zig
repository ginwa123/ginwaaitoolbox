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
const builtin = @import("builtin");
const sqlite = @import("nalarcore").sqlite;
const migration = @import("../../../migrations/migration.zig");
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
    // Empty after sanitization (query was all FTS5 operators) — bail
    // before FTS5 sees `MATCH ''` and throws "empty query".
    if (sanitized_query.len == 0) return allocator.alloc(MemoryHit, 0);

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

/// Generate a fresh `mem_<16-hex>` id.
///
/// Platform CSPRNG dispatch (mirrors `src/modules/custom_http_server/src/security.zig::generateNonce`):
///   * Linux → libc `getrandom(2)` (loops on partial reads). Declared
///     inside a `comptime` `.linux` branch so the `std.os.linux.getrandom`
///     reference is only validated when compiling for Linux targets — see
///     the zig 0.16 cross-target note in the comment block.
///   * macOS / iOS / tvOS / watchOS → libc `arc4random_buf` (CSPRNG under
///     the hood; the "arc4" name is stale — uses SecRandomCopyBytes since
///     macOS 10.12).
///   * Windows → BCryptGenRandom via bcrypt.dll (linked by `databases` build.zig).
/// `std.os.linux.getrandom` is the kernel syscall on Linux regardless of
/// link_libc — using it sidesteps the `link_libc=false → std.c.getrandom is
/// void` regression that bit Zig 0.16 cross-target compiles (where the
/// module target and root target disagree). Returns an allocated string
/// the caller owns.
fn generateMemoryId(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [8]u8 = undefined;
    switch (builtin.os.tag) {
        .linux => {
            var filled: usize = 0;
            while (filled < 8) {
                const slice = bytes[filled..];
                const got = std.os.linux.getrandom(slice.ptr, slice.len, 0);
                if (got <= 0) return error.RandomFailed;
                filled += @intCast(got);
            }
        },
        .macos, .ios, .tvos, .watchos => {
            // arc4random_buf is declared in std.c private on Apple targets.
            // No loop needed — it always fills in one call.
            std.c.arc4random_buf(&bytes, bytes.len);
        },
        .windows => {
            // BCrypt.dll → BCRYPT_USE_SYSTEM_PREFERRED_RNG (0x00000002).
            // The docs guarantee it is suitable for cryptographic use and is
            // seeded from the OS entropy pool at boot.
            const status = bcrypt.BCryptGenRandom(
                null,
                &bytes,
                @intCast(bytes.len),
                0x00000002,
            );
            if (status != 0) return error.RandomFailed;
        },
        else => return error.UnsupportedPlatform,
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

/// Windows bcrypt.dll bindings. Declared locally because std.c only covers
/// libc; bcrypt is a separate system DLL that the `databases` package links
/// via `linkSystemLibrary("bcrypt")` (see `src/modules/databases/build.zig`).
/// Only referenced from the `.windows` arm of `generateMemoryId`, so the
/// Zig compiler prunes the unused extern at link time on POSIX.
const bcrypt = struct {
    extern "bcrypt" fn BCryptGenRandom(
        hAlgorithm: ?*const anyopaque,
        pbBuffer: [*]u8,
        cbBuffer: c_ulong,
        dwFlags: c_ulong,
    ) callconv(.c) c_long;
};

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

// ─── Inline tests (formerly agent_memories_test.zig) ─────────────────────
// Behavioural tests for saveMemory / loadMemoriesByFts / getMemoryById.
// Tests follow the project convention: every test walks all migrations
// from scratch so the schema under test is GUARANTEED to match
// production. No hand-rolled CREATE TABLE.

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

    const row = try saveMemory(alloc, &ctx.db, .{
        .content = "the user's preferred LLM is claude-sonnet-4-5",
        .tags = &.{"preferences", "user"},
        .id = "",
    });
    defer freeMemoryRow(alloc, row);

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
    const first = try saveMemory(alloc, &ctx.db, .{
        .content = "original content",
        .tags = &.{"preferences"},
        .id = "user-preferred-model",
    });
    defer freeMemoryRow(alloc, first);

    // Tiny sleep so the UPDATE bumps `updated_at` (DATETIME resolution is 1s).
    // std.c.nanosleep — std.Thread.sleep doesn't exist in Zig 0.16.
    // Use a portable helper because std.c.timespec is broken on Windows
    // (Zig 0.16 — see test_sleep.zig for details).
    const test_sleep = @import("test_sleep.zig");
    test_sleep.sleep(1, 0);

    // UPSERT with the same id.
    const second = try saveMemory(alloc, &ctx.db, .{
        .content = "updated content — user switched to claude-opus-4-1",
        .tags = &.{"preferences", "updated"},
        .id = "user-preferred-model",
    });
    defer freeMemoryRow(alloc, second);

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

    const result = saveMemory(alloc, &ctx.db, .{
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

    const result = saveMemory(alloc, &ctx.db, .{
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
    const row1 = try saveMemory(alloc, &ctx.db, .{
        .content = "the user's preferred model is claude-sonnet for coding tasks",
        .tags = &.{"preferences"},
        .id = "mem-coding",
    });
    defer freeMemoryRow(alloc, row1);
    const row2 = try saveMemory(alloc, &ctx.db, .{
        .content = "the project's database is SQLite with FTS5 enabled",
        .tags = &.{"project"},
        .id = "mem-database",
    });
    defer freeMemoryRow(alloc, row2);
    const row3 = try saveMemory(alloc, &ctx.db, .{
        .content = "claude-sonnet is also the user's preferred writing model",
        .tags = &.{"preferences"},
        .id = "mem-writing",
    });
    defer freeMemoryRow(alloc, row3);

    // Search for "preferred" — should return 2 hits (coding + writing).
    const hits = try loadMemoriesByFts(alloc, &ctx.db, .{
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

    const row1 = try saveMemory(alloc, &ctx.db, .{
        .content = "memory one with model preference",
        .tags = &.{"preferences", "user"},
        .id = "mem-one",
    });
    defer freeMemoryRow(alloc, row1);
    const row2 = try saveMemory(alloc, &ctx.db, .{
        .content = "memory two with project context",
        .tags = &.{"preferences", "project"},
        .id = "mem-two",
    });
    defer freeMemoryRow(alloc, row2);
    const row3 = try saveMemory(alloc, &ctx.db, .{
        .content = "memory three with project context",
        .tags = &.{"project"},
        .id = "mem-three",
    });
    defer freeMemoryRow(alloc, row3);

    // Search for "context" + filter by tags=["project"] → should return
    // mem-two + mem-three (both have "project" tag) but NOT mem-one
    // (only has "preferences" + "user").
    const hits = try loadMemoriesByFts(alloc, &ctx.db, .{
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
    const hits2 = try loadMemoriesByFts(alloc, &ctx.db, .{
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
        const row = try saveMemory(alloc, &ctx.db, .{
            .content = content,
            .tags = &.{},
            .id = id,
        });
        freeMemoryRow(alloc, row);
    }

    // Page 1: limit=10 offset=0 → 10 rows, total=15.
    {
        const hits = try loadMemoriesByFts(alloc, &ctx.db, .{
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
        const hits = try loadMemoriesByFts(alloc, &ctx.db, .{
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
        const hits = try loadMemoriesByFts(alloc, &ctx.db, .{
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

    const row1 = try saveMemory(alloc, &ctx.db, .{
        .content = "the test memory content",
        .tags = &.{"test"},
        .id = "test-id-exists",
    });
    defer freeMemoryRow(alloc, row1);

    // Existing id → returns the row.
    const found = (try getMemoryById(alloc, &ctx.db, "test-id-exists")) orelse return error.GetReturnedNull;
    defer freeMemoryRow(alloc, found);
    try testing.expectEqualStrings("test-id-exists", found.id);
    try testing.expectEqualStrings("the test memory content", found.content);
    try testing.expectEqualStrings("test", found.tags);

    // Missing id → returns null (not error).
    const missing = try getMemoryById(alloc, &ctx.db, "no-such-id");
    try testing.expect(missing == null);
}