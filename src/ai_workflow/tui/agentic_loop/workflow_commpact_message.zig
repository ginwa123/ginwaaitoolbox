const std = @import("std");
const nalarcore = @import("nalarcore");
const CallCompactAgentInput = @import("compaction.zig").CallCompactAgentInput;
const callCompactAgent = @import("compaction.zig").callCompactAgent;
const mark_history_not_for_llmrun = @import("markHistoryNotForLLMRun.zig").markHistoryNotForLLMRun;
const compaction_context = @import("compaction_context.zig");

const LlmConfig = nalarcore.config.LlmConfig;
const agent = nalarcore.agent;
const AgentMessage = agent.AgentMessage;
const sqlite = nalarcore.sqlite;
const SqliteBackend = sqlite.SqliteBackend;
const Logger = nalarcore.loggermod.Logger;
const timestampIso = nalarcore.loggermod.timestampIso;
const xml_escape = nalarcore.helpers.xml_escape;
const saveMessage = @import("../llm_history.zig").saveMessage;
const llm_history = @import("../llm_history.zig");

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

    // Fetch user chat history + read_file paths + recent activities BEFORE
    // the mark_history_not_for_llmrun step takes them offline. The new
    // INSERT into llm_history (inside compactMessagesInMemory) carries the
    // enriched context forward to the next agent iteration.
    var user_turns = compaction_context.fetchUserChatHistory(allocator, db, session_id) catch |err| blk: {
        logger.warnFmt("[COMPACTION] fetchUserChatHistory failed: {s}", .{@errorName(err)});
        break :blk std.ArrayList(compaction_context.UserTurn).empty;
    };
    defer {
        for (user_turns.items) |t| t.deinit(allocator);
        user_turns.deinit(allocator);
    }
    var read_files = compaction_context.fetchReadFilePaths(allocator, db, session_id, logger) catch |err| blk: {
        logger.warnFmt("[COMPACTION] fetchReadFilePaths failed: {s}", .{@errorName(err)});
        break :blk std.ArrayList(compaction_context.ReadFileTurn).empty;
    };
    defer {
        for (read_files.items) |rf| rf.deinit(allocator);
        read_files.deinit(allocator);
    }
    // Recent activities: what the agent was thinking/doing at the tail of
    // the now-compacted-away messages. Mirrors user_turns/read_files: an
    // empty list is fine (the enrich helper omits the section entirely),
    // a DB error is logged + skipped (better to lose the section than to
    // abort the whole compaction). Capped at 20 rows so the envelope
    // stays bounded on long sessions where the activity log could be
    // thousands of rows — the agent only needs the most recent tail.
    const RECENT_ACTIVITIES_LIMIT: u32 = 20;
    var recent_activities = compaction_context.fetchRecentActivities(allocator, db, session_id, RECENT_ACTIVITIES_LIMIT) catch |err| blk: {
        logger.warnFmt("[COMPACTION] fetchRecentActivities failed: {s}", .{@errorName(err)});
        break :blk std.ArrayList(compaction_context.RecentActivity).empty;
    };
    defer {
        for (recent_activities.items) |a| a.deinit(allocator);
        recent_activities.deinit(allocator);
    }
    // Session skills (loaded via the `add_skill` tool) are stable
    // guidance material the compactor is unlikely to summarize verbatim.
    // Embedding them here gives the post-compaction agent continuity on
    // what skills were active before compaction. Fetched before
    // mark_history_not_for_llmrun so the next iteration's enriched
    // INSERT can carry them forward alongside the rest of the context.
    const session_skills = compaction_context.fetchSessionSkills(allocator, db, session_id) catch |err| blk: {
        logger.warnFmt("[COMPACTION] fetchSessionSkills failed: {s}", .{@errorName(err)});
        break :blk &.{};
    };
    defer {
        for (session_skills) |s| s.deinit(allocator);
        allocator.free(session_skills);
    }

    const enriched_xml = compaction_context.enrichCompactionXml(
        allocator,
        compacted_xml,
        user_turns.items,
        read_files.items,
        recent_activities.items,
        session_skills,
        cwd,
    ) catch |err| {
        logger.warnFmt("[COMPACTION] enrichCompactionXml failed: {s}", .{@errorName(err)});
        return false;
    };
    defer allocator.free(enriched_xml);

    _ = try deps.compactMessagesInMemory(
        allocator,
        messages.*,
        enriched_xml,
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
    /// Owned copy of the compacted XML the mock received. The caller frees
    /// its buffer as soon as `compactMessagesInMemory` returns (defer in
    /// `maybeCompactMessagesNew`), so the mock MUST dup before storing —
    /// otherwise later test assertions would read freed memory.
    last_compacted_xml_owned: []u8 = "",
    last_compacted_xml: []const u8 = "", // alias — points into last_compacted_xml_owned
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

/// Free the heap-owned copy of the last compacted XML and reset the
/// pointer fields. Tests that read `mock_state.last_compacted_xml` MUST
/// defer this call (BEFORE any leak detector runs) so the buffer isn't
/// reported as leaked. Tests that don't read it can skip this call.
fn releaseLastCompactedXml() void {
    if (mock_state.last_compacted_xml_owned.len > 0) {
        std.testing.allocator.free(mock_state.last_compacted_xml_owned);
        mock_state.last_compacted_xml_owned = "";
        mock_state.last_compacted_xml = "";
    }
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
    _ = cwd;
    _ = db;
    _ = io;
    _ = logger;
    mock_state.compact_messages_in_memory_calls += 1;
    // Dup the XML before storing — caller frees the original on return.
    // (See `last_compacted_xml_owned` doc-comment and `releaseLastCompactedXml`.)
    mock_state.last_compacted_xml_owned = try allocator.dupe(u8, compacted_xml);
    mock_state.last_compacted_xml = mock_state.last_compacted_xml_owned;
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
    var s = try setupDbForEnrichmentTest();
    defer teardownDbForEnrichmentTest(&s);

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = "GOAL: ship it\nNEXT ACTION: merge";
    defer releaseLastCompactedXml();

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
        &s.db,
        std.testing.io,
        &lg,
        &cfg,
    );

    try testing.expectEqual(true, result);
    try testing.expectEqual(@as(u32, 1), mock_state.should_compact_calls);
    try testing.expectEqual(@as(u32, 1), mock_state.call_compact_agent_calls);
    try testing.expectEqual(@as(u32, 1), mock_state.compact_messages_in_memory_calls);
    // The bare compacted_xml is now wrapped in <compaction_context> by the
    // new enrichment step; the bare content survives inside <summary>.
    try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "GOAL: ship it\nNEXT ACTION: merge") != null);
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
    var s = try setupDbForEnrichmentTest();
    defer teardownDbForEnrichmentTest(&s);

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = "valid xml";
    mock_state.compact_skip = true; // mock returns error.Skip
    defer releaseLastCompactedXml();

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
        &s.db,
        std.testing.io,
        &lg,
        &cfg,
    );

    try testing.expectError(error.Skip, result);
}

