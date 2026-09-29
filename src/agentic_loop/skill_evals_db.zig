//! Persistence for Skill Evals — Migration 095's usage ledger (and the home
//! for the eval-table repository that follows).
//!
//! ## Why a ledger exists at all
//!
//! `session_skills` (Migration 008) is an `INSERT OR REPLACE` keyed on
//! `(session_id, skill_name)`, written by `use_skill` alone. It therefore keeps
//! only the *latest* body of a skill a session loaded, and it cannot answer
//! three questions an eval depends on:
//!
//!   1. **Which turn** loaded this skill. (`session_skills` has no loop index,
//!      and its `loaded_at_nano` is re-stamped by every reload — and is
//!      seconds, despite the name.)
//!   2. **Was this skill merely listed and then ignored?** A skill the agent
//!      was offered and did not use is a real finding, and until now it left
//!      no trace at all: `list_skills` returns name/description/path only and
//!      writes nothing.
//!   3. **Has the body changed since it was read?** `content_hash` here is the
//!      hash of the body *as actually read*, so drift detection is a hash
//!      compare rather than a diff of two full bodies.
//!
//! It is append-only, with a fresh id per row, so nothing about it can
//! overwrite the history it is meant to preserve.
//!
//! ## Failure policy
//!
//! Every entry point on the write path **logs and swallows**. A ledger write
//! must never fail a tool turn — the tool already succeeded or failed on its
//! own terms, and the ledger is bookkeeping. This mirrors the existing
//! `SaveSkill` / `saveProgressiveTool` call sites in `handle_tool.zig`, which
//! use the same `catch |err| logger.errFmt(...)` shape.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const logger_mod = nalarcore.loggermod;
const migration = @import("../migrations/migration.zig");

/// The kinds of ledger row. Stored as text so a `SELECT` is readable without a
/// decoder, and so adding a kind later cannot invalidate existing rows.
pub const SkillEventKind = enum {
    /// The skill appeared in a `list_skills` result. Recorded once per
    /// `(session, skill)` — see `insertEvent`'s `dedupe` flag.
    listed,
    /// `use_skill` read the body. Carries `content_hash` of what was read.
    loaded,
    created,
    edited,
    removed,

    pub fn asString(self: SkillEventKind) []const u8 {
        return switch (self) {
            .listed => "listed",
            .loaded => "loaded",
            .created => "created",
            .edited => "edited",
            .removed => "removed",
        };
    }
};

/// Hex-encode SHA-256(input) into a 64-char lowercase string.
///
/// Allocation-free and caller-buffered, which is what lets the result be bound
/// straight into a `?` argument — `SqliteBackend`'s arg list is
/// `[]const []const u8`, so `&.{ hash_hex[0..] }` is the whole story and no
/// `allocPrint` is needed. Mirrors `auth_common.sha256Hex`; `fmtSliceHexLower`
/// does not exist in Zig 0.16, so this is the house idiom.
pub fn sha256Hex(input: []const u8, out: *[64]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &digest, .{});
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
}

pub const SkillToolEventArgs = struct {
    io: std.Io,
    /// The session that ran the tool — the ledger's primary read key.
    session_id: []const u8,
    /// `tool_call.function.name`.
    tool_name: []const u8,
    /// The wrapped tool result JSON (`{"tool":…,"success":…,"data":…}`).
    tool_result_json: []const u8,
    /// `handle_tool`'s `loop_counter` — the turn this happened on.
    loop_index: u32,
    /// The `llm_history` row id of this tool result, so the ledger can point
    /// back at its own evidence.
    llm_history_id: []const u8,
};

