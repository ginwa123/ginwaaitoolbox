const std = @import("std");
const linux = std.posix.system;
const c = std.c;

/// epoll constants (standard Linux values)
const EPOLLIN: u32 = 1;
const EPOLL_CTL_ADD: u32 = 1;
const EPOLL_CTL_DEL: u32 = 2;
const EPOLL_CTL_MOD: u32 = 3;
const EPOLLHUP: u32 = 0x10;
const EPOLLRDHUP: u32 = 0x2000;

pub const Self = @This();

/// Simple spinlock mutex for SSE client protection
pub const SpinMutex = struct {
    state: u8 = 0,

    pub fn init() SpinMutex {
        return .{ .state = 0 };
    }

    pub fn lock(self: *SpinMutex) void {
        while (@cmpxchgStrong(u8, &self.state, 0, 1, .acquire, .acquire) != null) {
            // spin
        }
    }

    pub fn unlock(self: *SpinMutex) void {
        @atomicStore(u8, &self.state, 0, .release);
    }
};

/// SSE Client state - each connected SSE client has one of these
pub const SseClient = struct {
    id: [16]u8,
    fd: i32,
    arena: std.heap.ArenaAllocator,
    alive: bool,
    last_heartbeat: u64,
    message_queue: std.ArrayListUnmanaged([]const u8),
    lock: SpinMutex,

    pub fn init(id: [16]u8, fd: i32, parent_allocator: std.mem.Allocator) SseClient {
        return .{
            .id = id,
            .fd = fd,
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .alive = true,
            .last_heartbeat = timestamp(),
            .message_queue = .empty,
            .lock = .{},
        };
    }

    pub fn allocator(self: *SseClient) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *SseClient) void {
        self.message_queue.deinit(self.allocator());
        self.arena.deinit();
        _ = linux.close(self.fd);
        self.* = undefined;
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
        const n = linux.write(self.fd, event.ptr, event.len);
        if (n < 0) {
            self.alive = false;
            return error.ClientDisconnected;
        }
    }
};

/// SSE Manager - owns all SSE clients and event loop
pub const SseManager = struct {
    clients: std.StringHashMapUnmanaged(*SseClient),
    timerfd: i32,
    epoll_fd: i32,
    lock: SpinMutex,
    allocator: std.mem.Allocator,
    server_allocator: std.mem.Allocator,
    running: bool,
    event_loop_thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, server_allocator: std.mem.Allocator) !SseManager {
        const epoll_fd_int = c.epoll_create1(0);
        if (epoll_fd_int < 0) return error.EpollCreateFailed;
        const epoll_fd: i32 = @intCast(epoll_fd_int);
        errdefer _ = linux.close(epoll_fd);

        const timerfd_int = c.timerfd_create(std.os.linux.timerfd_clockid_t.MONOTONIC, 0);
        if (timerfd_int < 0) {
            _ = linux.close(epoll_fd);
            return error.TimerCreateFailed;
        }
        const timerfd: i32 = @intCast(timerfd_int);
        errdefer _ = linux.close(timerfd);

        var ev: linux.epoll_event = .{
            .events = EPOLLIN,
            .data = .{ .u64 = 0 },
        };
        _ = c.epoll_ctl(epoll_fd, EPOLL_CTL_ADD, timerfd, &ev);

        return .{
            .clients = .empty,
            .timerfd = timerfd,
            .epoll_fd = epoll_fd,
            .lock = .{},
            .allocator = allocator,
            .server_allocator = server_allocator,
            .running = true,
        };
    }

    pub fn deinit(self: *SseManager) void {
        self.running = false;
        self.lock.lock();
        defer self.lock.unlock();

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.server_allocator.destroy(entry.value_ptr);
        }
        self.clients.clearRetainingCapacity();

        _ = linux.close(self.timerfd);
        _ = linux.close(self.epoll_fd);
    }

    pub fn registerClient(self: *SseManager, fd: i32) ![16]u8 {
        var id: [16]u8 = undefined;
        const n = std.c.getrandom(&id, id.len, 0);
        if (n != id.len) return error.GetRandomFailed;

        const client = try self.server_allocator.create(SseClient);
        client.* = SseClient.init(id, fd, self.allocator);

        var ev: linux.epoll_event = .{
            .events = EPOLLIN | EPOLLHUP | EPOLLRDHUP,
            .data = .{ .u64 = @intFromPtr(client) },
        };
        if (c.epoll_ctl(self.epoll_fd, EPOLL_CTL_ADD, fd, &ev) < 0) return error.EpollCtlFailed;

        self.lock.lock();
        defer self.lock.unlock();
        try self.clients.put(self.server_allocator, &id, client);

        return id;
    }

    pub fn removeClient(self: *SseManager, id: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.clients.fetchRemove(id)) |entry| {
            entry.value.*.deinit();
            self.server_allocator.destroy(entry.value);
        }
    }

    pub fn removeClientByFd(self: *SseManager, fd: i32) ?[16]u8 {
        self.lock.lock();
        defer self.lock.unlock();

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            if (entry.value.*.fd == fd) {
                const id = entry.value.*.id;
                entry.value.*.deinit();
                self.server_allocator.destroy(entry.value);
                _ = self.clients.remove(id);
                return id;
            }
        }
        return null;
    }

    /// Run event loop - blocks until shutdown (static wrapper)
