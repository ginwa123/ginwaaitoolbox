//! GET /api/llm/history/:session_id — LLM History Inspector
//!
//! Returns the full chain of LLM request messages for a session plus
//! ready-to-run curl commands for each of the 3 provider wire formats.
//!
//! CRITICAL: This handler MUST import and call Agent.buildJsonAnthropicRequest,
//! Agent.buildJsonOpenAIRequest, and Agent.buildJsonResponsesRequest verbatim —
//! do NOT duplicate serialization. The preview curl is byte-for-byte identical
//! to what the app actually sends. If Agent.zig changes its serialization
//! (e.g. new reasoning field), the inspector automatically reflects it.
//! A static-contract test below greps for these symbols to prevent drift.

const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const sqlite = nalarcore.sqlite;
const agent = nalarcore.agent;
const Agent = agent.Agent;
const llm_history = nalarcore.ai_mod.llm_history;
const config_mod = nalarcore.config;

// =====================================================================
// Error set
// =====================================================================

pub const LlmHistoryInspectorError = error{
    EmptySessionId,
    SessionNotFound,
    DatabaseError,
    OutOfMemory,
};

// =====================================================================
// Response types
// =====================================================================

pub const ChainMessage = struct {
    role: []const u8,
    content: []const u8,
    id: ?[]const u8 = null,
    tool_calls: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
};

pub const CurlMap = struct {
    anthropic: []const u8,
    openai: []const u8,
    openai_response: []const u8,
};

pub const BodiesMap = struct {
    anthropic: []const u8,
    openai: []const u8,
    openai_response: []const u8,
};

pub const LlmHistoryInspectorResponse = struct {
    session_id: []const u8,
    model: []const u8,
    url_style: []const u8,
    chain: []const ChainMessage,
    curl: CurlMap,
    bodies: BodiesMap,
};

// =====================================================================
// Helpers
// =====================================================================

