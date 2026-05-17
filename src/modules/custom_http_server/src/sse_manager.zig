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
    }

    /// Force destroy without going through arena.deinit().
    /// This is used when the SseManager is shutting down and we need to
    /// free the SseClient memory WITHOUT calling arena.deinit() which
    /// corrupts the backing allocator's bookkeeping (especially DebugAllocator).
    /// The arena's child allocator (used for SseClient allocations) will be
    /// cleaned up separately when the server allocator is destroyed.
    pub fn forceDestroy(self: *SseClient) void {
        _ = linux.close(self.fd);
        // Don't call deinit() - we skip the arena.deinit() to avoid corrupting
        // the backing allocator's canary tracking.
        // The memory for this SseClient will be reclaimed when the arena
        // that allocated it is destroyed.
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
    const Self = @This();

    clients: std.AutoHashMapUnmanaged([16]u8, *SseClient),
    timerfd: i32,
    epoll_fd: i32,
    lock: SpinMutex,
    allocator: std.mem.Allocator,
    server_allocator: std.mem.Allocator,
    running: bool,
    event_loop_thread: ?std.Thread = null,

    /// Optional callback called when a client disconnects
    /// Takes the client_id as argument
    on_disconnect: ?*const fn (client_id: [16]u8) void = null,

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
            // Unregister fd from epoll before closing
            _ = c.epoll_ctl(self.epoll_fd, EPOLL_CTL_DEL, entry.value_ptr.*.fd, null);
            // Use forceDestroy to skip arena.deinit() which corrupts backing allocator
            // The arena memory will be reclaimed when the server_allocator arena is destroyed
            entry.value_ptr.*.forceDestroy();
            // Don't call destroy() here - the arena that allocated the SseClient
            // will be destroyed when server_allocator is destroyed
        }
        self.clients.clearRetainingCapacity();

        _ = linux.close(self.timerfd);
        _ = linux.close(self.epoll_fd);
    }

    pub fn registerClient(self: *SseManager, fd: i32) ![16]u8 {
        self.lock.lock();
        defer self.lock.unlock();

        // Check if already registered
        if (self.getClientIdByFdLocked(fd)) |id| {
            return id;
        }

        // Generate unique ID (with collision detection)
        var id: [16]u8 = undefined;
        while (true) {
            const n = std.c.getrandom(&id, id.len, 0);
            if (n != id.len) return error.GetRandomFailed;
            // Check if this ID already exists
            if (!self.clients.contains(id)) break;
            // ID collision, regenerate
        }

        const client = try self.server_allocator.create(SseClient);
        client.* = SseClient.init(id, fd, self.allocator);

        var ev: linux.epoll_event = .{
            .events = EPOLLIN | EPOLLHUP | EPOLLRDHUP,
           .data = .{ .u64 = @intFromPtr(client) },
        };
        if (c.epoll_ctl(self.epoll_fd, EPOLL_CTL_ADD, fd, &ev) < 0) {
            self.server_allocator.destroy(client);
            return error.EpollCtlFailed;
        }

        try self.clients.put(self.server_allocator, id, client);
        return id;
    }

    pub fn removeClient(self: *SseManager, id: [16]u8) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.clients.fetchRemove(id)) |entry| {
            // Unregister fd from epoll before closing and deallocating
            _ = c.epoll_ctl(self.epoll_fd, EPOLL_CTL_DEL, entry.value.*.fd, null);
            entry.value.*.deinit();
            self.server_allocator.destroy(entry.value);
            // Call disconnect callback if set
            if (self.on_disconnect) |cb| {
                cb(id);
            }
        }
    }

    pub fn removeClientByFd(self: *SseManager, fd: i32) ?[16]u8 {
        self.lock.lock();
        defer self.lock.unlock();

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.fd == fd) {
                // Copy the key to a local array before any modifications
                const id = entry.key_ptr.*;
                // Unregister fd from epoll before closing and deallocating
                _ = c.epoll_ctl(self.epoll_fd, EPOLL_CTL_DEL, fd, null);
                // Copy the pointer before removing from hash map
                const client_ptr = entry.value_ptr.*;
                // Remove from hash map FIRST to invalidate the entry
                _ = self.clients.remove(id);
                // Now safe to deinit and destroy - client_ptr is no longer in hash map
                client_ptr.deinit();
                self.server_allocator.destroy(client_ptr);
                // Call disconnect callback if set
                if (self.on_disconnect) |cb| {
                    cb(id);
                }
                return id;
            }
        }
        return null;
    }

    /// Get client ID by fd (assumes lock is held by caller)
    fn getClientIdByFdLocked(self: *SseManager, fd: i32) ?[16]u8 {
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.fd == fd) {
                return entry.key_ptr.*;
            }
        }
        return null;
    }

    /// Get client ID by fd (does not remove or deinit) - acquires lock
    pub fn getClientIdByFd(self: *SseManager, fd: i32) ?[16]u8 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.getClientIdByFdLocked(fd);
    }

    /// Run event loop - blocks until shutdown (static wrapper)
    fn runEventLoopThread(sse_mgr: *SseManager, heartbeat_secs: u32) void {
        sse_mgr.runEventLoop(heartbeat_secs);
    }

    /// Run event loop - blocks until shutdown
    fn runEventLoop(self: *SseManager, heartbeat_secs: u32) void {
        // arm the timer for periodic heartbeat
        var ts: linux.itimerspec = .{
            .it_interval = .{ .sec = @intCast(heartbeat_secs), .nsec = 0 },
            .it_value = .{ .sec = @intCast(heartbeat_secs), .nsec = 0 },
        };
        _ = c.timerfd_settime(self.timerfd, 0, &ts, null);

        var events: [64]linux.epoll_event = undefined;

        while (self.running) {
            const n = c.epoll_wait(self.epoll_fd, &events, 64, 5000);
            if (n < 0) continue;

            for (events[0..@as(usize, @intCast(n))]) |ev| {
                if (ev.data.u64 == 0) {
                    // timerfd - consume the event and send heartbeat
                    var dummy: [8]u8 = undefined;
                    const r = linux.read(self.timerfd, @ptrCast(&dummy), dummy.len);
                    _ = r; // suppress unused warning
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
        // Take a local copy of the fd before any operations
        const fd = client.fd;

        // If we got events but client is not in our map, we need to clean up the fd from epoll
        // This happens when client was already removed but epoll still has events pending
        self.lock.lock();
        const valid = self.clients.contains(client.id);
        self.lock.unlock();

        if (!valid) {
            if (events & (EPOLLHUP | EPOLLRDHUP) != 0) {
                // Clean up the orphaned fd from epoll and close it
                _ = c.epoll_ctl(self.epoll_fd, EPOLL_CTL_DEL, fd, null);
                _ = linux.close(fd);
            }
            return;
        }

        if (events & (EPOLLHUP | EPOLLRDHUP) != 0) {
            // Let removeClientByFd handle the epoll cleanup and closing
            _ = self.removeClientByFd(fd);
            return;
        }

        if (events & EPOLLIN != 0) {
            var buf: [64]u8 = undefined;
            const n = linux.read(client.*.fd, &buf, buf.len);
            if (n <= 0) {
                _ = self.removeClientByFd(fd);
                return;
            }
        }
    }

    fn sendHeartbeat(self: *SseManager) void {
        const ping = "data: ping\n\n";

        // Note: timerfd event already consumed in event loop before calling sendHeartbeat

        // Collect client pointers under lock
        self.lock.lock();
        var client_ptrs: std.ArrayListUnmanaged(*SseClient) = .empty;
        defer client_ptrs.deinit(self.allocator);

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            client_ptrs.append(self.allocator, entry.value_ptr.*) catch break;
        }
        self.lock.unlock();

        // Perform I/O without holding the lock - track dead clients
        var dead_ids: std.ArrayListUnmanaged([16]u8) = .empty;
        defer dead_ids.deinit(self.allocator);

        for (client_ptrs.items) |client| {
            client.*.last_heartbeat = timestamp();
            const n = linux.write(client.*.fd, ping.ptr, ping.len);
            if (n < 0) {
                // Mark client as dead - don't remove during iteration
                dead_ids.append(self.allocator, client.*.id) catch break;
            }
        }

        // Remove dead clients AFTER iteration
        for (dead_ids.items) |id| {
            self.removeClient(id);
        }
    }

    /// Broadcast event to all connected clients
    pub fn broadcast(self: *SseManager, data: []const u8) !void {
        const event = try std.fmt.allocPrint(self.allocator, "data: {s}\n\n", .{data});
        defer self.allocator.free(event);

        // Collect client pointers under lock
        self.lock.lock();
        var client_ptrs: std.ArrayListUnmanaged(*SseClient) = .empty;
        defer client_ptrs.deinit(self.allocator);

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            client_ptrs.append(self.allocator, entry.value_ptr.*) catch break;
        }
        self.lock.unlock();

        for (client_ptrs.items) |client| {
            const n = linux.write(client.*.fd, event.ptr, event.len);
            if (n < 0) {
                self.removeClient(&client.*.id);
            }
        }
    }

    /// Broadcast event with type
    pub fn broadcastTyped(self: *SseManager, event_type: []const u8, data: []const u8) !void {
        const event = try std.fmt.allocPrint(self.allocator, "event: {s}\ndata: {s}\n\n", .{ event_type, data });
        defer self.allocator.free(event);

        // Collect client pointers under lock
        self.lock.lock();
        var client_ptrs: std.ArrayListUnmanaged(*SseClient) = .empty;
        defer client_ptrs.deinit(self.allocator);

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            client_ptrs.append(self.allocator, entry.value_ptr.*) catch break;
        }
        self.lock.unlock();

        for (client_ptrs.items) |client| {
            const n = linux.write(client.*.fd, event.ptr, event.len);
            if (n < 0) {
                self.removeClient(&client.*.id);
            }
        }
    }

    /// Send event to specific client by ID
    /// NOTE: Caller is responsible for freeing the data slice
    pub fn sendToClient(self: *SseManager, id: [16]u8, data: []const u8) !void {
        std.debug.print("SSE_DEBUG: sendToClient: sending event to client {s}\n", .{id});

        self.lock.lock();
        const client = self.clients.get(id);
        self.lock.unlock();

        if (client == null) {
            std.debug.print("SSE_DEBUG: sendToClient: client not found\n", .{});
            return error.ClientNotFound;
        }

        std.debug.print("SSE_DEBUG: sendToClient: fd={}\n", .{client.?.*.fd});
        std.debug.print("SSE_DEBUG: sendToClient: data={any}\n", .{data});
        std.debug.print("SSE_DEBUG: sendToClient: event={any}\n", .{data});
        const n = linux.write(client.?.*.fd, data.ptr, data.len);
        if (n < 0) {
            self.removeClient(id);
            std.debug.print("SSE_DEBUG: sendToClient: client disconnected, removing client\n", .{});
            return error.ClientDisconnected;
        }
    }

    /// Graceful shutdown - notify all clients, then close
    pub fn gracefulShutdown(self: *SseManager) void {
        const close_msg = "event: close\ndata: Server shutting down\n\n";

        self.lock.lock();
        defer self.lock.unlock();

        // First pass: send close messages to all clients
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            _ = linux.write(entry.value_ptr.*.fd, close_msg.ptr, close_msg.len);
        }

        // Second pass: remove all clients from hash map
        // Use forceDestroy instead of deinit to skip arena.deinit() which
        // corrupts the backing allocator's canary tracking.
        // We also don't call destroy() - the arena will reclaim memory when
        // SseManager is destroyed.
        while (self.clients.count() > 0) {
            var it2 = self.clients.iterator();
            if (it2.next()) |entry| {
                const id = entry.key_ptr.*;
                // Unregister fd from epoll before closing
                _ = c.epoll_ctl(self.epoll_fd, EPOLL_CTL_DEL, entry.value_ptr.*.fd, null);
                // Use forceDestroy - closes fd, skips arena.deinit()
                entry.value_ptr.*.forceDestroy();
                // Remove from hash map - memory stays allocated until arena is destroyed
                _ = self.clients.remove(id);
            }
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
