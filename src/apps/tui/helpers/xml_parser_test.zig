const std = @import("std");
const testing = std.testing;
const xml_parser = @import("xml_parser.zig");

test "decodeXmlEntities: basic entities" {
    const allocator = testing.allocator;
    
    // Test &lt;
    const r1 = try xml_parser.decodeXmlEntities(allocator, "&lt;div&gt;");
    defer allocator.free(r1);
    try testing.expectEqualSlices(u8, "<div>", r1);
    
    // Test &amp;
    const r2 = try xml_parser.decodeXmlEntities(allocator, "foo &amp; bar");
    defer allocator.free(r2);
    try testing.expectEqualSlices(u8, "foo & bar", r2);
    
    // Test &quot;
    const r3 = try xml_parser.decodeXmlEntities(allocator, "&quot;quoted&quot;");
    defer allocator.free(r3);
    try testing.expectEqualSlices(u8, "\"quoted\"", r3);
    
    // Test &apos;
    const r4 = try xml_parser.decodeXmlEntities(allocator, "&apos;single&apos;");
    defer allocator.free(r4);
    try testing.expectEqualSlices(u8, "'single'", r4);
    
    // Test combined
    const r5 = try xml_parser.decodeXmlEntities(allocator, "&lt;tag attr=&quot;val&quot;&gt;");
    defer allocator.free(r5);
    try testing.expectEqualSlices(u8, "<tag attr=\"val\">", r5);
}

test "decodeXmlEntities: no entities returns copy" {
    const allocator = testing.allocator;
    
    const input = "plain text without entities";
    const result = try xml_parser.decodeXmlEntities(allocator, input);
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
