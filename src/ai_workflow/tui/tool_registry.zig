const std = @import("std");
const nalar_mod = @import("nalarcore");
const agent = nalar_mod.agent;
const tool_models = nalar_mod.tool_models;
const sqlite = nalar_mod.sqlite;
const logger_mod = nalar_mod.logger;
const config_mod = nalar_mod.config;
const spawn_sub_agent_tool = nalar_mod.spawn_sub_agent;
const llm_history = nalar_mod.llm_history;
const ai_workflow = nalar_mod.ai_workflow;

// Tool imports for exec functions and tool_defs
const bash_tool_mod = nalar_mod.bash_tool;
const read_file_mod = nalar_mod.read_file;
const text_replace_mod = nalar_mod.text_replace_tool;
const write_file_mod = nalar_mod.write_file;
const list_skills_mod = nalar_mod.list_skills_tool;
const get_skill_mod = nalar_mod.get_skill_tool;
const remove_skill_mod = nalar_mod.remove_skill_tool;
const list_agents_mod = nalar_mod.list_agents;
const add_skill_mod = nalar_mod.add_skill;
const add_agent_mod = nalar_mod.add_agent;
const remove_agent_mod = nalar_mod.remove_agent;
const remove_file_mod = nalar_mod.remove_file;
const change_agent_mod = nalar_mod.change_agent;
const lsp_definition_mod = nalar_mod.tools.lsp_definition;
const lsp_references_mod = nalar_mod.tools.lsp_references;
const lsp_workspace_symbol_mod = nalar_mod.tools.lsp_workspace_symbol;
const lsp_document_symbol_mod = nalar_mod.tools.lsp_document_symbol;
const lsp_hover_mod = nalar_mod.tools.lsp_hover;
const set_agent_properties_mod = nalar_mod.set_agent_properties;
const web_search_mod = nalar_mod.web_search;
const update_activity_mod = nalar_mod.update_activity;
const glob_tool_mod = nalar_mod.glob_tool;
const search_tool_mod = nalar_mod.search_tool;

// Handle tool imports for exec functions
const background_process = @import("background_process.zig");

// ============================================================================
// CODE EXEC TOOL TYPES AND FUNCTIONS
// ============================================================================

/// Context passed to all tool handlers (shared between tool_registry and handle_tool)
pub const ToolExecContext = struct {
    allocator: std.mem.Allocator,
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
};

/// Tool execution result with optional agent state changes
pub const ToolExecResult = struct {
    output: []const u8,
    /// If true, the caller must free output with allocator.free()
    output_allocated: bool = false,
    temperature: ?f32 = null,
    is_thinking: ?bool = null,
    skill_save: ?SkillSaveInfo = null,
    agent_save: ?AgentSaveInfo = null,

    pub fn deinit(self: *const ToolExecResult, allocator: std.mem.Allocator) void {
        if (self.output_allocated) {
            allocator.free(self.output);
        }
    }
};

/// Legacy alias for backward compatibility
pub const SubAgentToolResult = ToolExecResult;

/// Function signature for tool executors
/// Takes full context to enable tools like set_agent_properties and spawn_sub_agent
pub const ToolExecFunc = *const fn (ctx: ToolExecContext, tc: agent.ToolCall) anyerror!ToolExecResult;

/// Legacy alias for backward compatibility
pub const SubAgentToolExec = ToolExecFunc;

pub const SkillSaveInfo = struct {
    name: []const u8,
    content: []const u8,
};

pub const AgentSaveInfo = struct {
    name: []const u8,
};

// ============================================================================
// BASH TOOL EXECUTION
// ============================================================================

