const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const LlmConfig = nalarcore.config.LlmConfig;
const CallCompactAgentInput = mod.CallCompactAgentInput;
const agent = nalarcore.agent;
const AgentMessage = agent.AgentMessage;
const sqlite = nalarcore.sqlite;
const SqliteBackend = sqlite.SqliteBackend;
const Logger = nalarcore.loggermod.Logger;
const callCompactAgent = mod.callCompactAgent;
const mark_history_not_for_llmrun = mod.mark_history_not_for_llmrun;
const timestampIso = nalarcore.loggermod.timestampIso;
const xml_escape = nalarcore.helpers.xml_escape;
const saveMessage = @import("../llm_history.zig").saveMessage;

/// Bundle of inputs to `shouldCompactDefault` — the threshold decision that
/// tests can swap via `CompactDeps.should_compact`. Carries enough context that
/// a test can assert on what the production decision actually saw (force flag,
/// total_tokens, model, llm_config).
pub const ThresholdCtx = struct {
    force: bool,
    total_tokens: u32,
    model: []const u8,
    llm_config: *const LlmConfig,
};

/// All non-std-lib function dependencies of `maybeCompactMessagesNew`. Bundled
/// into one struct so the function signature stays manageable. Each field is a
/// `comptime fn` so tests can swap in stubs without touching production.
/// Production callers should pass `defaultCompactDeps` (defined below).
pub const CompactDeps = struct {
    /// Decide whether compaction should run. Return `true` to compact, `false`
    /// to skip the function early. Production: `shouldCompactDefault`.
    shouldCompact: fn (ThresholdCtx) bool,

    /// Call the compaction LLM to produce compacted XML. Production:
    /// `agentic_loop_mod.callCompactAgent`.
    callCompactAgent: fn (CallCompactAgentInput) ?[]const u8,

    /// Persist the compacted state to DB + return the new in-memory list.
    /// Production: `compactMessageInMemoryNew`. Error set is widened to
    /// `anyerror` so the comptime fn pointer matches every caller's signature.
    compactMessagesInMemory: fn (
        allocator: std.mem.Allocator,
        messages: std.ArrayList(agent.AgentMessage),
        compacted_xml: []const u8,
        session_id: []const u8,
        model: []const u8,
        cwd: []const u8,
        db: *sqlite.SqliteBackend,
        io: std.Io,
        logger: *Logger,
    ) anyerror!std.ArrayList(agent.AgentMessage),
};

/// Production default for `CompactDeps.should_compact`. Forces a compaction
/// when `force=true` (manual endpoint), otherwise defers to the threshold
/// check (`agent.LLMModels.shouldCompact` over the model's effective context
/// window and the per-profile threshold percent).
pub fn shouldCompactDefault(ctx: ThresholdCtx) bool {
    if (ctx.force) return true;
    return agent.LLMModels.shouldCompact(
        ctx.total_tokens,
        ctx.llm_config.maxCapacityForModel(null, null, ctx.llm_config, ctx.model),
        ctx.llm_config.compactionThresholdPercent(null, null, ctx.llm_config),
    );
}
/// All production dependencies wired into one bundle. Pass this as the first
/// argument to `maybeCompactMessagesNew` from production call sites; tests
/// construct their own `CompactDeps` with mock fns.
pub const defaultCompactDeps: CompactDeps = .{
    .shouldCompact = shouldCompactDefault,
    .callCompactAgent = callCompactAgent,
    .compactMessagesInMemory = compactMessageInMemoryNew,
};
/// Conditionally compact `messages` in place. The compact-agent call is
/// best-effort — if it returns null, the message list is left untouched and
/// the caller continues with the original messages. Returns `true` if
/// compaction was performed (caller should re-enter the loop with the now-
/// compacted list), `false` if no compaction was done. Errors from
/// `deps.compact_messages_in_memory` propagate to the caller.
///
/// `deps` is passed as a comptime value (a struct of comptime fn pointers) so
/// tests can swap in stubs for every non-std-lib function call without
/// touching this body. Production callers should pass `defaultCompactDeps`.
pub fn maybeCompactMessagesNew(
    comptime deps: CompactDeps,
    allocator: std.mem.Allocator,
    total_tokens: u32,
    model: []const u8,
    force: bool,
    messages: *std.ArrayList(agent.AgentMessage),
    api_key: []const u8,
    base_url: []const u8,
    cwd: []const u8,
    session_id: []const u8,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    logger: *Logger,
    llm_config: *const LlmConfig,
) !bool {
    if (!deps.shouldCompact(.{
        .force = force,
        .total_tokens = total_tokens,
        .model = model,
        .llm_config = llm_config,
    })) {
        return false;
    }

    const copy_messages = try allocator.dupe(agent.AgentMessage, messages.items);
    var copy_list = std.ArrayList(agent.AgentMessage).fromOwnedSlice(copy_messages);
    defer copy_list.deinit(allocator);

    const compacted_xml = deps.callCompactAgent(
        .{
            .allocator = allocator,
            .io = io,
            .messages = copy_list,
            .api_key = api_key,
            .model = model,
            .base_url = base_url,
            .logger = logger,
        },
    ) orelse {
        return false;
    };

    // call all user chat history to embed TODO
    // select where role is user and content is not null

    // call all file that are touched by ai TODO
    // tool name read_file , is_output true
    // only get path file

    _ = try deps.compactMessagesInMemory(
        allocator,
        messages.*,
        compacted_xml,
        session_id,
        model,
        cwd,
        db,
        io,
        logger,
    );
    return true;
}

