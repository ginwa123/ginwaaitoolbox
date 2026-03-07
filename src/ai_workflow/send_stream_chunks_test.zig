const std = @import("std");
const send_stream_chunk_content = @import("send_stream_chunk_content.zig");
const send_stream_chunk_final = @import("send_stream_chunk_final.zig");
const send_stream_chunk_reasoning = @import("send_stream_chunk_reasoning.zig");

test "send_stream_chunk_content" {
    const allocator = std.testing.allocator;
    
    // Should not panic with invalid fd
    send_stream_chunk_content.run(allocator, -1, 0, "Hello, world!");
    send_stream_chunk_content.run(allocator, -1, 1, "");
    send_stream_chunk_content.run(allocator, -1, 42, "Test content with special chars: <>&\"");
}

test "send_stream_chunk_final without usage" {
    const allocator = std.testing.allocator;
    
    send_stream_chunk_final.run(allocator, -1, 0, null);
}

test "send_stream_chunk_reasoning" {
    const allocator = std.testing.allocator;
    
    send_stream_chunk_reasoning.run(allocator, -1, 0, "Let me think about this...");
    send_stream_chunk_reasoning.run(allocator, -1, 1, "");
}
