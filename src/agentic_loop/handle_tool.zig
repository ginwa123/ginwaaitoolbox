const std = @import("std");
const nalar = @import("nalarcore");
const agent = nalar.agent;
const logger_mod = nalar.loggermod;
const sqlite = nalar.sqlite;
const config_mod = nalar.config;
const tools_equipped = @import("tools_equipped.zig");
const tools = @import("tools.zig");
const llm_history = @import("llm_history.zig");
const SaveSkill = llm_history.saveSkill;
const SaveAgent = @import("save_agent.zig").SaveAgent;
const session_helpers = llm_history;
const get_current_agent_by_session_id = llm_history.get_current_agent_by_session_id;
const tool_models = nalar.tool_models;
const getLatestMessage = llm_history.getLatestMessage;
const handle_mcp_tool = @import("handle_mcp_tool.zig");
const ActiveLoops = @import("ActiveLoops.zig").ActiveLoops;
const agentic_loop_mod = @import("workflow.zig");
const wrapToolOutput = agentic_loop_mod.tools.wrapToolOutput;
const xmlUnescape = @import("helpers").xmlUnescape;
const on_event_sent = @import("on_event_sent.zig");
const hooks = @import("hooks.zig");
const onEventSendLLMHistory = on_event_sent.onEventSendLLMHistory;
const insertLLMHistories = @import("insert_llm_histories.zig").inserLLMHistories;

// ============================================================================
// TOOL REGISTRY - Single source of truth: tools_equipped.zig
// ============================================================================
//
// The registry used to live in `tool_registry.zig` (deleted). It is now
// defined exclusively in `tools_equipped.zig` — every reference in this
// file (and elsewhere) goes through there. Re-export the alias here for
// downstream callers that still import `handle_tool.TOOL_REGISTRY`.

/// Re-export from the canonical registry (`tools_equipped.zig`).
pub const TOOL_REGISTRY = tools_equipped.UNIFIED_TOOL_REGISTRY;

/// Context passed to all tool handlers
const ToolContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    api_key: []const u8,
    base_url: []const u8,
    config: *const config_mod.LlmConfig,
    agent_temperature: *f32,
    is_thinking: *bool,
    environment: ?*const std.process.Environ.Map,
    active_loops: *ActiveLoops,
    selected_profile_model: []const u8 = "",
    /// See `tools.ToolExecContext.allowed_tools` — the progressive-tool
    /// adapter needs it to know which built-ins are not enabled.
    allowed_tools: []const u8 = "",
    is_sub_agent: bool = false,
};

/// Result of parsing diff_view XML from tool result.
/// If diff_view was found, content_without_diffview is an allocated string (caller must free).
/// Otherwise, content_without_diffview is the original content slice.
pub const DiffViewParseResult = struct {
    /// The content with diff_view section removed (allocated if diff_view found).
    /// Caller must free this if diff_view_found is true.
    content_without_diffview: []const u8,
    /// Whether a diff_view section was found and removed
    diff_view_found: bool,
    /// The before content extracted from <before> tag, XML-unescaped
    /// (`&quot;` → `"`, `&lt;` → `<`, `&gt;` → `>`, `&apos;` → `'`, `&amp;` → `&`).
    /// Null if the tag wasn't found. If `diff_view_found` is true, this is
    /// ALWAYS an allocated buffer that the caller MUST free.
    before: ?[]const u8,
    /// The after content extracted from <after> tag, XML-unescaped (see `before`).
    /// Null if the tag wasn't found. If `diff_view_found` is true, this is
    /// ALWAYS an allocated buffer that the caller MUST free.
    after: ?[]const u8,
};

/// Parses diff_view XML from a text_replace tool result.
/// Extracts before/after content and returns content with diff_view section removed.
/// ALWAYS returns an allocated string for content_without_diffview - caller MUST free it.
pub fn parseDiffViewFromResult(allocator: std.mem.Allocator, content: []const u8) !DiffViewParseResult {
    const dv_start = std.mem.indexOf(u8, content, "<diff_view>");
    const dv_end = std.mem.indexOf(u8, content, "</diff_view>");

    // Even if no diff_view found, return allocated copy of original content
    if (dv_start == null or dv_end == null) {
        const allocated = try std.fmt.allocPrint(allocator, "{s}", .{content});
        return DiffViewParseResult{
            .content_without_diffview = allocated,
            .diff_view_found = false,
            .before = null,
            .after = null,
        };
    }

    const dv_content = content[dv_start.? + 10 .. dv_end.?]; // 10 = len("<diff_view>")

    // Extract before content. Inner slices point into `content` which holds
    // XML-encoded entities (`&quot;`, `&lt;`, ...); we MUST unescape them
    // before returning so the consumer sees the original byte-level content.
    // Without this, a source-code diff with `"` / `<` / `>` / `&` would
    // render literally as `&quot;` / `&lt;` / `&gt;` / `&amp;` in the UI
    // (bug: "diff view shows &quot; instead of ""). See parse_diff_view_test.zig
    // for regression coverage.
    var before_val: ?[]const u8 = null;
    var before_allocated = false;
    if (std.mem.indexOf(u8, dv_content, "<before>")) |b_start| {
        const b_content_start = b_start + 8; // 8 = len("<before>")
        if (std.mem.indexOf(u8, dv_content, "</before>")) |b_end| {
            const raw = dv_content[b_content_start..b_end];
            before_val = try xmlUnescape(allocator, raw);
            before_allocated = true;
            errdefer if (before_allocated) allocator.free(before_val.?);
        }
    }

    var after_val: ?[]const u8 = null;
    var after_allocated = false;
    if (std.mem.indexOf(u8, dv_content, "<after>")) |a_start| {
        const a_content_start = a_start + 7; // 7 = len("<after>")
        if (std.mem.indexOf(u8, dv_content, "</after>")) |a_end| {
            const raw = dv_content[a_content_start..a_end];
            after_val = try xmlUnescape(allocator, raw);
            after_allocated = true;
            errdefer if (after_allocated) allocator.free(after_val.?);
        }
    }

    // Remove diff_view section from content by concatenating before + after parts
    const before_part = content[0..dv_start.?];
    const after_part_start = dv_end.? + 12; // 12 = len("</diff_view>")
    const after_part = if (after_part_start < content.len) content[after_part_start..] else "";
    const content_without_diffview = try std.fmt.allocPrint(allocator, "{s}{s}", .{ before_part, after_part });

    return DiffViewParseResult{
        .content_without_diffview = content_without_diffview,
        .diff_view_found = true,
        .before = before_val,
        .after = after_val,
    };
}

/// Result of executing a tool
const ToolResult = struct {
    output: []const u8,
    temperature: ?f32 = null,
    is_thinking: ?bool = null,
    skill_saved: ?SkillSaveInfo = null,
    agent_saved: ?AgentSaveInfo = null,
    progressive_tool_saved: ?ProgressiveToolSaveInfo = null,
};

const SkillSaveInfo = struct {
    name: []const u8,
    content: []const u8,
};

const AgentSaveInfo = struct {
    name: []const u8,
};

/// `use_tool` actually INSERTed a `session_progressive_tool` row.
const ProgressiveToolSaveInfo = struct {
    name: []const u8,
    server_name: []const u8,
};

/// Extended result type for main agent tool execution
/// Includes optional temperature/is_thinking for set_agent_properties
const MainAgentToolResult = struct {
    output: []const u8,
    temperature: ?f32 = null,
    is_thinking: ?bool = null,
    skill_saved: ?SkillSaveInfo = null,
    agent_saved: ?AgentSaveInfo = null,
};