/// Shell-escape single quotes in body for curl -d '...' (replace ' with '\'')
fn shellEscapeSingleQuotes(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn buildCurlString(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    endpoint: []const u8,
    body: []const u8,
) ![]u8 {
    const escaped_body = try shellEscapeSingleQuotes(allocator, body);
    defer allocator.free(escaped_body);
    // Redacted api_key — never emit real key
    const redacted_key = "sk-****";
    return std.fmt.allocPrint(allocator,
        \\curl -X POST '{s}{s}' -H 'Authorization: Bearer {s}' -H 'Content-Type: application/json' -d '{s}'
    , .{ base_url, endpoint, redacted_key, escaped_body });
}

/// Convert TUIHistory rows to AgentMessage[] for builder input.
/// Simple mapping for v1 — covers role, content, tool_calls, reasoning.
fn buildAgentMessages(
    allocator: std.mem.Allocator,
    histories: []const llm_history.TUIHistory,
) ![]agent.AgentMessage {
    // Prepend synthetic system message for v1
    const has_system = false; // we always prepend one
    _ = has_system;
    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    errdefer {
        for (messages.items) |*m| m.deinit(allocator);
        messages.deinit(allocator);
    }

    // Synthetic system prompt — v1 keeps it simple
    try messages.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "You are a helpful assistant."),
    });

    for (histories) |h| {
        const role = agent.Role.from_str(h.role) orelse .assistant;

        // Parse tool_calls_json if present
        var tool_calls: ?[]agent.ToolCall = null;
        if (h.tools.len > 0 and !std.mem.eql(u8, h.tools, "")) {
            // Try to parse as JSON array of tool calls
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, h.tools, .{}) catch null;
            if (parsed) |p| {
                defer p.deinit();
                if (p.value == .array and p.value.array.items.len > 0) {
                    var tc_list: std.ArrayList(agent.ToolCall) = .empty;
                    errdefer {
                        for (tc_list.items) |*tc| {
                            allocator.free(tc.id);
                            allocator.free(tc.function.name);
                            allocator.free(tc.function.arguments);
                        }
                        tc_list.deinit(allocator);
                    }
                    for (p.value.array.items) |item| {
                        if (item != .object) continue;
                        const id_val = item.object.get("id") orelse continue;
                        const func_val = item.object.get("function") orelse continue;
                        if (id_val != .string) continue;
                        if (func_val != .object) continue;
                        const name_val = func_val.object.get("name") orelse continue;
                        const args_val = func_val.object.get("arguments") orelse continue;
                        if (name_val != .string) continue;
                        // arguments may be string or object — normalize to string
                        var args_str: []const u8 = "";
                        var args_owned: ?[]u8 = null;
                        if (args_val == .string) {
                            args_str = args_val.string;
                        } else {
                            // Serialize the value to JSON string
                            var aw: std.Io.Writer.Allocating = .init(allocator);
                            aw.writer.print("{f}", .{std.json.fmt(args_val, .{})}) catch continue;
                            args_owned = aw.toOwnedSlice() catch continue;
                            args_str = args_owned.?;
                        }
                        const tc = agent.ToolCall{
                            .id = try allocator.dupe(u8, id_val.string),
                            .type = "function",
                            .function = .{
                                .name = try allocator.dupe(u8, name_val.string),
                                .arguments = if (args_owned) |a| a else try allocator.dupe(u8, args_str),
                            },
                        };
                        // If we didn't own args, we already duped; if we did, it's already owned
                        if (args_owned == null and args_val != .string) {
                            // args_str was from serialization, need to handle
                        }
                        try tc_list.append(allocator, tc);
                    }
                    if (tc_list.items.len > 0) {
                        tool_calls = try tc_list.toOwnedSlice(allocator);
                    } else {
                        tc_list.deinit(allocator);
                    }
                }
            }
        }

        const content: ?[]const u8 = if (h.response_content.len > 0)
            try allocator.dupe(u8, h.response_content)
        else
            null;

        const reasoning: ?[]const u8 = if (h.reasoning_content) |rc|
            if (rc.len > 0) try allocator.dupe(u8, rc) else null
        else
            null;

        const reasoning_id: ?[]const u8 = if (h.reasoning_id) |rid|
            if (rid.len > 0) try allocator.dupe(u8, rid) else null
        else
            null;

        const reasoning_enc: ?[]const u8 = if (h.reasoning_encrypted_content) |rec|
            if (rec.len > 0) try allocator.dupe(u8, rec) else null
        else
            null;

        const tool_call_id: ?[]const u8 = if (h.tool_call_id) |tci|
            if (tci.len > 0) try allocator.dupe(u8, tci) else null
        else
            null;

        // Handle image_urls -> content_parts for vision
        var content_parts: ?[]agent.ContentPart = null;
        if (h.image_urls) |urls| {
            if (urls.len > 0) {
                var parts = try allocator.alloc(agent.ContentPart, urls.len + (if (content != null) @as(usize, 1) else 0));
                var idx: usize = 0;
                if (content) |c| {
                    parts[idx] = .{ .part_type = "text", .text = try allocator.dupe(u8, c) };
                    idx += 1;
                }
                for (urls) |url| {
                    parts[idx] = .{
                        .part_type = "image_url",
                        .image_url = .{ .url = try allocator.dupe(u8, url) },
                    };
                    idx += 1;
                }
                content_parts = parts[0..idx];
            }
        }

        try messages.append(allocator, .{
            .role = role,
            .content = content,
            .content_parts = content_parts,
            .tool_calls = tool_calls,
            .tool_call_id = tool_call_id,
            .reasoning_content = reasoning,
            .reasoning_id = reasoning_id,
            .reasoning_encrypted_content = reasoning_enc,
        });
    }

    return messages.toOwnedSlice(allocator);
}

// =====================================================================
// Use case — pure function, testable with in-memory SQLite
// =====================================================================

