const std = @import("std");
const globals = @import("../globals.zig");
const raw_mode = @import("../terminal/raw_mode.zig");
const App = @import("../main.zig").App;

fn getTimeMillis() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Wait for SSE "connected" event from server
/// Returns true if connected event received, false on timeout/error
pub fn waitForSseConnected(socket: std.c.fd_t, timeout_ms: u64) bool {
    var buf: [4096]u8 = undefined;
    const start = getTimeMillis();

    var enable: u32 = 1;
    _ = std.c.setsockopt(socket, std.c.SOL.SOCKET, std.c.SO.KEEPALIVE, @ptrCast(&enable), @sizeOf(u32));

    while (true) {
        if (getTimeMillis() - start > timeout_ms) return false;

        var poll_fd = [1]std.c.pollfd{
            .{ .fd = socket, .events = std.c.POLL.IN, .revents = 0 },
        };

        const ready = std.c.poll(&poll_fd, poll_fd.len, 100);
        if (ready > 0 and (poll_fd[0].revents & std.c.POLL.IN != 0)) {
            const n = std.c.read(socket, &buf, buf.len);
            if (n <= 0) return false;
            if (std.mem.indexOf(u8, buf[0..@intCast(n)], "event: connected") != null) {
                return true;
            }
        }
    }
}

/// Reconnect to SSE stream for the given session
/// Returns new socket fd on success, -1 on failure
pub fn reconnectSseStream(app: *App, _: std.mem.Allocator, current_socket: std.c.fd_t) std.c.fd_t {
    _ = std.c.close(current_socket);

    // Use high-level std.Io.net API to reconnect
    const address = std.Io.net.IpAddress.parse("127.0.0.1", app.http_port) catch return -1;
    const stream = std.Io.net.IpAddress.connect(&address, app.io, .{ .mode = .stream }) catch return -1;

    // Return the socket fd
    return @intCast(stream.socket.handle);
}