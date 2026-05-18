const std = @import("std");
const posix = std.posix;
const socket = posix.system;
const c = std.c;

/// Platform-specific includes
const builtin = @import("builtin");

// =============================================================================
// Platform Detection
// =============================================================================

const is_windows = builtin.os.tag == .windows;
const is_linux = builtin.os.tag == .linux;
const is_macos = builtin.os.tag == .macos;
const is_bsd = switch (builtin.os.tag) {
    .freebsd, .openbsd, .netbsd, .dragonfly => true,
    else => false,
};

/// Cross-platform SSE Manager implementation
/// Uses different backends based on OS:
/// - Linux: kqueue
/// - macOS/BSD: kqueue  
/// - Windows: select/poll based approach

pub const Self = @This();

/// SSE Client state - each connected SSE client has one of these
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

    /// Force destroy without going through arena.deinit().
    /// This is used when the SseManager is shutting down and we need to
    /// free the SseClient memory WITHOUT calling arena.deinit() which
    /// corrupts the backing allocator's bookkeeping (especially DebugAllocator).
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

/// SSE Manager - owns all SSE clients and event loop
pub const SseManager = struct {
    const Self = @This();
    io: std.Io,

    clients: std.AutoHashMapUnmanaged([16]u8, *SseClient),
    // fd_to_id maps socket fd to client id for quick lookup
    fd_to_id: std.AutoHashMapUnmanaged(i32, [16]u8),
    lock: std.Io.Mutex = .init,
    allocator: std.mem.Allocator,
    server_allocator: std.mem.Allocator,
    running: bool,
    event_loop_thread: ?std.Thread = null,

    /// Optional callback called when a client disconnects
    /// Takes the client_id as argument
    on_disconnect: ?*const fn (client_id: [16]u8) void = null,

    /// Notification pipe for waking up the event loop
    notify_pipe: [2]i32,

    pub fn init(allocator: std.mem.Allocator, server_allocator: std.mem.Allocator, io: std.Io) !SseManager {
        var notify_pipe: [2]i32 = .{ -1, -1 };
        
        // Create notification pipe for waking up the event loop
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
        
        // Wake up the event loop by writing to the pipe
        if (self.notify_pipe[1] >= 0) {
            const byte: u8 = 'q';
            var byte_buf: [1]u8 = .{byte};
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

        // Check if already registered
        if (self.getClientIdByFdLocked(fd)) |id| {
            return id;
        }

        // Generate unique ID (with collision detection)
        var id: [16]u8 = undefined;
        while (true) {
            // Use the io's random source to fill bytes
            self.io.random(&id);
            // Check if this ID already exists
            if (!self.clients.contains(id)) break;
            // ID collision, regenerate
        }

        const client = try self.server_allocator.create(SseClient);
        client.* = SseClient.init(id, fd, self.allocator, self.io);

        try self.clients.put(self.server_allocator, id, client);
        try self.fd_to_id.put(self.server_allocator, fd, id);
        
        return id;
    }

    pub fn removeClient(self: *SseManager, id: [16]u8) void {
        self.lock.lock(self.io) catch unreachable;
        defer self.lock.unlock(self.io);

        if (self.clients.fetchRemove(id)) |entry| {
            _ = self.fd_to_id.remove(entry.value.*.fd);
            entry.value.*.deinit();
            self.server_allocator.destroy(entry.value);
            // Call disconnect callback if set
            if (self.on_disconnect) |cb| {
                cb(id);
            }
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
            // Call disconnect callback if set
            if (self.on_disconnect) |cb| {
                cb(id);
            }
            return id;
        }
        return null;
    }

    /// Get client ID by fd (assumes lock is held by caller)
    fn getClientIdByFdLocked(self: *SseManager, fd: i32) ?[16]u8 {
        return self.fd_to_id.get(fd);
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

    /// Cross-platform event loop using kqueue on macOS/BSD and poll on Linux/Windows
    fn runEventLoop(self: *SseManager, heartbeat_secs: u32) void {
        const heartbeat_ms: i32 = @intCast(heartbeat_secs * 1000);
        
        while (self.running) {
            // Collect file descriptors to poll
            self.lock.lock(self.io) catch unreachable;
            const client_count = self.clients.count();
            
            // Allocate poll fds: clients + notification pipe
            const total_fds = if (self.notify_pipe[0] >= 0) client_count + 1 else client_count;
            if (total_fds == 0) {
                self.lock.unlock(self.io);
                // No clients, just sleep using nanosleep
                var ts: socket.timespec = .{
                    .sec = @intCast(heartbeat_secs),
                    .nsec = 0,
                };
                _ = socket.nanosleep(&ts, null);
                continue;
            }
            
            // Build poll array
            var poll_fds: []posix.pollfd = self.allocator.alloc(posix.pollfd, total_fds) catch {
                self.lock.unlock(self.io);
                var ts: socket.timespec = .{
                    .sec = @intCast(heartbeat_secs),
                    .nsec = 0,
                };
                _ = socket.nanosleep(&ts, null);
                continue;
            };
            defer self.allocator.free(poll_fds);
            
            var idx: usize = 0;
            if (self.notify_pipe[0] >= 0) {
                poll_fds[0] = .{
                    .fd = self.notify_pipe[0],
                    .events = posix.POLL.IN,
                    .revents = undefined,
                };
                idx = 1;
            }
            
            var it = self.clients.iterator();
            while (it.next()) |entry| {
                poll_fds[idx] = .{
                    .fd = entry.value_ptr.*.fd,
                    .events = posix.POLL.IN | posix.POLL.HUP,
                    .revents = undefined,
                };
                idx += 1;
            }
            self.lock.unlock(self.io);
            
            // Poll with timeout for heartbeat
            const num_events = posix.poll(poll_fds, heartbeat_ms) catch continue;
            
            // Process events
            for (poll_fds[0..@as(usize, @intCast(num_events))]) |pfd| {
                const revents = @as(u16, @bitCast(pfd.revents));
                const poll_err = @as(u16, @intCast(posix.POLL.ERR));
                const poll_hup = @as(u16, @intCast(posix.POLL.HUP));
                const poll_in = @as(u16, @intCast(posix.POLL.IN));
                
                if (revents & (poll_err | poll_hup) != 0) {
                    // Client disconnected
                    _ = self.removeClientByFd(pfd.fd);
                    continue;
                }
                if (revents & poll_in != 0) {
                    if (pfd.fd == self.notify_pipe[0]) {
                        // Notification received, drain the pipe
                        var buf: [64]u8 = undefined;
                        _ = socket.read(self.notify_pipe[0], &buf, buf.len);
                    } else {
                        // Client sent data, check if disconnected
                        var buf: [64]u8 = undefined;
                        const n = socket.read(pfd.fd, &buf, buf.len);
                        if (n <= 0) {
                            _ = self.removeClientByFd(pfd.fd);
                        }
                    }
                }
            }
            
            // Send heartbeat to all clients
            self.sendHeartbeat();
        }
    }

    pub fn startEventLoop(self: *SseManager, heartbeat_secs: u32) !void {
        self.running = true;
        self.event_loop_thread = try std.Thread.spawn(.{}, runEventLoopThread, .{ self, heartbeat_secs });
    }

    pub fn stop(self: *SseManager) void {
        self.running = false;
        // Wake up the event loop
        if (self.notify_pipe[1] >= 0) {
            const byte: u8 = 'q';
            var byte_buf: [1]u8 = .{byte};
            _ = socket.write(self.notify_pipe[1], &byte_buf, 1);
        }
        if (self.event_loop_thread) |t| {
            t.join();
            self.event_loop_thread = null;
        }
    }

    fn sendHeartbeat(self: *SseManager) void {
        const ping = "data: ping\n\n";

        // Collect client pointers under lock
        self.lock.lock(self.io) catch unreachable;
        var client_ptrs: std.ArrayListUnmanaged(*SseClient) = .empty;
        defer client_ptrs.deinit(self.allocator);

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            client_ptrs.append(self.allocator, entry.value_ptr.*) catch break;
        }
        self.lock.unlock(self.io);

        // Perform I/O without holding the lock - track dead clients
        var dead_ids: std.ArrayListUnmanaged([16]u8) = .empty;
        defer dead_ids.deinit(self.allocator);

        for (client_ptrs.items) |client| {
            client.*.last_heartbeat = timestamp();
            const n = socket.write(client.*.fd, ping.ptr, ping.len);
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
            const n = socket.write(client.*.fd, event.ptr, event.len);
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
            const n = socket.write(client.*.fd, event.ptr, event.len);
            if (n < 0) {
                self.removeClient(&client.*.id);
            }
        }
    }

    /// Send event to specific client by ID
    pub fn sendToClient(self: *SseManager, id: [16]u8, data: []const u8) !void {
        _ = try self.lock.lock(self.io);
        const client = self.clients.get(id);
        self.lock.unlock(self.io);

        if (client == null) {
            return error.ClientNotFound;
        }

        const n = socket.write(client.?.*.fd, data.ptr, data.len);
        if (n < 0) {
            self.removeClient(id);
            return error.ClientDisconnected;
        }
    }

    /// Graceful shutdown - notify all clients, then close
    pub fn gracefulShutdown(self: *SseManager) void {
        const close_msg = "event: close\ndata: Server shutting down\n\n";

        _ = self.lock.lock(self.io) catch unreachable;
        defer self.lock.unlock(self.io);

        // First pass: send close messages to all clients
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            _ = socket.write(entry.value_ptr.*.fd, close_msg.ptr, close_msg.len);
        }

        // Second pass: remove all clients from hash map
        while (self.clients.count() > 0) {
            var it2 = self.clients.iterator();
            if (it2.next()) |entry| {
                const id = entry.key_ptr.*;
                const fd = entry.value_ptr.*.fd;
                // Use forceDestroy - closes fd, skips arena.deinit()
                entry.value_ptr.*.forceDestroy();
                // Remove from hash map - memory stays allocated until arena is destroyed
                _ = self.clients.remove(id);
                _ = self.fd_to_id.remove(fd);
            }
        }
        self.clients.clearRetainingCapacity();
        self.fd_to_id.clearRetainingCapacity();
    }

    pub fn clientCount(self: *SseManager) usize {
        self.lock.lock(self.io);
        defer self.lock.unlock(self.io);
        return self.clients.count();
    }
};

fn timestamp() u64 {
    // Get current time in milliseconds
    var ts: socket.timespec = undefined;
    _ = socket.clock_gettime(socket.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1000000;
}
