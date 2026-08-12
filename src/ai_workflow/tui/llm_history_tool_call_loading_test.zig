//! Behavioural tests for the tool-call-loading-placeholder helpers
//! (Migration 068 + handle_tool 3-phase pattern, plan
//! `docs/superpowers/plans/2026-08-06-tool-call-loading-placeholder.md`).
//!
//! Three new helpers in `llm_history.zig`:
//!
//!   - `saveToolResultPlaceholder(db, opts)` — INSERT a `role=tool` row
//!     with `tool_call_id=<id>`, `is_loading=1`, `is_feed_to_llm=1`,
//!     empty content. Returns the new row's id.
//!   - `updateToolResultById(db, tool_call_id, content, ...)` —
//!     UPDATE the row in place, preserving `created_at` / `created_iso`,
//!     setting `is_loading=0` and replacing content with the actual
//!     tool result.
//!   - `resolveStaleLoadingToolResults(db, session_id)` —
//!     UPDATEs every `is_loading=1` row in the session to
//!     "<interrupted>...</interrupted>" + `is_loading=0`. Idempotent.
//!
//! Together they implement the 3-phase tool-call pattern that prevents
//! "Invalid function ID tool call error" when the agent crashes
//! mid-execution.

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const llm_history = @import("nalarcore").llm_history;
const migration = @import("../../migrations/migration.zig");

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    alloc: std.mem.Allocator,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Walk every production migration (001 → 068) so the schema
    // matches production. Manual schema setup drifts the moment a
    // migration lands; see project memory
    // `llm-history-test-use-migrations-module.md`.
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded, .alloc = alloc };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

/// Insert a session row so we can FK-reference it in tests below.
/// The production schema (after all migrations) requires a
/// `sessions` row before llm_history rows reference its id.
fn createSession(ctx: *TestCtx, session_id: []const u8) !void {
    var buf: [256]u8 = undefined;
    const stmt = try std.fmt.bufPrint(buf[0..],
        "INSERT INTO sessions (id, name) VALUES ('{s}', 'test-session')", .{session_id});
    try ctx.db.exec(ctx.alloc, stmt, &.{});
}

test "saveToolResultPlaceholder inserts row with is_loading=1 and empty content" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    try createSession(&ctx, "sess_1");

    const opts = llm_history.SaveToolResultPlaceholderOptions{
        .session_id = "sess_1",
        .model = "test-model",
        .tool_call_id = "tcA",
        .tool_name = "bash",
        .loop_index = 0,
    };
    const new_id = try llm_history.saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts);
    defer ctx.alloc.free(new_id);

    var q = try ctx.db.query(ctx.alloc,
        "SELECT response_content, is_loading, is_feed_to_llm " ++
            "FROM llm_history WHERE tool_call_id = ?",
        &.{"tcA"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(ctx.alloc);
    try testing.expectEqualStrings("", row.values[0]);
    try testing.expectEqualStrings("1", row.values[1]);
    try testing.expectEqualStrings("1", row.values[2]);
}

test "saveToolResultPlaceholder enforces the UNIQUE INDEX on tool_call_id" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    try createSession(&ctx, "sess_1");

    const opts = llm_history.SaveToolResultPlaceholderOptions{
        .session_id = "sess_1",
        .model = "test-model",
        .tool_call_id = "tcA",
        .tool_name = "bash",
        .loop_index = 0,
    };
    const id1 = try llm_history.saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts);
    defer ctx.alloc.free(id1);

    // Second placeholder with the SAME tool_call_id — must fail.
    const id2 = llm_history.saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts);
    try testing.expectError(error.ExecuteFailed, id2);
}

test "saveToolResultPlaceholder allows multiple empty tool_call_id rows (assistant message shape)" {
    // The partial UNIQUE INDEX excludes empty-string tool_call_ids
    // (`WHERE tool_call_id IS NOT NULL AND tool_call_id != ''`). So
    // an unlimited number of rows with `tool_call_id = ''` (the
    // assistant message shape) can coexist without conflict.
    var ctx = try setupDb();
    defer teardown(&ctx);
    try createSession(&ctx, "sess_1");

    const opts = llm_history.SaveToolResultPlaceholderOptions{
        .session_id = "sess_1",
        .model = "test-model",
        .tool_call_id = "",
        .tool_name = "bash",
        .loop_index = 0,
    };
    const id1 = try llm_history.saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts);
    defer ctx.alloc.free(id1);
    const id2 = try llm_history.saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts);
    defer ctx.alloc.free(id2);
}

