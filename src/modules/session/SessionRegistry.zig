//! ## Session Registry
//!
//! Thread-safe registry for tracking session state with support for:
//! - **Activity tracking**: Atomic counters for nested/recursive running
//! - **Cancellation**: Boolean flags for explicit cancellation requests
//! - **Stopped flag**: Persistent flag that makes is_running() return false
//! - **Message queuing**: Queue messages for paused/interrupted sessions
//!
//! ## Usage Example
//!
//! ```zig
//! // At session start - register the session
//! try session_registry.get_global_registry().?.register(session_id);
//!
//! // At start of while-loop
//! session_registry.get_global_registry().?.mark_running(session_id);
//! defer {
//!     session_registry.get_global_registry().?.mark_idle(session_id);
//! }
//!
//! while (true) {
//!     // Check if still active
//!     if (session_registry.get_global_registry()) |registry| {
//!         if (!registry.is_running(session_id)) break;
//!     }
//!     // ... loop body
//! }
//!
//! // When user cancels/pauses session:
//! session_registry.get_global_registry().?.cancel(session_id);
//! ```

const std = @import("std");

/// Thread-safe registry for session state management
pub const SessionRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// Activity count per session (0 = idle/not registered)
    activity: std.StringHashMap(*std.atomic.Value(usize)),
    /// Cancellation flag per session
    cancelled: std.StringHashMap(*std.atomic.Value(bool)),
    /// Message queue per session
    message_queues: std.StringHashMap(*std.ArrayList([]const u8)),
    /// Stopped flag per session - once stopped, is_running returns false until re-registered
    stopped: std.StringHashMap(?[]const u8),
    /// Mutex for thread-safe registration
    register_mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .activity = std.StringHashMap(*std.atomic.Value(usize)).init(allocator),
            .cancelled = std.StringHashMap(*std.atomic.Value(bool)).init(allocator),
            .message_queues = std.StringHashMap(*std.ArrayList([]const u8)).init(allocator),
            .stopped = std.StringHashMap(?[]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up message queues
        var queue_iter = self.message_queues.iterator();
        while (queue_iter.next()) |entry| {
            for (entry.value_ptr.*.items) |msg| {
                self.allocator.free(msg);
            }
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.message_queues.deinit();

        // Clean up activity counters
        var activity_iter = self.activity.iterator();
        while (activity_iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.activity.deinit();

        // Clean up cancellation flags
        var cancelled_iter = self.cancelled.iterator();
        while (cancelled_iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.cancelled.deinit();

        // Clean up stopped flags
        var stopped_iter = self.stopped.iterator();
        while (stopped_iter.next()) |entry| {
            if (entry.value_ptr.*) |reason| {
                self.allocator.free(reason);
            }
            self.allocator.free(entry.key_ptr.*);
        }
        self.stopped.deinit();
    }

    pub fn register(self: *Self, session_id: []const u8) !void {
        self.register_mutex.lock();
        defer self.register_mutex.unlock();

        // Always clean up any orphaned entries first (entry might exist in some maps but not all)
        _ = self.cancelled.remove(session_id);
        _ = self.message_queues.remove(session_id);
        _ = self.stopped.remove(session_id);

        if (self.activity.get(session_id)) |atomic| {
            atomic.store(0, .seq_cst);
            if (self.cancelled.get(session_id)) |cancel_atomic| {
                cancel_atomic.store(false, .seq_cst);
            } else {
                // cancelled was cleaned up above, re-create it
                const cancelled_atomic = try self.allocator.create(std.atomic.Value(bool));
                cancelled_atomic.* = std.atomic.Value(bool).init(false);
                errdefer self.allocator.destroy(cancelled_atomic);
                const key = try self.allocator.dupe(u8, session_id);
                errdefer self.allocator.free(key);
                // Use fetchPut to handle case where key might exist (race condition safety)
                const existing = try self.cancelled.fetchPut(key, cancelled_atomic);
                if (existing) |kv| {
                    // Key already existed - reuse existing atomic, cleanup our new one
                    self.allocator.destroy(cancelled_atomic);
                    kv.value.store(false, .seq_cst);
                }
            }
            // Clear stopped flag when re-registering
            if (self.stopped.fetchRemove(session_id)) |entry| {
                if (entry.value) |reason| {
                    self.allocator.free(reason);
                }
                self.allocator.free(entry.key);
            }
            return;
        }

        // Create key for insertion (use session_id directly as it's already unique per session)
        const key = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(key);

        // Create activity counter
        const activity_atomic = try self.allocator.create(std.atomic.Value(usize));
        activity_atomic.* = std.atomic.Value(usize).init(0);
        errdefer {
            self.allocator.destroy(activity_atomic);
        }
        // Use fetchPut for safety - handle existing key from race conditions
        const existing_activity = try self.activity.fetchPut(key, activity_atomic);
        if (existing_activity) |kv| {
            // Key already existed - cleanup our new atomic, reuse existing
            self.allocator.destroy(activity_atomic);
            kv.value.store(0, .seq_cst);
        }

        // Create cancellation flag - use fetchPut to handle race conditions
        const cancelled_atomic = try self.allocator.create(std.atomic.Value(bool));
        cancelled_atomic.* = std.atomic.Value(bool).init(false);
        errdefer {
            self.allocator.destroy(cancelled_atomic);
        }
        // Re-create key since fetchPut might have consumed it
        const cancelled_key = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(cancelled_key);
        
        const existing_cancelled = try self.cancelled.fetchPut(cancelled_key, cancelled_atomic);
        if (existing_cancelled) |kv| {
            // Key already existed - cleanup our new atomic
            self.allocator.destroy(cancelled_atomic);
            kv.value.store(false, .seq_cst);
        }

        // Create message queue
        const queue = try self.allocator.create(std.ArrayList([]const u8));
        queue.* = std.ArrayList([]const u8).empty;
        errdefer {
            queue.deinit(self.allocator);
            self.allocator.destroy(queue);
        }
        const queue_key = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(queue_key);
        
        const existing_queue = try self.message_queues.fetchPut(queue_key, queue);
        if (existing_queue) |kv| {
            // Key already existed - cleanup our new queue
            for (kv.value.items) |msg| {
                self.allocator.free(msg);
            }
            kv.value.deinit(self.allocator);
            self.allocator.destroy(queue);
        }
    }

    pub fn unregister(self: *Self, session_id: []const u8) void {
        self.register_mutex.lock();
        defer self.register_mutex.unlock();

        // Clean up message queue
        if (self.message_queues.fetchRemove(session_id)) |entry| {
            for (entry.value.items) |msg| {
                self.allocator.free(msg);
            }
            entry.value.deinit(self.allocator);
            self.allocator.destroy(entry.value);
        }

        // Clean up activity counter
        if (self.activity.fetchRemove(session_id)) |entry| {
            self.allocator.destroy(entry.value);
            self.allocator.free(entry.key);
        }

        // Clean up cancellation flag
        if (self.cancelled.fetchRemove(session_id)) |entry| {
            self.allocator.destroy(entry.value);
            self.allocator.free(entry.key);
        }

        // Clean up stopped flag
        if (self.stopped.fetchRemove(session_id)) |entry| {
            if (entry.value) |reason| {
                self.allocator.free(reason);
            }
            self.allocator.free(entry.key);
        }
    }

    pub fn is_registered(self: *Self, session_id: []const u8) bool {
        return self.activity.contains(session_id);
    }

    // ========== Activity Tracking ==========

    pub fn mark_running(self: *Self, session_id: []const u8) void {
        if (self.activity.get(session_id)) |atomic| {
            _ = atomic.fetchAdd(1, .seq_cst);
        }
    }

    pub fn mark_idle(self: *Self, session_id: []const u8) void {
        if (self.activity.get(session_id)) |atomic| {
            _ = atomic.fetchSub(1, .seq_cst);
        }
    }

    pub fn mark_stopped(self: *Self, session_id: []const u8) void {
        self.register_mutex.lock();
        defer self.register_mutex.unlock();

        // Reset activity count to 0
        if (self.activity.get(session_id)) |atomic| {
            atomic.store(0, .seq_cst);
        }

        // Set stopped flag if not already set
        if (!self.stopped.contains(session_id)) {
            const key = self.allocator.dupe(u8, session_id) catch return;
            self.stopped.put(key, null) catch {
                self.allocator.free(key);
            };
        }
    }

    /// Check if a session is currently running (not stopped and has activity > 0)
    pub fn is_running(self: *Self, session_id: []const u8) bool {
        const atomic = self.activity.get(session_id) orelse return false;
        if (self.stopped.contains(session_id)) return false;
        return atomic.load(.seq_cst) > 0;
    }

    pub fn is_stopped(self: *Self, session_id: []const u8) bool {
        return self.stopped.contains(session_id);
    }

    // ========== Cancellation ==========

    /// Cancel a specific session
    pub fn cancel(self: *Self, session_id: []const u8) void {
        if (self.cancelled.get(session_id)) |atomic| {
            atomic.store(true, .seq_cst);
        }
    }

    /// Reset cancellation for a specific session
    pub fn reset(self: *Self, session_id: []const u8) void {
        if (self.cancelled.get(session_id)) |atomic| {
            atomic.store(false, .seq_cst);
        }
    }

    /// Check if a session is cancelled
    pub fn is_cancelled(self: *Self, session_id: []const u8) bool {
        if (self.cancelled.get(session_id)) |atomic| {
            return atomic.load(.seq_cst);
        }
        return false;
    }

    // ========== Session Counting ==========

    pub fn has_sessions(self: *Self) bool {
        return self.activity.count() > 0;
    }

    pub fn session_count(self: *Self) usize {
        return self.activity.count();
    }

    /// Get a direct pointer to the cancellation atomic (for TUIWorkflow to store)
    pub fn get_cancellation_atomic(self: *Self, session_id: []const u8) ?*std.atomic.Value(bool) {
        return self.cancelled.get(session_id);
    }

    /// Get all registered session IDs as an ArrayList
    /// Caller must free the returned list and its items
    pub fn get_session_ids(self: *Self, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
        var result = std.ArrayList([]const u8).empty;
        var iter = self.activity.iterator();
        while (iter.next()) |entry| {
            const copy = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(copy);
            try result.append(allocator, copy);
        }
        return result;
    }

    /// Get queue count for a session (0 if not registered or empty)
    pub fn get_queue_count(self: *Self, session_id: []const u8) usize {
        if (self.message_queues.get(session_id)) |queue| {
            return queue.items.len;
        }
        return 0;
    }

    // ========== Message Queues ==========

    pub fn queue_message(self: *Self, session_id: []const u8, message: []const u8) void {
        self.register_mutex.lock();
        defer self.register_mutex.unlock();

        if (self.message_queues.get(session_id)) |queue| {
            const msg_copy = self.allocator.dupe(u8, message) catch return;
            queue.append(self.allocator, msg_copy) catch {
                self.allocator.free(msg_copy);
            };
        }
    }

    pub fn is_have_queue_message(self: *Self, session_id: []const u8) bool {
        if (self.message_queues.get(session_id)) |queue| {
            return queue.items.len > 0;
        }
        return false;
    }

    /// Get and clear all queued messages. Returns null if queue is empty.
    /// Caller must call deinit() on the returned list.
    pub fn get_queue_messages(self: *Self, session_id: []const u8) ?std.ArrayList([]const u8) {
        if (self.message_queues.get(session_id)) |queue| {
            if (queue.items.len == 0) return null;
            const result = queue.*;
            queue.* = std.ArrayList([]const u8).empty;
            return result;
        }
        return null;
    }

    /// Delete a specific message from the queue (removes first occurrence)
    pub fn delete_queue_messages(self: *Self, session_id: []const u8, message: []const u8) void {
        self.register_mutex.lock();
        defer self.register_mutex.unlock();

        if (self.message_queues.get(session_id)) |queue| {
            for (queue.items, 0..) |msg, i| {
                if (std.mem.eql(u8, msg, message)) {
                    self.allocator.free(msg);
                    _ = queue.swapRemove(i);
                    return;
                }
            }
        }
    }
};

// ========== Global Registry ==========

var g_registry: ?*SessionRegistry = null;
var g_mutex: std.Thread.Mutex = .{};
var g_allocator: ?std.mem.Allocator = null;

/// Initialize the global registry (call once at startup)
pub fn init_global_registry(allocator: std.mem.Allocator) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_registry == null) {
        g_allocator = allocator;
        const registry = allocator.create(SessionRegistry) catch unreachable;
        registry.* = SessionRegistry.init(allocator);
        g_registry = registry;
    }
}

/// Get the global registry instance
pub fn get_global_registry() ?*SessionRegistry {
    g_mutex.lock();
    defer g_mutex.unlock();
    return g_registry;
}

/// Deinitialize the global registry (call at shutdown)
pub fn deinit_global_registry() void {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_registry) |registry| {
        if (g_allocator) |allocator| {
            registry.deinit();
            allocator.destroy(registry);
        }
        g_registry = null;
        g_allocator = null;
    }
}
