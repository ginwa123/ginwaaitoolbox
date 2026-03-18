const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const lsp_references_tool = tree1_mod.tool_models.lsp_references;

/// Stateless lsp_references tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute lsp_references
/// Returns the result as string or error.
///
/// Note: This tool spawns zls, gets references, and cleans up automatically.
pub fn run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Parse arguments JSON to LspReferencesInput
    const parsed = std.json.parseFromSlice(
        lsp_references_tool.LspReferencesInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "<error>Failed to parse lsp_references arguments: {s}</error>",
            .{@errorName(err)},
        );
    };
    defer parsed.deinit();

    const result = lsp_references_tool.executeLspReferences(allocator, parsed.value) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "<error>Failed to get references: {s}</error>",
            .{@errorName(err)},
        );
    };
    defer result.deinit(allocator);

    return lsp_references_tool.lspReferencesToString(allocator, result);
}
