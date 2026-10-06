const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const session_llm_config = @import("../agentic_loop/session_llm_config.zig");
const gserverz = pabrikcore.gserverz;
const helpers = @import("helpers");
const ai_mod = pabrikcore.ai_mod;
const config = pabrikcore.config;
const llm_history = ai_mod.llm_history;
const chat_parsing = @import("../agentic_loop/parsing.zig");

/// Get messages for a session
pub fn sessionMessagesHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };

    const limit_str = req.query.get("limit") orelse "100";
    const cursor = req.query.get("cursor");
    const sort_by_str = req.query.get("sort_by") orelse "created_at";
    const direction_str = req.query.get("direction") orelse "asc";
    const limit_val = std.fmt.parseInt(u32, limit_str, 10) catch 100;

    // Determine sort direction (default: asc)
    const is_desc = std.mem.eql(u8, direction_str, "desc");

    // Parse sort_by parameter and combine with direction
    const sort_spec: llm_history.SortSpec = blk: {
        if (std.mem.eql(u8, sort_by_str, "id")) {
            break :blk if (is_desc)
                llm_history.SortSpec{ .id_desc = {} }
            else
                llm_history.SortSpec{ .id_asc = {} };
        } else if (std.mem.eql(u8, sort_by_str, "role")) {
            break :blk if (is_desc)
                llm_history.SortSpec{ .role_desc = {} }
            else
                llm_history.SortSpec{ .role_asc = {} };
        } else {
            // Default to created_at
            break :blk if (is_desc)
                llm_history.SortSpec{ .created_at_desc = {} }
            else
                llm_history.SortSpec{ .created_at_asc = {} };
        }
    };

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // 2026-08-21-fix-ui-context-window — resolve the session's selected
    // profile so the response's `max_capacity_total_tokens` honors the
    // profile's `max_capacity_tokens` override (cascade step 2 in
    // `maxCapacityForModel`). Previously this handler passed no profile,
    // so the chat footer always showed the built-in per-model default
    // (e.g. 500,000) even when the selected profile overrode the window
    // (e.g. 950,000). Graceful degradation: empty name / unknown profile
    // → null → Defaults-tab → built-in default (old behavior).
    //
    // `LlmProfile` is nested inside `LlmConfig` — refer to it as
    // `config.LlmConfig.LlmProfile`. The bare `pabrikcore.config.LlmProfile`
    // path compiles in `zig build test` (lib module lookup) but Zig 0.16's
    // `zig build-exe` (exe module lookup) rejects it because the parent
    // struct in the root module is `modules.config.Config` and has no
    // top-level `LlmProfile` member. CI fix 2026-08-21.
    //
    // `resolveSessionProfile` walks session selection → active_profile →
    // null, matching the workflow loop — so a Default chat with
    // active_profile=alpha shows alpha's 950k window, not 500k.
    // Session-scoped config: the session OWNER's stored config under
    // `--auth`, the process-global one otherwise — one resolution module
    // (`session_llm_config.zig`), never a hand-rolled singleton read.
    const cfg = session_llm_config.forSession(allocator, di.db, session_id) orelse
        pabrikcore.getLlmConfig(di);
    const profile_name = llm_history.getSessionProfileName(allocator, sqlite_db, session_id) catch "";
    const profile: ?config.LlmConfig.LlmProfile =
        llm_history.resolveSessionProfile(cfg, profile_name);

    const msg_response = llm_history.getSessionMessagesSorted(allocator, sqlite_db, session_id, limit_val, cursor, sort_spec, if (profile) |*p| p else null) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Database query failed" }) });
    };

    // 2026-08-24-fix-flaky-create-and-run-profile-test — when the
    // session has ZERO llm_history rows (fresh create_and_run session:
    // the worker drains the queued user message asynchronously), the
    // LEFT JOIN in getSessionMessagesSorted yields no rows and
    // msg_response.selected_profile_model stays null even though the
    // sessions row already carries the profile. Fall back to the
    // direct sessions-table read (already fetched above for the
    // capacity cascade) so the chatview's profile chip is correct from
    // the very first GET — no race with the worker.
    const selected_profile_model_final: ?[]const u8 = blk: {
        if (msg_response.selected_profile_model) |spm| break :blk spm;
        if (profile_name.len > 0) break :blk profile_name;
        break :blk null;
    };

    // Zero-message fallback for the attached-PR binding (same race as
    // the profile chip above): the JOIN yields no rows before the
    // first message, so read the sessions row directly. Non-empty
    // direct values win; otherwise null (unset).
    const pr_fields: llm_history.SessionPrFields = llm_history.getSessionPrFields(allocator, sqlite_db, session_id) catch .{ .pr_url = "", .pr_provider = "" };
    const pr_url_final: ?[]const u8 = msg_response.pr_url orelse (if (pr_fields.pr_url.len > 0) pr_fields.pr_url else null);
    const pr_provider_final: ?[]const u8 = msg_response.pr_provider orelse (if (pr_fields.pr_provider.len > 0) pr_fields.pr_provider else null);

    // Convert llm_history.SessionMessageResponse to http_response.SessionMessagesResponse
    var messages: []http_response.SessionMessage = try allocator.alloc(http_response.SessionMessage, msg_response.messages.len);
    for (msg_response.messages, 0..) |msg, idx| {
        // Join multiple image URLs into a pipe-separated string
        var image_url_str: []u8 = &[_]u8{};
        if (msg.image_urls) |urls| {
            var combined = std.ArrayList(u8).empty;
            errdefer combined.deinit(allocator);
            for (urls, 0..) |url, i| {
                if (i > 0) try combined.append(allocator, '|');
                try combined.appendSlice(allocator, url);
            }
            image_url_str = try combined.toOwnedSlice(allocator);
        }
        // Join multiple video URLs into a pipe-separated string
        var video_url_str: []u8 = &[_]u8{};
        if (msg.video_urls) |urls| {
            var combined = std.ArrayList(u8).empty;
            errdefer combined.deinit(allocator);
            for (urls, 0..) |url, i| {
                if (i > 0) try combined.append(allocator, '|');
                try combined.appendSlice(allocator, url);
            }
            video_url_str = try combined.toOwnedSlice(allocator);
        }

        messages[idx] = http_response.SessionMessage{
            .id = msg.id,
            .session_id = msg.session_id,
            .role = msg.role,
            // DB may hold Option A envelopes; wire stays plain `.msg` for
            // current frontend bubbles. Unwrap with legacy fallback.
            .content = blk: {
                const unwrapped = chat_parsing.unwrapChatContent(allocator, msg.content) catch break :blk try helpers.sanitize.sanitizeUtf8(allocator, msg.content);
                defer allocator.free(unwrapped);
                break :blk try helpers.sanitize.sanitizeUtf8(allocator, unwrapped);
            },
            .created_at = msg.timestamp,
            .is_input = msg.is_input,
            .is_output = msg.is_output,
            .tool_name = msg.tool_name,
            .finish_reason = msg.finish_reason,
            .reasoning_content = msg.reasoning_content,
            .diffview_before = msg.diffview_before orelse "",
            .diffview_after = msg.diffview_after orelse "",
            .image_url = image_url_str,
            .video_url = video_url_str,
            .tool_call_id = msg.tool_call_id orelse "",
            .tool_calls_json = msg.tool_calls_json orelse "",
        };
    }

    const http_resp = http_response.SessionMessagesResponse{
        .messages = messages,
        .has_more = msg_response.has_more,
        .next_cursor = msg_response.next_cursor,
        .cwd = msg_response.cwd,
        .git_worktree_cwd = msg_response.git_worktree_cwd,
        .pr_url = pr_url_final,
        .pr_provider = pr_provider_final,
        // 2026-08-07-profile-persist-read — pass the per-session
        // selected profile name through so the frontend's profile chip
        // survives a page refresh. Without this the chip resets to
        // "Default" because the read endpoint never returned the field
        // that PUT /api/llm/session/:id persists.
        .selected_profile_model = selected_profile_model_final,
        // Migration 091 — sub-agent identity passthrough.
        .sub_agent_name = msg_response.sub_agent_name,
        .parent_session_id = msg_response.parent_session_id,
        .skills = msg_response.skills,
        .max_total_tokens = msg_response.max_total_tokens,
        .max_capacity_total_tokens = msg_response.max_capacity_total_tokens,
        .total = msg_response.total_count,
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeSessionMessagesResponse(allocator, http_resp) });
}

