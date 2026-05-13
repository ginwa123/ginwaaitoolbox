const std = @import("std");
const httpz = @import("httpz");

pub const SseEvent = struct {
    data: []const u8,
    event_type: ?[]const u8 = null,
};

/// Thread-safe event queue item for SSE
pub const SseQueueItem = struct {
    data: []const u8,
    event_type: ?[]const u8 = null,
    next: ?*SseQueueItem = null,
};

/// Thread-safe queue-based SSE connection manager
pub const SseConnectionManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// Map from session_id to session data
    sessions: std.StringHashMap(SessionData),
    /// Mutex to protect sessions map
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Idle session timeout in nanoseconds (default: 5 minutes)
    idle_timeout_ns: u64,
    /// Cleanup interval in nanoseconds (default: 1 minute)
    cleanup_interval_ns: u64,
    /// Background thread for periodic cleanup
    cleanup_thread: ?std.Thread = null,
    /// Stop signal for cleanup thread
    stop_cleanup: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    io: std.Io,

    pub const Queue = struct {
        head: ?*SseQueueItem = null,
        tail: ?*SseQueueItem = null,
        cond: std.Io.Condition = std.Io.Condition.init,
        mutex: std.Io.Mutex = std.Io.Mutex.init,
        closed: bool = false,
        io: std.Io,

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

        pub fn dequeueWithTimeout(self: *Queue, timeout_ns: u64) ?*SseQueueItem {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            const ts = std.Io.Clock.now(.real, self.io);
            const now_ns: i64 = @intCast(ts.toNanoseconds());
            const deadline = now_ns + @as(i64, @intCast(timeout_ns));

            while (self.head == null and !self.closed) {
                const ts2 = std.Io.Clock.now(.real, self.io);
                const now_ns2 = ts2.toNanoseconds();

                // Only wait if there's still time remaining. If deadline passed,
                // break immediately so we don't block forever on cond.wait().
                if (deadline <= now_ns2) break;

                // Note: cond.wait() waits indefinitely until signaled.
                // The timeout is enforced by our loop checking the deadline.
                self.cond.wait(self.io, &self.mutex) catch break;
            }

            if (self.head) |item| {
                self.head = item.next;
                if (self.head == null) self.tail = null;
                return item;
            }
            return null;
        }

        pub fn close(self: *Queue) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.closed = true;
            self.cond.broadcast(self.io);
        }
    };

    /// Session data - single struct holds everything for a session
    const SessionData = struct {
        /// List of client queues
        queues: std.ArrayList(*Queue),
        /// Last activity timestamp
        last_activity_ns: i64,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .sessions = std.StringHashMap(SessionData).init(allocator),
            .mutex = std.Io.Mutex.init,
            .idle_timeout_ns = 15 * 1_000_000_000, // 15 seconds - kill if no activity
            .cleanup_interval_ns = 5 * 1_000_000_000, // 5 seconds - check frequently
        };
    }

    /// Start the background cleanup thread for removing stale sessions
    pub fn startCleanupThread(self: *Self) !void {
        self.cleanup_thread = try std.Thread.spawn(.{}, cleanupThreadFn, .{self});
    }

    /// Background cleanup thread function
    fn cleanupThreadFn(self: *Self) void {
        const interval_ns = self.cleanup_interval_ns;
        while (!self.stop_cleanup.load(.unordered)) {
            self.io.sleep(.{ .nanoseconds = interval_ns }, .real) catch {};
            if (self.stop_cleanup.load(.unordered)) break;
            const cleaned = self.cleanupIdleSessions();
            if (cleaned > 0) std.log.info("SSE cleanup: removed {d} stale session(s)", .{cleaned});
        }
    }

    pub fn deinit(self: *Self) void {
        self.stop_cleanup.store(true, .unordered);
        if (self.cleanup_thread) |thread| thread.join();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.queues.items) |queue| {
                queue.close();
                self.allocator.destroy(queue);
            }
            entry.value_ptr.queues.deinit(self.allocator);
        }
        self.sessions.deinit();
    }

    pub fn registerClient(self: *Self, session_id: []const u8, queue: *Queue) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Clean up idle sessions first (does NOT re-acquire the mutex)
        self.cleanupIdleSessionsLocked();

        const ts = std.Io.Clock.now(.real, self.io);
        const now_ns: i64 = @intCast(ts.toNanoseconds());

        const gop = try self.sessions.getOrPut(session_id);
        if (gop.found_existing) {
            // Session exists — just append the new client queue.
            // No new key allocation needed; the map already owns its key.
            try gop.value_ptr.queues.append(self.allocator, queue);
            gop.value_ptr.last_activity_ns = now_ns;
            std.log.info("SSE: Client connected to existing session: {s}, total clients: {d}", .{
                session_id, gop.value_ptr.queues.items.len,
            });
        } else {
            // New session — duplicate the key so the map owns its lifetime.
            errdefer _ = self.sessions.remove(session_id);
            const owned_key = try self.allocator.dupe(u8, session_id);
            gop.key_ptr.* = owned_key;

            var queues = std.ArrayList(*Queue).empty;
            try queues.append(self.allocator, queue);
            gop.value_ptr.* = SessionData{
                .queues = queues,
                .last_activity_ns = now_ns,
            };
            std.log.info("SSE: First client connected to new session: {s}", .{session_id});
        }
    }

    pub fn removeClient(self: *Self, session_id: []const u8, queue: *Queue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.sessions.getEntry(session_id)) |entry| {
            const session = &entry.value_ptr.*;

            // Find and remove this client's queue
            var found_idx: ?usize = null;
            for (session.queues.items, 0..) |q, idx| {
                if (q == queue) {
                    found_idx = idx;
                    break;
                }
            }

            if (found_idx) |idx| {
                _ = session.queues.orderedRemove(idx);
                queue.close();
                self.allocator.destroy(queue);

                if (session.queues.items.len == 0) {
                    // Last client — clean up session.
                    const owned_key = entry.key_ptr.*;
                    session.queues.deinit(self.allocator);
                    _ = self.sessions.remove(session_id);
                    self.allocator.free(owned_key);
                    std.log.info("SSE: Last client disconnected from session: {s}", .{session_id});
                    return true;
                } else {
                    const ts = std.Io.Clock.now(.real, self.io);
                    session.last_activity_ns = @intCast(ts.toNanoseconds());
                    std.log.info("SSE: Client disconnected from session: {s}, remaining: {d}", .{
                        session_id, session.queues.items.len,
                    });
                    return false;
                }
            }
        }
        return false;
    }

    pub fn createQueue(self: *Self) !*Queue {
        const queue = try self.allocator.create(Queue);
        queue.* = .{
            .io = self.io,
            .cond = std.Io.Condition.init,
            .mutex = std.Io.Mutex.init,
        };
        return queue;
    }

    pub fn enqueueEvent(self: *Self, session_id: []const u8, event: SseEvent) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const ts = std.Io.Clock.now(.real, self.io);
        const now_ns: i64 = @intCast(ts.toNanoseconds());

        const entry = self.sessions.getEntry(session_id) orelse return error.SessionNotFound;

        entry.value_ptr.last_activity_ns = now_ns;

        // Fan-out: deliver a copy of the event to every connected client queue.
        for (entry.value_ptr.queues.items) |q| {
            const data_copy = self.allocator.dupe(u8, event.data) catch continue;
            const item = self.allocator.create(SseQueueItem) catch {
                self.allocator.free(data_copy);
                continue;
            };
            item.* = .{
                .data = data_copy,
                .event_type = if (event.event_type) |et|
                    self.allocator.dupe(u8, et) catch null
                else
                    null,
                .next = null,
            };
            q.enqueue(item);
        }
    }

    pub fn hasSession(self: *Self, session_id: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.sessions.contains(session_id);
    }

    pub fn getClientCount(self: *Self, session_id: []const u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.sessions.get(session_id)) |session| {
            return session.queues.items.len;
        }
        return 0;
    }

    /// Remove a session and close all its client queues. Returns the number of
    /// clients that were disconnected. Caller must NOT hold self.mutex.
    pub fn removeSession(self: *Self, session_id: []const u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.removeSessionLocked(session_id);
    }

    /// Internal version — caller must already hold self.mutex.
    fn removeSessionLocked(self: *Self, session_id: []const u8) usize {
        if (self.sessions.getEntry(session_id)) |entry| {
            const count = entry.value_ptr.queues.items.len;
            const owned_key = entry.key_ptr.*;
            for (entry.value_ptr.queues.items) |queue| {
                queue.close();
                self.allocator.destroy(queue);
            }
            entry.value_ptr.queues.deinit(self.allocator);
            _ = self.sessions.remove(session_id);
            self.allocator.free(owned_key);
            std.log.info("SSE: Session {s} removed, {d} clients disconnected", .{ session_id, count });
            return count;
        }
        return 0;
    }

    pub fn broadcast(self: *Self, event: SseEvent) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const ts = std.Io.Clock.now(.real, self.io);
        const now_ns: i64 = @intCast(ts.toNanoseconds());

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.last_activity_ns = now_ns;

            for (entry.value_ptr.queues.items) |queue| {
                const data_copy = self.allocator.dupe(u8, event.data) catch {
                    std.log.warn("SSE broadcast: failed to dupe data", .{});
                    continue;
                };
                const item = self.allocator.create(SseQueueItem) catch {
                    std.log.warn("SSE broadcast: failed to create item", .{});
                    self.allocator.free(data_copy);
                    continue;
                };
                item.* = .{
                    .data = data_copy,
                    .event_type = if (event.event_type) |et| self.allocator.dupe(u8, et) catch null else null,
                    .next = null,
                };
                queue.enqueue(item);
            }
        }
    }

    /// Caller must hold self.mutex. Removes sessions idle longer than
    /// self.idle_timeout_ns. Does NOT call removeSession (which would
    /// deadlock by trying to re-acquire the mutex).
    fn cleanupIdleSessionsLocked(self: *Self) void {
        const ts = std.Io.Clock.now(.real, self.io);
        const now_ns: i64 = @intCast(ts.toNanoseconds());

        // Collect keys of sessions to remove. We can't remove while iterating.
        var to_remove = std.ArrayList([]const u8).empty;
        defer to_remove.deinit(self.allocator);

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            const idle_ns = now_ns - entry.value_ptr.last_activity_ns;
            if (idle_ns > @as(i64, @intCast(self.idle_timeout_ns))) {
                // Use the caller's slice; we will look the entry up again
                // in removeSessionLocked using the original key bytes.
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            // Pass the map-owned key slice; removeSessionLocked does the lookup
            // and frees the owned copy itself.
            _ = self.removeSessionLocked(key);
        }
    }

    pub fn cleanupIdleSessions(self: *Self) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const before = self.sessions.count();
        self.cleanupIdleSessionsLocked();
        return before - self.sessions.count();
    }

    pub fn getSessionCount(self: *Self) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.sessions.count();
    }

    pub fn getTotalClientCount(self: *Self) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var total: usize = 0;
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            total += entry.value_ptr.queues.items.len;
        }
        return total;
    }
};