/// Lookup a tool by name and execute it using unified registry
/// Refactored: Uses entry.exec() directly instead of double lookup
///
/// Lua hooks (`hooks/register_hook.lua :: init(event, data)`) wrap every
/// dispatch: the pre hook may deny (error envelope, no exec), modify args,
/// or mock the output (no exec); the post hook may replace the output.
/// All hook failures degrade to the no-hook behavior (see hooks.zig).
fn dispatchTool(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    var effective_call = tool_call;
    var modified_args: ?[]const u8 = null;
    defer if (modified_args) |a| ctx.allocator.free(a);

    switch (runPreHookAction(ctx, tool_call.function.name, tool_call.function.arguments)) {
        .proceed => {},
        .proceed_modified => |a| {
            modified_args = a;
            effective_call.function.arguments = a;
        },
        .short_circuit => |out| return ToolResult{ .output = out },
    }

    var result: ToolResult = blk: {
        for (tools_equipped.UNIFIED_TOOL_REGISTRY()) |entry| {
            if (std.mem.eql(u8, effective_call.function.name, entry.name)) {
                break :blk try dispatchFromRegistry(ctx, effective_call, entry.exec);
            }
        }

        // Check if it's an MCP tool (format: mcp_serverName_toolName)
        if (isMCPTool(ctx.config, effective_call.function.name)) {
            break :blk try dispatchMCP(ctx, effective_call);
        }

        return error.UnknownTool;
    };

    if (runPostHookOverride(ctx, effective_call.function.name, effective_call.function.arguments, result.output)) |replacement| {
        result.output = replacement;
    }
    return result;
}

/// Outcome of the Lua pre hook for one tool call. Owned strings transfer
/// to the caller (short_circuit becomes the tool output, proceed_modified
/// must be freed after dispatch).
const PreHookAction = union(enum) {
    proceed,
    proceed_modified: []const u8,
    short_circuit: []const u8,
};

fn runPreHookAction(ctx: ToolContext, tool_name: []const u8, arguments: []const u8) PreHookAction {
    const hook_ctx = hooks.HookContext{ .session_id = ctx.session_id, .cwd = ctx.cwd, .model = ctx.model };
    const pre = hooks.runPreHook(ctx.allocator, ctx.logger, ctx.environment, tool_name, arguments, hook_ctx) catch return .proceed;
    switch (pre) {
        .allow => return .proceed,
        .deny => |reason| {
            defer ctx.allocator.free(reason);
            const out = wrapToolOutput(ctx.allocator, tool_name, arguments, false, reason, "") catch return .proceed;
            return .{ .short_circuit = out };
        },
        .modify => |new_args| return .{ .proceed_modified = new_args },
        .mock => |mock_output| {
            defer ctx.allocator.free(mock_output);
            const out = wrapToolOutput(ctx.allocator, tool_name, arguments, true, null, mock_output) catch return .proceed;
            return .{ .short_circuit = out };
        },
    }
}

/// Run the Lua post hook. Returns an owned replacement output, or null to
/// keep `current`. Never errors outward (fail-open inside).
fn runPostHookOverride(ctx: ToolContext, tool_name: []const u8, arguments: []const u8, current: []const u8) ?[]const u8 {
    const hook_ctx = hooks.HookContext{ .session_id = ctx.session_id, .cwd = ctx.cwd, .model = ctx.model };
    const post = hooks.runPostHook(ctx.allocator, ctx.logger, ctx.environment, tool_name, arguments, current, hook_ctx) catch return null;
    switch (post) {
        .keep => return null,
        .replace => |new_output| return new_output,
        .deny => |reason| {
            defer ctx.allocator.free(reason);
            return wrapToolOutput(ctx.allocator, tool_name, arguments, false, reason, "") catch null;
        },
    }
}

/// Dispatch tool execution from registry entry
/// Calls exec directly and handles auto-save via registry flags
fn dispatchFromRegistry(ctx: ToolContext, tool_call: agent.ToolCall, exec: tools_equipped.ToolExecFunc) !ToolResult {
    const ctx_local = tools.ToolExecContext{
        .allocator = ctx.allocator,
        .io = ctx.io,
        .db = ctx.db,
        .logger = ctx.logger,
        .session_id = ctx.session_id,
        .model = ctx.model,
        .cwd = ctx.cwd,
        .api_key = ctx.api_key,
        .base_url = ctx.base_url,
        .config = ctx.config,
        .agent_temperature = ctx.agent_temperature,
        .is_thinking = ctx.is_thinking,
        .environment = ctx.environment,
        .active_loops = ctx.active_loops,
        .selected_profile_model = ctx.selected_profile_model,
        // 2026-08-23 spawn-subagent-live-progress: thread the
        // parent's tool_call.id through ToolExecContext so
        // execSpawnSubAgent can emit progress events keyed by it
        // (ChatView.vue's reducer filters on this exact value).
        .tool_call_id = tool_call.id,
        // Progressive tool search: the exec-side catalog computes which
        // built-ins are NOT enabled, which needs the resolved allowlist.
        .allowed_tools = ctx.allowed_tools,
        .is_sub_agent = ctx.is_sub_agent,
    };
    const exec_result = try exec(ctx_local, tool_call);

    return ToolResult{
        .output = exec_result.output,
        .temperature = exec_result.temperature,
        .is_thinking = exec_result.is_thinking,
        .skill_saved = if (exec_result.skill_save) |sk| SkillSaveInfo{ .name = sk.name, .content = sk.content } else null,
        .agent_saved = if (exec_result.agent_save) |ag| AgentSaveInfo{ .name = ag.name } else null,
        .progressive_tool_saved = if (exec_result.progressive_tool_save) |pt| ProgressiveToolSaveInfo{
            .name = pt.name,
            .server_name = pt.server_name,
        } else null,
    };
}

/// Check if a tool name is an MCP tool (format: mcp_serverName_toolName)
fn isMCPTool(config: *const config_mod.LlmConfig, tool_name: []const u8) bool {
    if (config.mcpServers() == null) return false;

    // MCP tool names have format: mcp_{serverName}_{toolName}
    // e.g., mcp_context7_query-docs
    if (!std.mem.startsWith(u8, tool_name, "mcp_")) return false;

    // Find second underscore (after "mcp_") to get server name
    const after_mcp = tool_name["mcp_".len..];
    const underscore_idx = std.mem.indexOf(u8, after_mcp, "_") orelse return false;
    const server_name = after_mcp[0..underscore_idx];

    const mcp_servers = switch (config.mcpServers().?) {
        .object => |obj| obj,
        else => return false,
    };
    return mcp_servers.get(server_name) != null;
}

/// Dispatch an MCP tool call
fn dispatchMCP(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const result = try handle_mcp_tool.handle_mcp_tool_run(
        ctx.allocator,
        ctx.logger,
        tool_call,
        ctx.config,
    );
    // Return success with tool output
    return ToolResult{ .output = result };
}

/// Check if a tool name is registered (uses unified registry)
pub fn isKnownTool(name: []const u8) bool {
    for (tools_equipped.UNIFIED_TOOL_REGISTRY()) |*tool| {
        if (std.mem.eql(u8, name, tool.name)) return true;
    }
    return false;
}

/// Check if a tool name is registered or is an MCP tool
pub fn isKnownToolOrMCP(name: []const u8, config: *const config_mod.LlmConfig) bool {
    if (isKnownTool(name)) return true;
    return isMCPTool(config, name);
}

/// Get all tool names as a slice
pub fn getToolNames() []const []const u8 {
    const unified = tools_equipped.UNIFIED_TOOL_REGISTRY();
    const names = comptime blk: {
        var n: [unified.len][]const u8 = undefined;
        for (unified, 0..) |tool, i| {
            n[i] = tool.name;
        }
        break :blk n;
    };
    return &names;
}