/// Append one ledger row.
///
/// `dedupe` uses a deterministic composite id and `INSERT OR IGNORE`, which
/// makes "first occurrence wins" a PRIMARY KEY property rather than a
/// read-then-write — the only correct shape here, because `SqliteBackend` has
/// no usable multi-statement transaction (`exec` releases its mutex per call;
/// see the atomicity note in `http_handlers/workspaces_reorder.zig`). A second
/// `list_skills` in the same session therefore cannot duplicate rows, and the
/// recorded `created_at` stays the moment the skill was *first* offered, which
/// is the fact the eval actually wants.
///
/// Non-deduped kinds get a fresh nanosecond id (`ordinal` disambiguates the
/// several rows a single `list_skills` call would otherwise emit in the same
/// nanosecond).
///
/// Free-text columns are wrapped in `COALESCE(NULLIF(?, ''), '')`: `exec` binds
/// an empty slice as SQL NULL, which would violate `NOT NULL` (the Migration
/// 079 `content` failure mode). `loop_index` is an INTEGER bound as text, the
/// repo-wide idiom.
pub fn insertEvent(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    args: SkillToolEventArgs,
    skill_name: []const u8,
    kind: SkillEventKind,
    content_hash: []const u8,
    ordinal: u32,
) !void {
    if (args.session_id.len == 0 or skill_name.len == 0) return;

    const source = args.tool_name;
    const loop_index_str = try std.fmt.allocPrint(allocator, "{d}", .{args.loop_index});
    defer allocator.free(loop_index_str);

    if (kind == .listed) {
        // Deterministic id ⇒ the PK does the dedupe and no read is needed.
        const id = try std.fmt.allocPrint(allocator, "sse:listed:{s}:{s}", .{ args.session_id, skill_name });
        defer allocator.free(id);
        try db.exec(allocator,
            \\INSERT OR IGNORE INTO session_skill_events
            \\    (id, session_id, skill_name, event, source, content_hash, loop_index, llm_history_id)
            \\VALUES
            \\    (?, ?, ?, 'listed', COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), ?, COALESCE(NULLIF(?, ''), ''))
        , &.{ id, args.session_id, skill_name, source, content_hash, loop_index_str, args.llm_history_id });
        return;
    }

    const id = try std.fmt.allocPrint(allocator, "sse:{d}_{d}", .{
        std.Io.Timestamp.now(args.io, .real).nanoseconds,
        ordinal,
    });
    defer allocator.free(id);

    try db.exec(allocator,
        \\INSERT INTO session_skill_events
        \\    (id, session_id, skill_name, event, source, content_hash, loop_index, llm_history_id)
        \\VALUES
        \\    (?, ?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), ?, COALESCE(NULLIF(?, ''), ''))
    , &.{
        id,
        args.session_id,
        skill_name,
        kind.asString(),
        source,
        content_hash,
        loop_index_str,
        args.llm_history_id,
    });
}

/// Read one string field out of the envelope's `data` object, or null.
fn dataString(data: std.json.Value, key: []const u8) ?[]const u8 {
    if (data != .object) return null;
    const v = data.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        .number_string => |s| s,
        else => null,
    };
}

fn dataArray(data: std.json.Value, key: []const u8) ?std.json.Array {
    if (data != .object) return null;
    const v = data.object.get(key) orelse return null;
    return switch (v) {
        .array => |a| a,
        else => null,
    };
}

const Envelope = struct {
    success: bool = false,
    data: ?std.json.Value = null,
};

/// Entry point for the save site in `handle_tool.zig`: one call per completed
/// skill-tool call, and it decides what (if anything) belongs in the ledger.
///
/// All parsing lives here rather than in `handle_tool` so the call site stays a
/// single line and this logic is unit-testable without a live tool turn. Never
/// returns an error: it logs and swallows, like every other writer at that site.
/// `?*Logger` so a caller (and a test) can pass `null` to discard the soft
/// failures this path logs. An optional logger is an existing pattern in this
/// directory — see `delete_worker.zig` and `background_watcher.zig`.
fn logWarn(logger: ?*logger_mod.Logger, comptime fmt: []const u8, args: anytype) void {
    if (logger) |l| l.warnFmt(fmt, args);
}

fn logDebug(logger: ?*logger_mod.Logger, comptime fmt: []const u8, args: anytype) void {
    if (logger) |l| l.debugFmt(fmt, args);
}

