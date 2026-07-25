const std = @import("std");
const mod = @import("mod.zig");
const tools = mod.tools;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = mod.nalarcore.agent;
const wrapToolOutput = tools.wrapToolOutput;

// Placeholder LSP exec function (not yet implemented).
pub fn execLspHover(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const output = try wrapToolOutput(ctx.allocator, "lsp_hover", tc.function.arguments, false, "lsp_hover not implemented", "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}
