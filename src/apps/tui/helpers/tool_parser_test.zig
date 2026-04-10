const std = @import("std");
const testing = std.testing;
const tool_parser = @import("tool_parser.zig");

test "parseToolCallXml: bash tool" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>bash</tool_name><command>ls -la</command><result>file1\nfile2</result><exit_code>0</exit_code></tool_call>";
    
    var result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "bash", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "ls -la", result.tools[0].fields.command);
    try testing.expectEqualSlices(u8, "file1\nfile2", result.tools[0].fields.result);
    try testing.expectEqualSlices(u8, "0", result.tools[0].fields.exit_code);
    try testing.expect(result.is_complete);
}

test "parseToolCallXml: read_file tool" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>read_file</tool_name><path>/tmp/test.txt</path><content>file contents</content></tool_call>";
    
    var result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "read_file", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "/tmp/test.txt", result.tools[0].fields.path);
    try testing.expectEqualSlices(u8, "file contents", result.tools[0].fields.content);
}

test "parseToolCallXml: write_file tool" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>write_file</tool_name><path>/tmp/out.txt</path><content>hello</content><hash>abc123</hash></tool_call>";
    
    var result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "write_file", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "/tmp/out.txt", result.tools[0].fields.path);
    try testing.expectEqualSlices(u8, "abc123", result.tools[0].fields.hash);
}

test "parseToolCallXml: search tool" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>search</tool_name><pattern>fn main</pattern><path>/src</path><matches>10</matches></tool_call>";
    
    var result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "search", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "fn main", result.tools[0].fields.pattern);
    try testing.expectEqualSlices(u8, "/src", result.tools[0].fields.path);
}

test "parseToolCallXml: glob tool" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>glob</tool_name><pattern>*.zig</pattern><results>src/main.zig\nsrc/lib.zig</results></tool_call>";
    
    var result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "glob", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "*.zig", result.tools[0].fields.pattern);
}

test "parseToolCallXml: web_search tool" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>web_search</tool_name><query>zig language</query><url>https://ziglang.org</url><results>page 1</results></tool_call>";
    
    var result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "web_search", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "zig language", result.tools[0].fields.query);
    try testing.expectEqualSlices(u8, "https://ziglang.org", result.tools[0].fields.url);
}

test "parseToolCallXml: lsp_definition tool" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>lsp_definition</tool_name><file_path>/src/main.zig</file_path><line>42</line><character>10</character></tool_call>";
    
    var result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "lsp_definition", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "/src/main.zig", result.tools[0].fields.file_path);
    try testing.expectEqualSlices(u8, "42", result.tools[0].fields.line);
    try testing.expectEqualSlices(u8, "10", result.tools[0].fields.character);
}

test "parseToolCallXml: spawn_sub_agent tool" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>spawn_sub_agent</tool_name><agents>[{\"name\":\"test\",\"instruction\":\"do work\"}]</agents></tool_call>";
    
    var result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "spawn_sub_agent", result.tools[0].tool_name);
    try testing.expect(result.tools[0].fields.agents.len > 0);
}

test "parseToolCallXml: multiple tool_calls wrapper" {
    const allocator = testing.allocator;
    
    const xml = "<tool_calls><tool_call><tool_name>bash</tool_name><command>echo hi</command></tool_call><tool_call><tool_name>read_file</tool_name><path>/etc/hosts</path></tool_call></tool_calls>";
    
    var result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 2);
    try testing.expectEqualSlices(u8, "bash", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "read_file", result.tools[1].tool_name);
}

test "parseToolCallXml: unknown tool falls back to raw" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>custom_tool</tool_name><custom_field>value</custom_field></tool_call>";
    
    var result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "custom_tool", result.tools[0].tool_name);
    try testing.expect(!result.tools[0].is_parsed); // Falls back to raw
}

test "parseToolCallXml: non-tool content returns unknown" {
    const allocator = testing.allocator;
    
    const xml = "This is just plain text response from the model.";
    
    var result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "unknown", result.tools[0].tool_name);
    try testing.expect(!result.tools[0].is_parsed);
}

test "parseToolCallXml: empty content" {
    const allocator = testing.allocator;
    
    var result = try tool_parser.parseToolCallXml("", allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 0);
    try testing.expect(result.is_complete);
}

test "parseToolCallXml: incomplete (streaming)" {
    const allocator = testing.allocator;
    
    // Missing closing </tool_call>
    const xml = "<tool_call><tool_name>bash</tool_name><command>ls";
    
    var result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(!result.is_complete);
}

test "getToolSummary: bash command" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>bash</tool_name><command>ls -la /tmp</command></tool_call>";
    var result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    const summary = try result.tools[0].getToolSummary(allocator);
    defer allocator.free(summary);
    
    try testing.expect(std.mem.indexOf(u8, summary, "ls -la").? == 0);
}

test "getToolSummary: read_file path" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>read_file</tool_name><path>/src/main.zig</path></tool_call>";
    var result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    const summary = try result.tools[0].getToolSummary(allocator);
    defer allocator.free(summary);
    
    try testing.expect(std.mem.indexOf(u8, summary, "/src/main.zig") != null);
}

test "getToolSummary: write_file" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>write_file</tool_name><path>/tmp/out.txt</path></tool_call>";
    var result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    const summary = try result.tools[0].getToolSummary(allocator);
    defer allocator.free(summary);
    
    try testing.expect(std.mem.indexOf(u8, summary, "Written:") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "/tmp/out.txt") != null);
}

test "getToolSummary: web_search query" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>web_search</tool_name><query>zig programming</query></tool_call>";
    var result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    const summary = try result.tools[0].getToolSummary(allocator);
    defer allocator.free(summary);
    
    try testing.expect(std.mem.indexOf(u8, summary, "Web:") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "zig programming") != null);
}
