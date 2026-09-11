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
    // Pass ctx.cwd so local skills are looked up in the session's workspace
    // (the same directory add_skill/edit_skill/remove_skill write to), matching
    // how those tools are invoked. Passing null here would make list_skills fall
    // back to the server's OS-level cwd, causing local skills to be invisible.
    const inner = skill_tools_mod.execute_list_skills(ctx.allocator, ctx.io, ctx.cwd, ctx.environment) catch |err| {
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

    const inner = skill_tools_mod.execute_use_skill_to_string(ctx.allocator, ctx.io, parsed.value, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "use_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "use_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "use_skill", tc.function.arguments, true, null, inner);

    // Check if skill was successfully loaded and extract skill info for auto-save.
    // The skill_save detection now looks for <success>true</success> in the WRAPPED
    // envelope, not <loaded>true</loaded> in the inner XML (which is now inside
    // <data>...</data>).
    if (std.mem.indexOf(u8, output, "<success>true</success>") != null) {
        // Extract skill name from <skill_name>...</skill_name>
        const name_start = (std.mem.indexOf(u8, output, "<skill_name>") orelse 0) + "<skill_name>".len;
        const name_end = std.mem.indexOf(u8, output[name_start..], "</skill_name>") orelse {
            return ToolExecResult{ .output = output, .output_allocated = true };
        };
        const skill_name = output[name_start .. name_start + name_end];

        // Extract content from <content>...</content>
        const content_start = (std.mem.indexOf(u8, output, "<content>") orelse 0) + "<content>".len;
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

    const inner = skill_tools_mod.execute_remove_skill_to_string(ctx.allocator, ctx.io, ctx.cwd, ctx.environment, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "remove_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // If inner has <error>...</error>, treat as failure
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse (inner.len - err_start);
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

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
    // union); errors are encoded as <error>...</error> in the XML
    // and handled below.
    const inner = skill_tools_mod.executeAddSkillToString(ctx.allocator, ctx.io, ctx.cwd, ctx.environment, parsed.value);

    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse (inner.len - err_start);
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, true, null, inner);

    // The registry entry has auto_save_skill = true → the dispatcher in
    // handle_tool.zig reads `output` to extract <skill_name>...</skill_name>
    // and <content>...</content>, then saves to session_skills. We return
    // skill_save (not used directly here, but kept for symmetry with
    // execUseSkill's auto-save contract — both rely on the dispatcher's
    // parsing pass over the wrapped output).
    _ = SkillSaveInfo;
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

    const inner = skill_tools_mod.executeEditSkillToString(ctx.allocator, ctx.io, ctx.cwd, ctx.environment, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "edit_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse (inner.len - err_start);
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
