const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const list_skills_mod = nalarcore.list_skills_tool;
const wrapToolOutput = tools.wrapToolOutput;

const ListSkillsArgs = struct {
    cwd: ?[]const u8 = null,
};

pub fn execListSkills(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // 1. Parse the optional `cwd` from the JSON args.
    const parsed = std.json.parseFromSlice(
        ListSkillsArgs,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "list_skills failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "list_skills", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // 2. Security: reject absolute cwd paths.
    if (parsed.value.cwd) |cwd| {
        if (try nalarcore.path_security.rejectAbsolutePath(
            ctx.allocator, "list_skills", "cwd", cwd, ctx.cwd
        )) |err_msg| {
            defer ctx.allocator.free(err_msg);
            const output = try wrapToolOutput(ctx.allocator, "list_skills", tc.function.arguments, false, err_msg, "");
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }

    // 3. Resolve cwd: relative/null/empty → ctx.cwd_override ?? ctx.cwd.
    const resolved_cwd = try nalarcore.path_security.resolveCwd(
        ctx.allocator, ctx.cwd, ctx.cwd_override, parsed.value.cwd
    );
    defer ctx.allocator.free(resolved_cwd);

    const inner = list_skills_mod.execute_list_skills(ctx.allocator, ctx.io, resolved_cwd, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "list_skills failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "list_skills", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "list_skills", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