pub fn recordSkillToolEvents(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: ?*logger_mod.Logger,
    args: SkillToolEventArgs,
) void {
    if (args.session_id.len == 0) return;

    const is_skill_tool =
        std.mem.eql(u8, args.tool_name, "use_skill") or
        std.mem.eql(u8, args.tool_name, "list_skills") or
        std.mem.eql(u8, args.tool_name, "add_skill") or
        std.mem.eql(u8, args.tool_name, "edit_skill") or
        std.mem.eql(u8, args.tool_name, "remove_skill");
    if (!is_skill_tool) return;

    const parsed = std.json.parseFromSlice(Envelope, allocator, args.tool_result_json, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        logDebug(logger, "skill ledger: could not parse {s} result: {s}", .{ args.tool_name, @errorName(err) });
        return;
    };
    defer parsed.deinit();

    // A failed tool call changed nothing, so it records nothing. The ledger is
    // evidence about what the agent was offered and what it read — not a tool
    // call log (that is `llm_history`'s job).
    if (!parsed.value.success) return;
    const data = parsed.value.data orelse return;

    if (std.mem.eql(u8, args.tool_name, "list_skills")) {
        // One row per listed skill, deduped by the PK, so a session that lists
        // skills ten times still records each skill once — at the moment it was
        // FIRST offered. That is what makes "offered but never loaded"
        // answerable: `event = 'listed'` with no later `event = 'loaded'`.
        var ordinal: u32 = 0;
        for ([_][]const u8{ "global_skills", "local_skills" }) |bucket| {
            const arr = dataArray(data, bucket) orelse continue;
            for (arr.items) |entry| {
                const name = dataString(entry, "name") orelse continue;
                insertEvent(allocator, db, args, name, .listed, "", ordinal) catch |err| {
                    logWarn(logger, "skill ledger: failed to record 'listed' for '{s}': {s}", .{ name, @errorName(err) });
                };
                ordinal += 1;
            }
        }
        return;
    }

    const name = dataString(data, "skill_name") orelse dataString(data, "name") orelse return;

    if (std.mem.eql(u8, args.tool_name, "use_skill")) {
        // Only a real read carries a body; a `loaded: false` result (oversized,
        // unreadable) must not look like a successful load.
        const loaded = if (data == .object) blk: {
            const v = data.object.get("loaded") orelse break :blk false;
            break :blk switch (v) {
                .bool => |b| b,
                else => false,
            };
        } else false;
        if (!loaded) return;

        const content = dataString(data, "content") orelse "";
        var hash_buf: [64]u8 = undefined;
        sha256Hex(content, &hash_buf);
        insertEvent(allocator, db, args, name, .loaded, hash_buf[0..], 0) catch |err| {
            logWarn(logger, "skill ledger: failed to record 'loaded' for '{s}': {s}", .{ name, @errorName(err) });
        };
        return;
    }

    const kind: SkillEventKind = if (std.mem.eql(u8, args.tool_name, "add_skill"))
        .created
    else if (std.mem.eql(u8, args.tool_name, "edit_skill"))
        .edited
    else
        .removed;

    insertEvent(allocator, db, args, name, kind, "", 0) catch |err| {
        logWarn(logger, "skill ledger: failed to record '{s}' for '{s}': {s}", .{ kind.asString(), name, @errorName(err) });
    };
}

// ─── tests ───────────────────────────────────────────────────────────────

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

