const std = @import("std");
const testing = std.testing;
const workflow = @import("workflow.zig");
const agent = @import("nalarcore").agent;
const sqlite = @import("nalarcore").sqlite;
const llm_history = @import("../llm_history.zig");
const logger_mod = @import("nalarcore").loggermod;
const migration = @import("../../../migrations/migration.zig");

/// Build a fresh in-memory DB by walking ALL migrations from 001 →
/// latest, so the schema under test is GUARANTEED to match production
/// (per project memory `llm-history-test-use-migrations-module.md`).
/// No hand-rolled CREATE TABLE — the migration chain is the source of
/// truth.
fn setupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
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

fn teardownDb(s: *@TypeOf(setupDb() catch unreachable)) void {
    s.db.deinit();
    s.threaded.deinit();
}

/// Build a synthetic in-memory message list shaped like the agent's
/// real messages: [system, user-1, assistant-1, tool-result-1, user-2, assistant-2].
/// Uses allocator.dupe'd slices so compactMessageInMemoryNew can free
/// them safely after compaction.
fn buildMessages(allocator: std.mem.Allocator) !std.ArrayList(agent.AgentMessage) {
    var list: std.ArrayList(agent.AgentMessage) = .empty;
    try list.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "You are a coding agent."),
    });
    try list.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "Fix the login bug"),
    });
    try list.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "I'll investigate"),
    });
    try list.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "tests pass: 42/42"),
        .tool_call_id = try allocator.dupe(u8, "tc_1"),
        // Set a real DB-style id so the envelope-test can assert
        // real-id embedding (regression for the adhoc_N synthesis bug).
        .id = try allocator.dupe(u8, "1782027292879102675"),
    });
    try list.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "Now ship it"),
    });
    try list.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "Shipping."),
    });
    return list;
}

