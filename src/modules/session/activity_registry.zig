//! ## Session Activity Registry
//!
//! Thread-safe registry for tracking which sessions are currently running their main while-loop.
//! Mirrors the CancellationRegistry pattern but uses atomic counters for nested/recursive tracking.
//! Also supports message queuing for paused/interrupted sessions.
//!
//! ## Key Concepts
//!
//! - **Activity count**: Tracks nested/recursive running (increment with `mark_running`, decrement with `mark_idle`)
//! - **Stopped flag**: Separate flag that persists even when activity count is 0. Once stopped, `is_running()` returns false permanently until re-registered.
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
//!
//! // When user marks session as stopped:
//! activity_registry.get_global_registry().?.mark_stopped(session_id);
//! ```

const std = @import("std");

pub const ActivityRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// Activity count per session (0 = idle/not registered)
    sessions: std.StringHashMap(*std.atomic.Value(usize)),
    /// Message queue per session
    message_queues: std.StringHashMap(*std.ArrayList([]const u8)),
    /// Stopped flag per session - once stopped, is_running returns false until re-registered
    stopped: std.StringHashMap(?[]const u8),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(*std.atomic.Value(usize)).init(allocator),
            .message_queues = std.StringHashMap(*std.ArrayList([]const u8)).init(allocator),
            .stopped = std.StringHashMap(?[]const u8).init(allocator),
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

        // Clean up stopped flags (keys are duplicated, so free them)
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
        // If already registered, reset it (clear stopped flag and activity count)
        if (self.sessions.get(session_id)) |atomic| {
            atomic.store(0, .seq_cst);
            // Clear stopped flag when re-registering
            // fetchRemove returns the stored key (which was allocated via dupe in mark_stopped)
            if (self.stopped.fetchRemove(session_id)) |entry| {
                if (entry.value) |reason| {
                    self.allocator.free(reason);
                }
                // Free the duplicated key allocated in mark_stopped
                self.allocator.free(entry.key);
            }
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

        // Clean up stopped flag (key was duplicated in mark_stopped)
        if (self.stopped.fetchRemove(session_id)) |entry| {
            if (entry.value) |reason| {
                self.allocator.free(reason);
            }
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

    /// Mark a session as stopped with an optional reason
    /// This sets a persistent flag that makes is_running() return false
    /// until the session is re-registered.
    pub fn mark_stopped(self: *Self, session_id: []const u8) void {
        // Reset activity count to 0
        if (self.sessions.get(session_id)) |atomic| {
            atomic.store(0, .seq_cst);
        }

        // Set stopped flag if not already set
        if (!self.stopped.contains(session_id)) {
            const key = self.allocator.dupe(u8, session_id) catch return;
            // Value is null for now - we can add reason support later if needed
            self.stopped.put(key, null) catch {
                self.allocator.free(key);
            };
        }
    }

    /// Check if a session is currently running (not stopped and has activity > 0)
    pub fn is_running(self: *Self, session_id: []const u8) bool {
        // First check if session is registered
        const atomic = self.sessions.get(session_id) orelse return false;

        // Then check if session is stopped
        if (self.stopped.contains(session_id)) {
            return false;
        }

        // Finally check activity count
        return atomic.load(.seq_cst) > 0;
    }

    /// Check if a session has been explicitly stopped
    pub fn is_stopped(self: *Self, session_id: []const u8) bool {
        return self.stopped.contains(session_id);
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

    /// Get and clear all queued messages
    /// Returns null if queue is empty.
    /// Caller must call deinit() on the returned list.
    pub fn get_queue_messages(self: *Self, session_id: []const u8) ?std.ArrayList([]const u8) {
        if (self.message_queues.get(session_id)) |queue| {
            if (queue.items.len == 0) {
                return null;
            }

            // Take ownership of the queue
            const result = queue.*;
            queue.* = std.ArrayList([]const u8).empty;

            return result;
        }
        return null;
    }

    /// Delete a specific message from the queue (removes first occurrence)
    pub fn delete_queue_messages(self: *Self, session_id: []const u8, message: []const u8) void {
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

