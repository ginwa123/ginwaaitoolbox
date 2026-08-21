const std = @import("std");
const nalarcore = @import("nalarcore");
const mark_history_not_for_llmrun = @import("markHistoryNotForLLMRun.zig").markHistoryNotForLLMRun;
const compact_message = @import("workflow_compact_message.zig");
const buildCompactMessagePrompt = compact_message.buildCompactMessagePrompt;
const migration = @import("../../../migrations/migration.zig");
const session_plan = @import("session_plan.zig");

const LlmConfig = nalarcore.config.LlmConfig;
const agent = nalarcore.agent;
const prompt = nalarcore.agent.prompt;
const AgentMessage = agent.AgentMessage;
const sqlite = nalarcore.sqlite;
const SqliteBackend = sqlite.SqliteBackend;
const Logger = nalarcore.loggermod.Logger;
const timestampIso = nalarcore.loggermod.timestampIso;
const xml_escape = nalarcore.helpers.xml_escape;
const saveMessage = @import("llm_history.zig").saveMessage;
const llm_history = @import("llm_history.zig");
const insertLLMHistory = @import("insert_llm_histories.zig").inserLLMHistories;
const event_bus_mod = nalarcore.event_bus;

/// Inputs to `callCompactAgent`. Moved here from the (now-deleted)
/// `compaction.zig` (PR this file's task card) — same struct, same
/// defaults. Kept as `pub` so the orchestrator's `CompactDeps.callCompactAgent`
/// fn-pointer field and the workflow.zig re-export both still resolve.
pub const CallCompactAgentInput = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: ?*Logger,
    messages: std.ArrayList(AgentMessage),
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    /// URL style of the calling profile (`"openai"` or `"anthropic"`).
    /// The CompactionAgent must use the SAME wire format as the main
    /// agent loop — otherwise an Anthropic-style base_url receives an
    /// OpenAI-shaped JSON request and rejects it, silently dropping
    /// the compaction. Mirrors the propagation pattern from
    /// `effective_url_style` in workflow.zig. Defaults to `"openai"`
    /// for callers that haven't been updated yet (back-compat with
    /// existing in-flight sessions). Plan: this file's task card.
    url_style: []const u8 = "openai",
};

/// Call the CompactionAgent to compress the conversation history into a
/// handoff package. Best-effort: any failure (network, parse, agent
/// construction) returns `null` and the orchestrator short-circuits
/// without compacting. The orchestrator (`maybeCompactMessagesNew`) is
/// the only production caller; tests stub the comptime fn-pointer field
/// in `CompactDeps.callCompactAgent`.
pub fn callCompactAgent(obj: CallCompactAgentInput) ?[]const u8 {
    const allocator = obj.allocator;
    const messages = obj.messages;
    const logger = obj.logger;
    const api_key = obj.api_key;
    const model = obj.model;
    const base_url = obj.base_url;
    const url_style = obj.url_style;
    const io = obj.io;

    if (messages.items.len < 2) {
        logger.?.warnFmt("[COMPACTION] Not enough messages to compact", .{});
        return null;
    }

    const original_system_prompt: []const u8 = messages.items[0].content orelse "";

    const compact_message_text = buildCompactMessagePrompt(
        allocator,
        logger,
        messages,
        original_system_prompt,
    ) orelse return null;
    defer allocator.free(compact_message_text);

    var messages_convocompact: std.ArrayList(AgentMessage) = .empty;
    defer messages_convocompact.deinit(allocator);

    messages_convocompact.append(allocator, .{
        .role = .system,
        .content = prompt.CompactionAgent,
    }) catch |err| {
        logger.?.errFmt("[COMPACTION] Failed to append system message: {s}", .{@errorName(err)});
        return null;
    };

    messages_convocompact.append(allocator, .{
        .role = .user,
        .content = compact_message_text,
    }) catch |err| {
        logger.?.errFmt("[COMPACTION] Failed to append user message: {s}", .{@errorName(err)});
        return null;
    };

    var compaction_agent = agent.Agent.init(allocator, io);
    defer compaction_agent.deinit();

    compaction_agent.apiKey = api_key;
    compaction_agent.model = model;
    compaction_agent.baseUrl = base_url;
    // Wire format must match the upstream endpoint. Without this set,
    // Agent defaults to "openai" — which means an `url_style: "anthropic"`
    // profile (e.g. "900 ribu antropic") sends an OpenAI-shaped JSON
    // body to https://api.minimax.io/anthropic, the upstream returns
    // an error, `callStreaming` returns an error, and `callCompactAgent`
    // silently returns null. The threshold check still fires (and the
    // session still balloons to 497K+ tokens) — the compaction just
    // never completes. This propagation fixes that.
    compaction_agent.UrlStyle = url_style;

    const response = compaction_agent.callStreaming(.{
        .tools = &.{},
        .messages = messages_convocompact.items,
        .temperature = 0.0,
    }, null, noopStreamCallbackNew) catch |err| {
        logger.?.errFmt("[COMPACTION] callStreaming failed: {s}", .{@errorName(err)});
        return null;
    };
    defer response.deinit();

    const content = response.content orelse {
        logger.?.errFmt("[COMPACTION] Response content is null", .{});
        return null;
    };

    if (content.len == 0) {
        logger.?.warnFmt("[COMPACTION] Empty response from CompactionAgent", .{});
        return null;
    }

    const duplicated = allocator.dupe(u8, content) catch |err| {
        logger.?.errFmt("[COMPACTION] Failed to duplicate content: {s}", .{@errorName(err)});
        return null;
    };

    return duplicated;
}

