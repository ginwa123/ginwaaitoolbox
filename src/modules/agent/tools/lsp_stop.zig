const std = @import("std");
const lsp_client_core = @import("lsp_client_core.zig");
const AgentTool = @import("models.zig").AgentTool;

pub const LspStopInput = struct {
    session_id: []const u8,
};

pub const LspStopOutput = struct {
    session_id: []u8,
    status: []u8,
};

pub fn executeLspStop(allocator: std.mem.Allocator, input: LspStopInput) !LspStopOutput {
    const sessions_ptr = lsp_client_core.getSessions();
    const client = sessions_ptr.get(input.session_id) orelse return lsp_client_core.LspError.SessionNotFound;
    
    // Send shutdown request if initialized
    if (client.initialized) {
        const request_id = client.next_request_id;
        client.next_request_id += 1;

        var req_json = std.ArrayList(u8).empty;
        defer req_json.deinit(allocator);

        try req_json.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
        try req_json.writer(allocator).print("{d}", .{request_id});
        try req_json.appendSlice(allocator, ",\"method\":\"shutdown\",\"params\":null}");

        lsp_client_core.writeMessage(client.stdin, req_json.items) catch {};
        _ = lsp_client_core.readMessage(client.stdout, allocator) catch {};
    }

    // Send exit notification
    var exit_json = std.ArrayList(u8).empty;
    defer exit_json.deinit(allocator);
    try exit_json.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    lsp_client_core.writeMessage(client.stdin, exit_json.items) catch {};

    // Kill process if still alive
    _ = client.process.kill() catch {};

    // Wait for process to exit
    _ = client.process.wait() catch {};

    // Remove from sessions
    _ = sessions_ptr.remove(input.session_id);
    client.deinit();
    allocator.destroy(client);
    
    return .{
        .session_id = try allocator.dupe(u8, input.session_id),
        .status = try allocator.dupe(u8, "stopped"),
    };
}

pub fn lspStopToString(allocator: std.mem.Allocator, result: LspStopOutput) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<session_id>{s}</session_id>
        \\<status>{s}</status>
    , .{
        result.session_id,
        result.status,
    });
}

pub const lspStopTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "lsp_stop",
        .description = "Stop an LSP server for a session. Sends shutdown → exit → kills process.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "session_id",
                    .type = "string",
                    .description = "Session identifier to stop",
                },
            },
            .required = &.{"session_id"},
        },
    },
};