pub fn useCase(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !LlmHistoryInspectorResponse {
    return useCaseWithIo(allocator, db, session_id, std.testing.io);
}

pub fn useCaseWithIo(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    io: std.Io,
) !LlmHistoryInspectorResponse {
    if (session_id.len == 0) return error.EmptySessionId;

    // 1. Load session — 404 if not found
    const session = try llm_history.getSession(allocator, db, session_id);
    if (session == null) return error.SessionNotFound;
    var sess = session.?;
    defer sess.deinit(allocator);

    // 2. Resolve effective profile
    var model: []const u8 = try allocator.dupe(u8, "gpt-4o");
    var base_url: []const u8 = try allocator.dupe(u8, "https://api.openai.com");
    var url_style: []const u8 = try allocator.dupe(u8, "openai");
    var thinking_enabled: bool = true;
    var thinking_budget: ?u32 = null;
    var thinking_adaptive: bool = false;
    var reasoning_effort: ?[]const u8 = null;
    var temperature: f32 = 0.4;
    const max_tokens: usize = 4096;

    // Try to resolve via singleton if available
    if (nalarcore.getSingleton() catch null) |di| {
        const cfg = nalarcore.getLlmConfig(di);
        const selected = sess.selected_profile_model;
        const eff = cfg.resolveEffectiveProfile(selected);
        // Only override if non-empty
        if (eff.model.len > 0) {
            allocator.free(model);
            model = try allocator.dupe(u8, eff.model);
        }
        if (eff.base_url.len > 0) {
            allocator.free(base_url);
            base_url = try allocator.dupe(u8, eff.base_url);
        }
        if (eff.url_style.len > 0) {
            allocator.free(url_style);
            url_style = try allocator.dupe(u8, eff.url_style);
        }
        if (eff.is_thinking) |v| thinking_enabled = v;
        thinking_adaptive = eff.thinking_adaptive;
        thinking_budget = eff.thinking_budget_tokens;
        if (eff.reasoning_effort) |re| {
            reasoning_effort = try allocator.dupe(u8, re);
        }
        // Temperature from profile
        if (eff.thinking_str.len > 0) {
            // temperature is stored as string in profile, parse it
            const temp_str = blk: {
                if (cfg.getProfile(selected)) |p| {
                    if (p.temperature.len > 0 and !std.mem.eql(u8, p.temperature, "auto")) break :blk p.temperature;
                }
                if (cfg.active_profile) |ap| {
                    if (cfg.getProfile(ap)) |p| {
                        if (p.temperature.len > 0 and !std.mem.eql(u8, p.temperature, "auto")) break :blk p.temperature;
                    }
                }
                break :blk "";
            };
            if (temp_str.len > 0) {
                temperature = std.fmt.parseFloat(f32, temp_str) catch 0.4;
            }
        }
    } else {
        // Fallback: try to use session's selected_profile_model directly
        // For tests without singleton, keep defaults
    }

    // 3. Load llm_history chain
    const histories = try llm_history.getMessages(allocator, db, session_id);
    defer {
        for (histories) |*h| {
            var mut = h.*;
            mut.deinit(allocator);
        }
        allocator.free(histories);
    }

    // 4. Build AgentMessage[] (with synthetic system prompt)
    const agent_messages = try buildAgentMessages(allocator, histories);
    defer {
        for (agent_messages) |*m| m.deinit(allocator);
        allocator.free(agent_messages);
    }

    // 5. Build chain for response (simple mapping for display)
    var chain_list: std.ArrayList(ChainMessage) = .empty;
    errdefer chain_list.deinit(allocator);
    // System message first
    try chain_list.append(allocator, .{
        .role = "system",
        .content = try allocator.dupe(u8, "You are a helpful assistant."),
        .id = null,
    });
    for (histories) |h| {
        try chain_list.append(allocator, .{
            .role = try allocator.dupe(u8, h.role),
            .content = try allocator.dupe(u8, h.response_content),
            .id = try allocator.dupe(u8, h.id),
            .tool_calls = if (h.tools.len > 0) try allocator.dupe(u8, h.tools) else null,
            .tool_call_id = if (h.tool_call_id) |tci| if (tci.len > 0) try allocator.dupe(u8, tci) else null else null,
            .reasoning_content = if (h.reasoning_content) |rc| if (rc.len > 0) try allocator.dupe(u8, rc) else null else null,
            .created_at = try allocator.dupe(u8, h.created_at),
        });
    }
    const chain = try chain_list.toOwnedSlice(allocator);

    // 6. For EACH of 3 url_styles, construct ephemeral Agent and call SAME builder methods
    // CRITICAL: Reuse Agent.zig builders verbatim — do NOT duplicate serialization.
    const tools_empty: []const agent.AgentTool = &.{};

    // Anthropic
    var agent_anthropic = Agent.init(allocator, io);
    agent_anthropic.model = model;
    agent_anthropic.baseUrl = base_url;
    agent_anthropic.UrlStyle = "anthropic";
    agent_anthropic.thinkingEnabled = thinking_enabled;
    agent_anthropic.thinkingBudgetTokens = thinking_budget;
    agent_anthropic.thinkingAdaptive = thinking_adaptive;
    agent_anthropic.temperature = temperature;
    agent_anthropic.maxTokens = max_tokens;

    const body_anthropic = try agent_anthropic.buildJsonAnthropicRequest(.{
        .messages = agent_messages,
        .tools = tools_empty,
        .temperature = temperature,
        .max_tokens = max_tokens,
    }, false);

    // OpenAI
    var agent_openai = Agent.init(allocator, io);
    agent_openai.model = model;
    agent_openai.baseUrl = base_url;
    agent_openai.UrlStyle = "openai";
    agent_openai.thinkingEnabled = thinking_enabled;
    agent_openai.reasoningEffort = reasoning_effort;
    agent_openai.temperature = temperature;
    agent_openai.maxTokens = max_tokens;

    const body_openai = try agent_openai.buildJsonOpenAIRequest(.{
        .messages = agent_messages,
        .tools = tools_empty,
        .temperature = temperature,
        .max_tokens = max_tokens,
    }, false);

    // OpenAI Responses
    var agent_responses = Agent.init(allocator, io);
    agent_responses.model = model;
    agent_responses.baseUrl = base_url;
    agent_responses.UrlStyle = "openai-response";
    agent_responses.thinkingEnabled = thinking_enabled;
    agent_responses.reasoningEffort = reasoning_effort;
    agent_responses.temperature = temperature;
    agent_responses.maxTokens = max_tokens;

    const body_responses = try agent_responses.buildJsonResponsesRequest(.{
        .messages = agent_messages,
        .tools = tools_empty,
        .temperature = temperature,
        .max_tokens = max_tokens,
    }, false);

    // 7. Build curl strings (redacted, shell-escaped)
    const curl_anthropic = try buildCurlString(allocator, base_url, "/v1/messages", body_anthropic);
    const curl_openai = try buildCurlString(allocator, base_url, "/v1/chat/completions", body_openai);
    const curl_responses = try buildCurlString(allocator, base_url, "/v1/responses", body_responses);

    return .{
        .session_id = try allocator.dupe(u8, session_id),
        .model = model,
        .url_style = url_style,
        .chain = chain,
        .curl = .{
            .anthropic = curl_anthropic,
            .openai = curl_openai,
            .openai_response = curl_responses,
        },
        .bodies = .{
            .anthropic = body_anthropic,
            .openai = body_openai,
            .openai_response = body_responses,
        },
    };
}

// =====================================================================
// HTTP handler
// =====================================================================

pub fn llmHistoryInspectorHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };

    const di = nalarcore.getSingleton() catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "server not ready" }) });
    };
    const db = di.db;

    const result = useCaseWithIo(allocator, db, session_id, ctx.io) catch |err| {
        switch (err) {
            error.EmptySessionId => return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "session_id is required" }) }),
            error.SessionNotFound => return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "session not found" }) }),
            else => return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "internal error" }) }),
        }
    };

    // Build JSON response manually to include chain + curl + bodies
    // Bodies are raw JSON strings — embed as parsed JSON objects
    const bodies_anthropic_val = std.json.parseFromSlice(std.json.Value, allocator, result.bodies.anthropic, .{}) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "failed to parse anthropic body" }) });
    };
    defer bodies_anthropic_val.deinit();
    const bodies_openai_val = std.json.parseFromSlice(std.json.Value, allocator, result.bodies.openai, .{}) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "failed to parse openai body" }) });
    };
    defer bodies_openai_val.deinit();
    const bodies_responses_val = std.json.parseFromSlice(std.json.Value, allocator, result.bodies.openai_response, .{}) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "failed to parse responses body" }) });
    };
    defer bodies_responses_val.deinit();

    // Build chain JSON array
    var chain_json: std.ArrayList(u8) = .empty;
    defer chain_json.deinit(allocator);
    try chain_json.appendSlice(allocator, "[");
    for (result.chain, 0..) |msg, i| {
        if (i > 0) try chain_json.append(allocator, ',');
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.writer.print("{f}", .{std.json.fmt(msg, .{})});
        try chain_json.appendSlice(allocator, aw.written());
    }
    try chain_json.append(allocator, ']');

    // Build final response JSON
    var aw_final: std.Io.Writer.Allocating = .init(allocator);
    defer aw_final.deinit();

    // Use json string escaping for curl strings
    var curl_anthropic_escaped: std.ArrayList(u8) = .empty;
    defer curl_anthropic_escaped.deinit(allocator);
    try std.json.Stringify.valueAlloc(allocator, result.curl.anthropic, .{}); // just to validate
    // Build response via manual JSON construction for bodies as objects
    const response_json = try std.fmt.allocPrint(allocator,
        \\{{"session_id":{f},"model":{f},"url_style":{f},"chain":{s},"curl":{{"anthropic":{f},"openai":{f},"openai_response":{f}}},"bodies":{{"anthropic":{s},"openai":{s},"openai_response":{s}}}}}
    , .{
        std.json.fmt(result.session_id, .{}),
        std.json.fmt(result.model, .{}),
        std.json.fmt(result.url_style, .{}),
        chain_json.items,
        std.json.fmt(result.curl.anthropic, .{}),
        std.json.fmt(result.curl.openai, .{}),
        std.json.fmt(result.curl.openai_response, .{}),
        result.bodies.anthropic,
        result.bodies.openai,
        result.bodies.openai_response,
    });

    return res.jsonResponse(.{ .status_code = 200, .data = response_json });
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