test "updateToolResultById updates content + is_loading=0 in place" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    try createSession(&ctx, "sess_1");

    const opts = llm_history.SaveToolResultPlaceholderOptions{
        .session_id = "sess_1",
        .model = "test-model",
        .tool_call_id = "tcA",
        .tool_name = "bash",
        .loop_index = 0,
    };
    const id = try llm_history.saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts);
    defer ctx.alloc.free(id);

    try llm_history.updateToolResultById(ctx.alloc, ctx.threaded.io(), &ctx.db, id, .{
        .content = "actual bash result",
        .diffview_before = null,
        .diffview_after = null,
    });

    var q = try ctx.db.query(ctx.alloc,
        "SELECT response_content, is_loading FROM llm_history WHERE tool_call_id = ?",
        &.{"tcA"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(ctx.alloc);
    try testing.expectEqualStrings("actual bash result", row.values[0]);
    try testing.expectEqualStrings("0", row.values[1]);
}

test "updateToolResultById on a non-existent tool_call_id is a no-op (no error)" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    // No pre-existing placeholder — the UPDATE must be a no-op,
    // returning Ok(()) with 0 rows affected.
    try llm_history.updateToolResultById(ctx.alloc, ctx.threaded.io(), &ctx.db, "tc_ghost", .{
        .content = "should be discarded",
        .diffview_before = null,
        .diffview_after = null,
    });

    var q = try ctx.db.query(ctx.alloc,
        "SELECT 1 FROM llm_history WHERE tool_call_id = ?",
        &.{"tc_ghost"});
    defer q.deinit();
    try testing.expect((try q.next()) == null);
}

test "updateToolResultById accepts and stores diffview_before / diffview_after" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    try createSession(&ctx, "sess_1");

    const opts = llm_history.SaveToolResultPlaceholderOptions{
        .session_id = "sess_1",
        .model = "test-model",
        .tool_call_id = "tcA",
        .tool_name = "text_replace",
        .loop_index = 0,
    };
    const id = try llm_history.saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts);
    defer ctx.alloc.free(id);

    try llm_history.updateToolResultById(ctx.alloc, ctx.threaded.io(), &ctx.db, id, .{
        .content = "diff content",
        .diffview_before = "old content",
        .diffview_after = "new content",
    });

    var q = try ctx.db.query(ctx.alloc,
        "SELECT diffview_before, diffview_after FROM llm_history WHERE tool_call_id = ?",
        &.{"tcA"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(ctx.alloc);
    try testing.expectEqualStrings("old content", row.values[0]);
    try testing.expectEqualStrings("new content", row.values[1]);
}

test "resolveStaleLoadingToolResults replaces all stranded placeholders with interrupted" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    try createSession(&ctx, "sess_1");

    // Insert 3 stranded placeholders.
    for ([_][]const u8{ "tcA", "tcB", "tcC" }) |tc| {
        const opts = llm_history.SaveToolResultPlaceholderOptions{
            .session_id = "sess_1",
            .model = "test-model",
            .tool_call_id = tc,
            .tool_name = "bash",
            .loop_index = 0,
        };
        const id = try llm_history.saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts);
        defer ctx.alloc.free(id);
    }

    // Resolve them.
    try llm_history.resolveStaleLoadingToolResults(ctx.alloc, &ctx.db, "sess_1");

    // All 3 should now have is_loading=0 and an interrupted-style content.
    for ([_][]const u8{ "tcA", "tcB", "tcC" }) |tc| {
        var q = try ctx.db.query(ctx.alloc,
            "SELECT response_content, is_loading FROM llm_history WHERE tool_call_id = ?",
            &.{tc});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(ctx.alloc);
        try testing.expectEqualStrings("0", row.values[1]);
        try testing.expect(std.mem.indexOf(u8, row.values[0], "interrupted") != null);
        try testing.expect(std.mem.indexOf(u8, row.values[0], "retry") != null);
    }
}