/// Run with database context for background process tracking
pub fn runWithContext(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
    db: ?*sqlite.SqliteBackend,
    session_id: ?[]const u8,
) ![]const u8 {
    // Parse arguments JSON to BashInput
    const parsed = try std.json.parseFromSlice(
        tool_models.BashInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const is_background = parsed.value.background;

    const bash_output = try bash_tool_mod.execute_bash(allocator, parsed.value);

    // If background mode and DB is available, save the process info
    if (is_background and db != null and session_id != null) {
        const db_ptr = db.?;
        const sess_id = session_id.?;

        // Parse PID from bash output (format: "PID: {pid}\nLog: {path}")
        const stdout = bash_output.stdout;
        if (stdout.len > 5) {
            // Skip "PID: " prefix
            const pid_start = 5;
            var pid_end: usize = 4;
            while (pid_end < stdout.len and stdout[pid_end] != '\n') : (pid_end += 1) {}

            if (pid_end > pid_start) {
                const pid_str = stdout[pid_start..pid_end];
                const pid = std.fmt.parseInt(u32, pid_str, 10) catch 0;

                if (pid > 0) {
                    // Extract log path from "Log: {path}" part
                    var log_start: usize = 0;
                    while (log_start < stdout.len and stdout[log_start] != '\n') : (log_start += 1) {}
                    log_start += 1; // skip newline

                    // Find "Log: " prefix
                    var log_path_start = log_start;
                    while (log_path_start < stdout.len and log_path_start < log_start + 5) : (log_path_start += 1) {}

                    if (log_path_start < stdout.len) {
                        const log_path = stdout[log_path_start..];

                        // Save to database
                        const started_at = std.time.timestamp();
                        background_process.save(db_ptr, allocator, sess_id, pid, parsed.value.command, log_path, started_at) catch {
                            // Log error but don't fail the tool execution
                        };
                    }
                }
            }
        }
    }

    const res_bash = try bash_tool_mod.bash_result_to_string(allocator, bash_output);

    return res_bash;
}

// Individual tool executors - all use unified ToolExecFunc signature

pub fn execBash(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const output = try runWithContext(ctx.allocator, tc, ctx.db, ctx.session_id);
    return ToolExecResult{ .output = output };
}

pub fn execReadFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = ctx.db;
    _ = ctx.session_id;

    // Parse arguments JSON to ReadFileInput
    const parsed = try std.json.parseFromSlice(
        tool_models.ReadFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const read_opts = read_file_mod.ReadFileOptions{
        .offset = parsed.value.offset,
        .limit = parsed.value.limit,
        .show_line_numbers = parsed.value.show_line_numbers,
    };

    const read_result = try read_file_mod.read_file(ctx.allocator, parsed.value.path, read_opts);
    defer read_result.deinit(ctx.allocator);

    // Single allocation: combines path and content into XML result
    const output = try read_file_mod.to_xml(ctx.allocator, read_result, parsed.value.path);
    return ToolExecResult{ .output = output };
}

pub fn execTextReplace(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // Check for empty arguments first
    if (tc.function.arguments.len == 0) {
        const output = try std.fmt.allocPrint(ctx.allocator,
            \\<error>text_replace failed: Missing arguments (empty JSON)</error>
            \\<path></path>
            \\<old_str></old_str>
            \\<new_str></new_str>
            \\<success>false</success>
        , .{});
        return ToolExecResult{ .output = output };
    }

    const parsed = std.json.parseFromSlice(
        text_replace_mod.TextReplaceInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg: []const u8 = switch (err) {
            error.UnexpectedEndOfInput => "text_replace failed: UnexpectedEndOfInput - arguments may be incomplete or malformed",
            else => "text_replace failed: Invalid JSON arguments",
        };
        const output = try std.fmt.allocPrint(ctx.allocator,
            \\<error>{s}</error>
            \\<path></path>
            \\<old_str></old_str>
            \\<new_str></new_str>
            \\<success>false</success>
        , .{err_msg});
        return ToolExecResult{ .output = output };
    };
    defer parsed.deinit();

    const result = text_replace_mod.text_replace(
        ctx.allocator,
        parsed.value.path,
        parsed.value.old_str,
        parsed.value.new_str,
    ) catch |err| {
        const output = text_replace_mod.toXmlError(
            ctx.allocator,
            err,
            parsed.value.path,
            parsed.value.old_str,
        );
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const output = text_replace_mod.toXmlSuccess(ctx.allocator, result, parsed.value.path);
    return ToolExecResult{ .output = output };
}

pub fn execWriteFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = try std.json.parseFromSlice(
        write_file_mod.WriteFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const write_result = write_file_mod.write_file(ctx.allocator, parsed.value) catch |err| {
        const output = write_file_mod.toXmlError(ctx.allocator, err, parsed.value.path);
        return ToolExecResult{ .output = output };
    };
    const res_write = write_file_mod.toXmlSuccess(ctx.allocator, write_result);
    write_result.deinit(ctx.allocator);

    return ToolExecResult{ .output = res_write };
}

pub fn execListSkills(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = tc;

    const output = list_skills_mod.execute_list_skills(ctx.allocator) catch blk: {
        break :blk try std.fmt.allocPrint(ctx.allocator, "{{\"error\": \"Failed to list skills\"}}", .{});
    };
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execGetSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        get_skill_mod.GetSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        const output = "<skill_name></skill_name><content></content><loaded>false</loaded><error>Failed to parse get_skill arguments</error>";
        return ToolExecResult{ .output = output };
    };
    defer parsed.deinit();

    const output = get_skill_mod.execute_get_skill_to_string(ctx.allocator, parsed.value) catch {
        return ToolExecResult{ .output = "<skill_name></skill_name><content></content><loaded>false</loaded><error>Failed to get skill</error>" };
    };
    return ToolExecResult{ .output = output };
}

pub fn execRemoveSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        remove_skill_mod.RemoveSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        const output = try std.fmt.allocPrint(ctx.allocator,
            \\<skill_name></skill_name>
            \\<removed>false</removed>
            \\<error>Failed to parse remove_skill arguments</error>
        , .{});
        return ToolExecResult{ .output = output };
    };
    defer parsed.deinit();

    const output = remove_skill_mod.execute_remove_skill_to_string(ctx.allocator, parsed.value) catch {
        const out = try std.fmt.allocPrint(ctx.allocator,
            \\<skill_name>{s}</skill_name>
            \\<removed>false</removed>
            \\<error>Unknown error</error>
        , .{parsed.value.skill_name});
        return ToolExecResult{ .output = out };
    };
    return ToolExecResult{ .output = output };
}

