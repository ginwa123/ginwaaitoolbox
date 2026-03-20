const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const lsp_workspace_symbol_tool = tree1_mod.tools.lsp_workspace_symbol;

/// Stateless lsp_workspace_symbol tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute lsp_workspace_symbol
/// Returns the result as string or error.
///
/// Note: This tool spawns zls, searches workspace symbols, and cleans up automatically.
pub fn run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Parse arguments JSON to LspWorkspaceSymbolInput
    const parsed = std.json.parseFromSlice(
        lsp_workspace_symbol_tool.LspWorkspaceSymbolInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "<error>Failed to parse lsp_workspace_symbol arguments: {s}</error>",
            .{@errorName(err)},
        );
    };
    defer parsed.deinit();

    const result = lsp_workspace_symbol_tool.executeLspWorkspaceSymbol(allocator, parsed.value) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "<error>Failed to search workspace symbols: {s}</error>",
            .{@errorName(err)},
        );
    };
    defer result.deinit(allocator);

    return lsp_workspace_symbol_tool.lspWorkspaceSymbolToString(allocator, result);
}
