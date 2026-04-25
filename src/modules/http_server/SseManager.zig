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

/// Thread-safe queue-based SSE connection manager
/// Supports MULTIPLE clients per session_id - each session can have many concurrent connections
/// Uses a channel approach: each SSE handler thread owns its stream and reads from its own queue
/// while other threads enqueue events to ALL client queues for a session.
pub const SseConnectionManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// Map from session_id to list of client info (queues)
    /// Each client gets its own queue, allowing independent streaming
    clients: std.StringHashMap(std.ArrayList(ClientInfo)),
    /// Mutex to protect the clients map
    mutex: std.Thread.Mutex,
    /// Condition for client count changes (for cleanup tracking)
    cond: std.Thread.Condition = .{},

    /// Client info - holds a queue for a specific client connection
    pub const ClientInfo = struct {
        queue: *Queue,
        connected_at: i64,
    };

    pub const Queue = struct {
        head: ?*SseQueueItem = null,
        tail: ?*SseQueueItem = null,
        cond: std.Thread.Condition = .{},
        mutex: std.Thread.Mutex = .{},
        closed: bool = false,

        /// Add an item to the queue (thread-safe)
        pub fn enqueue(self: *Queue, item: *SseQueueItem) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            item.next = null;
            if (self.tail) |tail| {
                tail.next = item;
            } else {
                self.head = item;
            }
            self.tail = item;
            self.cond.signal();
        }

        /// Get an item from the queue with timeout (thread-safe)
        /// Returns null if timeout expires or queue is closed
        pub fn dequeueWithTimeout(self: *Queue, timeout_ns: u64) ?*SseQueueItem {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Wait for an item or timeout
            const deadline = std.time.nanoTimestamp() + @as(i64, @intCast(timeout_ns));
            while (self.head == null and !self.closed) {
                const remaining = @as(u64, @intCast(deadline - std.time.nanoTimestamp()));
                if (remaining == 0) break;
                self.cond.wait(&self.mutex);
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
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.cond.broadcast();
        }
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .clients = std.StringHashMap(std.ArrayList(ClientInfo)).init(allocator),
            .mutex = .{},
            .cond = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.clients.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // Close and destroy all client queues
            for (entry.value_ptr.*.items) |client_info| {
                client_info.queue.close();
                self.allocator.destroy(client_info.queue);
            }
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.clients.deinit();
    }

    /// Register a new client SSE connection with its event queue
    /// Multiple clients can register for the same session_id - each gets their own queue
    pub fn registerClient(self: *Self, session_id: []const u8, queue: *Queue) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = try self.allocator.dupe(u8, session_id);

        // Get or create the client list for this session
        if (self.clients.getPtr(key)) |client_list| {
            // Session exists, append new client
            try client_list.append(self.allocator, ClientInfo{
                .queue = queue,
                .connected_at = std.time.timestamp(),
            });
            std.log.info("SSE: Client connected to existing session: {s}, total clients: {d}", .{
                session_id, client_list.items.len,
            });
        } else {
            // New session, create client list
            var client_list = std.ArrayList(ClientInfo).empty;
            errdefer client_list.deinit(self.allocator);
            try client_list.append(self.allocator, ClientInfo{
                .queue = queue,
                .connected_at = std.time.timestamp(),
            });
            try self.clients.put(key, client_list);
            std.log.info("SSE: First client connected to new session: {s}", .{session_id});
        }
    }

    /// Remove a specific client connection
    /// Returns true if this was the last client for the session
    pub fn removeClient(self: *Self, session_id: []const u8, queue: *Queue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.clients.getEntry(session_id)) |entry| {
            const client_list = &entry.value_ptr.*;

            // Find and remove the specific client
            var found_idx: ?usize = null;
            for (client_list.items, 0..) |client_info, idx| {
                if (client_info.queue == queue) {
                    found_idx = idx;
                    break;
                }
            }

            if (found_idx) |idx| {
                const client_info = client_list.orderedRemove(idx);
                client_info.queue.close();
                self.allocator.destroy(client_info.queue);

                const remaining = client_list.items.len;
                if (remaining == 0) {
                    // Last client disconnected - clean up the session
                    self.allocator.free(entry.key_ptr.*);
                    entry.value_ptr.*.deinit(self.allocator);
                    _ = self.clients.remove(entry.key_ptr.*);
                    std.log.info("SSE: Last client disconnected from session: {s}", .{session_id});
                    return true; // Session removed
                } else {
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
        queue.* = .{};
        return queue;
    }

    /// Enqueue an event to send to ALL clients of a specific session
    pub fn enqueueEvent(self: *Self, session_id: []const u8, event: SseEvent) !void {
        // Get client list pointer while holding mutex
        self.mutex.lock();
        const client_list_ptr = self.clients.getPtr(session_id);
        if (client_list_ptr == null) {
            self.mutex.unlock();
            return error.SessionNotFound;
        }
        const client_list = client_list_ptr.?;
        const client_count = client_list.items.len;
        self.mutex.unlock();

        // Fan-out the event to ALL clients
        var failed_clients: usize = 0;
        for (client_list.items) |*client_info| {
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
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.clients.contains(session_id);
    }

    /// Get the number of connected clients for a session
    pub fn getClientCount(self: *Self, session_id: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.clients.get(session_id)) |list| {
            return list.items.len;
        }
        return 0;
    }

    /// Remove ALL clients for a session (forceful disconnect of entire session)
    /// Returns the number of clients that were removed
    pub fn removeSession(self: *Self, session_id: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.clients.getEntry(session_id)) |entry| {
            const count = entry.value_ptr.*.items.len;
            // Close and destroy all client queues
            for (entry.value_ptr.*.items) |client_info| {
                client_info.queue.close();
                self.allocator.destroy(client_info.queue);
            }
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
            _ = self.clients.remove(session_id);
            std.log.info("SSE: Session {s} removed, {d} clients disconnected", .{ session_id, count });
            return count;
        }
        return 0;
    }

    /// Broadcast an event to ALL clients of ALL sessions
    pub fn broadcast(self: *Self, event: SseEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.clients.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.*.items) |*client_info| {
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
};