pub fn execAddSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        add_skill_mod.AddSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        const output = try std.fmt.allocPrint(ctx.allocator,
            \\<skill>
            \\<name></name>
            \\<created>false</created>
            \\<error>Failed to parse add_skill arguments</error>
            \\</skill>
        , .{});
        return ToolExecResult{ .output = output };
    };
    defer parsed.deinit();

    const output = add_skill_mod.executeAddSkillToString(ctx.allocator, parsed.value) catch {
        const out = try std.fmt.allocPrint(ctx.allocator,
            \\<skill>
            \\<name>{s}</name>
            \\<created>false</created>
            \\<error>Failed to add skill</error>
            \\</skill>
        , .{parsed.value.name});
        return ToolExecResult{ .output = out };
    };
    return ToolExecResult{ .output = output };
}

pub fn execAddAgent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        add_agent_mod.AddAgentInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        const output = try std.fmt.allocPrint(ctx.allocator,
            \\<agent>
            \\<name></name>
            \\<created>false</created>
            \\<error>Failed to parse add_agent arguments</error>
            \\</agent>
        , .{});
        return ToolExecResult{ .output = output };
    };
    defer parsed.deinit();

    const output = add_agent_mod.executeAddAgentToString(ctx.allocator, parsed.value) catch {
        const out = try std.fmt.allocPrint(ctx.allocator,
            \\<agent>
            \\<name>{s}</name>
            \\<created>false</created>
            \\<error>Failed to add agent</error>
            \\</agent>
        , .{parsed.value.name});
        return ToolExecResult{ .output = out };
    };
    return ToolExecResult{ .output = output };
}

pub fn execRemoveAgent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        remove_agent_mod.RemoveAgentInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        const output = try std.fmt.allocPrint(ctx.allocator,
            \\<name></name>
            \\<removed>false</removed>
            \\<error>Failed to parse remove_agent arguments</error>
        , .{});
        return ToolExecResult{ .output = output };
    };
    errdefer parsed.deinit();

    const output = remove_agent_mod.execute_remove_agent_to_string(ctx.allocator, parsed.value) catch {
        const out = try std.fmt.allocPrint(ctx.allocator,
            \\<name>{s}</name>
            \\<removed>false</removed>
            \\<error>Failed to remove agent</error>
        , .{parsed.value.name});
        return ToolExecResult{ .output = out };
    };
    parsed.deinit();
    return ToolExecResult{ .output = output };
}

