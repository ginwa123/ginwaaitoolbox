const std = @import("std");
const mod = @import("mod.zig");
const SseEvent = mod.SseEvent;
const nalarcore = mod.nalarcore;
const event_bus_mod = nalarcore.event_bus;

pub const OnEventInputWorkers = struct {
    action: []const u8, // "created", "updated", "deleted"
    id: []const u8,
    session_id: []const u8,
    working_directory: []const u8,
    last_activity: i64,
    last_activity_description: []const u8,
    created_at: []const u8,
    event_bus: *event_bus_mod.EventBus,
};


/// Send worker events to all subscribed clients via SSE
/// Broadcasts worker list updates (created, updated, deleted)
///
/// SSE event name (the value of `event:` in the wire format):
/// - workers:  worker_created | worker_updated | worker_deleted
pub fn onEventSendWorkers(allocator: std.mem.Allocator, input: OnEventInputWorkers) !void {

    const event_bus = input.event_bus;

    // Build the payload with action and all worker columns
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const payload = .{
        .action = input.action,
        .id = input.id,
        .session_id = input.session_id,
        .working_directory = input.working_directory,
        .last_activity = input.last_activity,
        .last_activity_description = input.last_activity_description,
        .created_at = input.created_at,
    };
    try buf.print(allocator, "{f}", .{std.json.fmt(payload, .{
        .whitespace = .indent_4,
    })});

    // Duplicate the data so event owns its own copy (buf will be deallocated below)
    const data_copy = try allocator.dupe(u8, buf.items);

    // Granular event name drives the SSE wire format `event:` line —
    // the frontend's EventSource dispatches each named event to its
    // registered listener without any JSON parsing (see project memory
    // browser-eventsource-named-events.md).
    //
    // Zig 0.16 can't `switch` on `[]const u8`; use an if/else cascade
    // (Zig's std.mem.eql returns the equality cheaply for short literals).
    const event_type_name: []const u8 = if (std.mem.eql(u8, input.action, "created"))
        "worker_created"
    else if (std.mem.eql(u8, input.action, "updated"))
        "worker_updated"
    else if (std.mem.eql(u8, input.action, "deleted"))
        "worker_deleted"
    else
        "worker_unknown"; // future-proofing for new actions

    // Use "workers" as routing key for worker events
    const event = SseEvent{
        .session_id = "workers",
        .data = data_copy,
        .event_type = event_type_name,
    };

    event_bus.emit(SseEvent, "workers", event);
}

