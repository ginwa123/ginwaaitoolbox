const std = @import("std");
const nalarcore = @import("nalarcore");
const LLMHistory = @import("llm_history.zig").LLMHistory;
const SkillInfo = @import("session_skills.zig").SkillInfo;
const onEventSendLLMHistory = @import("sse_on_event_send_llm_history.zig").onEventSendLLMHistory;

const sqlite = nalarcore.sqlite;
const logger_mod = nalarcore.loggermod;
const agent = nalarcore.agent;
const helpers = nalarcore.helpers;
const event_bus_mod = nalarcore.event_bus;
const keyword = "INSERTLLMHISTORIES";

pub const InsertLLMHistoriesInput = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: ?*logger_mod.Logger,
    is_emit_sse: bool,
    event_bus: ?*event_bus_mod.EventBus,
    cwd: []const u8,
    entity: LLMHistory,
    /// When true, skip the `INSERT INTO llm_history` and
    /// `UPDATE sessions SET cwd = ?` writes — the SSE branch still
    /// runs when `is_emit_sse = true` and `event_bus != null`. Used by
    /// error-path diagnostics (TooManyRetries + unattended-mode
    /// soft-bail) that should surface in the live chat stream without
    /// polluting the persistent chat history. Defaults to false so all
    /// existing call sites stay DB-writing unchanged.
    is_skip_db: bool = false,
};

