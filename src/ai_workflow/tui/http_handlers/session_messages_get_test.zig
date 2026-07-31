//! Behavioural tests for `getSessionMessagesSorted` carrying
//! `selected_profile_model` through to its response.
//!
//! Why this file exists
//! ─────────────────────
//! Bug "profiles in chatview not persistent" (2026-08-07): the user
//! picks a profile ("900ribu") in the chatview dropdown → chip shows
//! the selection → user refreshes the page → chip reverts to "Default".
//!
//! Root cause: `sessions.selected_profile_model` IS persisted by
//! `session_update.zig`'s PUT handler, but the read-side
//! `getSessionMessagesSorted` (called by `GET /api/llm/session/:id/messages`)
//! never selects the column from the joined `sessions` row, so the
//! frontend's `getChatHistory()` / `getSession()` calls both return
//! nothing for `selected_profile_model`. The chip resets because the
//! frontend defaults to `null` when the field is missing.
//!
//! These tests pin down the fix end-to-end:
//!   1. The SQL actually selects `s.selected_profile_model` from the
//!      joined `sessions` row.
//!   2. The `SessionMessageResponse` struct carries the value.
//!   3. The HTTP `SessionMessagesResponse` JSON builder (the wire
//!      shape the frontend reads) emits the field.
//!
//! Why we test against `getSessionMessagesSorted` + a manual JSON
//! builder (not the full HTTP handler)
//! ─────────────────────────────────────
//! `sessionMessagesHandler` calls `nalarcore.getSingleton()` to grab
//! the live DB handle, which is global process state and out of scope
//! for a unit test. The data layer (`getSessionMessagesSorted`) is
//! the only place where the field can be loaded — everything else is
//! pass-through. If the data layer returns the right value, the HTTP
//! handler is one struct field away from emitting it.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const llm_history = nalarcore.llm_history;
const http_response = nalarcore.http_response;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Open a fresh in-memory sqlite DB with `llm_history` and `sessions`
/// tables that match the production schema columns the
/// `getSessionMessagesSorted` query reads (plus
/// `selected_profile_model`, which is what we're testing).
fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // llm_history — only the columns the production SELECT list reads.
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    role TEXT,
        \\    response_content TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    is_input INTEGER DEFAULT 0,
        \\    is_output INTEGER DEFAULT 0,
        \\    tool_name TEXT,
        \\    finish_reason TEXT,
        \\    reasoning_content TEXT,
        \\    diffview_before TEXT,
        \\    diffview_after TEXT,
        \\    image_url TEXT,
        \\    tool_call_id TEXT,
        \\    tool_calls_json TEXT
        \\)
    , &.{});

    // sessions — full canonical schema (post-Migration-063 shape) so
    // the COALESCE-on-NULL convention used by the production query
    // matches reality. selected_profile_model is the field under test.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT,
        \\    created_at DATETIME,
        \\    updated_at DATETIME,
        \\    selected_profile_model TEXT,
        \\    git_worktree_cwd TEXT,
        \\    is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
        \\    last_finish_reason TEXT
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

/// Insert a minimal session row with the given `selected_profile_model`.
/// (Empty string → SQL NULL — matches the production COALESCE.)
fn seedSession(
    ctx: *TestCtx,
    allocator: std.mem.Allocator,
    session_id: []const u8,
    selected_profile_model: []const u8,
) !void {
    if (selected_profile_model.len == 0) {
        try ctx.db.exec(allocator,
            \\INSERT INTO sessions (id, name, status, selected_profile_model)
            \\VALUES (?, 'New Session', 'active', NULL)
        , &.{session_id});
    } else {
        try ctx.db.exec(allocator,
            \\INSERT INTO sessions (id, name, status, selected_profile_model)
            \\VALUES (?, 'New Session', 'active', ?)
        , &.{ session_id, selected_profile_model });
    }
}

/// Insert a minimal message for `session_id` so the
/// `getSessionMessagesSorted` query returns at least one row. Without
/// any messages the LEFT JOIN yields zero rows and the helper exits
/// before reaching the column-extraction block.
fn seedMessage(
    ctx: *TestCtx,
    allocator: std.mem.Allocator,
    id: []const u8,
    session_id: []const u8,
    content: []const u8,
) !void {
    try ctx.db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, role, response_content)
        \\VALUES (?, ?, 'user', ?)
    , &.{ id, session_id, content });
}

