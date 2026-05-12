const std = @import("std");
const httpz = @import("httpz");

pub const SseEvent = struct {
    data: []const u8,
    event_type: ?[]const u8 = null,

    /// Format SSE event using dynamic heap allocation (no size limit)
    /// Proper SSE format: "event: <type>\ndata: <line1>\ndata: <line2>\n\n"
    pub fn format(self: SseEvent, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        // Write event type line if specified
        if (self.event_type) |event_type| {
            try result.appendSlice(allocator, "event: ");
            try result.appendSlice(allocator, event_type);
            try result.appendSlice(allocator, "\n");
        }

        // If data is empty, write a placeholder
        if (self.data.len == 0) {
            try result.appendSlice(allocator, "data: \n");
        } else {
            // Write data lines: "data: <content>\n"
            var iter = std.mem.splitScalar(u8, self.data, '\n');
            while (iter.next()) |line| {
                if (line.len == 0) continue;
                try result.appendSlice(allocator, "data: ");
                try result.appendSlice(allocator, line);
                try result.appendSlice(allocator, "\n");
            }
        }

        // Final newline to end the event
        try result.appendSlice(allocator, "\n");

        return result.toOwnedSlice(allocator);
    }
};

/// Thread-safe event queue item for SSE
pub const SseQueueItem = struct {
    data: []const u8,
    event_type: ?[]const u8 = null,
    next: ?*SseQueueItem = null,
};

/// Session metadata for tracking activity and cleanup
pub const SessionMeta = struct {
    last_activity_ns: i64,
};