pub fn execRemoveFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        remove_file_mod.RemoveFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        const output = try std.fmt.allocPrint(ctx.allocator,
            \\<path></path>
            \\<deleted>false</deleted>
            \\<error>Failed to parse remove_file arguments</error>
        , .{});
        return ToolExecResult{ .output = output };
    };
    errdefer parsed.deinit();

    const output = remove_file_mod.executeRemoveFileToString(ctx.allocator, parsed.value) catch {
        const out = try std.fmt.allocPrint(ctx.allocator,
            \\<path></path>
            \\<deleted>false</deleted>
            \\<error>Failed to remove file</error>
        , .{});
        return ToolExecResult{ .output = out };
    };
    parsed.deinit();
    return ToolExecResult{ .output = output };
}

pub fn execListAgents(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = tc;

    const output = list_agents_mod.executeListAgents(ctx.allocator) catch {
        const out = try std.fmt.allocPrint(ctx.allocator,
            \\<agents>
            \\  <error>Failed to list agents</error>
            \\</agents>
        , .{});
        return ToolExecResult{ .output = out };
    };
    return ToolExecResult{ .output = output };
}

pub fn execChangeAgent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        change_agent_mod.ChangeAgentInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        const output = try std.fmt.allocPrint(ctx.allocator,
            \\<agent>
            \\  <agent_name></agent_name>
            \\  <content></content>
            \\  <loaded>false</loaded>
            \\  <error>Failed to parse change_agent arguments</error>
            \\</agent>
        , .{});
        return ToolExecResult{ .output = output };
    };
    defer parsed.deinit();

    const output = change_agent_mod.execute_change_agent_to_string(ctx.allocator, parsed.value) catch {
        const out = try std.fmt.allocPrint(ctx.allocator,
            \\<agent>
            \\  <agent_name></agent_name>
            \\  <content></content>
            \\  <loaded>false</loaded>
            \\  <error>Failed to get agent</error>
            \\</agent>
        , .{});
        return ToolExecResult{ .output = out };
    };
    return ToolExecResult{ .output = output };
}

pub fn execLspDefinition(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        lsp_definition_mod.LspDefinitionInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const output = try std.fmt.allocPrint(
            ctx.allocator,
            "<error>Failed to parse lsp_definition arguments: {s}</error>",
            .{@errorName(err)},
        );
        return ToolExecResult{ .output = output };
    };
    defer parsed.deinit();

    const result = lsp_definition_mod.execute_lsp_definition(ctx.allocator, parsed.value) catch |err| {
        const output = try std.fmt.allocPrint(
            ctx.allocator,
            "<error>Failed to get definition: {s}</error>",
            .{@errorName(err)},
        );
        return ToolExecResult{ .output = output };
    };
    defer result.deinit(ctx.allocator);

    const output = try lsp_definition_mod.lsp_definition_to_string(ctx.allocator, result);
    return ToolExecResult{ .output = output };
}

// set_agent_properties implementation - modifies agent temperature/is_thinking
pub fn execSetAgentProperties(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const result = try handleSetAgentProperties(ctx.allocator, tc);

    return ToolExecResult{
        .output = result.arguments,
        .temperature = result.temperature,
        .is_thinking = result.is_thinking,
    };
}

/// Result of parsing set_agent_properties arguments
pub const SetAgentPropertiesResult = struct {
    temperature: ?f32,
    is_thinking: ?bool,
    tool_call_id: []const u8,
    arguments: []const u8,
};