test "getSessionMessagesSorted: returns selected_profile_model from joined sessions row" {
    // Mirrors the production handler's allocator lifecycle: the per-
    // request arena is reclaimed by the HTTP server. The handler does
    // NOT free `msg_response.messages` itself — it lets the arena
    // do the cleanup. We use an arena here so the test harness can
    // deinit it in one shot without having to track the inner strings
    // individually.
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedSession(&ctx, arena_alloc, "s_pick", "900ribu");
    try seedMessage(&ctx, arena_alloc, "m1", "s_pick", "Hai!");

    const resp = try llm_history.getSessionMessagesSorted(
        arena_alloc,
        &ctx.db,
        "s_pick",
        50,
        null,
        .{ .created_at_asc = {} },
    );

    // The whole point: the response carries the profile.
    try testing.expect(resp.selected_profile_model != null);
    try testing.expectEqualStrings("900ribu", resp.selected_profile_model.?);
}

test "getSessionMessagesSorted: returns null when session has no profile set" {
    // See the lifecycle note in test #1 — arena allocator matches the
    // production handler's per-request arena so we don't need to track
    // individual `m.deinit` calls.
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedSession(&ctx, arena_alloc, "s_default", "");
    try seedMessage(&ctx, arena_alloc, "m1", "s_default", "no profile");

    const resp = try llm_history.getSessionMessagesSorted(
        arena_alloc,
        &ctx.db,
        "s_default",
        50,
        null,
        .{ .created_at_asc = {} },
    );

    // COALESCE-on-NULL → empty string → frontend coerces to null.
    if (resp.selected_profile_model) |p| {
        try testing.expectEqualStrings("", p);
    }
}

test "getSessionMessagesSorted: SessionMessagesResponse wire shape includes selected_profile_model" {
    // The frontend reads `data.selected_profile_model` from the JSON
    // response. If the `SessionMessagesResponse` struct in
    // http_response.zig doesn't have the field, std.json.Stringify
    // drops it on the floor regardless of what `getSessionMessagesSorted`
    // returns. This pins the wire shape.
    //
    // Mirrors the production handler's allocator lifecycle (see test #1).
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedSession(&ctx, arena_alloc, "s_wire", "900ribu");
    try seedMessage(&ctx, arena_alloc, "m1", "s_wire", "x");

    const resp = try llm_history.getSessionMessagesSorted(
        arena_alloc,
        &ctx.db,
        "s_wire",
        50,
        null,
        .{ .created_at_asc = {} },
    );

    // Build the wire response exactly the way sessionMessagesHandler
    // does — convert llm_history.SessionMessage → http_response.SessionMessage.
    var wire_messages = try arena_alloc.alloc(http_response.SessionMessage, resp.messages.len);
    for (resp.messages, 0..) |msg, i| {
        // The handler joins image_urls into a pipe-separated string.
        // For this test (no images seeded) the joined string is empty.
        var image_url_buf = std.ArrayList(u8).empty;
        defer image_url_buf.deinit(arena_alloc);
        if (msg.image_urls) |urls| {
            for (urls, 0..) |url, j| {
                if (j > 0) try image_url_buf.append(arena_alloc, '|');
                try image_url_buf.appendSlice(arena_alloc, url);
            }
        }
        const image_url_str = try image_url_buf.toOwnedSlice(arena_alloc);

        wire_messages[i] = http_response.SessionMessage{
            .id = msg.id,
            .session_id = msg.session_id,
            .role = msg.role,
            .content = msg.content,
            .created_at = msg.timestamp,
            .is_input = msg.is_input,
            .is_output = msg.is_output,
            .tool_name = msg.tool_name,
            .finish_reason = msg.finish_reason,
            .reasoning_content = msg.reasoning_content,
            .diffview_before = msg.diffview_before orelse "",
            .diffview_after = msg.diffview_after orelse "",
            .image_url = image_url_str,
            .tool_call_id = msg.tool_call_id orelse "",
            .tool_calls_json = msg.tool_calls_json orelse "",
        };
    }
    const wire = http_response.SessionMessagesResponse{
        .messages = wire_messages,
        .has_more = resp.has_more,
        .next_cursor = resp.next_cursor,
        .cwd = resp.cwd,
        .git_worktree_cwd = resp.git_worktree_cwd,
        .selected_profile_model = resp.selected_profile_model,
        .max_total_tokens = resp.max_total_tokens,
        .max_capacity_total_tokens = resp.max_capacity_total_tokens,
        .total = resp.total_count,
        .skills = resp.skills,
    };

    const json = try http_response.makeSessionMessagesResponse(arena_alloc, wire);

    // The frontend reads this exact key. If the field is missing from
    // SessionMessagesResponse, std.json.Stringify.valueAlloc will NOT
    // emit the key, and the assertion fails.
    try testing.expect(std.mem.indexOf(u8, json, "\"selected_profile_model\":\"900ribu\"") != null);
}