// ============================================================================
// HELPER FUNCTIONS - XML Parsing
// ============================================================================

fn parseSkillFromResult(result: []const u8) ?struct { name: []const u8, content: []const u8 } {
    if (std.mem.indexOf(u8, result, "<loaded>true</loaded>") == null) return null;

    const name_start = std.mem.indexOf(u8, result, "<skill_name>") orelse return null;
    const name_begin = name_start + "<skill_name>".len;
    const name_end = std.mem.indexOf(u8, result[name_begin..], "</skill_name>") orelse return null;
    const skill_name = result[name_begin .. name_begin + name_end];

    const content_start = std.mem.indexOf(u8, result, "<content>") orelse return null;
    const content_begin = content_start + "<content>".len;
    const content_end = std.mem.indexOf(u8, result[content_begin..], "</content>") orelse return null;
    const skill_content = result[content_begin .. content_begin + content_end];

    return .{ .name = skill_name, .content = skill_content };
}

fn parseAgentFromResult(result: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, result, "<loaded>true</loaded>") == null) return null;

    const name_start = std.mem.indexOf(u8, result, "<agent_name>") orelse return null;
    const name_begin = name_start + "<agent_name>".len;
    const name_end = std.mem.indexOf(u8, result[name_begin..], "</agent_name>") orelse return null;
    return result[name_begin .. name_begin + name_end];
}

// ============================================================================
// MAIN HANDLER - Clean dispatch using registry
// ============================================================================

