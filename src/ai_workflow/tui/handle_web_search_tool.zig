const std = @import("std");
const root_mod = @import("nalarcore");
const agent = root_mod.agent;
const web_search_mod = root_mod.web_search;
const tool_models = root_mod.tool_models;

/// Run with database context
pub fn runWithContext(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
    db: ?*root_mod.sqlite.SqliteBackend,
    session_id: ?[]const u8,
) ![]const u8 {
    _ = db;
    _ = session_id;

    // Parse arguments JSON to WebSearchInput
    const parsed = try std.json.parseFromSlice(
        tool_models.WebSearchInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const result = try web_search_mod.executeWebSearch(allocator, parsed.value);
    defer result.deinit(allocator);

    const output = try web_search_mod.webSearchResultToString(allocator, result);
    return output;
}
