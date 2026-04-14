const std = @import("std");
const session_registry = @import("session_registry.zig");

pub const SessionMonitor = struct {
    const Self = @This();

    thread: std.Thread,
    running: std.atomic.Value(bool),

    pub const CHECK_INTERVAL_MS = 30_000; // 30 seconds

    pub fn spawn() !Self {
        var self = Self{
            .thread = undefined,
            .running = std.atomic.Value(bool).init(true),
        };
        self.thread = try std.Thread.spawn(.{}, monitorLoop, .{&self.running});
        return self;
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .seq_cst);
        self.thread.join();
    }

    fn monitorLoop(running: *std.atomic.Value(bool)) void {
        while (running.load(.seq_cst)) {
            // Sleep for 30 seconds
            std.Thread.sleep(CHECK_INTERVAL_MS * std.time.ns_per_ms);

            // Check if we should still be running
            if (!running.load(.seq_cst)) break;

            // Check registry status
            const registry = session_registry.get_global_registry();
            // for now we will disabled this
            // if (registry == null) {
            //     std.log.info("SessionMonitor: No registry found, exiting process", .{});
            //     std.posix.exit(0);
            // }
            //
            // if (!registry.?.has_sessions()) {
            //     std.log.info("SessionMonitor: No active sessions, exiting process", .{});
            //     std.posix.exit(0);
            // }

            std.log.debug("SessionMonitor: {d} active session(s), continuing", .{registry.?.session_count()});
        }
    }
};

