const std = @import("std");
const builtin = @import("builtin");

// POSIX sockaddr_un - only needed on non-Windows
const sockaddr_un = if (builtin.os.tag != .windows)
    extern struct {
        sun_family: c_ushort,
        sun_path: [108]u8,
    }
else
    void;

pub const MessageHandler = *const fn (allocator: std.mem.Allocator, data: []const u8, ctx: ?*anyopaque, conn_fd: std.posix.fd_t) void;

pub const IpcServer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    socket_path: []const u8,
    message_handler: ?MessageHandler = null,
    ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, ctx: ?*anyopaque) Self {
        return .{
            .allocator = allocator,
            .socket_path = if (@import("builtin").os.tag == .windows)
                "\\\\.\\pipe\\agent.sock"
            else
                "/tmp/agent.sock",
            .ctx = ctx,
        };
    }

    pub fn messageIncoming(self: *Self, handler: MessageHandler) void {
        self.message_handler = handler;
    }

    pub fn onMessage(self: *Self, comptime name: []const u8, callback: MessageHandler) void {
        _ = name;
        self.message_handler = callback;
    }

    pub fn run(self: *Self) !void {
        if (@import("builtin").os.tag == .windows) {
            try self.runWindows();
        } else {
            try self.runUnix();
        }
    }

    fn handleMessage(self: *Self, data: []const u8, conn_fd: std.posix.fd_t) void {
        if (self.message_handler) |handler| {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            handler(arena.allocator(), data, self.ctx, conn_fd);
        }
    }

    fn handleConnection(self: *Self, conn_fd: std.posix.fd_t) void {
        defer std.posix.close(conn_fd);

        var message_buffer: std.ArrayList(u8) = .empty;
        defer message_buffer.deinit(self.allocator);

        var read_buffer: [4096]u8 = undefined;

        while (true) {
            const n = std.posix.read(conn_fd, &read_buffer) catch {
                return;
            };

            if (n == 0) {
                // Connection closed, process any remaining data
                if (message_buffer.items.len > 0) {
                    self.handleMessage(message_buffer.items, conn_fd);
                }
                return;
            }

            message_buffer.appendSlice(self.allocator, read_buffer[0..n]) catch {
                return;
            };

            // Check if we have a complete message (ends with </message>)
            if (std.mem.endsWith(u8, message_buffer.items, "</message>")) {
                self.handleMessage(message_buffer.items, conn_fd);
                message_buffer.clearRetainingCapacity();
            }
        }
    }

    fn runUnix(self: *Self) !void {
        const socket_fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        defer std.posix.close(socket_fd);

        std.fs.cwd().deleteFile(self.socket_path) catch {};

        const path_len = self.socket_path.len;
        const addr_len = @sizeOf(sockaddr_un);
        const bytes = try self.allocator.alloc(u8, addr_len);
        defer self.allocator.free(bytes);

        const addr = @as(*sockaddr_un, @ptrCast(@alignCast(bytes.ptr)));
        addr.* = std.mem.zeroInit(sockaddr_un, .{});
        addr.sun_family = std.posix.AF.UNIX;
        @memcpy(addr.sun_path[0..path_len], self.socket_path);
        addr.sun_path[path_len] = 0;

        try std.posix.bind(socket_fd, @as(*std.posix.sockaddr, @ptrCast(addr)), addr_len);
        try std.posix.listen(socket_fd, 128);

        std.debug.print("Listening on {s}\n", .{self.socket_path});

        while (true) {
            const conn_fd = try std.posix.accept(socket_fd, null, null, 0);
            _ = std.Thread.spawn(.{}, handleConnection, .{ self, conn_fd }) catch {
                std.posix.close(conn_fd);
            };
        }
    }

    fn runWindows(self: *Self) !void {
        const pipe_name = self.socket_path;

        while (true) {
            const pipe_fd = try std.os.windows.CreateNamedPipeA(
                pipe_name,
                std.os.windows.PIPE_ACCESS_DUPLEX,
                std.os.windows.PIPE_TYPE_MESSAGE | std.os.windows.PIPE_READMODE_MESSAGE | std.os.windows.PIPE_WAIT,
                1,
                65536, // Increased output buffer size
                65536, // Increased input buffer size
                0,
                null,
            );
            errdefer std.os.windows.CloseHandle(pipe_fd);

            try std.os.windows.ConnectNamedPipe(pipe_fd, null);

            // Use dynamic buffer for Windows as well
            var message_buffer: std.ArrayList(u8) = .empty;
            defer message_buffer.deinit(self.allocator);

            var read_buffer: [4096]u8 = undefined;
            while (true) {
                var bytes_read: u32 = undefined;
                const result = std.os.windows.ReadFile(pipe_fd, &read_buffer, null, &bytes_read, null);
                if (result) {
                    if (bytes_read == 0) break;
                    message_buffer.appendSlice(self.allocator, read_buffer[0..bytes_read]) catch break;
                } else |_| {
                    break;
                }
            }

            if (message_buffer.items.len > 0) {
                self.handleMessage(message_buffer.items, -1);
            }

            var bytes_written: u32 = undefined;
            try std.os.windows.WriteFile(pipe_fd, "ok", null, &bytes_written, null);

            std.os.windows.CloseHandle(pipe_fd);
        }
    }
};

test {
    _ = @import("ipc_test.zig");
}
