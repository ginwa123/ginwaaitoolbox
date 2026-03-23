const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const lsp_document_symbol_tool = tree1_mod.tools.lsp_document_symbol;

/// Stateless lsp_document_symbol tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute lsp_document_symbol
/// Returns the result as string or error.
///
/// Note: This tool spawns zls, gets document symbols, and cleans up automatically.
pub fn handle_lsp_document_symbol_tool_run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Parse arguments JSON to LspDocumentSymbolInput
    const parsed = std.json.parseFromSlice(
        lsp_document_symbol_tool.LspDocumentSymbolInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "<error>Failed to parse lsp_document_symbol arguments: {s}</error>",
            .{@errorName(err)},
        );
    };
    defer parsed.deinit();

    const result = lsp_document_symbol_tool.executeLspDocumentSymbol(allocator, parsed.value) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "<error>Failed to get document symbols: {s}</error>",
            .{@errorName(err)},
        );
    };
    defer result.deinit(allocator);

    return lsp_document_symbol_tool.lspDocumentSymbolToString(allocator, result);
}