/// Stateless set_agent_properties tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// Returns SetAgentPropertiesResult with parsed data.
///
/// Note: All side effects (modifying temperature/is_thinking, DB, SSE) must be handled by caller.
fn handleSetAgentProperties(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) !SetAgentPropertiesResult {
    const parsed = try std.json.parseFromSlice(
        set_agent_properties_mod.SetAgentPropertiesResult,
        allocator,
        tool_call.function.arguments,
        .{},
    );
    defer parsed.deinit();

    const contentSetAgentProps = try std.fmt.allocPrint(
        allocator,
        "<set_agent_properties>\n{s}\n<set_agent_properties>",
        .{tool_call.function.arguments},
    );

    return SetAgentPropertiesResult{
        .temperature = parsed.value.temperature,
        .is_thinking = parsed.value.is_thinking,
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
        .arguments = contentSetAgentProps,
    };
}

// update_activity implementation - records thought as worker activity
pub fn execUpdateActivity(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    ctx.logger.debugFmt("[update_activity] Starting for session {s}", .{ctx.session_id}) catch {};

    const parsed = std.json.parseFromSlice(
        update_activity_mod.UpdateActivityInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        ctx.logger.errFmt("[update_activity] Failed to parse arguments for session {s}", .{ctx.session_id}) catch {};
        const output = try std.fmt.allocPrint(ctx.allocator,
            \\<update_activity>
            \\  <updated>false</updated>
            \\  <error>Failed to parse update_activity arguments</error>
            \\</update_activity>
        , .{});
        return ToolExecResult{ .output = output };
    };
    defer parsed.deinit();

    // Use session_id directly as worker_id (matches how worker is registered)
    const worker_id = try ctx.allocator.dupe(u8, ctx.session_id);
    defer ctx.allocator.free(worker_id);

    // Update worker activity with the thought
    if (llm_history.updateWorkerActivityWithDescription(ctx.allocator, ctx.db, worker_id, parsed.value.thought)) |_| {
        ctx.logger.infoFmt("[update_activity] Updated activity for {s}: {s}", .{ worker_id, parsed.value.thought }) catch {};
        const output = try std.fmt.allocPrint(ctx.allocator,
            \\<update_activity>
            \\  <updated>true</updated>
            \\  <thought>{s}</thought>
            \\</update_activity>
        , .{parsed.value.thought});
        return ToolExecResult{ .output = output };
    } else |err| {
        ctx.logger.errFmt("[update_activity] Failed to update worker activity for {s}: {}", .{ worker_id, err }) catch {};
        const output = try std.fmt.allocPrint(ctx.allocator,
            \\<update_activity>
            \\  <updated>false</updated>
            \\  <error>Failed to update worker activity</error>
            \\</update_activity>
        , .{});
        return ToolExecResult{ .output = output };
    }
}

// Heap-allocated struct for sub-agent thread arguments
// This avoids capturing pointers from stack frames that may become invalid
const SubAgentThreadArgs = struct {
    allocator: std.mem.Allocator,
    sqlite_db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    parent_sess_id: []const u8,
    agent_name: []const u8,
    instruction: []const u8,
    tools: ?[]const []const u8,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    config: *const config_mod.LlmConfig,
    cwd: []const u8,
    is_sub_agent: bool,
};

