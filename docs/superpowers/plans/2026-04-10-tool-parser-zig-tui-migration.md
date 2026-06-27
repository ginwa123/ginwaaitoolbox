# Tool Parser Zig TUI Migration Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate tool parser pattern from desktop-bun (TypeScript) to Zig TUI with TDD approach.

**Architecture:** Create two new Zig modules: `xml_parser.zig` (XML utilities) and `tool_parser.zig` (tool call parsing), test files separate from implementation.

**Tech Stack:** Zig 0.15.2, existing TUI codebase in `src/apps/tui/`

---

## File Structure

| Implementation | Test File | Responsibility |
|----------------|-----------|----------------|
| `src/apps/tui/helpers/xml_parser.zig` | `src/apps/tui/helpers/xml_parser_test.zig` | XML entity decoding, tag extraction, format detection |
| `src/apps/tui/helpers/tool_parser.zig` | `src/apps/tui/helpers/tool_parser_test.zig` | Tool call parsing with `ToolData`/`ParseResult` structs |
| `src/apps/tui/helpers/utils.zig` | — (no test needed) | Keep existing API, delegate to xml_parser |

---

## Reference Files

- **Source pattern:** `src/apps/desktop-bun/src/mainview/utils/toolParser.ts` (459 lines)
- **Source XML utils:** `src/apps/desktop-bun/src/mainview/utils/xmlParser.ts` (123 lines)
- **Test pattern:** `src/apps/tui/display/response_test.zig` (227 lines)
- **Test pattern:** `src/apps/tui/network/sse_test.zig` (207 lines)

---

## TDD Workflow

1. **Write failing test** in `*_test.zig`
2. **Run test** — verify it fails with compile error or assertion
3. **Write minimal implementation** in `*.zig`
4. **Run test** — verify it passes
5. **Commit**

---

## Chunk 1: XML Parser Module (TDD)

### Task 1: Create `xml_parser_test.zig` FIRST

**Files:**
- Create: `src/apps/tui/helpers/xml_parser_test.zig`

- [ ] **Step 1: Write failing test file**