pub fn handle_tool(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    parent_session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    loop_counter: u32,
    res_dynamic_agent: agent.CallResponse,
    agent_temperature: *f32,
    isThinking: *bool,
    api_key: []const u8,
    base_url: []const u8,
    config: *const config_mod.LlmConfig,
    environment: ?*const std.process.Environ.Map,
    active_loops: *ActiveLoops,
    selected_profile_model: []const u8,
    // Passed straight through to `ToolExecContext`. Zig has no default
    // parameter values, so every caller must supply them; `workflow.zig`
    // does. The tool-result envelope stays the same either way.
    allowed_tools: []const u8,
    is_sub_agent: bool,
) !void {
    if (res_dynamic_agent.tool_calls) |tc| {
        // ─── Phase 1: INSERT placeholder rows for ALL known tools ───
        //
        // This is the critical fix for the "Invalid function ID" bug.
        // We pre-create every role=tool row BEFORE running any tool,
        // so the OpenAI API contract (every tool_call_id must have a
        // matching role=tool row) is satisfied even if the app
        // crashes mid-execution. The dispatch loop in Phase 3 then
        // UPDATEs each placeholder in place with the actual result.
        //
        // Unknown tools skip the placeholder (they're skipped below
        // too — the original code's behaviour is preserved).
        //
        // Migrated from the old 2-phase pattern (assistant message
        // INSERT then per-tool saveMessage) which left orphaned
        // tool_call_ids on crash. See plan:
        // docs/superpowers/plans/2026-08-06-tool-call-loading-placeholder.md

        // ─── Phase 2: INSERT the assistant message (existing code) ───
        //
        // The assistant message declares tool_calls=[A, B, C] and has
        // existing tool_call_id columns that match the placeholders
        // by id. The DB now has 1 assistant row + N placeholder rows.
        //
        // NOTE: the conversation order is "placeholders first, then
        // assistant message" by created_at. This is OK because the LLM
        // API contract matches tool_call_ids by VALUE, not by row
        // order. The LLM sees a complete set of (placeholder, assistant)
        // records either way. The ordering matters for the LLM's
        // understanding of the conversation flow, but an empty
        // placeholder content followed by an assistant message is
        // semantically equivalent to "the agent is mid-execution".
        var has_known_tools = false;
        for (tc) |tool_call| {
            if (isKnownToolOrMCP(tool_call.function.name, config)) {
                has_known_tools = true;
                break;
            }
        }
        if (!has_known_tools) {
            logger.infoFmt("[HANDLE_TOOL] All tool calls are unknown — placeholders were skipped", .{});
        }

        // Build tool names list and save assistant message
        var toolNames = try std.ArrayList([]const u8).initCapacity(allocator, tc.len);
        defer toolNames.deinit(allocator);
        for (tc) |tc_| {
            _ = try toolNames.append(allocator, tc_.function.name);
        }

        const current_agent_state = try get_current_agent_by_session_id(allocator, db, session_id);
        const current_agent_for_save = current_agent_state.agent;

        _ = try llm_history.saveMessage(allocator, io, db, .{
            .session_id = session_id,
            .model = model,
            .cwd = cwd,
            .content = res_dynamic_agent.content,
            .reasoning_content = res_dynamic_agent.reasoning_content,
            .reasoning_id = res_dynamic_agent.reasoning_id,
            .reasoning_encrypted_content = res_dynamic_agent.reasoning_encrypted_content,
            .role = agent.Role.assistant.to_str(),
            .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else null,
            .tool_calls = tc,
            .tool_call_id = null,
            .agent_name = current_agent_for_save,
            .loop_index = loop_counter,
            .temperature = agent_temperature.*,
            .is_thinking = isThinking.*,
            .prompt_tokens = res_dynamic_agent.usage.prompt_tokens,
            .completion_tokens = res_dynamic_agent.usage.completion_tokens,
            .total_tokens = res_dynamic_agent.usage.total_tokens,
            .cache_creation_input_tokens = res_dynamic_agent.usage.cache_creation_input_tokens,
            .cache_read_input_tokens = res_dynamic_agent.usage.cache_read_input_tokens,
            .is_input = true,
            .is_output = false,
            .tool_name = try std.mem.join(allocator, ",", toolNames.items),
            .parent_id = parent_session_id,
            .parent_session_id = parent_session_id,
        });

        // Send SSE for assistant message
        try sendSSEForLatestMessage(allocator, db, session_id, cwd, current_agent_for_save, parent_session_id, agent_temperature.*, isThinking.*, true, false, tc);

        var list_id_that_was_loaded: std.ArrayList([]const u8) = .empty;

        for (tc) |tool_call| {
            // Phase 1 placeholder content: build the canonical
            // `<tool>...</tool>` envelope via `wrapToolOutput` so the
            // frontend's `tryUnwrapToolOutput` can parse it on
            // page-refresh-mid-execution AND on the live-SSE path.
            //
            //  - Unknown tools (registry miss) → `success=false` envelope
            //    with `<error>unknown tools</error>` so the chat card
            //    shows a structured error block instead of a raw text
            //    bubble. Previously the raw string "unknown tools" was
            //    stored verbatim in `response_content`; the frontend
            //    then tried to unwrap it as a `<tool>` envelope and
            //    fell back to the `msg.content` legacy path, rendering
            //    an empty card.
            //  - Known tools (including MCP) → `success=true` envelope
            //    with empty `<data></data>`. Phase 3 will UPDATE the
            //    same row in place with the actual exec result. The
            //    empty `<data>` block is intentional — it keeps the
            //    envelope shape stable so the frontend never sees a
            //    "raw text" / "envelope" branch flip mid-flight.
            //
            // `wrapToolOutput` always emits `<name>` + `<parameters>`,
            // so any tool-output Vue component (the `v-else-if` chain
            // at ChatView.vue:2857-3094) can render a sensible
            // placeholder card (tool name + arguments) while it waits
            // for Phase 3 to land. Previously the bare empty content
            // caused `innerToolData()` to fall back to `msg.content`,
            // which was `""` — the card rendered blank.
            const placeholder = if (!isKnownToolOrMCP(tool_call.function.name, config))
                try wrapToolOutput(
                    allocator,
                    tool_call.function.name,
                    tool_call.function.arguments,
                    false,
                    "unknown tools",
                    "",
                )
            else
                try wrapToolOutput(
                    allocator,
                    tool_call.function.name,
                    tool_call.function.arguments,
                    true,
                    null,
                    "",
                );
            // `insertLLMHistories` duplicates the content slice
            // internally (line 123 of insert_llm_histories.zig), so
            // we own and free the envelope string after the call
            // returns — the DB row holds its own copy.
            defer allocator.free(placeholder);

            const created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
            const id_llm_history = try insertLLMHistories(.{
                .allocator = allocator,
                .io = io,
                .db = db,
                .logger = logger,
                .is_emit_sse = false,
                .event_bus = null,
                .cwd = cwd,
                .entity = .{
                    .id = created_at,
                    .session_id = session_id,
                    .model = model,
                    .response_content = placeholder,
                    .reasoning_content = null,
                    .role = agent.Role.tool.to_str(),
                    .finish_reason = agent.FinishReason.tool.to_str(),
                    .tool_calls_json = "",
                    .tool_call_id = tool_call.id,
                    .agent = current_agent_state.agent,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature.*,
                    .is_thinking = isThinking.*,
                    .prompt_tokens = 0,
                    .completion_tokens = 0,
                    .total_tokens = 0,
                    .parent_id = parent_session_id,
                    .parent_session_id = parent_session_id,
                    .is_input = false,
                    .is_output = true,
                    .image_urls = null,
                    .created_at = created_at,
                    .is_feed_to_llm = true,
                    .tool_name = tool_call.function.name,
                },
            });
            try list_id_that_was_loaded.append(allocator, id_llm_history);
        }

        // 2026-09-01 fix: emit placeholder SSE immediately so the
        // frontend has a tool message to attach live progress to.
        // Without this, spawn_sub_agent's `role="subagent_progress"`
        // events arrive but there's no <SpawnSubAgent> component yet
        // (it only mounts for tool messages), so the card stays at
        // "0 sub-agents" until the final <results> envelope lands
        // minutes later. Emitting here gives the card an empty-data
        // envelope (agents.length==0) that flips to inLiveMode when
        // progress arrives.
        for (list_id_that_was_loaded.items) |pid| {
            sendSSEForMessageById(allocator, db, session_id, cwd, current_agent_for_save, parent_session_id, agent_temperature.*, isThinking.*, false, true, pid) catch |err| {
                logger.warnFmt("Failed to emit placeholder SSE for {s}: {s}", .{ pid, @errorName(err) });
            };
        }

        // Build context for dispatch
        const ctx = ToolContext{
            .allocator = allocator,
            .io = io,
            .db = db,
            .logger = logger,
            .session_id = session_id,
            .model = model,
            .cwd = cwd,
            .api_key = api_key,
            .base_url = base_url,
            .config = config,
            .agent_temperature = agent_temperature,
            .is_thinking = isThinking,
            .environment = environment,
            .active_loops = active_loops,
            .selected_profile_model = selected_profile_model,
            .allowed_tools = allowed_tools,
            .is_sub_agent = is_sub_agent,
        };

        // ─── Phase 3: dispatch each tool & UPDATE placeholder in place ───
        //
        // For each tool_call, we run the tool (catching errors) and
        // UPDATE the placeholder row with the actual result (or the
        // error message). The placeholder's id is unchanged, so the
        // SSE listener (which reads the latest message) sees an
        // in-place update.
        //
        // If the app crashes mid-dispatch, the stranded placeholders
        // are picked up by `resolveStaleLoadingToolResults` on the
        // next worker loop start (called from workflow.zig).
        var idx: usize = 0;
        for (tc) |tool_call| {
            const id_llm_history = list_id_that_was_loaded.items[idx];
            idx += 1;
            var tool_result: []const u8 = undefined;
            var toolAgentTemp: f32 = agent_temperature.*;
            var toolIsThinking: bool = isThinking.*;

            // Skip placeholders for unknown tools (consistency with
            // Phase 1 — we never inserted a placeholder for them).
            if (!isKnownToolOrMCP(tool_call.function.name, config)) {
                logger.warnFmt("[HANDLE_TOOL] Skipping unknown tool '{s}' (no placeholder was created)", .{tool_call.function.name});
                continue;
            }

            // Check if this is an MCP tool. Lua hooks apply here too
            // (same pre/post contract as dispatchTool below) so hook
            // authors see every tool call, not just builtin ones.
            if (isMCPTool(config, tool_call.function.name)) {
                var mcp_call = tool_call;
                var mcp_modified_args: ?[]const u8 = null;
                defer if (mcp_modified_args) |a| allocator.free(a);
                switch (runPreHookAction(ctx, tool_call.function.name, tool_call.function.arguments)) {
                    .proceed => {},
                    .proceed_modified => |a| {
                        mcp_modified_args = a;
                        mcp_call.function.arguments = a;
                    },
                    .short_circuit => |out| {
                        tool_result = out;
                        errdefer allocator.free(tool_result);
                        try updateAndSendToolResult(allocator, io, db, id_llm_history, session_id, cwd, tool_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save, parent_session_id);
                        allocator.free(tool_result);
                        continue;
                    },
                }
                // Call MCP handler
                tool_result = handle_mcp_tool.handle_mcp_tool_run(
                    allocator,
                    logger,
                    mcp_call,
                    config,
                ) catch |err| {
                    const err_msg = try std.fmt.allocPrint(allocator, "MCP tool {s} failed: {s}", .{
                        mcp_call.function.name,
                        @errorName(err),
                    });
                    tool_result = try wrapToolOutput(allocator, mcp_call.function.name, mcp_call.function.arguments, false, err_msg, "");
                    errdefer allocator.free(tool_result);
                    try updateAndSendToolResult(allocator, io, db, id_llm_history, session_id, cwd, mcp_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save, parent_session_id);
                    allocator.free(tool_result);
                    continue;
                };
                if (runPostHookOverride(ctx, mcp_call.function.name, mcp_call.function.arguments, tool_result)) |replacement| {
                    tool_result = replacement;
                }
                try updateAndSendToolResult(allocator, io, db, id_llm_history, session_id, cwd, mcp_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save, parent_session_id);
                continue;
            }

            // Dispatch to the appropriate handler
            const exec_result = dispatchTool(ctx, tool_call) catch |err| {
                std.debug.print("DEBUG: dispatchTool failed with error: {s}\n", .{@errorName(err)});
                const err_msg = try std.fmt.allocPrint(allocator, "{s} failed: {s}", .{
                    tool_call.function.name,
                    @errorName(err),
                });
                tool_result = try wrapToolOutput(allocator, tool_call.function.name, tool_call.function.arguments, false, err_msg, "");
                errdefer allocator.free(tool_result);
                try updateAndSendToolResult(allocator, io, db, id_llm_history, session_id, cwd, tool_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save, parent_session_id);
                allocator.free(tool_result);
                continue;
            };

            tool_result = exec_result.output;

            // Apply property changes from tool execution
            if (exec_result.temperature) |temp| toolAgentTemp = temp;
            if (exec_result.is_thinking) |think| toolIsThinking = think;

            // Auto-save skill if loaded
            if (exec_result.skill_saved) |skill_info| {
                SaveSkill(allocator, db, logger, session_id, skill_info.name, skill_info.content) catch |err| {
                    logger.errFmt("Failed to save skill '{s}': {s}", .{ skill_info.name, @errorName(err) });
                };
            }

            // Auto-save agent if loaded
            if (exec_result.agent_saved) |agent_info| {
                SaveAgent(allocator, db, logger, session_id, agent_info.name) catch |err| {
                    logger.errFmt("Failed to save agent '{s}': {s}", .{ agent_info.name, @errorName(err) });
                };
            }

            // Progressive tool search: `use_tool` records the equip so the
            // NEXT iteration's tool resolution includes it. Persisting here
            // (rather than only inside the exec adapter) means a failure to
            // write is visible as a log line instead of a tool that silently
            // never becomes callable.
            if (exec_result.progressive_tool_saved) |pt| {
                _ = llm_history.saveProgressiveTool(allocator, db, logger, session_id, pt.name, pt.server_name) catch |err| {
                    logger.errFmt("Failed to equip progressive tool '{s}': {s}", .{ pt.name, @errorName(err) });
                };
            }

            try updateAndSendToolResult(allocator, io, db, id_llm_history, session_id, cwd, tool_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save, parent_session_id);
        }
    }

    logger.debugFmt("Tool calls processing complete, looping back for next API call...", .{});
}