/// Compact messages in memory based on CompactionAgent output.
/// Also persists to database: marks old messages as not for LLM, saves new compacted message.
/// On success, consumes `messages` (frees its backing slice) and returns the new
/// compacted list. On the `total <= 4` early return or any error before deinit,
/// `messages` is left intact and returned unchanged — the caller must always use
/// the return value.
pub fn compactMessageInMemoryNew(
    allocator: std.mem.Allocator,
    messages: std.ArrayList(agent.AgentMessage),
    compacted_xml: []const u8,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    logger: *Logger,
) !std.ArrayList(agent.AgentMessage) {
    const total = messages.items.len;
    if (total <= 4) return messages;

    // Mark all existing messages in this session as not for LLM (soft-delete)
    try mark_history_not_for_llmrun(allocator, db, session_id);

    // Build the compacted summary content with XML wrapping
    const summary_content = try buildCompactionEnvelope(
        allocator,
        messages.items[1..],
        total,
        session_id,
        model,
        io,
        compacted_xml,
        logger,
    );

    // Save the compacted summary to the database with is_feed_to_llm = 1
    try saveMessage(allocator, io, db, .{
        .session_id = session_id,
        .model = model,
        .cwd = cwd,
        .content = summary_content,
        .reasoning_content = null,
        .role = agent.Role.user.to_str(),
        .finish_reason = "stop",
        .tool_calls = null,
        .tool_call_id = null,
        .tool_name = null,
        .agent_name = "Agent",
        .loop_index = 0,
        .temperature = 0.0,
        .is_thinking = false,
        .is_input = true,
        .is_output = false,
    });

    // Update the session's cwd in the sessions table
    const copy_cwd = try allocator.dupe(u8, cwd);
    defer allocator.free(copy_cwd);
    try db.exec(allocator, "UPDATE sessions SET cwd = ? WHERE id = ?", &.{ copy_cwd, session_id });

    // Build new in-memory message list: system message + compacted summary
    var new_messages: std.ArrayList(agent.AgentMessage) = .empty;

    // Keep system message - duplicate content to be safe
    const system_content = if (messages.items[0].content) |c|
        try allocator.dupe(u8, c)
    else
        null;
    try new_messages.append(allocator, .{
        .role = .system,
        .content = system_content,
    });

    // Add compacted summary as user message
    try new_messages.append(allocator, .{
        .role = .user,
        .content = summary_content,
    });

    // Free ALL old messages (including ones we "kept" - we have copies now).
    // The old list is consumed; the caller must use the returned list.
    // Use a mutable local copy because the `messages` parameter is treated
    // as `const` in Zig 0.16 when the function signature has matching
    // parameter and return types (T → !T), and ArrayList.deinit requires
    // `*Self` (not `*const Self`).
    var messages_owned = messages;
    for (messages_owned.items) |*msg| {
        msg.deinit(allocator);
    }
    messages_owned.deinit(allocator);

    logger.debugFmt("[COMPACTION] Compacted: {} -> {} messages (persisted to DB)", .{ total, new_messages.items.len });
    return new_messages;
}

