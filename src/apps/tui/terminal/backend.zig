const std = @import("std");
const tui_text = @import("tui-text");

const green = tui_text.ansi.green;
const yellow = tui_text.ansi.yellow;
const reset = tui_text.ansi.reset;

/// Spawn the backend server as a daemon process
pub fn spawnBackend(verbose: bool, port: u16) !void {
    const backend_path = try std.fs.realpathAlloc(std.heap.page_allocator, "/usr/local/bin/nalar");
    defer std.heap.page_allocator.free(backend_path);

    // Check if backend is already running by trying to connect to HTTP port
    const test_socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch {
        // If we can't create a socket, skip spawning
        return;
    };
    defer std.posix.close(test_socket);

    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    var already_running = false;
    if (std.posix.connect(test_socket, &addr.any, @sizeOf(std.net.Address))) {
        already_running = true;
    } else |_| {
        already_running = false;
    }

    if (already_running) {
        if (verbose) std.debug.print("{s}Backend already running, skipping spawn{s}\n", .{ green, reset });
        return;
    }

    if (verbose) std.debug.print("{s}Spawning backend on port {d}{s}\n", .{ yellow, port, reset });

    // Fork a child process to run the backend
    const c = @cImport({
        @cInclude("unistd.h");
        @cInclude("sys/wait.h");
    });

    const pid = c.fork();
    if (pid < 0) {
        return error.ForkFailed;
    }

    if (pid > 0) {
        // Parent process - return immediately
        // Give the child process a moment to start
        _ = c.usleep(500_000); // 500ms
        return;
    }

    // Child process - daemonize and run the backend
    // Convert to null-terminated C string
    const backend_path_z = try std.heap.page_allocator.dupeZ(u8, backend_path);
    defer std.heap.page_allocator.free(backend_path_z);

    // daemon(1, 0) - change to / and close stdio
    // This is the standard Unix daemon() call
    if (c.daemon(1, 0) != 0) {
        return error.DaemonFailed;
    }

    // Use execl with --port argument
    const port_arg = "--port";
    var port_num_buf: [6]u8 = .{0} ** 6;
    const port_num_sentinel = std.fmt.bufPrintZ(&port_num_buf, "{}", .{port}) catch unreachable;
    const port_num_ptr: [*c]const u8 = @ptrCast(port_num_sentinel);

    const null_ptr: [*c]const u8 = null;
    _ = c.execl(backend_path_z, backend_path_z, port_arg, port_num_ptr, null_ptr);
    // If we get here, exec failed
    return error.ExecFailed;
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
        std.posix.connect(socket_fd, &addr.any, @sizeOf(std.net.Address)) catch {
            std.Thread.sleep(50_000_000);
            continue;
        };
        return;
    }
}