fn updateAndSendToolResult(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    session_id: []const u8,
    cwd: []const u8,
    tool_call: agent.ToolCall,
    result: []const u8,
    temperature: f32,
    is_thinking: bool,
    agent_name: []const u8,
    parent_session_id: []const u8,
) !void {
    var diffview_before: ?[]const u8 = null;
    var diffview_after: ?[]const u8 = null;
    var content_modified: []const u8 = result;
    var content_modified_allocated: ?[]u8 = null;

    if (std.mem.eql(u8, tool_call.function.name, "text_replace")) {
        // Parse diff_view from XML result - ALWAYS returns allocated string
        if (parseDiffViewFromResult(allocator, result)) |parsed| {
            diffview_before = parsed.before;
            diffview_after = parsed.after;
            content_modified_allocated = @ptrCast(@constCast(parsed.content_without_diffview));
            content_modified = parsed.content_without_diffview;
        } else |_| {
            // Keep original result on parse error
            content_modified = result;
        }
    }

    // UPDATE the placeholder row in place (created in Phase 1 of
    // handle_tool's 3-phase pattern). The row's id is unchanged, so
    // the SSE listener (which reads the latest message) sees an
    // in-place update.
    //
    // If the placeholder doesn't exist (e.g. an unknown tool was
    // dispatched anyway), updateToolResultById is a silent no-op
    // (0 rows affected) — the old saveMessage would have created a
    // new row, but with the placeholder pattern we prefer to drop
    // the orphan rather than have an unmatched tool result.
    try llm_history.updateToolResultById(allocator, io, db, id, .{
        .content = content_modified,
        .diffview_before = diffview_before,
        .diffview_after = diffview_after,
    });

    // Free the allocated content_after_diff_view.
    // `before` and `after` are also allocations owned by this caller (since
    // parseDiffViewFromResult now always allocates them — so it can unescape
    // XML entities like `&quot;` → `"` before returning the original byte
    // content for storage). See handle_tool.zig parseDiffViewFromResult.
    if (content_modified_allocated) |allocated| {
        allocator.free(allocated);
    }
    if (diffview_before) |before| allocator.free(before);
    if (diffview_after) |after| allocator.free(after);

    // 2026-08-23 B1 fix — emit the SSE for THIS tool's row by its known
    // id. The old code called sendSSEForLatestMessage here, which reads
    // getLatestMessage (last-created row in the session). With N
    // parallel tool calls, completions 1..N-1 all emitted the LAST
    // placeholder's data: empty content + wrong tool_call_id — the
    // frontend showed stale loading cards and TOOLS-pill spam. The row
    // id has been in hand all along (this function's `id` parameter);
    // selecting by it emits each completion's OWN row.
    try sendSSEForMessageById(allocator, db, session_id, cwd, agent_name, parent_session_id, temperature, is_thinking, false, true, id);
}

/// 2026-08-23 B1 fix — emit the SSE for ONE specific llm_history row,
/// selected by its exact id. This is the tool-result path: each
/// placeholder row's id is known (list_id_that_was_loaded), so there is
/// no reason to guess via getLatestMessage — which returns the
/// last-created row in the session and, for multi-tool turns, emitted
/// the WRONG row (empty content + wrong tool_call_id) for every
/// completion except the newest.
fn sendSSEForMessageById(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8, cwd: []const u8, agent_name: []const u8, parent_session_id: []const u8, temperature: f32, is_thinking: bool, is_input: bool, is_output: bool, id: []const u8) !void {
    const msgOpt = llm_history.getMessageById(allocator, db, session_id, id) catch |err| {
        std.debug.print("SSE_DEBUG: getMessageById failed for session {s} id {s}: {s}\n", .{ session_id, id, @errorName(err) });
        return;
    };
    const msg = msgOpt orelse {
        std.debug.print("SSE_DEBUG: no message found for session {s} id {s}\n", .{ session_id, id });
        return;
    };
    defer {
        allocator.free(msg.id);
        allocator.free(msg.session_id);
        allocator.free(msg.model);
        allocator.free(msg.created_at);
        allocator.free(msg.response_content);
        allocator.free(msg.finish_reason);
        allocator.free(msg.role);
        allocator.free(msg.tools);
        if (msg.reasoning_content) |r| allocator.free(r);
        allocator.free(msg.agent);
        allocator.free(msg.session_name);
        allocator.free(msg.tool_name);
        if (msg.parent_session_id) |p| allocator.free(p);
        if (msg.diffview_before) |d| allocator.free(d);
        if (msg.diffview_after) |d| allocator.free(d);
        if (msg.image_urls) |urls| {
            for (urls) |u| allocator.free(u);
            allocator.free(urls);
        }
        if (msg.tool_call_id) |t| allocator.free(t);
    }

    std.debug.print("SSE_DEBUG: sending SSE by id for session {s}, id={s}, content='{s}'\n", .{ session_id, msg.id, if (msg.response_content.len > 50) msg.response_content[0..50] else msg.response_content });

    const session_skills_tool = llm_history.getSessionSkills(allocator, db, session_id) catch null;
    defer if (session_skills_tool) |s| for (s) |*skill| {
        allocator.free(skill.skill_name);
        allocator.free(skill.content);
    };

    onEventSendLLMHistory(allocator, .{
        .id = msg.id,
        .session_id = msg.session_id,
        .model = msg.model,
        .cwd = cwd,
        .content = msg.response_content,
        .reasoning_content = msg.reasoning_content,
        .role = msg.role,
        .finish_reason = msg.finish_reason,
        // Tool-result rows carry NO tool_calls array — that field is the
        // assistant message's wire format. The old code passed null here
        // too (via sendSSEForLatestMessage's `null` argument).
        .tool_calls_json = null,
        // 2026-09-01 fix: tool_call_id on the wire is the ORIGINAL LLM
        // id (e.g. "call_abc123"), NOT the row id. The row id is already
        // in `msg.id` / `event.id`. Using the row id here broke
        // spawn_sub_agent live progress: progress events are keyed by
        // the original id, but the placeholder's SSE had the row id, so
        // `subAgentProgressMap[msg.tool_call_id]` never matched and the
        // card showed "0 sub-agents" while running. REST (get_llm_histories)
        // already returns the original id; SSE must agree.
        .tool_call_id = msg.tool_call_id orelse msg.id,
        .tool_name = msg.tool_name,
        .agent_name = agent_name,
        .loop_index = msg.loop_index,
        .temperature = temperature,
        .is_thinking = is_thinking,
        .is_input = is_input,
        .is_output = is_output,
        .parent_session_id = parent_session_id,
        .parent_id = session_id,
        .diffview_before = msg.diffview_before,
        .diffview_after = msg.diffview_after,
        .total_tokens = msg.total_tokens,
        .image_url = null,
        .session_skills = session_skills_tool,
    }) catch |err| {
        std.debug.print("SSE_DEBUG: on_event_send_new failed for session {s}: {s}\n", .{ session_id, @errorName(err) });
    };
}