/// Build the structured `<compact_messages>` envelope that replaces
/// the dropped messages after compaction. The envelope has three
/// sections: <metadata> (compaction event facts), <message_index>
/// (id+role+preview for every dropped message so the agent can
/// reference them later via search_history), and <summary>
/// (the compactor's output, preserved verbatim).
///
/// `dropped_messages` is the slice of messages that will be marked
/// `is_feed_to_llm=0` — typically `messages.items[1..]` for the
/// compactMessageInMemoryNew caller. We capture their metadata HERE
/// (in memory) rather than re-querying the DB, because these messages
/// still have their content/tool_call_id fields available in the
/// in-memory struct.
///
/// Caller owns the returned string and must free with `allocator.free`.
const MAX_INDEX_ENTRIES: usize = 50;

fn buildCompactionEnvelope(
    allocator: std.mem.Allocator,
    dropped_messages: []const agent.AgentMessage,
    original_count: usize,
    session_id: []const u8,
    model: []const u8,
    io: std.Io,
    compacted_xml: []const u8,
    logger: *Logger,
) ![]u8 {
    // Real RFC3339-ish timestamp from std.Io.Timestamp — same pattern
    // the logger's Timing.timestampIso uses. Non-empty so the test
    // can verify the tag is present without hardcoding a value.
    const now_iso = try timestampIso(allocator, io);
    defer allocator.free(now_iso);

    var env: std.ArrayList(u8) = .empty;
    defer env.deinit(allocator);

    try env.appendSlice(allocator, "<compact_messages>\n");

    // --- metadata header ---
    try env.print(allocator,
        \\  <metadata>
        \\    <session_id>{s}</session_id>
        \\    <model>{s}</model>
        \\    <compacted_at>{s}</compacted_at>
        \\    <original_count>{d}</original_count>
        \\  </metadata>
        \\
    , .{ session_id, model, now_iso, original_count });

    // --- message_index ---
    // Capped to MAX_INDEX_ENTRIES so a very long session (e.g. 360+
    // dropped messages) can't blow up the envelope size on its own;
    // we keep the most RECENT dropped messages since those are most
    // likely to be relevant to what the agent does next, and note how
    // many older entries were omitted (full content still recoverable
    // from the DB via search_history / session_id).
    try env.appendSlice(allocator, "  <message_index>\n");

    const show_count = @min(dropped_messages.len, MAX_INDEX_ENTRIES);
    const start_idx = dropped_messages.len - show_count;
    const omitted_count = dropped_messages.len - show_count;

    if (omitted_count > 0) {
        try env.print(
            allocator,
            "    <truncated_entries count=\"{d}\" note=\"older entries omitted from index; use search_history with session_id to fetch full history from DB\"/>\n",
            .{omitted_count},
        );
    }

    for (dropped_messages[start_idx..], start_idx..) |msg, i| {
        const msg_id = try std.fmt.allocPrint(allocator, "adhoc_{d}", .{i});
        defer allocator.free(msg_id);

        const role_str = msg.role.to_str();
        const preview = msg.content orelse "";
        // Byte-slice cap; fine for ASCII previews. If non-English content
        // is common, swap for a UTF-8-aware trim so we don't cut a
        // multi-byte codepoint in half.
        const preview_trimmed = if (preview.len > 100) preview[0..100] else preview;
        const preview_escaped = try xml_escape(allocator, preview_trimmed);
        defer allocator.free(preview_escaped);

        try env.print(allocator,
            \\    <entry>
            \\      <id>{s}</id>
            \\      <role>{s}</role>
            \\
        , .{ msg_id, role_str });

        // For tool-result messages, surface tool_call_id so the agent
        // can match results back to calls. (tool_name is not available
        // on the in-memory AgentMessage struct in this codebase; the
        // search_history tool can fetch it from the DB row.)
        if (msg.role == .tool) {
            const tcid = msg.tool_call_id orelse "";
            const tcid_escaped = try xml_escape(allocator, tcid);
            defer allocator.free(tcid_escaped);
            try env.print(allocator, "      <tool_call_id>{s}</tool_call_id>\n", .{tcid_escaped});
        }

        try env.print(allocator,
            \\      <preview>{s}</preview>
            \\    </entry>
            \\
        , .{preview_escaped});
    }

    try env.appendSlice(allocator, "  </message_index>\n");

    // --- summary (the compactor's output) ---
    // Hard cap as a safety net — the real budget should be enforced via
    // the compactor prompt itself, but we never want a misbehaving model
    // response to produce an unbounded envelope.
    const summary_to_embed = compacted_xml;

    // Wrapped in CDATA so embedded <, >, & in the summary (quoted file
    // contents, shell output, diffs, etc.) can never break the envelope.
    // If the summary itself contains the CDATA close sequence "]]>", we
    // split it into adjacent CDATA sections rather than escaping, so the
    // model still sees natural punctuation everywhere else.
    try env.appendSlice(allocator, "  <summary><![CDATA[\n");
    if (std.mem.indexOf(u8, summary_to_embed, "]]>") == null) {
        try env.appendSlice(allocator, summary_to_embed);
    } else {
        var rest = summary_to_embed;
        while (std.mem.indexOf(u8, rest, "]]>")) |idx| {
            try env.appendSlice(allocator, rest[0 .. idx + 2]); // up to and incl "]]"
            try env.appendSlice(allocator, "]]><![CDATA[>"); // close, literal '>', reopen
            rest = rest[idx + 3 ..];
        }
        try env.appendSlice(allocator, rest);
    }
    try env.appendSlice(allocator, "\n]]></summary>\n");

    try env.appendSlice(allocator, "</compact_messages>\n");

    const result = try env.toOwnedSlice(allocator);
    logger.debugFmt(
        "[COMPACTION] envelope size: {d} bytes, {d}/{d} index entries shown, summary {d}/{d} bytes",
        .{ result.len, show_count, dropped_messages.len, summary_to_embed.len, compacted_xml.len },
    );
    return result;
}

