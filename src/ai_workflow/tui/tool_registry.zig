const std = @import("std");
const nalar_mod = @import("nalarcore");
const models = @import("models.zig");
const ai_workflow = @import("workflow.zig");
const helpers = nalar_mod.helpers;
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
const memories_mod = nalar_mod.memories;
const list_memory_mod = nalar_mod.list_memory_tool;
const get_skill_mod = nalar_mod.get_skill_tool;
const view_skill_mod = nalar_mod.view_skill_tool;
const remove_skill_mod = nalar_mod.remove_skill_tool;
const list_agents_mod = nalar_mod.list_agents;
const add_skill_mod = nalar_mod.add_skill;
const edit_skill_mod = nalar_mod.edit_skill;
const set_git_worktree_mod = nalar_mod.set_git_worktree;
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
const nalar_browser_mod = nalar_mod.nalar_browser;
const update_activity_mod = nalar_mod.update_activity;
const glob_tool_mod = nalar_mod.glob_tool;
const search_tool_mod = nalar_mod.search_tool;
const semantic_search_mod = nalar_mod.semantic_search;
const xmlEscape = helpers.xml_escape;

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
    /// Name of the parent session's active profile (from
    /// `LlmConfig.profiles_models`). Empty string means "no
    /// profile selected — use the top-level config". Threaded
    /// from `RunParamsNew.selected_profile_model` through
    /// `handle_tool` so the spawn_sub_agent tool can do the
    /// per-profile sub_agents lookup (locked decision #1 in
    /// the plan).
    selected_profile_model: []const u8 = "",
    /// Optional CWD override set by `set_git_worktree`. When non-null,
    /// exec functions MAY prefer this path over `cwd` for filesystem
    /// operations. Currently a no-op at the exec layer (the field is
    /// reserved for a follow-up plan; see Chunk 3 of the
    /// set_git_worktree plan in NALAR.md). DB persistence is the
    /// MUST-HAVE — the override field is forward-looking only.
    cwd_override: ?[]const u8 = null,
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
    const inner = try runWithContext(ctx.allocator, ctx.io, tc, ctx.db, ctx.session_id);
    const output = try wrapToolOutput(ctx.allocator, "bash", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execReadFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = ctx.db;
    _ = ctx.session_id;

    // Parse arguments JSON to ReadFileInput
    const parsed = std.json.parseFromSlice(
        tool_models.ReadFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "read_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const read_opts = read_file_mod.ReadFileOptions{
        .offset = parsed.value.offset,
        .limit = parsed.value.limit,
    };

    const read_result = read_file_mod.readFile(ctx.allocator, ctx.io, parsed.value.path, read_opts) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "read_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer read_result.deinit(ctx.allocator);

    // Single allocation: combines path and content into XML result
    const inner = try read_file_mod.toXMLSuccess(ctx.allocator, read_result, parsed.value.path);
    const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execTextReplace(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // const sanitized_args = try helpers.sanitize.sanitizeJsonString(ctx.allocator, tc.function.arguments);
    // defer ctx.allocator.free(sanitized_args);

    const parsed = std.json.parseFromSlice(
        text_replace_mod.TextReplaceInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "text_replace failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const result = text_replace_mod.executeTextReplace(
        ctx.allocator,
        ctx.io,
        parsed.value.path,
        parsed.value.old_str,
        parsed.value.new_str,
    ) catch |err| {
        const inner = text_replace_mod.toXmlError(
            ctx.allocator,
            err,
            parsed.value.path,
            parsed.value.old_str,
        );
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "text_replace failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const inner = text_replace_mod.toXmlSuccess(ctx.allocator, result, parsed.value.path);
    const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execWriteFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        write_file_mod.WriteFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "write_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "write_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const write_result = write_file_mod.writeFile(ctx.allocator, ctx.io, parsed.value) catch |err| {
        const inner = write_file_mod.toXmlError(ctx.allocator, err, parsed.value.path);
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "write_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "write_file", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const inner = write_file_mod.toXmlSuccess(ctx.allocator, write_result);
    write_result.deinit(ctx.allocator);
    const output = try wrapToolOutput(ctx.allocator, "write_file", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execListSkills(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // Pass ctx.cwd so local skills are looked up in the session's workspace
    // (the same directory add_skill/edit_skill/remove_skill write to), matching
    // how those tools are invoked. Passing null here would make list_skills fall
    // back to the server's OS-level cwd, causing local skills to be invisible.
    const inner = list_skills_mod.execute_list_skills(ctx.allocator, ctx.io, ctx.cwd, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "list_skills failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "list_skills", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "list_skills", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execListMemory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // Memories are global only — no cwd involvement. The env comes from ctx
    // (same path as list_skills); on null we emit an error-tagged XML so the
    // LLM gets a structured failure instead of a panic.
    const inner = list_memory_mod.execute_list_memory(ctx.allocator, ctx.io, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "list_memory failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "list_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "list_memory", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execGetSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = try std.json.parseFromSlice(
        get_skill_mod.GetSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const inner = get_skill_mod.execute_get_skill_to_string(ctx.allocator, ctx.io, parsed.value, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "get_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "get_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "get_skill", tc.function.arguments, true, null, inner);

    // Check if skill was successfully loaded and extract skill info for auto-save.
    // The skill_save detection now looks for <success>true</success> in the WRAPPED
    // envelope, not <loaded>true</loaded> in the inner XML (which is now inside
    // <data>...</data>).
    if (std.mem.indexOf(u8, output, "<success>true</success>") != null) {
        // Parse skill_name from wrapped output
        const name_start = std.mem.indexOf(u8, output, "<skill_name>") orelse {
            return ToolExecResult{ .output = output, .output_allocated = true };
        };
        const name_begin = name_start + "<skill_name>".len;
        const name_end = std.mem.indexOf(u8, output[name_begin..], "</skill_name>") orelse {
            return ToolExecResult{ .output = output, .output_allocated = true };
        };
        const skill_name = output[name_begin .. name_begin + name_end];

        // Parse content from wrapped output
        const content_start = std.mem.indexOf(u8, output, "<content>") orelse {
            return ToolExecResult{ .output = output, .output_allocated = true };
        };
        const content_begin = content_start + "<content>".len;
        const content_end = std.mem.indexOf(u8, output[content_begin..], "</content>") orelse {
            return ToolExecResult{ .output = output, .output_allocated = true };
        };
        const skill_content = output[content_begin .. content_begin + content_end];

        // Return with skill_save info so handle_tool can auto-save to session_skills
        return ToolExecResult{
            .output = output,
            .output_allocated = true,
            .skill_save = SkillSaveInfo{
                .name = skill_name,
                .content = skill_content,
            },
        };
    }

    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execViewSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        view_skill_mod.ViewSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "view_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "view_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = view_skill_mod.execute_view_skill_to_string(ctx.allocator, ctx.io, parsed.value, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "view_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "view_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // Empty skill_name means "not found" → wrap as error.
    if (std.mem.indexOf(u8, inner, "<skill_name></skill_name>") != null) {
        const err_msg = try ctx.allocator.dupe(u8, "Skill not found");
        const output = try wrapToolOutput(ctx.allocator, "view_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "view_skill", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execRemoveSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        remove_skill_mod.RemoveSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "remove_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = remove_skill_mod.execute_remove_skill_to_string(ctx.allocator, ctx.io, ctx.cwd, ctx.environment, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "remove_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // If inner has <error>...</error>, treat as failure
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execAddSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        add_skill_mod.AddSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "add_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // executeAddSkillToString returns a plain []const u8 (no error
    // union); errors are encoded as <error>...</error> in the XML
    // and handled below.
    const inner = add_skill_mod.executeAddSkillToString(ctx.allocator, ctx.io, ctx.cwd, ctx.environment, parsed.value);

    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execSetGitWorktree(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        set_git_worktree_mod.SetGitWorktreeInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "set_git_worktree failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // executeSetGitWorktreeToString returns ![]const u8 — errors are
    // also encoded as <error>...</error> in the XML on success paths.
    // We must catch the error union separately.
    const inner = set_git_worktree_mod.executeSetGitWorktreeToString(
        ctx.allocator,
        ctx.io,
        ctx.db,
        ctx.cwd,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "set_git_worktree failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    // SUCCESS: persist the new git_worktree_cwd to the DB so the
    // session remembers it across tool calls. For CLEAR, pass null
    // (the function treats null and "" identically as "clear the
    // binding"). For SET, extract the <path>...</path> from the
    // inner XML and persist it.
    const effective: ?[]const u8 = if (parsed.value.clear) null else blk: {
        const path_start = (std.mem.indexOf(u8, inner, "<path>") orelse 0) + "<path>".len;
        const path_end = std.mem.indexOf(u8, inner[path_start..], "</path>") orelse inner.len;
        const worktree_path = inner[path_start .. path_start + path_end];
        if (worktree_path.len == 0) break :blk null;
        // Borrow the slice from `inner` (still alive for the duration
        // of this call). `updateSessionGitWorktreeCwd` only reads it
        // and never frees it, so this is safe.
        break :blk worktree_path;
    };

    llm_history.updateSessionGitWorktreeCwd(ctx.allocator, ctx.db, ctx.session_id, effective) catch |err| {
        ctx.logger.errFmt("set_git_worktree: failed to persist git_worktree_cwd: {s}", .{@errorName(err)});
    };

    const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execEditSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        edit_skill_mod.EditSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "edit_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = edit_skill_mod.executeEditSkillToString(ctx.allocator, ctx.io, ctx.cwd, ctx.environment, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "edit_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execAddAgent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        add_agent_mod.AddAgentInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "add_agent failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "add_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = add_agent_mod.executeAddAgentToString(ctx.allocator, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "add_agent failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "add_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "add_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "add_agent", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execRemoveAgent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        remove_agent_mod.RemoveAgentInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "remove_agent failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "remove_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = remove_agent_mod.execute_remove_agent_to_string(ctx.allocator, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "remove_agent failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "remove_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "remove_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "remove_agent", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execRemoveFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        remove_file_mod.RemoveFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "remove_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "remove_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = remove_file_mod.executeRemoveFileToString(ctx.allocator, ctx.io, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "remove_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "remove_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "remove_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "remove_file", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execListAgents(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const inner = list_agents_mod.executeListAgents(ctx.allocator, ctx.io, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "list_agents failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "list_agents", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "list_agents", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execChangeAgent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        change_agent_mod.ChangeAgentInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "change_agent failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "change_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = change_agent_mod.execute_change_agent_to_string(ctx.allocator, ctx.io, ctx.environment, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "change_agent failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "change_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "change_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "change_agent", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execLspDefinition(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        lsp_definition_mod.LspDefinitionInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "lsp_definition failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "lsp_definition", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const result = lsp_definition_mod.execute_lsp_definition(ctx.allocator, ctx.io, ctx.environment, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "lsp_definition failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "lsp_definition", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer result.deinit(ctx.allocator);

    const inner = try lsp_definition_mod.lsp_definition_to_string(ctx.allocator, result);
    const output = try wrapToolOutput(ctx.allocator, "lsp_definition", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// set_agent_properties implementation - modifies agent temperature/is_thinking
pub fn execSetAgentProperties(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const result = try handleSetAgentProperties(ctx.allocator, tc);

    return ToolExecResult{
        .output = result.arguments,
        .output_allocated = true,
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

    // The execX contract is "set these fields and return the wrapped output".
    // We use the standardized envelope so handle_tool sees the same shape as
    // every other tool. The typo in the closing tag (`<set_agent_properties>`
    // without the `/`) in the previous version is fixed.
    const wrapped = try wrapToolOutput(allocator, "set_agent_properties", tool_call.function.arguments, true, null, "");

    return SetAgentPropertiesResult{
        .temperature = parsed.value.temperature,
        .is_thinking = parsed.value.is_thinking,
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
        .arguments = wrapped,
    };
}

// update_activity implementation - records thought as worker activity
pub fn execUpdateActivity(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    ctx.logger.debugFmt("[update_activity] Starting for session {s}", .{ctx.session_id});

    const parsed = try std.json.parseFromSlice(
        update_activity_mod.UpdateActivityInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    // Use session_id directly as worker_id (matches how worker is registered)
    const worker_id = try ctx.allocator.dupe(u8, ctx.session_id);
    defer ctx.allocator.free(worker_id);

    // Update worker activity with the thought
    if (llm_history.updateWorkerActivityWithDescription(ctx.allocator, ctx.db, worker_id, parsed.value.thought)) |_| {
        ctx.logger.infoFmt("[update_activity] Updated activity for {s}: {s}", .{ worker_id, parsed.value.thought });
        const inner = update_activity_mod.xmlSuccess(ctx.allocator, parsed.value.thought);
        const output = try wrapToolOutput(ctx.allocator, "update_activity", tc.function.arguments, true, null, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    } else |err| {
        ctx.logger.errFmt("[update_activity] Failed to update worker activity for {s}: {}", .{ worker_id, err });
        const inner = update_activity_mod.xmlError(ctx.allocator, "Failed to update worker activity");
        const err_msg = "Failed to update worker activity";
        const output = try wrapToolOutput(ctx.allocator, "update_activity", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
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
    inherited_context: []const u8 = "", // NEW: mode string for parent history inheritance
    /// NEW: resolved sub-agent config overlay. When non-null, the
    /// workflow uses this sub-agent's model / base_url / api_key /
    /// url_style / thinking / temperature / system_prompt instead of
    /// the orchestrator's defaults. Set by `execSpawnSubAgent`
    /// after calling `Config.resolveSubAgent`. The struct is small
    /// and copied by value into the heap-allocated thread args; the
    /// string slices it references borrow from the LlmConfig
    /// allocator and must outlive the workflow run.
    sub_agent_overrides: ?ai_workflow.SubAgentOverrides = null,
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
    session_id: []const u8 = "",
    /// True when the LLM-requested `agent_name` was not found in
    /// any sub_agents list and a random name was generated. The
    /// frontend uses this to show the "random" badge on the
    /// affected <agent> tag. Populated by `runSubAgent` after
    /// `resolveSubAgent` returns.
    is_random_fallback: bool = false,
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

    // Build the result XML using `std.Io.Writer.Allocating`.
    //
    // IMPORTANT (learned the hard way on 2026-06-15): in this Zig
    // 0.16 build, `Writer.Allocating.fromArrayList` EMPTIES the
    // passed ArrayList (`defer array_list.* = .empty;` inside
    // `fromArrayListAligned`, see std/Io/Writer.zig line 2567) and
    // takes ownership of its allocated memory as the writer's
    // internal buffer. Calling `toOwnedSlice` on the ORIGINAL
    // ArrayList therefore returns "" — the data is in the writer.
    // And `Writer.Allocating.flush` is a no-op (see std/Io/Writer.zig
    // line 2582: `.flush = noopFlush`), so calling `flush` does
    // nothing useful.
    //
    // The right pattern is:
    //   1. `Allocating.init(allocator)` — get a writer with its own buffer
    //   2. write into it via `&aw.writer`
    //   3. `aw.toArrayList()` — MOVE the buffer out as a fresh ArrayList
    //   4. `final_list.toOwnedSlice(allocator)` — extract the data
    //   5. `defer aw.deinit()` — cleanup the writer
    //
    // (The previous fix that called `try aw.flush();` was a no-op
    // for the same reason and didn't actually fix the empty-data
    // bug. This is the real fix.)
    var aw = std.Io.Writer.Allocating.init(ctx.allocator);
    defer aw.deinit();
    const w = &aw.writer;

    const sub_agent_count = parsed.sub_agents.len;
    ctx.logger.debugFmt("Parsed {} sub-agents", .{sub_agent_count});
    for (parsed.sub_agents, 0..) |sa, i| {
        ctx.logger.debugFmt("Sub-agent {}: agent_name='{s}', instruction_len={}", .{ i, sa.agent_name, sa.instruction.len });
    }

    const shared_results = try ctx.allocator.create(SharedResults);
    shared_results.* = .{
        .results = try ctx.allocator.alloc(ThreadResult, sub_agent_count),
        .completed_count = std.atomic.Value(usize).init(0),
        .mutex = std.Io.Mutex.init,
    };
    for (shared_results.results, 0..) |*r, i| {
        r.* = .{ .success = false, .name = parsed.sub_agents[i].agent_name, .response = null, .error_message = null, .session_id = "" };
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
        ctx.logger.debugFmt("Launching concurrent task for agent '{s}' (index {})", .{ sub_agent.agent_name, idx });

        // Resolve the sub-agent config from the LlmConfig.
        // `agent_name` is the LLM-provided name from JSON (required).
        // We look it up in the config's sub_agents list and apply
        // the resolved fields as an overlay on the orchestrator's
        // defaults. If the name is not found, a random name is
        // generated and the orchestrator's defaults are used.
        const an = sub_agent.agent_name;
        const overrides: ?ai_workflow.SubAgentOverrides = blk: {
            // Resolve against the active profile's sub_agents
            // list first (when a profile is selected), then
            // fall back to the top-level sub_agents. The
            // parent's selected_profile_model is threaded
            // through `ToolExecContext.selected_profile_model`
            // by the workflow → handle_tool → dispatch path.
            //
            // The `@constCast` is needed because `resolveSubAgent`
            // mutates `self.random_names` to track the random
            // fallback's allocation for deinit cleanup. The
            // LlmConfig is logically immutable (it lives in
            // the singleton for the server's lifetime); this
            // single private mutation is a tracking side-effect,
            // not a semantic change. Casting away const at
            // the one production call site keeps the rest of
            // the type system honest about read-only access.
            const resolved = @constCast(ctx.config).resolveSubAgent(ctx.selected_profile_model, an);
            if (resolved.is_random_fallback) {
                ctx.logger.warnFmt("spawn_sub_agent: agent_name '{s}' not found in LlmConfig.sub_agents; using random name '{s}' and orchestrator defaults", .{ an, resolved.name });
            } else {
                ctx.logger.infoFmt("spawn_sub_agent: agent_name '{s}' resolved (source='{s}', model='{s}')", .{ an, resolved.source, resolved.model });
            }
            break :blk ai_workflow.SubAgentOverrides{
                .resolved_name = resolved.name,
                .is_random_fallback = resolved.is_random_fallback,
                .model = resolved.model,
                .base_url = resolved.base_url,
                .api_key = resolved.api_key,
                .url_style = resolved.url_style,
                .is_thinking = resolved.is_thinking,
                .temperature = resolved.temperature,
                .system_prompt = resolved.system_prompt,
            };
        };

        const args = try ctx.allocator.create(SubAgentThreadArgs);
        args.* = .{
            .allocator = ctx.allocator,
            .io = ctx.io,
            .sqlite_db = ctx.db,
            .logger = ctx.logger,
            .parent_sess_id = ctx.session_id,
            .agent_name = sub_agent.agent_name,
            .instruction = sub_agent.instruction,
            .tools = sub_agent.tools,
            .llm_config = ctx.config,
            .cwd = ctx.cwd,
            .is_sub_agent = true,
            .thread_idx = idx,
            .shared_results = shared_results,
            .environment = ctx.environment,
            .active_loops = ctx.active_loops,
            .inherited_context = sub_agent.inherited_context orelse "",
            .sub_agent_overrides = overrides,
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
        const random_fallback = if (result.is_random_fallback) "true" else "false";
        try w.print("<agent name=\"{s}\" success=\"{s}\" random_fallback=\"{s}\">\n", .{ result.name, success, random_fallback });
        if (result.session_id.len > 0) {
            try w.print("<session_id>{s}</session_id>\n", .{result.session_id});
        }
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

    // Move the writer's internal buffer out as an ArrayList (this
    // resets the writer to an empty state — `defer aw.deinit()`
    // at the top of the function will free the now-empty writer
    // bookkeeping). See the long comment on the `var aw` line
    // for the full rationale (the `results` ArrayList was
    // emptied by `fromArrayList`; we don't use that pattern
    // anymore; the data lives in the writer's internal buffer).
    var final_list = aw.toArrayList();
    defer final_list.deinit(ctx.allocator);
    const inner_owned = try final_list.toOwnedSlice(ctx.allocator);
    const output = try wrapToolOutput(ctx.allocator, "spawn_sub_agent", tc.function.arguments, true, null, inner_owned);
    return ToolExecResult{ .output = output, .output_allocated = true };
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

    // Propagate is_random_fallback from the resolved overrides to the
    // shared result so the frontend can render the "random" badge.
    // Done BEFORE the workflow call so it's set even if the workflow
    // errors out before reaching the result struct.
    if (args_ptr.sub_agent_overrides) |ov| {
        args_ptr.shared_results.results[args_ptr.thread_idx].is_random_fallback = ov.is_random_fallback;
    }

    // session_id uses the resolved sub-agent name (matched or random)
    // when overrides are present, otherwise the LLM-provided name.
    // This is what gets embedded in the sub-agent's session_id
    // suffix and shows up in the UI's worker list.
    const resolved_display_name: []const u8 = if (args_ptr.sub_agent_overrides) |ov|
        ov.resolved_name
    else
        args_ptr.agent_name;

    const sess_id = std.fmt.allocPrint(
        sub_agent_allocator,
        "subagent_{}_{s}",
        .{ std.Io.Timestamp.now(args_ptr.io, .real).nanoseconds, resolved_display_name },
    ) catch {
        const err_msg = args_ptr.allocator.dupe(u8, "Failed to create session_id") catch "Failed to allocate";
        args_ptr.shared_results.results[args_ptr.thread_idx].error_message = err_msg;
        args_ptr.logger.errFmt("Failed to create session_id for '{s}'", .{args_ptr.agent_name});
        return;
    };
    defer sub_agent_allocator.free(sess_id);
    args_ptr.logger.debugFmt("Session ID created: '{s}'", .{sess_id});

    // Store session_id in shared results immediately after creation
    {
        const session_id_copy = args_ptr.allocator.dupe(u8, sess_id) catch {
            const err_msg = args_ptr.allocator.dupe(u8, "Failed to copy session_id") catch "Failed to allocate";
            args_ptr.shared_results.results[args_ptr.thread_idx].error_message = err_msg;
            args_ptr.logger.errFmt("Failed to copy session_id for '{s}'", .{args_ptr.agent_name});
            return;
        };
        args_ptr.shared_results.results[args_ptr.thread_idx].session_id = session_id_copy;
    }

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
        .inherited_context = args_ptr.inherited_context,
        .sub_agent_overrides = args_ptr.sub_agent_overrides,
    }) catch |err| {
        const err_msg = std.fmt.allocPrint(args_ptr.allocator, "Workflow error: {s}", .{@errorName(err)}) catch "Failed to allocate error message";
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
    const output = try wrapToolOutput(ctx.allocator, "lsp_references", tc.function.arguments, false, "lsp_references not implemented", "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execLspWorkspaceSymbol(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const output = try wrapToolOutput(ctx.allocator, "lsp_workspace_symbol", tc.function.arguments, false, "lsp_workspace_symbol not implemented", "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execLspDocumentSymbol(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const output = try wrapToolOutput(ctx.allocator, "lsp_document_symbol", tc.function.arguments, false, "lsp_document_symbol not implemented", "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execLspHover(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const output = try wrapToolOutput(ctx.allocator, "lsp_hover", tc.function.arguments, false, "lsp_hover not implemented", "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execWebSearch(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        tool_models.WebSearchInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "web_search failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "web_search", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const result = web_search_mod.execute_web_search(ctx.allocator, ctx.io, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "web_search failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "web_search", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer result.deinit(ctx.allocator);

    const inner = try web_search_mod.web_search_result_to_string(ctx.allocator, result);
    const output = try wrapToolOutput(ctx.allocator, "web_search", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execNalarBrowser(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        nalar_browser_mod.NalarBrowserInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "nalar_browser failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "nalar_browser", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const result = nalar_browser_mod.execute_nalar_browser(ctx.allocator, ctx.io, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "nalar_browser failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "nalar_browser", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (result.success) {
        const inner = try nalar_browser_mod.toXMLSuccess(ctx.allocator, result);
        const output = try wrapToolOutput(ctx.allocator, "nalar_browser", tc.function.arguments, true, null, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    } else {
        const inner = try nalar_browser_mod.toXMLError(ctx.allocator, result, parsed.value.action);
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "nalar_browser {s} failed", .{parsed.value.action});
        const output = try wrapToolOutput(ctx.allocator, "nalar_browser", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }
}

pub fn execGlob(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const args = tc.function.arguments;
    const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;

    const parsed = std.json.parseFromSlice(
        glob_tool_mod.GlobInput,
        ctx.allocator,
        args_to_parse,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "glob failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    var glob_result = glob_tool_mod.executeGlob(ctx.allocator, ctx.io, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "glob failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const inner = try glob_tool_mod.toXmlSuccess(ctx.allocator, glob_result, parsed.value.pattern);
    glob_result.deinit(ctx.allocator);
    const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execSearch(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const args = tc.function.arguments;
    const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;

    const parsed = std.json.parseFromSlice(
        search_tool_mod.SearchInput,
        ctx.allocator,
        args_to_parse,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "search failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    var search_result = search_tool_mod.executeSearch(ctx.allocator, ctx.io, ctx.cwd, parsed.value) catch |err| {
        if (err == error.StdoutStreamTooLong) {
            const err_msg = "Search output exceeded max_output limit. Use a larger max_output value (e.g. 5242880 for 5MB), narrow your search path, or use a more specific pattern.";
            const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, false, err_msg, "");
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "search failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (search_result.matches.items.len == 0) {
        const inner = try ctx.allocator.dupe(u8, search_result.content);
        search_result.deinit(ctx.allocator);
        const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, true, null, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const inner = try search_tool_mod.search_result_to_string_grouped(
        ctx.allocator,
        search_result,
        parsed.value.pattern,
        parsed.value.path,
    );
    search_result.deinit(ctx.allocator);
    const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// pub fn execSemanticSearch(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
//     const args = tc.function.arguments;
//     const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;
//
//     const parsed = std.json.parseFromSlice(
//         semantic_search_mod.SemanticSearchInput,
//         ctx.allocator,
//         args_to_parse,
//         .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
//     ) catch {
//         const output = try semantic_search_mod.xmlError(ctx.allocator, "Failed to parse arguments");
//         return ToolExecResult{ .output = output };
//     };
//     defer parsed.deinit();
//
//     const handle_semantic_search = @import("handle_semantic_search.zig");
//     const result = try handle_semantic_search.handleSemanticSearch(ctx, .{
//         .query = parsed.value.query,
//         .limit = parsed.value.limit,
//     });
//     return result;
// }
//
// pub fn execIndexCodebase(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
//     _ = tc;
//
//     const handle_semantic_search = @import("handle_semantic_search.zig");
//     const result = try handle_semantic_search.handleIndexCodebase(ctx);
//     return result;
// }

// ============================================================================
// STANDARDIZED TOOL OUTPUT ENVELOPE
// ============================================================================
//
// Every `execX` function below MUST end by calling `wrapToolOutput` so the
// LLM sees a single consistent envelope:
//
//   <tool>
//     <name>{name}</name>
//     <parameters>{xml args (converted from JSON)}</parameters>
//     <success>true|false</success>
//     <error>{if failure}</error>
//     <data>{xml-escaped inner tool output, if success}</data>
//   </tool>
//
// The inner `<data>` field holds the existing tool-specific XML unchanged
// (e.g. read_file's `<path>`, text_replace's `<diff_view>`, get_skill's
// `<loaded>`, etc.) so the 12 tool modules' `toXmlSuccess`/`toXmlError`
// functions and the 13 frontend `tool_outputs/*.vue` components keep
// working unchanged.


/// Convert a JSON arguments string to XML structure wrapped in
/// `<parameters>...</parameters>`. The conversion rules:
///
/// - Object → `<parameters><k>v</k>...</parameters>` (one child per key)
/// - Array of primitives → `<parameters><item>...</item>...</parameters>`
/// - String/number/boolean → text content (XML-escaped)
/// - null → self-closing `<k/>`
/// - Nested object → `<parameters><k>...</k></parameters>` (recurses)
///
/// Returns `<parameters></parameters>` for an empty input string.
/// Returns `<parameters><raw>{escaped raw}</raw></parameters>` if the JSON
/// fails to parse (fallback so the LLM can still see what was passed).
fn jsonArgsToXml(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    if (json_str.len == 0) {
        return try allocator.dupe(u8, "<parameters></parameters>");
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        // Malformed JSON fallback: wrap the raw string in <raw>...</raw>
        const escaped = try xmlEscape(allocator, json_str);
        defer allocator.free(escaped);
        return try std.fmt.allocPrint(allocator, "<parameters><raw>{s}</raw></parameters>", .{escaped});
    };
    defer parsed.deinit();

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "<parameters>");
    switch (parsed.value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                try helpers.json_value_to_xml(allocator, &buffer, entry.key_ptr.*, entry.value_ptr.*);
            }
        },
        else => {
            // Top-level is not an object — wrap as <raw> for safety
            const escaped = try xmlEscape(allocator, json_str);
            defer allocator.free(escaped);
            try buffer.appendSlice(allocator, "<raw>");
            try buffer.appendSlice(allocator, escaped);
            try buffer.appendSlice(allocator, "</raw>");
        },
    }
    try buffer.appendSlice(allocator, "</parameters>");

    return try buffer.toOwnedSlice(allocator);
}

/// Wrap a tool result in the standardized `<tool>...</tool>` envelope.
///
/// On success: emits `<data>` containing the inner tool-specific XML output.
/// On error: emits `<error>` containing a human-readable message and omits
/// `<data>`. The two are mutually exclusive — when `success=true`, the
/// `error_message` argument is ignored; when `success=false`, the `data`
/// argument is ignored.
///
/// `tool_name` — the registered tool name (e.g. `"read_file"`). XML-escaped.
/// `parameters` — the raw JSON arguments string from the tool call
///   (e.g. `{"path":"/foo"}`). The wrapper parses this JSON and converts it
///   to XML structure inside `<parameters>...</parameters>`. If the JSON is
///   malformed, the raw string is wrapped in `<raw>...</raw>` as a fallback.
///   Always emitted (even on error).
/// `success` — `true` for a successful tool execution, `false` for a failure.
/// `error_message` — required when `success=false`; ignored when `success=true`.
/// `data` — the existing tool-specific XML output. Required when
///   `success=true`; ignored when `success=false`. Pass an empty string if
///   you have no data (the wrapper still emits an empty `<data></data>`).
///
/// The returned string is owned by the caller; free with `allocator.free`.
pub fn wrapToolOutput(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    parameters: []const u8,
    success: bool,
    error_message: ?[]const u8,
    data: []const u8,
) ![]u8 {
    const escaped_name = try xmlEscape(allocator, tool_name);
    defer allocator.free(escaped_name);
    const params_xml = try jsonArgsToXml(allocator, parameters);
    defer allocator.free(params_xml);

    if (success) {
        // Note: `data` is NOT XML-escaped. It is the tool-specific XML
        // output (e.g. read_file's `<path>/foo</path>...`) and escaping
        // it would corrupt the inner tags, making the result unreadable
        // to the LLM and the frontend. The other text fields (name,
        // parameters, error_message) ARE escaped because they are
        // arbitrary user input.
        return try std.fmt.allocPrint(
            allocator,
            "<tool><name>{s}</name><parameters>{s}</parameters><success>true</success><data>{s}</data></tool>",
            .{ escaped_name, params_xml, data },
        );
    } else {
        const msg = error_message orelse "unknown error";
        const escaped_err = try xmlEscape(allocator, msg);
        defer allocator.free(escaped_err);
        return try std.fmt.allocPrint(
            allocator,
            "<tool><name>{s}</name><parameters>{s}</parameters><success>false</success><error>{s}</error></tool>",
            .{ escaped_name, params_xml, escaped_err },
        );
    }
}

// ============================================================================
// UNIFIED TOOL REGISTRY - Single source of truth for ALL tool metadata
// ============================================================================

/// Metadata for each tool in the unified registry
pub const ToolInfo = struct {
    name: []const u8,
    exec: ToolExecFunc,
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
    .{ .name = "view_skill", .exec = execViewSkill, .tool_def = view_skill_mod.view_skill_tool },
    .{ .name = "get_skill", .exec = execGetSkill, .tool_def = get_skill_mod.get_skill_tool, .auto_save_skill = true },
    .{ .name = "remove_skill", .exec = execRemoveSkill, .tool_def = remove_skill_mod.remove_skill_tool },

    .{ .name = "add_skill", .exec = execAddSkill, .tool_def = add_skill_mod.add_skill_tool, .auto_save_skill = true },
    .{ .name = "edit_skill", .exec = execEditSkill, .tool_def = edit_skill_mod.edit_skill_tool },

    // === MEMORY TOOLS ===
    .{ .name = "list_memory", .exec = execListMemory, .tool_def = list_memory_mod.list_memory_tool },

    // === FILE OPERATIONS ===
    .{ .name = "bash", .exec = execBash, .tool_def = bash_tool_mod.bash_tool },
    .{ .name = "read_file", .exec = execReadFile, .tool_def = read_file_mod.read_file_tool },
    .{ .name = "write_file", .exec = execWriteFile, .tool_def = write_file_mod.write_file_tool },
    .{ .name = "text_replace", .exec = execTextReplace, .tool_def = text_replace_mod.text_replace_tool },
    .{ .name = "remove_file", .exec = execRemoveFile, .tool_def = remove_file_mod.remove_file_tool },

    // === GIT WORKTREE BINDING ===
    .{ .name = "set_git_worktree", .exec = execSetGitWorktree, .tool_def = set_git_worktree_mod.set_git_worktree_tool },

    // === LSP TOOLS ===
    .{ .name = "lsp_definition", .exec = execLspDefinition, .tool_def = lsp_definition_mod.lsp_definition_tool },
    .{ .name = "lsp_references", .exec = execLspReferences, .tool_def = lsp_references_mod.lsp_references_tool },
    .{ .name = "lsp_workspace_symbol", .exec = execLspWorkspaceSymbol, .tool_def = lsp_workspace_symbol_mod.lsp_workspace_symbol_tool },
    .{ .name = "lsp_document_symbol", .exec = execLspDocumentSymbol, .tool_def = lsp_document_symbol_mod.lsp_document_symbol_tool },
    .{ .name = "lsp_hover", .exec = execLspHover, .tool_def = lsp_hover_mod.lsp_hover_tool },

    // === WEB SEARCH TOOLS ===
    // .{ .name = "web_search", .exec = execWebSearch, .tool_def = web_search_mod.web_search_tool },
    .{ .name = "nalar_browser", .exec = execNalarBrowser, .tool_def = nalar_browser_mod.nalar_browser_tool },

    // === FILE SEARCH TOOLS ===
    .{ .name = "glob", .exec = execGlob, .tool_def = glob_tool_mod.glob_tool },
    .{ .name = "search", .exec = execSearch, .tool_def = search_tool_mod.search_tool },
    // .{ .name = "semantic_search", .exec = execSemanticSearch, .tool_def = semantic_search_mod.semantic_search_tool },
    // .{ .name = "index_codebase", .exec = execIndexCodebase, .tool_def = semantic_search_mod.index_codebase_tool },
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
        list_memory_mod.list_memory_tool,
        view_skill_mod.view_skill_tool,
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
        nalar_browser_mod.nalar_browser_tool,
        set_git_worktree_mod.set_git_worktree_tool,
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