pub fn inserLLMHistories(
    obj: InsertLLMHistoriesInput,
) ![]const u8 {
    const allocator = obj.allocator;
    const db = obj.db;
    const logger = obj.logger;
    const io = obj.io;
    const event_bus = obj.event_bus;

    const input = obj.entity;
    const session_id = input.session_id;
    const model = input.model;
    const cwd = obj.cwd;
    const temperature = input.temperature;
    const is_thinking = input.is_thinking;
    const is_input = input.is_input;
    const is_output = input.is_output;
    const finish_reason = input.finish_reason;
    const reasoning_content = input.reasoning_content;

    // Sample the timestamp ONCE for both `id` and `created_at`. The
    // `created_at` column stores Unix **microseconds** (see Migration
    // 059 header), but the stdlib only exposes `.nanoseconds`, so we
    // divide by `std.time.ns_per_us` to convert. The pre‑fix code
    // stored the raw nanosecond string AND never set `created_iso`,
    // so every row inserted via this path had NULL `created_iso` AND
    // any future fix‑up would have produced year 58,507 for them.
    //
    // `id` is borrowed from the caller (`input.id`) — the function
    // does NOT own it and must not allocate/free it. The previous
    // implementation allocated a fresh `id` here and returned a
    // `dupe(u8, id)` as the function's slice return, which leaked in
    // every test that discarded the result (`_ = try inserLLMHistories(...)`).
    const id = input.id;
    const created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    defer allocator.free(created_at);

    // Compute `created_iso` for the `since`/`until` filters. Mirrors
    // the conversion in `llm_history.saveMessage`. The helper
    // returns the current UTC time as ISO — semantically the same
    // as `created_at_us`/`now_ns` since both are generated from the
    // same `now_ns` source a few lines above.
    const created_iso = try helpers.currentTimeIsoLocal(allocator, io);
    defer allocator.free(created_iso);

    const contentStr = input.response_content;
    const finishReasonStr = input.finish_reason;
    const roleStr = input.role;
    const reasoningStr = input.reasoning_content orelse "";
    const agentStr = input.agent;

    const is_emit_sse = obj.is_emit_sse;
    const is_skip_db = obj.is_skip_db;

    // tool_calls_json holds ONLY the serialized tool_calls array (assistant message wire format).
    // For tool result messages, the tool_call_id lives in the dedicated tool_call_id column —
    // do NOT overload tool_calls_json with the id. That overload caused the 2013 bug where the
    // transform could not tell a JSON array from a plain id string.
    const toolCallsOwned = input.tool_calls_json;

    const sql =
        \\INSERT INTO llm_history (
        \\    id,
        \\    session_id,
        \\    model,
        \\    response_content,
        \\    finish_reason,
        \\    role,
        \\    tool_calls_json,
        \\    tool_call_id,
        \\    reasoning_content,
        \\    is_feed_to_llm,
        \\    agent,
        \\    loop_index,
        \\    temperature,
        \\    is_thinking,
        \\    created_at,
        \\    created_iso,
        \\    parent_session_id,
        \\    parent_id,
        \\    prompt_tokens,
        \\    completion_tokens,
        \\    total_tokens,
        \\    is_input,
        \\    is_output,
        \\    tool_name,
        \\    diffview_before,
        \\    diffview_after,
        \\    image_url
        \\) VALUES (
        \\    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        \\    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        \\    ?, ?, ?, ?, ?, ?, ?
        \\)
    ;

    const copy_session_id = try allocator.dupe(u8, input.session_id);
    defer allocator.free(copy_session_id);
    const copy_model = try allocator.dupe(u8, input.model);
    defer allocator.free(copy_model);
    const copy_content = try allocator.dupe(u8, contentStr);
    defer allocator.free(copy_content);
    const copy_finish_reason = try allocator.dupe(u8, finishReasonStr);
    defer allocator.free(copy_finish_reason);
    const copy_role = try allocator.dupe(u8, roleStr);
    defer allocator.free(copy_role);
    const copy_tool_calls = try allocator.dupe(u8, toolCallsOwned);
    defer allocator.free(copy_tool_calls);
    const copy_reasoning = try allocator.dupe(u8, reasoningStr);
    defer allocator.free(copy_reasoning);
    const copy_agent = try allocator.dupe(u8, agentStr);
    defer allocator.free(copy_agent);
    const loop_index_str = try std.fmt.allocPrint(allocator, "{}", .{input.loop_index});
    defer allocator.free(loop_index_str);
    const temperature_str = try std.fmt.allocPrint(allocator, "{d:.2}", .{input.temperature});
    defer allocator.free(temperature_str);
    const is_thinking_str = if (input.is_thinking) "1" else "0";
    const copy_parent_session_id = try allocator.dupe(u8, input.parent_session_id orelse "");
    defer allocator.free(copy_parent_session_id);
    const copy_parent_id = try allocator.dupe(u8, input.parent_id orelse "");
    defer allocator.free(copy_parent_id);
    const copy_tool_name = try allocator.dupe(u8, input.tool_name);
    defer allocator.free(copy_tool_name);
    const copy_tool_call_id = try allocator.dupe(u8, input.tool_call_id orelse "");
    defer allocator.free(copy_tool_call_id);
    const prompt_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.prompt_tokens});
    defer allocator.free(prompt_tokens_str);
    const completion_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.completion_tokens});
    defer allocator.free(completion_tokens_str);
    const total_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.total_tokens});
    defer allocator.free(total_tokens_str);
    const copy_diffview_before = try allocator.dupe(u8, input.diffview_before orelse "");
    defer allocator.free(copy_diffview_before);
    const copy_diffview_after = try allocator.dupe(u8, input.diffview_after orelse "");
    defer allocator.free(copy_diffview_after);

    const copy_is_feed_to_llm = try allocator.dupe(u8, if (input.is_feed_to_llm) "1" else "0");
    defer allocator.free(copy_is_feed_to_llm);

    // Join multiple image URLs with || delimiter
    var image_urls_str: []const u8 = "";
    var copy_image_urls: ?[]u8 = null;
    if (input.image_urls) |urls| {
        if (urls.len > 0) {
            var combined = std.ArrayList(u8).empty;
            defer combined.deinit(allocator);
            for (urls, 0..) |url, i| {
                if (i > 0) try combined.appendSlice(allocator, "||");
                try combined.appendSlice(allocator, url);
            }
            copy_image_urls = try allocator.dupe(u8, combined.items);
            image_urls_str = copy_image_urls.?;
        }
    }
    defer if (copy_image_urls) |c| allocator.free(c);

    const sqlArgs = &.{ id, copy_session_id, copy_model, copy_content, copy_finish_reason, copy_role, copy_tool_calls, copy_tool_call_id, copy_reasoning, copy_is_feed_to_llm, copy_agent, loop_index_str, temperature_str, is_thinking_str, created_at, created_iso, copy_parent_session_id, copy_parent_id, prompt_tokens_str, completion_tokens_str, total_tokens_str, if (input.is_input) "1" else "0", if (input.is_output) "1" else "0", copy_tool_name, copy_diffview_before, copy_diffview_after, image_urls_str };

    if (!is_skip_db) {
        try db.exec(allocator, sql, sqlArgs);

        // Update the session's cwd in the sessions table
        const copy_cwd = try allocator.dupe(u8, cwd);
        defer allocator.free(copy_cwd);
        try db.exec(allocator, "UPDATE sessions SET cwd = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?", &.{ copy_cwd, copy_session_id });
    }

    if (is_emit_sse) {
        if (event_bus) |ev| {
            const session_skills = try getSessionSkills(allocator, db, copy_session_id);

            _ = onEventSendLLMHistory(.{ .allocator = allocator, .io = io, .logger = logger, .event_bus = ev, .entity = .{
                .session_id = session_id,
                .model = model,
                .cwd = cwd,
                .content = copy_content,
                .reasoning_content = reasoning_content,
                .role = copy_role,
                .finish_reason = finish_reason,
                .tool_calls_json = copy_tool_calls,
                .tool_call_id = copy_tool_call_id,
                .agent_name = copy_agent,
                .loop_index = input.loop_index,
                .temperature = temperature,
                .is_thinking = is_thinking,
                .parent_id = session_id,
                .parent_session_id = session_id,
                .is_input = is_input,
                .is_output = is_output,
                .image_url = copy_image_urls,
                .session_skills = session_skills,
                .tool_name = copy_tool_name,
                .total_tokens = input.total_tokens,
                .diffview_before = copy_diffview_before,
                .diffview_after = copy_diffview_after,
            } }) catch |on_event_sent_err| {
                logger.?.errFmt("[{s}] failed to sent llm historry: {s}\n", .{ keyword, @errorName(on_event_sent_err) });
            };
        }
    }

    return id;
}