fn countEvents(db: *sqlite.SqliteBackend, alloc: std.mem.Allocator, session_id: []const u8) !i64 {
    var q = try db.query(alloc,
        "SELECT COUNT(*) FROM session_skill_events WHERE session_id = ?",
        &.{session_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}

fn eventCount(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    session_id: []const u8,
    event: []const u8,
) !i64 {
    var q = try db.query(alloc,
        "SELECT COUNT(*) FROM session_skill_events WHERE session_id = ? AND event = ?",
        &.{ session_id, event });
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}

fn testArgs(io: std.Io, session_id: []const u8, tool_name: []const u8, result: []const u8) SkillToolEventArgs {
    return .{
        .io = io,
        .session_id = session_id,
        .tool_name = tool_name,
        .tool_result_json = result,
        .loop_index = 7,
        .llm_history_id = "hist_1",
    };
}

test "sha256Hex matches a known vector and is stable" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    sha256Hex("hello", &a);
    sha256Hex("hello", &b);
    try testing.expectEqualStrings(a[0..], b[0..]);
    // Standard SHA-256("hello").
    try testing.expectEqualStrings(
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        a[0..],
    );
    // A one-byte difference must change the hash.
    var c: [64]u8 = undefined;
    sha256Hex("hellp", &c);
    try testing.expect(!std.mem.eql(u8, a[0..], c[0..]));
}

test "recordSkillToolEvents records a successful use_skill as 'loaded' with a content hash" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const body = "---\nname: my-skill\n---\n## Procedure\nstep\n";
    const result = try std.fmt.allocPrint(alloc,
        "{{\"tool\":\"use_skill\",\"success\":true,\"data\":{{\"skill_name\":\"my-skill\",\"content\":{f},\"loaded\":true}},\"error\":null,\"v\":1}}",
        .{std.json.fmt(body, .{})});
    defer alloc.free(result);

    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "use_skill", result));

    try testing.expectEqual(@as(i64, 1), try countEvents(&ctx.db, alloc, "sess_1"));
    try testing.expectEqual(@as(i64, 1), try eventCount(&ctx.db, alloc, "sess_1", "loaded"));

    var q = try ctx.db.query(alloc,
        "SELECT content_hash, loop_index, llm_history_id, source FROM session_skill_events WHERE session_id = ?",
        &.{"sess_1"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);

    // The hash must match the body that was read — that is the whole point of
    // storing it (drift becomes a hash compare later).
    var expected: [64]u8 = undefined;
    sha256Hex(body, &expected);
    try testing.expectEqualStrings(expected[0..], row.values[0]);
    try testing.expectEqualStrings("7", row.values[1]);
    try testing.expectEqualStrings("hist_1", row.values[2]);
    try testing.expectEqualStrings("use_skill", row.values[3]);
}

test "recordSkillToolEvents ignores a use_skill that did not load" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // `loaded: false` (oversized / unreadable) must not look like a successful
    // load, or the eval would judge a body the agent never saw.
    const result =
        \\{"tool":"use_skill","success":true,"data":{"skill_name":"big","content":"","loaded":false},"error":null,"v":1}
    ;
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "use_skill", result));
    try testing.expectEqual(@as(i64, 0), try countEvents(&ctx.db, alloc, "sess_1"));
}

test "recordSkillToolEvents ignores a failed tool call" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result =
        \\{"tool":"use_skill","success":false,"data":null,"error":"use_skill failed: InvalidInput","v":1}
    ;
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "use_skill", result));
    try testing.expectEqual(@as(i64, 0), try countEvents(&ctx.db, alloc, "sess_1"));
}

test "recordSkillToolEvents records one 'listed' row per offered skill, in both scopes" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result =
        \\{"tool":"list_skills","success":true,"data":{"global_skills":[{"name":"g-one","description":"d","path":"/p"},{"name":"g-two","description":"d","path":"/p"}],"local_skills":[{"name":"l-one","description":"d","path":"/p"}],"cwd":"/cwd"},"error":null,"v":1}
    ;
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "list_skills", result));

    try testing.expectEqual(@as(i64, 3), try countEvents(&ctx.db, alloc, "sess_1"));
    try testing.expectEqual(@as(i64, 3), try eventCount(&ctx.db, alloc, "sess_1", "listed"));

    // A `listed` row must NOT claim a body hash — nothing was read.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM session_skill_events WHERE session_id = ? AND content_hash = ''",
        &.{"sess_1"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("3", row.values[0]);
}

