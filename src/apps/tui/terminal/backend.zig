const std = @import("std");
const tui_text = @import("tui-text");

const green = tui_text.ansi.green;
const yellow = tui_text.ansi.yellow;
const reset = tui_text.ansi.reset;

/// Spawn the backend server as a daemon process
pub fn spawnBackend(_: bool) !void {
    const backend_path = try std.fs.realpathAlloc(std.heap.page_allocator, "/usr/local/bin/nalar");
    defer std.heap.page_allocator.free(backend_path);

    // Check if backend is already running by trying to connect to HTTP port
    const test_socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch {
        // If we can't create a socket, skip spawning
        return;
    };
    defer std.posix.close(test_socket);

    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080);
    var already_running = false;
    std.posix.connect(test_socket, &addr.any, @sizeOf(std.net.Address)) catch {
        already_running = true;
    };

    if (already_running) {
        std.debug.print("{s}Backend already running, skipping spawn{s}\n", .{ green, reset });
        return;
    }

    // Spawn the backend using daemon() for proper daemonization
    const c = @cImport({
        @cInclude("unistd.h");
    });

    // Convert to null-terminated C string
    const backend_path_z = try std.heap.page_allocator.dupeZ(u8, backend_path);
    defer std.heap.page_allocator.free(backend_path_z);

    // daemon(1, 0) - change to / and close stdio
    // This is the standard Unix daemon() call
    if (c.daemon(1, 0) != 0) {
        std.debug.print("{s}Warning: daemon() failed{s}\n", .{ yellow, reset });
        return;
    }

    // We're now in the daemon child - execute the backend directly
    // Use execl which is simpler than execvp
    // Cast null to proper pointer type for variadic function
    const null_ptr: [*c]const u8 = null;
    _ = c.execl(backend_path_z, backend_path_z, null_ptr);
    // If we get here, exec failed
    std.debug.print("{s}Warning: failed to exec backend{s}\n", .{ yellow, reset });
    std.posix.exit(1);
}

/// Wait for the HTTP server to become available
pub fn waitForHttpServer(timeout_ms: u64, port: u16) !void {
    const start = std.time.milliTimestamp();
    while (true) {
        if (std.time.milliTimestamp() - start > timeout_ms) return error.Timeout;
        const socket_fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch {
            std.Thread.sleep(50_000_000);
            continue;
        };
        defer std.posix.close(socket_fd);
        var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        if (std.posix.connect(socket_fd, &addr.any, @sizeOf(std.net.Address))) {
            return;
        } else |_| {
            std.Thread.sleep(50_000_000);
        }
    }
}
