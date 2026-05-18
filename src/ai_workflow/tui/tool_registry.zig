const std = @import("std");
const nalar_mod = @import("nalarcore");
const models = @import("models.zig");
const ai_workflow = @import("workflow.zig");
const agent = nalar_mod.agent;
const tool_models = nalar_mod.tool_models;
const sqlite = nalar_mod.sqlite;
const logger_mod = nalar_mod.logger;
const config_mod = nalar_mod.config;
const spawn_sub_agent_tool = nalar_mod.spawn_sub_agent;
const llm_history = nalar_mod.llm_history;

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
const edit_skill_mod = nalar_mod.edit_skill;
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
    active_loops: *models.ActiveLoops,
};

/// Tool execution result with optional agent state changes
pub const ToolExecResult = struct {
    output: []const u8,
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
    io: std.Io,
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

    const bash_output = try bash_tool_mod.execute_bash(allocator, io, parsed.value);

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
                        const ts = std.Io.Clock.now(.real, io);
                        const started_at: i64 = ts.toSeconds();
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
    const output = try runWithContext(ctx.allocator, ctx.io, tc, ctx.db, ctx.session_id);
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
    };

    const read_result = try read_file_mod.read_file(ctx.allocator, ctx.io, parsed.value.path, read_opts);
    defer read_result.deinit(ctx.allocator);

    // Single allocation: combines path and content into XML result
    const output = try read_file_mod.to_xml(ctx.allocator, read_result, parsed.value.path);
    return ToolExecResult{ .output = output };
}

pub fn execTextReplace(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // Check for empty arguments first
    if (tc.function.arguments.len == 0) {
        const output = text_replace_mod.xmlError(
            ctx.allocator,
            "text_replace failed: Missing arguments (empty JSON)",
            "",
            "",
            "",
        );
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
        const output = text_replace_mod.xmlError(ctx.allocator, err_msg, "", "", "");
        return ToolExecResult{ .output = output };
    };
    defer parsed.deinit();

    const result = text_replace_mod.executeTextReplace(
        ctx.allocator,
        ctx.io,
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
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execWriteFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = try std.json.parseFromSlice(
        write_file_mod.WriteFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const write_result = write_file_mod.write_file(ctx.allocator, ctx.io, parsed.value) catch |err| {
        const output = write_file_mod.toXmlError(ctx.allocator, err, parsed.value.path);
        return ToolExecResult{ .output = output };
    };
    const res_write = write_file_mod.toXmlSuccess(ctx.allocator, write_result);
    write_result.deinit(ctx.allocator);

    return ToolExecResult{ .output = res_write };
}

pub fn execListSkills(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = tc;

    const output = list_skills_mod.execute_list_skills(ctx.allocator, ctx.io, null, ctx.environment) catch blk: {
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

    const output = get_skill_mod.execute_get_skill_to_string(ctx.allocator, ctx.io, parsed.value, ctx.environment) catch {
        return ToolExecResult{ .output = "<skill_name></skill_name><content></content><loaded>false</loaded><error>Failed to get skill</error>" };
    };

    // Check if skill was successfully loaded and extract skill info for auto-save
    if (std.mem.indexOf(u8, output, "<loaded>true</loaded>") != null) {
        // Parse skill_name from XML output
        const name_start = std.mem.indexOf(u8, output, "<skill_name>") orelse {
            return ToolExecResult{ .output = output };
        };
        const name_begin = name_start + "<skill_name>".len;
        const name_end = std.mem.indexOf(u8, output[name_begin..], "</skill_name>") orelse {
            return ToolExecResult{ .output = output };
        };
        const skill_name = output[name_begin .. name_begin + name_end];

        // Parse content from XML output
        const content_start = std.mem.indexOf(u8, output, "<content>") orelse {
            return ToolExecResult{ .output = output };
        };
        const content_begin = content_start + "<content>".len;
        const content_end = std.mem.indexOf(u8, output[content_begin..], "</content>") orelse {
            return ToolExecResult{ .output = output };
        };
        const skill_content = output[content_begin .. content_begin + content_end];

        // Return with skill_save info so handle_tool can auto-save to session_skills
        return ToolExecResult{
            .output = output,
            .skill_save = SkillSaveInfo{
                .name = skill_name,
                .content = skill_content,
            },
        };
    }

    return ToolExecResult{ .output = output };
}

pub fn execRemoveSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        remove_skill_mod.RemoveSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        const output = remove_skill_mod.xmlErrorEmpty(ctx.allocator, "Failed to parse remove_skill arguments");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const output = remove_skill_mod.execute_remove_skill_to_string(ctx.allocator, ctx.io, parsed.value) catch {
        const out = remove_skill_mod.xmlError(ctx.allocator, parsed.value.skill_name, "Unknown error");
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
        const output = add_skill_mod.xmlErrorEmpty(ctx.allocator, "Failed to parse add_skill arguments");
        return ToolExecResult{ .output = output };
    };
    defer parsed.deinit();

    const output = add_skill_mod.executeAddSkillToString(ctx.allocator, ctx.io, parsed.value);
    return ToolExecResult{ .output = output };
}

pub fn execEditSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        edit_skill_mod.EditSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        const output = edit_skill_mod.xmlErrorEmpty(ctx.allocator, "Failed to parse edit_skill arguments");
        return ToolExecResult{ .output = output };
    };
    defer parsed.deinit();

    const output = edit_skill_mod.executeEditSkillToString(ctx.allocator, ctx.io, parsed.value) catch {
        const out = edit_skill_mod.xmlError(ctx.allocator, parsed.value.skill_name, "Failed to edit skill");
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
        const output = add_agent_mod.xmlErrorEmpty(ctx.allocator, "Failed to parse add_agent arguments");
        return ToolExecResult{ .output = output };
    };
    defer parsed.deinit();

    const output = add_agent_mod.executeAddAgentToString(ctx.allocator, parsed.value) catch {
        const out = add_agent_mod.xmlError(ctx.allocator, parsed.value.name, "Failed to add agent");
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
        const output = remove_agent_mod.xmlErrorEmpty(ctx.allocator, "Failed to parse remove_agent arguments");
        return ToolExecResult{ .output = output };
    };
    defer parsed.deinit();

    const output = remove_agent_mod.execute_remove_agent_to_string(ctx.allocator, parsed.value) catch {
        const out = remove_agent_mod.xmlError(ctx.allocator, parsed.value.name, "Failed to remove agent");
        return ToolExecResult{ .output = out };
    };
    return ToolExecResult{ .output = output };
}