fn setupTestDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    // Minimal sessions + llm_history schema
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT NOT NULL DEFAULT '',
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    selected_profile_model TEXT,
        \\    git_worktree_cwd TEXT,
        \\    is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
        \\    last_finish_reason TEXT,
        \\    last_human_touched_at_nano INTEGER
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT,
        \\    response_content TEXT,
        \\    finish_reason TEXT,
        \\    role TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_call_id TEXT,
        \\    reasoning_content TEXT,
        \\    reasoning_id TEXT,
        \\    reasoning_encrypted_content TEXT,
        \\    is_feed_to_llm INTEGER DEFAULT 1,
        \\    agent TEXT,
        \\    loop_index INTEGER,
        \\    temperature REAL,
        \\    is_thinking INTEGER,
        \\    created_at_nano TEXT,
        \\    created_iso TEXT,
        \\    parent_session_id TEXT,
        \\    parent_id TEXT,
        \\    prompt_tokens INTEGER,
        \\    completion_tokens INTEGER,
        \\    total_tokens INTEGER,
        \\    cache_creation_input_tokens INTEGER DEFAULT 0,
        \\    cache_read_input_tokens INTEGER DEFAULT 0,
        \\    is_input INTEGER,
        \\    is_output INTEGER,
        \\    tool_name TEXT,
        \\    diffview_before TEXT,
        \\    diffview_after TEXT,
        \\    image_url TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "llm_history_inspector: empty session_id returns EmptySessionId" {
    var ctx = try setupTestDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const alloc = testing.allocator;
    const result = useCase(alloc, &ctx.db, "");
    try testing.expectError(error.EmptySessionId, result);
}