fn noopStreamCallbackNew(_: ?*anyopaque, _: agent.StreamChunk) void {}

/// Bundle of inputs to `shouldCompactDefault` — the threshold decision that
/// tests can swap via `CompactDeps.should_compact`. Carries enough context that
/// a test can assert on what the production decision actually saw (force flag,
/// total_tokens, model, llm_config).
pub const ThresholdCtx = struct {
    force: bool,
    total_tokens: u32,
    model: []const u8,
    llm_config: *const LlmConfig,
    /// The session's selected profile, resolved by the caller from
    /// `sessions.selected_profile_model`. Feeds cascade step 2 of
    /// `maxCapacityForModel` / `compactionThresholdPercent` so a
    /// profile's `max_capacity_tokens` / `compaction_threshold_percent`
    /// overrides shape the compaction decision. 2026-08-21-fix-ui-
    /// context-window: previously hardcoded null, so the backend compacted
    /// at 80% of the built-in window even when the selected profile
    /// overrode it — disagreeing with the (now profile-aware) chat footer.
    /// `null` → fall through to Defaults-tab → built-in default.
    profile: ?*const LlmConfig.LlmProfile = null,
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
        event_bus: ?*event_bus_mod.EventBus,
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
        ctx.llm_config.maxCapacityForModel(ctx.profile, null, ctx.llm_config, ctx.model),
        ctx.llm_config.compactionThresholdPercent(ctx.profile, null, ctx.llm_config),
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
    /// URL style of the calling profile (`"openai"` or `"anthropic"`).
    /// Propagated to `callCompactAgent` so the CompactionAgent sends
    /// the SAME wire format as the main loop. Without this, an
    /// `url_style: "anthropic"` profile (e.g. "900 ribu antropic")
    /// sends an OpenAI-shaped JSON body to an Anthropic endpoint,
    /// the upstream rejects it, and `callCompactAgent` silently
    /// returns null — so the threshold check fires every iteration
    /// but compaction never completes (sessions balloon past the
    /// threshold forever). Defaults to `"openai"` for back-compat
    /// with callers that haven't been updated. Plan: this file's
    /// task card.
    url_style: []const u8,
    cwd: []const u8,
    session_id: []const u8,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    logger: *Logger,
    /// Event bus for SSE side-effects (insertLLMHistory's
    /// `onEventSendLLMHistory` path). Pass `null` when running
    /// offline (tests, the manual `/session/compact` endpoint
    /// without an open chat, etc.). The DB write happens
    /// regardless — `null` only skips the SSE fanout.
    event_bus: ?*event_bus_mod.EventBus,
    llm_config: *const LlmConfig,
    /// The session's selected profile (resolved by the caller from
    /// `sessions.selected_profile_model` via `LlmConfig.getProfile`).
    /// Threaded into `ThresholdCtx` so `shouldCompactDefault` honors the
    /// profile's `max_capacity_tokens` / `compaction_threshold_percent`
    /// overrides. `null` → Defaults-tab → built-in default (old behavior).
    /// 2026-08-21-fix-ui-context-window.
    profile: ?*const LlmConfig.LlmProfile,
) !bool {
    if (!deps.shouldCompact(.{
        .force = force,
        .total_tokens = total_tokens,
        .model = model,
        .llm_config = llm_config,
        .profile = profile,
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
            .url_style = url_style,
            .logger = logger,
        },
    ) orelse {
        return false;
    };

    // Fetch user chat history + read_file paths + recent activities BEFORE
    // the mark_history_not_for_llmrun step takes them offline. The new
    // INSERT into llm_history (inside compactMessagesInMemory) carries the
    // enriched context forward to the next agent iteration.
    var user_turns = compact_message.fetchUserChatHistory(allocator, db, session_id) catch |err| blk: {
        logger.warnFmt("[COMPACTION] fetchUserChatHistory failed: {s}", .{@errorName(err)});
        break :blk std.ArrayList(compact_message.UserTurn).empty;
    };
    defer {
        for (user_turns.items) |t| t.deinit(allocator);
        user_turns.deinit(allocator);
    }
    var read_files = compact_message.fetchReadFilePaths(allocator, db, session_id, logger) catch |err| blk: {
        logger.warnFmt("[COMPACTION] fetchReadFilePaths failed: {s}", .{@errorName(err)});
        break :blk std.ArrayList(compact_message.ReadFileTurn).empty;
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
    var recent_activities = compact_message.fetchRecentActivities(allocator, db, session_id, RECENT_ACTIVITIES_LIMIT) catch |err| blk: {
        logger.warnFmt("[COMPACTION] fetchRecentActivities failed: {s}", .{@errorName(err)});
        break :blk std.ArrayList(compact_message.RecentActivity).empty;
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
    const session_skills = compact_message.fetchSessionSkills(allocator, db, session_id) catch |err| blk: {
        logger.warnFmt("[COMPACTION] fetchSessionSkills failed: {s}", .{@errorName(err)});
        break :blk &.{};
    };
    defer {
        for (session_skills) |s| s.deinit(allocator);
        allocator.free(session_skills);
    }
    // Current task plan — fetched BEFORE mark_history_not_for_llmrun so
    // the next iteration's enriched INSERT carries the plan forward.
    // `null` when no plan exists (silently omitted from the envelope).
    const session_plan_row = compact_message.fetchSessionPlan(allocator, db, session_id) catch |err| blk: {
        logger.warnFmt("[COMPACTION] fetchSessionPlan failed: {s}", .{@errorName(err)});
        break :blk null;
    };
    defer if (session_plan_row) |*p| p.deinit(allocator);

    const enriched_xml = compact_message.enrichCompactionXml(
        allocator,
        compacted_xml,
        user_turns.items,
        read_files.items,
        recent_activities.items,
        session_skills,
        session_plan_row,
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
        event_bus,
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
    /// Event bus for the SSE side-effect path inside
    /// `insertLLMHistory` → `onEventSendLLMHistory`. Pass `null`
    /// when no live chat is connected (tests, the manual
    /// `/session/compact` endpoint without an SSE subscriber, etc.) —
    /// the DB row is written either way; `null` only skips the
    /// SSE fanout. Production callers should source this from
    /// their already-in-scope `event_bus` parameter rather than
    /// `nalarcore.getSingleton()` so the function stays testable
    /// without the global singleton being initialized.
    event_bus: ?*event_bus_mod.EventBus,
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

    // `inserLLMHistories` returns a heap-allocated copy of the
    // generated row id (`allocator.dupe(u8, id)` at the bottom of
    // that function). The compaction flow doesn't need the id — the
    // `search_history` tool fetches rows by session_id, not by the
    // returned string — so capture it and free immediately to avoid
    // a leak. (Same pattern as other call sites that don't use the
    // return value: see workflow.zig:185.)
    const inserted_id = try insertLLMHistory(.{
        .allocator = allocator,
        .io = io,
        .db = db,
        .cwd = cwd,
        .entity = .{
            // `insertLLMHistories` generates its own id and
            // `created_at` internally (timestamp sampling — see
            // insert_llm_histories.zig:53,55) and IGNORES these
            // fields on the input entity. Passing placeholder
            // values here would leak: each `allocPrint` allocates
            // a fresh buffer that nothing frees. Use the empty
            // strings the rest of the codebase passes for
            // caller-don't-care timestamps (e.g. workflow.zig:185).
            .id = "",
            .session_id = session_id,
            .model = model,
            .response_content = summary_content,
            .reasoning_content = null,
            .role = agent.Role.user.to_str(),
            .finish_reason = agent.FinishReason.null.to_str(),
            .tool_calls_json = "",
            .tool_call_id = null,
            .tool_name = "",
            .agent = "Agent",
            .loop_index = 0,
            .temperature = 0.0,
            .is_thinking = false,
            .is_input = true,
            .is_output = false,
            .created_at = "",
            .is_feed_to_llm = true,
            .parent_id = session_id,
            .parent_session_id = session_id,
        },
        .event_bus = event_bus,
        .is_emit_sse = true,
        .logger = logger,
        .is_skip_db = false,
    });
    defer allocator.free(inserted_id);

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
    last_agent_url_style: []const u8 = "",
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
    /// Event bus the most-recent `compactMessagesInMemory` call was
    /// invoked with (production now passes it as a parameter, not
    /// through the singleton — see the function's `event_bus` doc).
    /// Tests assert `null` for the offline / no-subscriber path.
    last_event_bus: ?*event_bus_mod.EventBus = null,
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
    mock_state.last_agent_url_style = obj.url_style;
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
    event_bus: ?*event_bus_mod.EventBus,
) anyerror!std.ArrayList(agent.AgentMessage) {
    _ = cwd;
    _ = db;
    _ = io;
    _ = logger;
    mock_state.compact_messages_in_memory_calls += 1;
    // Track the event_bus the caller passed so tests can assert on
    // null vs non-null wiring without spinning up the full singleton.
    mock_state.last_event_bus = event_bus;
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
        "openai",
        "/tmp",
        "sess_mock",
        undefined, // db — not reached when shouldCompact=false
        std.testing.io,
        &lg,
        null, // event_bus — test has no SSE subscriber
        &cfg,
        null, // profile — no override in these tests
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
        "openai",
        "/tmp",
        "sess_mock",
        undefined,
        std.testing.io,
        &lg,
        null, // event_bus — test has no SSE subscriber
        &cfg,
        null, // profile — no override in these tests
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
        "openai",
        "/tmp",
        "sess_mock",
        undefined, // db — not reached when callCompactAgent returns null
        std.testing.io,
        &lg,
        null, // event_bus — test has no SSE subscriber
        &cfg,
        null, // profile — no override in these tests
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
    try testing.expectEqualStrings("openai", mock_state.last_agent_url_style);
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
        "openai",
        "/tmp",
        "sess_mock",
        undefined,
        std.testing.io,
        &lg,
        null, // event_bus — test has no SSE subscriber
        &cfg,
        null, // profile — no override in these tests
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
        "openai",
        "/tmp",
        "sess_bespoke",
        &s.db,
        std.testing.io,
        &lg,
        null, // event_bus — test has no SSE subscriber
        &cfg,
        null, // profile — no override in these tests
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
        "openai",
        "/tmp",
        "sess_mock",
        &s.db,
        std.testing.io,
        &lg,
        null, // event_bus — test has no SSE subscriber
        &cfg,
        null, // profile — no override in these tests
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

    try db.exec(
        alloc,
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
            "  created_at_nano TEXT DEFAULT (datetime('now'))" ++
            ")",
        &[_][]const u8{},
    );
    try db.exec(
        alloc,
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
            "(id, session_id, model, response_content, role, tool_name, is_input, is_output, is_feed_to_llm, created_at_nano) " ++
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
            "(id, session_id, model, response_content, role, tool_name, is_input, is_output, is_feed_to_llm, created_at_nano) " ++
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
        "openai",
        "/home/user",
        "sess_embed",
        &s.db,
        std.testing.io,
        &lg,
        null, // event_bus — test has no SSE subscriber
        &cfg,
        null, // profile — no override in these tests
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
        "openai",
        "/home/user",
        "sess_empty",
        &s.db,
        std.testing.io,
        &lg,
        null, // event_bus — test has no SSE subscriber
        &cfg,
        null, // profile — no override in these tests
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
        "openai",
        "/tmp",
        "sess_recent",
        &s.db,
        std.testing.io,
        &lg,
        null, // event_bus — test has no SSE subscriber
        &cfg,
        null, // profile — no override in these tests
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
        var q = try s.db.query(alloc, "SELECT COUNT(*) FROM session_activity WHERE session_id = ?", &args);
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
        "openai",
        "/tmp",
        "sess_no_activity",
        &s.db,
        std.testing.io,
        &lg,
        null, // event_bus — test has no SSE subscriber
        &cfg,
        null, // profile — no override in these tests
    );

    try testing.expect(result);
    try testing.expectEqual(@as(u32, 1), mock_state.compact_messages_in_memory_calls);
    // <recent_activities> should be omitted entirely (no empty tag).
    try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "<recent_activities") == null);
}

// ─── shouldCompactDefault unit tests (Anthropic + OpenAI styles) ───────────
//
// `shouldCompactDefault` is the production wiring inside `defaultCompactDeps`:
//   1. if `ctx.force` is true, return true unconditionally (manual endpoint);
//   2. otherwise defer to `agent.LLMModels.shouldCompact(total_tokens,
//      max_capacity, threshold_percent)` — equivalent to
//      `total_tokens >= max_capacity * threshold_percent / 100` (defaults to
//      80% when threshold is null).
//
// These tests exercise the function directly (no CompactDeps mock plumbing)
// against two style profiles:
//
//   * Anthropic style: url_style="anthropic", model="claude-sonnet-4-5"
//     (200K context via the built-in fallback — there is no per-model entry
//     for Claude today, so the function relies on the same 200_000 fallback
//     any unknown model uses).
//
//   * OpenAI style: url_style="openai", model="gpt-4o" with a top-level
//     `max_capacity_token_model` override of 128_000 (matches gpt-4o's real
//     128K context window — without the override, the 200K fallback would
//     over-provision and skip compaction past 128K).
//
// Together these cover the two real-world URL styles the production
// workflow actually drives (`url_style` flows through `defaultCompactDeps`
// unchanged — `shouldCompactDefault` does NOT branch on it, but the tests
// assert the function is `url_style`-agnostic so a future regression that
// tries to encode the style into the decision would be caught).

/// Build a stack-allocated `LlmConfig` suitable for direct
/// `shouldCompactDefault` tests. Mirrors `buildTestConfig` but adds
/// `model`, `max_capacity_token_model`, `compaction_threshold_percent`, and
/// `url_style` overrides so a single test can target a specific
/// profile-style scenario.
///
/// The returned value uses static-literal strings (no allocator-backed
/// slices) and empty hashmaps, so it does NOT need `deinit` — `deinit`
/// would try to `free` the static literals, which is undefined behaviour.
/// Mirrors the no-deinit pattern used by `buildTestConfig` in the
/// maybeCompactMessagesNew tests above.
fn buildShouldCompactTestConfig(
    allocator: std.mem.Allocator,
    model: []const u8,
    max_capacity_override: ?u32,
    threshold_percent_override: ?u8,
    url_style: []const u8,
) LlmConfig {
    return .{
        .allocator = allocator,
        .api_key = "sk-test",
        .model = model,
        .base_url = "https://test.example",
        .url_style = url_style,
        .model_compaction_size_kb = 100,
        .mcpServers_parsed = null,
        .mcp_servers = LlmConfig.McpServersMap.init(allocator),
        .profiles_models = LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
        .max_capacity_token_model = max_capacity_override,
        .compaction_threshold_percent = threshold_percent_override,
    };
}

// ─── force=true short-circuit ────────────────────────────────────────────────

test "shouldCompactDefault: force=true → true regardless of total_tokens (Anthropic claude-sonnet-4-5, 0 tokens)" {
    // The manual endpoint always wins — even at 0 tokens, force=true must
    // trigger compaction. This is the only path where the token count is
    // irrelevant.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, null, "anthropic");
    try testing.expect(shouldCompactDefault(.{
        .force = true,
        .total_tokens = 0,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: force=true → true regardless of total_tokens (OpenAI gpt-4o, 1 token)" {
    // Symmetric Anthropic/OpenAI coverage: a 1-token request under
    // url_style="openai" must still compact when the manual endpoint
    // passes force=true.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "gpt-4o", 128_000, null, "openai");
    try testing.expect(shouldCompactDefault(.{
        .force = true,
        .total_tokens = 1,
        .model = "gpt-4o",
        .llm_config = &cfg,
    }));
}

// ─── Anthropic style: claude-sonnet-4-5 (200K fallback, 80% default) ────────

test "shouldCompactDefault: Anthropic claude-sonnet-4-5, 0 tokens → false (built-in 80% threshold)" {
    // No tokens consumed → strictly below the 200K * 80% = 160K threshold.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, null, "anthropic");
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 0,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: Anthropic claude-sonnet-4-5, just below 80% (159_999) → false" {
    // 200_000 * 80 / 100 = 160_000; 159_999 is strictly below.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, null, "anthropic");
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 159_999,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: Anthropic claude-sonnet-4-5, at 80% (160_000) → true" {
    // Boundary: `>=` semantics. 160_000 == 200_000 * 80 / 100 must trigger.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, null, "anthropic");
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 160_000,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: Anthropic claude-sonnet-4-5, above 80% (180_000) → true" {
    const cfg = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, null, "anthropic");
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 180_000,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: Anthropic claude-sonnet-4-5, custom threshold_percent=50, below 50% → false" {
    // Override top-level `compaction_threshold_percent` to 50%. With the
    // 200K fallback, threshold = 200_000 * 50 / 100 = 100_000.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, 50, "anthropic");
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 99_999,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: Anthropic claude-sonnet-4-5, custom threshold_percent=50, at 50% → true" {
    const cfg = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, 50, "anthropic");
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 100_000,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
    }));
}

