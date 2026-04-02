const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const search_tool = tree1_mod.search_tool;

/// Stateless search tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute search
/// Returns the search result as string or error.
///
/// All side effects (DB, logging, socket, message list) must be handled by caller.
pub fn handle_search_tool_run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Handle empty arguments - treat as empty JSON object
    const args = tool_call.function.arguments;
    const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;

    // Parse arguments JSON to SearchInput
    const parsed = try std.json.parseFromSlice(
        search_tool.SearchInput,
        allocator,
        args_to_parse,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    var search_result = try search_tool.executeSearch(allocator, parsed.value);

    // If there are no matches, return the raw content (which may contain warning)
    if (search_result.matches.items.len == 0) {
        const content = try allocator.dupe(u8, search_result.content);
        search_result.deinit(allocator);
        return content;
    }

    // Convert search result to string format
    const res_search = try search_tool.searchResultToString(allocator, search_result);
    // Caller is responsible for freeing this returned string
    // Also need to free the search_result
    search_result.deinit(allocator);

    return res_search;
}

