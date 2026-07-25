const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const tools = mod.tools;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const SkillSaveInfo = tools.SkillSaveInfo;
const agent = nalarcore.agent;
const add_skill_mod = nalarcore.add_skill;
const wrapToolOutput = tools.wrapToolOutput;

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

    // The registry entry has auto_save_skill = true → the dispatcher in
    // handle_tool.zig reads `output` to extract <skill_name>...</skill_name>
    // and <content>...</content>, then saves to session_skills. We return
    // skill_save (not used directly here, but kept for symmetry with
    // execGetSkill's auto-save contract — both rely on the dispatcher's
    // parsing pass over the wrapped output).
    _ = SkillSaveInfo;
    return ToolExecResult{ .output = output, .output_allocated = true };
}