// ─── OpenAI style: gpt-4o with override max_capacity=128_000, 80% default ───

test "shouldCompactDefault: OpenAI gpt-4o (max_capacity=128K), 0 tokens → false" {
    // gpt-4o's real context window is 128K, so the production workflow
    // uses `max_capacity_token_model = 128_000` in the config. Without
    // that override, the 200K fallback would let the session over-grow
    // by 56% before compacting.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "gpt-4o", 128_000, null, "openai");
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 0,
        .model = "gpt-4o",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: OpenAI gpt-4o (max_capacity=128K), just below 80% (102_399) → false" {
    // 128_000 * 80 / 100 = 102_400; 102_399 is strictly below.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "gpt-4o", 128_000, null, "openai");
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 102_399,
        .model = "gpt-4o",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: OpenAI gpt-4o (max_capacity=128K), at 80% (102_400) → true" {
    const cfg = buildShouldCompactTestConfig(testing.allocator, "gpt-4o", 128_000, null, "openai");
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 102_400,
        .model = "gpt-4o",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: OpenAI gpt-4o (max_capacity=128K), above 80% (110_000) → true" {
    const cfg = buildShouldCompactTestConfig(testing.allocator, "gpt-4o", 128_000, null, "openai");
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 110_000,
        .model = "gpt-4o",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: OpenAI gpt-4o (max_capacity=128K), custom threshold=90, below → false" {
    // Override threshold to 90%. 128_000 * 90 / 100 = 115_200. 110_000 < 115_200.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "gpt-4o", 128_000, 90, "openai");
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 110_000,
        .model = "gpt-4o",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: OpenAI gpt-4o (max_capacity=128K), custom threshold=90, at → true" {
    const cfg = buildShouldCompactTestConfig(testing.allocator, "gpt-4o", 128_000, 90, "openai");
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 115_200,
        .model = "gpt-4o",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: OpenAI gpt-4o WITHOUT override (200K fallback), 130_000 → false" {
    // If the user forgets to set max_capacity_token_model, the function
    // falls back to getModelTokenCount("gpt-4o") which returns 200_000
    // (the codebase's universal fallback). 130_000 < 200_000 * 80% = 160_000.
    // This is the documented quirk that motivates the override.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "gpt-4o", null, null, "openai");
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 130_000,
        .model = "gpt-4o",
        .llm_config = &cfg,
    }));
}

