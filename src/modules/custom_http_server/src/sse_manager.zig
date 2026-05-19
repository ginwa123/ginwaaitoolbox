const std = @import("std");
const posix = std.posix;
const socket = posix.system;
const c = std.c;

const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const is_linux = builtin.os.tag == .linux;
const is_macos = builtin.os.tag == .macos;
const is_bsd = switch (builtin.os.tag) {
    .freebsd, .openbsd, .netbsd, .dragonfly => true,
    else => false,
};

const LOOP_COUNT = 4;

pub const Self = @This();

pub const SseClient = struct {
    io: std.Io,
    id: [16]u8,
    fd: i32,
    arena: std.heap.ArenaAllocator,
    alive: bool,
    last_heartbeat: u64,
    message_queue: std.ArrayListUnmanaged([]const u8),
    lock: std.Io.Mutex = .init,

    pub fn init(id: [16]u8, fd: i32, parent_allocator: std.mem.Allocator, io: std.Io) SseClient {
        return .{
            .id = id,
            .fd = fd,
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .alive = true,
            .last_heartbeat = timestamp(),
            .message_queue = .empty,
            .lock = .init,
            .io = io,
        };
    }

    pub fn allocator(self: *SseClient) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *SseClient) void {
        self.message_queue.deinit(self.allocator());
        self.arena.deinit();
        _ = socket.close(self.fd);
    }

    pub fn forceDestroy(self: *SseClient) void {
        _ = socket.close(self.fd);
    }

    pub fn markDisconnected(self: *SseClient) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.alive = false;
    }

    pub fn sendEvent(self: *SseClient, event: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
        if (!self.alive) return error.ClientDisconnected;
        const n = socket.write(self.fd, event.ptr, event.len);
        if (n < 0) {
            self.alive = false;
            return error.ClientDisconnected;
        }
    }
};