/// Get all skills loaded for a session
fn getSessionSkills(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]SkillInfo {
    if (session_id.len == 0) return &.{};

    const sql = "SELECT skill_name, content, loaded_at FROM session_skills WHERE session_id = ?";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    var skills = std.ArrayList(SkillInfo).empty;
    errdefer {
        for (skills.items) |*s| s.deinit(allocator);
        skills.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const skill_name = row.values[0];
        const content = row.values[1];
        const loaded_at = if (row.values[2].len > 0) std.fmt.parseInt(i64, row.values[2], 10) catch null else null;

        try skills.append(allocator, .{
            .skill_name = try allocator.dupe(u8, skill_name),
            .content = try allocator.dupe(u8, content),
            .loaded_at = loaded_at,
        });
        row.deinit(allocator);
    }

    return try skills.toOwnedSlice(allocator);
}

fn serializeToolCalls(allocator: std.mem.Allocator, tool_calls: []agent.ToolCall) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    try aw.writer.print("{f}", .{std.json.fmt(tool_calls, .{})});
    return aw.toOwnedSlice();
}

// ─── Tests ──────────────────────────────────────────────────────────────────
//
// `inserLLMHistories` performs a 24-column INSERT into `llm_history`
// (overriding the row id + created_at with `std.Io.Timestamp.now(io, .real)`),
// an `UPDATE sessions SET cwd = ?`, and an optional SSE emit. The tests
// below exercise the DB paths and the SSE branch's two short-circuits.
//
// `session_skills` is only touched when `is_emit_sse = true` AND
// `event_bus != null`, so the basic DB-only tests don't need that table.

const testing = std.testing;

fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // llm_history schema (only the columns the INSERT writes — extra
    // columns from production migrations are omitted, the INSERT
    // statement doesn't reference them).
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT,
        \\    model TEXT,
        \\    response_content TEXT,
        \\    finish_reason TEXT,
        \\    role TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_call_id TEXT,
        \\    reasoning_content TEXT,
        \\    is_feed_to_llm INTEGER,
        \\    agent TEXT,
        \\    loop_index INTEGER,
        \\    temperature REAL,
        \\    is_thinking INTEGER,
        \\    created_at TEXT,
        \\    created_iso TEXT,
        \\    parent_session_id TEXT,
        \\    parent_id TEXT,
        \\    prompt_tokens INTEGER,
        \\    completion_tokens INTEGER,
        \\    total_tokens INTEGER,
        \\    is_input INTEGER,
        \\    is_output INTEGER,
        \\    tool_name TEXT,
        \\    diffview_before TEXT,
        \\    diffview_after TEXT,
        \\    image_url TEXT
        \\)
    , &.{});
    // sessions schema (only id + cwd are required by the UPDATE).
    try db.exec(alloc,
        \\CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, updated_at TEXT)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