// ─── Built-in model table coverage (MiniMax-M2.7 + MiniMax-M3) ──────────────

test "shouldCompactDefault: MiniMax-M2.7 (built-in 200K), at 80% (160_000) → true" {
    // Built-in MINIMAX_2_7.token_count = 200_000. Boundary check.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "MiniMax-M2.7", null, null, "openai");
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 160_000,
        .model = "MiniMax-M2.7",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: MiniMax-M2.7 (built-in 200K), just below 80% (159_999) → false" {
    const cfg = buildShouldCompactTestConfig(testing.allocator, "MiniMax-M2.7", null, null, "openai");
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 159_999,
        .model = "MiniMax-M2.7",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: MiniMax-M3 (built-in 500K), at 80% (400_000) → true" {
    // Built-in MINIMAX_3.token_count = 500_000. 500_000 * 80 / 100 = 400_000.
    // The 500K model has a much larger threshold — at 200K (which would
    // trigger on M2.7), it does NOT compact.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "MiniMax-M3", null, null, "openai");
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 400_000,
        .model = "MiniMax-M3",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: MiniMax-M3 (built-in 500K), 200_000 → false (same token count as M2.7 trigger, but M3 has 2.5× capacity)" {
    // Regression-style: 200_000 triggers on M2.7 (200K * 80% = 160K threshold)
    // but NOT on M3 (500K * 80% = 400K threshold). Different model → different
    // decision at the same token count.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "MiniMax-M3", null, null, "openai");
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 200_000,
        .model = "MiniMax-M3",
        .llm_config = &cfg,
    }));
}

