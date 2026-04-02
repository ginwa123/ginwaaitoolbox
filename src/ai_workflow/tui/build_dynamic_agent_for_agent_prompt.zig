const std = @import("std");
const tree1_mod = @import("nalarcore");
const sqlite = tree1_mod.sqlite;

/// Build dynamic agents content string from database for persistence
pub fn BuildDynamicAgentContent(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) {
        return allocator.dupe(u8, "");
    }

    var agentsBuilder: std.ArrayList(u8) = .empty;
    errdefer agentsBuilder.deinit(allocator);

    const sql = "SELECT agent_name FROM session_agents WHERE session_id = ?";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    var hasAgents = false;
    while (try rows.next()) |row| {
        hasAgents = true;
        const agent_name = row.values[0];
        try agentsBuilder.appendSlice(allocator, "- ");
        try agentsBuilder.appendSlice(allocator, agent_name);
        try agentsBuilder.appendSlice(allocator, "\n");
        row.deinit(allocator);
    }

    if (!hasAgents) {
        return allocator.dupe(u8, "");
    }

    // Prepend the header to the existing content
    const header = "\n\n## Loaded Dynamic Agents\n\n";
    const result = try allocator.alloc(u8, header.len + agentsBuilder.items.len);
    @memcpy(result[0..header.len], header);
    @memcpy(result[header.len..], agentsBuilder.items);
    return result;
}