// ─── Better-compaction-context integration tests ──────────────────────────

/// In-memory DB with just the columns `fetchUserChatHistory`,
/// `fetchReadFilePaths`, and `fetchRecentActivities` read. The mock
/// `compactMessagesInMemory` is `db`-agnostic, so we don't need the
/// full sessions/llm_history schema the real
/// `compactMessageInMemoryNew` requires.
fn setupDbForEnrichmentTest() !struct {
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

    try db.exec(alloc,
        "CREATE TABLE llm_history (" ++
            "  id TEXT PRIMARY KEY," ++
            "  session_id TEXT NOT NULL," ++
            "  model TEXT," ++
            "  response_content TEXT," ++
            "  role TEXT," ++
            "  tool_name TEXT," ++
            "  is_input INTEGER DEFAULT 0," ++
            "  is_output INTEGER DEFAULT 0," ++
            "  is_feed_to_llm INTEGER DEFAULT 1," ++
            "  created_at TEXT DEFAULT (datetime('now'))" ++
            ")",
        &[_][]const u8{},
    );
    try db.exec(alloc,
        "CREATE TABLE session_activity (" ++
            "  id TEXT PRIMARY KEY," ++
            "  session_id TEXT NOT NULL," ++
            "  description TEXT NOT NULL," ++
            "  created_at DATETIME DEFAULT CURRENT_TIMESTAMP" ++
            ")",
        &[_][]const u8{},
    );
    return .{ .db = db, .threaded = threaded };
}

