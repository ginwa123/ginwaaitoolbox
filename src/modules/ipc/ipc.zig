const std = @import("std");
const c = @cImport({
    @cInclude("sys/un.h");
});

pub const MessageHandler = *const fn (data: []const u8) void;

pub const IpcServer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    socket_path: []const u8,
    message_handler: ?MessageHandler = null,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .socket_path = if (@import("builtin").os.tag == .windows)
                "\\\\.\\pipe\\agent.sock"
            else
                "/tmp/agent.sock",
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

    fn handleMessage(self: *Self, data: []const u8) void {
        if (self.message_handler) |handler| {
            handler(data);
        }
    }

    fn runUnix(self: *Self) !void {
        const socket_fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        defer std.posix.close(socket_fd);

        std.fs.cwd().deleteFile(self.socket_path) catch {};

        const path_len = self.socket_path.len;
        const addr_len = @sizeOf(c.sockaddr_un);
        const bytes = try self.allocator.alloc(u8, addr_len);
        defer self.allocator.free(bytes);

        const addr = @as(*c.sockaddr_un, @ptrCast(@alignCast(bytes.ptr)));
        addr.* = std.mem.zeroInit(c.sockaddr_un, .{});
        addr.sun_family = std.posix.AF.UNIX;
        @memcpy(addr.sun_path[0..path_len], self.socket_path);
        addr.sun_path[path_len] = 0;

        try std.posix.bind(socket_fd, @as(*std.posix.sockaddr, @ptrCast(addr)), addr_len);
        try std.posix.listen(socket_fd, 128);

        std.debug.print("Listening on {s}\n", .{self.socket_path});

        while (true) {
            const conn_fd = try std.posix.accept(socket_fd, null, null, 0);
            defer std.posix.close(conn_fd);

            var buffer: [1024]u8 = undefined;
            const n = try std.posix.read(conn_fd, &buffer);

            self.handleMessage(buffer[0..n]);

            _ = try std.posix.write(conn_fd, "ok");
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
                1024,
                1024,
                0,
                null,
            );
            errdefer std.os.windows.CloseHandle(pipe_fd);

            try std.os.windows.ConnectNamedPipe(pipe_fd, null);

            var buffer: [1024]u8 = undefined;
            var bytes_read: u32 = undefined;
            try std.os.windows.ReadFile(pipe_fd, &buffer, null, &bytes_read, null);

            self.handleMessage(buffer[0..bytes_read]);

            var bytes_written: u32 = undefined;
            try std.os.windows.WriteFile(pipe_fd, "ok", null, &bytes_written, null);

            std.os.windows.CloseHandle(pipe_fd);
        }
    }
};