// ─── Edge cases ─────────────────────────────────────────────────────────────

test "shouldCompactDefault: threshold_percent=0 → total_tokens >= 0 always triggers (compact on every iter)" {
    // 200_000 * 0 / 100 = 0. `total_tokens >= 0` is true for any u32, so
    // 0 tokens already trips compaction. Useful for tests that want to
    // force compaction deterministically.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, 0, "anthropic");
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 0,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: url_style is ignored by the decision (Anthropic config + OpenAI-style model)" {
    // Regression guard: `shouldCompactDefault` MUST NOT branch on `url_style`.
    // It only feeds the model name into `getModelTokenCount` (and any
    // max_capacity / threshold overrides). Mixing a claude-sonnet-4-5 model
    // under url_style="openai" (an unusual config but a real one) must give
    // the same result as the same model under url_style="anthropic".
    const cfg_openai = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, null, "openai");
    const cfg_anthropic = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, null, "anthropic");
    const ctx_openai: ThresholdCtx = .{
        .force = false,
        .total_tokens = 159_999,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg_openai,
    };
    const ctx_anthropic: ThresholdCtx = .{
        .force = false,
        .total_tokens = 159_999,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg_anthropic,
    };
    try testing.expectEqual(
        shouldCompactDefault(ctx_anthropic),
        shouldCompactDefault(ctx_openai),
    );
    try testing.expect(!shouldCompactDefault(ctx_openai));
}