// ===== Tests merged from session_messages_get_test.zig (2026-09-11 flatten) =====
// Behavioural tests for `getSessionMessagesSorted` carrying
// `selected_profile_model` through to its response.
// 
// Why this file exists
// ─────────────────────
// Bug "profiles in chatview not persistent" (2026-08-07): the user
// picks a profile ("900ribu") in the chatview dropdown → chip shows
// the selection → user refreshes the page → chip reverts to "Default".
// 
// Root cause: `sessions.selected_profile_model` IS persisted by
// `session_update.zig`'s PUT handler, but the read-side
// `getSessionMessagesSorted` (called by `GET /api/llm/session/:id/messages`)
// never selects the column from the joined `sessions` row, so the
// frontend's `getChatHistory()` / `getSession()` calls both return
// nothing for `selected_profile_model`. The chip resets because the
// frontend defaults to `null` when the field is missing.
// 
// These tests pin down the fix end-to-end:
//   1. The SQL actually selects `s.selected_profile_model` from the
//      joined `sessions` row.
//   2. The `SessionMessageResponse` struct carries the value.
//   3. The HTTP `SessionMessagesResponse` JSON builder (the wire
//      shape the frontend reads) emits the field.
// 
// Why we test against `getSessionMessagesSorted` + a manual JSON
// builder (not the full HTTP handler)
// ─────────────────────────────────────
// `sessionMessagesHandler` calls `pabrikcore.getSingleton()` to grab
// the live DB handle, which is global process state and out of scope
// for a unit test. The data layer (`getSessionMessagesSorted`) is
// the only place where the field can be loaded — everything else is
// pass-through. If the data layer returns the right value, the HTTP
// handler is one struct field away from emitting it.

