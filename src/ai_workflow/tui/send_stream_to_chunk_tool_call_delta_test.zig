const std = @import("std");
const testing = std.testing;
const send_stream_to_chunk_tool_call_delta = @import("send_stream_to_chunk_tool_call_delta.zig");

test "send_stream_to_chunk_tool_call_delta module exists" {
    // This module depends on agent types, so we just verify it compiles
    _ = send_stream_to_chunk_tool_call_delta;
}