```zig
// src/apps/tui/helpers/xml_parser_test.zig
const std = @import("std");
const testing = std.testing;
const xml_parser = @import("xml_parser.zig");

test "decodeXmlEntities: basic entities" {
    const allocator = testing.allocator;
    
    // Test &lt;
    const r1 = try xml_parser.decodeXmlEntities("&lt;div&gt;", allocator);
    defer allocator.free(r1);
    try testing.expectEqualSlices(u8, "<div>", r1);
    
    // Test &amp;
    const r2 = try xml_parser.decodeXmlEntities("foo &amp; bar", allocator);
    defer allocator.free(r2);
    try testing.expectEqualSlices(u8, "foo & bar", r2);
    
    // Test &quot;
    const r3 = try xml_parser.decodeXmlEntities("&quot;quoted&quot;", allocator);
    defer allocator.free(r3);
    try testing.expectEqualSlices(u8, "\"quoted\"", r3);
    
    // Test &apos;
    const r4 = try xml_parser.decodeXmlEntities("&apos;single&apos;", allocator);
    defer allocator.free(r4);
    try testing.expectEqualSlices(u8, "'single'", r4);
    
    // Test combined
    const r5 = try xml_parser.decodeXmlEntities("&lt;tag attr=&quot;val&quot;&gt;", allocator);
    defer allocator.free(r5);
    try testing.expectEqualSlices(u8, "<tag attr=\"val\">", r5);
}

test "decodeXmlEntities: no entities returns copy" {
    const allocator = testing.allocator;
    
    const input = "plain text without entities";
    const result = try xml_parser.decodeXmlEntities(input, allocator);
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, input, result);
}

test "extractTag: simple tag" {
    const allocator = testing.allocator;
    
    const xml = "<tool_result><result>hello world</result></tool_result>";
    const result = try xml_parser.extractTag(xml, "result", allocator);
    defer if (result) |r| allocator.free(r);
    try testing.expect(result != null);
    try testing.expectEqualSlices(u8, "hello world", result.?);
}

test "extractTag: nested tags" {
    const allocator = testing.allocator;
    
    const xml = "<outer><inner><content>deep value</content></inner></outer>";
    const result = try xml_parser.extractTag(xml, "content", allocator);
    defer if (result) |r| allocator.free(r);
    try testing.expect(result != null);
    try testing.expectEqualSlices(u8, "deep value", result.?);
}

test "extractTag: tag not found" {
    const allocator = testing.allocator;
    
    const xml = "<root><other>value</other></root>";
    const result = try xml_parser.extractTag(xml, "missing", allocator);
    try testing.expect(result == null);
}

test "extractTag: last occurrence" {
    const allocator = testing.allocator;
    
    // Should get the LAST occurrence
    const xml = "<root><tag>first</tag><tag>second</tag></root>";
    const result = try xml_parser.extractTag(xml, "tag", allocator);
    defer if (result) |r| allocator.free(r);
    try testing.expect(result != null);
    try testing.expectEqualSlices(u8, "second", result.?);
}

test "detectFormat: xml" {
    try testing.expect(xml_parser.detectFormat("<xml>test</xml>") == .xml);
    try testing.expect(xml_parser.detectFormat("  <tag>test</tag>") == .xml);
    try testing.expect(xml_parser.detectFormat("<![CDATA[]]>") == .xml);
}

test "detectFormat: json" {
    try testing.expect(xml_parser.detectFormat("{\"key\": \"value\"}") == .json);
    try testing.expect(xml_parser.detectFormat("[1, 2, 3]") == .json);
    try testing.expect(xml_parser.detectFormat("  {\"a\":1}") == .json);
}

test "detectFormat: unknown" {
    try testing.expect(xml_parser.detectFormat("plain text") == .unknown);
    try testing.expect(xml_parser.detectFormat("") == .unknown);
    try testing.expect(xml_parser.detectFormat("   ") == .unknown);
}

test "isToolCallXml: tool call format" {
    try testing.expect(xml_parser.isToolCallXml("<tool_call><tool_name>bash</tool_name></tool_call>"));
    try testing.expect(xml_parser.isToolCallXml("<tool_calls><tool_call>...</tool_call></tool_calls>"));
    try testing.expect(!xml_parser.isToolCallXml("plain text response"));
    try testing.expect(!xml_parser.isToolCallXml(""));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --test-filter "xml_parser" 2>&1 | head -50`
Expected: FAIL with error "container 'xml_parser' has no member called..."

---

### Task 2: Create `xml_parser.zig` implementation

**Files:**
- Create: `src/apps/tui/helpers/xml_parser.zig`

- [ ] **Step 1: Write minimal implementation**

