const std = @import("std");
const httpz = @import("httpz");

pub const SseEvent = struct {
    data: []const u8,
    event_type: ?[]const u8 = null,

    /// Maximum size for SSE event formatting (legacy constant, no longer used)
    pub const MAX_SSE_SIZE = 1048576;

    /// Format SSE event into a provided buffer (stack-allocated, no heap allocations)
    /// Returns the formatted bytes or error.BufferTooSmall if buffer is insufficient
    /// Proper SSE format: "event: <type>\ndata: <line1>\ndata: <line2>\n\n"
    pub fn formatInto(self: SseEvent, buf: []u8) error{BufferTooSmall}![]u8 {
        var pos: usize = 0;

        // Write event type line if specified
        if (self.event_type) |event_type| {
            const event_line = std.fmt.bufPrint(buf[pos..], "event: {s}\n", .{event_type}) catch return error.BufferTooSmall;
            pos += event_line.len;
        }

        // If data is empty, write a placeholder to ensure we send something
        if (self.data.len == 0) {
            const needed = 7; // "data: \n"
            if (pos + needed > buf.len) return error.BufferTooSmall;
            @memcpy(buf[pos..][0..7], "data: \n");
            pos += 7;
        } else {
            // Write data lines: "data: <line>\n" for each line
            var iter = std.mem.splitScalar(u8, self.data, '\n');
            while (iter.next()) |line| {
                if (line.len == 0) continue; // Skip empty lines from split
                // Format: "data: <content>\n"
                const needed_for_line = 6 + line.len + 1; // "data: " + content + "\n"
                if (pos + needed_for_line > buf.len) return error.BufferTooSmall;
                @memcpy(buf[pos..][0..6], "data: ");
                pos += 6;
                @memcpy(buf[pos..][0..line.len], line);
                pos += line.len;
                buf[pos] = '\n';
                pos += 1;
            }
        }

        // Final newline to end the event
        if (pos + 1 > buf.len) return error.BufferTooSmall;
        buf[pos] = '\n';
        pos += 1;

        return buf[0..pos];
    }

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
/// Uses a channel approach: the SSE handler thread owns the stream and reads from a queue
/// while other threads enqueue events. This avoids concurrent stream access.
pub const SseConnectionManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// Map from session_id to event queue
    queues: std.StringHashMap(*Queue),
    mutex: std.Thread.Mutex,

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
            .queues = std.StringHashMap(*Queue).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.queues.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.close();
            self.allocator.destroy(entry.value_ptr);
        }
        self.queues.deinit();
    }

    /// Register a new SSE connection with its event queue
    pub fn register(self: *Self, session_id: []const u8, queue: *Queue) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(key);

        try self.queues.put(key, queue);
        std.log.info("SSE registered: session_id={s}", .{session_id});
    }

    /// Remove a connection
    pub fn remove(self: *Self, session_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.queues.fetchRemove(session_id)) |entry| {
            self.allocator.free(entry.key);
            std.log.info("SSE removed: session_id={s}", .{session_id});
        }
    }

    /// Create a new queue for a session
    pub fn createQueue(self: *Self) !*Queue {
        const queue = try self.allocator.create(Queue);
        queue.* = .{};
        return queue;
    }

    /// Enqueue an event to send to a specific session
    pub fn enqueueEvent(self: *Self, session_id: []const u8, event: SseEvent) !void {
        // Get queue pointer while holding mutex
        self.mutex.lock();
        const q = self.queues.get(session_id);
        if (q == null) {
            self.mutex.unlock();
            return error.SessionNotFound;
        }
        const queue_ptr = q.?;
        self.mutex.unlock();

        // Create the item (outside manager mutex)
        const item = try self.allocator.create(SseQueueItem);
        errdefer self.allocator.destroy(item);
        item.* = .{
            .data = try self.allocator.dupe(u8, event.data),
            .event_type = if (event.event_type) |et| try self.allocator.dupe(u8, et) else null,
        };
        errdefer {
            self.allocator.free(item.data);
            if (item.event_type) |et| self.allocator.free(et);
        }

        // Re-acquire manager mutex to check queue still exists, then enqueue
        self.mutex.lock();
        defer self.mutex.unlock();
        const queueStillExists = self.queues.get(session_id);
        if (queueStillExists == queue_ptr) {
            queue_ptr.enqueue(item);
        } else {
            return error.SessionNotFound;
        }
    }

    /// Check if a session exists
    pub fn hasSession(self: *Self, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.queues.contains(session_id);
    }

    /// Broadcast an event to ALL connected sessions
    pub fn broadcast(self: *Self, event: SseEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.queues.iterator();
        while (iter.next()) |entry| {
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
            entry.value_ptr.enqueue(item);
        }
    }
};
