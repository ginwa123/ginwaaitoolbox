//! Minimal SSE frame parser for the nalar event stream.
//!
//! The backend emits frames like:
//!
//! ```
//! event: llm_history
//! data: {"action":"updated","session_id":"session-123","id":"42",...}
//!
//! ```
//!
//! This module splits a byte stream into (event_name, data_payload)
//! pairs and extracts just the fields the TUI cares about.

const std = @import("std");

pub const Event = struct {
    /// `event:` line value (borrowed from the input buffer).
    name: []const u8,
    /// Concatenated `data:` lines (borrowed from the input buffer).
    data: []const u8,
};

/// Parse ALL complete SSE events in `buf`. Returns how many bytes were
/// consumed (events are complete only when terminated by a blank line).
/// `out` receives the parsed events (borrowed slices into buf).
pub fn parse(buf: []const u8, out: *std.ArrayList(Event), allocator: std.mem.Allocator) !usize {
    var consumed: usize = 0;
    var rest = buf;
    while (rest.len > 0) {
        const frame_end = std.mem.indexOf(u8, rest, "\n\n") orelse
            (if (std.mem.indexOf(u8, rest, "\r\n\r\n")) |i| i else break);
        const sep_len: usize = if (std.mem.startsWith(u8, rest[frame_end..], "\r\n\r\n")) 4 else 2;
        const frame = rest[0..frame_end];
        consumed += frame_end + sep_len;
        rest = rest[frame_end + sep_len ..];

        var name: []const u8 = "";
        var data_start: ?usize = null;
        var data_end: usize = 0;

        var it = std.mem.splitScalar(u8, frame, '\n');
        while (it.next()) |raw_line| {
            const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
            if (std.mem.startsWith(u8, line, "event:")) {
                name = std.mem.trim(u8, line["event:".len..], " ");
            } else if (std.mem.startsWith(u8, line, "data:")) {
                var payload = line["data:".len..];
                while (payload.len > 0 and payload[0] == ' ') payload = payload[1..];
                const offset = @intFromPtr(payload.ptr) - @intFromPtr(frame.ptr);
                if (data_start == null) data_start = offset;
                data_end = offset + payload.len;
            }
        }
        if (data_start) |ds| {
            try out.append(allocator, .{
                .name = name,
                .data = frame[ds..data_end],
            });
        }
    }
    return consumed;
}

/// Extract `"action"` from an SSE data payload (JSON). Returns null if
/// absent.
pub fn actionOf(data: []const u8) ?[]const u8 {
    return stringField(data, "action");
}

/// Extract `"session_id"` from an SSE data payload (JSON).
pub fn sessionIdOf(data: []const u8) ?[]const u8 {
    return stringField(data, "session_id");
}

fn stringField(data: []const u8, field: []const u8) ?[]const u8 {
    // Cheap scan for "\"field\":\"value\"" without a full JSON parse —
    // the payloads are small and this avoids arena churn per event.
    var pat_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":\"", .{field}) catch return null;
    const start = std.mem.indexOf(u8, data, pat) orelse return null;
    const vstart = start + pat.len;
    const vend = std.mem.indexOfScalarPos(u8, data, vstart, '"') orelse return null;
    return data[vstart..vend];
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "parse: single event with name and data" {
    var events = std.ArrayList(Event).empty;
    defer events.deinit(testing.allocator);
    const input = "event: llm_history\ndata: {\"action\":\"updated\"}\n\n";
    const consumed = try parse(input, &events, testing.allocator);
    try testing.expectEqual(input.len, consumed);
    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expectEqualStrings("llm_history", events.items[0].name);
    try testing.expectEqualStrings("{\"action\":\"updated\"}", events.items[0].data);
}

test "parse: multiple events" {
    var events = std.ArrayList(Event).empty;
    defer events.deinit(testing.allocator);
    const input = "event: a\ndata: 1\n\nevent: b\ndata: 2\n\n";
    _ = try parse(input, &events, testing.allocator);
    try testing.expectEqual(@as(usize, 2), events.items.len);
    try testing.expectEqualStrings("b", events.items[1].name);
}

test "parse: incomplete frame consumes nothing" {
    var events = std.ArrayList(Event).empty;
    defer events.deinit(testing.allocator);
    const input = "event: a\ndata: 1\n"; // no blank-line terminator
    const consumed = try parse(input, &events, testing.allocator);
    try testing.expectEqual(@as(usize, 0), consumed);
    try testing.expectEqual(@as(usize, 0), events.items.len);
}

test "actionOf: extracts action" {
    try testing.expectEqualStrings("updated", actionOf("{\"action\":\"updated\",\"x\":1}").?);
    try testing.expect(actionOf("{\"nope\":1}") == null);
}

test "sessionIdOf: extracts session_id" {
    try testing.expectEqualStrings("session-42", sessionIdOf("{\"session_id\":\"session-42\"}").?);
}