fn sendSSEForLatestMessage(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8, cwd: []const u8, agent_name: []const u8, parent_session_id: []const u8, temperature: f32, is_thinking: bool, is_input: bool, is_output: bool, tool_calls_json: ?[]agent.ToolCall) !void {
    // 2026-08-24 wire-shape fix (task_1787590621966_10): the raw array is
    // passed through unchanged — on_event_sent.onEventSendLLMHistory now
    // serializes tool_calls to a JSON STRING internally (single
    // serialization point, all callers fixed at once).

    const latestMessage = getLatestMessage(allocator, db, session_id) catch |err| {
        std.debug.print("SSE_DEBUG: getLatestMessage failed for session {s}: {s}\n", .{ session_id, @errorName(err) });
        return;
    };
    if (latestMessage) |msg| {
        std.debug.print("SSE_DEBUG: sending SSE for session {s}, content='{s}'\n", .{ session_id, if (msg.response_content.len > 50) msg.response_content[0..50] else msg.response_content });

        const session_skills_tool = llm_history.getSessionSkills(allocator, db, session_id) catch null;
        defer if (session_skills_tool) |s| for (s) |*skill| {
            allocator.free(skill.skill_name);
            allocator.free(skill.content);
        };

        onEventSendLLMHistory(allocator, .{
            .id = msg.id,
            .session_id = msg.session_id,
            .model = msg.model,
            .cwd = cwd,
            .content = msg.response_content,
            .reasoning_content = msg.reasoning_content,
            .role = msg.role,
            .finish_reason = msg.finish_reason,
            .tool_calls_json = tool_calls_json,
            .tool_call_id = msg.tool_call_id orelse msg.id,
            .tool_name = msg.tool_name,
            .agent_name = agent_name,
            .loop_index = msg.loop_index,
            .temperature = temperature,
            .is_thinking = is_thinking,
            .is_input = is_input,
            .is_output = is_output,
            .parent_session_id = parent_session_id,
            .parent_id = session_id,
            .diffview_before = msg.diffview_before,
            .diffview_after = msg.diffview_after,
            .total_tokens = msg.total_tokens,
            .image_url = null,
            .session_skills = session_skills_tool,
        }) catch |err| {
            std.debug.print("SSE_DEBUG: on_event_send_new failed for session {s}: {s}\n", .{ session_id, @errorName(err) });
        };
    } else {
        std.debug.print("SSE_DEBUG: no latest message found for session {s}\n", .{session_id});
    }
}

test "parseDiffViewFromResult - no diff_view returns allocated copy" {
    const content = "File modified successfully";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(!result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, content));
    try std.testing.expect(result.before == null);
    try std.testing.expect(result.after == null);

    // ALWAYS free the allocated content
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - empty diff_view at end returns content before diff_view" {
    const content = "Success<diff_view></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "Success"));
    try std.testing.expect(result.before == null);
    try std.testing.expect(result.after == null);

    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - extracts before and after content" {
    const content = "Success<diff_view><before>old content</before><after>new content</after></diff_view>!";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "Success!"));
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "old content"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "new content"));

    // before / after are always allocated when diff_view_found=true
    // (so xmlUnescape can transform entities).
    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - extracts multiline before and after" {
    const content = "Result:<diff_view><before>line1\nline2\nline3</before><after>line1\nmodified\nline3</after></diff_view>:end";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "Result::end"));
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "line1\nline2\nline3"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "line1\nmodified\nline3"));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - only before tag extracts correctly" {
    const content = "Done<diff_view><before>original</before></diff_view>!";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "Done!"));
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "original"));
    try std.testing.expect(result.after == null);

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - only after tag extracts correctly" {
    const content = "Done<diff_view><after>replacement</after></diff_view>!";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "Done!"));
    try std.testing.expect(result.before == null);
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "replacement"));

    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - missing closing tag returns allocated copy" {
    const content = "Result<diff_view><before>old</before><after>new</after>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(!result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, content));
    try std.testing.expect(result.before == null);
    try std.testing.expect(result.after == null);

    // ALWAYS free the allocated content
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - missing opening tag returns allocated copy" {
    const content = "Result<before>old</before><after>new</after></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(!result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, content));
    try std.testing.expect(result.before == null);
    try std.testing.expect(result.after == null);

    // ALWAYS free the allocated content
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - empty before and after tags" {
    const content = "Empty<diff_view><before></before><after></after></diff_view>!";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "Empty!"));
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, ""));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, ""));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - before/after at boundaries" {
    const content = "<diff_view><before>start</before><after>end</after></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, ""));
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "start"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "end"));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - diff_view in middle of content" {
    const content = "prefix <diff_view><before>a</before><after>b</after></diff_view> suffix";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "prefix  suffix"));
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "a"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "b"));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

// ============================================================================
// XML unescape regression tests (bug: "diff view shows &quot; instead of \"")
// ============================================================================

test "parseDiffViewFromResult - unescapes &quot; in before/after (regression)" {
    // XML-escaped content (as produced by xmlEscape) must be un-escaped before
    // being stored, so the diff view renders the original characters.
    const content =
        "<diff_view><before>const a = &quot;hello&quot;;</before>" ++
        "<after>const a = &quot;world&quot;;</after></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "const a = \"hello\";"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "const a = \"world\";"));

    // Caller MUST free before/after when diff_view_found is true.
    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - unescapes all 5 XML entities" {
    const content =
        "<diff_view><before>" ++
        "&lt;a&gt; &amp; &quot;b&quot; &apos;c&apos;" ++
        "</before><after>" ++
        "&lt;x&gt; &amp; &quot;y&quot; &apos;z&apos;" ++
        "</after></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "<a> & \"b\" 'c'"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "<x> & \"y\" 'z'"));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - no entities, content unchanged (fast path)" {
    // When there's no `&` at all, before/after should be allocated copies
    // with the original content unchanged (fast path in xmlUnescape).
    const content =
        "<diff_view><before>plain text content</before>" ++
        "<after>more plain text</after></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "plain text content"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "more plain text"));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - decodes &amp; LAST (no double-decoding)" {
    // `&amp;quot;` is the literal 6-byte sequence representing the entity
    // `&quot;` — NOT a double-encoded `"`. The &amp; replacement must come
    // last, otherwise the prior passes would convert `&amp;quot;` → `"`.
    // Correct: `&amp;quot;` → `&quot;` (literal 6 chars).
    const content =
        "<diff_view><before>encoded &amp;quot;quote&amp;quot;</before></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "encoded &quot;quote&quot;"));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - unescapes multiline content with entities" {
    const content =
        "<diff_view><before>const fn = &lt;T&gt;(a: &amp;T) {\n" ++
        "  return a.toString();\n}</before>" ++
        "<after>const fn = &lt;T&gt;(a: &amp;T) {\n" ++
        "  return a.serialize();\n}</after></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(
        u8,
        result.before.?,
        "const fn = <T>(a: &T) {\n  return a.toString();\n}",
    ));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(
        u8,
        result.after.?,
        "const fn = <T>(a: &T) {\n  return a.serialize();\n}",
    ));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

// =============================================================================
// Static-contract tests — Phase 1 placeholder envelope.
//
// 2026-08-24-better-tool-placeholder: Phase 1 inserts used to store
// raw text in `response_content` (`"unknown tools"` for unknown tools,
// `""` for known tools). On page-refresh-mid-execution or restart the
// frontend's `tryUnwrapToolOutput` couldn't parse the row, fell back
// to `msg.content`, and rendered a blank/garbage card. The fix pipes
// every Phase 1 placeholder through `wrapToolOutput` so the envelope
// shape is stable across all 3 phases.
//
// These tests pin the contract: grep the source for the required
// emission sites. If a future refactor accidentally swaps back to a
// raw-string placeholder, or skips the unknown-tool error path, the
// chat card regression returns and these tests fail closed.
// =============================================================================