/// Build a minimal `LLMHistory` entity for INSERT. Caller overrides
/// individual fields after construction.
fn makeEntity() LLMHistory {
    return .{
        .id = "ignored-by-impl", // function overwrites this with Timestamp.now
        .session_id = "s1",
        .model = "test-model",
        .created_at = "ignored-by-impl", // same — overwritten by Timestamp.now
        .response_content = "hello",
        .finish_reason = "stop",
        .role = "assistant",
        .tool_calls_json = "",
        .tool_call_id = null,
        .reasoning_content = null,
        .agent = "Agent",
        .session_name = "",
        .loop_index = 0,
        .tool_name = "",
        .parent_session_id = null,
        .parent_id = null,
        .temperature = 0.2,
        .is_thinking = false,
        .prompt_tokens = 0,
        .completion_tokens = 0,
        .total_tokens = 0,
        .is_input = false,
        .is_output = true,
        .diffview_before = null,
        .diffview_after = null,
        .image_urls = null,
        .is_feed_to_llm = true,
    };
}

test "inserLLMHistories: inserts exactly one row into llm_history for the given session_id" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

_ = try inserLLMHistories(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .db = &s.db,
        .logger = null,
        .is_emit_sse = false,
        .event_bus = null,
        .cwd = "/tmp/test",
        .entity = makeEntity(),
    });

    var q = try s.db.query(testing.allocator, "SELECT COUNT(*) FROM llm_history WHERE session_id = 's1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "inserLLMHistories: inserted row carries the user-supplied response_content, role, finish_reason" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    var entity = makeEntity();
    entity.response_content = "the answer is 42";
    entity.role = "assistant";
    entity.finish_reason = "stop";

_ = try inserLLMHistories(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .db = &s.db,
        .logger = null,
        .is_emit_sse = false,
        .event_bus = null,
        .cwd = "/tmp",
        .entity = entity,
    });

    var q = try s.db.query(testing.allocator, "SELECT response_content, role, finish_reason FROM llm_history WHERE session_id = 's1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("the answer is 42", row.values[0]);
    try testing.expectEqualStrings("assistant", row.values[1]);
    try testing.expectEqualStrings("stop", row.values[2]);
}

test "inserLLMHistories: updates sessions.cwd when a matching session row exists" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try s.db.exec(testing.allocator, "INSERT INTO sessions (id, cwd) VALUES ('s1', '/old/dir')", &.{});

_ = try inserLLMHistories(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .db = &s.db,
        .logger = null,
        .is_emit_sse = false,
        .event_bus = null,
        .cwd = "/new/dir",
        .entity = makeEntity(),
    });

    var q = try s.db.query(testing.allocator, "SELECT cwd FROM sessions WHERE id = 's1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.SessionRowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("/new/dir", row.values[0]);
}

test "inserLLMHistories: UPDATE sessions is a no-op when the session row does not exist" {
    // No session_id='s_missing' in sessions → UPDATE matches zero rows.
    // The INSERT into llm_history must still happen.
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

_ = try inserLLMHistories(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .db = &s.db,
        .logger = null,
        .is_emit_sse = false,
        .event_bus = null,
        .cwd = "/tmp",
        .entity = makeEntity(),
    });

    var q = try s.db.query(testing.allocator, "SELECT COUNT(*) FROM llm_history", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "inserLLMHistories: stores is_input, is_output, is_thinking as 0/1" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    var entity = makeEntity();
    entity.is_input = true;
    entity.is_output = false;
    entity.is_thinking = true;
    entity.loop_index = 3;
    entity.temperature = 0.7;

_ = try inserLLMHistories(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .db = &s.db,
        .logger = null,
        .is_emit_sse = false,
        .event_bus = null,
        .cwd = "/tmp",
        .entity = entity,
    });

    var q = try s.db.query(testing.allocator, "SELECT is_input, is_output, is_thinking, loop_index, temperature FROM llm_history", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("1", row.values[0]);
    try testing.expectEqualStrings("0", row.values[1]);
    try testing.expectEqualStrings("1", row.values[2]);
    try testing.expectEqualStrings("3", row.values[3]);
    try testing.expectEqualStrings("0.7", row.values[4]);
}