```zig
const std = @import("std");

/// XML format detection result
pub const XmlFormat = enum {
    xml,
    json,
    unknown,
};

/// Decode XML entities in a string
/// Caller owns returned slice
pub fn decodeXmlEntities(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '&') {
            // Check for &xxx; pattern
            const semicolon_idx = std.mem.indexOfScalar(u8, input[i..], ';');
            if (semicolon_idx) |idx| {
                const entity_start = i + 1;
                const entity_end = entity_start + idx;
                const entity = input[entity_start..entity_end];
                
                // Map known entities
                const decoded: []const u8 = if (std.mem.eql(u8, entity, "lt"))
                    "<"
                else if (std.mem.eql(u8, entity, "gt"))
                    ">"
                else if (std.mem.eql(u8, entity, "amp"))
                    "&"
                else if (std.mem.eql(u8, entity, "quot"))
                    "\""
                else if (std.mem.eql(u8, entity, "apos"))
                    "'"
                else
                    null;
                
                if (decoded) |d| {
                    try result.appendSlice(d);
                    i += idx + 1; // Skip past ';'
                    continue;
                }
            }
        }
        try result.append(input[i]);
    }
    
    return result.toOwnedSlice();
}

/// Extract content between XML tags (last occurrence)
/// Caller owns returned slice
pub fn extractTag(xml: []const u8, tag: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    const open_tag = try std.fmt.allocPrint(allocator, "<{s}>", .{tag});
    defer allocator.free(open_tag);
    
    const close_tag = try std.fmt.allocPrint(allocator, "</{s}>", .{tag});
    defer allocator.free(close_tag);
    
    // Find last occurrence of open_tag (handles nested tags)
    const open_pos = std.mem.lastIndexOf(u8, xml, open_tag) orelse return null;
    const close_pos = std.mem.lastIndexOf(u8, xml, close_tag) orelse return null;
    
    if (close_pos <= open_pos) return null;
    
    const content = xml[open_pos + open_tag.len .. close_pos];
    return try allocator.dupe(u8, content);
}

/// Detect if content is XML, JSON, or unknown format
pub fn detectFormat(text: []const u8) XmlFormat {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return .unknown;
    
    switch (trimmed[0]) {
        '<' => return .xml,
        '{', '[' => return .json,
        else => return .unknown,
    }
}

/// Check if content appears to be tool call XML format
pub fn isToolCallXml(content: []const u8) bool {
    if (content.len == 0) return false;
    return std.mem.indexOf(u8, content, "<tool_call>") != null or
           std.mem.indexOf(u8, content, "<tool_name>") != null;
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `zig build test --test-filter "xml_parser"`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add src/apps/tui/helpers/xml_parser.zig src/apps/tui/helpers/xml_parser_test.zig
git commit -m "feat(tui): add xml_parser module with entity decoding"
```

---

## Chunk 2: Tool Parser Module (TDD)

### Task 3: Create `tool_parser_test.zig` FIRST

**Files:**
- Create: `src/apps/tui/helpers/tool_parser_test.zig`

- [ ] **Step 1: Write failing test file**