pub fn execRemoveFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        remove_file_mod.RemoveFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        const output = remove_file_mod.xmlErrorEmpty(ctx.allocator, "Failed to parse remove_file arguments");
        return ToolExecResult{ .output = output };
    };
    defer parsed.deinit();

    const output = remove_file_mod.executeRemoveFileToString(ctx.allocator, ctx.io, parsed.value) catch {
        const out = remove_file_mod.xmlError(ctx.allocator, "", "Failed to remove file");
        return ToolExecResult{ .output = out };
    };
    return ToolExecResult{ .output = output };
}

pub fn execListAgents(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = tc;

    const output = list_agents_mod.executeListAgents(ctx.allocator, ctx.io, ctx.environment) catch {
        const out = list_agents_mod.jsonError("Failed to list agents");
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
        const output = change_agent_mod.xmlErrorEmpty(ctx.allocator, "Failed to parse change_agent arguments");
        return ToolExecResult{ .output = output };
    };
    defer parsed.deinit();

    const output = change_agent_mod.execute_change_agent_to_string(ctx.allocator, ctx.io, ctx.environment, parsed.value) catch {
        const out = change_agent_mod.xmlError(ctx.allocator, "Failed to get agent");
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
        const output = lsp_definition_mod.xmlError(ctx.allocator, std.fmt.allocPrint(ctx.allocator, "Failed to parse lsp_definition arguments: {s}", .{@errorName(err)}) catch "Unknown error");
        return ToolExecResult{ .output = output };
    };
    defer parsed.deinit();

    const result = lsp_definition_mod.execute_lsp_definition(ctx.allocator, ctx.io, ctx.environment, parsed.value) catch |err| {
        const output = lsp_definition_mod.xmlError(ctx.allocator, std.fmt.allocPrint(ctx.allocator, "Failed to get definition: {s}", .{@errorName(err)}) catch "Unknown error");
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
    ctx.logger.debugFmt("[update_activity] Starting for session {s}", .{ctx.session_id});

    const parsed = std.json.parseFromSlice(
        update_activity_mod.UpdateActivityInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        ctx.logger.errFmt("[update_activity] Failed to parse arguments for session {s}", .{ctx.session_id});
        const output = update_activity_mod.xmlError(ctx.allocator, "Failed to parse update_activity arguments");
        return ToolExecResult{ .output = output };
    };
    defer parsed.deinit();

    // Use session_id directly as worker_id (matches how worker is registered)
    const worker_id = try ctx.allocator.dupe(u8, ctx.session_id);
    defer ctx.allocator.free(worker_id);

    // Update worker activity with the thought
    if (llm_history.updateWorkerActivityWithDescription(ctx.allocator, ctx.db, worker_id, parsed.value.thought)) |_| {
        ctx.logger.infoFmt("[update_activity] Updated activity for {s}: {s}", .{ worker_id, parsed.value.thought });
        const output = update_activity_mod.xmlSuccess(ctx.allocator, parsed.value.thought);
        return ToolExecResult{ .output = output };
    } else |err| {
        ctx.logger.errFmt("[update_activity] Failed to update worker activity for {s}: {}", .{ worker_id, err });
        const output = update_activity_mod.xmlError(ctx.allocator, "Failed to update worker activity");
        return ToolExecResult{ .output = output };
    }
}

// Heap-allocated struct for sub-agent thread arguments
// This avoids capturing pointers from stack frames that may become invalid
const SubAgentThreadArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    sqlite_db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    parent_sess_id: []const u8,
    agent_name: []const u8,
    instruction: []const u8,
    tools: ?[]const []const u8,
    llm_config: *const config_mod.LlmConfig,
    cwd: []const u8,
    is_sub_agent: bool,
    thread_idx: usize,
    shared_results: *SharedResults,
    environment: ?*const std.process.Environ.Map,
    active_loops: *models.ActiveLoops,
};

