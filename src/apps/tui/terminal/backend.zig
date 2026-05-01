const std = @import("std");
const Io = std.Io;
const globals = @import("../globals.zig");

const cImport = @cImport(@cInclude("unistd.h"));

pub fn spawnBackend(allocator: std.mem.Allocator, io: std.Io, verbose: bool, port: u16, process_name: []const u8) !void {
    const backend_path_str = try std.fmt.allocPrint(std.heap.page_allocator, "/usr/local/bin/{s}", .{process_name});
    defer std.heap.page_allocator.free(backend_path_str);

    const backend_path = try Io.Dir.realPathFileAbsoluteAlloc(io, backend_path_str, allocator);

    const already_running = try checkPortInUse(io, port);

    if (already_running) {
        if (verbose) std.debug.print("{s}Backend already running, skipping spawn{s}\n", .{ globals.green, globals.reset });
        return;
    }

    if (verbose) std.debug.print("{s}Spawning backend on port {d}{s}\n", .{ globals.yellow, port, globals.reset });

    const pid = cImport.fork();
    if (pid < 0) {
        return error.ForkFailed;
    }

    if (pid > 0) {
        _ = cImport.usleep(500_000);
        return;
    }

    const backend_path_z = try std.heap.page_allocator.dupeZ(u8, backend_path);
    defer std.heap.page_allocator.free(backend_path_z);

    if (cImport.daemon(1, 0) != 0) {
        return error.DaemonFailed;
    }

    const port_arg = "--port";
    var port_num_buf: [6]u8 = .{0} ** 6;
    const port_num_sentinel = std.fmt.bufPrintZ(&port_num_buf, "{}", .{port}) catch unreachable;
    const port_num_ptr: [*c]const u8 = @ptrCast(port_num_sentinel);
    const null_ptr: [*c]const u8 = null;
    _ = cImport.execl(backend_path_z, backend_path_z, port_arg, port_num_ptr, null_ptr);
    return error.ExecFailed;
}

fn checkPortInUse(io: std.Io, port: u16) !bool {
    const address = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return false;
    const stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch return false;
    stream.socket.close(io);
    return true;
}

pub fn waitForHttpServer(io: std.Io, timeout_ms: u64, port: u16) !void {
    const max_attempts = timeout_ms / 50;
    var attempts: u64 = 0;
    while (attempts < max_attempts) : (attempts += 1) {
        const address = std.Io.net.IpAddress.parse("127.0.0.1", port) catch {
            io.sleep(.{ .nanoseconds = 50_000_000 }, .real) catch {};
            continue;
        };
        const stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch {
            io.sleep(.{ .nanoseconds = 50_000_000 }, .real) catch {};
            continue;
        };
        stream.socket.close(io);
        return;
    }
    return error.Timeout;
}