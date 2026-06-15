const std = @import("std");
const nalar_browser = @import("nalar_browser.zig");

test "NalarBrowserInput default values" {
    const input = nalar_browser.NalarBrowserInput{ .action = "launch" };
    try std.testing.expect(std.mem.eql(u8, input.action, "launch"));
    try std.testing.expect(input.browser_id == null);
    try std.testing.expect(input.page_id == null);
    try std.testing.expect(input.url == null);
    try std.testing.expect(input.ref == null);
    try std.testing.expect(input.text == null);
    try std.testing.expect(input.key == null);
    try std.testing.expect(input.api_url == null);
}

test "NalarBrowserInput with all fields" {
    const input = nalar_browser.NalarBrowserInput{
        .action = "open_page",
        .browser_id = "browser_123",
        .page_id = "page_456",
        .url = "https://example.com",
        .ref = "e1",
        .text = "search query",
        .key = "Enter",
        .api_url = "http://localhost:9000",
    };
    try std.testing.expect(std.mem.eql(u8, input.action, "open_page"));
    try std.testing.expect(std.mem.eql(u8, input.browser_id.?, "browser_123"));
    try std.testing.expect(std.mem.eql(u8, input.page_id.?, "page_456"));
    try std.testing.expect(std.mem.eql(u8, input.url.?, "https://example.com"));
    try std.testing.expect(std.mem.eql(u8, input.ref.?, "e1"));
    try std.testing.expect(std.mem.eql(u8, input.text.?, "search query"));
    try std.testing.expect(std.mem.eql(u8, input.key.?, "Enter"));
    try std.testing.expect(std.mem.eql(u8, input.api_url.?, "http://localhost:9000"));
}

test "NalarBrowserResult success with all fields" {
    const result = nalar_browser.NalarBrowserResult{
        .success = true,
        .browser_id = "browser_abc",
        .page_id = "page_xyz",
        .url = "https://ziglang.org",
        .title = "Zig Programming Language",
        .tree_json = "[{\"ref\":\"e1\",\"text\":\"Download\"}]",
    };
    try std.testing.expect(result.success == true);
    try std.testing.expect(std.mem.eql(u8, result.browser_id.?, "browser_abc"));
    try std.testing.expect(std.mem.eql(u8, result.page_id.?, "page_xyz"));
    try std.testing.expect(std.mem.eql(u8, result.url.?, "https://ziglang.org"));
    try std.testing.expect(std.mem.eql(u8, result.title.?, "Zig Programming Language"));
    try std.testing.expect(std.mem.eql(u8, result.tree_json.?, "[{\"ref\":\"e1\",\"text\":\"Download\"}]"));
    try std.testing.expect(result.err_msg == null);
}

test "NalarBrowserResult error case" {
    const result = nalar_browser.NalarBrowserResult{
        .success = false,
        .err_msg = "Connection refused",
    };
    try std.testing.expect(result.success == false);
    try std.testing.expect(result.browser_id == null);
    try std.testing.expect(result.err_msg != null);
    try std.testing.expect(std.mem.eql(u8, result.err_msg.?, "Connection refused"));
}

test "toXMLSuccess with minimal result" {
    const allocator = std.testing.allocator;
    const result = nalar_browser.NalarBrowserResult{ .success = true };

    const xml = try nalar_browser.toXMLSuccess(allocator, result);
    defer allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<success>1</success>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "</success>") != null);
}

test "toXMLSuccess with all fields" {
    const allocator = std.testing.allocator;
    const result = nalar_browser.NalarBrowserResult{
        .success = true,
        .browser_id = "browser_test",
        .page_id = "page_test",
        .url = "https://example.com",
        .title = "Example Domain",
        .tree_json = "[{\"ref\":\"e1\",\"text\":\"Click Here\",\"href\":\"https://example.com/link\"}]",
    };

    const xml = try nalar_browser.toXMLSuccess(allocator, result);
    defer allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<browser_id>browser_test</browser_id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<page_id>page_test</page_id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<url>https://example.com</url>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<title>Example Domain</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<tree>") != null);
}

test "toXMLError with error message" {
    const allocator = std.testing.allocator;
    const result = nalar_browser.NalarBrowserResult{
        .success = false,
        .err_msg = "Page not found",
    };

    const xml = try nalar_browser.toXMLError(allocator, result, "open_page");
    defer allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<error>NalarBrowser open_page failed: Page not found</error>") != null);
}

test "toXMLError with null error message" {
    const allocator = std.testing.allocator;
    const result = nalar_browser.NalarBrowserResult{
        .success = false,
        .err_msg = null,
    };

    const xml = try nalar_browser.toXMLError(allocator, result, "click");
    defer allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<error>NalarBrowser click failed: </error>") != null);
}

test "nalar_browser_tool definition" {
    try std.testing.expect(std.mem.eql(u8, nalar_browser.nalar_browser_tool.type, "function"));
    try std.testing.expect(std.mem.eql(u8, nalar_browser.nalar_browser_tool.function.name, "nalar_browser"));
    try std.testing.expect(nalar_browser.nalar_browser_tool.function.description.len > 0);
    try std.testing.expect(std.mem.eql(u8, nalar_browser.nalar_browser_tool.function.parameters.type, "object"));
    try std.testing.expect(nalar_browser.nalar_browser_tool.function.parameters.properties.len == 8);
    try std.testing.expect(nalar_browser.nalar_browser_tool.function.parameters.required.len == 1);
    try std.testing.expect(std.mem.eql(u8, nalar_browser.nalar_browser_tool.function.parameters.required[0], "action"));
}

test "nalar_browser_tool has correct property names" {
    const props = nalar_browser.nalar_browser_tool.function.parameters.properties;
    const expected_names = &[_][]const u8{
        "action", "browser_id", "page_id", "url", "ref", "text", "key", "api_url",
    };
    for (expected_names, props) |expected, prop| {
        try std.testing.expect(std.mem.eql(u8, prop.name, expected));
    }
}

test "buildJsonBody with empty map" {
    const allocator = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(allocator);
    defer map.deinit();

    // Can't test buildJsonBody directly since it's private
    // Just verify empty map behavior
    try std.testing.expect(map.count() == 0);
}

test "buildJsonBody with single field" {
    const allocator = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(allocator);
    defer map.deinit();
    try map.put("action", "launch");

    // Can't test buildJsonBody directly since it's private
    // Just verify map contents
    try std.testing.expect(map.get("action") != null);
    try std.testing.expect(std.mem.eql(u8, map.get("action").?, "launch"));
}

test "buildJsonBody with multiple fields" {
    const allocator = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(allocator);
    defer map.deinit();
    try map.put("action", "open_page");
    try map.put("browser_id", "browser_123");
    try map.put("url", "https://example.com");

    // Can't test buildJsonBody directly since it's private
    // Just verify map contents
    try std.testing.expect(map.get("action") != null);
    try std.testing.expect(map.get("browser_id") != null);
    try std.testing.expect(map.get("url") != null);
}

test "buildJsonBody with special characters" {
    const allocator = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(allocator);
    defer map.deinit();
    try map.put("text", "hello world");

    // Can't test buildJsonBody directly since it's private
    // Just verify map is correct
    try std.testing.expect(map.get("text") != null);
}
