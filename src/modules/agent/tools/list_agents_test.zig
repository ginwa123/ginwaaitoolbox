const std = @import("std");
const list_agents = @import("list_agents.zig");
const agents = @import("agents.zig");

test "list_agents_tool has correct structure" {
    // Verify tool definition
    try std.testing.expectEqualStrings("function", list_agents.list_agents_tool.type);
    try std.testing.expectEqualStrings("list_agents", list_agents.list_agents_tool.function.name);
    try std.testing.expectEqualStrings("object", list_agents.list_agents_tool.function.parameters.type);
    try std.testing.expectEqual(@as(usize, 0), list_agents.list_agents_tool.function.parameters.properties.len);
    try std.testing.expectEqual(@as(usize, 0), list_agents.list_agents_tool.function.parameters.required.len);
}

test "execute_list_agents returns valid JSON" {
    const allocator = std.testing.allocator;

    const result = try list_agents.execute_list_agents(allocator);
    defer allocator.free(result);

    // Verify result is valid JSON starting with {"agents":[
    try std.testing.expectStringStartsWith(result, "{\"agents\":[");
    try std.testing.expectStringEndsWith(result, "]}");
}

test "execute_list_agents returns valid JSON structure" {
    const allocator = std.testing.allocator;

    const result = try list_agents.execute_list_agents(allocator);
    defer allocator.free(result);

    // Verify JSON structure is valid - starts with {"agents":[ and ends with ]}
    // Don't assert on specific content since sample agents may exist
    try std.testing.expectStringStartsWith(result, "{\"agents\":[");
    try std.testing.expectStringEndsWith(result, "]}");

    // Verify the result is valid JSON by checking brackets are balanced
    var brace_count: i32 = 0;
    var bracket_count: i32 = 0;
    var in_string = false;
    var escape_next = false;

    for (result) |c| {
        if (escape_next) {
            escape_next = false;
            continue;
        }
        if (c == '\\') {
            escape_next = true;
            continue;
        }
        if (c == '"' and !escape_next) {
            in_string = !in_string;
            continue;
        }
        if (!in_string) {
            switch (c) {
                '{' => brace_count += 1,
                '}' => brace_count -= 1,
                '[' => bracket_count += 1,
                ']' => bracket_count -= 1,
                else => {},
            }
        }
    }

    try std.testing.expectEqual(@as(i32, 0), brace_count);
    try std.testing.expectEqual(@as(i32, 0), bracket_count);
}

test "escape_json_string escapes quotes" {
    const allocator = std.testing.allocator;

    const input = "Hello \"world\"";
    const result = list_agents.escape_json_string(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello \\\"world\\\"", result);
}

test "escape_json_string escapes backslashes" {
    const allocator = std.testing.allocator;

    const input = "path\\to\\file";
    const result = list_agents.escape_json_string(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("path\\\\to\\\\file", result);
}

test "escape_json_string escapes newlines" {
    const allocator = std.testing.allocator;

    const input = "line1\nline2";
    const result = list_agents.escape_json_string(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("line1\\nline2", result);
}

test "escape_json_string escapes tabs" {
    const allocator = std.testing.allocator;

    const input = "col1\tcol2";
    const result = list_agents.escape_json_string(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("col1\\tcol2", result);
}

test "escape_json_string handles empty string" {
    const allocator = std.testing.allocator;

    const input = "";
    const result = list_agents.escape_json_string(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "escape_json_string handles string without special chars" {
    const allocator = std.testing.allocator;

    const input = "Hello World";
    const result = list_agents.escape_json_string(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello World", result);
}