```zig
// src/apps/tui/helpers/tool_parser_test.zig
const std = @import("std");
const testing = std.testing;
const tool_parser = @import("tool_parser.zig");

test "parseToolCallXml: bash tool" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>bash</tool_name><command>ls -la</command><result>file1\nfile2</result><exit_code>0</exit_code></tool_call>";
    
    const result = try tool_parser.parseToolCallXml(xml, allocator);
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
    
    const result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "read_file", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "/tmp/test.txt", result.tools[0].fields.path);
    try testing.expectEqualSlices(u8, "file contents", result.tools[0].fields.content);
}

test "parseToolCallXml: write_file tool" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>write_file</tool_name><path>/tmp/out.txt</path><content>hello</content><hash>abc123</hash></tool_call>";
    
    const result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "write_file", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "/tmp/out.txt", result.tools[0].fields.path);
    try testing.expectEqualSlices(u8, "abc123", result.tools[0].fields.hash);
}

test "parseToolCallXml: search tool" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>search</tool_name><pattern>fn main</pattern><path>/src</path><matches>10</matches></tool_call>";
    
    const result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "search", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "fn main", result.tools[0].fields.pattern);
    try testing.expectEqualSlices(u8, "/src", result.tools[0].fields.path);
}

test "parseToolCallXml: glob tool" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>glob</tool_name><pattern>*.zig</pattern><results>src/main.zig\nsrc/lib.zig</results></tool_call>";
    
    const result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "glob", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "*.zig", result.tools[0].fields.pattern);
}

test "parseToolCallXml: web_search tool" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>web_search</tool_name><query>zig language</query><url>https://ziglang.org</url><results>page 1</results></tool_call>";
    
    const result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "web_search", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "zig language", result.tools[0].fields.query);
    try testing.expectEqualSlices(u8, "https://ziglang.org", result.tools[0].fields.url);
}

test "parseToolCallXml: lsp_definition tool" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>lsp_definition</tool_name><file_path>/src/main.zig</file_path><line>42</line><character>10</character></tool_call>";
    
    const result = try tool_parser.parseToolCallXml(xml, allocator);
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
    
    const result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "spawn_sub_agent", result.tools[0].tool_name);
    try testing.expect(result.tools[0].fields.agents.len > 0);
}

test "parseToolCallXml: multiple tool_calls wrapper" {
    const allocator = testing.allocator;
    
    const xml = "<tool_calls><tool_call><tool_name>bash</tool_name><command>echo hi</command></tool_call><tool_call><tool_name>read_file</tool_name><path>/etc/hosts</path></tool_call></tool_calls>";
    
    const result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 2);
    try testing.expectEqualSlices(u8, "bash", result.tools[0].tool_name);
    try testing.expectEqualSlices(u8, "read_file", result.tools[1].tool_name);
}

test "parseToolCallXml: unknown tool falls back to raw" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>custom_tool</tool_name><custom_field>value</custom_field></tool_call>";
    
    const result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "custom_tool", result.tools[0].tool_name);
    try testing.expect(!result.tools[0].is_parsed); // Falls back to raw
}

test "parseToolCallXml: non-tool content returns unknown" {
    const allocator = testing.allocator;
    
    const xml = "This is just plain text response from the model.";
    
    const result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "unknown", result.tools[0].tool_name);
    try testing.expect(!result.tools[0].is_parsed);
}

test "parseToolCallXml: empty content" {
    const allocator = testing.allocator;
    
    const result = try tool_parser.parseToolCallXml("", allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 0);
    try testing.expect(result.is_complete);
}

test "parseToolCallXml: incomplete (streaming)" {
    const allocator = testing.allocator;
    
    // Missing closing </tool_call>
    const xml = "<tool_call><tool_name>bash</tool_name><command>ls";
    
    const result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(!result.is_complete);
}

test "getToolSummary: bash command" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>bash</tool_name><command>ls -la /tmp</command></tool_call>";
    const result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    const summary = try result.tools[0].getToolSummary(allocator);
    defer allocator.free(summary);
    
    try testing.expect(std.mem.indexOf(u8, summary, "ls -la").? == 0);
}

test "getToolSummary: read_file path" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>read_file</tool_name><path>/src/main.zig</path></tool_call>";
    const result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    const summary = try result.tools[0].getToolSummary(allocator);
    defer allocator.free(summary);
    
    try testing.expect(std.mem.indexOf(u8, summary, "/src/main.zig") != null);
}

test "getToolSummary: write_file" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>write_file</tool_name><path>/tmp/out.txt</path></tool_call>";
    const result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    const summary = try result.tools[0].getToolSummary(allocator);
    defer allocator.free(summary);
    
    try testing.expect(std.mem.indexOf(u8, summary, "Written:") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "/tmp/out.txt") != null);
}

test "getToolSummary: web_search query" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>web_search</tool_name><query>zig programming</query></tool_call>";
    const result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    const summary = try result.tools[0].getToolSummary(allocator);
    defer allocator.free(summary);
    
    try testing.expect(std.mem.indexOf(u8, summary, "Web:") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "zig programming") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --test-filter "tool_parser" 2>&1 | head -30`
Expected: FAIL with "container 'tool_parser' has no member..."

---

### Task 4: Create `tool_parser.zig` implementation

**Files:**
- Create: `src/apps/tui/helpers/tool_parser.zig`

- [ ] **Step 1: Write implementation**

