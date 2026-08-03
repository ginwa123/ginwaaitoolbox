const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const wrapToolOutput = tools.wrapToolOutput;

// Placeholder LSP exec function (not yet implemented).
pub fn execLspDocumentSymbol(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const output = try wrapToolOutput(ctx.allocator, "lsp_document_symbol", tc.function.arguments, false, "lsp_document_symbol not implemented", "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}