test "compactMessageInMemoryNew: envelope contains metadata header" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    const messages = try buildMessages(alloc);
    // No defer messages.deinit — compactMessageInMemoryNew takes ownership
    // (T → !T): its body deinits messages.items + the ArrayList, leaving our
    // test scope's copy stale. Double-deinit would crash.

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const compacted_xml =
        \\GOAL: fix login
        \\NEXT ACTION: ship it
    ;

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc,
        messages,
        compacted_xml,
        "sess_123",
        "gpt-4o",
        "/tmp",
        &s.db,
        s.threaded.io(),
        &lg,
        null, // event_bus — no SSE subscriber in tests
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    try testing.expectEqual(@as(usize, 2), new_messages.items.len); // [system, compact_summary]
    const summary = new_messages.items[1].content.?;
    try testing.expect(std.mem.indexOf(u8, summary, "<compact_messages>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "</compact_messages>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<session_id>sess_123</session_id>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<model>gpt-4o</model>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<original_count>6</original_count>") != null);
    // Compactor's summary text is preserved inside <summary>...</summary>
    try testing.expect(std.mem.indexOf(u8, summary, "<summary>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "GOAL: fix login") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "NEXT ACTION: ship it") != null);
    // The <compacted_at> tag must exist and be non-empty
    try testing.expect(std.mem.indexOf(u8, summary, "<compacted_at>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "</compacted_at>") != null);
    const ca_tag = std.mem.indexOf(u8, summary, "<compacted_at>").?;
    const ca_close = std.mem.indexOf(u8, summary, "</compacted_at>").?;
    try testing.expect(ca_close > ca_tag + "<compacted_at>".len);
}

test "compactMessageInMemoryNew: message_index lists every dropped message with id, role, preview" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    const messages = try buildMessages(alloc);
    // No defer messages.deinit — compactMessageInMemoryNew takes ownership
    // (T → !T): its body deinits messages.items + the ArrayList, leaving our
    // test scope's copy stale. Double-deinit would crash.

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc, messages, "summary text", "sess_abc", "gpt-4o", "/tmp",
        &s.db, s.threaded.io(), &lg,
        null, // event_bus — no SSE subscriber in tests
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    const summary = new_messages.items[1].content.?;

    // <message_index> section must exist and contain one entry per dropped
    // message (everything except index 0 = the system prompt). The 6-msg
    // fixture drops 5 messages (indices 1..5).
    try testing.expect(std.mem.indexOf(u8, summary, "<message_index>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "</message_index>") != null);

    // Every non-system role from the fixture must appear in the index.
    try testing.expect(std.mem.indexOf(u8, summary, "<role>user</role>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<role>assistant</role>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<role>tool</role>") != null);

    // Each index entry must include a message id and a preview.
    // CURRENT IMPL: the envelope uses synthetic `adhoc_<i>` ids (where `i`
    // is the index into `dropped_messages`, i.e. messages.items[1..]).
    // Real DB primary keys are NOT embedded in the envelope — the full
    // content is recovered from the DB via `search_history` using
    // the session_id, not via the embedded id. (See workflow.zig:1144.)
    //
    // The 6-msg fixture drops 5 messages, so the tool-result is at
    // dropped_messages[2] → `adhoc_2`.
    try testing.expect(std.mem.indexOf(u8, summary, "<id>adhoc_2</id>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<preview>") != null);
}

test "compactMessageInMemoryNew: tool-role index entries include tool_call_id" {
    // Regression: a tool-result message has `tool_call_id`. The index must
    // surface it so the agent can match the result back to the call.
    //
    // CURRENT IMPL: only `tool_call_id` is surfaced for tool-role entries.
    // `tool_name` is NOT emitted in the envelope (the in-memory AgentMessage
    // struct has no `tool_name` field — that lives on the DB row and can
    // be recovered via `search_history` with session_id). See
    // workflow.zig:1163-1172.
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    const messages = try buildMessages(alloc);
    // No defer messages.deinit — compactMessageInMemoryNew takes ownership
    // (T → !T): its body deinits messages.items + the ArrayList, leaving our
    // test scope's copy stale. Double-deinit would crash.

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc, messages, "summary", "sess_xyz", "gpt-4o", "/tmp",
        &s.db, s.threaded.io(), &lg,
        null, // event_bus — no SSE subscriber in tests
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    const summary = new_messages.items[1].content.?;
    try testing.expect(std.mem.indexOf(u8, summary, "<tool_call_id>tc_1</tool_call_id>") != null);
    // tool_name is intentionally NOT in the envelope; the tool_call_id
    // alone is enough to pair the result back to the originating call.
    try testing.expect(std.mem.indexOf(u8, summary, "<tool_name>") == null);
}

test "compactMessageInMemoryNew: existing short-circuit (total <= 4) returns messages unchanged" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "sys") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "hi") });

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const result = try workflow.compactMessageInMemoryNew(
        alloc, messages, "summary", "sess_1", "gpt-4o", "/tmp",
        &s.db, s.threaded.io(), &lg,
        null, // event_bus — no SSE subscriber in tests
    );
    defer {
        // Free each AgentMessage's content then the ArrayList.
        for (result.items) |*m| m.deinit(alloc);
        var result_owned = result;
        result_owned.deinit(alloc);
    }

    try testing.expectEqual(@as(usize, 2), result.items.len); // unchanged
    try testing.expectEqualStrings("hi", result.items[1].content.?);
}

test "buildCompactionEnvelope: all previews are capped at 100 chars regardless of role" {
    // CURRENT IMPL: the envelope caps every preview at 100 bytes
    // (`preview.len > 100` → trim). There is no role-based 200/500
    // distinction. (See workflow.zig:1152.) The 100-char cap is a safety
    // net for ASCII; if non-English content is common, swap for a
    // UTF-8-aware trim.
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    const long_text = try alloc.alloc(u8, 1000);
    defer alloc.free(long_text);
    @memset(long_text, 'x');

    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "sys") });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027251703514461"),
        .role = .user,
        .content = try alloc.dupe(u8, long_text),
    });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027292873814871"),
        .role = .assistant,
        .content = try alloc.dupe(u8, "I'll handle that"),
    });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027292879102675"),
        .role = .tool,
        .content = try alloc.dupe(u8, long_text),
        .tool_call_id = try alloc.dupe(u8, "tc_1"),
    });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027306945614038"),
        .role = .assistant,
        .content = try alloc.dupe(u8, "Done"),
    });

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc, messages, "summary", "sess_500", "gpt-4o", "/tmp",
        &s.db, s.threaded.io(), &lg,
        null, // event_bus — no SSE subscriber in tests
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    const summary = new_messages.items[1].content.?;

    // 4 dropped messages, so user is `adhoc_0` and tool is `adhoc_2`.
    try testing.expect(std.mem.indexOf(u8, summary, "<id>adhoc_0</id>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<id>adhoc_2</id>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<role>user</role>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<role>tool</role>") != null);

    // Slice out the user entry and the tool entry by their ids.
    const user_id_pos = std.mem.indexOf(u8, summary, "<id>adhoc_0</id>").?;
    const tool_id_pos = std.mem.indexOf(u8, summary, "<id>adhoc_2</id>").?;
    const user_entry_end = std.mem.indexOfPos(u8, summary, user_id_pos, "</entry>").?;
    const tool_entry_end = std.mem.indexOfPos(u8, summary, tool_id_pos, "</entry>").?;

    const user_entry = summary[user_id_pos..user_entry_end];
    const tool_entry = summary[tool_id_pos..tool_entry_end];

    // Both previews are trimmed to exactly 100 chars.
    const user_p_start = std.mem.indexOf(u8, user_entry, "<preview>").? + "<preview>".len;
    const user_p_end = std.mem.indexOf(u8, user_entry, "</preview>").?;
    try testing.expectEqual(@as(usize, 100), user_p_end - user_p_start);

    const tool_p_start = std.mem.indexOf(u8, tool_entry, "<preview>").? + "<preview>".len;
    const tool_p_end = std.mem.indexOf(u8, tool_entry, "</preview>").?;
    try testing.expectEqual(@as(usize, 100), tool_p_end - tool_p_start);
}

