//! ## Session Activity Registry
//! 
//! Thread-safe registry for tracking which sessions are currently running their main while-loop.
//! Mirrors the CancellationRegistry pattern but uses atomic counters for nested/recursive tracking.
//! Also supports message queuing for paused/interrupted sessions.
//! 
//! ## Usage Example
//! 
//! ```zig
//! // At session start - register the session
//! try activity_registry.get_global_registry().?.register(session_id);
//! 
//! // At start of while-loop
//! activity_registry.get_global_registry().?.mark_running(session_id);
//! defer {
//!     activity_registry.get_global_registry().?.mark_idle(session_id);
//! }
//! 
//! while (true) {
//!     // Check if still active
//!     if (activity_registry.get_global_registry()) |registry| {
//!         if (!registry.is_running(session_id)) break;
//!     }
//!     // ... loop body
//! }
//! ```

const std = @import("std");

pub const ActivityRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// Activity count per session (0 = idle/not registered)
    sessions: std.StringHashMap(*std.atomic.Value(usize)),
    /// Message queue per session
    message_queues: std.StringHashMap(*std.ArrayList([]const u8)),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(*std.atomic.Value(usize)).init(allocator),
            .message_queues = std.StringHashMap(*std.ArrayList([]const u8)).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up message queues
        var queue_iter = self.message_queues.iterator();
        while (queue_iter.next()) |entry| {
            // Free all messages in the queue
            for (entry.value_ptr.*.items) |msg| {
                self.allocator.free(msg);
            }
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.message_queues.deinit();

        // Clean up session activity counters
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.sessions.deinit();
    }

    pub fn register(self: *Self, session_id: []const u8) !void {
        // If already registered, reset it
        if (self.sessions.get(session_id)) |atomic| {
            atomic.store(0, .seq_cst);
            return;
        }

        const atomic = try self.allocator.create(std.atomic.Value(usize));
        atomic.* = std.atomic.Value(usize).init(0);

        const key = try self.allocator.dupe(u8, session_id);
        try self.sessions.put(key, atomic);

        // Also create message queue for this session
        const queue = try self.allocator.create(std.ArrayList([]const u8));
        queue.* = std.ArrayList([]const u8).empty;
        try self.message_queues.put(key, queue);
    }

    pub fn unregister(self: *Self, session_id: []const u8) void {
        // Clean up message queue
        if (self.message_queues.fetchRemove(session_id)) |entry| {
            for (entry.value.items) |msg| {
                self.allocator.free(msg);
            }
            entry.value.deinit(self.allocator);
            self.allocator.destroy(entry.value);
        }

        // Clean up session activity counter
        if (self.sessions.fetchRemove(session_id)) |entry| {
            self.allocator.destroy(entry.value);
            self.allocator.free(entry.key);
        }
    }

    pub fn is_registered(self: *Self, session_id: []const u8) bool {
        return self.sessions.contains(session_id);
    }

    pub fn mark_running(self: *Self, session_id: []const u8) void {
        if (self.sessions.get(session_id)) |atomic| {
            _ = atomic.fetchAdd(1, .seq_cst);
        }
    }

    pub fn mark_idle(self: *Self, session_id: []const u8) void {
        if (self.sessions.get(session_id)) |atomic| {
            _ = atomic.fetchSub(1, .seq_cst);
        }
    }

    /// Reset activity count to 0 immediately (e.g., when session stops completely)
    pub fn mark_stopped(self: *Self, session_id: []const u8) void {
        if (self.sessions.get(session_id)) |atomic| {
            atomic.store(0, .seq_cst);
        }
    }

    pub fn is_running(self: *Self, session_id: []const u8) bool {
        if (self.sessions.get(session_id)) |atomic| {
            return atomic.load(.seq_cst) > 0;
        }
        return false;
    }

    /// Queue a message for a session
    pub fn queue_message(self: *Self, session_id: []const u8, message: []const u8) void {
        if (self.message_queues.get(session_id)) |queue| {
            const msg_copy = self.allocator.dupe(u8, message) catch return;
            queue.append(self.allocator, msg_copy) catch {
                self.allocator.free(msg_copy);
            };
        }
    }

    /// Check if session has queued messages
    pub fn is_have_queue_message(self: *Self, session_id: []const u8) bool {
        if (self.message_queues.get(session_id)) |queue| {
            return queue.items.len > 0;
        }
        return false;
    }

    /// Get and clear all queued messages (returns null-joined string)
    /// Caller owns the returned memory.
    pub fn get_queue_messages(self: *Self, session_id: []const u8) ?[]u8 {
        if (self.message_queues.get(session_id)) |queue| {
            if (queue.items.len == 0) {
                return null;
            }

            // Join all messages with newline
            var result = std.ArrayList(u8).empty;
            errdefer result.deinit(self.allocator);

            for (queue.items, 0..) |msg, i| {
                if (i > 0) {
                    result.append(self.allocator, '\n') catch unreachable;
                }
                result.appendSlice(self.allocator, msg) catch unreachable;
            }

            // Clear the queue
            for (queue.items) |msg| {
                self.allocator.free(msg);
            }
            queue.clearRetainingCapacity();

            return result.toOwnedSlice(self.allocator) catch return null;
        }
        return null;
    }
};

// Global registry singleton
var g_activity_registry: ?*ActivityRegistry = null;
var g_activity_mutex: std.Thread.Mutex = .{};
var g_activity_allocator: ?std.mem.Allocator = null;

/// Initialize the global registry (call once at startup)
pub fn initGlobalRegistry(allocator: std.mem.Allocator) void {
    g_activity_mutex.lock();
    defer g_activity_mutex.unlock();
    if (g_activity_registry == null) {
        g_activity_allocator = allocator;
        const registry = allocator.create(ActivityRegistry) catch unreachable;
        registry.* = ActivityRegistry.init(allocator);
        g_activity_registry = registry;
    }
}

/// Get the global registry instance
pub fn get_global_registry() ?*ActivityRegistry {
    g_activity_mutex.lock();
    defer g_activity_mutex.unlock();
    return g_activity_registry;
}

/// Deinitialize the global registry (call at shutdown)
pub fn deinitGlobalRegistry() void {
    g_activity_mutex.lock();
    defer g_activity_mutex.unlock();
    if (g_activity_registry) |registry| {
        if (g_activity_allocator) |allocator| {
            registry.deinit();
            allocator.destroy(registry);
        }
        g_activity_registry = null;
        g_activity_allocator = null;
    }
}

test {
    _ = @import("activity_registry_test.zig");
}