// spawn_sub_agent implementation - uses workflow.zig logic
pub fn execSpawnSubAgent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // Parse sub-agents from tool call arguments
    const parsed = try spawn_sub_agent_tool.parse_sub_agents(ctx.allocator, tc.function.arguments, 20);
    defer parsed.deinit(ctx.allocator);

    // Build results array for sub-agent outputs
    var results = std.ArrayList(u8).empty;
    defer results.deinit(ctx.allocator);
    const w = results.writer(ctx.allocator);

    // Run each sub-agent in its own thread
    var threads = std.ArrayList(std.Thread).empty;
    defer threads.deinit(ctx.allocator);

    const sub_agent_count = parsed.sub_agents.len;

    for (parsed.sub_agents, 0..) |sub_agent, _idx| {
        _ = _idx; // Index not needed

        // Allocate thread args on the heap to avoid pointer stability issues
        // This ensures the data remains valid even if stack frames are deallocated
        const args = try ctx.allocator.create(SubAgentThreadArgs);
        args.* = .{
            .allocator = ctx.allocator,
            .sqlite_db = ctx.db,
            .logger = ctx.logger,
            .parent_sess_id = ctx.session_id,
            .agent_name = sub_agent.name,
            .instruction = sub_agent.instruction,
            .tools = sub_agent.tools,
            .api_key = ctx.api_key,
            .model = ctx.model,
            .base_url = ctx.base_url,
            .config = ctx.config,
            .cwd = ctx.cwd,
            .is_sub_agent = true,
        };

        const thread = try std.Thread.spawn(.{}, struct {
            fn run(args_ptr: *SubAgentThreadArgs) void {
                defer {
                    // Clean up the heap-allocated args
                    args_ptr.allocator.destroy(args_ptr);
                }
                // Generate unique session ID for this sub-agent
                const sess_id = std.fmt.allocPrint(args_ptr.allocator, "subagent_{}_{s}", .{ std.time.nanoTimestamp(), args_ptr.agent_name }) catch return;
                defer args_ptr.allocator.free(sess_id);

                // Register sub-agent as worker
                llm_history.upsertWorker(args_ptr.allocator, args_ptr.sqlite_db, sess_id, sess_id, args_ptr.cwd) catch {};
                defer llm_history.removeWorker(args_ptr.allocator, args_ptr.sqlite_db, sess_id) catch {};

                var workflow = ai_workflow.TUIWorkflow.init(args_ptr.sqlite_db, args_ptr.logger);
                // Derive is_sub_agent from session_id - no need to pass it explicitly
                const is_sub_agent = std.mem.indexOf(u8, sess_id, "subagent") != null;
                workflow.run(.{
                    .parent_allocator = args_ptr.allocator,
                    .parent_session_id = args_ptr.parent_sess_id,
                    .session_id = sess_id,
                    .message = args_ptr.instruction,
                    .cwd = args_ptr.cwd,
                    .api_key = args_ptr.api_key,
                    .model = args_ptr.model,
                    .base_url = args_ptr.base_url,
                    .config = args_ptr.config,
                    .body = "",
                    .allowed_tools = if (args_ptr.tools) |tools|
                        blk: {
                            var tools_str = std.ArrayList(u8).empty;
                            for (tools, 0..) |tool, i| {
                                if (i > 0) tools_str.append(args_ptr.allocator, ',') catch break;
                                tools_str.appendSlice(args_ptr.allocator, tool) catch break;
                            }
                            break :blk tools_str.items;
                        }
                    else
                        "",
                    .is_sub_agent = is_sub_agent,
                }) catch {
                    // Capture error
                    return;
                };
            }
        }.run, .{args});

        try threads.append(ctx.allocator, thread);
    }

    // Wait for all threads to complete
    for (threads.items) |thread| {
        thread.join();
    }

    // Format results
    try w.print("Spawned {} sub-agent(s) - use /api/session to query results\n", .{sub_agent_count});

    return ToolExecResult{ .output = try results.toOwnedSlice(ctx.allocator) };
}

// Placeholder LSP exec functions
pub fn execLspReferences(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = ctx;
    _ = tc;
    const output = "lsp_references not implemented";
    return ToolExecResult{ .output = output };
}

pub fn execLspWorkspaceSymbol(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = ctx;
    _ = tc;
    const output = "lsp_workspace_symbol not implemented";
    return ToolExecResult{ .output = output };
}

pub fn execLspDocumentSymbol(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = ctx;
    _ = tc;
    const output = "lsp_document_symbol not implemented";
    return ToolExecResult{ .output = output };
}

pub fn execLspHover(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = ctx;
    _ = tc;
    const output = "lsp_hover not implemented";
    return ToolExecResult{ .output = output };
}