const placeholder_impl_path = "src/agentic_loop/handle_tool.zig";

test "Phase 1 placeholder uses wrapToolOutput for both known + unknown branches" {
    // Reads THIS file at runtime via a known repo-root-relative path,
    // matching the technique used in tools_exec_spawn_sub_agent.zig's
    // static-contract tests and design_model_group_test.zig.
    const max_bytes: usize = 1 * 1024 * 1024; // 1 MiB ceiling
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        placeholder_impl_path,
        std.testing.allocator,
        .limited(max_bytes),
    );
    defer std.testing.allocator.free(source);

    // Two wrapToolOutput call sites inside the Phase 1 for-loop:
    //   - success=false envelope (unknown tools branch)
    //   - success=true  envelope (known tools branch — the normal case)
    // plus the existing 3 in Phase 3 (MCP error, dispatch error,
    // MCP success = 3) = 5 baseline. Bump this bound in lock-step
    // with future Phase 1/3 wrapToolOutput additions.
    const wrap_count = std.mem.count(u8, source, "wrapToolOutput(");
    try std.testing.expect(wrap_count >= 5);

    // Unknown tools MUST emit a failure envelope so the frontend
    // renders a structured error block (not a raw "unknown tools"
    // text bubble). Asserts on the literal `"unknown tools"` arg
    // passed to the `error_message` slot of wrapToolOutput.
    try std.testing.expect(std.mem.indexOf(u8, source, "\"unknown tools\",") != null);

    // The bare-`""` literal that used to be assigned directly to
    // `response_content = ""` must NOT survive in Phase 1. Any
    // match here is a regression to the legacy behaviour.
    try std.testing.expect(std.mem.indexOf(u8, source, ".response_content = \"\",") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".response_content = \"unknown tools\",") == null);
}

test "wrapToolOutput envelope is round-trip parseable (envelope shape vs frontend)" {
    // Sanity: the known-tool branch envelope can be parsed by the
    // frontend's `unwrapToolOutput` shape (name + parameters +
    // success=true + data=""). Mirrors the wire contract that
    // tools_wrap_output.zig's own tests pin — Phase 1 doesn't need
    // to re-test `wrapToolOutput` itself, just the Phase 1 pick of
    // arguments.
    const envelope = try wrapToolOutput(
        std.testing.allocator,
        "read_file",
        "{\"path\":\"/tmp/foo.txt\"}",
        true,
        null,
        "",
    );
    defer std.testing.allocator.free(envelope);

    try std.testing.expect(std.mem.indexOf(u8, envelope, "<tool>") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "<name>read_file</name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "<parameters><path>/tmp/foo.txt</path></parameters>") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "<success>true</success>") != null);
    // Empty data — Phase 3 will UPDATE this row with the real result.
    try std.testing.expect(std.mem.indexOf(u8, envelope, "<data></data>") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "<error>") == null);

    // Unknown tool branch envelope: success=false, error="unknown tools".
    const err_envelope = try wrapToolOutput(
        std.testing.allocator,
        "totally_made_up_tool",
        "{}",
        false,
        "unknown tools",
        "",
    );
    defer std.testing.allocator.free(err_envelope);

    try std.testing.expect(std.mem.indexOf(u8, err_envelope, "<name>totally_made_up_tool</name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_envelope, "<success>false</success>") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_envelope, "<error>unknown tools</error>") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_envelope, "<data>") == null);
}

// ============================================================================
// Lua hook seam tests (plan 2026-09-12-hook-lua-pre-post-tool-use, Phase 3)
// ============================================================================
//
// These cover runPreHookAction / runPostHookOverride — the exact helpers
// dispatchTool and the MCP branch call. The helpers only touch
// allocator/logger/environment, so db/config/loops stay `undefined`
// (never dereferenced on these paths; a future touch would crash loudly).
// End-to-end exec-skipping is covered by tests/functional/hooks_lua_test.py.

/// Minimal ToolContext for hook tests: only allocator/logger/environment
/// (+ identity strings) are read by the hook path.
fn hookTestCtx(
    allocator: std.mem.Allocator,
    logger: *logger_mod.Logger,
    environment: ?*const std.process.Environ.Map,
) ToolContext {
    var temp: f32 = 0.4;
    var thinking: bool = false;
    return ToolContext{
        .allocator = allocator,
        .io = std.testing.io,
        .db = undefined,
        .logger = logger,
        .session_id = "sess_hook_test",
        .model = "test-model",
        .cwd = "/tmp",
        .api_key = "",
        .base_url = "",
        .config = undefined,
        .agent_temperature = &temp,
        .is_thinking = &thinking,
        .environment = environment,
        .active_loops = undefined,
    };
}

/// HOME=tmpdir with hooks/register_hook.lua containing `lua_source`.
/// Returns the env map (caller frees map + tmpdir via cleanup).
const HookFixture = struct {
    env_map: std.process.Environ.Map,
    tmp: std.testing.TmpDir,
    home: []const u8, // slice into path_buf below — keep alive via tmp

    fn deinit(self: *HookFixture) void {
        self.env_map.deinit();
        self.tmp.cleanup();
    }
};

fn hookFixture(allocator: std.mem.Allocator, lua_source: []const u8, path_buf: *[std.Io.Dir.max_path_bytes]u8) !HookFixture {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const n = try tmp.dir.realPath(std.testing.io, path_buf);
    const home = path_buf[0..n];
    try tmp.dir.createDirPath(std.testing.io, ".config/nalar/hooks");
    var hooks_dir = try tmp.dir.openDir(std.testing.io, ".config/nalar/hooks", .{});
    defer hooks_dir.close(std.testing.io);
    try hooks_dir.writeFile(std.testing.io, .{ .sub_path = hooks.HOOK_FILENAME, .data = lua_source });
    var env_map = std.process.Environ.Map.init(allocator);
    errdefer env_map.deinit();
    try env_map.put("HOME", home);
    return HookFixture{ .env_map = env_map, .tmp = tmp, .home = home };
}

test "hook seam: no hook file proceeds without touching exec deps" {
    const allocator = std.testing.allocator;
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var empty_tmp = std.testing.tmpDir(.{});
    defer empty_tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try empty_tmp.dir.realPath(std.testing.io, &path_buf);
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", path_buf[0..n]);

    const ctx = hookTestCtx(allocator, &lg, &env_map);
    const action = runPreHookAction(ctx, "bash", "{}");
    try std.testing.expect(action == .proceed);
    try std.testing.expect(runPostHookOverride(ctx, "bash", "{}", "some output") == null);
}

test "hook seam: pre deny short-circuits with error envelope" {
    const allocator = std.testing.allocator;
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fx = try hookFixture(allocator, "function init(event, data) if event == 'pre_tool_use' then return { deny = 'blocked by hook' } end return nil end\n", &path_buf);
    defer fx.deinit();

    const ctx = hookTestCtx(allocator, &lg, &fx.env_map);
    const action = runPreHookAction(ctx, "bash", "{}");
    try std.testing.expect(action == .short_circuit);
    defer allocator.free(action.short_circuit);
    try std.testing.expect(std.mem.indexOf(u8, action.short_circuit, "<success>false</success>") != null);
    try std.testing.expect(std.mem.indexOf(u8, action.short_circuit, "blocked by hook") != null);
}

test "hook seam: pre modify rewrites args" {
    const allocator = std.testing.allocator;
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fx = try hookFixture(allocator, "function init(event, data) return { arguments = '{\"command\":\"echo safe\"}' } end\n", &path_buf);
    defer fx.deinit();

    const ctx = hookTestCtx(allocator, &lg, &fx.env_map);
    const action = runPreHookAction(ctx, "bash", "{\"command\":\"rm -rf /\"}");
    try std.testing.expect(action == .proceed_modified);
    defer allocator.free(action.proceed_modified);
    try std.testing.expectEqualStrings("{\"command\":\"echo safe\"}", action.proceed_modified);
}

test "hook seam: pre mock returns success envelope" {
    const allocator = std.testing.allocator;
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fx = try hookFixture(allocator, "function init(event, data) return { output = 'mocked output' } end\n", &path_buf);
    defer fx.deinit();

    const ctx = hookTestCtx(allocator, &lg, &fx.env_map);
    const action = runPreHookAction(ctx, "bash", "{}");
    try std.testing.expect(action == .short_circuit);
    defer allocator.free(action.short_circuit);
    try std.testing.expect(std.mem.indexOf(u8, action.short_circuit, "<success>true</success>") != null);
    try std.testing.expect(std.mem.indexOf(u8, action.short_circuit, "mocked output") != null);
}

test "hook seam: post replace swaps output" {
    const allocator = std.testing.allocator;
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fx = try hookFixture(allocator, "function init(event, data) if event == 'post_tool_use' then return { output = 'redacted' } end return nil end\n", &path_buf);
    defer fx.deinit();

    const ctx = hookTestCtx(allocator, &lg, &fx.env_map);
    const replacement = runPostHookOverride(ctx, "bash", "{}", "secret=abc");
    try std.testing.expect(replacement != null);
    defer allocator.free(replacement.?);
    try std.testing.expectEqualStrings("redacted", replacement.?);
}

test "hook seam: broken hook file fails open to proceed/keep" {
    const allocator = std.testing.allocator;
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fx = try hookFixture(allocator, "function init(((\n", &path_buf);
    defer fx.deinit();

    const ctx = hookTestCtx(allocator, &lg, &fx.env_map);
    try std.testing.expect(runPreHookAction(ctx, "bash", "{}") == .proceed);
    try std.testing.expect(runPostHookOverride(ctx, "bash", "{}", "out") == null);
}

// ============================================================================
// Lua hook dispatch tests: real registry + real read_file exec + real Lua.
// A real in-memory DB is provided (read_file ignores it); config stays
// undefined because read_file always hits the registry (config is only
// read on registry miss). These prove the wiring, not just the helpers.
// ============================================================================

const HookDispatchCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn hookDispatchSetup() !HookDispatchCtx {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    return .{ .db = db, .threaded = threaded };
}

fn hookDispatchCtx(
    allocator: std.mem.Allocator,
    setup: *HookDispatchCtx,
    logger: *logger_mod.Logger,
    environment: ?*const std.process.Environ.Map,
) ToolContext {
    var temp: f32 = 0.4;
    var thinking: bool = false;
    return ToolContext{
        .allocator = allocator,
        .io = setup.threaded.io(),
        .db = &setup.db,
        .logger = logger,
        .session_id = "sess_hook_dispatch",
        .model = "test-model",
        .cwd = "/tmp",
        .api_key = "",
        .base_url = "",
        .config = undefined,
        .agent_temperature = &temp,
        .is_thinking = &thinking,
        .environment = environment,
        .active_loops = undefined,
    };
}

fn readFileCall(allocator: std.mem.Allocator, path: []const u8) !agent.ToolCall {
    const args = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{path});
    return agent.ToolCall{ .id = "call_hook_dispatch", .function = .{ .name = "read_file", .arguments = args } };
}

test "hook dispatch: no hook runs real read_file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const dispatch_alloc = arena.allocator();
    var lg = logger_mod.Logger.init(dispatch_alloc, std.testing.io, .{});
    var setup = try hookDispatchSetup();
    defer setup.threaded.deinit();
    defer setup.db.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "real.txt", .data = "REAL CONTENT" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const abs = try std.fs.path.join(dispatch_alloc, &.{ path_buf[0..n], "real.txt" });

    var empty_tmp = std.testing.tmpDir(.{});
    defer empty_tmp.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const hn = try empty_tmp.dir.realPath(std.testing.io, &home_buf);
    var env_map = std.process.Environ.Map.init(dispatch_alloc);
    defer env_map.deinit();
    try env_map.put("HOME", home_buf[0..hn]);

    const ctx = hookDispatchCtx(dispatch_alloc, &setup, &lg, &env_map);
    const tc = try readFileCall(dispatch_alloc, abs);
    const result = try dispatchTool(ctx, tc);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "REAL CONTENT") != null);
}