// Shared result storage for thread synchronization
const SharedResults = struct {
    results: []ThreadResult,
    completed_count: std.atomic.Value(usize),
    mutex: std.Io.Mutex,
};

// Result structure for thread execution
const ThreadResult = struct {
    success: bool,
    name: []const u8,
    response: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

// spawn_sub_agent implementation - uses workflow.zig logic
pub fn execSpawnSubAgent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    ctx.logger.debugFmt("execSpawnSubAgent called, arguments len={}", .{tc.function.arguments.len});
    ctx.logger.debugFmt("arguments: '{s}'", .{tc.function.arguments[0..@min(tc.function.arguments.len, 200)]});

    const parsed = spawn_sub_agent_tool.parse_sub_agents(ctx.allocator, tc.function.arguments, 20) catch |err| {
        ctx.logger.errFmt("parse_sub_agents failed: {}", .{err});
        return error.InvalidArguments;
    };
    defer parsed.deinit(ctx.allocator);

    var results = std.ArrayList(u8).empty;
    defer results.deinit(ctx.allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(ctx.allocator, &results);
    const w = &aw.writer;

    const sub_agent_count = parsed.sub_agents.len;
    ctx.logger.debugFmt("Parsed {} sub-agents", .{sub_agent_count});
    for (parsed.sub_agents, 0..) |sa, i| {
        ctx.logger.debugFmt("Sub-agent {}: name='{s}', instruction_len={}", .{ i, sa.name, sa.instruction.len });
    }

    const shared_results = try ctx.allocator.create(SharedResults);
    shared_results.* = .{
        .results = try ctx.allocator.alloc(ThreadResult, sub_agent_count),
        .completed_count = std.atomic.Value(usize).init(0),
        .mutex = std.Io.Mutex.init,
    };
    for (shared_results.results, 0..) |*r, i| {
        r.* = .{ .success = false, .name = parsed.sub_agents[i].name, .response = null, .error_message = null };
    }
    defer {
        ctx.allocator.free(shared_results.results);
        ctx.allocator.destroy(shared_results);
    }

    // Launch all sub-agents concurrently using std.Io.Group.
    // We need `concurrent` (not `async`) because agents must run in parallel —
    // using `async` on a single-threaded Io can deadlock.
    var group: std.Io.Group = .init;

    for (parsed.sub_agents, 0..) |sub_agent, idx| {
        ctx.logger.debugFmt("Launching concurrent task for agent '{s}' (index {})", .{ sub_agent.name, idx });

        const args = try ctx.allocator.create(SubAgentThreadArgs);
        args.* = .{
            .allocator = ctx.allocator,
            .io = ctx.io,
            .sqlite_db = ctx.db,
            .logger = ctx.logger,
            .parent_sess_id = ctx.session_id,
            .agent_name = sub_agent.name,
            .instruction = sub_agent.instruction,
            .tools = sub_agent.tools,
            .llm_config = ctx.config,
            .cwd = ctx.cwd,
            .is_sub_agent = true,
            .thread_idx = idx,
            .shared_results = shared_results,
            .environment = ctx.environment,
            .active_loops = ctx.active_loops,
        };

        // group.concurrent returns error.ConcurrencyUnavailable if the Io
        // backend cannot run tasks in parallel (e.g. a bare blocking Io).
        try group.concurrent(ctx.io, runSubAgent, .{args});
    }

    // Wait for every sub-agent to finish (replaces the thread.join loop).
    ctx.logger.debugFmt("Awaiting {} concurrent tasks...", .{sub_agent_count});
    try group.await(ctx.io);
    ctx.logger.debugFmt("All concurrent tasks completed", .{});

    var success_count: usize = 0;
    for (shared_results.results) |result| {
        if (result.success) success_count += 1;
    }

    try w.print("<results>\n", .{});
    for (shared_results.results) |result| {
        const success = if (result.success) "true" else "false";
        try w.print("<agent name=\"{s}\" success=\"{s}\">\n", .{ result.name, success });
        if (result.success) {
            if (result.response) |resp| {
                try w.print("<response>{s}</response>\n", .{resp});
            } else {
                try w.print("<response></response>\n", .{});
            }
        } else if (result.error_message) |err| {
            try w.print("<error>{s}</error>\n", .{err});
        } else {
            try w.print("<error>unknown error</error>\n", .{});
        }
        try w.print("</agent>\n", .{});
    }
    try w.print("<summary succeeded=\"{}\" failed=\"{}\" />\n", .{ success_count, sub_agent_count - success_count });
    try w.print("</results>\n", .{});

    results = aw.toArrayList();
    return ToolExecResult{ .output = try results.toOwnedSlice(ctx.allocator) };
}

// Top-level function required by group.concurrent — takes a single *SubAgentThreadArgs.
// The function signature must NOT return an error union if you want group.await
// to not propagate individual task errors; handle them internally instead and
// write results into shared_results, exactly as the original thread fn did.
fn runSubAgent(args_ptr: *SubAgentThreadArgs) void {
    args_ptr.logger.debugFmt("Concurrent task started for '{s}'", .{args_ptr.agent_name});

    var thread_arena_alloc = std.heap.ArenaAllocator.init(args_ptr.allocator);
    defer thread_arena_alloc.deinit();
    const sub_agent_allocator = thread_arena_alloc.allocator();

    defer args_ptr.allocator.destroy(args_ptr);

    const sess_id = std.fmt.allocPrint(
        sub_agent_allocator,
        "subagent_{}_{s}",
        .{ std.Io.Timestamp.now(args_ptr.io, .real).nanoseconds, args_ptr.agent_name },
    ) catch {
        const err_msg = args_ptr.allocator.dupe(u8, "Failed to create session_id") catch "Failed to allocate";
        args_ptr.shared_results.results[args_ptr.thread_idx].error_message = err_msg;
        args_ptr.logger.errFmt("Failed to create session_id for '{s}'", .{args_ptr.agent_name});
        return;
    };
    defer sub_agent_allocator.free(sess_id);
    args_ptr.logger.debugFmt("Session ID created: '{s}'", .{sess_id});

    const di = nalar_mod.getSingleton() catch unreachable;

    const is_sub_agent = std.mem.indexOf(u8, sess_id, "subagent") != null;
    args_ptr.logger.debugFmt("Calling workflow.runAgenticMultiStep for '{s}'", .{args_ptr.agent_name});

    ai_workflow.runAgenticMultiStepnew(di, .{
        .parent_session_id = args_ptr.parent_sess_id,
        .session_id = sess_id,
        .message = args_ptr.instruction,
        .cwd = args_ptr.cwd,
        .body = "",
        .allowed_tools = if (args_ptr.tools) |tools| blk: {
            var tools_str = std.ArrayList(u8).empty;
            for (tools, 0..) |tool, i| {
                if (i > 0) tools_str.append(args_ptr.allocator, ',') catch break;
                tools_str.appendSlice(args_ptr.allocator, tool) catch break;
            }
            break :blk tools_str.items;
        } else "",
        .is_sub_agent = is_sub_agent,
    }) catch |err| {
        const err_msg = args_ptr.allocator.dupe(u8, "Workflow error") catch "Failed to allocate";
        args_ptr.shared_results.results[args_ptr.thread_idx].error_message = err_msg;
        args_ptr.logger.errFmt("Sub-agent workflow error for '{s}': {s}", .{ args_ptr.agent_name, @errorName(err) });
        return;
    };

    args_ptr.logger.debugFmt("workflow.runAgenticMultiStep completed for '{s}', fetching message", .{args_ptr.agent_name});

    const latest_msg_result = llm_history.getLatestMessage(sub_agent_allocator, args_ptr.sqlite_db, sess_id) catch |err| {
        const err_msg = args_ptr.allocator.dupe(u8, "getLatestMessage error") catch return;
        args_ptr.shared_results.results[args_ptr.thread_idx].error_message = err_msg;
        args_ptr.logger.errFmt("getLatestMessage error for '{s}': {s}", .{ sess_id, @errorName(err) });
        return;
    };

    if (latest_msg_result) |msg| {
        var mutable_msg = msg;
        if (mutable_msg.response_content.len > 0) {
            const response_copy = args_ptr.allocator.dupe(u8, mutable_msg.response_content) catch {
                const err_msg = args_ptr.allocator.dupe(u8, "Failed to copy response") catch "allocation failed";
                args_ptr.shared_results.results[args_ptr.thread_idx].error_message = err_msg;
                mutable_msg.deinit(args_ptr.allocator);
                return;
            };
            args_ptr.shared_results.results[args_ptr.thread_idx].response = response_copy;
            args_ptr.shared_results.results[args_ptr.thread_idx].success = true;
        } else {
            args_ptr.shared_results.results[args_ptr.thread_idx].error_message = "Empty response content";
        }
        mutable_msg.deinit(args_ptr.allocator);
    } else {
        args_ptr.shared_results.results[args_ptr.thread_idx].error_message = "No message found in database";
    }

    _ = args_ptr.shared_results.completed_count.fetchAdd(1, .monotonic);
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

    const result = try web_search_mod.execute_web_search(ctx.allocator, ctx.io, parsed.value);
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

    var glob_result = try glob_tool_mod.executeGlob(ctx.allocator, ctx.io, parsed.value);
    const res_glob = try glob_tool_mod.toXmlSuccess(ctx.allocator, glob_result, parsed.value.pattern);
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

    var search_result = search_tool_mod.execute_search(ctx.allocator, ctx.io, parsed.value) catch |err| {
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

    const res_search = try search_tool_mod.search_result_to_string_grouped(
        ctx.allocator,
        search_result,
        parsed.value.pattern,
        parsed.value.path,
    );
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

    // === SKILL MANAGEMENT ===
    .{ .name = "list_skills", .exec = execListSkills, .tool_def = list_skills_mod.list_skills_tool },
    .{ .name = "get_skill", .exec = execGetSkill, .tool_def = get_skill_mod.get_skill_tool, .auto_save_skill = true },
    .{ .name = "remove_skill", .exec = execRemoveSkill, .tool_def = remove_skill_mod.remove_skill_tool },

    // === SKILL/AGENT CREATION ===
    .{ .name = "add_skill", .exec = execAddSkill, .tool_def = add_skill_mod.add_skill_tool, .auto_save_skill = true },
    .{ .name = "edit_skill", .exec = execEditSkill, .tool_def = edit_skill_mod.edit_skill_tool },

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
pub fn allAgentTools(allocator: std.mem.Allocator) []const tool_models.AgentTool {
    const tools_list = comptime &[_]tool_models.AgentTool{
        set_agent_properties_mod.set_agent_properties_tool,
        spawn_sub_agent_tool.spawn_sub_agent_tool,
        update_activity_mod.update_activity_tool,
        list_skills_mod.list_skills_tool,
        get_skill_mod.get_skill_tool,
        remove_skill_mod.remove_skill_tool,
        add_skill_mod.add_skill_tool,
        edit_skill_mod.edit_skill_tool,
        bash_tool_mod.bash_tool,
        read_file_mod.read_file_tool,
        write_file_mod.write_file_tool,
        text_replace_mod.text_replace_tool,
        remove_file_mod.remove_file_tool,
        glob_tool_mod.glob_tool,
        search_tool_mod.search_tool,
    };
    return allocator.dupe(tool_models.AgentTool, tools_list) catch return &.{};
}

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
    const names = comptime blk: {
        var n: [UNIFIED_TOOL_REGISTRY.len][]const u8 = undefined;
        for (UNIFIED_TOOL_REGISTRY, 0..) |tool, i| {
            n[i] = tool.name;
        }
        break :blk n;
    };
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