```zig
const std = @import("std");
const xml_parser = @import("xml_parser.zig");

/// ToolFields holds the extracted fields for a tool
pub const ToolFields = struct {
    // Common fields
    command: []const u8 = "",
    result: []const u8 = "",
    exit_code: []const u8 = "",
    
    // File tool fields
    path: []const u8 = "",
    content: []const u8 = "",
    hash: []const u8 = "",
    show_line_numbers: []const u8 = "",
    
    // Search tool fields
    pattern: []const u8 = "",
    matches: []const u8 = "",
    results: []const u8 = "",
    
    // Web search fields
    query: []const u8 = "",
    url: []const u8 = "",
    
    // LSP tool fields
    file_path: []const u8 = "",
    line: []const u8 = "",
    character: []const u8 = "",
    symbol: []const u8 = "",
    
    // Spawn sub-agent fields
    agents: []const u8 = "",
    
    // Generic fallback
    raw: []const u8 = "",
};

/// ToolData holds parsed tool call information
pub const ToolData = struct {
    tool_name: []const u8,
    fields: ToolFields,
    is_parsed: bool,
    raw_content: []const u8,
    
    /// Get summary for collapsed display
    pub fn getToolSummary(self: *const ToolData, allocator: std.mem.Allocator) ![]u8 {
        const summary: []const u8 = switch (self.tool_name) {
            "bash" => self.fields.command,
            "read_file" => self.fields.path,
            "write_file" => if (self.fields.path.len > 0)
                try std.fmt.allocPrint(allocator, "Written: {s}", .{self.fields.path})
            else
                "file",
            "search" => if (self.fields.pattern.len > 0)
                try std.fmt.allocPrint(allocator, "Search: {s}", .{self.fields.pattern})
            else
                "pattern",
            "glob" => if (self.fields.pattern.len > 0)
                try std.fmt.allocPrint(allocator, "Glob: {s}", .{self.fields.pattern})
            else
                "pattern",
            "web_search", "web_search_browse" => if (self.fields.query.len > 0)
                try std.fmt.allocPrint(allocator, "Web: {s}", .{self.fields.query})
            else if (self.fields.url.len > 0)
                try std.fmt.allocPrint(allocator, "Web: {s}", .{self.fields.url})
            else
                "search",
            "spawn_sub_agent" => if (self.fields.agents.len > 0)
                try std.fmt.allocPrint(allocator, "Agents: {s}", .{self.fields.agents})
            else
                "spawn",
            else => self.tool_name,
        };
        
        if (summary == self.tool_name) {
            return try allocator.dupe(u8, summary);
        }
        return try allocator.dupe(u8, summary);
    }
};

/// ParseResult holds the result of parsing tool call XML
pub const ParseResult = struct {
    tools: []ToolData,
    is_complete: bool,
    
    /// Free owned memory
    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        for (&self.tools) |*tool| {
            allocator.free(tool.tool_name);
        }
        allocator.free(self.tools);
    }
};

/// Parse tool call XML content
/// Caller owns returned ParseResult
pub fn parseToolCallXml(content: []const u8, allocator: std.mem.Allocator) !ParseResult {
    if (content.len == 0) {
        return ParseResult{ .tools = &.{}, .is_complete = true };
    }
    
    // Check if content is tool call XML format
    if (!xml_parser.isToolCallXml(content)) {
        // Not tool call XML, return as single generic tool
        var tool = ToolData{
            .tool_name = try allocator.dupe(u8, "unknown"),
            .fields = ToolFields{ .raw = content },
            .is_parsed = false,
            .raw_content = content,
        };
        return ParseResult{
            .tools = &.{tool},
            .is_complete = true,
        };
    }
    
    var tools = std.ArrayList(ToolData).init(allocator);
    errdefer {
        for (tools.items) |*t| allocator.free(t.tool_name);
        tools.deinit();
    }
    
    // Handle multiple tool calls wrapped in <tool_calls>
    if (std.mem.indexOf(u8, content, "<tool_calls>")) |_| {
        const start = (std.mem.indexOf(u8, content, ">").?) + 1;
        const end = (std.mem.lastIndexOf(u8, content, "</tool_calls>").?);
        const tool_calls_section = content[start..end];
        
        var pos: usize = 0;
        while (pos < tool_calls_section.len) {
            const tc_start = std.mem.indexOf(u8, tool_calls_section[pos..], "<tool_call>") orelse break;
            const tc_start_pos = pos + tc_start;
            const tc_end = std.mem.indexOf(u8, tool_calls_section[tc_start_pos..], "</tool_call>") orelse break;
            const tc_block = tool_calls_section[tc_start_pos..tc_start_pos + tc_end + "</tool_call>".len];
            pos = tc_start_pos + tc_end + "</tool_call>".len;
            
            if (parseSingleToolCall(tc_block, allocator)) |tool| {
                try tools.append(tool);
            }
        }
    } else {
        // Single tool call
        if (parseSingleToolCall(content, allocator)) |tool| {
            try tools.append(tool);
        }
    }
    
    // Check completeness
    const is_complete = !isIncompleteToolXml(content);
    
    return ParseResult{
        .tools = try tools.toOwnedSlice(),
        .is_complete = is_complete,
    };
}

/// Check if content appears to be incomplete (streaming)
fn isIncompleteToolXml(content: []const u8) bool {
    const opens = std.mem.count(u8, content, "<tool_call>");
    const closes = std.mem.count(u8, content, "</tool_call>");
    if (opens > closes) return true;
    
    const opens_multi = std.mem.count(u8, content, "<tool_calls>");
    const closes_multi = std.mem.count(u8, content, "</tool_calls>");
    if (opens_multi > closes_multi) return true;
    
    return false;
}

/// Parse a single <tool_call>...</tool_call> block
fn parseSingleToolCall(tool_call_xml: []const u8, allocator: std.mem.Allocator) ?ToolData {
    // Extract tool_name
    const tool_name_opt = extractField(tool_call_xml, "tool_name");
    const tool_name = tool_name_opt orelse return null;
    if (tool_name.len == 0) return null;
    
    // Lowercase for case-insensitive matching
    const tool_name_lower = std.ascii.lowerString(allocator, tool_name);
    defer allocator.free(tool_name_lower);
    
    var fields = ToolFields{};
    var is_parsed = true;
    
    // Route to appropriate parser based on tool type
    switch (tool_name_lower) {
        "bash" => {
            fields.command = extractField(tool_call_xml, "command") orelse "";
            fields.result = extractField(tool_call_xml, "result") orelse "";
            fields.exit_code = extractField(tool_call_xml, "exit_code") orelse "";
        },
        "read_file" => {
            fields.path = extractField(tool_call_xml, "path") orelse "";
            fields.content = extractField(tool_call_xml, "content") orelse "";
            fields.hash = extractField(tool_call_xml, "hash") orelse "";
            fields.show_line_numbers = extractField(tool_call_xml, "show_line_numbers") orelse "";
        },
        "write_file" => {
            fields.path = extractField(tool_call_xml, "path") orelse "";
            fields.content = extractField(tool_call_xml, "content") orelse "";
            fields.hash = extractField(tool_call_xml, "hash") orelse "";
        },
        "search" => {
            fields.pattern = extractField(tool_call_xml, "pattern") orelse "";
            fields.path = extractField(tool_call_xml, "path") orelse "";
            fields.matches = extractField(tool_call_xml, "matches") orelse "";
        },
        "glob" => {
            fields.pattern = extractField(tool_call_xml, "pattern") orelse "";
            fields.results = extractField(tool_call_xml, "results") orelse "";
        },
        "web_search", "web_search_browse" => {
            fields.query = extractField(tool_call_xml, "query") orelse "";
            fields.url = extractField(tool_call_xml, "url") orelse "";
            fields.results = extractField(tool_call_xml, "results") orelse "";
        },
        "lsp_definition", "lsp_hover", "lsp_references", "lsp_workspace_symbol", "lsp_document_symbol" => {
            fields.file_path = extractField(tool_call_xml, "file_path") orelse "";
            fields.line = extractField(tool_call_xml, "line") orelse "";
            fields.character = extractField(tool_call_xml, "character") orelse "";
            fields.symbol = extractField(tool_call_xml, "symbol") orelse "";
        },
        "spawn_sub_agent" => {
            fields.agents = extractField(tool_call_xml, "agents") orelse "";
            fields.results = extractField(tool_call_xml, "results") orelse "";
        },
        else => {
            // Generic fallback
            is_parsed = false;
            fields.raw = tool_call_xml;
        },
    }
    
    return ToolData{
        .tool_name = try allocator.dupe(u8, tool_name_lower),
        .fields = fields,
        .is_parsed = is_parsed,
        .raw_content = tool_call_xml,
    };
}

/// Extract a field value from tool call XML (borrowed slice)
fn extractField(xml: []const u8, field_name: []const u8) ?[]const u8 {
    const open_tag = "<" ++ field_name ++ ">";
    const close_tag = "</" ++ field_name ++ ">";
    
    const open_pos = std.mem.indexOf(u8, xml, open_tag) orelse return null;
    const close_pos = std.mem.indexOf(u8, xml, close_tag) orelse return null;
    
    if (close_pos <= open_pos + open_tag.len) return null;
    
    return xml[open_pos + open_tag.len .. close_pos];
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `zig build test --test-filter "tool_parser"`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add src/apps/tui/helpers/tool_parser.zig src/apps/tui/helpers/tool_parser_test.zig
git commit -m "feat(tui): add tool_parser module with ToolData and ParseResult"
```

