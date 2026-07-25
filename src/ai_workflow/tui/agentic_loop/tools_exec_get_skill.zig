const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const tools = mod.tools;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const SkillSaveInfo = tools.SkillSaveInfo;
const agent = nalarcore.agent;
const get_skill_mod = nalarcore.get_skill_tool;
const wrapToolOutput = tools.wrapToolOutput;

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