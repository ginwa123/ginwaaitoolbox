const std = @import("std");
const globals = @import("../globals.zig");
const raw_mode = @import("../terminal/raw_mode.zig");
const App = @import("../main.zig").App;

/// Wait for SSE "connected" event from server
/// Returns true if connected event received, false on timeout/error
pub fn waitForSseConnected(socket: std.posix.fd_t, timeout_ms: u64) bool {
    var buf: [4096]u8 = undefined;
    const start = std.time.milliTimestamp();

    // Enable TCP keepalive to detect connection drops
    var enable: u32 = 1;
    std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&enable)) catch {};

    while (true) {
        if (std.time.milliTimestamp() - start > timeout_ms) return false;

        var poll_fd = [1]std.posix.pollfd{
            .{ .fd = socket, .events = std.posix.POLL.IN, .revents = 0 },
        };

        const ready = std.posix.poll(&poll_fd, 100) catch 0;
        if (ready > 0 and (poll_fd[0].revents & std.posix.POLL.IN != 0)) {
            const n = std.posix.read(socket, &buf) catch return false;
            if (n == 0) return false;
            if (std.mem.indexOf(u8, buf[0..n], "event: connected") != null) {
                return true;
            }
        }
    }
}

/// Reconnect to SSE stream for the given session
/// Returns new socket fd on success, -1 on failure
pub fn reconnectSseStream(app: *App, alloc: std.mem.Allocator, current_socket: std.posix.fd_t) std.posix.fd_t {
    // Close old socket
    std.posix.close(current_socket);

    // Create new socket
    const new_socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch return -1;

    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, app.http_port);
    std.posix.connect(new_socket, &addr.any, @sizeOf(std.net.Address)) catch {
        std.posix.close(new_socket);
        return -1;
    };

    // Send stream request
    const stream_request = std.fmt.allocPrint(alloc, "GET /api/stream/{s} HTTP/1.1\r\nHost: {s}:{d}\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n", .{ app.session_id, globals.HTTP_HOST, app.http_port }) catch {
        std.posix.close(new_socket);
        return -1;
    };

    _ = std.posix.write(new_socket, stream_request) catch {
        std.posix.close(new_socket);
        return -1;
    };

    // Wait for connected event
    if (!waitForSseConnected(new_socket, 5000)) {
        std.posix.close(new_socket);
        return -1;
    }

    return new_socket;
}