---

## Chunk 3: Integration with Existing Code

### Task 5: Update `utils.zig` to delegate to `xml_parser`

**Files:**
- Modify: `src/apps/tui/helpers/utils.zig`

- [ ] **Step 1: Review current utils.zig**

```zig
// Current content at src/apps/tui/helpers/utils.zig
const std = @import("std");

/// Trim leading and trailing whitespace from a string
pub fn trim(s: []const u8) []const u8 { ... }
/// Extract content between XML-like tags
pub fn extract_tag(xml: []const u8, tag: []const u8) ?[]const u8 { ... }
/// Extract content from nested response XML structure
pub fn extractContentFromResponse(response_xml: []const u8) ?[]const u8 { ... }
```

- [ ] **Step 2: Add xml_parser import (keep existing API)**

```zig
const std = @import("std");
const xml_parser = @import("xml_parser.zig");

/// Trim leading and trailing whitespace from a string
pub fn trim(s: []const u8) []const u8 { ... }  // unchanged

/// Extract content between XML-like tags (keep for backward compat)
pub fn extract_tag(xml: []const u8, tag: []const u8) ?[]const u8 { ... }  // unchanged
```

- [ ] **Step 3: Run build to verify no breakage**

Run: `zig build`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add src/apps/tui/helpers/utils.zig
git commit -m "refactor(tui): utils.zig imports xml_parser"
```

---

### Task 6: Update `tool_results.zig` to use `ToolData`

**Files:**
- Modify: `src/apps/tui/display/tool_results.zig`

- [ ] **Step 1: Write integration test**

```zig
// src/apps/tui/display/tool_results_integration_test.zig
const std = @import("std");
const testing = std.testing;
const tool_parser = @import("../helpers/tool_parser.zig");
const tool_results = @import("tool_results.zig");