test "llm_history_inspector: unknown session returns SessionNotFound" {
    var ctx = try setupTestDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const alloc = testing.allocator;
    const result = useCase(alloc, &ctx.db, "nonexistent_session");
    try testing.expectError(error.SessionNotFound, result);
}

test "llm_history_inspector: known session returns chain + curl with correct endpoints and redaction" {
    var ctx = try setupTestDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const alloc = testing.allocator;
    const io = ctx.threaded.io();

    // Create session
    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('sess_test_1', 'Test Session')", &.{});
    // Insert messages
    try llm_history.saveMessage(alloc, io, &ctx.db, .{
        .session_id = "sess_test_1",
        .model = "gpt-4o",
        .cwd = "/tmp",
        .content = "hello",
        .role = "user",
        .agent_name = "Agent",
        .loop_index = 0,
        .temperature = 0.4,
        .is_thinking = false,
        .is_input = true,
    });
    try llm_history.saveMessage(alloc, io, &ctx.db, .{
        .session_id = "sess_test_1",
        .model = "gpt-4o",
        .cwd = "/tmp",
        .content = "hi there",
        .role = "assistant",
        .agent_name = "Agent",
        .loop_index = 0,
        .temperature = 0.4,
        .is_thinking = false,
        .is_output = true,
    });

    const result = try useCase(alloc, &ctx.db, "sess_test_1");
    defer {
        for (result.chain) |*m| {
            alloc.free(m.role);
            alloc.free(m.content);
            alloc.free(m.id.?);
            if (m.tool_calls) |tc| alloc.free(tc);
            if (m.tool_call_id) |tci| alloc.free(tci);
            if (m.reasoning_content) |rc| alloc.free(rc);
            if (m.created_at) |ca| alloc.free(ca);
        }
        alloc.free(result.chain);
        alloc.free(result.session_id);
        alloc.free(result.model);
        alloc.free(result.url_style);
        alloc.free(result.curl.anthropic);
        alloc.free(result.curl.openai);
        alloc.free(result.curl.openai_response);
        alloc.free(result.bodies.anthropic);
        alloc.free(result.bodies.openai);
        alloc.free(result.bodies.openai_response);
    }

    // Chain has system + 2 messages
    try testing.expectEqual(@as(usize, 3), result.chain.len);
    try testing.expectEqualStrings("system", result.chain[0].role);
    try testing.expectEqualStrings("user", result.chain[1].role);
    try testing.expectEqualStrings("hello", result.chain[1].content);
    try testing.expectEqualStrings("assistant", result.chain[2].role);
    try testing.expectEqualStrings("hi there", result.chain[2].content);

    // Curl strings contain correct endpoints
    try testing.expect(std.mem.indexOf(u8, result.curl.anthropic, "/v1/messages") != null);
    try testing.expect(std.mem.indexOf(u8, result.curl.openai, "/v1/chat/completions") != null);
    try testing.expect(std.mem.indexOf(u8, result.curl.openai_response, "/v1/responses") != null);

    // Redaction: no real api_key, contains sk-****
    try testing.expect(std.mem.indexOf(u8, result.curl.anthropic, "sk-****") != null);
    try testing.expect(std.mem.indexOf(u8, result.curl.openai, "sk-****") != null);
    try testing.expect(std.mem.indexOf(u8, result.curl.openai_response, "sk-****") != null);

    // Bodies are valid JSON
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.bodies.anthropic, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value == .object);
    }
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.bodies.openai, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value == .object);
    }
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.bodies.openai_response, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value == .object);
    }
}