const testing = std.testing;
const sqlite = pabrikcore.sqlite;
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
        \\    created_at_nano DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    is_input INTEGER DEFAULT 0,
        \\    is_output INTEGER DEFAULT 0,
        \\    tool_name TEXT,
        \\    finish_reason TEXT,
        \\    reasoning_content TEXT,
        \\    reasoning_id TEXT,
        \\    reasoning_encrypted_content TEXT,
        \\    diffview_before TEXT,
        \\    diffview_after TEXT,
        \\    image_url TEXT,
        \\    video_url TEXT,
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
        \\    last_finish_reason TEXT,
        \\    pr_url TEXT,
        \\    pr_provider TEXT
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
        null,
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
        null,
    );

    // COALESCE-on-NULL → empty string → frontend coerces to null.
    if (resp.selected_profile_model) |p| {
        try testing.expectEqualStrings("", p);
    }
}

test "getSessionMessagesSorted: profile override flows into max_capacity_total_tokens" {
    // 2026-08-21-fix-ui-context-window — the chat footer's context
    // window readout must honor the session's selected profile's
    // `max_capacity_tokens` override. Previously the capacity blk in
    // `getSessionMessagesSorted` hardcoded a null profile, so a profile
    // with an explicit override (e.g. 950,000) was ignored and the UI
    // showed the built-in per-model default (e.g. 500,000).
    //
    // The profile is passed in directly (dependency injection) so this
    // test doesn't need the process-global singleton.
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedSession(&ctx, arena_alloc, "s_cap", "900ribu");
    try seedMessage(&ctx, arena_alloc, "m1", "s_cap", "x");

    // Build a minimal LlmConfig via the same JSON round-trip the
    // config tests use, with one profile carrying an explicit
    // max_capacity_tokens override.
    const config_json =
        \\{ "api_key": "k", "model": "MiniMax-M3", "base_url": "b",
        \\  "profiles_models": { "900ribu": { "model": "m", "max_capacity_tokens": 950000 } } }
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config.json",
        .data = config_json,
        .flags = .{ .truncate = true },
    });
    const config_path = try tmp.dir.realPathFileAlloc(testing.io, "config.json", arena_alloc);
    var env_map = std.process.Environ.Map.init(arena_alloc);
    try env_map.put("HOME", "/tmp");
    try env_map.put("XDG_CONFIG_HOME", "/tmp");
    var cfg = try pabrikcore.config.LlmConfig.init(arena_alloc, testing.io, config_path, &env_map);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("900ribu") orelse unreachable;

    const resp = try llm_history.getSessionMessagesSorted(
        arena_alloc,
        &ctx.db,
        "s_cap",
        50,
        null,
        .{ .created_at_asc = {} },
        &profile,
    );

    // The whole point: the override wins over the built-in default.
    try testing.expectEqual(@as(u32, 950000), resp.max_capacity_total_tokens);
}

