const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const lsp_hover_tool = tree1_mod.tools.lsp_hover;

/// Stateless lsp_hover tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute lsp_hover
/// Returns the result as string or error.
///
/// Note: This tool spawns zls, gets hover info, and cleans up automatically.
pub fn handle_lsp_hover_tool_run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Parse arguments JSON to LspHoverInput
    const parsed = std.json.parseFromSlice(
        lsp_hover_tool.LspHoverInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "<error>Failed to parse lsp_hover arguments: {s}</error>",
            .{@errorName(err)},
        );
    };
    defer parsed.deinit();

    const result = lsp_hover_tool.executeLspHover(allocator, parsed.value) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "<error>Failed to get hover info: {s}</error>",
            .{@errorName(err)},
        );
    };
    defer result.deinit(allocator);

    return lsp_hover_tool.lspHoverToString(allocator, result);
}