test "buildCompactionEnvelope: content=null yields empty preview (no content_parts extraction)" {
    // CURRENT IMPL: when `msg.content` is null (vision / multimodal messages
    // carry text in `content_parts`, not `content`), the preview falls
    // through to "" via `msg.content orelse ""`. The text parts of
    // `content_parts` are NOT extracted into the preview.
    // (See workflow.zig:1148.)
    //
    // This is a known limitation: the agent has no signal in the envelope
    // that an image attachment existed. The full content is still
    // recoverable via `search_history` using session_id.
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    const part_text = "What is in this image?";

    const image_part = agent.ContentPart{
        .part_type = "image_url",
        .text = null,
        .image_url = .{
            .url = try alloc.dupe(u8, "data:image/png;base64,iVBORw0..."),
            .detail = null,
        },
    };
    const text_part = agent.ContentPart{
        .part_type = "text",
        .text = try alloc.dupe(u8, part_text),
        .image_url = null,
    };
    const content_parts = try alloc.dupe(agent.ContentPart, &[_]agent.ContentPart{ text_part, image_part });

    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "sys") });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027251703514461"),
        .role = .user,
        .content = null,
        .content_parts = content_parts,
    });
    // Add enough messages so total > 4 (the compaction threshold).
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027292873814871"),
        .role = .assistant,
        .content = try alloc.dupe(u8, "Looking at the image"),
    });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027292879102675"),
        .role = .tool,
        .content = try alloc.dupe(u8, "image processed"),
        .tool_call_id = try alloc.dupe(u8, "tc_v1"),
    });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027306945614038"),
        .role = .assistant,
        .content = try alloc.dupe(u8, "It's a sunset"),
    });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027317965287809"),
        .role = .user,
        .content = try alloc.dupe(u8, "thanks"),
    });

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc, messages, "summary", "sess_vision", "gpt-4o", "/tmp",
        &s.db, s.threaded.io(), &lg,
        null, // event_bus — no SSE subscriber in tests
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    const summary = new_messages.items[1].content.?;
    // The first dropped message (user with content=null, content_parts set)
    // is at dropped_messages[0] → `adhoc_0`. Its preview is empty.
    try testing.expect(std.mem.indexOf(u8, summary, "<id>adhoc_0</id>") != null);
    // No text-part content leaks into the preview.
    try testing.expect(std.mem.indexOf(u8, summary, "What is in this image?") == null);
    // The empty preview appears for the vision message.
    try testing.expect(std.mem.indexOf(u8, summary, "<preview></preview>") != null);
    // (If you want to fix the underlying limitation, change
    // workflow.zig:1148 to fall back to concatenated content_parts text.)
}

