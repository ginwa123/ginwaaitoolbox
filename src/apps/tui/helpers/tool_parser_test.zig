const std = @import("std");
const testing = std.testing;
const tool_parser = @import("tool_parser.zig");

test "parseToolCallJson: bash tool" {
    const allocator = testing.allocator;

    const json_str = \\{"name":"bash","command":"ls -la","result":"file1\\nfile2","exit_code":"0"}
;

    var result = try tool_parser.parseToolCallJson(json_str, allocator);
    defer result.deinit(allocator);

    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "bash", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "ls -la", result.tools[0].fields.command);
    try testing.expectEqualSlices(u8, "file1\nfile2", result.tools[0].fields.result);
    try testing.expectEqualSlices(u8, "0", result.tools[0].fields.exit_code);
    try testing.expect(result.is_complete);
}

test "parseToolCallJson: read_file tool" {
    const allocator = testing.allocator;

    const json_str = \\{"name":"read_file","path":"/tmp/test.txt","content":"file contents"}
;

    var result = try tool_parser.parseToolCallJson(json_str, allocator);
    defer result.deinit(allocator);

    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "read_file", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "/tmp/test.txt", result.tools[0].fields.path);
    try testing.expectEqualSlices(u8, "file contents", result.tools[0].fields.content);
}

test "parseToolCallJson: write_file tool" {
    const allocator = testing.allocator;

    const json_str = \\{"name":"write_file","path":"/tmp/out.txt","content":"hello","hash":"abc123"}
;

    var result = try tool_parser.parseToolCallJson(json_str, allocator);
    defer result.deinit(allocator);

    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "write_file", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "/tmp/out.txt", result.tools[0].fields.path);
    try testing.expectEqualSlices(u8, "abc123", result.tools[0].fields.hash);
}

test "parseToolCallJson: web_search tool" {
    const allocator = testing.allocator;

    const json_str = \\{"name":"web_search","query":"zig language","url":"https://ziglang.org","results":"page 1"}
;

    var result = try tool_parser.parseToolCallJson(json_str, allocator);
    defer result.deinit(allocator);

    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "web_search", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "zig language", result.tools[0].fields.query);
    try testing.expectEqualSlices(u8, "https://ziglang.org", result.tools[0].fields.url);
}

test "parseToolCallJson: lsp_definition tool" {
    const allocator = testing.allocator;

    const json_str = \\{"name":"lsp_definition","file_path":"/src/main.zig","line":"42","character":"10"}
;

    var result = try tool_parser.parseToolCallJson(json_str, allocator);
    defer result.deinit(allocator);

    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "lsp_definition", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "/src/main.zig", result.tools[0].fields.file_path);
    try testing.expectEqualSlices(u8, "42", result.tools[0].fields.line);
    try testing.expectEqualSlices(u8, "10", result.tools[0].fields.character);
}

test "parseToolCallJson: spawn_sub_agent tool" {
    const allocator = testing.allocator;

    const json_str = \\{"name":"spawn_sub_agent","agents":"[{\\"name\\":\\"test\\",\\"instruction\\":\\"do work\\"}]"}
;

    var result = try tool_parser.parseToolCallJson(json_str, allocator);
    defer result.deinit(allocator);

    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "spawn_sub_agent", result.tools[0].tool_name);
    try testing.expect(result.tools[0].fields.agents.len > 0);
}

test "parseToolCallJson: array of tool calls" {
    const allocator = testing.allocator;

    const json_str = \\[{"name":"bash","command":"echo hi"},{"name":"read_file","path":"/etc/hosts"}]
;

    var result = try tool_parser.parseToolCallJson(json_str, allocator);
    defer result.deinit(allocator);

    try testing.expect(result.tools.len == 2);
    try testing.expectEqualSlices(u8, "bash", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "read_file", result.tools[1].tool_name);
}

test "parseToolCallJson: unknown tool falls back to raw" {
    const allocator = testing.allocator;

    const json_str = \\{"name":"custom_tool","custom_field":"value"}
;

    var result = try tool_parser.parseToolCallJson(json_str, allocator);
    defer result.deinit(allocator);

    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "custom_tool", result.tools[0].tool_name);
    try testing.expect(!result.tools[0].is_parsed); // Falls back to raw
}

test "parseToolCallJson: non-tool content returns unknown" {
    const allocator = testing.allocator;

    const json_str = "This is just plain text response from the model.";

    var result = try tool_parser.parseToolCallJson(json_str, allocator);
    defer result.deinit(allocator);

    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "unknown", result.tools[0].tool_name);
    try testing.expect(!result.tools[0].is_parsed);
}

test "parseToolCallJson: empty content" {
    const allocator = testing.allocator;

    var result = try tool_parser.parseToolCallJson("", allocator);
    defer result.deinit(allocator);

    try testing.expect(result.tools.len == 0);
    try testing.expect(result.is_complete);
}

test "parseToolCallJson: search tool" {
    const allocator = testing.allocator;

    const json_str = \\{"name":"search","pattern":"fn main","path":"/src","matches":"10"}
;

    var result = try tool_parser.parseToolCallJson(json_str, allocator);
    defer result.deinit(allocator);

    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "search", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "fn main", result.tools[0].fields.pattern);
}

test "parseToolCallJson: glob tool" {
    const allocator = testing.allocator;

    const json_str = \\{"name":"glob","pattern":"*.zig","results":"file1.zig\\nfile2.zig"}
;

    var result = try tool_parser.parseToolCallJson(json_str, allocator);
    defer result.deinit(allocator);

    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "glob", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "*.zig", result.tools[0].fields.pattern);
}

test "getToolSummary: bash command" {
    const allocator = testing.allocator;

    const json_str = \\{"name":"bash","command":"ls -la /tmp"}
;
    var result = try tool_parser.parseToolCallJson(json_str, allocator);
    defer result.deinit(allocator);

    const summary = try result.tools[0].getToolSummary(allocator);
    defer allocator.free(summary);

    try testing.expect(std.mem.indexOf(u8, summary, "ls -la").? == 0);
}

test "getToolSummary: read_file path" {
    const allocator = testing.allocator;

    const json_str = \\{"name":"read_file","path":"/src/main.zig"}
;
    var result = try tool_parser.parseToolCallJson(json_str, allocator);
    defer result.deinit(allocator);

    const summary = try result.tools[0].getToolSummary(allocator);
    defer allocator.free(summary);

    try testing.expect(std.mem.indexOf(u8, summary, "/src/main.zig") != null);
}

test "getToolSummary: write_file" {
    const allocator = testing.allocator;

    const json_str = \\{"name":"write_file","path":"/tmp/out.txt"}
;
    var result = try tool_parser.parseToolCallJson(json_str, allocator);
    defer result.deinit(allocator);

    const summary = try result.tools[0].getToolSummary(allocator);
    defer allocator.free(summary);

    try testing.expect(std.mem.indexOf(u8, summary, "Written:") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "/tmp/out.txt") != null);
}

test "getToolSummary: web_search query" {
    const allocator = testing.allocator;

    const json_str = \\{"name":"web_search","query":"zig programming"}
;
    var result = try tool_parser.parseToolCallJson(json_str, allocator);
    defer result.deinit(allocator);

    const summary = try result.tools[0].getToolSummary(allocator);
    defer allocator.free(summary);

    try testing.expect(std.mem.indexOf(u8, summary, "Web:") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "zig programming") != null);
}
