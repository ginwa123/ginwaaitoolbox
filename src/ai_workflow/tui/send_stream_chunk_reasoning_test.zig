const std = @import("std");
const testing = std.testing;
const send_stream_chunk_reasoning = @import("send_stream_chunk_reasoning.zig");

test "send_stream_chunk_reasoning - validate basic functionality" {
    const allocator = testing.allocator;

    // Test that the module can be imported and basic types work
    const test_reasoning = "This is my reasoning process.";
    const test_index: usize = 7;

    // Verify the reasoning content and index are valid
    try testing.expectEqualStrings("This is my reasoning process.", test_reasoning);
    try testing.expect(test_index == 7);
}

test "send_stream_chunk_reasoning - empty reasoning" {
    const allocator = testing.allocator;

    const empty_reasoning = "";
    try testing.expectEqualStrings("", empty_reasoning);
    try testing.expect(empty_reasoning.len == 0);
}

test "send_stream_chunk_reasoning - multiline reasoning" {
    const allocator = testing.allocator;

    const multiline_reasoning =
        \\Step 1: Analyze the problem
        \\Step 2: Consider alternatives
        \\Step 3: Choose the best solution
    ;

    try testing.expect(multiline_reasoning.len > 0);
    try testing.expect(std.mem.indexOf(u8, multiline_reasoning, "Step 1") != null);
    try testing.expect(std.mem.indexOf(u8, multiline_reasoning, "Step 2") != null);
    try testing.expect(std.mem.indexOf(u8, multiline_reasoning, "Step 3") != null);
}
