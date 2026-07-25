const std = @import("std");
const mod = @import("mod.zig");
const tools = mod.tools;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = mod.nalarcore.agent;
const wrapToolOutput = tools.wrapToolOutput;

// Placeholder LSP exec function (not yet implemented).
pub fn execLspWorkspaceSymbol(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const output = try wrapToolOutput(ctx.allocator, "lsp_workspace_symbol", tc.function.arguments, false, "lsp_workspace_symbol not implemented", "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}