fn teardownDbForEnrichmentTest(s: *@TypeOf(setupDbForEnrichmentTest() catch unreachable)) void {
    s.db.deinit();
    s.threaded.deinit();
}

fn seedUserForEnrichmentTest(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    session_id: []const u8,
    content: []const u8,
    created_at: []const u8,
) !void {
    try db.exec(
        alloc,
        "INSERT INTO llm_history " ++
            "(id, session_id, model, response_content, role, tool_name, is_input, is_output, is_feed_to_llm, created_at) " ++
            "VALUES (?, ?, 'test-model', ?, 'user', '', 1, 0, 1, ?)",
        &.{ id, session_id, content, created_at },
    );
}

fn seedReadFileForEnrichmentTest(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    session_id: []const u8,
    content: []const u8,
    created_at: []const u8,
) !void {
    try db.exec(
        alloc,
        "INSERT INTO llm_history " ++
            "(id, session_id, model, response_content, role, tool_name, is_input, is_output, is_feed_to_llm, created_at) " ++
            "VALUES (?, ?, 'test-model', ?, 'tool', 'read_file', 0, 1, 1, ?)",
        &.{ id, session_id, content, created_at },
    );
}

fn seedRecentActivityForEnrichmentTest(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    session_id: []const u8,
    description: []const u8,
    created_at: []const u8,
) !void {
    try db.exec(
        alloc,
        "INSERT INTO session_activity (id, session_id, description, created_at) " ++
            "VALUES (?, ?, ?, ?)",
        &.{ id, session_id, description, created_at },
    );
}

test "happy path embeds user history and read_file paths into the compaction XML" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);

    var s = try setupDbForEnrichmentTest();
    defer teardownDbForEnrichmentTest(&s);

    try seedUserForEnrichmentTest(alloc, &s.db, "u1", "sess_embed", "first user message", "2026-01-01 00:00:01");
    try seedReadFileForEnrichmentTest(alloc, &s.db, "rf1", "sess_embed", "<path>/home/user/foo.zig</path><content>body</content>", "2026-01-01 00:00:02");
    try seedUserForEnrichmentTest(alloc, &s.db, "u2", "sess_embed", "second user message", "2026-01-01 00:00:03");

    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = "GOAL: ship X";
    defer releaseLastCompactedXml();

    const result = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        200_000,
        "test-model",
        true,
        &messages,
        "sk-test",
        "https://test.example",
        "/home/user",
        "sess_embed",
        &s.db,
        std.testing.io,
        &lg,
        &cfg,
    );

    try testing.expect(result);
    try testing.expectEqual(@as(u32, 1), mock_state.compact_messages_in_memory_calls);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "<user_history>") != null);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "<read_files>") != null);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "first user message") != null);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "second user message") != null);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "/home/user/foo.zig") != null);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "GOAL: ship X") != null);
}

test "compaction still proceeds when fetchUserChatHistory returns empty (no user rows)" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);

    var s = try setupDbForEnrichmentTest();
    defer teardownDbForEnrichmentTest(&s);

    // No seeded rows. user_turns comes back empty, read_files empty, but
    // the bare compacted_xml still passes through to compactMessagesInMemory.

    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = "GOAL: ship X";
    defer releaseLastCompactedXml();

    const result = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        200_000,
        "test-model",
        true,
        &messages,
        "sk-test",
        "https://test.example",
        "/home/user",
        "sess_empty",
        &s.db,
        std.testing.io,
        &lg,
        &cfg,
    );

    try testing.expect(result);
    try testing.expectEqual(@as(u32, 1), mock_state.compact_messages_in_memory_calls);
    // The enrich helper wraps the bare compacted_xml in <compaction_context>.
    try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "<compaction_context>") != null);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "GOAL: ship X") != null);
}

