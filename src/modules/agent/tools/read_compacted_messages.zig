const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const llm_history = nalarcore.llm_history;
const helpers = nalarcore.helpers;
const xmlEscape = helpers.xml_escape;

/// Input for read_compacted_messages. The LLM supplies this from the
/// <message_index> section of its current <compact_messages> summary.
///
/// Why both `mode` AND `message_ids`: the LLM often wants to "skim"
/// the index first (1 tool call returns 20 entries, ~500 tokens), then
/// fetch full content for 2-3 specific ids. Forcing a second round-trip
/// would add latency; collapsing the two modes into one tool keeps the
/// surface area small (one tool, one prompt line).
pub const ReadCompactedMessagesInput = struct {
    /// "index" (default) returns the <message_index> section only.
    /// "full" returns <message_index> + <content> bodies for the
    /// requested message_ids. The two modes produce overlapping but
    /// not identical output — pick the one that matches your need.
    mode: []const u8 = "index",
    /// Comma-separated message ids from the <message_index>. Required
    /// when mode="full". Ignored when mode="index". Example:
    ///   "h_123,h_456"
    message_ids: []const u8 = "",
    /// When non-empty, filter to messages with this exact role.
    /// Useful for "show me only the user's questions" queries.
    role: []const u8 = "",
    /// ISO 8601 / YYYY-MM-DD HH:MM:SS lower bound on created_at.
    since: []const u8 = "",
    /// Upper bound. Both bounds are inclusive and lex-sort = chrono-sort.
    until: []const u8 = "",
    /// Max rows to return. Defaults to 20 (matches the safe default in
    /// the description); capped at 200 by execute_read_compacted_messages
    /// to prevent token-budget blowups.
    limit: u32 = 20,
};

/// Tool definition for read_compacted_messages.
///
/// CRITICAL for the long-context story: this is the ONLY way the agent
/// can read the messages dropped by compaction. Without it, every
/// compaction is a permanent loss of detail (the summary is lossy by
/// design). The description must be precise enough that the LLM uses
/// the tool correctly: index mode first, then full mode with explicit ids.
pub const read_compacted_messages_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "read_compacted_messages",
        .description =
            \\Read messages that were dropped from the conversation by compaction. Compaction marks old messages as is_feed_to_llm=0 and replaces them with a <compact_messages> summary. This tool is the ONLY way to recover the full content of those dropped messages.
            \\
            \\TWO MODES:
            \\- mode="index" (default): returns a <message_index> with id, role, created_at, and a 100-char preview per message. Use this first to see what's available. Cheap.
            \\- mode="full": also returns the full <content> bodies of the messages whose ids you list in `message_ids`. Use this when you need the actual text — e.g. to re-read a tool result, a user question, or an assistant response.
            \\
            \\The id values come from the <message_index> section of the current <compact_messages> summary in your context. The summary is regenerated on every compaction, so the ids are stable for the lifetime of the session.
            \\
            \\Filters (optional, work in both modes):
            \\- role: "user", "assistant", or "tool" — exact match.
            \\- since / until: YYYY-MM-DD HH:MM:SS timestamps (inclusive).
            \\- limit: max rows (default 20, max 200).
            \\
            \\Example (index mode):
            \\  {"mode": "index", "role": "user"}
            \\Example (full mode, fetch 2 specific messages):
            \\  {"mode": "full", "message_ids": "h_1781,h_1782"}
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "mode",
                    .type = "string",
                    .description = "Either 'index' (default, returns only metadata + preview) or 'full' (also returns full <content> bodies for the messages listed in message_ids).",
                },
                .{
                    .name = "message_ids",
                    .type = "string",
                    .description = "Comma-separated message ids from the <message_index>. Required when mode='full'. Example: 'h_123,h_456'. Ignored when mode='index'.",
                },
                .{
                    .name = "role",
                    .type = "string",
                    .description = "Optional exact-match role filter: 'user', 'assistant', or 'tool'.",
                },
                .{
                    .name = "since",
                    .type = "string",
                    .description = "Optional lower bound on created_at (inclusive). YYYY-MM-DD HH:MM:SS format.",
                },
                .{
                    .name = "until",
                    .type = "string",
                    .description = "Optional upper bound on created_at (inclusive).",
                },
                .{
                    .name = "limit",
                    .type = "number",
                    .description = "Max rows to return. Default 20, max 200.",
                },
            },
            .required = &.{},
        },
    },
};