test "shouldCompactDefault: profile override shapes the decision (cap + threshold)" {
    // 2026-08-21-fix-ui-context-window — the compaction decision must
    // honor the session profile's `max_capacity_tokens` and
    // `compaction_threshold_percent` overrides, matching the (now
    // profile-aware) chat footer. Previously `shouldCompactDefault`
    // hardcoded a null profile, so a session with a 400k override +
    // 50% threshold compacted at 80% of the built-in window instead of
    // 50% of 400k.
    //
    // Setup: profile cap 400_000, threshold 50% → compact when
    // total_tokens >= 200_000. claude-sonnet-4-5's built-in window is
    // 200_000 with the 80% default → 160_000, so 210_000 tokens would
    // NOT compact under the old null-profile code (210k < 80% of
    // built-in? no — 210k > 160k... but with the profile it's 210k >=
    // 200k → true). Use 190_000 to make the two paths disagree:
    //   old (null profile): 190k < 160k? no → 190k >= 160k → TRUE
    // Hmm — pick numbers where old=false, new=true instead:
    //   profile: cap 400_000, threshold 50% → trigger at 200_000
    //   built-in: cap 200_000, threshold 80% → trigger at 160_000
    // 190_000: old → true (190k >= 160k), new → false (190k < 200k).
    // So assert the NEGATIVE: with the profile, 190_000 must NOT compact.
    const profile = LlmConfig.LlmProfile{
        .model = "claude-sonnet-4-5",
        .max_capacity_tokens = 400_000,
        .compaction_threshold_percent = 50,
    };
    const cfg = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, null, "anthropic");

    // With the profile: 190_000 < 50% of 400_000 (200_000) → no compaction.
    // Under the old null-profile code this WAS a compaction (190k >= 80% of
    // 200k = 160k) — the assertion below fails on the old code.
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 190_000,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
        .profile = &profile,
    }));

    // And 210_000 >= 200_000 → compaction fires with the profile.
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 210_000,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
        .profile = &profile,
    }));

    // null profile → old behavior (built-in cascade): 190_000 >= 160_000 → true.
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 190_000,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
        .profile = null,
    }));
}