pub const SseManager = struct {
    io: std.Io,
    clients: std.AutoHashMapUnmanaged([16]u8, *SseClient),
    fd_to_id: std.AutoHashMapUnmanaged(i32, [16]u8),
    lock: std.Io.Mutex = .init,
    allocator: std.mem.Allocator,
    server_allocator: std.mem.Allocator,
    running: bool,
    on_disconnect: ?*const fn (client_id: [16]u8) void = null,
    notify_pipe: [2]i32,

    pub fn init(allocator: std.mem.Allocator, server_allocator: std.mem.Allocator, io: std.Io) !SseManager {
        var notify_pipe: [2]i32 = .{ -1, -1 };
        if (!is_windows) {
            const rc = socket.pipe(&notify_pipe);
            if (rc < 0) return error.PipeFailed;
        }
        return .{
            .clients = .empty,
            .fd_to_id = .empty,
            .lock = .init,
            .allocator = allocator,
            .server_allocator = server_allocator,
            .running = true,
            .io = io,
            .notify_pipe = notify_pipe,
        };
    }

    pub fn deinit(self: *SseManager) void {
        self.running = false;
        if (self.notify_pipe[1] >= 0) {
            var byte_buf: [1]u8 = .{'q'};
            _ = socket.write(self.notify_pipe[1], &byte_buf, 1);
        }
        self.lock.lock(self.io) catch unreachable;
        defer self.lock.unlock(self.io);

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.forceDestroy();
        }
        self.clients.clearRetainingCapacity();
        self.fd_to_id.clearRetainingCapacity();

        if (self.notify_pipe[0] >= 0) _ = socket.close(self.notify_pipe[0]);
        if (self.notify_pipe[1] >= 0) _ = socket.close(self.notify_pipe[1]);
    }

    pub fn registerClient(self: *SseManager, fd: i32) ![16]u8 {
        _ = try self.lock.lock(self.io);
        defer self.lock.unlock(self.io);

        if (self.getClientIdByFdLocked(fd)) |id| return id;

        var id: [16]u8 = undefined;
        while (true) {
            self.io.random(&id);
            if (!self.clients.contains(id)) break;
        }

        const client = try self.server_allocator.create(SseClient);
        client.* = SseClient.init(id, fd, self.allocator, self.io);

        try self.clients.put(self.server_allocator, id, client);
        try self.fd_to_id.put(self.server_allocator, fd, id);

        // Wake up all event loops so they pick up the new client
        self.notifyLoops();

        return id;
    }

    pub fn removeClient(self: *SseManager, id: [16]u8) void {
        self.lock.lock(self.io) catch unreachable;
        defer self.lock.unlock(self.io);

        if (self.clients.fetchRemove(id)) |entry| {
            _ = self.fd_to_id.remove(entry.value.*.fd);
            entry.value.*.deinit();
            self.server_allocator.destroy(entry.value);
            if (self.on_disconnect) |cb| cb(id);
        }
    }

    pub fn removeClientByFd(self: *SseManager, fd: i32) ?[16]u8 {
        self.lock.lock(self.io) catch unreachable;
        defer self.lock.unlock(self.io);

        if (self.fd_to_id.fetchRemove(fd)) |entry| {
            const id = entry.value;
            if (self.clients.fetchRemove(id)) |client_entry| {
                client_entry.value.*.deinit();
                self.server_allocator.destroy(client_entry.value);
            }
            if (self.on_disconnect) |cb| cb(id);
            return id;
        }
        return null;
    }

    fn getClientIdByFdLocked(self: *SseManager, fd: i32) ?[16]u8 {
        return self.fd_to_id.get(fd);
    }

    pub fn getClientIdByFd(self: *SseManager, fd: i32) ?[16]u8 {
        self.lock.lock(self.io) catch unreachable;
        defer self.lock.unlock(self.io);
        return self.getClientIdByFdLocked(fd);
    }

    fn notifyLoops(self: *SseManager) void {
        if (self.notify_pipe[1] >= 0) {
            var byte_buf: [1]u8 = .{'x'};
            _ = socket.write(self.notify_pipe[1], &byte_buf, 1);
        }
    }

    /// Start LOOP_COUNT concurrent event loops using std.Io.Group
    pub fn startEventLoop(self: *SseManager, heartbeat_secs: u32) !void {
        self.running = true;
        var group: std.Io.Group = .init;
        defer group.cancel(self.io);

        for (0..LOOP_COUNT) |loop_id| {
            try group.concurrent(
                self.io,
                struct {
                    fn run(mgr: *SseManager, secs: u32, id: usize) void {
                        mgr.runEventLoop(secs, id);
                    }
                }.run,
                .{ self, heartbeat_secs, loop_id },
            );
        }

        try group.await(self.io);
    }

    pub fn gracefulShutdown(self: *SseManager) void {
        const close_msg = "event: close\ndata: Server shutting down\n\n";

        self.lock.lock(self.io) catch unreachable;
        defer self.lock.unlock(self.io);

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            _ = socket.write(entry.value_ptr.*.fd, close_msg.ptr, close_msg.len);
        }

        while (self.clients.count() > 0) {
            var it2 = self.clients.iterator();
            if (it2.next()) |entry| {
                const id = entry.key_ptr.*;
                const fd = entry.value_ptr.*.fd;
                entry.value_ptr.*.forceDestroy();
                _ = self.clients.remove(id);
                _ = self.fd_to_id.remove(fd);
            }
        }
        self.clients.clearRetainingCapacity();
        self.fd_to_id.clearRetainingCapacity();
    }

    pub fn stop(self: *SseManager) void {
        self.running = false;
        self.notifyLoops();
    }

    /// Each loop handles clients at indices where client_index % LOOP_COUNT == loop_id
    fn runEventLoop(self: *SseManager, heartbeat_secs: u32, loop_id: usize) void {
        const heartbeat_ms: i32 = @intCast(heartbeat_secs * 1000);
        var last_hb: i64 = @intCast(timestamp());

        while (self.running) {
            // --- snapshot fds under lock (fast, no poll while holding lock) ---
            self.lock.lock(self.io) catch unreachable;

            var my_fds = std.ArrayListUnmanaged(i32).empty;
            defer my_fds.deinit(self.allocator);

            var it = self.clients.iterator();
            while (it.next()) |entry| {
                // deterministic ownership by client id — stable across inserts/removes
                if (entry.value_ptr.*.id[0] % LOOP_COUNT == loop_id) {
                    my_fds.append(self.allocator, entry.value_ptr.*.fd) catch break;
                }
            }
            self.lock.unlock(self.io); // release before poll — critical

            const has_pipe = self.notify_pipe[0] >= 0 and loop_id == 0;
            const total_fds = if (has_pipe) my_fds.items.len + 1 else my_fds.items.len;

            if (total_fds == 0) {
                // no clients — wait for notification or heartbeat interval
                var ts: socket.timespec = .{
                    .sec = @intCast(heartbeat_secs),
                    .nsec = 0,
                };
                _ = socket.nanosleep(&ts, null);
                continue;
            }

            var poll_fds: []posix.pollfd = self.allocator.alloc(posix.pollfd, total_fds) catch {
                var ts: socket.timespec = .{
                    .sec = @intCast(heartbeat_secs),
                    .nsec = 0,
                };
                _ = socket.nanosleep(&ts, null);
                continue;
            };
            defer self.allocator.free(poll_fds);

            var idx: usize = 0;
            if (has_pipe) {
                poll_fds[0] = .{
                    .fd = self.notify_pipe[0],
                    .events = posix.POLL.IN,
                    .revents = undefined,
                };
                idx = 1;
            }
            for (my_fds.items) |fd| {
                poll_fds[idx] = .{
                    .fd = fd,
                    .events = posix.POLL.IN | posix.POLL.HUP,
                    .revents = undefined,
                };
                idx += 1;
            }

            // poll blocks here — lock is FREE, sendToClient/registerClient can proceed
            _ = posix.poll(poll_fds, heartbeat_ms) catch continue;

            for (poll_fds[0..total_fds]) |pfd| {
                const revents = @as(u16, @bitCast(pfd.revents));
                if (revents == 0) continue;

                const poll_err = @as(u16, @intCast(posix.POLL.ERR));
                const poll_hup = @as(u16, @intCast(posix.POLL.HUP));
                const poll_in = @as(u16, @intCast(posix.POLL.IN));

                if (revents & (poll_err | poll_hup) != 0) {
                    _ = self.removeClientByFd(pfd.fd);
                    continue;
                }

                if (revents & poll_in != 0) {
                    if (has_pipe and pfd.fd == self.notify_pipe[0]) {
                        var buf: [64]u8 = undefined;
                        _ = socket.read(self.notify_pipe[0], &buf, buf.len);
                    } else {
                        var buf: [64]u8 = undefined;
                        const n = socket.read(pfd.fd, &buf, buf.len);
                        if (n <= 0) {
                            _ = self.removeClientByFd(pfd.fd);
                        }
                    }
                }
            }

            // only send heartbeat when actually due
            const now: i64 = @intCast(timestamp());
            if (now - last_hb >= heartbeat_ms) {
                self.sendHeartbeat(loop_id);
                last_hb = now;
            }
        }
    }

    /// Only send heartbeat to clients owned by this loop
    fn sendHeartbeat(self: *SseManager, loop_id: usize) void {
        const ping = "data: ping\n\n";

        // self.lock.lock(self.io) catch unreachable;
        var client_ptrs: std.ArrayListUnmanaged(*SseClient) = .empty;
        defer client_ptrs.deinit(self.allocator);

        var it = self.clients.iterator();
        var global_idx: usize = 0;
        while (it.next()) |entry| : (global_idx += 1) {
            if (global_idx % LOOP_COUNT == loop_id) {
                client_ptrs.append(self.allocator, entry.value_ptr.*) catch break;
            }
        }
        // self.lock.unlock(self.io);

        var dead_ids: std.ArrayListUnmanaged([16]u8) = .empty;
        defer dead_ids.deinit(self.allocator);

        for (client_ptrs.items) |client| {
            client.last_heartbeat = timestamp();
            const n = socket.write(client.fd, ping.ptr, ping.len);
            if (n < 0) {
                dead_ids.append(self.allocator, client.id) catch break;
            }
        }

        for (dead_ids.items) |id| {
            self.removeClient(id);
        }
    }

    pub fn sendToClient(self: *SseManager, id: [16]u8, data: []const u8) !void {
        const client = self.clients.get(id);

        if (client == null) return error.ClientNotFound;

        const n = socket.write(client.?.fd, data.ptr, data.len);
        if (n < 0) {
            self.removeClient(id);
            return error.ClientDisconnected;
        }
    }

    pub fn broadcast(self: *SseManager, data: []const u8) !void {
        const event = try std.fmt.allocPrint(self.allocator, "data: {s}\n\n", .{data});
        defer self.allocator.free(event);

        self.lock.lock(self.io) catch unreachable;
        var client_ptrs: std.ArrayListUnmanaged(*SseClient) = .empty;
        defer client_ptrs.deinit(self.allocator);

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            client_ptrs.append(self.allocator, entry.value_ptr.*) catch break;
        }
        self.lock.unlock(self.io);

        for (client_ptrs.items) |client| {
            const n = socket.write(client.fd, event.ptr, event.len);
            if (n < 0) self.removeClient(client.id);
        }
    }

    pub fn broadcastTyped(self: *SseManager, event_type: []const u8, data: []const u8) !void {
        const event = try std.fmt.allocPrint(self.allocator, "event: {s}\ndata: {s}\n\n", .{ event_type, data });
        defer self.allocator.free(event);

        self.lock.lock(self.io) catch unreachable;
        var client_ptrs: std.ArrayListUnmanaged(*SseClient) = .empty;
        defer client_ptrs.deinit(self.allocator);

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            client_ptrs.append(self.allocator, entry.value_ptr.*) catch break;
        }
        self.lock.unlock(self.io);

        for (client_ptrs.items) |client| {
            const n = socket.write(client.fd, event.ptr, event.len);
            if (n < 0) self.removeClient(client.id);
        }
    }

    pub fn clientCount(self: *SseManager) usize {
        self.lock.lock(self.io) catch unreachable;
        defer self.lock.unlock(self.io);
        return self.clients.count();
    }
};

fn timestamp() u64 {
    var ts: socket.timespec = undefined;
    _ = socket.clock_gettime(socket.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1000000;
}