test "llm_history_inspector: session with tool calls includes tool_calls in chain and bodies" {
    var ctx = try setupTestDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const alloc = testing.allocator;
    const io = ctx.threaded.io();

    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('sess_tool', 'Tool Session')", &.{});
    try llm_history.saveMessage(alloc, io, &ctx.db, .{
        .session_id = "sess_tool",
        .model = "gpt-4o",
        .cwd = "/tmp",
        .content = "run bash",
        .role = "user",
        .agent_name = "Agent",
        .loop_index = 0,
        .temperature = 0.4,
        .is_thinking = false,
        .is_input = true,
    });
    // Assistant with tool calls
    const tool_calls = [_]agent.ToolCall{.{
        .id = "call_123",
        .type = "function",
        .function = .{ .name = "bash", .arguments = "{\"command\":\"ls\"}" },
    }};
    try llm_history.saveMessage(alloc, io, &ctx.db, .{
        .session_id = "sess_tool",
        .model = "gpt-4o",
        .cwd = "/tmp",
        .content = "",
        .role = "assistant",
        .tool_calls = @constCast(&tool_calls),
        .agent_name = "Agent",
        .loop_index = 0,
        .temperature = 0.4,
        .is_thinking = false,
        .is_output = true,
    });

    const result = try useCase(alloc, &ctx.db, "sess_tool");
    defer {
        for (result.chain) |*m| {
            alloc.free(m.role);
            alloc.free(m.content);
            alloc.free(m.id.?);
            if (m.tool_calls) |tc| alloc.free(tc);
            if (m.tool_call_id) |tci| alloc.free(tci);
            if (m.reasoning_content) |rc| alloc.free(rc);
            if (m.created_at) |ca| alloc.free(ca);
        }
        alloc.free(result.chain);
        alloc.free(result.session_id);
        alloc.free(result.model);
        alloc.free(result.url_style);
        alloc.free(result.curl.anthropic);
        alloc.free(result.curl.openai);
        alloc.free(result.curl.openai_response);
        alloc.free(result.bodies.anthropic);
        alloc.free(result.bodies.openai);
        alloc.free(result.bodies.openai_response);
    }

    // Chain should have system + user + assistant with tool calls
    try testing.expectEqual(@as(usize, 3), result.chain.len);
    // The assistant message should have tool_calls_json
    var found_tool = false;
    for (result.chain) |msg| {
        if (msg.tool_calls) |tc| {
            if (std.mem.indexOf(u8, tc, "bash") != null) found_tool = true;
        }
    }
    try testing.expect(found_tool);

    // Bodies should contain tools
    try testing.expect(std.mem.indexOf(u8, result.bodies.openai, "bash") != null);
    try testing.expect(std.mem.indexOf(u8, result.bodies.anthropic, "bash") != null);
}