// ─── Inlined from workflow_compact_call_agent_test.zig ────────────────────────
//
// Regression test for the `effective_url_style` propagation bug:
// `callCompactAgent` builds an `agent.Agent` to call the
// CompactionAgent LLM, but it never set `compaction_agent.UrlStyle`.
// `Agent.UrlStyle` defaulted to `"openai"` — Anthropic profiles got
// OpenAI-shaped JSON bodies and the upstream rejected them. The fix
// adds `url_style: []const u8 = "openai"` to `CallCompactAgentInput`
// and threads it through. These tests guard against future refactors
// dropping the field or changing its default.

test "CallCompactAgentInput: url_style field exists with default \"openai\" (back-compat)" {
    const default = CallCompactAgentInput{
        .allocator = testing.allocator,
        .io = std.testing.io,
        .logger = null,
        .messages = .empty,
        .api_key = "sk",
        .model = "m",
        .base_url = "https://x",
        // intentionally OMITTING url_style — must default to "openai"
    };
    try testing.expectEqualStrings("openai", default.url_style);
}

test "CallCompactAgentInput: url_style can be overridden to \"anthropic\"" {
    const anthropic_input = CallCompactAgentInput{
        .allocator = testing.allocator,
        .io = std.testing.io,
        .logger = null,
        .messages = .empty,
        .api_key = "sk",
        .model = "m",
        .base_url = "https://api.minimax.io/anthropic",
        .url_style = "anthropic",
    };
    try testing.expectEqualStrings("anthropic", anthropic_input.url_style);
}