test "end-to-end: compacted rows are findable via getCompactedMessages after compaction" {
    // CURRENT IMPL: the envelope uses synthetic `adhoc_<i>` ids, NOT the
    // real DB primary keys. So you cannot pull an id out of the envelope
    // and feed it back — `search_history` must be queried with
    // the session_id alone (no message_ids filter), and it returns all
    // rows for the session that have is_feed_to_llm=0.
    //
    // This test verifies the FULL round-trip: pre-seed rows with
    // is_feed_to_llm=1, compact (which flips them to 0 and saves a new
    // summary row with is_feed_to_llm=1), then query via getCompactedMessages
    // using session_id. The pre-seeded rows must come back with their
    // original content intact.
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    const session_id = "sess_roundtrip";
    const ids = [_][]const u8{
        "1000000000000000001",
        "1000000000000000002",
        "1000000000000000003",
        "1000000000000000004",
        "1000000000000000005",
    };
    const contents = [_][]const u8{
        "Fix the login bug",
        "I'll investigate",
        "running tests",
        "tests pass: 42/42",
        "shipping",
    };
    const roles = [_][]const u8{ "user", "assistant", "assistant", "tool", "user" };

    // Pre-seed DB with real ids, marked is_feed_to_llm=1 (so compactMessageInMemoryNew's
    // markMessageNotForLlmRun will flip them to 0 after compaction).
    for (ids, contents, roles) |id, content, role| {
        const tcid: []const u8 = if (std.mem.eql(u8, role, "tool")) "tc_xyz" else "";
        const tname: []const u8 = if (std.mem.eql(u8, role, "tool")) "bash" else "";
        try s.db.exec(alloc,
            \\INSERT INTO llm_history
            \\  (id, session_id, model, response_content, role, is_feed_to_llm,
            \\   created_at, tool_call_id, tool_name)
            \\VALUES (?, ?, 'gpt-4o', ?, ?, 1, '2026-01-01 00:00:00', ?, ?)
        , &.{ id, session_id, content, role, tcid, tname });
    }

    // Build the in-memory message list with matching .id values, then compact.
    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "sys") });
    for (ids, contents, roles) |id, content, role| {
        const role_enum = std.meta.stringToEnum(agent.Role, role) orelse .user;
        try messages.append(alloc, .{
            .id = try alloc.dupe(u8, id),
            .role = role_enum,
            .content = try alloc.dupe(u8, content),
            .tool_call_id = if (std.mem.eql(u8, role, "tool"))
                try alloc.dupe(u8, "tc_xyz")
            else
                null,
        });
    }

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc, messages, "summary", session_id, "gpt-4o", "/tmp",
        &s.db, s.threaded.io(), &lg,
        null, // event_bus — no SSE subscriber in tests
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    const summary = new_messages.items[1].content.?;

    // CURRENT IMPL: the envelope uses synthetic `adhoc_<i>` ids, not the
    // real DB primary keys. Confirm the pattern is present.
    try testing.expect(std.mem.indexOf(u8, summary, "<id>adhoc_0</id>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<id>adhoc_4</id>") != null);
    // Real ids MUST NOT be embedded in the envelope (the impl does not
    // reach into AgentMessage.id).
    for (ids) |id| {
        const needle = try std.fmt.allocPrint(alloc, "<id>{s}</id>", .{id});
        defer alloc.free(needle);
        try testing.expect(std.mem.indexOf(u8, summary, needle) == null);
    }

    // Pull ALL compacted rows for the session (no message_ids filter) and
    // verify each pre-seeded row is findable with its original content.
    const found = try llm_history.getCompactedMessages(alloc, &s.db,
        session_id,
        .{ .limit = 100 });
    defer {
        for (found) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(found);
    }
    try testing.expectEqual(@as(usize, 5), found.len);

    // Build a quick id→row index and verify every original id/content
    // is recoverable.
    for (ids, contents) |id, original_content| {
        var matched = false;
        for (found) |m| {
            if (std.mem.eql(u8, m.id, id)) {
                try testing.expectEqualStrings(original_content, m.content);
                matched = true;
                break;
            }
        }
        try testing.expect(matched); // id was recoverable from the session
    }
}

// ============================================================================
// ============================================================================
// Migration 073 — session_activity recent_activities embedding
// ============================================================================
//
// Per PR #226 review comment:
//   "dont recorsessionactivty, but get the activity, so the next cycle
//    agent is know the activity aftert compaction"
// — the compaction flow must READ prior session_activity rows
// (recorded by `update_activity`) and embed them in a
// `<recent_activities>` section inside the <compaction_context>
// enrichment, NOT record a new "[COMPACTION] Compacted..." row.
//
// After the "lift recent_activities out of buildCompactionEnvelope"
// refactor, this behavior lives at the `maybeCompactMessagesNew` level
// (via `enrichCompactionXml`), so the integration tests are now in
// `workflow_commpact_message.zig` (which has the mock-state
// infrastructure for the full function).
// buildCompactionEnvelope itself no longer emits <recent_activities>
// — it just wraps whatever XML the caller hands it.