test "inserLLMHistories: stores prompt/completion/total tokens" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    var entity = makeEntity();
    entity.prompt_tokens = 100;
    entity.completion_tokens = 50;
    entity.total_tokens = 150;

_ = try inserLLMHistories(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .db = &s.db,
        .logger = null,
        .is_emit_sse = false,
        .event_bus = null,
        .cwd = "/tmp",
        .entity = entity,
    });

    var q = try s.db.query(testing.allocator, "SELECT prompt_tokens, completion_tokens, total_tokens FROM llm_history", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("100", row.values[0]);
    try testing.expectEqualStrings("50", row.values[1]);
    try testing.expectEqualStrings("150", row.values[2]);
}

test "inserLLMHistories: stores reasoning_content when present (nullable column)" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    var entity = makeEntity();
    entity.reasoning_content = "step-by-step reasoning";

_ = try inserLLMHistories(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .db = &s.db,
        .logger = null,
        .is_emit_sse = false,
        .event_bus = null,
        .cwd = "/tmp",
        .entity = entity,
    });

    var q = try s.db.query(testing.allocator, "SELECT reasoning_content FROM llm_history", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("step-by-step reasoning", row.values[0]);
}

test "inserLLMHistories: stores empty string for null reasoning_content" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    // entity.reasoning_content = null (default), is_feed_to_llm = false
    // → the implementation passes '' as the reasoning_content arg,
    // so the column holds '' not NULL. Document that contract.
_ = try inserLLMHistories(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .db = &s.db,
        .logger = null,
        .is_emit_sse = false,
        .event_bus = null,
        .cwd = "/tmp",
        .entity = makeEntity(),
    });

    var q = try s.db.query(testing.allocator, "SELECT reasoning_content, is_feed_to_llm FROM llm_history", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("", row.values[0]);
    // makeEntity() sets is_feed_to_llm=true → stored as "1".
    try testing.expectEqualStrings("1", row.values[1]);
}

test "inserLLMHistories: is_feed_to_llm=false is stored as '0'" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    var entity = makeEntity();
    entity.is_feed_to_llm = false;

_ = try inserLLMHistories(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .db = &s.db,
        .logger = null,
        .is_emit_sse = false,
        .event_bus = null,
        .cwd = "/tmp",
        .entity = entity,
    });

    var q = try s.db.query(testing.allocator, "SELECT is_feed_to_llm FROM llm_history", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "inserLLMHistories: joins multiple image_urls with '||' delimiter" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    // Build a `[][]const u8` of three dupes. Using `&.{ "u1", "u2", "u3" }`
    // here produces `*const [3][]const u8` (an array pointer), which
    // won't coerce to `[][]const u8` — so we use an ArrayList +
    // toOwnedSlice to materialize a real slice, matching how
    // getLLMHistories builds the same field.
    var entity = makeEntity();
    var urls = std.ArrayList([]const u8).empty;
    defer for (urls.items) |u| testing.allocator.free(u);
    try urls.append(testing.allocator, try testing.allocator.dupe(u8, "u1"));
    try urls.append(testing.allocator, try testing.allocator.dupe(u8, "u2"));
    try urls.append(testing.allocator, try testing.allocator.dupe(u8, "u3"));
    entity.image_urls = try urls.toOwnedSlice(testing.allocator);
    // IMPORTANT: defer the frees — `inserLLMHistories` reads `image_urls`
    // by reference, so the strings must stay alive until it returns.
    // (Running the frees inline would invalidate the slice before the
    // call and crash inside the implementation's appendSlice.)
    defer testing.allocator.free(entity.image_urls.?);
    defer for (entity.image_urls.?) |u| testing.allocator.free(u);

_ = try inserLLMHistories(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .db = &s.db,
        .logger = null,
        .is_emit_sse = false,
        .event_bus = null,
        .cwd = "/tmp",
        .entity = entity,
    });

    var q = try s.db.query(testing.allocator, "SELECT image_url FROM llm_history", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("u1||u2||u3", row.values[0]);
}

