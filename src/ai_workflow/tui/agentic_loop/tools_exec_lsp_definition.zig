const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const tools = mod.tools;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const lsp_definition_mod = nalarcore.tools.lsp_definition;
const wrapToolOutput = tools.wrapToolOutput;

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