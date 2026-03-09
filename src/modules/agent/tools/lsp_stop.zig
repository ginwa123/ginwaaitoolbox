const std = @import("std");
const json = std.json;
const lsp_client_core = @import("lsp_client_core.zig");
const AgentTool = @import("models.zig").AgentTool;

// JSON-RPC shutdown request with custom serialization
const ShutdownRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: i32,
    method: []const u8 = "shutdown",

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("jsonrpc");
        try jws.write(self.jsonrpc);
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("method");
        try jws.write(self.method);
        try jws.objectField("params");
        try jws.write(null);
        try jws.endObject();
    }
};

// JSON-RPC exit notification (no id)
const ExitNotification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8 = "exit",

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("jsonrpc");
        try jws.write(self.jsonrpc);
        try jws.objectField("method");
        try jws.write(self.method);
        try jws.objectField("params");
        try jws.write(null);
        try jws.endObject();
    }
};

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

        // Use arena allocator for JSON building
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // Build shutdown request using the struct with jsonStringify
        const request = ShutdownRequest{ .id = request_id };

        var aw: std.io.Writer.Allocating = .init(arena_alloc);
        try aw.writer.print("{f}", .{std.json.fmt(request, .{})});
        const json_str = try aw.toOwnedSlice();
        defer arena_alloc.free(json_str);

        lsp_client_core.writeMessage(client.stdin, json_str) catch {};
        _ = lsp_client_core.readMessage(client.stdout, allocator) catch {};
    }

    // Send exit notification
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const exit_notification = ExitNotification{};
    var aw: std.io.Writer.Allocating = .init(arena_alloc);
    try aw.writer.print("{f}", .{std.json.fmt(exit_notification, .{})});
    const json_str = try aw.toOwnedSlice();
    defer arena_alloc.free(json_str);

    lsp_client_core.writeMessage(client.stdin, json_str) catch {};

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

test {
    _ = @import("lsp_stop_test.zig");
}
