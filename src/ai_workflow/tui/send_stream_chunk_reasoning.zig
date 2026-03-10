const std = @import("std");
const http_server = @import("nalarcore").http_server;

/// Maximum size for reasoning chunk (32KB)
const MAX_CHUNK_SIZE = 32768;

pub fn run(allocator: std.mem.Allocator, session_id: []const u8, index: usize, reasoning: []const u8) void {
    _ = allocator; // No longer needed - using stack buffer
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    // Use fixed-size stack buffer instead of heap allocation
    var buf: [MAX_CHUNK_SIZE]u8 = undefined;
    var pos: usize = 0;

    // Build the XML response directly into stack buffer
    const prefix = std.fmt.bufPrint(buf[pos..], "<response><chunk index=\"{}\"><reasoning_content>", .{index}) catch return;
    pos += prefix.len;

    if (pos + reasoning.len + 40 > buf.len) return; // Check remaining space
    @memcpy(buf[pos..][0..reasoning.len], reasoning);
    pos += reasoning.len;

    const suffix = "</reasoning_content></chunk></response>";
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    const event = http_server.SseEvent{
        .event_type = "reasoning",
        .data = buf[0..pos],
    };
    sse_manager.sendEvent(session_id, event) catch {};
}
