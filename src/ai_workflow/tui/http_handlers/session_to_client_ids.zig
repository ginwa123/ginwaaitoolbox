const std = @import("std");
const root_mod = @import("nalarcore");

const gserverz = root_mod.gserverz;
const http_response = root_mod.http_response;

/// Response structure for session to client IDs mapping
pub const SessionToClientIdsEntry = struct {
    session_id: []const u8,
    client_ids: []const []const u8,
};

pub const SessionToClientIdsResponse = struct {
    sessions: []const SessionToClientIdsEntry,
    total_sessions: u32,
    total_clients: u32,
};

/// Convert a [16]u8 client ID to a hex string
fn clientIdToHex(client_id: [16]u8, allocator: std.mem.Allocator) ![]u8 {
    const hex_chars = "0123456789abcdef";
    const result = try allocator.alloc(u8, 32);
    for (client_id, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return result;
}

/// Handler to get all session to client IDs mappings
pub fn sessionToClientIdsHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    _ = req;

    const di = root_mod.getSingleton() catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server context not initialized" }) });
    };

    const io = di.io;

    // Acquire lock to read session_to_client_ids
    try di.session_map_lock.lock(io);
    defer di.session_map_lock.unlock(io);

    var entries = std.ArrayListUnmanaged(SessionToClientIdsEntry){.items = &.{}, .capacity = 0};
    var total_clients: u32 = 0;

    var it = di.session_to_client_ids.iterator();
    while (it.next()) |entry| {
        const session_id = entry.key_ptr.*;
        const client_list = entry.value_ptr.*;

        // Allocate space for client ID hex strings
        var client_id_hexes = std.ArrayListUnmanaged([]const u8){.items = &.{}, .capacity = 0};

        for (client_list.items) |client_id| {
            const hex_str = try clientIdToHex(client_id, allocator);
            try client_id_hexes.append(allocator, hex_str);
            total_clients += 1;
        }

        try entries.append(allocator, .{
            .session_id = session_id,
            .client_ids = try allocator.dupe([]const u8, client_id_hexes.items),
        });
    }

    // Build response
    const response_data = SessionToClientIdsResponse{
        .sessions = entries.items,
        .total_sessions = @as(u32, @intCast(entries.items.len)),
        .total_clients = total_clients,
    };
    const response = try std.json.Stringify.valueAlloc(allocator, response_data, .{});

    return res.jsonResponse(.{ .status_code = 200, .data = response });
}
