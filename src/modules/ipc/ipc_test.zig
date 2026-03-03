const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("ipc.zig");

// POSIX sockaddr_un - only needed on non-Windows for tests
const c = if (builtin.os.tag != .windows) struct {
    const sockaddr_un = extern struct {
        sun_family: c_ushort,
        sun_path: [108]u8,
    };
} else struct {
    // Placeholder for Windows - tests that need this are skipped
    const sockaddr_un = void;
};
const testing = std.testing;

test "IpcServer init returns correct socket path on unix" {
    const allocator = std.testing.allocator;
    const server = ipc.IpcServer.init(allocator, null);

    if (@import("builtin").os.tag == .windows) {
        try testing.expectEqualStrings("\\\\.\\pipe\\agent.sock", server.socket_path);
    } else {
        try testing.expectEqualStrings("/tmp/agent.sock", server.socket_path);
    }
}

test "IpcServer allocator is set correctly" {
    const allocator = std.testing.allocator;
    const server = ipc.IpcServer.init(allocator, null);

    try testing.expectEqual(allocator, server.allocator);
}

test "socket path length is reasonable" {
    const allocator = std.testing.allocator;
    const server = ipc.IpcServer.init(allocator, null);

    try testing.expect(server.socket_path.len > 0);
}

test "messageIncoming callback can be set" {
    const allocator = std.testing.allocator;
    var server = ipc.IpcServer.init(allocator, null);

    server.messageIncoming(struct {
        fn handler(_allocator: std.mem.Allocator, data: []const u8, ctx: ?*anyopaque, conn_fd: std.posix.fd_t) void {
            _ = _allocator;
            _ = data;
            _ = ctx;
            _ = conn_fd;
        }
    }.handler);

    try testing.expect(server.message_handler != null);
}

test "IPC client disconnects before server responds" {
    if (@import("builtin").os.tag == .windows) {
        return error.SkipZigTest;
    }

    const socket_path = "/tmp/test_ipc_disconnect.sock";

    std.fs.cwd().deleteFile(socket_path) catch {};

    const server_fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(server_fd);

    var addr: c.sockaddr_un = std.mem.zeroInit(c.sockaddr_un, .{});
    addr.sun_family = 1; // AF_UNIX
    @memcpy(addr.sun_path[0..socket_path.len], socket_path);
    addr.sun_path[socket_path.len] = 0;

    try std.posix.bind(server_fd, @as(*std.posix.sockaddr, @ptrCast(&addr)), @sizeOf(c.sockaddr_un));
    try std.posix.listen(server_fd, 1);

    const test_message = "test message";

    const child = try std.Thread.spawn(.{}, struct {
        fn run(a: *c.sockaddr_un, msg: []const u8) void {
            const client_fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch return;
            defer std.posix.close(client_fd);

            std.posix.connect(client_fd, @as(*std.posix.sockaddr, @ptrCast(a)), @sizeOf(c.sockaddr_un)) catch return;
            _ = std.posix.write(client_fd, msg) catch return;
            // Disconnect immediately without waiting for response
        }
    }.run, .{ &addr, test_message });

    const conn_fd = try std.posix.accept(server_fd, null, null, 0);
    defer std.posix.close(conn_fd);

    var buffer: [1024]u8 = undefined;
    const n = try std.posix.read(conn_fd, &buffer);
    const received = buffer[0..n];

    child.join();

    try testing.expectEqualStrings(test_message, received);

    // Now try to write to the disconnected client - should not crash
    const response = "response from server";
    _ = std.posix.write(conn_fd, response) catch |err| {
        // Expected: BrokenPipe because client disconnected
        try testing.expect(err == error.BrokenPipe);
    };
}

test "IPC client can send data to server" {
    if (@import("builtin").os.tag == .windows) {
        return error.SkipZigTest;
    }

    const allocator = std.testing.allocator;
    const socket_path = "/tmp/test_ipc.sock";

    std.fs.cwd().deleteFile(socket_path) catch {};

    const server_fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(server_fd);

    var addr: c.sockaddr_un = std.mem.zeroInit(c.sockaddr_un, .{});
    addr.sun_family = 1; // AF_UNIX
    @memcpy(addr.sun_path[0..socket_path.len], socket_path);
    addr.sun_path[socket_path.len] = 0;

    try std.posix.bind(server_fd, @as(*std.posix.sockaddr, @ptrCast(&addr)), @sizeOf(c.sockaddr_un));
    try std.posix.listen(server_fd, 1);

    const test_message = "Hello from client";
    const received_data = try allocator.alloc(u8, 1024);
    defer allocator.free(received_data);

    const test_args = .{ &addr, test_message };

    const child = try std.Thread.spawn(.{}, struct {
        fn run(args: @TypeOf(test_args)) void {
            const a = args[0];
            const m = args[1];
            const client_fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch return;
            defer std.posix.close(client_fd);

            std.posix.connect(client_fd, @as(*std.posix.sockaddr, @ptrCast(a)), @sizeOf(c.sockaddr_un)) catch return;
            _ = std.posix.write(client_fd, m) catch return;
        }
    }.run, .{test_args});

    const conn_fd = try std.posix.accept(server_fd, null, null, 0);
    defer std.posix.close(conn_fd);

    const n = try std.posix.read(conn_fd, received_data);
    const received = received_data[0..n];

    child.join();

    try testing.expectEqualStrings(test_message, received);
}