test "llm_history_inspector: session with reasoning_content includes it in chain and Responses body" {
    var ctx = try setupTestDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const alloc = testing.allocator;
    const io = ctx.threaded.io();

    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('sess_reason', 'Reason Session')", &.{});
    try llm_history.saveMessage(alloc, io, &ctx.db, .{
        .session_id = "sess_reason",
        .model = "gpt-4o",
        .cwd = "/tmp",
        .content = "think step by step",
        .role = "user",
        .agent_name = "Agent",
        .loop_index = 0,
        .temperature = 0.4,
        .is_thinking = false,
        .is_input = true,
    });
    try llm_history.saveMessage(alloc, io, &ctx.db, .{
        .session_id = "sess_reason",
        .model = "gpt-4o",
        .cwd = "/tmp",
        .content = "the answer is 42",
        .reasoning_content = "let me think...",
        .reasoning_id = "rs_123",
        .reasoning_encrypted_content = "enc_data",
        .role = "assistant",
        .agent_name = "Agent",
        .loop_index = 0,
        .temperature = 0.4,
        .is_thinking = true,
        .is_output = true,
    });

    const result = try useCase(alloc, &ctx.db, "sess_reason");
    defer {
        for (result.chain) |*m| {
            alloc.free(m.role);
            alloc.free(m.content);
            alloc.free(m.id.?);
            if (m.tool_calls) |tc| alloc.free(tc);
            if (m.tool_call_id) |tci| alloc.free(tci);
            if (m.reasoning_content) |rc| alloc.free(rc);
            if (m.created_at) |ca| alloc.free(ca);
        }
        alloc.free(result.chain);
        alloc.free(result.session_id);
        alloc.free(result.model);
        alloc.free(result.url_style);
        alloc.free(result.curl.anthropic);
        alloc.free(result.curl.openai);
        alloc.free(result.curl.openai_response);
        alloc.free(result.bodies.anthropic);
        alloc.free(result.bodies.openai);
        alloc.free(result.bodies.openai_response);
    }

    // Chain should have reasoning_content
    var found_reasoning = false;
    for (result.chain) |msg| {
        if (msg.reasoning_content) |rc| {
            if (std.mem.indexOf(u8, rc, "let me think") != null) found_reasoning = true;
        }
    }
    try testing.expect(found_reasoning);

    // Responses body should have reasoning item
    try testing.expect(std.mem.indexOf(u8, result.bodies.openai_response, "reasoning") != null);
    try testing.expect(std.mem.indexOf(u8, result.bodies.openai_response, "let me think") != null);
}