test "a second list_skills does not duplicate 'listed' rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result =
        \\{"tool":"list_skills","success":true,"data":{"global_skills":[{"name":"g-one","description":"d","path":"/p"}],"local_skills":[],"cwd":"/cwd"},"error":null,"v":1}
    ;
    const args = testArgs(ctx.threaded.io(), "sess_1", "list_skills", result);
    recordSkillToolEvents(alloc, &ctx.db, null, args);
    recordSkillToolEvents(alloc, &ctx.db, null, args);
    recordSkillToolEvents(alloc, &ctx.db, null, args);

    // The deterministic composite id means the PRIMARY KEY does the dedupe, so
    // this holds without any read-then-write (which would be a TOCTOU bug).
    try testing.expectEqual(@as(i64, 1), try countEvents(&ctx.db, alloc, "sess_1"));
}

test "a listed skill and a loaded skill coexist for the same name" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const listed =
        \\{"tool":"list_skills","success":true,"data":{"global_skills":[{"name":"my-skill","description":"d","path":"/p"}],"local_skills":[],"cwd":"/cwd"},"error":null,"v":1}
    ;
    const loaded =
        \\{"tool":"use_skill","success":true,"data":{"skill_name":"my-skill","content":"body","loaded":true},"error":null,"v":1}
    ;
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "list_skills", listed));
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "use_skill", loaded));

    // Two rows, two kinds — this pair is exactly what distinguishes "offered
    // and then used" from "offered and ignored".
    try testing.expectEqual(@as(i64, 2), try countEvents(&ctx.db, alloc, "sess_1"));
    try testing.expectEqual(@as(i64, 1), try eventCount(&ctx.db, alloc, "sess_1", "listed"));
    try testing.expectEqual(@as(i64, 1), try eventCount(&ctx.db, alloc, "sess_1", "loaded"));
}

test "recordSkillToolEvents handles add/edit/remove" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const cases = [_]struct { tool: []const u8, event: []const u8, result: []const u8 }{
        .{ .tool = "add_skill", .event = "created", .result =
        \\{"tool":"add_skill","success":true,"data":{"skill_name":"new-skill","name":"new-skill","created":true,"path":"/p"},"error":null,"v":1}
        },
        .{ .tool = "edit_skill", .event = "edited", .result =
        \\{"tool":"edit_skill","success":true,"data":{"skill_name":"new-skill","name":"new-skill","updated":true,"path":"/p"},"error":null,"v":1}
        },
        .{ .tool = "remove_skill", .event = "removed", .result =
        \\{"tool":"remove_skill","success":true,"data":{"skill_name":"new-skill","removed":true,"path":"/p"},"error":null,"v":1}
        },
    };

    for (cases) |c| {
        recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", c.tool, c.result));
        try testing.expectEqual(@as(i64, 1), try eventCount(&ctx.db, alloc, "sess_1", c.event));
    }
    try testing.expectEqual(@as(i64, 3), try countEvents(&ctx.db, alloc, "sess_1"));
}

test "recordSkillToolEvents tolerates a payload it cannot parse" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // A tool result that is not JSON at all, and one whose `data` was wrapped as
    // `{"_raw":…}` by `normalizeDataFragment`. Neither may throw or write.
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "use_skill", "not json"));
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "list_skills",
        \\{"tool":"list_skills","success":true,"data":{"_raw":"oops"},"error":null,"v":1}
    ));
    try testing.expectEqual(@as(i64, 0), try countEvents(&ctx.db, alloc, "sess_1"));
}

test "recordSkillToolEvents ignores tools that are not skill tools" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result =
        \\{"tool":"read_file","success":true,"data":{"skill_name":"sneaky"},"error":null,"v":1}
    ;
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "read_file", result));
    try testing.expectEqual(@as(i64, 0), try countEvents(&ctx.db, alloc, "sess_1"));
}

test "recordSkillToolEvents is a no-op without a session id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result =
        \\{"tool":"use_skill","success":true,"data":{"skill_name":"my-skill","content":"b","loaded":true},"error":null,"v":1}
    ;
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "", "use_skill", result));
    try testing.expectEqual(@as(i64, 0), try countEvents(&ctx.db, alloc, "sess_1"));
}