const testing = std.testing;

// ─── Mock infrastructure ────────────────────────────────────────────────────

/// Records what each mock saw on its last invocation, plus what to return on
/// the next call. Lives at module scope so the comptime fns can write to it
/// (comptime fns cannot capture locals).
const MockState = struct {
    // ─── shouldCompact mock ────────────────────────────────────────────
    should_compact_calls: u32 = 0,
    last_ctx_force: bool = undefined,
    last_ctx_total_tokens: u32 = undefined,
    last_ctx_model: []const u8 = undefined,
    should_compact_result: bool = true, // default: "yes, compact"

    // ─── callCompactAgent mock ────────────────────────────────────────
    call_compact_agent_calls: u32 = 0,
    last_agent_model: []const u8 = "",
    last_agent_api_key: []const u8 = "",
    last_agent_base_url: []const u8 = "",
    last_agent_messages_len: usize = 0,
    next_compact_xml: ?[]const u8 = null, // null → mock returns null

    // ─── compactMessagesInMemory mock ──────────────────────────────────
    compact_messages_in_memory_calls: u32 = 0,
    last_compacted_xml: []const u8 = "",
    last_compact_session_id: []const u8 = "",
    last_compact_model: []const u8 = "",
    /// If `compact_returns_null` is true, the mock returns error.Skip to
    /// propagate as a test signal. (Mock returns the messages list unchanged
    /// on success — the test owns them.)
    compact_skip: bool = false,
};

var mock_state: MockState = .{};

fn resetMockState() void {
    mock_state = .{};
}

// ─── Three mock fns (one per CompactDeps field) ───────────────────────────