fn runEventLoopThread(sse_mgr: *SseManager, heartbeat_secs: u32) void {
        sse_mgr.runEventLoop(heartbeat_secs);
    }

    /// Run event loop - blocks until shutdown
    fn runEventLoop(self: *SseManager, heartbeat_secs: u32) void {
        var ts: linux.itimerspec = .{
            .it_interval = .{ .sec = @intCast(heartbeat_secs), .nsec = 0 },
            .it_value = .{ .sec = @intCast(heartbeat_secs), .nsec = 0 },
        };
        _ = c.timerfd_settime(self.timerfd, 0, &ts, null);

        var events: [64]linux.epoll_event = undefined;

        while (self.running) {
            const n = c.epoll_wait(self.epoll_fd, &events, 64, 1000);
            if (n < 0) continue;

            for (events[0..@as(usize, @intCast(n))]) |ev| {
                if (ev.data.u64 == 0) {
                    self.sendHeartbeat();
                } else {
                    const client: *SseClient = @ptrFromInt(ev.data.u64);
                    self.handleClientEvent(client, ev.events);
                }
            }
        }
    }

    pub fn startEventLoop(self: *SseManager, heartbeat_secs: u32) !void {
        self.running = true;
        self.event_loop_thread = try std.Thread.spawn(.{}, runEventLoopThread, .{ self, heartbeat_secs });
    }

    pub fn stop(self: *SseManager) void {
        self.running = false;
        if (self.event_loop_thread) |t| {
            t.join();
            self.event_loop_thread = null;
        }
    }

    fn handleClientEvent(self: *SseManager, client: *SseClient, events: u32) void {
        if (events & (EPOLLHUP | EPOLLRDHUP) != 0) {
            self.removeClient(&client.id);
            return;
        }

        if (events & EPOLLIN != 0) {
            var buf: [64]u8 = undefined;
            const n = linux.read(client.*.fd, &buf, buf.len);
            if (n <= 0) {
                self.removeClient(&client.id);
                return;
            }
        }
    }

    fn sendHeartbeat(self: *SseManager) void {
        const ping = "data: ping\n\n";

        // Consume the timerfd event by reading from it
        var buf: [8]u8 = undefined;
        _ = linux.read(self.timerfd, @ptrCast(&buf), buf.len);

        self.lock.lock();
        defer self.lock.unlock();

        var it = self.clients.valueIterator();
        while (it.next()) |client| {
            client.*.last_heartbeat = timestamp();
            _ = linux.write(client.*.fd, ping.ptr, ping.len);
        }
    }

    /// Broadcast event to all connected clients
    pub fn broadcast(self: *SseManager, data: []const u8) !void {
        const event = try std.fmt.allocPrint(self.allocator, "data: {s}\n\n", .{data});
        defer self.allocator.free(event);

        self.lock.lock();
        defer self.lock.unlock();

        var it = self.clients.valueIterator();
        while (it.next()) |client| {
            _ = linux.write(client.*.fd, event.ptr, event.len);
        }
    }

    /// Broadcast event with type
    pub fn broadcastTyped(self: *SseManager, event_type: []const u8, data: []const u8) !void {
        const event = try std.fmt.allocPrint(self.allocator, "event: {s}\ndata: {s}\n\n", .{ event_type, data });
        defer self.allocator.free(event);

        self.lock.lock();
        defer self.lock.unlock();

        var it = self.clients.valueIterator();
        while (it.next()) |client| {
            _ = linux.write(client.*.fd, event.ptr, event.len);
        }
    }

    /// Send event to specific client by ID
    pub fn sendToClient(self: *SseManager, id: []const u8, data: []const u8) !void {
        const event = try std.fmt.allocPrint(self.allocator, "data: {s}\n\n", .{data});
        defer self.allocator.free(event);

        self.lock.lock();
        defer self.lock.unlock();

        const client = self.clients.get(id) orelse return error.ClientNotFound;
        try client.*.sendEvent(event);
    }

    /// Graceful shutdown - notify all clients, then close
    pub fn gracefulShutdown(self: *SseManager) void {
        const close_msg = "event: close\ndata: Server shutting down\n\n";

        self.lock.lock();
        defer self.lock.unlock();

        var it = self.clients.valueIterator();
        while (it.next()) |client| {
            _ = linux.write(client.*.fd, close_msg.ptr, close_msg.len);
            client.*.deinit();
        }

        var it2 = self.clients.iterator();
        while (it2.next()) |entry| {
            self.server_allocator.destroy(entry.value_ptr);
        }
        self.clients.clearRetainingCapacity();
    }

    pub fn clientCount(self: *SseManager) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.clients.count();
    }
};

fn timestamp() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(std.os.linux.clockid_t.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec));
}