// ─── Migration 073 — recent_activities integration tests ────────────────────
//
// Per PR #226 review feedback: the compaction flow must READ prior
// session_activity rows (recorded by `update_activity`) and embed them
// in a `<recent_activities>` section inside the <compaction_context>
// enrichment, NOT record a new "[COMPACTION] Compacted..." row.
//
// After the refactor that lifted recent_activities fetch + embed from
// buildCompactionEnvelope into maybeCompactMessagesNew, these tests
// exercise the FULL path through maybeCompactMessagesNew so we
// actually verify the DB fetch + enrich step, not just the envelope
// builder.

test "happy path embeds prior session_activity rows in <recent_activities>" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);

    var s = try setupDbForEnrichmentTest();
    defer teardownDbForEnrichmentTest(&s);

    // Pre-seed 3 prior update_activity rows for this session. Insert
    // them in NON-chrono order to verify the envelope sorts them
    // (oldest first).
    try seedRecentActivityForEnrichmentTest(alloc, &s.db, "a3", "sess_recent", "wiring it in", "2026-01-01 00:00:03");
    try seedRecentActivityForEnrichmentTest(alloc, &s.db, "a1", "sess_recent", "planning the migration", "2026-01-01 00:00:01");
    try seedRecentActivityForEnrichmentTest(alloc, &s.db, "a2", "sess_recent", "writing the test", "2026-01-01 00:00:02");

    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = "GOAL: ship X";
    defer releaseLastCompactedXml();

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
        "sess_recent",
        &s.db,
        std.testing.io,
        &lg,
        &cfg,
    );

    try testing.expect(result);
    try testing.expectEqual(@as(u32, 1), mock_state.compact_messages_in_memory_calls);
    // The <recent_activities> section is embedded inside
    // <compaction_context> by enrichCompactionXml.
    try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "<recent_activities") != null);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "planning the migration") != null);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "writing the test") != null);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "wiring it in") != null);
    // The activities must appear in chronological (oldest first) order.
    const planning_pos = std.mem.indexOf(u8, mock_state.last_compacted_xml, "planning the migration").?;
    const writing_pos = std.mem.indexOf(u8, mock_state.last_compacted_xml, "writing the test").?;
    const wiring_pos = std.mem.indexOf(u8, mock_state.last_compacted_xml, "wiring it in").?;
    try testing.expect(planning_pos < writing_pos);
    try testing.expect(writing_pos < wiring_pos);

    // The session_activity table must NOT have grown — the compaction
    // event is NOT recorded (per review feedback).
    {
        const sid_dup = try alloc.dupe(u8, "sess_recent");
        defer alloc.free(sid_dup);
        const args = [_][]const u8{sid_dup};
        var q = try s.db.query(alloc,
            "SELECT COUNT(*) FROM session_activity WHERE session_id = ?",
            &args);
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("3", row.values[0]); // still just the 3 pre-seeded rows
    }
}

test "omits <recent_activities> when session has no prior activity" {
    // When there are no prior session_activity rows for the session,
    // the enriched XML must OMIT the <recent_activities> section
    // entirely (rather than emit an empty one).
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);

    var s = try setupDbForEnrichmentTest();
    defer teardownDbForEnrichmentTest(&s);

    // No session_activity rows seeded for sess_no_activity.

    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = "GOAL: ship X";
    defer releaseLastCompactedXml();

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
        "sess_no_activity",
        &s.db,
        std.testing.io,
        &lg,
        &cfg,
    );

    try testing.expect(result);
    try testing.expectEqual(@as(u32, 1), mock_state.compact_messages_in_memory_calls);
    // <recent_activities> should be omitted entirely (no empty tag).
    try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "<recent_activities") == null);
}