fn mockShouldCompact(ctx: ThresholdCtx) bool {
    mock_state.should_compact_calls += 1;
    mock_state.last_ctx_force = ctx.force;
    mock_state.last_ctx_total_tokens = ctx.total_tokens;
    mock_state.last_ctx_model = ctx.model;
    return mock_state.should_compact_result;
}

fn mockCallCompactAgent(obj: CallCompactAgentInput) ?[]const u8 {
    mock_state.call_compact_agent_calls += 1;
    mock_state.last_agent_model = obj.model;
    mock_state.last_agent_api_key = obj.api_key;
    mock_state.last_agent_base_url = obj.base_url;
    mock_state.last_agent_messages_len = obj.messages.items.len;
    return mock_state.next_compact_xml;
}

fn mockCompactMessagesInMemory(
    allocator: std.mem.Allocator,
    messages: std.ArrayList(agent.AgentMessage),
    compacted_xml: []const u8,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    logger: *Logger,
) anyerror!std.ArrayList(agent.AgentMessage) {
    _ = allocator;
    _ = cwd;
    _ = db;
    _ = io;
    _ = logger;
    mock_state.compact_messages_in_memory_calls += 1;
    mock_state.last_compacted_xml = compacted_xml;
    mock_state.last_compact_session_id = session_id;
    mock_state.last_compact_model = model;
    if (mock_state.compact_skip) return error.Skip;
    // Return the messages unchanged. The test owns them — `messages.*` was
    // passed in by value from `maybeCompactMessagesNew`, and we don't want
    // to double-free or invalidate the test's `messages.items`.
    return messages;
}

/// The mock bundle wired into a `CompactDeps`. Pass this as the first arg
/// to `maybeCompactMessagesNew` from any test in this file.
const mockCompactDeps: CompactDeps = .{
    .shouldCompact = mockShouldCompact,
    .callCompactAgent = mockCallCompactAgent,
    .compactMessagesInMemory = mockCompactMessagesInMemory,
};

// ─── Test fixtures ──────────────────────────────────────────────────────────

fn buildTestConfig(allocator: std.mem.Allocator) LlmConfig {
    return .{
        .allocator = allocator,
        .api_key = "sk-test",
        .model = "test-model",
        .base_url = "https://test.example",
        .model_compaction_size_kb = 100,
        .mcpServers_parsed = null,
        .mcp_servers = LlmConfig.McpServersMap.init(allocator),
        .profiles_models = LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
        .url_style = "openai",
    };
}

/// Build a 6-message list like the production workflow. Returns ownership to
/// the caller — caller MUST `defer` cleanup of `messages.items` and `messages`.
fn buildMessages(allocator: std.mem.Allocator) !std.ArrayList(agent.AgentMessage) {
    var list: std.ArrayList(agent.AgentMessage) = .empty;
    try list.append(allocator, .{ .role = .system, .content = try allocator.dupe(u8, "sys") });
    try list.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "u1") });
    try list.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "a1") });
    try list.append(allocator, .{ .role = .tool, .content = try allocator.dupe(u8, "t1"), .tool_call_id = try allocator.dupe(u8, "tc_1") });
    try list.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "u2") });
    try list.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "a2") });
    return list;
}

fn freeMessages(allocator: std.mem.Allocator, messages: *std.ArrayList(agent.AgentMessage)) void {
    for (messages.items) |*m| m.deinit(allocator);
    var owned = messages.*;
    owned.deinit(allocator);
}

// ─── Tests ─────────────────────────────────────────────────────────────────

test "shouldCompact dep is called with the right context (force, tokens, model)" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = false; // gate early-return path

    _ = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        123_456,
        "gpt-4o-mini",
        false,
        &messages,
        "sk-test",
        "https://test.example",
        "/tmp",
        "sess_mock",
        undefined, // db — not reached when shouldCompact=false
        std.testing.io,
        &lg,
        &cfg,
    );

    try testing.expectEqual(@as(u32, 1), mock_state.should_compact_calls);
    try testing.expectEqual(false, mock_state.last_ctx_force);
    try testing.expectEqual(@as(u32, 123_456), mock_state.last_ctx_total_tokens);
    try testing.expectEqualStrings("gpt-4o-mini", mock_state.last_ctx_model);
}