/// Thread-safe queue-based SSE connection manager
/// Supports MULTIPLE clients per session_id - each session can have many concurrent connections
/// Uses a channel approach: each SSE handler thread owns its stream and reads from its own queue
/// while other threads enqueue events to ALL client queues for a session.
/// Implements idle session timeout to clean up zombie connections when clients crash.
pub const SseConnectionManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// Map from session_id to session entry (client list + metadata)
    sessions: std.StringHashMap(SessionEntry),
    /// Mutex to protect the sessions map
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Condition for client count changes (for cleanup tracking)
    cond: std.Io.Condition = std.Io.Condition.init,
    /// Idle session timeout in nanoseconds (default: 5 minutes)
    idle_timeout_ns: u64,
    /// Timer state for cleanup
    cleanup_running: bool = false,

    io: std.Io,

    pub const Queue = struct {
        head: ?*SseQueueItem = null,
        tail: ?*SseQueueItem = null,
        cond: std.Io.Condition = std.Io.Condition.init,
        mutex: std.Io.Mutex = std.Io.Mutex.init,
        closed: bool = false,
        io: std.Io,

        /// Add an item to the queue (thread-safe)
        pub fn enqueue(self: *Queue, item: *SseQueueItem) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            item.next = null;
            if (self.tail) |tail| {
                tail.next = item;
            } else {
                self.head = item;
            }
            self.tail = item;
            self.cond.signal(self.io);
        }

        /// Get an item from the queue with timeout (thread-safe)
        /// Returns null if timeout expires or queue is closed
        pub fn dequeueWithTimeout(self: *Queue, timeout_ns: u64) ?*SseQueueItem {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            // Wait for an item or timeout
            const ts = std.Io.Clock.now(.real, self.io);
            const now_ns = ts.toNanoseconds();
            const deadline = now_ns + @as(i64, @intCast(timeout_ns));
            while (self.head == null and !self.closed) {
                const ts2 = std.Io.Clock.now(.real, self.io);
                const now_ns2 = ts2.toNanoseconds();
                const remaining = @as(u64, @intCast(deadline - now_ns2));
                if (remaining == 0) break;
                self.cond.wait(self.io, &self.mutex) catch {};
            }

            if (self.head) |item| {
                self.head = item.next;
                if (self.head == null) self.tail = null;
                return item;
            }
            return null;
        }

        /// Close the queue (signals no more items)
        pub fn close(self: *Queue) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.closed = true;
            self.cond.broadcast(self.io);
        }
    };

    /// Client info - holds a queue for a specific client connection
    pub const ClientInfo = struct {
        queue: *Queue,
        connected_at: i64,
    };

    /// Session entry containing client list and metadata
    pub const SessionEntry = struct {
        clients: std.ArrayList(ClientInfo),
        last_activity_ns: i64,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .sessions = std.StringHashMap(SessionEntry).init(allocator),
            .mutex = std.Io.Mutex.init,
            .cond = std.Io.Condition.init,
            .idle_timeout_ns = 5 * 60 * 1_000_000_000, // 5 minutes default
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // Close and destroy all client queues
            for (entry.value_ptr.*.clients.items) |client_info| {
                client_info.queue.close();
                self.allocator.destroy(client_info.queue);
            }
            entry.value_ptr.*.clients.deinit(self.allocator);
        }
        self.sessions.deinit();
    }

    /// Update last activity time for a session
    fn touchSession(self: *Self, session_id: []const u8) void {
        if (self.sessions.getEntry(session_id)) |entry| {
            const ts = std.Io.Clock.now(.real, self.io);
            entry.value_ptr.*.last_activity_ns = @intCast(ts.toNanoseconds());
        }
    }

    /// Register a new client SSE connection with its event queue
    /// Multiple clients can register for the same session_id - each gets their own queue
    pub fn registerClient(self: *Self, session_id: []const u8, queue: *Queue) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Clean up any idle sessions before registering new client
        self.cleanupIdleSessionsInternal();

        const key = try self.allocator.dupe(u8, session_id);
        const ts = std.Io.Clock.now(.real, self.io);
        const now_ns: i64 = @intCast(ts.toNanoseconds());

        // Use getOrPut to atomically check-and-insert, avoiding race with enqueueEvent
        const gop = try self.sessions.getOrPut(key);
        if (gop.found_existing) {
            // Session exists, append new client
            try gop.value_ptr.clients.append(self.allocator, ClientInfo{
                .queue = queue,
                .connected_at = ts.toSeconds(),
            });
            gop.value_ptr.last_activity_ns = now_ns;
            std.log.info("SSE: Client connected to existing session: {s}, total clients: {d}", .{
                session_id, gop.value_ptr.clients.items.len,
            });
        } else {
            // New session, create session entry
            var client_list = std.ArrayList(ClientInfo).empty;
            errdefer client_list.deinit(self.allocator);
            const new_queue = try self.createQueue();
            try client_list.append(self.allocator, ClientInfo{
                .queue = new_queue,
                .connected_at = ts.toSeconds(),
            });
            gop.value_ptr.* = SessionEntry{
                .clients = client_list,
                .last_activity_ns = now_ns,
            };
            std.log.info("SSE: First client connected to new session: {s}", .{session_id});
        }
    }

    /// Remove a specific client connection
    /// Returns true if this was the last client for the session
    pub fn removeClient(self: *Self, session_id: []const u8, queue: *Queue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.sessions.getEntry(session_id)) |entry| {
            const session_entry = &entry.value_ptr.*;

            // Find and remove the specific client
            var found_idx: ?usize = null;
            for (session_entry.clients.items, 0..) |client_info, idx| {
                if (client_info.queue == queue) {
                    found_idx = idx;
                    break;
                }
            }

            if (found_idx) |idx| {
                const client_info = session_entry.clients.orderedRemove(idx);
                client_info.queue.close();
                self.allocator.destroy(client_info.queue);

                const remaining = session_entry.clients.items.len;
                if (remaining == 0) {
                    // Last client disconnected - clean up the session
                    self.allocator.free(entry.key_ptr.*);
                    session_entry.clients.deinit(self.allocator);
                    _ = self.sessions.remove(entry.key_ptr.*);
                    std.log.info("SSE: Last client disconnected from session: {s}", .{session_id});
                    return true; // Session removed
                } else {
                    // Update activity on client disconnect
                    const ts = std.Io.Clock.now(.real, self.io);
                    session_entry.last_activity_ns = @intCast(ts.toNanoseconds());
                    std.log.info("SSE: Client disconnected from session: {s}, remaining: {d}", .{
                        session_id, remaining,
                    });
                    return false; // Session still has clients
                }
            }
        }
        return false;
    }

    /// Create a new queue for a session
    pub fn createQueue(self: *Self) !*Queue {
        const queue = try self.allocator.create(Queue);
        queue.* = .{
            .io = self.io,
            .cond = std.Io.Condition.init,
            .mutex = std.Io.Mutex.init,
        };
        return queue;
    }

    /// Enqueue an event to send to ALL clients of a specific session
    pub fn enqueueEvent(self: *Self, session_id: []const u8, event: SseEvent) !void {
        // Get session entry pointer while holding mutex
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const session_ptr = self.sessions.getPtr(session_id);
        if (session_ptr == null) {
            std.debug.print("[SSE_DEBUG] enqueueEvent: session '{s}' NOT FOUND, auto-creating queue\n", .{session_id});
            // Auto-create a queue for this session if it doesn't exist
            // This handles the race condition where the workflow runs before
            // the SSE handler has registered the client
            const key = self.allocator.dupe(u8, session_id) catch {
                std.debug.print("[SSE_DEBUG] enqueueEvent: failed to dupe session_id\n", .{});
                return error.SessionNotFound;
            };
            var client_list = std.ArrayList(ClientInfo).empty;
            // NOTE: Do NOT call client_list.deinit() here - the ArrayList is moved into the SessionEntry
            // and will be cleaned up when the session is removed
            const new_queue = try self.createQueue();
            const ts = std.Io.Clock.now(.real, self.io);
            try client_list.append(self.allocator, ClientInfo{
                .queue = new_queue,
                .connected_at = ts.toSeconds(),
            });
            try self.sessions.put(key, SessionEntry{
                .clients = client_list,
                .last_activity_ns = @intCast(ts.toNanoseconds()),
            });
            std.debug.print("[SSE_DEBUG] enqueueEvent: auto-created queue for session '{s}'\n", .{session_id});
            // Now get the pointer again
            const new_session_ptr = self.sessions.getPtr(session_id) orelse {
                std.debug.print("[SSE_DEBUG] enqueueEvent: still not found after creation\n", .{});
                return error.SessionNotFound;
            };
            // Fan-out to the newly created client
            const item = self.allocator.create(SseQueueItem) catch return error.SessionNotFound;
            item.* = .{
                .data = self.allocator.dupe(u8, event.data) catch {
                    self.allocator.destroy(item);
                    return error.SessionNotFound;
                },
                .event_type = if (event.event_type) |et|
                    self.allocator.dupe(u8, et) catch null
                else
                    null,
            };
            new_session_ptr.clients.items[0].queue.enqueue(item);
            return;
        }
        const session_entry = session_ptr.?;
        const client_count = session_entry.clients.items.len;

        // Update last activity timestamp
        const ts = std.Io.Clock.now(.real, self.io);
        session_entry.last_activity_ns = @intCast(ts.toNanoseconds());

        // Fan-out the event to ALL clients
        var failed_clients: usize = 0;
        for (session_entry.clients.items) |*client_info| {
            // Create the item for this client
            const item = self.allocator.create(SseQueueItem) catch {
                failed_clients += 1;
                continue;
            };
            item.* = .{
                .data = self.allocator.dupe(u8, event.data) catch {
                    self.allocator.destroy(item);
                    failed_clients += 1;
                    continue;
                },
                .event_type = if (event.event_type) |et|
                    self.allocator.dupe(u8, et) catch null
                else
                    null,
            };
            client_info.queue.enqueue(item);
        }

        if (failed_clients > 0) {
            std.log.warn("SSE: Failed to enqueue event to {d}/{d} clients for session {s}", .{
                failed_clients, client_count, session_id,
            });
        }
    }

    /// Check if a session has any connected clients
    pub fn hasSession(self: *Self, session_id: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.sessions.contains(session_id);
    }

    /// Get the number of connected clients for a session
    pub fn getClientCount(self: *Self, session_id: []const u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.sessions.get(session_id)) |entry| {
            return entry.clients.items.len;
        }
        return 0;
    }

    /// Remove ALL clients for a session (forceful disconnect of entire session)
    /// Returns the number of clients that were removed
    pub fn removeSession(self: *Self, session_id: []const u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.sessions.getEntry(session_id)) |entry| {
            const count = entry.value_ptr.*.clients.items.len;
            // Close and destroy all client queues
            for (entry.value_ptr.*.clients.items) |client_info| {
                client_info.queue.close();
                self.allocator.destroy(client_info.queue);
            }
            entry.value_ptr.*.clients.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
            _ = self.sessions.remove(session_id);
            std.log.info("SSE: Session {s} removed, {d} clients disconnected", .{ session_id, count });
            return count;
        }
        return 0;
    }

    /// Broadcast an event to ALL clients of ALL sessions
    pub fn broadcast(self: *Self, event: SseEvent) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const ts = std.Io.Clock.now(.real, self.io);
        const now_ns: i64 = @intCast(ts.toNanoseconds());

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            // Update activity for this session
            entry.value_ptr.last_activity_ns = now_ns;

            for (entry.value_ptr.*.clients.items) |*client_info| {
                const item = self.allocator.create(SseQueueItem) catch {
                    std.log.warn("SSE broadcast: failed to create item for session {s}", .{entry.key_ptr.*});
                    continue;
                };
                item.* = .{
                    .data = self.allocator.dupe(u8, event.data) catch {
                        self.allocator.destroy(item);
                        std.log.warn("SSE broadcast: failed to dupe data for session {s}", .{entry.key_ptr.*});
                        continue;
                    },
                    .event_type = if (event.event_type) |et| self.allocator.dupe(u8, et) catch null else null,
                };
                client_info.queue.enqueue(item);
            }
        }
    }

    /// Internal cleanup - assumes mutex is already held
    fn cleanupIdleSessionsInternal(self: *Self) void {
        const ts = std.Io.Clock.now(.real, self.io);
        const now_ns: i64 = @intCast(ts.toNanoseconds());

        var sessions_to_remove = std.ArrayList([]const u8).empty;
        defer sessions_to_remove.deinit(self.allocator);

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            const idle_ns: i64 = @intCast(now_ns - entry.value_ptr.last_activity_ns);
            if (idle_ns > self.idle_timeout_ns) {
                std.log.info("SSE: Session {s} idle for {d}ms, removing", .{
                    entry.key_ptr.*, @divTrunc(idle_ns, 1_000_000),
                });
                sessions_to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (sessions_to_remove.items) |session_id| {
            if (self.sessions.getEntry(session_id)) |entry| {
                const count = entry.value_ptr.*.clients.items.len;
                for (entry.value_ptr.*.clients.items) |client_info| {
                    client_info.queue.close();
                    self.allocator.destroy(client_info.queue);
                }
                entry.value_ptr.*.clients.deinit(self.allocator);
                self.allocator.free(entry.key_ptr.*);
                _ = self.sessions.remove(session_id);
                _ = count;
            }
        }
    }

    /// Remove all sessions that have been idle longer than idle_timeout_ns
    /// Returns the number of sessions removed
    pub fn cleanupIdleSessions(self: *Self) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const before = self.sessions.count();
        self.cleanupIdleSessionsInternal();
        return before - self.sessions.count();
    }

    /// Get count of active sessions (for monitoring/debugging)
    pub fn getSessionCount(self: *Self) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.sessions.count();
    }

    /// Get total client count across all sessions (for monitoring/debugging)
    pub fn getTotalClientCount(self: *Self) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var total: usize = 0;
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            total += entry.value_ptr.*.clients.items.len;
        }
        return total;
    }
};