/// Parse `message_ids_csv` ("h_123,h_456") into a `[]const []const u8`.
/// Returns an empty slice for empty input. Caller owns the returned
/// strings + the outer slice; free with the helpers in
/// `std.ArrayList([]const u8)`.
fn parseMessageIds(allocator: std.mem.Allocator, csv: []const u8) ![]const []const u8 {
    if (csv.len == 0) return &.{};
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }
    var iter = std.mem.splitScalar(u8, csv, ',');
    while (iter.next()) |id| {
        const trimmed = std.mem.trim(u8, id, " \t");
        if (trimmed.len > 0) {
            try ids.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }
    return try ids.toOwnedSlice(allocator);
}

/// Execute read_compacted_messages. Returns an XML string for the LLM.
///
/// Output shape:
///   <read_compacted_messages mode="index">
///     <session_id>...</session_id>
///     <count>5</count>
///     <message_index>
///       <entry>
///         <id>h_123</id>
///         <role>user</role>
///         <created_at>2025-01-01 00:00:00</created_at>
///         <preview>Fix the login bug</preview>     <-- 100-char preview, always
///         <tool_call_id>tc_1</tool_call_id>         <-- only for tool role
///         <tool_name>bash</tool_name>              <-- only for tool role
///         <content>Full message body here</content> <-- ONLY when mode=full AND id in message_ids
///       </entry>
///       ...
///     </message_index>
///   </read_compacted_messages>
///
/// On a hard error (e.g. malformed mode), returns:
///   <read_compacted_messages><error>...</error></read_compacted_messages>
pub fn execute_read_compacted_messages(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    input: ReadCompactedMessagesInput,
) ![]const u8 {
    _ = io; // Reserved for future streaming; not used in v1.

    // Validate mode.
    const is_full_mode = blk: {
        if (std.mem.eql(u8, input.mode, "index")) break :blk false;
        if (std.mem.eql(u8, input.mode, "full")) break :blk true;
        // Default to index for unknown / empty mode.
        if (input.mode.len == 0) break :blk false;
        const msg = try std.fmt.allocPrint(allocator,
            "Invalid mode '{s}'. Must be 'index' or 'full'.",
            .{input.mode});
        defer allocator.free(msg);
        const err_escaped = try xmlEscape(allocator, msg);
        defer allocator.free(err_escaped);
        return std.fmt.allocPrint(allocator,
            "<read_compacted_messages><error>{s}</error></read_compacted_messages>",
            .{err_escaped});
    };

    // Parse and validate.
    const parsed_ids = try parseMessageIds(allocator, input.message_ids);
    defer {
        for (parsed_ids) |id| allocator.free(id);
        allocator.free(parsed_ids);
    }
    if (is_full_mode and parsed_ids.len == 0) {
        const msg = "mode='full' requires non-empty message_ids.";
        const err_escaped = try xmlEscape(allocator, msg);
        defer allocator.free(err_escaped);
        return std.fmt.allocPrint(allocator,
            "<read_compacted_messages><error>{s}</error></read_compacted_messages>",
            .{err_escaped});
    }

    const effective_limit = @min(input.limit, 200);

    const opts = llm_history.CompactedMessagesOptions{
        .message_ids = if (is_full_mode) parsed_ids else null,
        .role = if (input.role.len > 0) input.role else null,
        .since = if (input.since.len > 0) input.since else null,
        .until = if (input.until.len > 0) input.until else null,
        .limit = effective_limit,
    };

    const messages = llm_history.getCompactedMessages(allocator, db, session_id, opts) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Database query failed: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        const err_escaped = try xmlEscape(allocator, msg);
        defer allocator.free(err_escaped);
        return std.fmt.allocPrint(allocator,
            "<read_compacted_messages><error>{s}</error></read_compacted_messages>",
            .{err_escaped});
    };
    defer {
        for (messages) |m| {
            var copy = m;
            copy.deinit(allocator);
        }
        allocator.free(messages);
    }

    // Build a quick lookup set from parsed_ids (only used in full mode).
    var full_ids_set: ?std.StringHashMapUnmanaged(void) = if (is_full_mode)
        .empty
    else
        null;
    defer if (full_ids_set) |*s| s.deinit(allocator);
    if (is_full_mode) {
        for (parsed_ids) |id| try full_ids_set.?.put(allocator, id, {});
    }

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.print(allocator, "<read_compacted_messages mode=\"{s}\">\n", .{input.mode});
    try xml.print(allocator, "  <session_id>{s}</session_id>\n", .{session_id});
    try xml.print(allocator, "  <count>{d}</count>\n", .{messages.len});
    try xml.appendSlice(allocator, "  <message_index>\n");

    for (messages) |m| {
        const id_escaped = try xmlEscape(allocator, m.id);
        defer allocator.free(id_escaped);
        const role_escaped = try xmlEscape(allocator, m.role);
        defer allocator.free(role_escaped);
        const preview_src: []const u8 = if (m.content.len > 100) m.content[0..100] else m.content;
        const preview_escaped = try xmlEscape(allocator, preview_src);
        defer allocator.free(preview_escaped);

        try xml.appendSlice(allocator, "    <entry>\n");
        try xml.print(allocator, "      <id>{s}</id>\n", .{id_escaped});
        try xml.print(allocator, "      <role>{s}</role>\n", .{role_escaped});
        if (m.created_at.len > 0) {
            const ca_escaped = try xmlEscape(allocator, m.created_at);
            defer allocator.free(ca_escaped);
            try xml.print(allocator, "      <created_at>{s}</created_at>\n", .{ca_escaped});
        }
        try xml.print(allocator, "      <preview>{s}</preview>\n", .{preview_escaped});

        if (std.mem.eql(u8, m.role, "tool")) {
            if (m.tool_call_id) |tcid| {
                const tcid_escaped = try xmlEscape(allocator, tcid);
                defer allocator.free(tcid_escaped);
                try xml.print(allocator, "      <tool_call_id>{s}</tool_call_id>\n", .{tcid_escaped});
            }
            if (m.tool_name) |tn| {
                const tn_escaped = try xmlEscape(allocator, tn);
                defer allocator.free(tn_escaped);
                try xml.print(allocator, "      <tool_name>{s}</tool_name>\n", .{tn_escaped});
            }
        }

        // Full-mode content inclusion: only when this id is in the parsed_ids set.
        if (is_full_mode and full_ids_set != null and full_ids_set.?.contains(m.id)) {
            const content_escaped = try xmlEscape(allocator, m.content);
            defer allocator.free(content_escaped);
            try xml.print(allocator, "      <content>{s}</content>\n", .{content_escaped});
        }

        try xml.appendSlice(allocator, "    </entry>\n");
    }

    try xml.appendSlice(allocator, "  </message_index>\n");
    try xml.appendSlice(allocator, "</read_compacted_messages>\n");

    return try xml.toOwnedSlice(allocator);
}

/// `toXmlSuccess` / `toXmlError` are the standardized envelope helpers
/// used by the tool_registry.execX wrapper. They wrap the inner XML
/// in `<tool>...</tool>` so handle_tool sees the consistent envelope.
pub fn toXmlSuccess(allocator: std.mem.Allocator, inner: []const u8) ![]u8 {
    return allocator.dupe(u8, inner);
}

pub fn toXmlError(allocator: std.mem.Allocator, err_msg: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, err_msg);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        "<read_compacted_messages><error>{s}</error></read_compacted_messages>",
        .{escaped});
}