test "integration: parse bash tool and display" {
    const allocator = testing.allocator;
    
    const xml = "<tool_call><tool_name>bash</tool_name><command>ls -la</command><result>file1\nfile2</result><exit_code>0</exit_code></tool_call>";
    
    const result = try tool_parser.parseToolCallXml(xml, allocator);
    defer result.deinit(allocator);
    
    try testing.expect(result.tools.len == 1);
    try testing.expectEqualSlices(u8, "bash", result.tools[0].tool_name);
}
```

Run: `zig build test --test-filter "tool_results_integration" 2>&1 | head -20`

- [ ] **Step 2: Update tool_results.zig imports**

```zig
const std = @import("std");
const globals = @import("../globals.zig");
const utils = @import("../helpers/utils.zig");
const tool_parser = @import("../helpers/tool_parser.zig");  // ADD

// Re-export ToolData
pub const ToolData = tool_parser.ToolData;
```

- [ ] **Step 3: Add helper to convert ToolResult to ToolData**

```zig
/// Convert raw tool result XML to ToolData
pub fn toolResultToToolData(result_xml: []const u8, tool_name: []const u8, allocator: std.mem.Allocator) !ToolData {
    return ToolData{
        .tool_name = try allocator.dupe(u8, tool_name),
        .fields = .{
            .result = result_xml,
        },
        .is_parsed = true,
        .raw_content = result_xml,
    };
}
```

- [ ] **Step 4: Run build to verify**

Run: `zig build`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/apps/tui/display/tool_results.zig
git commit -m "refactor(tui): tool_results.zig uses tool_parser"
```