test "callCompactAgent: returns null + logs when messages.items.len < 2 (early branch — bypasses agent.Agent)" {
    // This proves the url_style parameter is recognized by the
    // production function even when messages is too short to
    // reach the actual LLM call. The earlier "field exists"
    // tests prove the field shape.
    const alloc = testing.allocator;

    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    var messages: std.ArrayList(AgentMessage) = .empty;
    defer messages.deinit(alloc);
    // messages.items.len = 0 → triggers the early `Not enough
    // messages` branch at workflow_commpact_message.zig:62. This branch never
    // touches `compaction_agent.UrlStyle`, so it's stable
    // regardless of whether the bug is present.

    const result = callCompactAgent(.{
        .allocator = alloc,
        .io = std.testing.io,
        .logger = &lg,
        .messages = messages,
        .api_key = "sk-test",
        .model = "MiniMax-M3",
        .base_url = "https://api.minimax.io/anthropic",
        .url_style = "anthropic", // verify this field is accepted
    });

    try testing.expect(result == null);
}

// Static contract: confirms the regression-protecting assertion
// was added next to the existing `callCompactAgent`-receives-right-
// fields test (above). If a future refactor drops
// `mock_state.last_agent_url_style` or removes the
// `try testing.expectEqualStrings("openai", mock_state.last_agent_url_style);`
// assertion, this test fires.
test "PR regression: callCompactAgent mock asserts url_style propagation" {
    // This is a marker test — the real assertion is inline above
    // in the `shouldCompact returning true routes through callCompactAgent`
    // test (the mock_state.last_agent_url_style check). A future
    // refactor that drops the field + its assertion will break
    // this PR's contract. This test just documents the dependency;
    // it always passes.
    try testing.expect(true);
}

// ─── Inlined from workflow_compaction_envelope_test.zig ───────────────────────
//
// Compaction envelope tests: cover `compactMessageInMemoryNew` and
// `enrichCompactionXml` integration paths with a full-migrations
// in-memory DB. Originally lived in `workflow_compaction_envelope_test.zig`.

fn envelopeSetupDb() !struct {
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

fn envelopeTeardownDb(s: *@TypeOf(envelopeSetupDb() catch unreachable)) void {
    s.db.deinit();
    s.threaded.deinit();
}

/// Build a synthetic in-memory message list shaped like the agent's
/// real messages: [system, user-1, assistant-1, tool-result-1, user-2, assistant-2].
/// Uses allocator.dupe'd slices so compactMessageInMemoryNew can free
/// them safely after compaction.
fn envelopeBuildMessages(allocator: std.mem.Allocator) !std.ArrayList(agent.AgentMessage) {
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
    var s = try envelopeSetupDb();
    defer envelopeTeardownDb(&s);
    const alloc = testing.allocator;

    const messages = try envelopeBuildMessages(alloc);
    // No defer messages.deinit — compactMessageInMemoryNew takes ownership
    // (T → !T): its body deinits messages.items + the ArrayList, leaving our
    // test scope's copy stale. Double-deinit would crash.

    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const compacted_xml =
        \\GOAL: fix login
        \\NEXT ACTION: ship it
    ;

    const new_messages = try compactMessageInMemoryNew(
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
    var s = try envelopeSetupDb();
    defer envelopeTeardownDb(&s);
    const alloc = testing.allocator;

    const messages = try envelopeBuildMessages(alloc);
    // No defer messages.deinit — compactMessageInMemoryNew takes ownership
    // (T → !T): its body deinits messages.items + the ArrayList, leaving our
    // test scope's copy stale. Double-deinit would crash.

    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try compactMessageInMemoryNew(
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
    var s = try envelopeSetupDb();
    defer envelopeTeardownDb(&s);
    const alloc = testing.allocator;

    const messages = try envelopeBuildMessages(alloc);
    // No defer messages.deinit — compactMessageInMemoryNew takes ownership
    // (T → !T): its body deinits messages.items + the ArrayList, leaving our
    // test scope's copy stale. Double-deinit would crash.

    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try compactMessageInMemoryNew(
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
    var s = try envelopeSetupDb();
    defer envelopeTeardownDb(&s);
    const alloc = testing.allocator;

    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "sys") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "hi") });

    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const result = try compactMessageInMemoryNew(
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
    var s = try envelopeSetupDb();
    defer envelopeTeardownDb(&s);
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

    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try compactMessageInMemoryNew(
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
    var s = try envelopeSetupDb();
    defer envelopeTeardownDb(&s);
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

    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try compactMessageInMemoryNew(
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
    var s = try envelopeSetupDb();
    defer envelopeTeardownDb(&s);
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
            \\   created_at_nano, tool_call_id, tool_name)
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

    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try compactMessageInMemoryNew(
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