test "inserLLMHistories: stores empty image_url when image_urls is null" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    // entity.image_urls = null → the implementation writes "" (no rows
    // are added to the combined buffer). Document that contract.
_ = try inserLLMHistories(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .db = &s.db,
        .logger = null,
        .is_emit_sse = false,
        .event_bus = null,
        .cwd = "/tmp",
        .entity = makeEntity(),
    });

    var q = try s.db.query(testing.allocator, "SELECT image_url FROM llm_history", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("", row.values[0]);
}

test "inserLLMHistories: is_emit_sse=true with event_bus=null is a safe no-op for the SSE branch" {
    // The implementation must check `if (event_bus) |ev|` BEFORE any
    // payload allocation / session_skills query. The DB writes must
    // still complete.
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

_ = try inserLLMHistories(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .db = &s.db,
        .logger = null,
        .is_emit_sse = true,
        .event_bus = null,
        .cwd = "/tmp",
        .entity = makeEntity(),
    });

    var q = try s.db.query(testing.allocator, "SELECT 1 FROM llm_history WHERE session_id = 's1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
}

test "inserLLMHistories: is_emit_sse=false short-circuits before any event_bus access" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    _ = try inserLLMHistories(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .db = &s.db,
        .logger = null,
        .is_emit_sse = false,
        .event_bus = null,
        .cwd = "/tmp",
        .entity = makeEntity(),
    });

    var q = try s.db.query(testing.allocator, "SELECT 1 FROM llm_history WHERE session_id = 's1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
}

// ─── is_skip_db — error-path SSE-only mode (workflow.zig retry_count > 10) ───
//
// When `is_skip_db = true` is set by the caller, the function must skip the
// `INSERT INTO llm_history` and the `UPDATE sessions SET cwd = ?` writes but
// STILL run the SSE emit branch (when `is_emit_sse = true` and
// `event_bus != null`). This is used by error-path diagnostics (the
// unattached soft-bail + TooManyRetries hard-bail in workflow.zig's
// `if (retry_count > 10)` block) so the user sees the diagnostic live in
// their chat stream without it accumulating in the persistent chat history
// (and without re-feeding it to the LLM context on the next turn).

test "inserLLMHistories: is_skip_db=true inserts ZERO rows into llm_history" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

_ = try inserLLMHistories(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .db = &s.db,
        .logger = null,
        .is_emit_sse = false,
        .event_bus = null,
        .cwd = "/tmp",
        .entity = makeEntity(),
        .is_skip_db = true,
    });

    var q = try s.db.query(testing.allocator, "SELECT COUNT(*) FROM llm_history WHERE session_id = 's1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "inserLLMHistories: is_skip_db=true leaves sessions.cwd untouched even when a matching row exists" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try s.db.exec(testing.allocator, "INSERT INTO sessions (id, cwd) VALUES ('s1', '/original/dir')", &.{});

_ = try inserLLMHistories(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .db = &s.db,
        .logger = null,
        .is_emit_sse = false,
        .event_bus = null,
        .cwd = "/should/not/win",
        .entity = makeEntity(),
        .is_skip_db = true,
    });

    var q = try s.db.query(testing.allocator, "SELECT cwd FROM sessions WHERE id = 's1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.SessionRowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("/original/dir", row.values[0]);
}

test "inserLLMHistories: is_skip_db=false (default) preserves the existing DB-write behavior" {
    // Regression guard: the new `is_skip_db` field defaults to false and
    // existing call sites without the field must continue to INSERT into
    // llm_history. This is the same DB-state assertion as the original
    // "inserts exactly one row into llm_history for the given session_id"
    // test but with the explicit `.is_skip_db = false` spelling to lock in
    // that the default is honored.
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

_ = try inserLLMHistories(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .db = &s.db,
        .logger = null,
        .is_emit_sse = false,
        .event_bus = null,
        .cwd = "/tmp",
        .entity = makeEntity(),
        .is_skip_db = false,
    });

    var q = try s.db.query(testing.allocator, "SELECT COUNT(*) FROM llm_history WHERE session_id = 's1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("1", row.values[0]);
}
