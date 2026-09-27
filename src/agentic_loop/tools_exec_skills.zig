// Exec wrappers for the skill agent tools (`list_skills` / `use_skill` /
// `remove_skill` / `add_skill` / `edit_skill`) — merged 2026-09-11
// skills-merge refactor: one file, five exec fns. The public names
// (`execListSkills` / `execUseSkill` / `execRemoveSkill` / `execAddSkill` /
// `execEditSkill`) and behavior are unchanged.

const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const SkillSaveInfo = tools.SkillSaveInfo;
const agent = nalarcore.agent;
const skill_tools_mod = nalarcore.skill_tools;
const wrapToolOutput = tools.wrapToolOutput;

// ─── list_skills ───

pub fn execListSkills(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // Pass ctx.cwd so local skills are looked up in the session's workspace.
    // skills_db keys local rows by a canonicalised cwd, so a mismatch here
    // would make local skills invisible.
    const inner = skill_tools_mod.execute_list_skills(ctx.allocator, ctx.io, ctx.db, ctx.cwd) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "list_skills failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "list_skills", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "list_skills", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── use_skill ───

pub fn execUseSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = try std.json.parseFromSlice(
        skill_tools_mod.UseSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const inner = skill_tools_mod.execute_use_skill_to_string(ctx.allocator, ctx.io, ctx.db, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "use_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "use_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "use_skill", tc.function.arguments, true, null, inner);

    // Check if skill was successfully loaded and extract skill info for auto-save.
    // The inner payload is JSON (`{skill_name, content, loaded, ...}`); parse it
    // and key off `loaded` instead of substring-matching XML tags.
    if (std.json.parseFromSlice(skill_tools_mod.UseSkillOutput, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed_inner| {
        defer parsed_inner.deinit();
        if (parsed_inner.value.loaded) {
            const skill_name = try ctx.allocator.dupe(u8, parsed_inner.value.skill_name);
            const skill_content = try ctx.allocator.dupe(u8, parsed_inner.value.content);
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
    } else |_| {}

    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── remove_skill ───

pub fn execRemoveSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        skill_tools_mod.RemoveSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "remove_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = skill_tools_mod.execute_remove_skill_to_string(ctx.allocator, ctx.io, ctx.db, ctx.cwd, ctx.environment, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "remove_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // If the inner JSON carries an `error`, treat as failure.
    if (std.json.parseFromSlice(skill_tools_mod.RemoveSkillOutput, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed_inner| {
        defer parsed_inner.deinit();
        if (parsed_inner.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, false, err_msg, "");
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    } else |_| {}

    const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── add_skill ───

pub fn execAddSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        skill_tools_mod.AddSkillInput,
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
    // union); errors are encoded as `error` in the inner JSON object
    // and handled below.
    const inner = skill_tools_mod.executeAddSkillToString(ctx.allocator, ctx.io, ctx.db, ctx.cwd, ctx.environment, parsed.value);

    if (std.json.parseFromSlice(skill_tools_mod.AddSkillOutput, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed_inner| {
        defer parsed_inner.deinit();
        if (parsed_inner.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, false, err_msg, "");
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    } else |_| {}

    const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, true, null, inner);

    // No `skill_save` here: the dispatcher persists `exec_result.skill_saved`
    // verbatim (handle_tool.zig) and re-parsing the wrapped JSON was a
    // documented-but-never-implemented step. add_skill therefore does not
    // snapshot into session_skills — tracked separately, not part of the
    // skills-table move.
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── edit_skill ───

pub fn execEditSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        skill_tools_mod.EditSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "edit_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = skill_tools_mod.executeEditSkillToString(ctx.allocator, ctx.io, ctx.db, ctx.cwd, ctx.environment, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "edit_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // If the inner JSON carries an `error`, treat as failure.
    if (std.json.parseFromSlice(skill_tools_mod.EditSkillOutput, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed_inner| {
        defer parsed_inner.deinit();
        if (parsed_inner.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, false, err_msg, "");
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    } else |_| {}

    const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
