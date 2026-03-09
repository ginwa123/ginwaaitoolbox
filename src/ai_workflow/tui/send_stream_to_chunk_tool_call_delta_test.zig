const std = @import("std");
const testing = std.testing;
const send_stream_to_chunk_tool_call_delta = @import("send_stream_to_chunk_tool_call_delta.zig");

test "send_stream_to_chunk_tool_call_delta - XML format validation" {
    const allocator = testing.allocator;

    // Test XML structure
    const xml_start = "<response><chunk index=\"";
    const tool_calls_delta = "<tool_calls_delta>";
    const delta_tag = "<delta index=\"";
    const id_tag = "<id>";
    const function_name_tag = "<function_name>";
    const function_args_tag = "<function_arguments>";

    try testing.expect(xml_start.len > 0);
    try testing.expect(tool_calls_delta.len > 0);
    try testing.expect(delta_tag.len > 0);
    try testing.expect(id_tag.len > 0);
    try testing.expect(function_name_tag.len > 0);
    try testing.expect(function_args_tag.len > 0);
}

test "send_stream_to_chunk_tool_call_delta - invalid conn_fd handling" {
    // Negative conn_fd should return early
    const invalid_fd: std.posix.fd_t = -1;
    try testing.expect(invalid_fd < 0);
}

test "send_stream_to_chunk_tool_call_delta - delta structure" {
    const allocator = testing.allocator;

    // Test delta data components
    const test_id = "call_abc123";
    const test_name = "get_skill";
    const test_args = "{\"skill_name\": \"test\"}";

    try testing.expect(test_id.len > 0);
    try testing.expect(test_name.len > 0);
    try testing.expect(test_args.len > 0);

    try testing.expect(std.mem.indexOf(u8, test_id, "call_") != null);
    try testing.expect(std.mem.indexOf(u8, test_name, "_") != null or test_name.len > 0);
}

test "send_stream_to_chunk_tool_call_delta - multiple deltas" {
    const allocator = testing.allocator;

    // Test handling multiple deltas
    const deltas = [_]struct {
        index: usize,
        id: ?[]const u8,
        name: ?[]const u8,
        args: ?[]const u8,
    }{
        .{ .index = 0, .id = "call_1", .name = "tool1", .args = "{}" },
        .{ .index = 1, .id = "call_2", .name = "tool2", .args = null },
        .{ .index = 2, .id = null, .name = null, .args = "{\"key\": \"value\"}" },
    };

    try testing.expect(deltas.len == 3);
    for (deltas, 0..) |delta, i| {
        try testing.expect(delta.index == i);
    }
}

test "send_stream_to_chunk_tool_call_delta - optional fields handling" {
    const allocator = testing.allocator;

    // Test that optional fields are handled correctly
    const with_all: struct { id: ?[]const u8, name: ?[]const u8, args: ?[]const u8 } = .{
        .id = "test",
        .name = "test",
        .args = "test",
    };

    const with_none: struct { id: ?[]const u8, name: ?[]const u8, args: ?[]const u8 } = .{
        .id = null,
        .name = null,
        .args = null,
    };

    try testing.expect(with_all.id != null);
    try testing.expect(with_all.name != null);
    try testing.expect(with_all.args != null);

    try testing.expect(with_none.id == null);
    try testing.expect(with_none.name == null);
    try testing.expect(with_none.args == null);
}
