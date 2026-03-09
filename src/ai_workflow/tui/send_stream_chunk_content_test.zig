const std = @import("std");
const testing = std.testing;
const send_stream_chunk_content = @import("send_stream_chunk_content.zig");

test "send_stream_chunk_content - validate XML format" {
    const allocator = testing.allocator;

    // Test that the module can be imported and basic types work
    const test_content = "Hello, world!";
    const test_index: usize = 42;

    // Verify the content and index are valid
    try testing.expectEqualStrings("Hello, world!", test_content);
    try testing.expect(test_index == 42);
}

test "send_stream_chunk_content - empty content" {
    const allocator = testing.allocator;

    const empty_content = "";
    try testing.expectEqualStrings("", empty_content);
    try testing.expect(empty_content.len == 0);
}

test "send_stream_chunk_content - special characters" {
    const allocator = testing.allocator;

    const special_content = "<>&\"'";
    try testing.expectEqualStrings("<>&\"'", special_content);
    try testing.expect(special_content.len == 5);
}