---

### Task 7: Update `response.zig` to use `tool_parser`

**Files:**
- Modify: `src/apps/tui/display/response.zig`

- [ ] **Step 1: Add tool_parser import**

```zig
const std = @import("std");
const xml_parser = @import("../helpers/xml_parser.zig");
const tool_parser = @import("../helpers/tool_parser.zig");  // ADD
```

- [ ] **Step 2: Add helper function**

```zig
/// Parse tool calls using the new tool_parser module
/// Returns owned ParseResult - caller must call .deinit()
pub fn parseToolCallsFromXml(xml: []const u8, allocator: std.mem.Allocator) !tool_parser.ParseResult {
    return try tool_parser.parseToolCallXml(xml, allocator);
}
```

- [ ] **Step 3: Run build to verify**

Run: `zig build`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add src/apps/tui/display/response.zig
git commit -m "feat(tui): response.zig uses tool_parser for tool call parsing"
```

---

### Task 8: Update `streaming.zig` to use `tool_parser`

**Files:**
- Modify: `src/apps/tui/network/streaming.zig`

- [ ] **Step 1: Add import**

```zig
const std = @import("std");
const debug = @import("debug.zig");
const globals = @import("../globals.zig");
const sse = @import("sse.zig");
const messaging = @import("messaging.zig");
const connection = @import("connection.zig");
const utils = @import("../helpers/utils.zig");
const xml_parser = @import("../helpers/xml_parser.zig");  // ADD
const tool_parser = @import("../helpers/tool_parser.zig");  // ADD
const tool_results = @import("../display/tool_results.zig");
const response = @import("../display/response.zig");
const App = @import("../main.zig").App;
```

- [ ] **Step 2: Run build to verify**

Run: `zig build`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add src/apps/tui/network/streaming.zig
git commit -m "feat(tui): streaming.zig imports tool_parser"
```

---

## Summary

| Chunk | Task | Test File | Impl File | Test Command |
|-------|------|-----------|-----------|--------------|
| 1 | xml_parser | `xml_parser_test.zig` | `xml_parser.zig` | `zig build test --test-filter "xml_parser"` |
| 2 | tool_parser | `tool_parser_test.zig` | `tool_parser.zig` | `zig build test --test-filter "tool_parser"` |
| 3 | utils integration | — | `utils.zig` | `zig build` |
| 3 | tool_results integration | `tool_results_integration_test.zig` | `tool_results.zig` | `zig build test --test-filter "tool_results_integration"` |
| 3 | response integration | — | `response.zig` | `zig build` |
| 3 | streaming integration | — | `streaming.zig` | `zig build` |

**Build:** `zig build`
**Test:** `zig build test --test-filter "xml_parser\|tool_parser"`

---

## Test Naming Convention (from existing codebase)

```
test "module: specific behavior"
test "module: edge case"
test "integration: full workflow"
```

## TDD Pattern

```
1. Write FAILING test in *_test.zig
2. Run: zig build test --test-filter "module_name"
3. Verify: FAIL (compile error or assertion)
4. Write minimal impl in *.zig
5. Run: zig build test --test-filter "module_name"
6. Verify: PASS
7. Commit
```
