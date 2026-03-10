const std = @import("std");
const http_server = @import("nalarcore").http_server;

/// Maximum size for chunk content (32KB)
const MAX_CHUNK_SIZE = 32768;

pub fn run(allocator: std.mem.Allocator, session_id: []const u8, index: usize, content: []const u8) void {
    _ = allocator; // No longer needed - using stack buffer
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    // Use fixed-size stack buffer instead of heap allocation
    var buf: [MAX_CHUNK_SIZE]u8 = undefined;
    var pos: usize = 0;

    // Build the XML response directly into stack buffer
    const prefix = std.fmt.bufPrint(buf[pos..], "<response><chunk index=\"{}\"><content>", .{index}) catch return;
    pos += prefix.len;

    if (pos + content.len + 30 > buf.len) return; // Check remaining space for content + closing tags
    @memcpy(buf[pos..][0..content.len], content);
    pos += content.len;

    const suffix = "</content></chunk></response>";
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    const event = http_server.SseEvent{
        .event_type = "chunk",
        .data = buf[0..pos],
    };
    sse_manager.sendEvent(session_id, event) catch {};
}