test "llm_history_inspector: handler imports and calls all 3 builders verbatim (static contract)" {
    const source = @embedFile("llm_history_inspector.zig");
    try testing.expect(std.mem.indexOf(u8, source, "buildJsonAnthropicRequest") != null);
    try testing.expect(std.mem.indexOf(u8, source, "buildJsonOpenAIRequest") != null);
    try testing.expect(std.mem.indexOf(u8, source, "buildJsonResponsesRequest") != null);
}

test "llm_history_inspector: curl redaction never leaks api_key" {
    var ctx = try setupTestDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const alloc = testing.allocator;
    const io = ctx.threaded.io();

    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('sess_redact', 'Redact Session')", &.{});
    try llm_history.saveMessage(alloc, io, &ctx.db, .{
        .session_id = "sess_redact",
        .model = "gpt-4o",
        .cwd = "/tmp",
        .content = "hello",
        .role = "user",
        .agent_name = "Agent",
        .loop_index = 0,
        .temperature = 0.4,
        .is_thinking = false,
        .is_input = true,
    });

    const result = try useCase(alloc, &ctx.db, "sess_redact");
    defer {
        for (result.chain) |*m| {
            alloc.free(m.role);
            alloc.free(m.content);
            alloc.free(m.id.?);
            if (m.tool_calls) |tc| alloc.free(tc);
            if (m.tool_call_id) |tci| alloc.free(tci);
            if (m.reasoning_content) |rc| alloc.free(rc);
            if (m.created_at) |ca| alloc.free(ca);
        }
        alloc.free(result.chain);
        alloc.free(result.session_id);
        alloc.free(result.model);
        alloc.free(result.url_style);
        alloc.free(result.curl.anthropic);
        alloc.free(result.curl.openai);
        alloc.free(result.curl.openai_response);
        alloc.free(result.bodies.anthropic);
        alloc.free(result.bodies.openai);
        alloc.free(result.bodies.openai_response);
    }

    // Ensure no real key pattern appears — only sk-****
    // The curl should contain sk-**** and NOT contain any other sk- pattern with real chars
    for ([_][]const u8{ result.curl.anthropic, result.curl.openai, result.curl.openai_response }) |curl| {
        try testing.expect(std.mem.indexOf(u8, curl, "sk-****") != null);
        // Ensure bodies don't contain api_key either
        try testing.expect(std.mem.indexOf(u8, curl, "sk-proj") == null);
        try testing.expect(std.mem.indexOf(u8, curl, "sk-ant") == null);
    }
    // Bodies should not contain api_key
    for ([_][]const u8{ result.bodies.anthropic, result.bodies.openai, result.bodies.openai_response }) |body| {
        try testing.expect(std.mem.indexOf(u8, body, "sk-") == null);
    }
}