test "getSessionProfileName: returns selected_profile_model for a session" {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedSession(&ctx, arena_alloc, "s_name", "alpha model");

    const name = try llm_history.getSessionProfileName(arena_alloc, &ctx.db, "s_name");
    try testing.expectEqualStrings("alpha model", name);

    // Missing session row → "" (graceful degrade, no error).
    const missing = try llm_history.getSessionProfileName(arena_alloc, &ctx.db, "nope");
    try testing.expectEqualStrings("", missing);
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
        null,
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
            .video_url = "",
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

// ─── 2026-08-24-fix-flaky-create-and-run-profile-test ──────────────────────
//
// A fresh create_and_run session has ZERO llm_history rows until the
// worker drains the queued user message (asynchronous). The LEFT JOIN
// in getSessionMessagesSorted yields no rows → selected_profile_model
// stays null even though the sessions row already carries the profile.
// The handler now falls back to the direct sessions-table read
// (getSessionProfileName, already fetched for the capacity cascade).
// These tests pin the data-layer contract that makes the fallback
// correct: null ⇔ zero messages, and getSessionProfileName still sees
// the profile on a message-less session.

test "getSessionMessagesSorted: selected_profile_model is NULL when session has zero messages (fallback precondition)" {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Session row WITH a profile but NO messages — the exact state a
    // fresh create_and_run session is in before the worker drains.
    try seedSession(&ctx, arena_alloc, "s_fresh", "stub");

    const resp = try llm_history.getSessionMessagesSorted(
        arena_alloc,
        &ctx.db,
        "s_fresh",
        50,
        null,
        .{ .created_at_asc = {} },
        null,
    );

    // Data-layer contract: no JOINed rows → null. This is WHY the
    // handler needs the sessions-table fallback — assert it so a
    // future change to the JOIN semantics fails loudly here first.
    try testing.expectEqual(@as(usize, 0), resp.messages.len);
    try testing.expect(resp.selected_profile_model == null);

    // And the fallback source still sees the profile directly.
    const name = try llm_history.getSessionProfileName(arena_alloc, &ctx.db, "s_fresh");
    try testing.expectEqualStrings("stub", name);
}

test "getSessionPrFields reads pr_url + pr_provider straight from sessions row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name, status, pr_url, pr_provider) VALUES ('s_pr', 'PR', 'active', 'https://github.com/o/r/pull/7', 'github')", &.{});

    const fields = try llm_history.getSessionPrFields(alloc, &ctx.db, "s_pr");
    defer alloc.free(fields.pr_url);
    defer alloc.free(fields.pr_provider);
    try testing.expectEqualStrings("https://github.com/o/r/pull/7", fields.pr_url);
    try testing.expectEqualStrings("github", fields.pr_provider);

    // Missing row degrades to empty (unset), never an error.
    const missing = try llm_history.getSessionPrFields(alloc, &ctx.db, "s_nope");
    try testing.expectEqualStrings("", missing.pr_url);
    try testing.expectEqualStrings("", missing.pr_provider);
}
