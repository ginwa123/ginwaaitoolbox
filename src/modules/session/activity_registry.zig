//! ## Session Activity Registry
//! 
//! Thread-safe registry for tracking which sessions are currently running their main while-loop.
//! Mirrors the CancellationRegistry pattern but uses atomic counters for nested/recursive tracking.
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
    sessions: std.StringHashMap(*std.atomic.Value(usize)),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(*std.atomic.Value(usize)).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.sessions.deinit();
    }

    pub fn register(self: *Self, session_id: []const u8) !void {
        const atomic = try self.allocator.create(std.atomic.Value(usize));
        atomic.* = std.atomic.Value(usize).init(0);

        const key = try self.allocator.dupe(u8, session_id);
        try self.sessions.put(key, atomic);
    }

    pub fn unregister(self: *Self, session_id: []const u8) void {
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

    pub fn is_running(self: *Self, session_id: []const u8) bool {
        if (self.sessions.get(session_id)) |atomic| {
            return atomic.load(.seq_cst) > 0;
        }
        return false;
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
