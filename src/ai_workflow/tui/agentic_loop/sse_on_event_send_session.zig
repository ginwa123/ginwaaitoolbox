const std = @import("std");
const nalarcore = @import("nalarcore");
const SseEvent = @import("sse.zig").SseEvent;

const event_bus_mod = nalarcore.event_bus;

pub const OnEventInputSessions = struct {
    action: []const u8, // "created", "updated", "deleted"
    id: []const u8,
    name: []const u8,
    status: []const u8,
    cwd: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    selected_profile_model: []const u8 = "",
    git_worktree_cwd: []const u8 = "",
};

pub fn onEventSendSessions(
    allocator: std.mem.Allocator,
    event_bus: *event_bus_mod.EventBus,
    input: OnEventInputSessions
    ) !void {
    if (std.mem.indexOf(u8, input.id, "subagent")) |_| {
        return;
    }

    // Build the payload with action and all session columns
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const payload = .{
        .action = input.action,
        .id = input.id,
        .name = input.name,
        .status = input.status,
        .cwd = input.cwd,
        .created_at = input.created_at,
        .updated_at = input.updated_at,
        .selected_profile_model = input.selected_profile_model,
    };
    try buf.print(allocator, "{f}", .{std.json.fmt(payload, .{
        .whitespace = .indent_4,
    })});

    // Duplicate the data so event owns its own copy (buf will be deallocated below)
    const data_copy = try allocator.dupe(u8, buf.items);

    // Granular event name drives the SSE wire format `event:` line.
    // Today only `created` is emitted; the if/else covers future actions.
    // (Zig 0.16 can't `switch` on `[]const u8`.)
    const event_type_name: []const u8 = if (std.mem.eql(u8, input.action, "created"))
        "session_created"
    else if (std.mem.eql(u8, input.action, "deleted"))
        "session_deleted"
    else
        "session_unknown"; // future-proofing for new actions

    // Use actual session_id as routing key and in event
    const event = SseEvent{
        .session_id = input.id,
        .data = data_copy,
        .event_type = event_type_name,
    };

    event_bus.emit(SseEvent, "sessions", event);
}
