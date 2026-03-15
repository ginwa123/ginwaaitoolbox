const std = @import("std");
const tree1_mod = @import("nalarcore");
const sqlite = tree1_mod.sqlite;

/// Create a new session in the database
pub fn createSession(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    agent_type: []const u8,
    model: []const u8,
    temperature: f32,
) ![]const u8 {
    // Generate session ID
    var session_id_buf: [64]u8 = undefined;
    const session_id = try std.fmt.bufPrint(&session_id_buf, "kerjabot_{}", .{std.time.timestamp()});

    // Insert session into database
    const insert_sql = "INSERT INTO llm_history (id, session_id, model, response_content, role, agent, temperature, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))";
    
    const temp_str = try std.fmt.allocPrint(allocator, "{d}", .{temperature});
    defer allocator.free(temp_str);
    
    try db.exec(allocator, insert_sql, &.{ session_id, session_id, model, "", "system", agent_type, temp_str });

    return session_id;
}
