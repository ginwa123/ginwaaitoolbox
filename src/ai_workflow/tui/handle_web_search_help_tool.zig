const std = @import("std");
const root_mod = @import("nalarcore");
const agent = root_mod.agent;
const web_search_help_mod = root_mod.web_search_help;

/// Run with database context
pub fn runWithContext(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
    db: ?*root_mod.sqlite.SqliteBackend,
    session_id: ?[]const u8,
) ![]const u8 {
    _ = db;
    _ = session_id;
    _ = tool_call;

    const result = try web_search_help_mod.executeWebSearchHelp(allocator);
    defer result.deinit(allocator);

    return result.content;
}