pub fn execWebSearch(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = try std.json.parseFromSlice(
        tool_models.WebSearchInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const result = try web_search_mod.execute_web_search(ctx.allocator, parsed.value);
    defer result.deinit(ctx.allocator);

    const output = try web_search_mod.web_search_result_to_string(ctx.allocator, result);
    return ToolExecResult{ .output = output };
}

pub fn execGlob(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const args = tc.function.arguments;
    const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;

    const parsed = try std.json.parseFromSlice(
        glob_tool_mod.GlobInput,
        ctx.allocator,
        args_to_parse,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    var glob_result = try glob_tool_mod.execute_glob(ctx.allocator, parsed.value);
    const res_glob = try glob_tool_mod.glob_result_to_string(ctx.allocator, glob_result);
    glob_result.deinit(ctx.allocator);

    return ToolExecResult{ .output = res_glob };
}

pub fn execSearch(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const args = tc.function.arguments;
    const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;

    const parsed = try std.json.parseFromSlice(
        search_tool_mod.SearchInput,
        ctx.allocator,
        args_to_parse,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    var search_result = search_tool_mod.execute_search(ctx.allocator, parsed.value) catch |err| {
        if (err == error.StdoutStreamTooLong) {
            const output = try ctx.allocator.dupe(u8,
                \\<warning>Search output exceeded max_output limit. Use a larger max_output value (e.g. 5242880 for 5MB), narrow your search path, or use a more specific pattern.</warning>
            );
            return ToolExecResult{ .output = output };
        }
        return err;
    };

    if (search_result.matches.items.len == 0) {
        const output = try ctx.allocator.dupe(u8, search_result.content);
        search_result.deinit(ctx.allocator);
        return ToolExecResult{ .output = output };
    }

    const res_search = try search_tool_mod.search_result_to_string_grouped(ctx.allocator, search_result);
    search_result.deinit(ctx.allocator);

    return ToolExecResult{ .output = res_search };
}

// ============================================================================
// UNIFIED TOOL REGISTRY - Single source of truth for ALL tool metadata
// ============================================================================

/// Metadata for each tool in the unified registry
pub const ToolInfo = struct {
    name: []const u8,
    exec: SubAgentToolExec,
    tool_def: tool_models.AgentTool,
    auto_save_skill: bool = false,
    auto_save_agent: bool = false,
};

/// The ONE registry for all tool metadata.
pub const UNIFIED_TOOL_REGISTRY: []const ToolInfo = &.{
    // === AGENT CONTROL (main agent only) ===
    .{ .name = "set_agent_properties", .exec = execSetAgentProperties, .tool_def = set_agent_properties_mod.set_agent_properties_tool },
    .{ .name = "spawn_sub_agent", .exec = execSpawnSubAgent, .tool_def = spawn_sub_agent_tool.spawn_sub_agent_tool },
    .{ .name = "update_activity", .exec = execUpdateActivity, .tool_def = update_activity_mod.update_activity_tool },

    // === AGENT MANAGEMENT (auto-save) ===
    .{ .name = "list_agents", .exec = execListAgents, .tool_def = list_agents_mod.list_agents_tool, .auto_save_agent = true },
    .{ .name = "change_agent", .exec = execChangeAgent, .tool_def = change_agent_mod.change_agent_tool, .auto_save_agent = true },
    .{ .name = "remove_agent", .exec = execRemoveAgent, .tool_def = remove_agent_mod.remove_agent_tool },

    // === SKILL MANAGEMENT ===
    .{ .name = "list_skills", .exec = execListSkills, .tool_def = list_skills_mod.list_skills_tool },
    .{ .name = "get_skill", .exec = execGetSkill, .tool_def = get_skill_mod.get_skill_tool, .auto_save_skill = true },
    .{ .name = "remove_skill", .exec = execRemoveSkill, .tool_def = remove_skill_mod.remove_skill_tool },

    // === SKILL/AGENT CREATION ===
    .{ .name = "add_skill", .exec = execAddSkill, .tool_def = add_skill_mod.add_skill_tool, .auto_save_skill = true },
    .{ .name = "add_agent", .exec = execAddAgent, .tool_def = add_agent_mod.add_agent_tool, .auto_save_agent = true },

    // === FILE OPERATIONS ===
    .{ .name = "bash", .exec = execBash, .tool_def = bash_tool_mod.bash_tool },
    .{ .name = "read_file", .exec = execReadFile, .tool_def = read_file_mod.read_file_tool },
    .{ .name = "write_file", .exec = execWriteFile, .tool_def = write_file_mod.write_file_tool },
    .{ .name = "text_replace", .exec = execTextReplace, .tool_def = text_replace_mod.text_replace_tool },
    .{ .name = "remove_file", .exec = execRemoveFile, .tool_def = remove_file_mod.remove_file_tool },

    // === LSP TOOLS ===
    .{ .name = "lsp_definition", .exec = execLspDefinition, .tool_def = lsp_definition_mod.lsp_definition_tool },
    .{ .name = "lsp_references", .exec = execLspReferences, .tool_def = lsp_references_mod.lsp_references_tool },
    .{ .name = "lsp_workspace_symbol", .exec = execLspWorkspaceSymbol, .tool_def = lsp_workspace_symbol_mod.lsp_workspace_symbol_tool },
    .{ .name = "lsp_document_symbol", .exec = execLspDocumentSymbol, .tool_def = lsp_document_symbol_mod.lsp_document_symbol_tool },
    .{ .name = "lsp_hover", .exec = execLspHover, .tool_def = lsp_hover_mod.lsp_hover_tool },

    // === WEB SEARCH TOOLS ===
    .{ .name = "web_search", .exec = execWebSearch, .tool_def = web_search_mod.web_search_tool },

    // === FILE SEARCH TOOLS ===
    .{ .name = "glob", .exec = execGlob, .tool_def = glob_tool_mod.glob_tool },
    .{ .name = "search", .exec = execSearch, .tool_def = search_tool_mod.search_tool },
};

// ============================================================================
// DERIVED REGISTRIES
// ============================================================================

/// Registry for main agent (all tools)
pub const MAIN_AGENT_TOOL_REGISTRY: []const ToolInfo = UNIFIED_TOOL_REGISTRY;

/// All tool definitions for the main agent
/// This is the canonical list of tool definitions for the main agent
pub const ALL_AGENT_TOOLS: []const tool_models.AgentTool = &.{
    set_agent_properties_mod.set_agent_properties_tool,
    spawn_sub_agent_tool.spawn_sub_agent_tool,
    update_activity_mod.update_activity_tool,
    list_agents_mod.list_agents_tool,
    change_agent_mod.change_agent_tool,
    remove_agent_mod.remove_agent_tool,
    list_skills_mod.list_skills_tool,
    get_skill_mod.get_skill_tool,
    remove_skill_mod.remove_skill_tool,
    add_skill_mod.add_skill_tool,
    add_agent_mod.add_agent_tool,
    bash_tool_mod.bash_tool,
    read_file_mod.read_file_tool,
    write_file_mod.write_file_tool,
    text_replace_mod.text_replace_tool,
    remove_file_mod.remove_file_tool,
    lsp_definition_mod.lsp_definition_tool,
    lsp_references_mod.lsp_references_tool,
    lsp_workspace_symbol_mod.lsp_workspace_symbol_tool,
    lsp_document_symbol_mod.lsp_document_symbol_tool,
    lsp_hover_mod.lsp_hover_tool,
    web_search_mod.web_search_tool,
    glob_tool_mod.glob_tool,
    search_tool_mod.search_tool,
};



/// Get tool metadata by name from registry
pub fn getToolByName(name: []const u8) ?*const ToolInfo {
    for (UNIFIED_TOOL_REGISTRY) |*tool| {
        if (std.mem.eql(u8, tool.name, name)) {
            return tool;
        }
    }
    return null;
}

/// Check if tool is known
pub fn isKnownTool(name: []const u8) bool {
    return getToolByName(name) != null;
}

/// Get all tool names
pub fn getToolNames() []const []const u8 {
    var names: [UNIFIED_TOOL_REGISTRY.len][]const u8 = undefined;
    for (UNIFIED_TOOL_REGISTRY, 0..) |tool, i| {
        names[i] = tool.name;
    }
    return &names;
}

// ============================================================================
// AUTO-SAVE PARSING HELPERS
// ============================================================================

pub fn parseSkillFromResult(result: []const u8) ?struct { name: []const u8, content: []const u8 } {
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

pub fn parseAgentFromResult(result: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, result, "<loaded>true</loaded>") == null) return null;

    const name_start = std.mem.indexOf(u8, result, "<agent_name>") orelse return null;
    const name_begin = name_start + "<agent_name>".len;
    const name_end = std.mem.indexOf(u8, result[name_begin..], "</agent_name>") orelse return null;
    return result[name_begin .. name_begin + name_end];
}