test "resolveStaleLoadingToolResults is idempotent on a session with no stranded rows" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    try createSession(&ctx, "sess_1");

    // No placeholders. The call must succeed with 0 rows affected.
    try llm_history.resolveStaleLoadingToolResults(ctx.alloc, &ctx.db, "sess_1");

    // Insert a placeholder, UPDATE it to is_loading=0, then resolve:
    // the resolved row must NOT be touched.
    const opts = llm_history.SaveToolResultPlaceholderOptions{
        .session_id = "sess_1",
        .model = "test-model",
        .tool_call_id = "tcA",
        .tool_name = "bash",
        .loop_index = 0,
    };
    const id = try llm_history.saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts);
    defer ctx.alloc.free(id);
    try llm_history.updateToolResultById(ctx.alloc, ctx.threaded.io(), &ctx.db, id, .{
        .content = "real result",
        .diffview_before = null,
        .diffview_after = null,
    });

    // Resolve — should be a no-op for this row.
    try llm_history.resolveStaleLoadingToolResults(ctx.alloc, &ctx.db, "sess_1");

    var q = try ctx.db.query(ctx.alloc,
        "SELECT response_content FROM llm_history WHERE tool_call_id = ?",
        &.{"tcA"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(ctx.alloc);
    try testing.expectEqualStrings("real result", row.values[0]);
    try testing.expect(std.mem.indexOf(u8, row.values[0], "interrupted") == null);
}

test "resolveStaleLoadingToolResults only touches the target session" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    try createSession(&ctx, "sess_1");
    try createSession(&ctx, "sess_2");

    // Insert a stranded placeholder in each session. Different
    // tool_call_ids because the partial UNIQUE INDEX is global
    // (not session-scoped) — two rows with the same tool_call_id
    // across different sessions would still collide.
    const opts1 = llm_history.SaveToolResultPlaceholderOptions{
        .session_id = "sess_1",
        .model = "test-model",
        .tool_call_id = "tc_sess_1_x",
        .tool_name = "bash",
        .loop_index = 0,
    };
    const id1 = try llm_history.saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts1);
    defer ctx.alloc.free(id1);

    const opts2 = llm_history.SaveToolResultPlaceholderOptions{
        .session_id = "sess_2",
        .model = "test-model",
        .tool_call_id = "tc_sess_2_y",
        .tool_name = "bash",
        .loop_index = 0,
    };
    const id2 = try llm_history.saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts2);
    defer ctx.alloc.free(id2);

    // Resolve only sess_1.
    try llm_history.resolveStaleLoadingToolResults(ctx.alloc, &ctx.db, "sess_1");

    // sess_1:tc_sess_1_x is interrupted.
    var q1 = try ctx.db.query(ctx.alloc,
        "SELECT response_content, is_loading FROM llm_history " ++
            "WHERE session_id = ? AND tool_call_id = ?",
        &.{ "sess_1", "tc_sess_1_x" });
    defer q1.deinit();
    const row1 = (try q1.next()) orelse return error.RowMissing;
    defer row1.deinit(ctx.alloc);
    try testing.expectEqualStrings("0", row1.values[1]);
    try testing.expect(std.mem.indexOf(u8, row1.values[0], "interrupted") != null);

    // sess_2:tc_sess_2_y is still is_loading=1 with empty content.
    var q2 = try ctx.db.query(ctx.alloc,
        "SELECT is_loading, response_content FROM llm_history " ++
            "WHERE session_id = ? AND tool_call_id = ?",
        &.{ "sess_2", "tc_sess_2_y" });
    defer q2.deinit();
    const row2 = (try q2.next()) orelse return error.RowMissing;
    defer row2.deinit(ctx.alloc);
    try testing.expectEqualStrings("1", row2.values[0]);
    try testing.expectEqualStrings("", row2.values[1]);
}