test "hook dispatch: pre deny skips exec (missing file still denies)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const dispatch_alloc = arena.allocator();
    var lg = logger_mod.Logger.init(dispatch_alloc, std.testing.io, .{});
    var setup = try hookDispatchSetup();
    defer setup.threaded.deinit();
    defer setup.db.deinit();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fx = try hookFixture(dispatch_alloc, "function init(event, data) if event == 'pre_tool_use' and data.tool_name == 'read_file' then return { deny = 'reads blocked' } end return nil end\n", &path_buf);
    defer fx.deinit();

    const ctx = hookDispatchCtx(dispatch_alloc, &setup, &lg, &fx.env_map);
    // Points at a file that does not exist: without the hook this would
    // be a read_file error envelope, with the hook it must be the deny.
    const tc = try readFileCall(dispatch_alloc, "/tmp/nalar-hook-test-does-not-exist-12345.txt");
    const result = try dispatchTool(ctx, tc);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "<success>false</success>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "reads blocked") != null);
}

test "hook dispatch: pre modify rewrites args seen by exec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const dispatch_alloc = arena.allocator();
    var lg = logger_mod.Logger.init(dispatch_alloc, std.testing.io, .{});
    var setup = try hookDispatchSetup();
    defer setup.threaded.deinit();
    defer setup.db.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "other.txt", .data = "OTHER CONTENT" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const other_abs = try std.fs.path.join(dispatch_alloc, &.{ path_buf[0..n], "other.txt" });

    const lua_source = try std.fmt.allocPrint(dispatch_alloc, "function init(event, data) if event == 'pre_tool_use' then return {{ arguments = '{{\"path\":\"{s}\"}}' }} end return nil end\n", .{other_abs});
    var fx = try hookFixture(dispatch_alloc, lua_source, &path_buf);
    defer fx.deinit();

    const ctx = hookDispatchCtx(dispatch_alloc, &setup, &lg, &fx.env_map);
    const tc = try readFileCall(dispatch_alloc, "/tmp/nalar-hook-test-original-12345.txt");
    const result = try dispatchTool(ctx, tc);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "OTHER CONTENT") != null);
}

test "hook dispatch: post replace swaps real output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const dispatch_alloc = arena.allocator();
    var lg = logger_mod.Logger.init(dispatch_alloc, std.testing.io, .{});
    var setup = try hookDispatchSetup();
    defer setup.threaded.deinit();
    defer setup.db.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "secret.txt", .data = "TOP SECRET" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const abs = try std.fs.path.join(dispatch_alloc, &.{ path_buf[0..n], "secret.txt" });

    var fx = try hookFixture(dispatch_alloc, "function init(event, data) if event == 'post_tool_use' then return { output = 'REDACTED BY HOOK' } end return nil end\n", &path_buf);
    defer fx.deinit();

    const ctx = hookDispatchCtx(dispatch_alloc, &setup, &lg, &fx.env_map);
    const tc = try readFileCall(dispatch_alloc, abs);
    const result = try dispatchTool(ctx, tc);
    try std.testing.expectEqualStrings("REDACTED BY HOOK", result.output);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "TOP SECRET") == null);
}