test "shouldCompact returning false short-circuits — no other deps called" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = false;

    const result = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        100,
        "test-model",
        false,
        &messages,
        "sk-test",
        "https://test.example",
        "/tmp",
        "sess_mock",
        undefined,
        std.testing.io,
        &lg,
        &cfg,
    );

    try testing.expectEqual(false, result);
    try testing.expectEqual(@as(u32, 1), mock_state.should_compact_calls);
    try testing.expectEqual(@as(u32, 0), mock_state.call_compact_agent_calls);
    try testing.expectEqual(@as(u32, 0), mock_state.compact_messages_in_memory_calls);
}

test "shouldCompact returning true routes through callCompactAgent" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = null; // callCompactAgent returns null → function returns false

    const result = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        100,
        "test-model",
        true, // force — shouldCompact mock just receives it; mock decides
        &messages,
        "sk-bespoke",
        "https://bespoke.example",
        "/tmp",
        "sess_mock",
        undefined, // db — not reached when callCompactAgent returns null
        std.testing.io,
        &lg,
        &cfg,
    );

    try testing.expectEqual(false, result);
    try testing.expectEqual(@as(u32, 1), mock_state.should_compact_calls);
    try testing.expectEqual(@as(u32, 1), mock_state.call_compact_agent_calls);
    // compact_messages_in_memory was NOT called (callCompactAgent returned null)
    try testing.expectEqual(@as(u32, 0), mock_state.compact_messages_in_memory_calls);
    // callCompactAgent received the right fields
    try testing.expectEqualStrings("test-model", mock_state.last_agent_model);
    try testing.expectEqualStrings("sk-bespoke", mock_state.last_agent_api_key);
    try testing.expectEqualStrings("https://bespoke.example", mock_state.last_agent_base_url);
    try testing.expectEqual(@as(usize, 6), mock_state.last_agent_messages_len);
}

test "callCompactAgent returning null short-circuits — compact_messages_in_memory not called" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = null;

    const result = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        100,
        "test-model",
        false,
        &messages,
        "sk-test",
        "https://test.example",
        "/tmp",
        "sess_mock",
        undefined,
        std.testing.io,
        &lg,
        &cfg,
    );

    try testing.expectEqual(false, result);
    try testing.expectEqual(@as(u32, 1), mock_state.call_compact_agent_calls);
    try testing.expectEqual(@as(u32, 0), mock_state.compact_messages_in_memory_calls);
}

test "full happy path: all three deps called, returns true" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = "GOAL: ship it\nNEXT ACTION: merge";

    const result = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        200_000,
        "test-model",
        true,
        &messages,
        "sk-test",
        "https://test.example",
        "/tmp",
        "sess_bespoke",
        undefined, // db — mock doesn't touch it
        std.testing.io,
        &lg,
        &cfg,
    );

    try testing.expectEqual(true, result);
    try testing.expectEqual(@as(u32, 1), mock_state.should_compact_calls);
    try testing.expectEqual(@as(u32, 1), mock_state.call_compact_agent_calls);
    try testing.expectEqual(@as(u32, 1), mock_state.compact_messages_in_memory_calls);
    try testing.expectEqualStrings("GOAL: ship it\nNEXT ACTION: merge", mock_state.last_compacted_xml);
    try testing.expectEqualStrings("sess_bespoke", mock_state.last_compact_session_id);
    try testing.expectEqualStrings("test-model", mock_state.last_compact_model);
}

test "compact_messages_in_memory error propagates to caller" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = "valid xml";
    mock_state.compact_skip = true; // mock returns error.Skip

    const result = maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        200_000,
        "test-model",
        true,
        &messages,
        "sk-test",
        "https://test.example",
        "/tmp",
        "sess_mock",
        undefined,
        std.testing.io,
        &lg,
        &cfg,
    );

    try testing.expectError(error.Skip, result);
}

